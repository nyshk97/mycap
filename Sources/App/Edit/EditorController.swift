import AppKit
import SwiftUI

/// 編集ウィンドウ（矢印・四角・モザイク・文字を描き込む）。⌘S で `_edited.png` をキャッシュに書き、元のサムネイルを置き換える
final class EditorController: NSObject, NSWindowDelegate {
    private var window: EditorWindow?
    private var model: EditorModel?
    private var canvas: EditorCanvas?
    /// NSToolbar の delegate は弱参照なので持っておく
    private var toolbar: EditorToolbar?
    /// 開く前に前面だったアプリ（閉じたら戻す）
    private var previousApp: NSRunningApplication?
    /// 保存した（元の画像, 書き出した画像）を受け取る
    var onSaved: ((URL, URL) -> Void)?

    func open(_ url: URL, activate: Bool = true) {
        if let window, let model, model.isDirty {
            // 描きかけを黙って捨てない
            window.makeKeyAndOrderFront(nil)
            Toast.shared.show("編集中の画像があります。保存するかキャンセルしてから開き直してください")
            Log.write("edit.open_blocked name=\(url.lastPathComponent) editing=\(model.source.lastPathComponent)")
            return
        }
        close()
        guard let (image, scale) = EditService.load(url) else {
            Log.write("edit.load_failed path=\(url.path)")
            Toast.shared.show("画像を開けませんでした")
            return
        }
        let model = EditorModel(source: url, image: image, scale: scale)
        let canvas = EditorCanvas(model: model)
        model.onChange = { [weak canvas] in canvas?.modelChanged() }
        model.onSave = { [weak self] in self?.save() }
        canvas.onEscape = { [weak self] in self?.requestClose() }
        self.model = model
        self.canvas = canvas

        let screen = NSScreen.underMouse.visibleFrame
        let size = Self.initialSize(imagePoints: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale),
                                    visible: screen.size)
        let w = EditorWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        // タイトルは出さずにツールバーと 1 段にする（Mission Control 等のためにタイトル自体は持つ）
        w.title = "編集 — \(url.lastPathComponent)"
        w.titleVisibility = .hidden
        w.toolbarStyle = .unified
        let toolbar = EditorToolbar(model: model)
        w.toolbar = toolbar.toolbar
        self.toolbar = toolbar
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.minSize = NSSize(width: 640, height: 320)
        w.delegate = self
        w.editor = self

        canvas.frame = NSRect(origin: .zero, size: size)
        w.contentView = canvas
        w.setFrameOrigin(NSPoint(x: screen.midX - w.frame.width / 2, y: screen.midY - w.frame.height / 2))
        window = w

        if activate {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFrontRegardless()
        }
        w.makeFirstResponder(canvas)
        Log.write("edit.opened name=\(url.lastPathComponent) px=\(image.width)x\(image.height) scale=\(scale) window=\(Int(size.width))x\(Int(size.height))")
    }

    /// 開いたときの大きさ。画像が原寸（ポイント）で収まる大きさ、収まらなければ画面の 9 割に収まるまで縮める
    static func initialSize(imagePoints: CGSize, visible: CGSize) -> NSSize {
        let margin: CGFloat = 32
        let maxW = visible.width * 0.9, maxH = visible.height * 0.9 - EditorToolbar.height
        let s = min(1, (maxW - margin) / imagePoints.width, (maxH - margin) / imagePoints.height)
        let w = max(640, imagePoints.width * s + margin)
        let h = max(320, imagePoints.height * s + margin)
        return NSSize(width: min(w, visible.width), height: min(h, visible.height))
    }

    /// 閉じる（描いたものがあれば破棄してよいか聞く）
    func requestClose() {
        guard let window, let model else { return }
        canvas?.endTextEditing()
        guard model.isDirty else {
            close()
            return
        }
        let alert = NSAlert()
        alert.messageText = "編集を破棄しますか？"
        alert.informativeText = "描き込んだ内容は保存されません。"
        alert.addButton(withTitle: "破棄")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                Log.write("edit.discarded annotations=\(model.annotations.count)")
                self?.close()
            }
        }
    }

    func close() {
        guard let window else { return }
        let wasKey = window.isKeyWindow
        window.delegate = nil
        window.orderOut(nil)
        self.window = nil
        model = nil
        canvas = nil
        toolbar = nil
        if wasKey, let app = previousApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.activate()
        }
        previousApp = nil
    }

    func save() {
        guard let model else { return }
        canvas?.endTextEditing()
        let source = model.source
        guard let out = EditService.export(source, annotations: model.annotations) else {
            Toast.shared.show("編集した画像を保存できませんでした")
            return
        }
        close()
        onSaved?(source, out)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose()
        return false
    }

    // MARK: - キー（メニューバーの無い常駐アプリなので、ウィンドウで受ける）

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let model, let canvas else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = flags.contains(.shift)
        switch key {
        case "z":
            if canvas.isEditingText, let um = canvas.textUndoManager {
                if shift { um.redo() } else { um.undo() }
            } else if shift {
                model.redo()
            } else {
                model.undo()
            }
        case "s": save()
        case "w": requestClose()
        case "c", "v", "x", "a":
            guard canvas.isEditingText else { return false }
            let sel: Selector = switch key {
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "x": #selector(NSText.cut(_:))
            default: #selector(NSText.selectAll(_:))
            }
            NSApp.sendAction(sel, to: nil, from: nil)
        default:
            return false
        }
        return true
    }

    // MARK: - 検証フック用

    /// JSON（`[Annotation]`）の要素を足す。取り消し 1 回分として積む
    func load(json path: String) {
        guard let model else { return }
        do {
            let list = try JSONDecoder().decode([Annotation].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let before = model.annotations
            model.annotations += list
            model.commit(before: before)
            Log.write("hook.edit_load added=\(list.count)")
        } catch {
            Log.write("hook.edit_load_failed error=\(error)")
        }
    }

    func selectIndex(_ i: Int) {
        guard let model, model.annotations.indices.contains(i) else { return }
        model.select(model.annotations[i].id)
    }

    func setColor(index: Int) {
        guard AnnotationColor.presets.indices.contains(index) else { return }
        model?.setColor(AnnotationColor.presets[index])
    }

    func undo() { model?.undo() }

    func dump() -> String {
        guard let model, let window, let canvas else { return "open=false" }
        let items = model.annotations.enumerated().map { i, a in
            "\(i):\(a.kind.rawValue)|rect=\(NSStringFromRect(AnnotationGeometry.bounds(a).integral))|size=\(a.size)|color=\(AnnotationColor.presets.firstIndex(of: a.color).map(String.init) ?? "custom")|text=\(a.text.replacingOccurrences(of: "\n", with: "⏎"))"
        }
        let sel = model.annotations.firstIndex { $0.id == model.selected?.id }.map(String.init) ?? "none"
        return "open=true name=\(model.source.lastPathComponent) window=\(NSStringFromRect(window.frame)) image=\(NSStringFromRect(canvas.imageRect)) viewScale=\(String(format: "%.3f", canvas.viewScale)) tool=\(model.tool.rawValue) count=\(model.annotations.count) selected=\(sel) undo=\(model.undoDepth) dirty=\(model.isDirty) items=\(items)"
    }

    func snapshot(to path: String) -> Bool {
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

/// ⌘Z / ⌘S / ⌘W 等をメニュー無しで受けるウィンドウ
final class EditorWindow: NSWindow {
    weak var editor: EditorController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editor?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
