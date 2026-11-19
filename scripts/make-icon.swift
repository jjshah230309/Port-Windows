// Generates the 1024x1024 app icon (an original design) with CoreGraphics. Usage: swift make-icon.swift out.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let rect = CGRect(x: 64, y: 64, width: size - 128, height: size - 128)
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 200, cornerHeight: 200, transform: nil))
ctx.clip()
let colors = [CGColor(red: 0.20, green: 0.16, blue: 0.42, alpha: 1), CGColor(red: 0.07, green: 0.55, blue: 0.62, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0), options: [])

// A simple rounded "roof" shape (an attic) in the middle.
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
ctx.move(to: CGPoint(x: 512, y: 780))
ctx.addLine(to: CGPoint(x: 800, y: 500))
ctx.addLine(to: CGPoint(x: 700, y: 500))
ctx.addLine(to: CGPoint(x: 700, y: 280))
ctx.addLine(to: CGPoint(x: 324, y: 280))
ctx.addLine(to: CGPoint(x: 324, y: 500))
ctx.addLine(to: CGPoint(x: 224, y: 500))
ctx.closePath()
ctx.fillPath()
ctx.setFillColor(CGColor(red: 0.20, green: 0.16, blue: 0.42, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 452, y: 400, width: 120, height: 120))

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("cannot create image destination") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(out)") }
