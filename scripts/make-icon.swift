// Genera Resources/AppIcon-1024.png: tesela redondeada oscura con el anillo
// de uso en naranja Claude. Uso: swift scripts/make-icon.swift <salida.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon-1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Tesela con esquinas continuas (rejilla de iconos de macOS: 824 pt centrados).
let inset: CGFloat = 100
let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// Fondo: degradado vertical gris muy oscuro.
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.070, green: 0.070, blue: 0.082, alpha: 1),
    NSColor(calibratedRed: 0.125, green: 0.125, blue: 0.145, alpha: 1)
])!
gradient.draw(in: tilePath, angle: 90)

// Borde superior sutil (luz).
tilePath.lineWidth = 3
NSColor(white: 1, alpha: 0.07).setStroke()
tilePath.stroke()

let center = NSPoint(x: size / 2, y: size / 2)
let radius: CGFloat = 232
let lineWidth: CGFloat = 58

// Pista del anillo.
let track = NSBezierPath()
track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
track.lineWidth = lineWidth
track.lineCapStyle = .round
NSColor(white: 1, alpha: 0.13).setStroke()
track.stroke()

// Arco de uso (≈72 %) en naranja Claude, desde arriba en sentido horario.
let arc = NSBezierPath()
arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 260, clockwise: true)
arc.lineWidth = lineWidth
arc.lineCapStyle = .round
NSColor(calibratedRed: 0.851, green: 0.467, blue: 0.341, alpha: 1).setStroke() // #D97757
arc.stroke()

// Punto central pequeño, como el icono de la barra de menús.
let dotRadius: CGFloat = 40
let dot = NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                      width: dotRadius * 2, height: dotRadius * 2))
NSColor(white: 1, alpha: 0.92).setFill()
dot.fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Icono escrito en \(out)")
