#!/usr/bin/env swift
// Draws the Ensemble app icon (\"Lanterns\") with CoreGraphics and writes Assets/AppIcon.iconset, Assets/AppIcon.icns and Assets/logo.png.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit
import CoreGraphics
import Foundation

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

let fullRange: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

/// Apple-style continuous-corner squircle (superellipse), centred on (512, 512).
func squircle(half: CGFloat, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = 512 + half * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = 512 + half * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
}

/// Fine film grain as a tiled greyscale image, seeded so every build draws the same icon.
let grain: CGImage = {
    let n = 256
    var seed: UInt64 = 0x9E3779B97F4A7C15
    var bytes = [UInt8](repeating: 0, count: n * n)
    for i in 0..<bytes.count {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        bytes[i] = UInt8(truncatingIfNeeded: seed >> 56)
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}()

/// "Lanterns": a deep teal night with three warm lights in the Ensemble formation. The top light is the session
/// you are looking at, amber with a soft glow; the two below are dimmer peach.
func draw(_ ctx: CGContext, pixels: Int) {
    let small = pixels <= 64
    let body = squircle(half: 412)

    // Contact shadow under the whole icon.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: rgb(0x061416, 0.32))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0x0F2A2C))
    ctx.fillPath()
    ctx.restoreGState()

    // Base: teal, lighter at the top left, deepening to the bottom right.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0x24575A)), (0.55, rgb(0x163C3E)), (1, rgb(0x0C2426))]),
                           start: CGPoint(x: 230, y: 900), end: CGPoint(x: 820, y: 110), options: fullRange)
    if !small {
        ctx.setBlendMode(.softLight)
        ctx.setAlpha(0.35)
        ctx.draw(grain, in: CGRect(x: 0, y: 0, width: 256, height: 256), byTiling: true)
        ctx.setAlpha(1)
        ctx.setBlendMode(.normal)
    }
    // The looked-at light warms the dark around it.
    let top = CGPoint(x: 512, y: 636)
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFC867, 0.42)), (1, rgb(0xFFC867, 0))]),
                           startCenter: top, startRadius: 0, endCenter: top, endRadius: 270, options: [])
    ctx.restoreGState()

    // The three lights, lifted with a soft shadow.
    func light(_ c: CGPoint, inner: UInt32, outer: UInt32, alpha: CGFloat) {
        let r: CGFloat = 89
        let disc = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0x041012, 0.45))
        ctx.addPath(disc)
        ctx.setFillColor(rgb(outer, alpha))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(disc)
        ctx.clip()
        ctx.drawRadialGradient(gradient([(0, rgb(inner, alpha)), (1, rgb(outer, alpha))]),
                               startCenter: CGPoint(x: c.x - 26, y: c.y + 30), startRadius: 0,
                               endCenter: c, endRadius: r, options: fullRange)
        ctx.restoreGState()
    }
    light(CGPoint(x: 375, y: 395), inner: 0xFAD2C0, outer: 0xE9A58C, alpha: 0.92)
    light(CGPoint(x: 649, y: 395), inner: 0xFAD2C0, outer: 0xE9A58C, alpha: 0.92)
    light(top, inner: 0xFFE7AE, outer: 0xFFC35C, alpha: 1)

    // Hairline rim: bright on top, faint underneath.
    ctx.saveGState()
    ctx.setLineWidth(3)
    ctx.addPath(squircle(half: 410))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0.04)), (0.5, rgb(0xFFFFFF, 0.10)), (1, rgb(0xFFFFFF, 0.38))]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: fullRange)
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(ctx, pixels: pixels)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let assets = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_256x256", 256), ("icon_512x512", 512),
]
for (name, px) in sizes {
    try render(pixels: px).write(to: iconset.appendingPathComponent("\(name).png"))
    print("wrote \(name).png (\(px)px)")
}
try render(pixels: 1024).write(to: assets.appendingPathComponent("logo.png"))

let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try tool.run()
tool.waitUntilExit()
print(tool.terminationStatus == 0 ? "wrote Assets/AppIcon.icns" : "iconutil failed")
