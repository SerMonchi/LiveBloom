import AppKit

/// Menu bar icon: a simple cherry blossom with one falling petal – matching the app logo.
/// Drawn as a template image so macOS tints it correctly in light and dark mode.
enum MenuBarIcon {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setFill()

            // Blossom: five petals with a fine notch, slightly rotated like in the logo.
            let center = CGPoint(x: 8.5, y: 9.5)
            for i in 0..<5 {
                petal(base: center, length: 7.6, width: 5.2, angle: CGFloat(i) * 72 + 12).fill()
            }
            // Punch out the center so the blossom is still recognizable at small sizes.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            // A single petal drifting away to the side.
            petal(base: CGPoint(x: 15.2, y: 2.2), length: 4.6, width: 3.4, angle: -62).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "LiveBloom"
        return img
    }()

    /// Petal from its base (`base`) outwards, tip with a small notch.
    private static func petal(base: CGPoint, length: CGFloat, width: CGFloat, angle: CGFloat) -> NSBezierPath {
        let w = width / 2
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: 0))
        p.curve(to: NSPoint(x: -w, y: length * 0.62), controlPoint1: NSPoint(x: -w * 0.55, y: length * 0.12),
                controlPoint2: NSPoint(x: -w * 1.05, y: length * 0.38))
        p.curve(to: NSPoint(x: -w * 0.28, y: length), controlPoint1: NSPoint(x: -w * 0.95, y: length * 0.86),
                controlPoint2: NSPoint(x: -w * 0.6, y: length))
        p.line(to: NSPoint(x: 0, y: length * 0.86))
        p.line(to: NSPoint(x: w * 0.28, y: length))
        p.curve(to: NSPoint(x: w, y: length * 0.62), controlPoint1: NSPoint(x: w * 0.6, y: length),
                controlPoint2: NSPoint(x: w * 0.95, y: length * 0.86))
        p.curve(to: NSPoint(x: 0, y: 0), controlPoint1: NSPoint(x: w * 1.05, y: length * 0.38),
                controlPoint2: NSPoint(x: w * 0.55, y: length * 0.12))
        p.close()
        var t = AffineTransform()
        t.translate(x: base.x, y: base.y)
        t.rotate(byDegrees: angle)
        p.transform(using: t)
        return p
    }
}
