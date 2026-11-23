// Modern variants of the LiveBloom icon. Usage: swift make_icon_modern.swift <glass|night|minimal> <output.png>
import AppKit

let variant = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Sakura petal (notch at the tip), centered at 0/0, length 1, tip pointing up.
func petalPath(center: CGPoint, length: CGFloat, angle: CGFloat, width: CGFloat = 0.82) -> NSBezierPath {
    let p = NSBezierPath()
    let w = width
    p.move(to: NSPoint(x: 0, y: -0.5))
    p.curve(to: NSPoint(x: -0.42 * w, y: 0.12), controlPoint1: NSPoint(x: -0.30 * w, y: -0.40), controlPoint2: NSPoint(x: -0.48 * w, y: -0.14))
    p.curve(to: NSPoint(x: -0.07 * w, y: 0.5), controlPoint1: NSPoint(x: -0.37 * w, y: 0.40), controlPoint2: NSPoint(x: -0.20 * w, y: 0.52))
    p.curve(to: NSPoint(x: 0, y: 0.44), controlPoint1: NSPoint(x: -0.03 * w, y: 0.49), controlPoint2: NSPoint(x: -0.01 * w, y: 0.46))
    p.curve(to: NSPoint(x: 0.07 * w, y: 0.5), controlPoint1: NSPoint(x: 0.01 * w, y: 0.46), controlPoint2: NSPoint(x: 0.03 * w, y: 0.49))
    p.curve(to: NSPoint(x: 0.42 * w, y: 0.12), controlPoint1: NSPoint(x: 0.20 * w, y: 0.52), controlPoint2: NSPoint(x: 0.37 * w, y: 0.40))
    p.curve(to: NSPoint(x: 0, y: -0.5), controlPoint1: NSPoint(x: 0.48 * w, y: -0.14), controlPoint2: NSPoint(x: 0.30 * w, y: -0.40))
    p.close()
    var t = AffineTransform()
    t.translate(x: center.x, y: center.y)
    t.rotate(byDegrees: angle)
    t.scale(length)
    p.transform(using: t)
    return p
}

func softLight(center: CGPoint, radius: CGFloat, color: NSColor) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func fill(_ path: NSBezierPath, gradient colors: [NSColor], angle: CGFloat,
          shadow: NSColor? = nil, blur: CGFloat = 0, offset: CGSize = .zero) {
    if let shadow {
        ctx.saveGState()
        ctx.setShadow(offset: offset, blur: blur, color: shadow.cgColor)
        colors.last!.setFill()
        path.fill()
        ctx.restoreGState()
    }
    NSGradient(colors: colors)!.draw(in: path, angle: angle)
}

/// Motion streak: fades from transparent to color – shows the sideways drift.
func streak(from a: CGPoint, to b: CGPoint, bend: CGFloat, width: CGFloat, color: NSColor) {
    let p = NSBezierPath()
    p.move(to: a)
    let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + bend)
    p.curve(to: b, controlPoint1: m, controlPoint2: m)
    p.lineWidth = width
    p.lineCapStyle = .round
    ctx.saveGState()
    let cg = p.cgPathCopy
    ctx.addPath(cg)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [color.withAlphaComponent(0).cgColor, color.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: a, end: b, options: [])
    ctx.restoreGState()
}

