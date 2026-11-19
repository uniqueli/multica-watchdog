// multica-notify — Multica 菜单栏通知宠物 🐕
// 轮询 Multica Inbox(mentioned + status_changed) → macOS 系统通知
// 构建: 见同目录 build.sh; 配置: ~/.multica-notify.json; 凭证: ~/.multica/config.json

import AppKit
import UserNotifications
import Foundation

// MARK: - 数据模型

struct AppConfig: Codable {
    var intervalSec: Double = 30
    var paused: Bool = false
    var notifyMention: Bool = true
    var notifyStatus: Bool = true
    var recent: [RecentItem] = []
}

struct RecentItem: Codable {
    var id: String
    var title: String
    var issueID: String
    var at: String
}

struct MulticaCreds: Codable {
    var server_url: String
    var app_url: String?
    var workspace_id: String?
    var token: String
}

struct InboxItem: Codable {
    let id: String
    let type: String
    let title: String?
    let read: Bool?
    let archived: Bool?
    let created_at: String?
    let issue_id: String?
    let issue_status: String?
}

// MARK: - 状态

enum ConnState { case ok, offline, badCreds }

let home = FileManager.default.homeDirectoryForCurrentUser.path
let cfgPath = home + "/.multica-notify.json"
let seenPath = home + "/.multica-notify.seen.json"
let credsPath = home + "/.multica/config.json"
let launchAgentPlist = home + "/Library/LaunchAgents/com.uniqueli.multica-notify.plist"
let intervals: [(Double, String)] = [(30, "30 秒"), (60, "1 分钟"), (300, "5 分钟"), (900, "15 分钟")]
let watchTypes: Set<String> = ["mentioned", "status_changed"]

