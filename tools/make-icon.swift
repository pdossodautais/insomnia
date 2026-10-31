// Generates Resources/AppIcon.icns: an infinity sign on a night-blue gradient.
// Usage: swift tools/make-icon.swift (from the repository root)

import AppKit

func render(_ size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let inset = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
        let shape = NSBezierPath(roundedRect: inset, xRadius: size * 0.18, yRadius: size * 0.18)
        NSGradient(starting: NSColor(red: 0.20, green: 0.16, blue: 0.48, alpha: 1),
                   ending: NSColor(red: 0.04, green: 0.05, blue: 0.16, alpha: 1))!.draw(in: shape, angle: -90)

        let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        let symbol = NSImage(systemSymbolName: "infinity", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
        symbol.draw(in: NSRect(x: rect.midX - symbol.size.width / 2, y: rect.midY - symbol.size.height / 2,
                               width: symbol.size.width, height: symbol.size.height))
        return true
    }
    let bitmap = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    return bitmap.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
