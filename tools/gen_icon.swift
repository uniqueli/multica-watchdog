// gen_icon.swift — 生成 multica-watchdog 的 App 图标 (🐕 + 渐变圆角底)
// 用法: swift tools/gen_icon.swift <输出iconset目录>

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/icon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func makePNG(_ n: Int, _ name: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    rep.size = NSSize(width: n, height: n)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: n, height: n)
    // 暖橙渐变底 + 圆角(macOS 图标比例)
    if let g = NSGradient(starting: NSColor(calibratedRed: 1.00, green: 0.80, blue: 0.42, alpha: 1),
                          ending: NSColor(calibratedRed: 0.94, green: 0.52, blue: 0.14, alpha: 1)) {
        let bp = NSBezierPath(roundedRect: rect, xRadius: CGFloat(n) * 0.225, yRadius: CGFloat(n) * 0.225)
        g.draw(in: bp, angle: -90)
    }
    // 🐕 居中
    let dog = NSAttributedString(string: "🐕", attributes: [
        .font: NSFont.systemFont(ofSize: CGFloat(n) * 0.60)
    ])
    let sz = dog.size()
    dog.draw(at: NSPoint(x: (CGFloat(n) - sz.width) / 2, y: (CGFloat(n) - sz.height) / 2 - CGFloat(n) * 0.03))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: URL(fileURLWithPath: outDir + "/" + name))
}

let spec: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (n, name) in spec { makePNG(n, name) }
print("iconset 完成: \(outDir) (\(spec.count) 张)")
