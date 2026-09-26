import AppKit
import SwiftUI

/// 編集ウィンドウのツールバー。タイトルバーと 1 段にまとめ（unified）、
/// 中央にツール・色・太さ、右に取り消し・やり直し・保存を置く
final class EditorToolbar: NSObject, NSToolbarDelegate {
    /// タイトルバー込みの高さの目安（ウィンドウの初期サイズの計算に使う）
    static let height: CGFloat = 52

    private static let center = NSToolbarItem.Identifier("mycap.edit.center")
    private static let actions = NSToolbarItem.Identifier("mycap.edit.actions")

    private let model: EditorModel
    let toolbar = NSToolbar(identifier: "mycap.edit")

    init(model: EditorModel) {
        self.model = model
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.center]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.center, .flexibleSpace, Self.actions]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        let host: NSView
        switch id {
        case Self.center: host = NSHostingView(rootView: EditorToolsBar(model: model))
        case Self.actions: host = NSHostingView(rootView: EditorActionsBar(model: model))
        default: return nil
        }
        host.frame.size = host.fittingSize
        item.view = host
        // 項目の枠は付けない（中の SwiftUI が自前でまとめている）
        item.isBordered = false
        return item
    }
}

/// 中央: ツール 4 つ（淡い枠でまとめる）・色・太さ
struct EditorToolsBar: View {
    @ObservedObject var model: EditorModel

    private static let tools: [(Annotation.Kind, String)] = [
        (.arrow, "矢印（A）"), (.rect, "四角（R）"), (.mosaic, "モザイク（P）"), (.text, "文字（T）"),
    ]

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Self.tools, id: \.0) { tool, tip in
                    Button {
                        model.tool = tool
                        if model.selected.map({ $0.kind != tool }) == true { model.select(nil) }
                    } label: {
                        ToolIcon(kind: tool)
                            .frame(width: 30, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(model.tool == tool ? 0.16 : 0)))
                            .foregroundStyle(model.tool == tool ? Color.primary : Color.primary.opacity(0.75))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tip)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))

            Divider().frame(height: 20)

            HStack(spacing: 2) {
                ColorMenu(model: model)
                    // モザイクに色は無いが、幅を変えないよう隠さずに薄くする
                    .disabled(model.contextKind == .mosaic)
                    .opacity(model.contextKind == .mosaic ? 0.3 : 1)
                SizeMenu(model: model)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 右: 取り消し・やり直し・保存（キャンセルはウィンドウの閉じるボタンと Esc で足りるので置かない）
struct EditorActionsBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 4) {
            Button { model.undo() } label: { ActionIcon("arrow.uturn.backward") }
                .buttonStyle(.plain).disabled(!model.canUndo).opacity(model.canUndo ? 1 : 0.35).help("取り消す（⌘Z）")
            Button { model.redo() } label: { ActionIcon("arrow.uturn.forward") }
                .buttonStyle(.plain).disabled(!model.canRedo).opacity(model.canRedo ? 1 : 0.35).help("やり直す（⌘⇧Z）")
            Button { model.onSave?() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 26)
                    // 形はツールのボタンと同じ角丸にそろえ、色だけで「ここで終わる」を示す
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .help("保存（⌘S）")
        }
        .padding(.vertical, 2)
    }
}

private struct ActionIcon: View {
    let symbol: String
    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.75))
            .frame(width: 28, height: 26)
            .contentShape(Rectangle())
    }
}

/// ツールのアイコン。文字は `textformat` だと日本語環境で「あぁ」になるので「T」を描く
private struct ToolIcon: View {
    let kind: Annotation.Kind

    var body: some View {
        switch kind {
        case .arrow: Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .semibold))
        case .rect: Image(systemName: "rectangle").font(.system(size: 14, weight: .medium))
        case .mosaic: Image(systemName: "checkerboard.rectangle").font(.system(size: 14, weight: .medium))
        case .text: Text("T").font(.system(size: 16, weight: .semibold, design: .serif))
        }
    }
}

/// 押すと開くポップオーバーのボタンの共通の見た目（中身 + ▾）
private struct MenuLabel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .contentShape(Rectangle())
    }
}

/// 今の色だけを出し、押すと 8 色のプリセットを並べたポップオーバーを開く
private struct ColorMenu: View {
    @ObservedObject var model: EditorModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            MenuLabel { Swatch(color: model.color, size: 16) }
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

/// 今の太さ（文字なら大きさ、モザイクなら粗さ）を見せ、押すとスライダーのポップオーバーを開く。文字はフォントもここで選ぶ
private struct SizeMenu: View {
    @ObservedObject var model: EditorModel
    @State private var open = false

    var body: some View {
        let kind = model.contextKind
        Button { open.toggle() } label: {
            MenuLabel { preview(kind) }
        }
        .buttonStyle(.plain)
        .help(kind == .text ? "文字の大きさとフォント" : kind == .mosaic ? "モザイクの粗さ" : "線の太さ")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { model.sizePt }, set: { model.sizePt = $0 }),
                           in: EditorModel.sizeRange(kind), onEditingChanged: { model.sliderEditing($0) })
                        .frame(width: 160)
                        .controlSize(.small)
                    Text("\(Int(model.sizePt.rounded()))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                }
                if kind == .text {
                    Picker("", selection: Binding(get: { model.font }, set: { model.setFont($0) })) {
                        ForEach(AnnotationFont.allCases, id: \.self) { f in
                            Text(f.title).font(.custom(f.rawValue, size: 13)).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(12)
        }
    }

    /// ボタンの中身。太さは今の太さの線、文字は大きさの数字、モザイクは格子
    @ViewBuilder private func preview(_ kind: Annotation.Kind) -> some View {
        switch kind {
        case .arrow, .rect:
            Capsule()
                .fill(Color.primary.opacity(0.85))
                .frame(width: 20, height: max(1.5, min(model.sizePt, 10)))
                .frame(width: 22, height: 16)
        case .text:
            Text("\(Int(model.sizePt.rounded()))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .frame(minWidth: 22, minHeight: 16)
        case .mosaic:
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 12))
                .frame(width: 22, height: 16)
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
