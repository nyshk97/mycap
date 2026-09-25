import CoreGraphics
import Foundation

/// Vision の認識結果（断片ごとの文字列と位置）から、コピーするテキストを組み立てる（純粋関数）。
/// 位置は Vision の正規化座標（0〜1、原点は左下）。縦に重なる断片を 1 行にまとめ、行は上から、行の中は左から並べる
enum OCRText {
    struct Fragment {
        let text: String
        let box: CGRect
        init(_ text: String, _ box: CGRect) {
            self.text = text
            self.box = box
        }
    }

    static func assemble(_ fragments: [Fragment]) -> String {
        let items = fragments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        // 上にあるもの（maxY が大きい）から順に、既存の行と縦に半分以上重なれば同じ行に入れる
        var lines: [[Fragment]] = []
        for f in items.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let i = lines.firstIndex(where: { line in line.contains { overlapsVertically($0.box, f.box) } }) {
                lines[i].append(f)
            } else {
                lines.append([f])
            }
        }
        return lines
            .map { line in join(line.sorted { $0.box.minX < $1.box.minX }.map(\.text)) }
            .joined(separator: "\n")
    }

    /// 低い方の高さの半分以上が重なっていれば同じ行
    private static func overlapsVertically(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > min(a.height, b.height) / 2
    }

    /// 同じ行の断片をつなぐ。英数字どうしの間だけ空白を入れる（日本語の間に空白を入れない）
    static func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts {
            if let last = out.last, let first = part.first, last.isASCIIWordChar, first.isASCIIWordChar {
                out += " "
            }
            out += part
        }
        return out
    }
}

private extension Character {
    var isASCIIWordChar: Bool { isASCII && (isLetter || isNumber) }
}
