#!/usr/bin/env swift
import AppKit

// OCR の確認用の画像（日本語と英語が混ざった 4 行。3 行目は左右 2 つの断片が同じ行に並ぶ）を作る。
// 使い方: swift scripts/make_ocr_fixture.swift → Tests/Fixtures/ocr-ja-en.png（Retina 相当の 2x・144dpi）
// 期待する読み取り結果は同じディレクトリの ocr-ja-en.txt。生成物はコミットする

let lines: [(String, CGFloat)] = [
    ("画面収録の許可を確認する", 40),
    ("Screen Recording 2026-09-25", 40),
    ("保存先は Downloads", 40),
    ("撮影後のサムネイルとピン留め", 40),
]
let scale: CGFloat = 2
let size = CGSize(width: 900, height: 360)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()
let font = NSFont(name: "Hiragino Sans W3", size: 30) ?? .systemFont(ofSize: 30)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
var y = size.height - 70
for (i, (text, _)) in lines.enumerated() {
    if i == 2 {
        // 左右 2 つの断片（間を大きく空けて、Vision に別の断片として返させる）
        ("保存先は" as NSString).draw(at: NSPoint(x: 40, y: y), withAttributes: attrs)
        ("Downloads" as NSString).draw(at: NSPoint(x: 520, y: y), withAttributes: attrs)
    } else {
        (text as NSString).draw(at: NSPoint(x: 40, y: y), withAttributes: attrs)
    }
    y -= 80
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Tests/Fixtures/ocr-ja-en.png"))
print("OK: Tests/Fixtures/ocr-ja-en.png")
