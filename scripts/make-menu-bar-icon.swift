// Builds the menu bar icon, a template image, from the logo.
//
//     swift scripts/make-menu-bar-icon.swift Design/logo.png App/Assets.xcassets/MenuBarIcon.imageset
//
// The logo's dark rounded square becomes opaque and its light R is cut out, so macOS draws the icon in the menu bar's
// own color, light or dark. The R's shaded fold stays partly transparent, so the letter keeps its shape.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: make-menu-bar-icon.swift <logo.png> <MenuBarIcon.imageset>")
    exit(1)
}
let source = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: arguments[1])))!
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// The logo's rounded square: the box of its opaque pixels.
var box = (minX: source.pixelsWide, minY: source.pixelsHigh, maxX: 0, maxY: 0)
for y in 0..<source.pixelsHigh {
    for x in 0..<source.pixelsWide where (source.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
        box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
    }
}
let width = box.maxX - box.minX + 1
let height = box.maxY - box.minY + 1

// Opaque where the logo is dark, clear where it's light: from luminance 0.35 (opaque) to 0.55 (clear).
var pixels = [UInt8](repeating: 0, count: width * height * 4)
for y in 0..<height {
    for x in 0..<width {
        guard let color = source.colorAt(x: box.minX + x, y: box.minY + y)?.usingColorSpace(.sRGB) else { continue }
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        let alpha = min(max((0.55 - luminance) / 0.2, 0), 1) * color.alphaComponent
        pixels[(y * width + x) * 4 + 3] = UInt8((alpha * 255).rounded())
    }
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGImageAlphaInfo.premultipliedLast.rawValue
let mask = pixels.withUnsafeMutableBytes { bytes in
    CGContext(
        data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: space, bitmapInfo: info)!.makeImage()!
}

/// 16 points, like the system's menu bar icons.
func write(_ pixels: Int, name: String) throws {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4, space: space,
        bitmapInfo: info)!
    context.interpolationQuality = .high
    // Centered, keeping the logo's proportions.
    let scale = CGFloat(pixels) / CGFloat(max(width, height))
    let size = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
    let origin = CGPoint(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2)
    context.draw(mask, in: CGRect(origin: origin, size: size))
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: output.appending(path: name))
}
try write(16, name: "menu-bar-icon_16.png")
try write(32, name: "menu-bar-icon_32.png")

let contents = """
    {
      "images" : [
        {
          "filename" : "menu-bar-icon_16.png",
          "idiom" : "universal",
          "scale" : "1x"
        },
        {
          "filename" : "menu-bar-icon_32.png",
          "idiom" : "universal",
          "scale" : "2x"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      },
      "properties" : {
        "template-rendering-intent" : "template"
      }
    }

    """
try contents.write(to: output.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(output.path) from a \(width)×\(height) logo")
