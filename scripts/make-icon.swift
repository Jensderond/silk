#!/usr/bin/env swift
// Renders Silk's app icon with CoreGraphics and packs it into an .icns with iconutil.
//
//     swift scripts/make-icon.swift Resources/AppIcon.icns
//
// The result is committed, so regular builds never run this. Motif: a macOS-grid rounded square with an
// indigo → violet → rose gradient and a soft diagonal sheen (silk), carrying three tiled panes in AeroSpace's
// classic split: one tall pane on the left, two stacked on the right.

import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

/// Draws the icon on a `size`×`size` pixel canvas, laid out on Apple's 1024-point icon grid.
func render(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high

    // Body: 824×824 at (100, 100) with the macOS corner radius; drop shadow below.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
    context.addPath(bodyPath)
    context.setFillColor(color(0.20, 0.16, 0.45))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.16, 0.13, 0.42), color(0.43, 0.25, 0.75), color(0.93, 0.47, 0.62)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(background, start: CGPoint(x: 160, y: 140), end: CGPoint(x: 880, y: 900), options: [])

    // Sheen: a soft light band across the diagonal, like light on silk.
    let sheen = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(1, 1, 1, 0), color(1, 1, 1, 0.22), color(1, 1, 1, 0)] as CFArray,
        locations: [0.30, 0.52, 0.72]
    )!
    context.drawLinearGradient(sheen, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    context.restoreGState()

    // Panes: a tall left tile and two stacked right tiles with even gaps.
    let inset: CGFloat = 196
    let gap: CGFloat = 44
    let content = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
    let leftWidth = (content.width - gap) * 0.52
    let rightWidth = content.width - gap - leftWidth
    let rightHeight = (content.height - gap) / 2
    let panes = [
        CGRect(x: content.minX, y: content.minY, width: leftWidth, height: content.height),
        CGRect(x: content.minX + leftWidth + gap, y: content.minY + rightHeight + gap, width: rightWidth, height: rightHeight),
        CGRect(x: content.minX + leftWidth + gap, y: content.minY, width: rightWidth, height: rightHeight),
    ]
    let paneFill = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(1, 1, 1, 0.97), color(0.94, 0.92, 1, 0.90)] as CFArray,
        locations: [0, 1]
    )!
    for (index, pane) in panes.enumerated() {
        let path = CGPath(roundedRect: pane, cornerWidth: 34, cornerHeight: 34, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0.08, 0.04, 0.25, 0.35))
        context.addPath(path)
        context.setFillColor(color(1, 1, 1, 0.95))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(paneFill, start: CGPoint(x: pane.midX, y: pane.maxY), end: CGPoint(x: pane.midX, y: pane.minY), options: [])
        // The focused (left) pane carries an accent title bar.
        if index == 0 {
            context.setFillColor(color(0.43, 0.25, 0.75, 0.85))
            context.fill(CGRect(x: pane.minX, y: pane.maxY - 46, width: pane.width, height: 46))
        }
        context.restoreGState()
    }
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Can't write \(url.path)") }
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Silk-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    writePNG(render(size: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(size: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
