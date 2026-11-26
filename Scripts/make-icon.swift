// Draws the app icon: a list of three rows, each with a switch, on a white card.
//
//   swift Scripts/make-icon.swift Resources/AppIcon.iconset
//   iconutil -c icns Resources/AppIcon.iconset -o Resources/HostManager.icns
//
// The result is checked in, so this only has to run when the icon changes.
import AppKit

// Everything is laid out on a 1024-point canvas measured from the top-left corner.
private let canvas: CGFloat = 1024

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, radius: CGFloat) -> NSBezierPath {
    // Convert to AppKit's bottom-left origin.
    NSBezierPath(roundedRect: NSRect(x: x, y: canvas - y - height, width: width, height: height), xRadius: radius, yRadius: radius)
}

private func circle(_ centerX: CGFloat, _ centerY: CGFloat, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: centerX - radius, y: canvas - centerY - radius, width: radius * 2, height: radius * 2))
}

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

private func draw() {
    let background = rect(100, 100, 824, 824, radius: 186)
    NSGradient(starting: color(255, 107, 157), ending: color(104, 92, 231))!
        .draw(in: background, angle: -45)

    let card = rect(212, 272, 600, 480, radius: 64)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 26
    shadow.set()
    NSColor.white.setFill()
    card.fill()
    NSGraphicsContext.restoreGraphicsState()

    let rowCenters: [CGFloat] = [368, 480, 592]
    for (row, centerY) in rowCenters.enumerated() {
        color(58, 60, 84).setFill()
        circle(284, centerY, radius: 22).fill()
        color(201, 205, 218).setFill()
        rect(336, centerY - 13, 236, 26, radius: 13).fill()

        let isOn = row == 0
        let track = rect(628, centerY - 32, 116, 64, radius: 32)
        (isOn ? color(255, 84, 140) : color(228, 231, 239)).setFill()
        track.fill()
        let knobX: CGFloat = isOn ? 712 : 660
        NSGraphicsContext.saveGraphicsState()
        circle(knobX, centerY + 2, radius: 24).addClip()
        NSColor.black.withAlphaComponent(isOn ? 0.12 : 0.10).setFill()
        circle(knobX, centerY + 3, radius: 24).fill()
        NSColor.white.setFill()
        circle(knobX, centerY, radius: 24).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private func render(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / canvas)
    transform.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    bitmap.size = NSSize(width: pixels, height: pixels)
    return bitmap.representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <output.iconset>\n".utf8))
    exit(64)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
// What iconutil expects for a macOS app icon.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try render(pixels: points * scale).write(to: directory.appendingPathComponent(name))
    print("wrote \(name)")
}
