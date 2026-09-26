import CoreGraphics
import CoreText
import Foundation

/// 編集で画像に描き込む要素（矢印・四角・モザイク・文字）。座標は**画像のピクセル・左上原点**。
/// 保存まではデータのまま持ち、選び直して動かす・色を変えることができる。画像に焼き込むのは保存のとき（`AnnotationRenderer`）
struct Annotation: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case arrow, rect, mosaic, text
    }

    var id = UUID()
    var kind: Kind
    /// 矢印は始点、四角・モザイクは対角の一方、文字は左上
    var start: CGPoint
    /// 矢印は終点、四角・モザイクは対角のもう一方。文字では使わない
    var end: CGPoint
    var color = AnnotationColor.red
    /// 矢印・四角は線の太さ、文字は文字の大きさ、モザイクはブロックの一辺（どれもピクセル）
    var size: Double
    var text = ""
    var font = AnnotationFont.gothicBold

    init(kind: Kind, start: CGPoint, end: CGPoint, color: AnnotationColor = .red, size: Double,
         text: String = "", font: AnnotationFont = .gothicBold) {
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.size = size
        self.text = text
        self.font = font
    }

    /// 検証フックで JSON を手書きしやすいよう、`id` / `end` / `color` / `text` / `font` は省略できる
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        start = try c.decode(CGPoint.self, forKey: .start)
        end = try c.decodeIfPresent(CGPoint.self, forKey: .end) ?? start
        color = try c.decodeIfPresent(AnnotationColor.self, forKey: .color) ?? .red
        size = try c.decode(Double.self, forKey: .size)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        font = try c.decodeIfPresent(AnnotationFont.self, forKey: .font) ?? .gothicBold
    }

    /// 四角・モザイクの矩形（対角をどちら向きに引いても正の幅・高さ）
    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

/// sRGB（0〜1）
struct AnnotationColor: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    static let red = AnnotationColor(r: 1, g: 0.231, b: 0.188)
    /// ツールバーに並べる色（左から）
    static let presets: [AnnotationColor] = [
        red,
        AnnotationColor(r: 1, g: 0.584, b: 0),
        AnnotationColor(r: 1, g: 0.8, b: 0),
        AnnotationColor(r: 0.204, g: 0.78, b: 0.349),
        AnnotationColor(r: 0, g: 0.478, b: 1),
        AnnotationColor(r: 0.686, g: 0.322, b: 0.871),
        AnnotationColor(r: 1, g: 1, b: 1),
        AnnotationColor(r: 0, g: 0, b: 0),
    ]
}

/// 文字のフォント（数種のプリセットだけ。全フォント一覧は出さない）
enum AnnotationFont: String, Codable, CaseIterable {
    case gothicBold = "HiraginoSans-W6"
    case gothic = "HiraginoSans-W3"
    case maru = "HiraMaruProN-W4"
    case mincho = "HiraMinProN-W6"
    case mono = "SFMono-Bold"

    var title: String {
        switch self {
        case .gothicBold: "角ゴ 太字"
        case .gothic: "角ゴ"
        case .maru: "丸ゴ"
        case .mincho: "明朝"
        case .mono: "等幅"
        }
    }

    func ctFont(size: Double) -> CTFont {
        CTFontCreateWithName(rawValue as CFString, CGFloat(size), nil)
    }
}
