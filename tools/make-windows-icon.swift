// Draws the icon of Windows Authenticator (https://github.com/skoszewski/windows-authenticator)
// as a Windows .ico file.
//
//   swift tools/make-windows-icon.swift <output.ico> [<preview-folder>]
//
// The icon is a shield with a keyhole inside a countdown ring on a rounded square with a blue
// gradient, the shapes of Mac Authenticator's icon layers on their 1024-unit canvas. Each size is
// drawn from the shapes, not scaled from another size. Sizes up to 64 pixels are stored as 32-bit
// DIBs with an AND mask, 256 pixels as PNG. With a preview folder, each size is also written there
// as icon-<size>.png.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sizes = [16, 20, 24, 32, 40, 48, 64, 256]

/// The icon at the given size, drawn into a context whose rows are BGRA, premultiplied, top row first.
func draw(size: Int) -> CGContext {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let scale = CGFloat(size) / 1024
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: scale, y: -scale)

    // Background: a rounded square with a gradient from the top to the bottom.
    context.saveGState()
    context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                           cornerWidth: 224, cornerHeight: 224, transform: nil))
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color(0x4F46E5), color(0x0EA5E9)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 1024), options: [])
    context.restoreGState()

    // The ring: a faint full track and three quarters clockwise from the top.
    let center = CGPoint(x: 512, y: 512)
    context.setLineWidth(72)
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.3))
    context.addEllipse(in: CGRect(x: 140, y: 140, width: 744, height: 744))
    context.strokePath()
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.setLineCap(.round)
    context.addArc(center: center, radius: 372, startAngle: -.pi / 2, endAngle: .pi, clockwise: false)
    context.strokePath()

    // The shield.
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.move(to: CGPoint(x: 325.6, y: 334.3))
    context.addQuadCurve(to: CGPoint(x: 512, y: 275.9), control: CGPoint(x: 410.1, y: 288.3))
    context.addQuadCurve(to: CGPoint(x: 698.4, y: 334.3), control: CGPoint(x: 613.9, y: 288.3))
    context.addCurve(to: CGPoint(x: 512, y: 753.1), control1: CGPoint(x: 698.4, y: 551.8),
                     control2: CGPoint(x: 621.4, y: 691))
    context.addCurve(to: CGPoint(x: 325.6, y: 334.3), control1: CGPoint(x: 402.6, y: 691),
                     control2: CGPoint(x: 325.6, y: 551.8))
    context.closePath()
    context.fillPath()

    // The keyhole.
    context.setFillColor(color(0x4338CA))
    context.addEllipse(in: CGRect(x: 512 - 57.2, y: 467.3 - 57.2, width: 114.4, height: 114.4))
    context.fillPath()
    context.addLines(between: [CGPoint(x: 484.7, y: 467.3), CGPoint(x: 467.3, y: 626.3),
                               CGPoint(x: 556.7, y: 626.3), CGPoint(x: 539.3, y: 467.3)])
    context.closePath()
    context.fillPath()
    return context
}

func color(_ rgb: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
}

func png(_ context: CGContext) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination), "The PNG image was not written.")
    return data as Data
}

/// A 32-bit DIB of the icon: BITMAPINFOHEADER, the BGRA rows bottom row first, not premultiplied, and an
/// all-zero AND mask, as an icon image of an .ico file holds it.
func dib(_ context: CGContext, size: Int) -> Data {
    var data = Data()
    data.appendLittleEndian(UInt32(40))
    data.appendLittleEndian(Int32(size))
    data.appendLittleEndian(Int32(size * 2))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt16(32))
    data.appendLittleEndian(UInt32(0))
    let maskRow = (size + 31) / 32 * 4
    data.appendLittleEndian(UInt32(size * size * 4 + maskRow * size))
    for _ in 0 ..< 4 {
        data.appendLittleEndian(UInt32(0))
    }
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    for row in (0 ..< size).reversed() {
        for column in 0 ..< size {
            let pixel = pixels + row * context.bytesPerRow + column * 4
            let alpha = Int(pixel[3])
            for channel in 0 ..< 3 {
                let value = alpha == 0 ? 0 : min(255, (Int(pixel[channel]) * 255 + alpha / 2) / alpha)
                data.append(UInt8(value))
            }
            data.append(UInt8(alpha))
        }
    }
    data.append(Data(count: maskRow * size))
    return data
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 || arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: swift tools/make-windows-icon.swift <output.ico> [<preview-folder>]\n".utf8))
    exit(2)
}

var images: [(size: Int, data: Data)] = []
for size in sizes {
    let context = draw(size: size)
    images.append((size, size >= 256 ? png(context) : dib(context, size: size)))
    if arguments.count == 3 {
        try png(context).write(to: URL(fileURLWithPath: arguments[2]).appendingPathComponent("icon-\(size).png"))
    }
}

// ICONDIR, one ICONDIRENTRY per image, then the images.
var file = Data()
file.appendLittleEndian(UInt16(0))
file.appendLittleEndian(UInt16(1))
file.appendLittleEndian(UInt16(images.count))
var offset = 6 + 16 * images.count
for image in images {
    file.append(UInt8(image.size >= 256 ? 0 : image.size))
    file.append(UInt8(image.size >= 256 ? 0 : image.size))
    file.append(UInt8(0))
    file.append(UInt8(0))
    file.appendLittleEndian(UInt16(1))
    file.appendLittleEndian(UInt16(32))
    file.appendLittleEndian(UInt32(image.data.count))
    file.appendLittleEndian(UInt32(offset))
    offset += image.data.count
}
for image in images {
    file.append(image.data)
}
try file.write(to: URL(fileURLWithPath: arguments[1]))
