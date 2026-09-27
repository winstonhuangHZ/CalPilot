#!/usr/bin/env swift
//
//  Draws the CalPilot app icon and emits assets/CalPilot.icns.
//
//  Written with CoreGraphics instead of being generated as a bitmap, so the geometry is
//  reproducible and each size can be drawn deliberately rather than downscaled:
//  `swift scripts/generate-icon.swift`
//
//  Design: an indigo squircle holding a white calendar page with binding rings. Two grey
//  time blocks and one amber block — the slot the model picked for you — plus a spark.
//
import CoreGraphics
import Foundation
import ImageIO

// MARK: - Palette

let canvas: CGFloat = 1024
let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircleRadius: CGFloat = 185.4

let gradientTop = CGColor(srgbRed: 0.235, green: 0.290, blue: 0.780, alpha: 1)   // #3C4AC7
let gradientBottom = CGColor(srgbRed: 0.451, green: 0.318, blue: 0.960, alpha: 1) // #7351F5

// Deep navy rather than a mid indigo: a mid indigo sits too close to the background
// gradient and the top of the page visually merges with the squircle.
let headerColor = CGColor(srgbRed: 0.122, green: 0.153, blue: 0.451, alpha: 1)    // #1F2773
let cardWhite = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let ringSilver = CGColor(srgbRed: 0.902, green: 0.914, blue: 0.949, alpha: 1)     // #E6E9F2
let blockGrey = CGColor(srgbRed: 0.839, green: 0.859, blue: 0.914, alpha: 1)      // #D6DBE9
let blockAmber = CGColor(srgbRed: 1.000, green: 0.690, blue: 0.125, alpha: 1)     // #FFB020

// MARK: - Geometry

/// Two detail levels. Everything survives at 64pt and above; below that the page, the
/// binding rings, the extra bars and the spark collapse into visual mush, so the small
/// sizes get a deliberately coarser drawing rather than a downscaled one.
struct Design {
    var cardRect: CGRect
    var cardRadius: CGFloat
    var headerHeight: CGFloat
    var rings: [CGRect]
    var blocks: [(CGRect, CGColor)]
    var spark: (center: CGPoint, radius: CGFloat)?

    static let full = Design(
        // The page leaves real breathing room inside the squircle; a card that nearly
        // fills it reads as a frame rather than an icon.
        cardRect: CGRect(x: 262, y: 286, width: 500, height: 452),
        cardRadius: 56,
        headerHeight: 84,
        // Binding rings straddling the top edge — the cue that says "calendar".
        rings: [
            CGRect(x: 400, y: 252, width: 34, height: 68),
            CGRect(x: 590, y: 252, width: 34, height: 68),
        ],
        blocks: [
            (CGRect(x: 314, y: 432, width: 300, height: 48), blockGrey),
            (CGRect(x: 314, y: 534, width: 210, height: 48), blockAmber),
            (CGRect(x: 314, y: 636, width: 336, height: 48), blockGrey),
        ],
        spark: (CGPoint(x: 700, y: 558), 44)
    )

    /// 32pt: the page fills more of the squircle and the chosen block gets thicker.
    static let compact = Design(
        cardRect: CGRect(x: 236, y: 246, width: 552, height: 532),
        cardRadius: 72,
        headerHeight: 165,
        rings: [],
        blocks: [
            (CGRect(x: 312, y: 512, width: 400, height: 128), blockAmber),
        ],
        spark: nil
    )

    /// 16pt: only three bands survive — squircle, page, chosen block. The header is
    /// thickened and the block is pulled up under it so they read as one shape.
    static let tiny = Design(
        cardRect: CGRect(x: 216, y: 232, width: 592, height: 560),
        cardRadius: 76,
        headerHeight: 186,
        rings: [],
        blocks: [
            (CGRect(x: 300, y: 492, width: 424, height: 152), blockAmber),
        ],
        spark: nil
    )

    static func forSize(_ size: Int) -> Design {
        switch size {
        case ..<24: return .tiny
        case ..<48: return .compact
        default: return .full
        }
    }
}

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A four-point spark centred on `center`.
func sparkPath(center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let waist = radius * 0.20
    path.move(to: CGPoint(x: center.x, y: center.y - radius))
    path.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y),
                      control: CGPoint(x: center.x + waist, y: center.y - waist))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius),
                      control: CGPoint(x: center.x + waist, y: center.y + waist))
    path.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y),
                      control: CGPoint(x: center.x - waist, y: center.y + waist))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius),
                      control: CGPoint(x: center.x - waist, y: center.y - waist))
    path.closeSubpath()
    return path
}

