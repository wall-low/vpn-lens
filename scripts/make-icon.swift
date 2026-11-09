// Рисует иконку VPN Lens и собирает из неё AppIcon.icns.
//   swift scripts/make-icon.swift macos/Resources/AppIcon.icns
//
// Иконка рисуется кодом, а не берётся из SF Symbols: лицензия Apple не разрешает
// использовать символы в иконках приложений.

import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func render(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let s = rect.width
        // Подложка по сетке иконок macOS: поле 10% и скругление около 22%.
        let inset = s * 0.1
        let tile = rect.insetBy(dx: inset, dy: inset)
        let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = s * 0.025
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.set()
        NSGradient(colors: [
            NSColor(srgbRed: 0.20, green: 0.52, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.05, green: 0.24, blue: 0.62, alpha: 1),
        ])?.draw(in: shape, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()

        // Линза: кольцо, ручка и галочка внутри - "проверено".
        let center = NSPoint(x: tile.midX - tile.width * 0.06, y: tile.midY + tile.width * 0.06)
        let radius = tile.width * 0.25
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ring.lineWidth = tile.width * 0.075
        NSColor.white.setStroke()
        NSColor.white.withAlphaComponent(0.14).setFill()
        ring.fill()
        ring.stroke()

        let handle = NSBezierPath()
        let start = NSPoint(x: center.x + radius * 0.74, y: center.y - radius * 0.74)
        handle.move(to: start)
        handle.line(to: NSPoint(x: start.x + tile.width * 0.2, y: start.y - tile.width * 0.2))
        handle.lineWidth = tile.width * 0.1
        handle.lineCapStyle = .round
        handle.stroke()

        let check = NSBezierPath()
        check.move(to: NSPoint(x: center.x - radius * 0.45, y: center.y + radius * 0.02))
        check.line(to: NSPoint(x: center.x - radius * 0.1, y: center.y - radius * 0.32))
        check.line(to: NSPoint(x: center.x + radius * 0.48, y: center.y + radius * 0.36))
        check.lineWidth = tile.width * 0.065
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.stroke()
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(render(size: CGFloat(pixels)), pixels: pixels).write(to: iconset.appendingPathComponent(name))
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? output : "iconutil завершился с ошибкой")
