// アプリアイコンを描く。使い方: swift make-icon.swift <trans|claude> <out.png>
import Foundation
import AppKit

let variant = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "trans"
let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "icon.png"
let isClaude = variant == "claude" || variant == "glyph-claude"
/// glyph: ツールバー用。背景なし・単色（テンプレート画像）で波形とカードだけを描く
let isGlyph = variant.hasPrefix("glyph")

let canvas: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let cacaoTop = rgb(139, 82, 58)     // ICTCacao ロゴのブラウン
let cacaoBottom = rgb(92, 50, 34)
let cream = rgb(246, 233, 220)
let accentA = rgb(240, 168, 76)     // 話者1
let accentB = rgb(120, 190, 214)    // 話者2
let gold = rgb(255, 214, 102)

if isGlyph {
    // 背景なしのカラー版。波形はブラウン、カードはクリーム色、話者丸はオレンジ／水色
    let ink = cacaoTop
    // 波形
    let bars: [CGFloat] = [0.22, 0.40, 0.62, 0.90, 0.55, 1.00, 0.70, 0.36, 0.82, 0.48, 0.28]
    let barW: CGFloat = 46, gap: CGFloat = 30, waveMaxH: CGFloat = 320, waveCenterY: CGFloat = 760
    let totalW = CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * gap
    var x = (canvas - totalW) / 2
    ink.setFill()
    for h in bars {
        let bh = waveMaxH * h
        NSBezierPath(roundedRect: NSRect(x: x, y: waveCenterY - bh/2, width: barW, height: bh), xRadius: barW/2, yRadius: barW/2).fill()
        x += barW + gap
    }
    // カード（クリーム色の塗り＋ブラウンの縁）
    let card = NSRect(x: 110, y: 90, width: canvas - 220, height: 440)
    let frame = NSBezierPath(roundedRect: card, xRadius: 70, yRadius: 70)
    cream.setFill()
    frame.fill()
    frame.lineWidth = 36
    ink.setStroke()
    frame.stroke()
    // 行（話者の色丸＋ブラウンの線）
    var rowY = card.maxY - 120
    let rowSpecs: [(NSColor, CGFloat)] = [(accentA, 0.62), (accentB, 0.80), (accentA, 0.46)]
    for (dot, w) in rowSpecs {
        dot.setFill()
        NSBezierPath(ovalIn: NSRect(x: card.minX + 90, y: rowY - 34, width: 68, height: 68)).fill()
        let lw = (card.width - 300) * w
        ink.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: NSRect(x: card.minX + 200, y: rowY - 20, width: lw, height: 40), xRadius: 20, yRadius: 20).fill()
        rowY -= 120
    }
    ink.setFill()
    if isClaude {
        func sparkle(center c: NSPoint, size s: CGFloat) {
            let p = NSBezierPath(); let k: CGFloat = 0.22
            p.move(to: NSPoint(x: c.x, y: c.y + s))
            p.curve(to: NSPoint(x: c.x + s, y: c.y), controlPoint1: NSPoint(x: c.x + s*k, y: c.y + s*k), controlPoint2: NSPoint(x: c.x + s*k, y: c.y + s*k))
            p.curve(to: NSPoint(x: c.x, y: c.y - s), controlPoint1: NSPoint(x: c.x + s*k, y: c.y - s*k), controlPoint2: NSPoint(x: c.x + s*k, y: c.y - s*k))
            p.curve(to: NSPoint(x: c.x - s, y: c.y), controlPoint1: NSPoint(x: c.x - s*k, y: c.y - s*k), controlPoint2: NSPoint(x: c.x - s*k, y: c.y - s*k))
            p.curve(to: NSPoint(x: c.x, y: c.y + s), controlPoint1: NSPoint(x: c.x - s*k, y: c.y + s*k), controlPoint2: NSPoint(x: c.x - s*k, y: c.y + s*k))
            p.close(); p.fill()
        }
        // 波形の右上に金色で重ねる。重なる部分はくり抜いて見やすくする
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        sparkle(center: NSPoint(x: 880, y: 900), size: 150)
        ctx.restoreGState()
        gold.setFill()
        sparkle(center: NSPoint(x: 880, y: 900), size: 118)
        rgb(214, 160, 40).setStroke()
        let outline = NSBezierPath()
        outline.lineWidth = 10
        _ = outline
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
    exit(0)
}

