// XM6-Connect app icon: a plain over-ear headphones silhouette on a teal tile. One solid
// shape, because the icon is read at 16-32 px in the Dock, Finder and the widget gallery,
// where thin strokes and small detail collapse into an unreadable smudge.
// Usage: swift scripts/make-icon.swift <out.png> writes the 1024 x 1024 master. To rebuild
// Resources/XM6Connect.icns: make an XM6Connect.iconset holding icon_<s>x<s>.png and
// icon_<s>x<s>@2x.png for s in 16 32 128 256 512 (resize the master with `sips -z`), then
// `iconutil -c icns XM6Connect.iconset -o Resources/XM6Connect.icns`.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)   // top-left origin, y down

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255,
                                            CGFloat(v & 255) / 255, a])!
}
func tile(_ top: UInt32, _ bottom: UInt32) -> CGPath {
    // Apple's macOS icon grid: 824 px tile, 100 px inset, ~185 px corner radius.
    let path = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: hex(0x000000, 0.35))
    ctx.addPath(path); ctx.setFillColor(hex(bottom)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [hex(top), hex(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()
    return path
}
func save(_ file: String) {
    let url = URL(fileURLWithPath: file)
    let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, ctx.makeImage()!, nil); CGImageDestinationFinalize(dst)
}


// ---- Artwork ----
let tilePath = tile(0x1FC3AE, 0x0B4F6C)
let white = hex(0xFFFFFF)
// Band arc centre, radius, stroke; the ear cups hang from the arc's two ends.
let cy: CGFloat = 470, r: CGFloat = 236, bandW: CGFloat = 92
let cupW: CGFloat = 186, cupH: CGFloat = 268

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: hex(0x000000, 0.25))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // one shadow for band + cups, no seams
ctx.setStrokeColor(white); ctx.setFillColor(white)
ctx.setLineWidth(bandW); ctx.setLineCap(.round)
// y grows downward here, so the band is the arc swept counter-clockwise from pi to 0.
ctx.addArc(center: CGPoint(x: 512, y: cy), radius: r, startAngle: .pi, endAngle: 0, clockwise: false)
ctx.strokePath()
for x in [512 - r, 512 + r] {
    let rect = CGRect(x: x - cupW / 2, y: cy - cupH * 0.18, width: cupW, height: cupH)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cupW * 0.42, cornerHeight: cupW * 0.42, transform: nil))
}
ctx.fillPath()
ctx.endTransparencyLayer()
ctx.restoreGState()

save(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
