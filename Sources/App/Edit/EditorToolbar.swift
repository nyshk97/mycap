import SwiftUI

/// 編集ウィンドウの上のツールバー。ツール・色・太さ（大きさ）・フォント・取り消し・保存
struct EditorToolbar: View {
    @ObservedObject var model: EditorModel

    private static let tools: [(Annotation.Kind, String, String)] = [
        (.arrow, "arrow.up.right", "矢印（A）"),
        (.rect, "rectangle", "四角（R）"),
        (.mosaic, "checkerboard.rectangle", "モザイク（P）"),
        (.text, "textformat", "文字（T）"),
    ]

    var body: some View {
        let kind = model.contextKind
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Self.tools, id: \.0) { tool, symbol, tip in
                    Button {
                        model.tool = tool
                        if model.selected.map({ $0.kind != tool }) == true { model.select(nil) }
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(model.tool == tool ? Color.accentColor : .clear))
                            .foregroundStyle(model.tool == tool ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tip)
                }
            }

            Divider().frame(height: 20)

            if kind != .mosaic {
                ColorMenu(model: model)
                Divider().frame(height: 20)
            }

            HStack(spacing: 6) {
                Image(systemName: kind == .text ? "textformat.size" : kind == .mosaic ? "square.grid.3x3" : "lineweight")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 18)
                    .help(kind == .text ? "文字の大きさ" : kind == .mosaic ? "モザイクの粗さ" : "線の太さ")
                Slider(value: Binding(get: { model.sizePt }, set: { model.sizePt = $0 }),
                       in: EditorModel.sizeRange(kind), onEditingChanged: { model.sliderEditing($0) })
                    .frame(width: 110)
                    .controlSize(.small)
                Text("\(Int(model.sizePt.rounded()))").font(.system(size: 11).monospacedDigit()).frame(width: 24, alignment: .trailing)
            }

            if kind == .text {
                Picker("", selection: Binding(get: { model.font }, set: { model.setFont($0) })) {
                    ForEach(AnnotationFont.allCases, id: \.self) { f in
                        Text(f.title).font(.custom(f.rawValue, size: 13)).tag(f)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
                .controlSize(.small)
            }

            Spacer(minLength: 8)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless).disabled(!model.canUndo).help("取り消す（⌘Z）")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.borderless).disabled(!model.canRedo).help("やり直す（⌘⇧Z）")
            // キャンセルはウィンドウの閉じるボタンと Esc で足りるので置かない
            Button { model.onSave?() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .help("保存（⌘S）")
        }
        .padding(.horizontal, 12)
        .frame(height: EditorToolbar.height)
    }

    static let height: CGFloat = 40
}

/// 今の色だけを出し、押すと 8 色のプリセットを並べたポップオーバーを開く
private struct ColorMenu: View {
    @ObservedObject var model: EditorModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                Swatch(color: model.color, size: 16)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("色")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                ForEach(AnnotationColor.presets, id: \.self) { c in
                    Swatch(color: c, size: 20)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).padding(-3).opacity(model.color == c ? 1 : 0))
                        .contentShape(Circle())
                        .onTapGesture {
                            model.setColor(c)
                            open = false
                        }
                }
            }
            .padding(10)
        }
    }
}

private struct Swatch: View {
    let color: AnnotationColor
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color(.sRGB, red: color.r, green: color.g, blue: color.b))
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.5))
    }
}
