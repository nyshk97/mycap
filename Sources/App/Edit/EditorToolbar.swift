import SwiftUI

/// 編集ウィンドウの上のツールバー。ツール・色・太さ（大きさ）・フォント・取り消し・保存
struct EditorToolbar: View {
    @ObservedObject var model: EditorModel

    private static let tools: [(Annotation.Kind, String, String)] = [
        (.arrow, "arrow.up.right", "矢印（A）"),
        (.rect, "rectangle", "四角（R）"),
        (.mosaic, "checkerboard.rectangle", "モザイク（M）"),
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
                HStack(spacing: 6) {
                    ForEach(AnnotationColor.presets, id: \.self) { c in
                        Circle()
                            .fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 0.5))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).padding(-3).opacity(model.color == c ? 1 : 0))
                            .contentShape(Circle())
                            .onTapGesture { model.setColor(c) }
                    }
                }
                Divider().frame(height: 20)
            }

            HStack(spacing: 6) {
                Text(kind == .text ? "大きさ" : kind == .mosaic ? "粗さ" : "太さ")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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
            Button("キャンセル") { model.onCancel?() }
                .controlSize(.small)
            Button("保存") { model.onSave?() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .help("保存してサムネイルを置き換える（⌘S）")
        }
        .padding(.horizontal, 12)
        .frame(height: EditorToolbar.height)
    }

    static let height: CGFloat = 40
}
