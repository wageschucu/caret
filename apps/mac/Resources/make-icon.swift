// Generates Caret.icns: a rounded tile with a text caret and an accent arrow chip.
// Run: swift apps/mac/Resources/make-icon.swift  (from the repository root)
import AppKit

func draw(size: CGFloat) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  let s = size
  let inset = s * 0.06
  let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset), xRadius: s * 0.22, yRadius: s * 0.22)
  let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.30, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.62, alpha: 1),
  ])!
  gradient.draw(in: tile, angle: -60)

  // Text caret: a tall rounded bar, slightly left of centre.
  let barW = s * 0.085
  let barH = s * 0.52
  let barX = s * 0.40
  let barY = s * 0.24
  NSColor.white.setFill()
  NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: barW, height: barH), xRadius: barW / 2, yRadius: barW / 2).fill()
  // Serifs, like an I-beam cursor.
  let serifW = s * 0.22
  let serifH = s * 0.055
  for y in [barY - serifH * 0.2, barY + barH - serifH * 0.8] {
    NSBezierPath(roundedRect: NSRect(x: barX + barW / 2 - serifW / 2, y: y, width: serifW, height: serifH), xRadius: serifH / 2, yRadius: serifH / 2).fill()
  }

  // Accent chip with an arrow, to the upper right of the caret.
  let chipW = s * 0.30
  let chipH = s * 0.19
  let chipX = s * 0.52
  let chipY = s * 0.58
  let chip = NSBezierPath(roundedRect: NSRect(x: chipX, y: chipY, width: chipW, height: chipH), xRadius: chipH / 2, yRadius: chipH / 2)
  NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.18, alpha: 1).setFill()
  chip.fill()
  let arrow = NSBezierPath()
  arrow.lineWidth = s * 0.028
  arrow.lineCapStyle = .round
  arrow.lineJoinStyle = .round
  let ax = chipX + chipW * 0.32, ay = chipY + chipH * 0.30
  let bx = chipX + chipW * 0.68, by = chipY + chipH * 0.70
  arrow.move(to: NSPoint(x: ax, y: ay))
  arrow.line(to: NSPoint(x: bx, y: by))
  arrow.move(to: NSPoint(x: bx - chipW * 0.20, y: by))
  arrow.line(to: NSPoint(x: bx, y: by))
  arrow.line(to: NSPoint(x: bx, y: by - chipH * 0.42))
  NSColor.white.setStroke()
  arrow.stroke()
  image.unlockFocus()
  return image
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "apps/mac/Resources/Caret.iconset")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
  let image = draw(size: CGFloat(px))
  guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
  rep.size = NSSize(width: px, height: px)
  let png = rep.representation(using: .png, properties: [:])!
  try! png.write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("wrote \(out.path)")
