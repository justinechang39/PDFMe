import AppKit
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.89, green: 0.93, blue: 0.83, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 984, height: 984), xRadius: 225, yRadius: 225).fill()
        context.saveGState()
        context.translateBy(x: 485, y: 540)
        context.rotate(by: 0.16)
        NSColor(calibratedWhite: 1, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: -215, y: -280, width: 390, height: 535), xRadius: 53, yRadius: 53).fill()
        context.restoreGState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 32
        shadow.shadowOffset = NSSize(width: 0, height: -15)
        context.saveGState(); shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 347, y: 213, width: 400, height: 560), xRadius: 54, yRadius: 54).fill()
        context.restoreGState()
        NSColor(calibratedRed: 0.25, green: 0.39, blue: 0.28, alpha: 1).setStroke()
        let arrow = NSBezierPath()
        arrow.lineWidth = 34; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: 548, y: 644)); arrow.line(to: NSPoint(x: 548, y: 409))
        arrow.move(to: NSPoint(x: 460, y: 491)); arrow.line(to: NSPoint(x: 548, y: 402)); arrow.line(to: NSPoint(x: 636, y: 491)); arrow.stroke()
        let line = NSBezierPath(); line.lineWidth = 23; line.lineCapStyle = .round
        line.move(to: NSPoint(x: 466, y: 337)); line.line(to: NSPoint(x: 630, y: 337)); line.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output + "/icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
