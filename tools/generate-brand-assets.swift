#!/usr/bin/env swift
import AppKit
import Foundation

let projectURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputURL = projectURL.appendingPathComponent("assets/brand")
let temporaryURL = projectURL.appendingPathComponent("build/brand-assets")
let fileManager = FileManager.default

func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

try? fileManager.removeItem(at: outputURL)
try? fileManager.removeItem(at: temporaryURL)
try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

let night = color(14, 23, 42)
let ink = color(22, 78, 99)
let teal = color(20, 184, 166)
let gold = color(245, 196, 81)
let ivory = color(255, 247, 220)
let muted = color(148, 163, 184)

func font(_ names: [String], size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    for name in names {
        if let font = NSFont(name: name, size: size) {
            return font
        }
    }

    return NSFont.systemFont(ofSize: size, weight: weight)
}

func textFont(size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
    font(["STHeitiTC-Medium", "STHeitiSC-Medium", "PingFangTC-Semibold", "PingFangSC-Semibold"], size: size, weight: weight)
}

func titleFont(size: CGFloat) -> NSFont {
    font(["AvenirNext-DemiBold", "HelveticaNeue-Bold"], size: size, weight: .bold)
}

func drawText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .center) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]

    let attributed = NSAttributedString(string: text, attributes: attributes)
    let size = attributed.size()
    let drawRect = CGRect(
        x: rect.minX,
        y: rect.midY - (size.height / 2),
        width: rect.width,
        height: max(rect.height, size.height)
    )

    attributed.draw(in: drawRect)
}

func starPath(center: CGPoint, outer: CGFloat, inner: CGFloat, points: Int = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let step = CGFloat.pi / CGFloat(points)
    let start = -CGFloat.pi / 2

    for index in 0..<(points * 2) {
        let radius = index.isMultiple(of: 2) ? outer : inner
        let angle = start + (CGFloat(index) * step)
        let point = CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )

        if index == 0 {
            path.move(to: point)
        } else {
            path.line(to: point)
        }
    }

    path.close()
    return path
}

func drawSparkle(center: CGPoint, radius: CGFloat, color: NSColor) {
    color.setFill()
    starPath(center: center, outer: radius, inner: radius * 0.42, points: 4).fill()
}

func drawConstellation(in rect: CGRect, scale: CGFloat) {
    let points = [
        CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.72),
        CGPoint(x: rect.minX + rect.width * 0.32, y: rect.minY + rect.height * 0.83),
        CGPoint(x: rect.minX + rect.width * 0.50, y: rect.minY + rect.height * 0.75),
        CGPoint(x: rect.minX + rect.width * 0.66, y: rect.minY + rect.height * 0.88),
        CGPoint(x: rect.minX + rect.width * 0.81, y: rect.minY + rect.height * 0.70)
    ]

    let path = NSBezierPath()
    path.lineWidth = max(1, scale * 0.008)
    muted.withAlphaComponent(0.42).setStroke()

    for (index, point) in points.enumerated() {
        if index == 0 {
            path.move(to: point)
        } else {
            path.line(to: point)
        }
    }

    path.stroke()

    for point in points {
        color(226, 232, 240, 0.82).setFill()
        NSBezierPath(ovalIn: CGRect(x: point.x - scale * 0.012, y: point.y - scale * 0.012, width: scale * 0.024, height: scale * 0.024)).fill()
    }
}

func renderBitmap(width: Int, height: Int, alpha: Bool = true, draw: (CGRect) -> Void) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: alpha ? 4 : 3,
        hasAlpha: alpha,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Unable to create bitmap \(width)x\(height)")
    }

    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor.clear.setFill()
    CGRect(x: 0, y: 0, width: width, height: height).fill()
    draw(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL, type: NSBitmapImageRep.FileType, properties: [NSBitmapImageRep.PropertyKey: Any] = [:]) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    guard let data = rep.representation(using: type, properties: properties) else {
        fatalError("Unable to encode \(url.path)")
    }

    try data.write(to: url)
}

