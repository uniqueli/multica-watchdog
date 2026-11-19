// multica-watchdog — Multica 菜单栏通知宠物 🐕
// 轮询 Multica Inbox(mentioned + status_changed) → macOS 系统通知
// 构建: 见同目录 build.sh; 配置: ~/.multica-watchdog.json; 凭证: ~/.multica/config.json

import AppKit
import AVFoundation
import UserNotifications
import Foundation

// MARK: - 数据模型

struct AppConfig: Codable {
    var intervalSec: Double = 30
    var paused: Bool = false
    var notifyMention: Bool = true
    var notifyStatus: Bool = true
    var funMode: Bool? = nil            // legacy, 已拆分为下面两项
    var soundEnabled: Bool? = nil
    var petEmoji: String = "🐕"
    var soundMode: String = "voice"   // voice | system | custom | off
    var dndEnabled: Bool = false
    var dndStart: String = "22:00"
    var dndEnd: String = "08:00"
    var pausedUntil: Double? = nil    // epoch秒,定时暂停到期时刻
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
    let actor_id: String?
    let actor_type: String?
}

// MARK: - 状态

enum ConnState { case ok, offline, badCreds }

let home = FileManager.default.homeDirectoryForCurrentUser.path
let cfgPath = home + "/.multica-watchdog.json"
let seenPath = home + "/.multica-watchdog.seen.json"
let credsPath = home + "/.multica/config.json"
let launchAgentPlist = home + "/Library/LaunchAgents/com.uniqueli.multica-watchdog.plist"
let intervals: [(Double, String)] = [(30, "30 秒"), (60, "1 分钟"), (300, "5 分钟"), (900, "15 分钟")]
let watchTypes: Set<String> = ["mentioned", "status_changed"]
let APP_VERSION = "0.2.5"
let RELEASE_API = "https://api.github.com/repos/uniqueli/multica-watchdog/releases/latest"

func isNewer(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}

extension AppConfig {
    var soundOn: Bool { soundMode != "off" && (soundEnabled ?? funMode ?? true) }
}