let dbgPath = home + "/.multica-notify.log"
func dbg(_ s: String) {
    let line = "[" + TimeStamp() + "] " + s + "\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if !FileManager.default.fileExists(atPath: dbgPath) {
        FileManager.default.createFile(atPath: dbgPath, contents: nil)
    }
    if let h = FileHandle(forWritingAtPath: dbgPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    }
}
func TimeStamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var cfg = AppConfig()
    var seen = Set<String>()
    var seeded = false
    var conn: ConnState = .ok
    var lastCheck: Date?
    var unreadNew = 0
    var creds: MulticaCreds?
    var appWebURL = "https://multica.jiaoyanyun.com"
    let menu = NSMenu()
    let fm = FileManager.default
    let isoIn: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        dbg("[launch] start")
        cfg = loadJSON(cfgPath) ?? AppConfig()
        loadCreds()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.menuBarFont(ofSize: 15)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
            dbg("[notif] auth granted=\(granted) err=\(String(describing: err))")
        }
        UNUserNotificationCenter.current().delegate = self

        poll()
        scheduleTimer()
    }

    // MARK: 凭证 / 持久化

    func loadCreds() {
        var c: MulticaCreds? = loadJSON(credsPath)
        if c == nil || c?.token.isEmpty == true {
            // 队友可能只有桌面端profile凭证
            let pdir = home + "/.multica/profiles"
            if let dirs = try? fm.contentsOfDirectory(atPath: pdir) {
                for d in dirs.sorted() where c == nil {
                    let pc: MulticaCreds? = loadJSON(pdir + "/" + d + "/config.json")
                    if let pc, !pc.token.isEmpty { c = pc; dbg("[creds] 用profile凭证: \(d)") }
                }
            }
        }
        guard let c else {
            dbg("[creds] 无可用凭证(先 multica login)")
            conn = .badCreds; return
        }
        creds = c
        var base = (c.app_url ?? c.server_url).replacingOccurrences(of: "http://", with: "https://")
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        appWebURL = base
    }

    func loadJSON<T: Decodable>(_ path: String) -> T? {
        guard let data = fm.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func saveState() {
        if let d = try? JSONEncoder().encode(cfg) { fm.createFile(atPath: cfgPath, contents: d) }
        if let d = try? JSONEncoder().encode(Array(seen.suffix(500))) { fm.createFile(atPath: seenPath, contents: d) }
    }

    // MARK: 轮询

    func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: cfg.intervalSec, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        guard !cfg.paused, let creds else { return }
        guard let url = URL(string: "\(creds.server_url.replacingOccurrences(of: "http://", with: "https://"))/api/inbox?workspace_id=\(creds.workspace_id ?? "")") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer " + creds.token, forHTTPHeaderField: "Authorization")

        let sessionCfg = URLSessionConfiguration.ephemeral
            sessionCfg.connectionProxyDictionary = [:]  // 内网直连,绕开系统代理(Clash)
            URLSession(configuration: sessionCfg).dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastCheck = Date()
                if err != nil || !(200...299).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    dbg("[poll] err=\(String(describing: err)) code=\(code)")
                    self.conn = (code == 401 || code == 403) ? .badCreds : .offline
                    self.refreshIcon(); return
                }
                guard let data, let items = try? JSONDecoder().decode([InboxItem].self, from: data) else {
                    dbg("[poll] decode失败 bytes=\(data?.count ?? -1)")
                    self.conn = .offline; self.refreshIcon(); return
                }
                dbg("[poll] ok items=\(items.count)")
                self.conn = .ok
                if !self.seeded, self.seen.isEmpty, let s: [String] = self.loadJSON(seenPath) {
                    self.seen = Set(s)
                }
                var types = watchTypes
                if !self.cfg.notifyMention { types.remove("mentioned") }
                if !self.cfg.notifyStatus { types.remove("status_changed") }
                let fresh = items.filter { ($0.read != true) && ($0.archived != true) && types.contains($0.type) }
                if !self.seeded && self.seen.isEmpty {
                    // 首次运行:播种全部,只补通知近3分钟
                    self.seen = Set(fresh.map(\.id))
                    self.seeded = true
                    let cutoff = Date().addingTimeInterval(-180)
                    let backlog = fresh.filter { self.parseDate($0.created_at) > cutoff }
                    dbg("[poll] 首次播种 seen=\(self.seen.count) backlog=\(backlog.count)")
                    if !backlog.isEmpty { self.notify(backlog) }
                    self.saveState()
                    return
                }
                self.seeded = true
                let news = fresh.filter { !self.seen.contains($0.id) }
                if !news.isEmpty {
                    self.seen.formUnion(news.map(\.id))
                    dbg("[poll] 新通知 \(news.count) 条")
                    self.notify(news)
                    self.saveState()
                }
                self.refreshIcon()
            }
        }.resume()
    }

    func parseDate(_ s: String?) -> Date {
        guard let s, let d = isoIn.date(from: s) else { return .distantPast }
        return d
    }

    // MARK: 通知

    func notify(_ items: [InboxItem]) {
        unreadNew += items.count
        var cap = items; if cap.count > 5 { cap = Array(cap.prefix(5)) }
        let center = UNUserNotificationCenter.current()
        for it in cap {
            let content = UNMutableNotificationContent()
            switch it.type {
            case "mentioned": content.title = "【Multica】有人@你"
            default: content.title = "【Multica】任务状态更新"
            }
            content.body = "\(it.title ?? "(无标题)")" + (it.issue_status.map { " → \($0)" } ?? "")
            content.sound = .default
            if let iid = it.issue_id { content.userInfo = ["issue": iid] }
            let req = UNNotificationRequest(identifier: it.id, content: content, trigger: nil)
            center.add(req)
            center.getNotificationSettings { st in
                if st.authorizationStatus != .authorized {
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    p.arguments = ["-e", "display notification \(String(describing: content.body).replacingOccurrences(of: "\"", with: "'")) with title \(String(describing: content.title).replacingOccurrences(of: "\"", with: "'")) sound name \"Glass\""]
                    try? p.run()
                }
            }
            cfg.recent.insert(RecentItem(id: it.id, title: content.body, issueID: it.issue_id ?? "", at: it.created_at ?? ""), at: 0)
        }
        if items.count > 5 {
            let sum = UNMutableNotificationContent()
            sum.title = "【Multica】还有 \(items.count - 5) 条新通知"
            sum.body = "点击菜单栏 🐕 查看"
            sum.sound = .default
            center.add(UNNotificationRequest(identifier: "summary-\(Date().timeIntervalSince1970)", content: sum, trigger: nil))
        }
        cfg.recent = Array(cfg.recent.prefix(5))
        saveState()
        refreshIcon()
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler h: @escaping () -> Void) {
        if let iid = r.notification.request.content.userInfo["issue"] as? String {
            openIssue(iid)
        }
        h()
    }

    func localAppExists() -> Bool {
        fm.fileExists(atPath: "/Applications/Multica.app") || fm.fileExists(atPath: home + "/Applications/Multica.app")
    }
    @objc func openWeb() {
        if localAppExists() {
            let path = fm.fileExists(atPath: "/Applications/Multica.app") ? "/Applications/Multica.app" : home + "/Applications/Multica.app"
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(string: appWebURL)!)
        }
    }
    func openIssue(_ iid: String) {
        // 本地App优先(multica:// scheme),失败回落网页
        if localAppExists(), let deep = URL(string: "multica://issues/\(iid)") {
            if NSWorkspace.shared.open(deep) { return }
        }
        NSWorkspace.shared.open(URL(string: "\(appWebURL)/issues/\(iid)")!)
    }

    // MARK: 菜单

    func refreshIcon() {
        let base = "🐕"
        switch conn {
        case .ok: statusItem.button?.title = unreadNew > 0 ? base + "·\(min(unreadNew, 99))" : base
        case .offline: statusItem.button?.title = base + "💤"
        case .badCreds: statusItem.button?.title = base + "❗"
        }
    }

    func rebuildMenu() {
        menu.removeAllItems()
        let stateStr: String
        switch conn {
        case .ok: stateStr = "● 已连接 · \(unreadNew) 条新"
        case .offline: stateStr = "💤 离线(重试中)"
        case .badCreds: stateStr = "❗ 凭证失效(multica login)"
        }
        menu.addItem(disabled(stateStr))
        menu.addItem(disabled("最近检查: " + (lastCheck.map { "\(Int(Date().timeIntervalSince($0))) 秒前" } ?? "—")))
        menu.addItem(.separator())

        let intervalItem = NSMenuItem(title: "轮询间隔", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (sec, label) in intervals {
            let mi = NSMenuItem(title: (cfg.intervalSec == sec ? "✓ " : "   ") + label,
                                action: #selector(setInterval(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = sec
            sub.addItem(mi)
        }
        intervalItem.submenu = sub
        menu.addItem(intervalItem)

        let filterItem = NSMenuItem(title: "通知过滤", action: nil, keyEquivalent: "")
        let fsub = NSMenu()
        let fm1 = NSMenuItem(title: (cfg.notifyMention ? "✓ " : "   ") + "有人@我", action: #selector(toggleFilter(_:)), keyEquivalent: "")
        fm1.target = self; fm1.representedObject = "mention"
        let fm2 = NSMenuItem(title: (cfg.notifyStatus ? "✓ " : "   ") + "任务状态/完成", action: #selector(toggleFilter(_:)), keyEquivalent: "")
        fm2.target = self; fm2.representedObject = "status"
        fsub.addItem(fm1); fsub.addItem(fm2)
        filterItem.submenu = fsub
        menu.addItem(filterItem)
        menu.addItem(.separator())

        let pause = NSMenuItem(title: cfg.paused ? "▶ 恢复通知" : "⏸ 暂停通知",
                               action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self; menu.addItem(pause)

        let web = NSMenuItem(title: "📖 打开 Multica", action: #selector(openWeb), keyEquivalent: "m")
        web.target = self; menu.addItem(web)

        let auto = NSMenuItem(title: fm.fileExists(atPath: launchAgentPlist) ? "🚀 开机自启: 已开" : "🚀 开机自启: 关",
                              action: #selector(toggleAutostart), keyEquivalent: "")
        auto.target = self; menu.addItem(auto)

        if !cfg.recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabled("最近通知"))
            for r in cfg.recent.prefix(5) {
                let mi = NSMenuItem(title: " " + String(r.title.prefix(40)),
                                    action: #selector(openRecent(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = r.issueID
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
    }

    func disabled(_ t: String) -> NSMenuItem {
        let mi = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        cfg.intervalSec = sender.representedObject as! Double
        saveState(); scheduleTimer(); refreshIcon()
    }
    @objc func toggleFilter(_ sender: NSMenuItem) {
        if sender.representedObject as? String == "mention" { cfg.notifyMention.toggle() }
        else { cfg.notifyStatus.toggle() }
        saveState()
    }
    @objc func togglePause() {
        cfg.paused.toggle(); saveState(); refreshIcon()
        if !cfg.paused { poll() }
    }
    @objc func openRecent(_ sender: NSMenuItem) {
        if let iid = sender.representedObject as? String, !iid.isEmpty { openIssue(iid) } else { openWeb() }
    }
    @objc func toggleAutostart() {
        if fm.fileExists(atPath: launchAgentPlist) {
            try? fm.removeItem(atPath: launchAgentPlist)
            runProcess("/bin/launchctl", ["unload", launchAgentPlist])
        } else {
            let bundle = Bundle.main.bundleURL.path
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
              <key>Label</key><string>com.uniqueli.multica-notify</string>
              <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>\(bundle)</string></array>
              <key>RunAtLoad</key><true/>
            </dict></plist>
            """
            fm.createFile(atPath: launchAgentPlist, contents: plist.data(using: .utf8))
            runProcess("/bin/launchctl", ["load", launchAgentPlist])
        }
    }

    func runProcess(_ path: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        try? p.run(); p.waitUntilExit()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
