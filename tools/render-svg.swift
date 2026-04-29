#!/usr/bin/env swift
// Render an SVG to a PNG of a given pixel size using AppKit (macOS 13+).
//
// Usage: render-svg.swift <input.svg> <output.png> <pixelSize> [--template]
//
// With --template, the output is a single-channel-alpha black-on-transparent
// PNG suitable for use as an NSImage template (auto-tints in menu bar etc.).
// Without --template, the SVG is rendered as-is (vector colours preserved).

import AppKit
import CoreImage

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 4 else {
    die("usage: render-svg.swift <input.svg> <output.png> <pixelSize> [--template]")
}
let inputPath = args[1]
let outputPath = args[2]
guard let size = Int(args[3]), size > 0 else { die("invalid size: \(args[3])") }
let template = args.dropFirst(4).contains("--template")

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
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
           from: .zero, operation: .sourceOver, fraction: 1.0)
ctx.flushGraphics()

if template {
    // Force every visible pixel to opaque black, preserving the alpha mask.
    // This makes the PNG behave as a proper macOS template image.
    let bytes = rep.bitmapData!
    let total = size * size
    for i in 0..<total {
        let p = bytes.advanced(by: i * 4)
        // RGBA, premultiplied. If alpha > 0, set RGB to 0 (black) at full alpha intensity.
        let a = p[3]
        if a > 0 {
            p[0] = 0
            p[1] = 0
            p[2] = 0
        }
    }
}

guard let png = rep.representation(using: .png, properties: [:]) else { die("png encode failed") }
try png.write(to: URL(fileURLWithPath: outputPath))
