#!/usr/bin/env swift
// Draws the installer window's background, Assets/dmg-background.png and its @2x, in the icon's "Lanterns" palette:
// warm paper with faint grain, a teal headline, and the three lights as a dotted trail from the app to Applications.
// Run from the repo root: swift scripts/make-dmg-background.swift
// The window is 640 x 400 points; the app icon sits at (170, 205) and Applications at (470, 205) (scripts/dmg-settings.py).
import AppKit
import CoreGraphics

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}

func render(scale: CGFloat) -> Data {
    let w = Int(640 * scale), h = Int(400 * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    // Flip to top-left coordinates so positions match Finder's.
    ctx.translateBy(x: 0, y: 400)
    ctx.scaleBy(x: 1, y: -1)

    ctx.setFillColor(rgb(0xF6EFE3))
    ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
    // Faint grain, seeded so every build draws the same background.
    var seed: UInt64 = 0x2545F4914F6CDD1D
    for _ in 0..<9000 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let x = CGFloat(seed >> 40 & 0x3FF) / 1023 * 640
        let y = CGFloat(seed >> 20 & 0x3FF) / 1023 * 400
        ctx.setFillColor(rgb(0x5A4A32, 0.05))
        ctx.fill(CGRect(x: x, y: y, width: 0.8, height: 0.8))
    }

    // Headline, centred.
    let title = NSAttributedString(string: "Drag Ensemble into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor(cgColor: rgb(0x163C3E))!, .kern: -0.3,
    ])
    let note = NSAttributedString(string: "Then open it. If macOS asks: System Settings \u{203A} Privacy & Security \u{203A} Open Anyway", attributes: [
        .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor(cgColor: rgb(0x163C3E, 0.6))!,
    ])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    let ts = title.size(); title.draw(at: NSPoint(x: (640 - ts.width) / 2, y: 52))
    let ns = note.size(); note.draw(at: NSPoint(x: (640 - ns.width) / 2, y: 338))
    NSGraphicsContext.restoreGraphicsState()

    // The trail: the icon's three lights, small, arcing from the app to Applications.
    let lights: [(CGFloat, UInt32, CGFloat)] = [(0.1, 0xE9A58C, 0.75), (0.3, 0xE9A58C, 0.8), (0.5, 0xF0B48C, 0.85),
                                               (0.7, 0xF7C27A, 0.9), (0.9, 0xFFC35C, 1.0)]
    for (t, color, a) in lights {
        let x = 232 + t * 176
        let y = 205 - sin(t * .pi) * 26
        let r: CGFloat = 4.5 + t * 2.5
        ctx.setFillColor(rgb(color, a))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: 640, height: 400)
    return rep.representation(using: .png, properties: [:])!
}

let assets = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets")
try render(scale: 1).write(to: assets.appendingPathComponent("dmg-background.png"))
try render(scale: 2).write(to: assets.appendingPathComponent("dmg-background@2x.png"))
print("wrote Assets/dmg-background.png and @2x")
