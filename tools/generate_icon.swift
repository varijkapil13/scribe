// Renders Scribe's placeholder app icon at 1024x1024 and saves it as
// `tools/AppIcon-1024.png`. Run with `swift tools/generate_icon.swift`.
//
// The companion shell script (`tools/regen_app_icon.sh`) calls this once,
// then uses `sips` to derive the sizes the macOS asset catalog expects.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let outputURL = URL(fileURLWithPath: "tools/AppIcon-1024.png")

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Failed to create CGContext")
}

context.setFillColor(NSColor.clear.cgColor)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Rounded square background with a subtle vertical gradient.
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let cornerRadius: CGFloat = CGFloat(size) * 0.225 // matches macOS Big Sur+ icon mask
let path = CGPath(roundedRect: rect.insetBy(dx: 16, dy: 16),
                  cornerWidth: cornerRadius,
                  cornerHeight: cornerRadius,
                  transform: nil)

context.addPath(path)
context.clip()

let topColor = NSColor(calibratedRed: 0.13, green: 0.20, blue: 0.40, alpha: 1).cgColor
let bottomColor = NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.18, alpha: 1).cgColor
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [topColor, bottomColor] as CFArray,
    locations: [0.0, 1.0]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// Soft inner highlight.
let highlightRect = CGRect(x: 0, y: CGFloat(size) * 0.55,
                           width: CGFloat(size), height: CGFloat(size) * 0.45)
context.saveGState()
context.addRect(highlightRect)
context.clip()
context.setFillColor(NSColor.white.withAlphaComponent(0.05).cgColor)
context.fill(highlightRect)
context.restoreGState()

// Waveform glyph centered.
let centerY = CGFloat(size) / 2
let barCount = 5
let barSpacing = CGFloat(size) * 0.085
let barWidth = CGFloat(size) * 0.055
let totalWidth = barSpacing * CGFloat(barCount - 1)
let startX = CGFloat(size) / 2 - totalWidth / 2

let barHeights: [CGFloat] = [0.30, 0.55, 0.78, 0.55, 0.30].map { $0 * CGFloat(size) }

context.setFillColor(NSColor.white.cgColor)
for i in 0..<barCount {
    let barX = startX + CGFloat(i) * barSpacing - barWidth / 2
    let barH = barHeights[i]
    let barRect = CGRect(x: barX, y: centerY - barH / 2, width: barWidth, height: barH)
    let barPath = CGPath(
        roundedRect: barRect,
        cornerWidth: barWidth / 2,
        cornerHeight: barWidth / 2,
        transform: nil
    )
    context.addPath(barPath)
    context.fillPath()
}

// "S" wordmark below the waveform — a tiny editorial mark so the icon doesn't
// read as a generic audio app at small sizes.
let monogramAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: CGFloat(size) * 0.18, weight: .bold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.85)
]
let monogram = NSAttributedString(string: "S", attributes: monogramAttributes)
let line = CTLineCreateWithAttributedString(monogram)
let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
let monoX = (CGFloat(size) - bounds.width) / 2 - bounds.origin.x
let monoY = CGFloat(size) * 0.07

context.textPosition = CGPoint(x: monoX, y: monoY)
CTLineDraw(line, context)

guard let cgImage = context.makeImage() else {
    fatalError("Failed to make CGImage")
}

guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    fatalError("Failed to create image destination at \(outputURL.path)")
}
CGImageDestinationAddImage(destination, cgImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Failed to write PNG")
}

print("Wrote \(outputURL.path) (\(size)x\(size))")