extension NSBezierPath {
    var cgPathCopy: CGPath {
        let path = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo: path.move(to: pts[0])
            case .lineTo: path.addLine(to: pts[0])
            case .curveTo, .cubicCurveTo: path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .quadraticCurveTo: path.addQuadCurve(to: pts[1], control: pts[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

switch variant {
case "glass":
    // Strong pink-coral gradient, glassy petals.
    NSGradient(colors: [rgb(255, 154, 190), rgb(255, 111, 145), rgb(255, 160, 122)])!.draw(in: shape, angle: -60)
    shape.addClip()
    // Soft light at the top left.
    softLight(center: CGPoint(x: 260, y: 880), radius: 520, color: rgb(255, 255, 255, 0.45))
    streak(from: CGPoint(x: 150, y: 560), to: CGPoint(x: 420, y: 520), bend: 30, width: 14, color: rgb(255, 255, 255, 0.55))
    streak(from: CGPoint(x: 230, y: 330), to: CGPoint(x: 560, y: 300), bend: -25, width: 10, color: rgb(255, 255, 255, 0.4))
    let big = petalPath(center: CGPoint(x: 620, y: 520), length: 380, angle: -98)
    fill(big, gradient: [rgb(255, 255, 255, 0.95), rgb(255, 228, 236, 0.85)], angle: 0,
         shadow: rgb(180, 40, 80, 0.35), blur: 40, offset: CGSize(width: 0, height: -18))
    // Highlight edge
    NSGradient(colors: [rgb(255, 255, 255, 0.0), rgb(255, 255, 255, 0.7)])!.draw(in: big, angle: 120)
    fill(petalPath(center: CGPoint(x: 730, y: 270), length: 170, angle: -70),
         gradient: [rgb(255, 255, 255, 0.85), rgb(255, 220, 230, 0.7)], angle: 0,
         shadow: rgb(180, 40, 80, 0.25), blur: 24, offset: CGSize(width: 0, height: -10))
    fill(petalPath(center: CGPoint(x: 300, y: 780), length: 120, angle: -120),
         gradient: [rgb(255, 255, 255, 0.75), rgb(255, 220, 230, 0.6)], angle: 0)

case "night":
    // Dark plum-indigo gradient with glowing petals.
    NSGradient(colors: [rgb(28, 22, 58), rgb(58, 28, 82), rgb(110, 38, 98)])!.draw(in: shape, angle: -70)
    shape.addClip()
    softLight(center: CGPoint(x: 640, y: 520), radius: 430, color: rgb(255, 110, 170, 0.32))
    streak(from: CGPoint(x: 140, y: 560), to: CGPoint(x: 430, y: 520), bend: 32, width: 12, color: rgb(255, 140, 190, 0.8))
    streak(from: CGPoint(x: 220, y: 300), to: CGPoint(x: 540, y: 270), bend: -26, width: 9, color: rgb(255, 140, 190, 0.6))
    streak(from: CGPoint(x: 520, y: 820), to: CGPoint(x: 690, y: 805), bend: 14, width: 7, color: rgb(255, 140, 190, 0.5))
    let glow = rgb(255, 92, 160, 0.9)
    fill(petalPath(center: CGPoint(x: 630, y: 520), length: 360, angle: -98),
         gradient: [rgb(255, 196, 220), rgb(255, 98, 160)], angle: -30, shadow: glow, blur: 60)
    fill(petalPath(center: CGPoint(x: 720, y: 260), length: 170, angle: -68),
         gradient: [rgb(255, 196, 220), rgb(255, 110, 170)], angle: -30, shadow: glow, blur: 40)
    fill(petalPath(center: CGPoint(x: 780, y: 800), length: 110, angle: -125),
         gradient: [rgb(255, 196, 220), rgb(255, 120, 175)], angle: -30, shadow: glow, blur: 28)

default: // "minimal"
    // Bright and clear: one large, bold petal with a long, soft shadow.
    NSGradient(colors: [rgb(255, 255, 255), rgb(252, 238, 243)])!.draw(in: shape, angle: -90)
    shape.addClip()
    streak(from: CGPoint(x: 160, y: 520), to: CGPoint(x: 400, y: 495), bend: 22, width: 16, color: rgb(255, 120, 160, 0.45))
    streak(from: CGPoint(x: 230, y: 420), to: CGPoint(x: 410, y: 405), bend: 14, width: 10, color: rgb(255, 120, 160, 0.3))
    fill(petalPath(center: CGPoint(x: 600, y: 500), length: 420, angle: -100),
         gradient: [rgb(255, 150, 185), rgb(236, 64, 122)], angle: -40,
         shadow: rgb(236, 64, 122, 0.35), blur: 50, offset: CGSize(width: 18, height: -30))
    fill(petalPath(center: CGPoint(x: 790, y: 250), length: 130, angle: -70),
         gradient: [rgb(255, 170, 200), rgb(245, 100, 150)], angle: -40,
         shadow: rgb(236, 64, 122, 0.25), blur: 24, offset: CGSize(width: 8, height: -14))
}

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