enum IconKind {
    case main
    case menu
    case preferences
    case phraseEditor
}

func drawIcon(kind: IconKind, in rect: CGRect) {
    let size = rect.width
    let radius = size * 0.225
    let iconRect = rect.insetBy(dx: size * 0.035, dy: size * 0.035)
    let background = NSBezierPath(roundedRect: iconRect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -size * 0.018), blur: size * 0.035, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSGradient(colors: [night, ink, color(15, 118, 110)])?.draw(in: background, angle: -35)
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

    color(255, 255, 255, 0.08).setStroke()
    background.lineWidth = max(1, size * 0.008)
    background.stroke()

    drawConstellation(in: iconRect, scale: size)

    let starCenter = CGPoint(x: iconRect.maxX - size * 0.19, y: iconRect.maxY - size * 0.20)
    gold.setFill()
    starPath(center: starCenter, outer: size * 0.105, inner: size * 0.047).fill()

    color(251, 191, 36, 0.30).setFill()
    NSBezierPath(ovalIn: CGRect(x: starCenter.x - size * 0.16, y: starCenter.y - size * 0.16, width: size * 0.32, height: size * 0.32)).fill()

    let glyph: String
    let glyphSize: CGFloat
    let glyphY: CGFloat
    let glyphColor: NSColor

    switch kind {
    case .main:
        glyph = "倉"
        glyphSize = size * 0.53
        glyphY = size * 0.18
        glyphColor = ivory
    case .menu:
        glyph = "倉"
        glyphSize = size * 0.56
        glyphY = size * 0.15
        glyphColor = ivory
    case .preferences:
        glyph = "星"
        glyphSize = size * 0.47
        glyphY = size * 0.20
        glyphColor = ivory
    case .phraseEditor:
        glyph = "詞"
        glyphSize = size * 0.46
        glyphY = size * 0.20
        glyphColor = ivory
    }

    drawText(glyph, in: CGRect(x: 0, y: glyphY, width: size, height: size * 0.58), font: textFont(size: glyphSize, weight: .bold), color: glyphColor)

    if kind == .main {
        drawText("X", in: CGRect(x: size * 0.66, y: size * 0.13, width: size * 0.18, height: size * 0.12), font: titleFont(size: size * 0.095), color: gold)
    }
}

func writePNG(width: Int, height: Int, to url: URL, draw: @escaping (CGRect) -> Void) throws {
    let rep = renderBitmap(width: width, height: height, draw: draw)
    try write(rep, to: url, type: .png)
}

func makeIcon(name: String, kind: IconKind) throws {
    log("Generating \(name).icns")
    let iconsetURL = temporaryURL.appendingPathComponent("\(name).iconset")
    try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

    let entries: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    for (filename, size) in entries {
        try writePNG(width: size, height: size, to: iconsetURL.appendingPathComponent(filename)) { rect in
            drawIcon(kind: kind, in: rect)
        }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.appendingPathComponent("\(name).icns").path]
    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        fatalError("iconutil failed for \(name)")
    }
}

func drawTile(symbol: String, in rect: CGRect, accent: NSColor = gold) {
    let size = min(rect.width, rect.height)
    let tile = rect.insetBy(dx: size * 0.09, dy: size * 0.09)
    let path = NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGradient(colors: [night, ink])?.draw(in: path, angle: -35)
    color(255, 255, 255, 0.10).setStroke()
    path.lineWidth = max(1, size * 0.035)
    path.stroke()
    drawSparkle(center: CGPoint(x: tile.maxX - size * 0.18, y: tile.maxY - size * 0.18), radius: size * 0.09, color: accent)
    drawText(symbol, in: tile.insetBy(dx: size * 0.08, dy: size * 0.08), font: textFont(size: size * 0.45, weight: .bold), color: ivory)
}

