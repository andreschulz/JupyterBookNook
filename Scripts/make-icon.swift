// Makes the app icon from the artwork: removes the white background around it (only white that
// touches the edge, so light parts inside stay), centres it on a 1024 × 1024 transparent canvas
// and writes the PNGs of an .iconset.
//
//   swift Scripts/make-icon.swift Design/AppIcon-source.png Design/AppIcon.iconset
//   iconutil -c icns Design/AppIcon.iconset -o Design/AppIcon.icns
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: make-icon.swift source.png output.iconset")
    exit(1)
}
let source = URL(fileURLWithPath: arguments[1])
let iconset = URL(fileURLWithPath: arguments[2], isDirectory: true)

guard let image = NSImage(contentsOf: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("cannot read \(source.path)")
    exit(1)
}
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func minChannel(_ i: Int) -> Int { Int(min(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2])) }

// Background: near-white pixels connected to the border.
let backgroundLevel = 238
var background = [Bool](repeating: false, count: width * height)
var stack: [Int] = []
for x in 0..<width { stack += [x, (height - 1) * width + x] }
for y in 0..<height { stack += [y * width, y * width + width - 1] }
while let i = stack.popLast() {
    guard !background[i], minChannel(i) >= backgroundLevel else { continue }
    background[i] = true
    let x = i % width, y = i / width
    if x > 0 { stack.append(i - 1) }
    if x < width - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - width) }
    if y < height - 1 { stack.append(i + width) }
}

// Edge pixels next to the background are partly transparent by how white they are, with the
// white taken out of their colour, so the edge is smooth on any background.
let edgeLevel = 190
for i in 0..<(width * height) {
    if background[i] {
        pixels[i * 4 ..< i * 4 + 4] = [0, 0, 0, 0]
        continue
    }
    let x = i % width, y = i / width
    let touches = (x > 0 && background[i - 1]) || (x < width - 1 && background[i + 1])
        || (y > 0 && background[i - width]) || (y < height - 1 && background[i + width])
    let level = minChannel(i)
    guard touches, level > edgeLevel else { continue }
    let alpha = Double(255 - level) / Double(255 - edgeLevel)
    for c in 0..<3 {
        let value = Double(pixels[i * 4 + c])
        // Un-mix the white, then premultiply again.
        let colour = max(0, min(255, (value - 255 * (1 - alpha)) / alpha))
        pixels[i * 4 + c] = UInt8(colour * alpha)
    }
    pixels[i * 4 + 3] = UInt8(alpha * 255)
}

// The artwork's bounds.
var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
let cleaned = context.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

/// The artwork centred in a square of `size`, filling 88 % of it (the rest is room for the
/// shadow macOS draws, as in Apple's icon grid).
func icon(size: Int) -> Data {
    let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                           space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    canvas.interpolationQuality = .high
    let box = Double(size) * 0.88
    let scale = box / Double(max(cleaned.width, cleaned.height))
    let w = Double(cleaned.width) * scale, h = Double(cleaned.height) * scale
    canvas.draw(cleaned, in: CGRect(x: (Double(size) - w) / 2, y: (Double(size) - h) / 2, width: w, height: h))
    let rep = NSBitmapImageRep(cgImage: canvas.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try icon(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try icon(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
print("wrote \(iconset.path)")
