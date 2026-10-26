#!/usr/bin/env swift
// Renders the install DMG's window background with CoreGraphics: a 1x and a 2x PNG that make-dmg.sh packs into
// one HiDPI TIFF with tiffutil.
//
//     swift scripts/make-dmg-background.swift <out.png> <out@2x.png>
//
// Same look as the app icon (scripts/make-icon.swift): the indigo → violet → rose gradient with a diagonal sheen,
// and translucent panes in AeroSpace's classic split. Silk.app sits in the tall left pane, Applications in the top
// right one, an arrow crosses the gap between them and the bottom right pane says what to do.
//
// Finder draws the icon labels in black on a background picture, in dark mode too, so the panes behind them are
// light enough to carry black text. make-dmg.sh places the icons at the centers below.

import CoreGraphics
import CoreText
import Foundation
import ImageIO

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <out.png> <out@2x.png>\n".utf8))
    exit(2)
}

/// Window content size in points; make-dmg.sh sizes the Finder window to match. The canvas runs a little taller,
/// because Finder title bars differ in height between macOS versions and the picture must not end inside the window.
let width: CGFloat = 660
let height: CGFloat = 400
let canvasHeight: CGFloat = 420
/// Icon centers in the Finder's top-left coordinates; make-dmg.sh uses the same numbers.
let appCenter = CGPoint(x: 172, y: 168)
let applicationsCenter = CGPoint(x: 488, y: 168)

let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

/// Finder coordinates (top-left origin) → CoreGraphics coordinates (bottom-left origin).
func flipped(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: canvasHeight - point.y) }
func flipped(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: canvasHeight - rect.maxY, width: rect.width, height: rect.height) }

func render(scale: CGFloat) -> CGImage {
    let context = CGContext(
        data: nil, width: Int(width * scale), height: Int(canvasHeight * scale), bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high

    // Background: the icon's gradient, bottom left to top right, toned so the label row stays mid-tone.
    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.20, 0.16, 0.48), color(0.45, 0.27, 0.76), color(0.80, 0.42, 0.66)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        background, start: CGPoint(x: 0, y: 0), end: CGPoint(x: width, y: canvasHeight),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // Sheen: a soft light band across the other diagonal, like light on silk.
    let sheen = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(1, 1, 1, 0), color(1, 1, 1, 0.16), color(1, 1, 1, 0)] as CFArray,
        locations: [0.32, 0.50, 0.68]
    )!
    context.drawLinearGradient(sheen, start: CGPoint(x: 80, y: canvasHeight + 80), end: CGPoint(x: width - 80, y: -80), options: [])

    // Panes: the icon's split, translucent so the gradient shows through.
    let margin: CGFloat = 24
    let gap: CGFloat = 20
    let leftWidth = (width - 2 * margin - gap) / 2
    let left = CGRect(x: margin, y: margin, width: leftWidth, height: height - 2 * margin)
    let topRight = CGRect(x: margin + leftWidth + gap, y: margin, width: leftWidth, height: 272)
    let bottomRight = CGRect(
        x: topRight.minX, y: topRight.maxY + gap, width: leftWidth, height: height - margin - topRight.maxY - gap
    )
    for pane in [left, topRight, bottomRight] {
        let path = CGPath(roundedRect: flipped(pane), cornerWidth: 18, cornerHeight: 18, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -4), blur: 16, color: color(0.08, 0.04, 0.25, 0.25))
        context.addPath(path)
        context.setFillColor(color(1, 1, 1, 0.24))
        context.fillPath()
        context.restoreGState()

        context.addPath(path)
        context.setStrokeColor(color(1, 1, 1, 0.22))
        context.setLineWidth(1)
        context.strokePath()
    }
    // The focused (left) pane carries the icon's accent title bar.
    context.saveGState()
    context.addPath(CGPath(roundedRect: flipped(left), cornerWidth: 18, cornerHeight: 18, transform: nil))
    context.clip()
    context.setFillColor(color(0.43, 0.25, 0.75, 0.55))
    context.fill(flipped(CGRect(x: left.minX, y: left.minY, width: left.width, height: 22)))
    context.restoreGState()

    // Arrow: from the app to Applications across the gap, fading in, with a soft glow.
    let arrowY = flipped(appCenter).y
    let tail = CGPoint(x: appCenter.x + 84, y: arrowY)
    let tip = CGPoint(x: applicationsCenter.x - 84, y: arrowY)
    let headLength: CGFloat = 20
    let headHalfWidth: CGFloat = 15
    let shaft = CGMutablePath()
    shaft.move(to: tail)
    shaft.addLine(to: CGPoint(x: tip.x - headLength + 2, y: arrowY))
    let head = CGMutablePath()
    head.move(to: tip)
    head.addLine(to: CGPoint(x: tip.x - headLength, y: arrowY + headHalfWidth))
    head.addQuadCurve(
        to: CGPoint(x: tip.x - headLength, y: arrowY - headHalfWidth), control: CGPoint(x: tip.x - headLength * 0.55, y: arrowY)
    )
    head.closeSubpath()
    let arrow = CGMutablePath()
    arrow.addPath(shaft.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 1))
    arrow.addPath(head)

    context.saveGState()
    context.setShadow(offset: .zero, blur: 14, color: color(1, 0.85, 0.95, 0.55))
    context.addPath(arrow)
    context.setFillColor(color(1, 1, 1, 0.25))
    context.fillPath()
    context.restoreGState()

    let fade = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(1, 1, 1, 0.2), color(1, 1, 1, 1)] as CFArray,
        locations: [0, 0.75]
    )!
    context.saveGState()
    context.addPath(arrow)
    context.clip()
    context.drawLinearGradient(fade, start: tail, end: tip, options: [])
    context.restoreGState()

    // Caption in the bottom right pane.
    let font = CTFontCreateUIFontForLanguage(.system, 14, nil)!
    let bold = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font
    let caption = NSMutableAttributedString()
    for (text, font, alpha) in [("Drag ", font, 0.85), ("Silk", bold, 1.0), (" into Applications", font, 0.85)] as [(String, CTFont, CGFloat)] {
        caption.append(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(1, 1, 1, alpha),
        ]))
    }
    let line = CTLineCreateWithAttributedString(caption)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let paneCenter = flipped(CGPoint(x: bottomRight.midX, y: bottomRight.midY))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: color(0.08, 0.04, 0.25, 0.45))
    context.textPosition = CGPoint(x: paneCenter.x - bounds.width / 2 - bounds.minX, y: paneCenter.y - bounds.midY)
    CTLineDraw(line, context)
    context.restoreGState()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to path: String, scale: CGFloat) {
    let url = URL(fileURLWithPath: path)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    let dpi = 72 * scale
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("Can't write \(path)") }
}

writePNG(render(scale: 1), to: CommandLine.arguments[1], scale: 1)
writePNG(render(scale: 2), to: CommandLine.arguments[2], scale: 2)
print("Wrote \(CommandLine.arguments[1]), \(CommandLine.arguments[2])")