func writeSymbolAsset(_ symbol: String, path: String, width: Int = 32, height: Int = 32, type: NSBitmapImageRep.FileType = .tiff, accent: NSColor = gold) throws {
    log("Generating \(path)")
    let rep = renderBitmap(width: width, height: height) { rect in
        drawTile(symbol: symbol, in: rect, accent: accent)
    }

    try write(rep, to: outputURL.appendingPathComponent(path), type: type)
}

func writeAboutImage() throws {
    log("Generating About.jpg")
    let width = 275
    let height = 90
    let rep = renderBitmap(width: width, height: height, alpha: true) { rect in
        let background = NSBezierPath(rect: rect)
        NSGradient(colors: [night, color(12, 74, 110), color(15, 118, 110)])?.draw(in: background, angle: -20)
        drawConstellation(in: rect.insetBy(dx: 8, dy: 6), scale: 90)
        drawSparkle(center: CGPoint(x: 232, y: 62), radius: 14, color: gold)
        drawText("CangjieX", in: CGRect(x: 18, y: 42, width: 150, height: 26), font: titleFont(size: 25), color: ivory, alignment: .left)
        drawText("倉頡星", in: CGRect(x: 18, y: 15, width: 120, height: 24), font: textFont(size: 21, weight: .bold), color: gold, alignment: .left)
        drawText("Open Cangjie for macOS", in: CGRect(x: 128, y: 19, width: 132, height: 14), font: NSFont.systemFont(ofSize: 10, weight: .medium), color: color(203, 213, 225), alignment: .left)
    }

    try write(rep, to: outputURL.appendingPathComponent("About.jpg"), type: .jpeg, properties: [.compressionFactor: 0.92])
}

try makeIcon(name: "CangjieX", kind: .main)
try makeIcon(name: "CangjieXMenu", kind: .menu)
try makeIcon(name: "CangjieXPreferences", kind: .preferences)
try makeIcon(name: "CangjieXPhraseEditor", kind: .phraseEditor)
try writeAboutImage()

try writeSymbolAsset("A-", path: "main/FontSmaller.tiff", width: 23, height: 16, accent: teal)
try writeSymbolAsset("A+", path: "main/FontBigger.tiff", width: 23, height: 16, accent: teal)

try writeSymbolAsset("⚙", path: "preferences/general.tiff", accent: teal)
try writeSymbolAsset("倉", path: "preferences/cangjie.tiff")
try writeSymbolAsset("文", path: "preferences/phrase.tiff")
try writeSymbolAsset("◆", path: "preferences/plugin.tiff", accent: color(129, 140, 248))
try writeSymbolAsset("鍵", path: "preferences/generic.tiff", accent: teal)
try writeSymbolAsset("ㄅ", path: "preferences/phonetic.tiff", accent: color(129, 140, 248))
try writeSymbolAsset("繁", path: "preferences/simplex.tiff")
try writeSymbolAsset("↻", path: "preferences/update.tiff", accent: teal)
try writeSymbolAsset("▶", path: "preferences/playSound.tiff", width: 16, height: 16, accent: teal)
try writeSymbolAsset("■", path: "preferences/stopSound.tiff", width: 16, height: 16, accent: color(248, 113, 113))

try writeSymbolAsset("+", path: "phrase-editor/add.png", type: .png, accent: teal)
try writeSymbolAsset("−", path: "phrase-editor/delete.png", type: .png, accent: color(248, 113, 113))
try writeSymbolAsset("↻", path: "phrase-editor/reload.png", type: .png, accent: teal)
try writeSymbolAsset("詞", path: "phrase-editor/editPhrase.png", type: .png)
try writeSymbolAsset("音", path: "phrase-editor/editReading.png", type: .png, accent: color(129, 140, 248))
try writeSymbolAsset("人", path: "phrase-editor/addressBook.png", type: .png, accent: teal)

try writePNG(width: 512, height: 512, to: outputURL.appendingPathComponent("CangjieX-preview.png")) { rect in
    drawIcon(kind: .main, in: rect)
}

log("Generated brand assets in \(outputURL.path)")
