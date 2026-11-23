// Draws the LiveBloom app icon (1024×1024 PNG): falling sakura petals, simple and light pink.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Background: rounded square on the macOS icon grid with a soft pink gradient.
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(red: 1.00, green: 0.97, blue: 0.98, alpha: 1),
    NSColor(red: 0.99, green: 0.88, blue: 0.92, alpha: 1),
])!.draw(in: shape, angle: -90)
shape.addClip()

/// A sakura petal: drop-shaped with the typical notch at the tip.
func petal(at center: CGPoint, length: CGFloat, angle: CGFloat, alpha: CGFloat) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 0, y: -0.5))
    p.curve(to: NSPoint(x: -0.40, y: 0.14), controlPoint1: NSPoint(x: -0.26, y: -0.40), controlPoint2: NSPoint(x: -0.46, y: -0.12))
    p.curve(to: NSPoint(x: -0.11, y: 0.50), controlPoint1: NSPoint(x: -0.36, y: 0.38), controlPoint2: NSPoint(x: -0.23, y: 0.49))
    p.line(to: NSPoint(x: 0, y: 0.39))
    p.line(to: NSPoint(x: 0.11, y: 0.50))
    p.curve(to: NSPoint(x: 0.40, y: 0.14), controlPoint1: NSPoint(x: 0.23, y: 0.49), controlPoint2: NSPoint(x: 0.36, y: 0.38))
    p.curve(to: NSPoint(x: 0, y: -0.5), controlPoint1: NSPoint(x: 0.46, y: -0.12), controlPoint2: NSPoint(x: 0.26, y: -0.40))
    p.close()

    var t = AffineTransform()
    t.translate(x: center.x, y: center.y)
    t.rotate(byDegrees: angle)
    t.scale(length)
    p.transform(using: t)

    // Soft shadow for a bit of depth.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
                  color: NSColor(red: 0.85, green: 0.45, blue: 0.58, alpha: 0.28 * alpha).cgColor)
    NSColor(red: 0.96, green: 0.66, blue: 0.75, alpha: alpha).setFill()
    p.fill()
    ctx.restoreGState()

    // Gradient from light (tip) to stronger (base).
    NSGradient(colors: [
        NSColor(red: 0.99, green: 0.80, blue: 0.86, alpha: alpha),
        NSColor(red: 0.95, green: 0.60, blue: 0.71, alpha: alpha),
    ])!.draw(in: p, angle: angle - 90)
}

/// Fine trail behind a petal – shows that the wind carries it sideways.
func trail(from start: CGPoint, to end: CGPoint, bend: CGFloat, width: CGFloat, alpha: CGFloat) {
    let p = NSBezierPath()
    p.move(to: start)
    let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + bend)
    p.curve(to: end, controlPoint1: mid, controlPoint2: mid)
    p.lineWidth = width
    p.lineCapStyle = .round
    NSColor(red: 0.95, green: 0.66, blue: 0.76, alpha: alpha).setStroke()
    p.stroke()
}

// Petals drift sideways from left to right and sink in a gentle wave.
// Two short, curved wind strokes behind each of the larger petals.
trail(from: CGPoint(x: 170, y: 640), to: CGPoint(x: 420, y: 615), bend: 38, width: 9, alpha: 0.28)
trail(from: CGPoint(x: 230, y: 575), to: CGPoint(x: 405, y: 560), bend: 26, width: 6, alpha: 0.20)
trail(from: CGPoint(x: 260, y: 300), to: CGPoint(x: 470, y: 270), bend: -30, width: 8, alpha: 0.24)
trail(from: CGPoint(x: 300, y: 240), to: CGPoint(x: 455, y: 222), bend: -20, width: 5, alpha: 0.17)
trail(from: CGPoint(x: 560, y: 810), to: CGPoint(x: 700, y: 800), bend: 18, width: 6, alpha: 0.20)

petal(at: CGPoint(x: 640, y: 590), length: 290, angle: -100, alpha: 1.0)
petal(at: CGPoint(x: 650, y: 300), length: 190, angle: -70, alpha: 0.95)
petal(at: CGPoint(x: 835, y: 775), length: 130, angle: -115, alpha: 0.85)
petal(at: CGPoint(x: 330, y: 470), length: 120, angle: -60, alpha: 0.8)
petal(at: CGPoint(x: 300, y: 790), length: 85, angle: -125, alpha: 0.7)

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