// 1. 角丸の土台（macOS の squircle 相当。余白 100px）
let inset: CGFloat = 100
let base = NSRect(x: inset, y: inset, width: canvas - inset*2, height: canvas - inset*2)
let radius = base.width * 0.225
let squircle = NSBezierPath(roundedRect: base, xRadius: radius, yRadius: radius)
ctx.saveGState()
squircle.addClip()
NSGradient(starting: cacaoTop, ending: cacaoBottom)!.draw(in: base, angle: -90)
// ほんのり光沢
NSGradient(starting: NSColor(white: 1, alpha: 0.10), ending: NSColor(white: 1, alpha: 0))!
    .draw(in: NSRect(x: base.minX, y: base.midY, width: base.width, height: base.height/2), angle: -90)
ctx.restoreGState()

// 2. 上半分: 波形（白、丸いバー）
let bars: [CGFloat] = [0.22, 0.40, 0.62, 0.90, 0.55, 1.00, 0.70, 0.36, 0.82, 0.48, 0.28]
let waveCenterY: CGFloat = 690
let waveMaxH: CGFloat = 230
let barW: CGFloat = 34
let gap: CGFloat = 22
let totalW = CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * gap
var x = (canvas - totalW) / 2
cream.setFill()
for h in bars {
    let bh = waveMaxH * h
    let r = NSRect(x: x, y: waveCenterY - bh/2, width: barW, height: bh)
    NSBezierPath(roundedRect: r, xRadius: barW/2, yRadius: barW/2).fill()
    x += barW + gap
}

// 3. 下半分: 文字起こしカード（話者の色丸 + テキスト行）
let card = NSRect(x: 190, y: 170, width: canvas - 380, height: 330)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor(white: 0, alpha: 0.30).cgColor)
cream.setFill()
NSBezierPath(roundedRect: card, xRadius: 44, yRadius: 44).fill()
ctx.restoreGState()

let lineColor = rgb(139, 82, 58, 0.75)
let rows: [(NSColor, [CGFloat])] = [
    (accentA, [0.62]),
    (accentB, [0.80]),
    (accentA, [0.46]),
]
var rowY = card.maxY - 78
for (dot, widths) in rows {
    dot.setFill()
    NSBezierPath(ovalIn: NSRect(x: card.minX + 52, y: rowY - 22, width: 44, height: 44)).fill()
    var lx = card.minX + 128
    for w in widths {
        let lw = (card.width - 200) * w
        lineColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: lx, y: rowY - 13, width: lw, height: 26), xRadius: 13, yRadius: 13).fill()
        lx += lw + 20
    }
    rowY -= 100
}

// 4. Claude 版: 金色のスパークル
if isClaude {
    func sparkle(center c: NSPoint, size s: CGFloat) {
        let p = NSBezierPath()
        let k: CGFloat = 0.22
        p.move(to: NSPoint(x: c.x, y: c.y + s))
        p.curve(to: NSPoint(x: c.x + s, y: c.y), controlPoint1: NSPoint(x: c.x + s*k, y: c.y + s*k), controlPoint2: NSPoint(x: c.x + s*k, y: c.y + s*k))
        p.curve(to: NSPoint(x: c.x, y: c.y - s), controlPoint1: NSPoint(x: c.x + s*k, y: c.y - s*k), controlPoint2: NSPoint(x: c.x + s*k, y: c.y - s*k))
        p.curve(to: NSPoint(x: c.x - s, y: c.y), controlPoint1: NSPoint(x: c.x - s*k, y: c.y - s*k), controlPoint2: NSPoint(x: c.x - s*k, y: c.y - s*k))
        p.curve(to: NSPoint(x: c.x, y: c.y + s), controlPoint1: NSPoint(x: c.x - s*k, y: c.y + s*k), controlPoint2: NSPoint(x: c.x - s*k, y: c.y + s*k))
        p.close()
        p.fill()
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28, color: gold.withAlphaComponent(0.9).cgColor)
    gold.setFill()
    sparkle(center: NSPoint(x: 800, y: 800), size: 92)
    sparkle(center: NSPoint(x: 705, y: 862), size: 40)
    sparkle(center: NSPoint(x: 872, y: 700), size: 34)
    ctx.restoreGState()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
