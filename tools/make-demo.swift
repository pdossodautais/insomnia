// Renders docs/demo.gif, the README illustration. Usage: swift tools/make-demo.swift docs/demo.gif
import AppKit
import ImageIO
import UniformTypeIdentifiers

let W: CGFloat = 720, H: CGFloat = 400, scale: CGFloat = 1.5
let bg = NSColor(red: 0.11, green: 0.12, blue: 0.17, alpha: 1)
let barColor = NSColor(white: 0.16, alpha: 1)
let fg = NSColor.white
let dim = NSColor(white: 0.55, alpha: 1)

func symbol(_ name: String, _ size: CGFloat, _ color: NSColor, weight: NSFont.Weight = .regular) -> NSImage {
    let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: size, weight: weight))!
    return NSImage(size: s.size, flipped: false) { r in s.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true }
}

func text(_ s: String, _ size: CGFloat, _ color: NSColor, weight: NSFont.Weight = .regular) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}

extension NSImage {
    func drawUpright(at point: NSPoint) {
        draw(in: NSRect(origin: point, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

struct Scene {
    var awake: Bool
    var menu: Bool = false
    var highlight: Int? = nil
    var lid: CGFloat? = nil      // 0 = open, 1 = closed
    var caption: String
}

let menuItems: [(String, String, Bool)] = [   // title, right side, enabled
    ("Awake until you turn it off", "", false), ("-", "", false),
    ("Allow Sleep", "⌃⌥⌘I", true), ("Stay Awake For", "›", true), ("Stay Awake While App Runs", "›", true),
    ("Black Screen (No Lock)", "", true), ("-", "", false),
    ("Allow Sleep Below", "›", true), ("Lock When Lid Opens", "", true), ("✓  Open at Login", "", true), ("-", "", false),
    ("Quit Insomnia", "⌘Q", true),
]

func draw(_ scene: Scene) -> CGImage {
    let image = NSImage(size: NSSize(width: W, height: H), flipped: true) { _ in
        bg.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()

        // Menu bar
        barColor.setFill(); NSRect(x: 0, y: 0, width: W, height: 28).fill()
        text("Sat 31 Oct  09:41", 13, fg, weight: .medium).draw(at: NSPoint(x: W - 132, y: 6))
        var x = W - 160
        for name in ["switch.2", "wifi", "battery.75percent"] {
            let img = symbol(name, 13, fg); x -= img.size.width + 14
            img.drawUpright(at: NSPoint(x: x, y: 14 - img.size.height / 2))
        }
        let icon = symbol(scene.awake ? "infinity.circle.fill" : "infinity.circle", 15, fg)
        let iconX = x - icon.size.width - 18
        if scene.menu {
            NSColor(white: 1, alpha: 0.18).setFill()
            NSBezierPath(roundedRect: NSRect(x: iconX - 6, y: 3, width: icon.size.width + 12, height: 22), xRadius: 5, yRadius: 5).fill()
        }
        icon.drawUpright(at: NSPoint(x: iconX, y: 14 - icon.size.height / 2))
        text("Insomnia", 13, fg, weight: .bold).draw(at: NSPoint(x: 38, y: 6))
        symbol("applelogo", 14, fg).drawUpright(at: NSPoint(x: 14, y: 6))

        // Menu
        if scene.menu {
            let menuW: CGFloat = 270, rowH: CGFloat = 23
            let rows = menuItems.reduce(CGFloat(0)) { $0 + ($1.0 == "-" ? 9 : rowH) }
            let frame = NSRect(x: iconX - 8, y: 32, width: menuW, height: rows + 10)
            NSColor(white: 0.21, alpha: 0.98).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9).fill()
            NSColor(white: 1, alpha: 0.12).setStroke()
            NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9).stroke()
            var y = frame.minY + 5
            for (i, item) in menuItems.enumerated() {
                if item.0 == "-" {
                    NSColor(white: 1, alpha: 0.12).setFill(); NSRect(x: frame.minX + 10, y: y + 4, width: menuW - 20, height: 1).fill()
                    y += 9; continue
                }
                if scene.highlight == i {
                    NSColor.controlAccentColor.setFill()
                    NSBezierPath(roundedRect: NSRect(x: frame.minX + 5, y: y, width: menuW - 10, height: rowH), xRadius: 5, yRadius: 5).fill()
                }
                let color = item.2 ? fg : dim
                text(item.0, 13, color).draw(at: NSPoint(x: frame.minX + 14, y: y + 3))
                let right = text(item.1, 13, dim)
                right.draw(at: NSPoint(x: frame.maxX - 14 - right.size().width, y: y + 3))
                y += rowH
            }
        }

        // Laptop with lid
        if let lid = scene.lid {
            let base = NSRect(x: 150, y: 300, width: 220, height: 10)
            NSColor(white: 0.75, alpha: 1).setFill(); NSBezierPath(roundedRect: base, xRadius: 4, yRadius: 4).fill()
            let screenH: CGFloat = 140 * (1 - lid) + 4
            let screen = NSRect(x: 168, y: 300 - screenH, width: 184, height: screenH)
            NSColor(white: 0.75, alpha: 1).setFill(); NSBezierPath(roundedRect: screen, xRadius: 6, yRadius: 6).fill()
            if lid < 0.95 {
                (lid > 0 ? NSColor.black : NSColor(red: 0.20, green: 0.16, blue: 0.48, alpha: 1)).setFill()
                NSRect(x: screen.minX + 6, y: screen.minY + 6, width: screen.width - 12, height: max(screen.height - 10, 0)).fill()
            }
            let status = scene.awake ? "Still running · no sleep · no lock" : ""
            text(status, 14, NSColor(red: 0.55, green: 0.85, blue: 0.6, alpha: 1), weight: .medium).draw(at: NSPoint(x: 400, y: 260))
            if scene.awake {
                symbol("infinity", 30, NSColor(red: 0.55, green: 0.85, blue: 0.6, alpha: 1), weight: .semibold).drawUpright(at: NSPoint(x: 400, y: 215))
            }
        }

        // Caption
        let caption = text(scene.caption, 17, fg, weight: .semibold)
        caption.draw(at: NSPoint(x: (W - caption.size().width) / 2, y: H - 46))
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

var frames: [(Scene, Double)] = [
    (Scene(awake: false, caption: "∞ outline: your Mac sleeps as usual"), 1.8),
    (Scene(awake: true, caption: "Right-click or ⌃⌥⌘I: stay awake"), 1.8),
    (Scene(awake: true, menu: true, caption: "Click: the menu"), 1.2),
    (Scene(awake: true, menu: true, highlight: 3, caption: "Stay awake for a while…"), 1.0),
    (Scene(awake: true, menu: true, highlight: 4, caption: "…or while an app runs"), 1.0),
    (Scene(awake: true, menu: true, highlight: 5, caption: "Black screen without locking"), 1.2),
]
for step in 0...10 {
    let lid = CGFloat(step) / 10
    frames.append((Scene(awake: true, lid: lid, caption: "Close the lid: the Mac keeps working"), step == 0 ? 0.8 : 0.06))
}
frames.append((Scene(awake: true, lid: 1, caption: "Close the lid: the Mac keeps working"), 2.2))

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (scene, delay) in frames {
    CGImageDestinationAddImage(destination, draw(scene), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
}
CGImageDestinationFinalize(destination)