let dbgPath = home + "/.multica-watchdog.log"
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
        // 单实例接管: 已有实例在跑(如旧版本未退出)→替换之
        if let bid = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid).filter { $0.processIdentifier != me }
            if !others.isEmpty {
                dbg("[single] 接管旧实例: \(others.map(\.processIdentifier))")
                for o in others { o.terminate() }
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
        dbg("[launch] start")
        cfg = loadJSON(cfgPath) ?? AppConfig()
        if cfg.soundEnabled == false { cfg.soundMode = "off" }   // 旧静音开关迁移
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

        loadSlug()
        loadActors()
        checkUpdate(manual: false)
        poll()
        scheduleTimer()

        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.notify([InboxItem(id: "demo-\(Int(Date().timeIntervalSince1970))", type: "mentioned",
                                        title: "趣味模式演示:有人@你啦", read: false, archived: false,
                                        created_at: nil, issue_id: "01a1f1cf-bca3-7702-8443-8dd168bc1ff5", issue_status: nil, actor_id: nil, actor_type: nil)])
            }
        }
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
        guard !effectivePaused, let creds else { return }
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

    func loadSlug() {
        guard let creds else { return }
        let base = creds.server_url.replacingOccurrences(of: "http://", with: "https://")
        guard let url = URL(string: base + "/api/workspaces") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer " + creds.token, forHTTPHeaderField: "Authorization")
        let sc = URLSessionConfiguration.ephemeral
        sc.connectionProxyDictionary = [:]
        URLSession(configuration: sc).dataTask(with: req) { [weak self] data, resp, _ in
            guard let data, (200...299).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let want = self?.creds?.workspace_id ?? ""
            let hit = arr.first { ($0["id"] as? String) == want } ?? arr.first
            let slug = (hit?["slug"] as? String) ?? ""
            DispatchQueue.main.async { self?.wsSlug = slug; dbg("[slug] \(slug)") }
        }.resume()
    }

    func loadActors() {
        guard let creds else { return }
        let base = creds.server_url.replacingOccurrences(of: "http://", with: "https://")
        let ws = creds.workspace_id ?? ""
        let paths = ["/api/workspaces/\(ws)/members", "/api/agents?workspace_id=\(ws)"]
        let sc = URLSessionConfiguration.ephemeral
        sc.connectionProxyDictionary = [:]
        let grp = DispatchGroup()
        for p in paths {
            guard let url = URL(string: base + p) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("Bearer " + creds.token, forHTTPHeaderField: "Authorization")
            grp.enter()
            URLSession(configuration: sc).dataTask(with: req) { [weak self] data, resp, _ in
                defer { grp.leave() }
                guard let data, (200...299).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
                var got = 0
                for o in arr {
                    if let i = o["id"] as? String, let n = o["name"] as? String {
                        self?.actors[i] = n; got += 1
                    }
                }
                dbg("[actors] \(p) 解析 \(got) 条")
            }.resume()
        }
    }

    func actorName(_ id: String?) -> String {
        guard let id else { return "" }
        return actors[id] ?? ""
    }

    func inDND() -> Bool {
        guard cfg.dndEnabled else { return false }
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        let cur = df.string(from: Date())
        let a = cfg.dndStart, b = cfg.dndEnd
        guard a.count == 5, b.count == 5 else { return false }
        return a <= b ? (cur >= a && cur < b) : (cur >= a || cur < b)
    }

    var effectivePaused: Bool {
        cfg.paused || (cfg.pausedUntil ?? 0) > Date().timeIntervalSince1970
    }

    func parseDate(_ s: String?) -> Date {
        guard let s, let d = isoIn.date(from: s) else { return .distantPast }
        return d
    }

    func checkUpdate(manual: Bool) {
        guard let url = URL(string: RELEASE_API) else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // 注意:GitHub用系统代理(与Multica内网API的绕代理相反)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let data, (200...299).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                DispatchQueue.main.async {
                    dbg("[update] 检查失败(无release或网络不通)")
                    if manual { self?.updateAlert("检查失败:网络不通或还没有发布过release。\n可手动访问 GitHub releases 页面。") }
                }
                return
            }
            let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let page = (obj["html_url"] as? String) ?? "https://github.com/uniqueli/multica-watchdog/releases/latest"
            DispatchQueue.main.async {
                if isNewer(remote, than: APP_VERSION) {
                    self?.latestReleaseURL = page
                    dbg("[update] 发现新版 v\(remote)(当前 v\(APP_VERSION))")
                    if manual { self?.updateAlert("发现新版 v\(remote)!即将打开下载页。\n下载zip后: 退出🐕 → 覆盖 /Applications → 打开") ; NSWorkspace.shared.open(URL(string: page)!) }
                } else {
                    self?.latestReleaseURL = nil
                    if manual { self?.updateAlert("已是最新版本 v\(APP_VERSION) 🐕") }
                }
            }
        }.resume()
    }

    func updateAlert(_ text: String) {
        let a = NSAlert()
        a.messageText = "检查更新"
        a.informativeText = text
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: 趣味效果

    var speaker: AVSpeechSynthesizer?
    var actors: [String: String] = [:]
    var wsSlug: String = ""
    var latestReleaseURL: String? = nil   // 非nil=有新版

    func customSoundURL() -> URL? {
        let dir = home + "/.multica-watchdog"
        for ext in ["mp3", "wav", "aiff", "aif", "m4a", "caf"] {
            let p = dir + "/alert." + ext
            if fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    func playFun(_ kind: String) {
        guard cfg.soundOn else { return }
        switch cfg.soundMode {
        case "system":
            NSSound(named: "Ping")?.play()
        case "custom":
            if let u = customSoundURL() {
                if let snd = NSSound(contentsOf: u, byReference: true) {
                    if !snd.play() { dbg("[sound] play()返回false: \(u.lastPathComponent)") }
                } else {
                    dbg("[sound] 格式不支持(NSSound支持wav/aiff/mp3/m4a/caf,不支持ogg/flac): \(u.lastPathComponent)")
                    NSSound(named: "Ping")?.play()
                }
            } else {
                dbg("[sound] 自定义声音文件缺失,回落Ping")
                NSSound(named: "Ping")?.play()
            }
        default:  // voice
            guard let v = AVSpeechSynthesisVoice(language: "zh-CN") else {
                NSSound(named: "Ping")?.play(); return
            }
            if speaker == nil { speaker = AVSpeechSynthesizer() }
            speaker?.stopSpeaking(at: .immediate)
            let u = AVSpeechUtterance(string: "有消息，快查看")
            u.voice = v
            u.rate = AVSpeechUtteranceDefaultSpeechRate
            speaker?.speak(u)
        }
    }

    // MARK: 通知

    func notify(_ items: [InboxItem]) {
        unreadNew += items.count
        let silent = inDND()
        let first = items.first
        if !silent {
            if first?.type == "mentioned" { playFun("mentioned") } else { playFun("status") }
        }
        var cap = items; if cap.count > 5 { cap = Array(cap.prefix(5)) }
        let center = UNUserNotificationCenter.current()
        for it in cap {
            let who = actorName(it.actor_id)
            let content = UNMutableNotificationContent()
            switch it.type {
            case "mentioned": content.title = "【Multica】\(who.isEmpty ? "有人" : who) @你"
            default: content.title = "【Multica】\(who.isEmpty ? "任务" : who) · 状态更新"
            }
            content.body = "\(it.title ?? "(无标题)")" + (it.issue_status.map { " → \($0)" } ?? "")
            content.sound = .default
            if let iid = it.issue_id { content.userInfo = ["issue": iid] }
            let req = UNNotificationRequest(identifier: it.id, content: content, trigger: nil)
            if !silent { center.add(req) }
            else { dbg("[dnd] 静默记录: \(it.title ?? "")") }
            center.getNotificationSettings { st in
                if !silent, st.authorizationStatus != .authorized {
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    p.arguments = ["-e", "display notification \(String(describing: content.body).replacingOccurrences(of: "\"", with: "'")) with title \(String(describing: content.title).replacingOccurrences(of: "\"", with: "'")) sound name \"Glass\""]
                    try? p.run()
                }
            }
            cfg.recent.insert(RecentItem(id: it.id, title: content.title.replacingOccurrences(of: "【Multica】", with: "") + " " + content.body, issueID: it.issue_id ?? "", at: it.created_at ?? ""), at: 0)
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
        unreadNew = 0
        refreshIcon()
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
        // 官方深链: multica://open/issue?url=<编码后的网页issue地址> (源码 issue-deep-link.ts)
        if localAppExists(), !wsSlug.isEmpty, !iid.isEmpty {
            let web = "\(appWebURL)/\(wsSlug)/issues/\(iid)"
            if let enc = web.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               let deep = URL(string: "multica://open/issue?url=\(enc)") {
                if NSWorkspace.shared.open(deep) { return }
            }
        }
        // 回落: 网页
        if !wsSlug.isEmpty, !iid.isEmpty {
            NSWorkspace.shared.open(URL(string: "\(appWebURL)/\(wsSlug)/issues/\(iid)")!)
        } else {
            NSWorkspace.shared.open(URL(string: appWebURL)!)
        }
    }

    // MARK: 菜单

    func refreshIcon() {
        let base = cfg.petEmoji
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
        menu.addItem(disabled(stateStr + " · v" + APP_VERSION))
        if latestReleaseURL != nil {
            let up = NSMenuItem(title: "⬆️ 有新版本,点击下载", action: #selector(openUpdate), keyEquivalent: "")
            up.target = self; menu.addItem(up)
        }
        if effectivePaused {
            let until: String
            if let u = cfg.pausedUntil, u > Date().timeIntervalSince1970 {
                let df = DateFormatter(); df.dateFormat = "HH:mm"
                until = "至 " + df.string(from: Date(timeIntervalSince1970: u))
            } else { until = "手动恢复前" }
            menu.addItem(disabled("⏸ 已暂停(" + until + ")"))
        }
        if inDND() { menu.addItem(disabled("🌙 免打扰中 \(cfg.dndStart)–\(cfg.dndEnd)")) }
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

        let dndItem = NSMenuItem(title: "🌙 免打扰", action: nil, keyEquivalent: "")
        let dsub = NSMenu()
        let dndOff = NSMenuItem(title: (!cfg.dndEnabled ? "✓ " : "   ") + "关闭", action: #selector(setDND(_:)), keyEquivalent: "")
        dndOff.target = self; dndOff.representedObject = "off"
        dsub.addItem(dndOff)
        for range in ["22:00-08:00", "23:00-07:00"] {
            let on = cfg.dndEnabled && cfg.dndStart + "-" + cfg.dndEnd == range
            let mi = NSMenuItem(title: (on ? "✓ " : "   ") + range.replacingOccurrences(of: "-", with: " – "),
                                action: #selector(setDND(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = range
            dsub.addItem(mi)
        }
        let dndC = NSMenuItem(title: "✏️ 自定义时段...", action: #selector(askDND), keyEquivalent: "")
        dndC.target = self; dsub.addItem(dndC)
        dndItem.submenu = dsub
        menu.addItem(dndItem)


        let petItem = NSMenuItem(title: "🎨 宠物形象", action: nil, keyEquivalent: "")
        let psub = NSMenu()
        for e in ["🐕", "🐈", "🐇", "🐼", "🦊", "🐸"] {
            let mi = NSMenuItem(title: (cfg.petEmoji == e ? "✓ " : "   ") + e,
                                action: #selector(setPet(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = e
            psub.addItem(mi)
        }
        let customPet = NSMenuItem(title: "✏️ 自定义emoji...", action: #selector(askPet), keyEquivalent: "")
        customPet.target = self
        psub.addItem(customPet)
        petItem.submenu = psub
        menu.addItem(petItem)

        let sndItem = NSMenuItem(title: "🔊 提醒声音", action: nil, keyEquivalent: "")
        let ssub = NSMenu()
        for (mode, label) in [("voice", "语音播报·有消息快查看"), ("system", "系统提示音"), ("custom", "自定义声音文件..."), ("off", "静音")] {
            let mi = NSMenuItem(title: (cfg.soundMode == mode ? "✓ " : "   ") + label,
                                action: #selector(setSound(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = mode
            ssub.addItem(mi)
        }
        sndItem.submenu = ssub
        menu.addItem(sndItem)
        menu.addItem(.separator())

        if effectivePaused {
            let resume = NSMenuItem(title: "▶ 立即恢复", action: #selector(resumePause), keyEquivalent: "p")
            resume.target = self; menu.addItem(resume)
        } else {
            let pauseItem = NSMenuItem(title: "⏸ 暂停通知", action: nil, keyEquivalent: "")
            let psub = NSMenu()
            for (key, label) in [("3600", "暂停 1 小时"), ("morning", "暂停到明早 8 点"), ("manual", "直到手动恢复")] {
                let mi = NSMenuItem(title: "   " + label, action: #selector(pauseFor(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = key
                psub.addItem(mi)
            }
            pauseItem.submenu = psub
            menu.addItem(pauseItem)
        }

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
        let chk = NSMenuItem(title: "🔄 检查更新", action: #selector(checkNow), keyEquivalent: "")
        chk.target = self; menu.addItem(chk)
        let restart = NSMenuItem(title: "🔄 重启(更新后生效)", action: #selector(restartApp), keyEquivalent: "r")
        restart.target = self; menu.addItem(restart)
        let perm = NSMenuItem(title: "🔔 开启系统通知权限", action: #selector(openNotifSettings), keyEquivalent: "")
        perm.target = self; menu.addItem(perm)
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
    @objc func setPet(_ sender: NSMenuItem) {
        cfg.petEmoji = sender.representedObject as! String
        saveState(); refreshIcon()
    }
    @objc func askPet() {
        let alert = NSAlert()
        alert.messageText = "自定义宠物形象"
        alert.informativeText = "输入任意 emoji(建议单个)"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        input.stringValue = cfg.petEmoji
        alert.accessoryView = input
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty {
            cfg.petEmoji = String(input.stringValue.prefix(2))
            saveState(); refreshIcon()
        }
    }
    @objc func setSound(_ sender: NSMenuItem) {
        let mode = sender.representedObject as! String
        if mode == "custom" {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff]
            panel.allowsOtherFileTypes = false
            panel.canChooseDirectories = false
            panel.message = "选择提醒声音文件(将复制到 ~/.multica-watchdog/alert.*)"
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url {
                let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
                let dir = home + "/.multica-watchdog"
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)  // 关键:目录必须先建
                let dst = dir + "/alert." + ext
                for e in ["mp3", "wav", "aiff", "aif", "m4a", "caf", ext] {
                    try? fm.removeItem(atPath: dir + "/alert." + e)
                }
                do {
                    try fm.copyItem(at: url, to: URL(fileURLWithPath: dst))
                    dbg("[sound] 自定义声音已保存: \(dst)")
                } catch {
                    dbg("[sound] 拷贝失败: \(error)")
                }
                if fm.fileExists(atPath: dst) {
                    cfg.soundMode = "custom"; saveState()
                    playFun("demo")
                }
            }
        } else {
            cfg.soundMode = mode; saveState()
            if mode != "off" { playFun("demo") }
        }
    }
    @objc func toggleFilter(_ sender: NSMenuItem) {
        if sender.representedObject as? String == "mention" { cfg.notifyMention.toggle() }
        else { cfg.notifyStatus.toggle() }
        saveState()
    }
    @objc func resumePause() {
        cfg.paused = false; cfg.pausedUntil = nil
        saveState(); refreshIcon(); poll()
    }
    @objc func pauseFor(_ sender: NSMenuItem) {
        let key = sender.representedObject as! String
        if key == "manual" {
            cfg.paused = true; cfg.pausedUntil = nil
        } else if key == "morning" {
            var c = Calendar.current; c.timeZone = .current
            let now = Date()
            var t = c.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? now
            if t <= now { t = c.date(byAdding: .day, value: 1, to: t) ?? t }
            cfg.paused = false; cfg.pausedUntil = t.timeIntervalSince1970
        } else if let sec = Double(key) {
            cfg.paused = false; cfg.pausedUntil = Date().addingTimeInterval(sec).timeIntervalSince1970
        }
        saveState(); refreshIcon()
    }
    @objc func setDND(_ sender: NSMenuItem) {
        let v = sender.representedObject as! String
        if v == "off" { cfg.dndEnabled = false }
        else {
            let parts = v.split(separator: "-").map(String.init)
            if parts.count == 2, parts[0].count == 5, parts[1].count == 5 {
                cfg.dndStart = parts[0]; cfg.dndEnd = parts[1]; cfg.dndEnabled = true
            }
        }
        saveState()
    }
    @objc func askDND() {
        let alert = NSAlert()
        alert.messageText = "自定义免打扰时段"
        alert.informativeText = "格式 HH:MM-HH:MM(如 22:30-07:30,可跨午夜)"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        input.stringValue = cfg.dndStart + "-" + cfg.dndEnd
        alert.accessoryView = input
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let parts = input.stringValue.split(separator: "-").map(String.init)
            if parts.count == 2, parts[0].count == 5, parts[1].count == 5 {
                cfg.dndStart = parts[0]; cfg.dndEnd = parts[1]; cfg.dndEnabled = true
                saveState()
            }
        }
    }
    @objc func checkNow() { checkUpdate(manual: true) }
    @objc func openUpdate() {
        if let u = latestReleaseURL { NSWorkspace.shared.open(URL(string: u)!) }
    }
    @objc func restartApp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open '" + Bundle.main.bundleURL.path + "'"]
        try? p.run()
        NSApp.terminate(nil)
    }
    @objc func openNotifSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
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
              <key>Label</key><string>com.uniqueli.multica-watchdog</string>
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
    func menuNeedsUpdate(_ menu: NSMenu) {
        if unreadNew != 0 { unreadNew = 0; refreshIcon() }
        rebuildMenu()
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
