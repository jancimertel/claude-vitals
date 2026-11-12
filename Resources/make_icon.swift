// Draws the app icon (usage ring + ">_" prompt) and writes a 1024px PNG to the path given as the
// first argument. make_icon.sh turns it into Resources/AppIcon.icns; only rerun it after changing
// this drawing.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Body on Apple's macOS icon grid: 824pt rounded square centred in the 1024 canvas.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
rgb(0x111623).setFill()
shape.fill()
ctx.restoreGState()
NSGradient(starting: rgb(0x252C3D), ending: rgb(0x111623))!.draw(in: shape, angle: -90)

// Usage ring: muted track, then a 69% arc running teal to violet.
let center = CGPoint(x: size / 2, y: size / 2)
let radius: CGFloat = 270
let lineWidth: CGFloat = 64
let track = NSBezierPath()
track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
track.lineWidth = lineWidth
rgb(0x2C3446).setStroke()
track.stroke()

let start: CGFloat = 90                 // 12 o'clock, drawing clockwise
let end: CGFloat = start - 360 * 0.69
// CoreGraphics has no public conic gradient, so the arc is short round-capped segments, each tinted
// at its position along the arc.
let stops = [rgb(0x2DD4BF), rgb(0x38BDF8), rgb(0x818CF8), rgb(0xC084FC)]
func color(at t: CGFloat) -> NSColor {
    let x = t * CGFloat(stops.count - 1)
    let i = min(Int(x), stops.count - 2)
    return stops[i].blended(withFraction: x - CGFloat(i), of: stops[i + 1])!
}
let segments = 180
for k in (0..<segments).reversed() {     // later segments underneath, so the teal head sits on top
    let t0 = CGFloat(k) / CGFloat(segments), t1 = CGFloat(k + 1) / CGFloat(segments)
    let seg = NSBezierPath()
    seg.appendArc(withCenter: center, radius: radius, startAngle: start + (end - start) * t0,
                  endAngle: start + (end - start) * t1, clockwise: true)
    seg.lineWidth = lineWidth
    seg.lineCapStyle = .round
    color(at: (t0 + t1) / 2).setStroke()
    seg.stroke()
}

// Terminal prompt ">_" in the middle: the app watches Claude Code sessions. Drawn at full size
// around (515, 500), the glyph's own center, then scaled down and centered in the ring.
let promptScale: CGFloat = 0.72
ctx.saveGState()
ctx.translateBy(x: center.x, y: center.y)
ctx.scaleBy(x: promptScale, y: promptScale)
ctx.translateBy(x: -515, y: -500)
let chevron = NSBezierPath()
chevron.move(to: CGPoint(x: 360, y: 600))
chevron.line(to: CGPoint(x: 470, y: 512))
chevron.line(to: CGPoint(x: 360, y: 424))
chevron.lineWidth = 46
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
rgb(0xF2F4F8).setStroke()
chevron.stroke()
let cursor = NSBezierPath(roundedRect: NSRect(x: 510, y: 400, width: 160, height: 46), xRadius: 23, yRadius: 23)
rgb(0xF2F4F8).setFill()
cursor.fill()
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
