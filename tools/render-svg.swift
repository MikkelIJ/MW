#!/usr/bin/env swift
// Render an SVG to a PNG of a given pixel size using AppKit (macOS 13+).
//
// Usage: render-svg.swift <input.svg> <output.png> <pixelSize> [options]
//
// Options:
//   --template
//       Force every visible pixel to opaque black, preserving the alpha
//       mask. Produces a PNG suitable for use as an NSImage template
//       (auto-tints in menu bar, etc.).
//   --padding <0..0.45>
//       Fractional padding around the SVG inside the canvas. Default 0.
//       Example: 0.18 means the glyph fills 64% of each side.
//   --bg <hex|none>
//       Fill the canvas with the given color before drawing the SVG.
//       Hex may be #RGB, #RRGGBB or #RRGGBBAA. "none" is transparent.
//   --rounded <0..0.5>
//       Treat --bg as a rounded rectangle whose corner radius is the given
//       fraction of the canvas size. Apple's icon tile is roughly 0.225.

import AppKit

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

func parseColor(_ raw: String) -> NSColor? {
    if raw.lowercased() == "none" { return nil }
    var s = raw
    if s.hasPrefix("#") { s.removeFirst() }
    func byte(_ str: Substring) -> CGFloat { CGFloat(UInt8(str, radix: 16) ?? 0) / 255.0 }
    switch s.count {
    case 3:
        let chars = Array(s)
        let r = "\(chars[0])\(chars[0])"
        let g = "\(chars[1])\(chars[1])"
        let b = "\(chars[2])\(chars[2])"
        return NSColor(deviceRed: byte(Substring(r)),
                       green: byte(Substring(g)),
                       blue:  byte(Substring(b)), alpha: 1)
    case 6:
        return NSColor(deviceRed: byte(s.prefix(2)),
                       green: byte(s.dropFirst(2).prefix(2)),
                       blue: byte(s.dropFirst(4).prefix(2)),
                       alpha: 1)
    case 8:
        return NSColor(deviceRed: byte(s.prefix(2)),
                       green: byte(s.dropFirst(2).prefix(2)),
                       blue: byte(s.dropFirst(4).prefix(2)),
                       alpha: byte(s.dropFirst(6).prefix(2)))
    default:
        return nil
    }
}

let args = CommandLine.arguments
guard args.count >= 4 else {
    die("usage: render-svg.swift <input.svg> <output.png> <pixelSize> [--template] [--padding f] [--bg #RRGGBB|none] [--rounded f]")
}
let inputPath = args[1]
let outputPath = args[2]
guard let size = Int(args[3]), size > 0 else { die("invalid size: \(args[3])") }

var template = false
var padding: CGFloat = 0
var bg: NSColor? = nil
var rounded: CGFloat = 0

var idx = 4
while idx < args.count {
    let arg = args[idx]
    switch arg {
    case "--template":
        template = true
    case "--padding":
        idx += 1; guard idx < args.count, let f = Double(args[idx]) else { die("--padding needs a value") }
        padding = CGFloat(f)
    case "--bg":
        idx += 1; guard idx < args.count else { die("--bg needs a value") }
        bg = parseColor(args[idx])
    case "--rounded":
        idx += 1; guard idx < args.count, let f = Double(args[idx]) else { die("--rounded needs a value") }
        rounded = CGFloat(f)
    default:
        die("unknown option: \(arg)")
    }
    idx += 1
}

let url = URL(fileURLWithPath: inputPath)
guard let image = NSImage(contentsOf: url) else { die("could not load \(inputPath)") }
image.size = NSSize(width: size, height: size)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 32)
else { die("could not allocate bitmap") }
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
defer { NSGraphicsContext.restoreGraphicsState() }
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { die("no graphics context") }
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill(); canvas.fill()

if let bg {
    bg.setFill()
    if rounded > 0 {
        let radius = CGFloat(size) * min(max(rounded, 0), 0.5)
        NSBezierPath(roundedRect: canvas, xRadius: radius, yRadius: radius).fill()
    } else {
        canvas.fill()
    }
}

let pad = CGFloat(size) * min(max(padding, 0), 0.45)
let drawRect = canvas.insetBy(dx: pad, dy: pad)
image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)

ctx.flushGraphics()

if template {
    let bytes = rep.bitmapData!
    let total = size * size
    for i in 0..<total {
        let p = bytes.advanced(by: i * 4)
        if p[3] > 0 { p[0] = 0; p[1] = 0; p[2] = 0 }
    }
}

guard let png = rep.representation(using: .png, properties: [:]) else { die("png encode failed") }
try png.write(to: URL(fileURLWithPath: outputPath))
