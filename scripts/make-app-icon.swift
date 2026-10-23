// Builds the macOS app icon set from the logo.
//
//     swift scripts/make-app-icon.swift Design/logo.png App/Assets.xcassets/AppIcon.appiconset
//
// The logo is a rounded square on a transparent background. It is placed on Apple's macOS icon grid: an 824-point
// rounded square (continuous corners) centered on a 1024-point canvas, with a soft shadow. The logo is enlarged just
// enough that its own anti-aliased edge falls outside that shape, so no seam shows, and its background colors fill
// in behind it. The icon then has exactly the system's shape and is never shown inside a gray tile.
import AppKit
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: make-app-icon.swift <logo.png> <AppIcon.appiconset>")
    exit(1)
}
let source = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: arguments[1])))!
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// The logo's rounded square: the box of its opaque pixels.
func isOpaque(_ x: Int, _ y: Int) -> Bool { (source.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }
var box = (minX: source.pixelsWide, minY: source.pixelsHigh, maxX: 0, maxY: 0)
for y in 0..<source.pixelsHigh {
    for x in 0..<source.pixelsWide where isOpaque(x, y) {
        box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
    }
}
let crop = CGRect(x: box.minX, y: box.minY, width: box.maxX - box.minX + 1, height: box.maxY - box.minY + 1)

// The background near each corner, inside the logo's own corner curve (never on the letter).
func color(_ fx: Double, _ fy: Double) -> CGColor {
    let x = Int(crop.minX + crop.width * fx)
    let y = Int(crop.minY + crop.height * fy)
    return source.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.withAlphaComponent(1).cgColor
}
let corners = [color(0.13, 0.13), color(0.87, 0.13), color(0.13, 0.87), color(0.87, 0.87)]

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: body).cgPath
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ width: Int, _ height: Int? = nil) -> CGContext {
    let context = CGContext(
        data: nil, width: width, height: height ?? width, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    return context
}

/// Alpha values of an image, row 0 at the top.
func alphas(_ draw: (CGContext) -> Void, width: Int, height: Int) -> [UInt8] {
    let bitmap = context(width, height)
    draw(bitmap)
    let bytes = bitmap.data!.assumingMemoryBound(to: UInt8.self)
    return (0..<width * height).map { bytes[$0 * 4 + 3] }
}

let logo = source.cgImage!.cropping(to: crop)!
let logoAlpha = alphas(
    { $0.draw(logo, in: CGRect(x: 0, y: 0, width: logo.width, height: logo.height)) },
    width: logo.width, height: logo.height)
let shapeAlpha = alphas(
    { context in
        context.addPath(shape)
        context.fillPath()
    }, width: Int(canvas), height: Int(canvas))

/// Where the logo goes at `scale`: the body, enlarged around its center.
func logoRect(_ scale: CGFloat) -> CGRect {
    body.insetBy(dx: -body.width * (scale - 1) / 2, dy: -body.height * (scale - 1) / 2)
}

/// Whether the logo, drawn at `scale`, is nearly opaque under every pixel of the icon shape.
func covers(_ scale: CGFloat) -> Bool {
    let rect = logoRect(scale)
    for y in 0..<Int(canvas) {
        for x in 0..<Int(canvas) where shapeAlpha[y * Int(canvas) + x] > 0 {
            let lx = Int((CGFloat(x) + 0.5 - rect.minX) / rect.width * CGFloat(logo.width))
            let ly = Int((CGFloat(y) + 0.5 - rect.minY) / rect.height * CGFloat(logo.height))
            guard (0..<logo.width).contains(lx), (0..<logo.height).contains(ly),
                logoAlpha[ly * logo.width + lx] >= 200
            else { return false }
        }
    }
    return true
}
let scale = stride(from: 1.0, through: 1.2, by: 0.0025).first(where: covers) ?? 1.2

let master = context(Int(canvas))
// Core Graphics' origin is bottom-left; flip so the logo's rows map top to bottom.
master.translateBy(x: 0, y: canvas)
master.scaleBy(x: 1, y: -1)

// Shadow, then the background: a blend of the logo's four corner colors.
master.saveGState()
master.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
master.addPath(shape)
master.setFillColor(corners[3])
master.fillPath()
master.restoreGState()

master.saveGState()
master.addPath(shape)
master.clip()
let blend = context(2)
for (index, corner) in corners.enumerated() {
    blend.setFillColor(corner)
    // `blend` isn't flipped: its row 1 is the top.
    blend.fill(CGRect(x: index % 2, y: 1 - index / 2, width: 1, height: 1))
}
// Scaled up from 2×2 with interpolation, the four colors become a smooth gradient.
master.draw(blend.makeImage()!, in: body.insetBy(dx: -body.width / 2, dy: -body.height / 2))
master.saveGState()
master.translateBy(x: 0, y: body.maxY + body.minY)
master.scaleBy(x: 1, y: -1)
master.draw(logo, in: logoRect(scale))
master.restoreGState()
master.restoreGState()
let image = master.makeImage()!

func write(_ size: Int) throws {
    let small = context(size)
    small.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: small.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: output.appending(path: "icon_\(size).png"))
}
for size in [16, 32, 64, 128, 256, 512, 1024] { try write(size) }

let entries = [
    (16, 1, 16), (16, 2, 32), (32, 1, 32), (32, 2, 64), (128, 1, 128), (128, 2, 256), (256, 1, 256),
    (256, 2, 512), (512, 1, 512), (512, 2, 1024),
]
let images = entries.map { point, scale, pixels in
    """
        {
          "filename" : "icon_\(pixels).png",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(point)x\(point)"
        }
    """
}
let contents = """
    {
      "images" : [
    \(images.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
try contents.write(to: output.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(output.path) from a \(Int(crop.width))×\(Int(crop.height)) logo, enlarged \(scale)×")
