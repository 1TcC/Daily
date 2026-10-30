// 绘制 Daily 的图标，输出 1024×1024 的 PNG。
//   swift tools/make_icon.swift <输出目录>
// 生成 icon-ios.png（铺满，无透明，系统自己切圆角）和 icon-mac.png（按 macOS 图标规格留边、带圆角和阴影）。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ top: UInt32, _ bottom: UInt32) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(top), color(bottom)] as CFArray,
               locations: [0, 1])!
}

/// 在 size×size 的正方形里画完整图案：深色底、一页日历、其中一天被圈出来。
func drawArt(_ c: CGContext, size s: CGFloat) {
    // CoreGraphics 原点在左下，这里的 y 都从下往上算
    c.drawLinearGradient(gradient(0x2E3650, 0x171B2B), start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    let pageW = s * 0.64, pageH = s * 0.66
    let page = CGRect(x: (s - pageW) / 2, y: (s - pageH) / 2 - s * 0.012, width: pageW, height: pageH)
    let radius = s * 0.095

    // 底下再露出一页
    c.saveGState()
    c.setFillColor(color(0xFFFFFF, 0.16))
    c.addPath(CGPath(roundedRect: page.offsetBy(dx: 0, dy: s * 0.038).insetBy(dx: s * 0.035, dy: 0),
                     cornerWidth: radius, cornerHeight: radius, transform: nil))
    c.fillPath()
    c.restoreGState()

    // 纸面
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -s * 0.018), blur: s * 0.05, color: color(0x000000, 0.4))
    c.setFillColor(color(0xF7F4EE))
    c.addPath(CGPath(roundedRect: page, cornerWidth: radius, cornerHeight: radius, transform: nil))
    c.fillPath()
    c.restoreGState()

    // 顶部色带
    let bandH = pageH * 0.235
    c.saveGState()
    c.addPath(CGPath(roundedRect: page, cornerWidth: radius, cornerHeight: radius, transform: nil))
    c.clip()
    let band = CGRect(x: page.minX, y: page.maxY - bandH, width: pageW, height: bandH)
    c.clip(to: band)
    c.drawLinearGradient(gradient(0xE9685A, 0xD24C42), start: CGPoint(x: 0, y: band.maxY), end: CGPoint(x: 0, y: band.minY), options: [])
    c.restoreGState()

    // 日期格：4 列 3 行的圆点，最后一行第 3 个是「今天」
    let cols = 4, rows = 3
    let inset = pageW * 0.135
    let gridTop = page.maxY - bandH - pageH * 0.135
    let gridBottom = page.minY + pageH * 0.135
    let stepX = (pageW - inset * 2) / CGFloat(cols - 1)
    let stepY = (gridTop - gridBottom) / CGFloat(rows - 1)
    let dot = s * 0.048
    for row in 0..<rows {
        for col in 0..<cols {
            let center = CGPoint(x: page.minX + inset + CGFloat(col) * stepX, y: gridTop - CGFloat(row) * stepY)
            if row == 1 && col == 2 {
                let ring = dot * 1.42
                c.setFillColor(color(0xDA5448))
                c.fillEllipse(in: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2))
            } else {
                c.setFillColor(color(0x2E3650, 0.2))
                c.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))
            }
        }
    }
}

func makeContext(_ pixels: Int, alpha: Bool) -> CGContext {
    CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
}

func write(_ c: CGContext, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, c.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("saved \(url.path)")
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)

// iPhone：铺满
let ios = makeContext(1024, alpha: false)
drawArt(ios, size: 1024)
write(ios, to: out.appendingPathComponent("icon-ios.png"))

// Mac：824 见方的圆角方块居中，带投影
let mac = makeContext(1024, alpha: true)
let side: CGFloat = 824
let tile = CGRect(x: 100, y: 100 + 8, width: side, height: side)
let path = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
mac.saveGState()
mac.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
mac.setFillColor(color(0x171B2B))
mac.addPath(path)
mac.fillPath()
mac.restoreGState()
mac.saveGState()
mac.addPath(path)
mac.clip()
mac.translateBy(x: tile.minX, y: tile.minY)
drawArt(mac, size: side)
mac.restoreGState()
write(mac, to: out.appendingPathComponent("icon-mac.png"))
