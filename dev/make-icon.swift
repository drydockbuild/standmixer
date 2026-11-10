import AppKit

guard (2...3).contains(CommandLine.arguments.count),
      CommandLine.arguments.count == 2 || ["light", "dark"].contains(CommandLine.arguments[2]) else {
    fputs("Usage: make-icon.swift ICONSET_DIRECTORY [light|dark]\n", stderr)
    exit(2)
}

let isDark = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "dark"
let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

// StandMixer master geometry matches brand/standmixer-icon.svg and StandMixerBrandMark.
let size = 1024
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32),
    let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create icon rendering context\n", stderr); exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high; context.shouldAntialias = true
let flip = NSAffineTransform(); flip.translateX(by: 0, yBy: CGFloat(size)); flip.scaleX(by: 1, yBy: -1); flip.concat()
let tile = NSBezierPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
color(isDark ? 0x0B1220 : 0xF8FAFB).setFill(); tile.fill()
color(isDark ? 0x6FB3B8 : 0x0B1220, alpha: isDark ? 0.18 : 0.07).setStroke(); tile.lineWidth = 2; tile.stroke()
let transform = NSAffineTransform(); transform.translateX(by: 128, yBy: 188); transform.scaleX(by: 12, yBy: 12); transform.concat()
let p = NSBezierPath()
p.move(to: NSPoint(x: 14, y: 46)); p.line(to: NSPoint(x: 14, y: 23)); p.line(to: NSPoint(x: 10, y: 23)); p.line(to: NSPoint(x: 10, y: 19))
p.curve(to: NSPoint(x: 20, y: 9), controlPoint1: NSPoint(x: 10, y: 13.5), controlPoint2: NSPoint(x: 14.5, y: 9))
p.line(to: NSPoint(x: 42, y: 9)); p.curve(to: NSPoint(x: 52, y: 19), controlPoint1: NSPoint(x: 47.5, y: 9), controlPoint2: NSPoint(x: 52, y: 13.5))
p.line(to: NSPoint(x: 52, y: 23)); p.line(to: NSPoint(x: 23, y: 23)); p.line(to: NSPoint(x: 23, y: 46))
p.move(to: NSPoint(x: 28, y: 29)); p.line(to: NSPoint(x: 51, y: 29)); p.curve(to: NSPoint(x: 39.5, y: 42), controlPoint1: NSPoint(x: 50.2, y: 37.5), controlPoint2: NSPoint(x: 46.4, y: 42))
p.curve(to: NSPoint(x: 28, y: 29), controlPoint1: NSPoint(x: 32.6, y: 42), controlPoint2: NSPoint(x: 29, y: 37.5)); p.close()
p.move(to: NSPoint(x: 39.5, y: 23)); p.line(to: NSPoint(x: 39.5, y: 33))
p.lineWidth = 3.5; p.lineCapStyle = .round; p.lineJoinStyle = .round; color(isDark ? 0x6FB3B8 : 0x0E9488).setStroke(); p.stroke()
color(isDark ? 0x6FB3B8 : 0x0E9488).setFill(); NSBezierPath(ovalIn: CGRect(x: 16.2, y: 15.2, width: 3.6, height: 3.6)).fill()
let underline = NSBezierPath(); underline.move(to: NSPoint(x: 10, y: 46)); underline.line(to: NSPoint(x: 53, y: 46))
underline.lineWidth = 3.5; underline.lineCapStyle = .round; color(0xF59E0B).setStroke(); underline.stroke()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode app icon\n", stderr)
    exit(1)
}
let masterURL = iconsetURL.appendingPathComponent("master.png")
try png.write(to: masterURL)
for base in [16, 32, 128, 256, 512] {
    for (suffix, pixels) in [("", base), ("@2x", base * 2)] {
        let output = iconsetURL.appendingPathComponent("icon_\(base)x\(base)\(suffix).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = ["-z", "\(pixels)", "\(pixels)", masterURL.path, "--out", output.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            fputs("Could not create \(pixels)px icon\n", stderr)
            exit(1)
        }
    }
}
try FileManager.default.removeItem(at: masterURL)