// MARK: - Drawing

func makeContext(size: Int) -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else {
        fatalError("could not create a \(size)px bitmap context")
    }
    // Draw in the same top-left coordinate space as the design above.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: CGFloat(size) / canvas, y: -CGFloat(size) / canvas)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    return context
}

func drawIcon(into context: CGContext, size: Int, design: Design) {
    let scale = CGFloat(size) / canvas
    func scaled(_ value: CGFloat) -> CGFloat { value * scale }

    context.clear(CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))

    // 1. Soft drop shadow under the squircle.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: scaled(16)),
        blur: scaled(38),
        color: CGColor(srgbRed: 0.06, green: 0.07, blue: 0.24, alpha: 0.34)
    )
    context.addPath(roundedPath(squircleRect, radius: squircleRadius))
    context.setFillColor(gradientTop)
    context.fillPath()
    context.restoreGState()

    // 2. Squircle filled with the indigo gradient.
    context.saveGState()
    context.addPath(roundedPath(squircleRect, radius: squircleRadius))
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [gradientTop, gradientBottom] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: squircleRect.minX, y: squircleRect.minY),
            end: CGPoint(x: squircleRect.maxX, y: squircleRect.maxY),
            options: []
        )
    }
    // Gentle top highlight so the surface does not read as flat.
    if let gloss = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gloss,
            start: CGPoint(x: 0, y: squircleRect.minY),
            end: CGPoint(x: 0, y: squircleRect.midY),
            options: []
        )
    }
    context.restoreGState()

    // 3. The calendar page.
    let card = roundedPath(design.cardRect, radius: design.cardRadius)
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: scaled(10)),
        blur: scaled(24),
        color: CGColor(srgbRed: 0.05, green: 0.06, blue: 0.22, alpha: 0.30)
    )
    context.addPath(card)
    context.setFillColor(cardWhite)
    context.fillPath()
    context.restoreGState()

    // 4. Header band, clipped to the page so only its top corners round.
    context.saveGState()
    context.addPath(card)
    context.clip()
    context.setFillColor(headerColor)
    context.fill(CGRect(
        x: design.cardRect.minX,
        y: design.cardRect.minY,
        width: design.cardRect.width,
        height: design.headerHeight
    ))
    context.restoreGState()

    // 5. Binding rings.
    for ring in design.rings {
        context.addPath(roundedPath(ring, radius: ring.width / 2))
        context.setFillColor(ringSilver)
        context.fillPath()
    }

    // 6. Time blocks.
    for (rect, color) in design.blocks {
        context.addPath(roundedPath(rect, radius: rect.height / 2))
        context.setFillColor(color)
        context.fillPath()
    }

    // 7. Spark: the slot the model chose.
    if let spark = design.spark {
        context.addPath(sparkPath(center: spark.center, radius: spark.radius))
        context.setFillColor(blockAmber)
        context.fillPath()
    }

    // 8. Hairline rim to separate the squircle from dark backgrounds.
    context.saveGState()
    context.addPath(roundedPath(squircleRect.insetBy(dx: 0.5, dy: 0.5), radius: squircleRadius))
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
    context.setLineWidth(max(1, scaled(2)))
    context.strokePath()
    context.restoreGState()
}

func renderPNG(size: Int, to url: URL) throws {
    let context = makeContext(size: size)
    drawIcon(into: context, size: size, design: .forSize(size))
    guard let image = context.makeImage() else {
        throw NSError(domain: "CalPilotIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "no image at \(size)px"])
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "CalPilotIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "CalPilotIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot finalize \(url.path)"])
    }
}

// MARK: - Entry point

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assetsDir = root.appendingPathComponent("assets")
let iconset = assetsDir.appendingPathComponent("CalPilot.iconset")
let previewDir = assetsDir.appendingPathComponent("preview")

try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.removeItem(at: previewDir)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

// The names iconutil expects.
let iconsetSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in iconsetSizes {
    try renderPNG(size: pixels, to: iconset.appendingPathComponent(name))
}
for pixels in [1024, 256, 64, 32, 16] {
    try renderPNG(size: pixels, to: previewDir.appendingPathComponent("preview-\(pixels).png"))
}

let icnsURL = assetsDir.appendingPathComponent("CalPilot.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed with status \(iconutil.terminationStatus)\n".utf8))
    exit(1)
}

let attributes = try? FileManager.default.attributesOfItem(atPath: icnsURL.path)
let byteCount = (attributes?[.size] as? Int) ?? 0
print("wrote \(icnsURL.path) (\(byteCount) bytes)")
print("previews in \(previewDir.path)")
