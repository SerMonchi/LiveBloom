// Crops the logo (without the black border) and places it on the macOS icon grid (824 px area in 1024 px, transparent margins).
// Usage: swift make_icon_from_logo.swift <source> <output.png>
import AppKit
let src = NSImage(contentsOfFile: CommandLine.arguments[1])!
let srcRep = NSBitmapImageRep(data: src.tiffRepresentation!)!
// Measured edges of the rounded square in the original (1254 px), inset slightly.
let crop = NSRect(x: 106, y: 106, width: 1042, height: 1042)

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let target = NSRect(x: 100, y: 100, width: 824, height: 824)
NSBezierPath(roundedRect: target, xRadius: 185, yRadius: 185).addClip()
// NSImage coordinates: origin at the bottom left → flip y.
let fromRect = NSRect(x: crop.minX, y: CGFloat(srcRep.pixelsHigh) - crop.maxY, width: crop.width, height: crop.height)
let srcImage = NSImage(size: NSSize(width: srcRep.pixelsWide, height: srcRep.pixelsHigh))
srcImage.addRepresentation(srcRep)
srcImage.draw(in: target, from: fromRect, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
