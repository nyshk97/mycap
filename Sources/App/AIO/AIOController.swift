import AppKit
import SwiftUI

/// 暗幕のパネル。アプリを前面にしないまま key になり、Esc・Enter・W / H の入力を受ける
/// （Capit を前面にすると、元のアプリのウィンドウが非アクティブの見た目で写ってしまう）
final class AIOPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// オールインワン（⌘⇧5）。マウスのあるディスプレイに暗幕を出して範囲を選ばせ、Capture / Scrolling / Recording をその範囲に行う。
/// ⌘⇧5 の振り分け（録画・カウントダウン・スクロールキャプチャ・暗幕の開閉）もここで行う
final class AIOController {
    private let recorder: Recorder
    private let scroller: ScrollCapturer

    private var panel: AIOPanel?
    private var selectionView: AIOSelectionView?
    private var hosting: NSHostingView<AIOToolbar>?
    private let model = AIOModel()
    private var screen: NSScreen = .underMouse
    /// 暗幕を出す前の前面アプリ（撮影元の記録・サムネイルの待ち受けの戻る先）
    private var app: String?

    /// 開く前の準備（許可の確認・サムネイルを隠す）。false なら開かない
    var prepare: (() -> Bool)?
    /// 暗幕を閉じた（サムネイルを戻す）
    var onClosed: (() -> Void)?
    /// 範囲（ディスプレイ内の左上原点のポイント）を撮る
    var onCapture: ((NSScreen, CGRect, String?) -> Void)?

    var isOpen: Bool { panel != nil }
    /// 暗幕が出ている・スクロールキャプチャ中（ほかの撮影のホットキーを無視する。範囲選択の UI がコマに写り込むため）
    var isBusy: Bool { isOpen || scroller.isActive }

    init(recorder: Recorder, scroller: ScrollCapturer) {
        self.recorder = recorder
        self.scroller = scroller
        model.onAction = { [weak self] in self?.perform($0) }
        model.onSizeEntered = { [weak self] w, h in self?.applySize(width: w, height: h) }
        model.onEditEnded = { [weak self] in
            guard let self, let v = selectionView else { return }
            panel?.makeFirstResponder(v)
        }
    }

    /// ⌘⇧5: 録画中・録画のカウントダウン中 → 停止／キャンセル、スクロールキャプチャ中（開始待ちを含む）→ Done、
    /// 暗幕が出ている → 閉じる、どれでもない → 開く
    func toggle() {
        if recorder.state != .idle {
            recorder.toggle()
        } else if scroller.isActive {
            scroller.finish(reason: "hotkey")
        } else if isOpen {
            close(reason: "toggle")
        } else {
            open()
        }
    }

    private func open() {
        guard prepare?() ?? true else { return }
        app = CaptureStore.frontmostAppID()
        screen = .underMouse
        let p = makePanel(frame: screen.frame)
        panel = p
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(selectionView)
        selectionView?.updateCursor(at: p.mouseLocationOutsideOfEventStream)
        Log.write("aio.opened screen=\(screen.displayID) frame=\(NSStringFromRect(screen.frame)) app=\(app ?? "-") key=\(p.isKeyWindow)")
    }

    func close(reason: String) {
        guard let p = panel else { return }
        p.orderOut(nil)
        panel = nil
        selectionView = nil
        hosting = nil
        NSCursor.arrow.set()
        Log.write("aio.closed reason=\(reason)")
        onClosed?()
    }

    private func makePanel(frame: NSRect) -> AIOPanel {
        let p = AIOPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        // 透明なウィンドウは、描いていない（alpha 0 の）ところのクリックを下のウィンドウへ素通しする。範囲の内側（穴）も受けるよう明示する
        p.ignoresMouseEvents = false
        p.hidesOnDeactivate = false

        let bounds = NSRect(origin: .zero, size: frame.size)
        let container = NSView(frame: bounds)
        let view = AIOSelectionView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.onChange = { [weak self] rect, dragging in self?.selectionChanged(rect, dragging: dragging) }
        view.onCancel = { [weak self] in self?.close(reason: "escape") }
        view.onEnter = { [weak self] in self?.perform(.capture) }
        container.addSubview(view)
        let h = NSHostingView(rootView: AIOToolbar(model: model))
        h.isHidden = true
        container.addSubview(h)
        p.contentView = container
        selectionView = view
        hosting = h
        model.size = .zero
        model.audio = RecordingAudio.load()
        return p
    }

    private func selectionChanged(_ rect: CGRect?, dragging: Bool) {
        guard let h = hosting, let v = selectionView else { return }
        guard let rect else {
            h.isHidden = true
            return
        }
        model.size = rect.size
        h.isHidden = false
        let size = h.fittingSize
        // ツールバーは影の分の余白（10pt）を持っているので、その分だけ外へずらして置く
        let pad: CGFloat = 10
        let o = AIOLayout.toolbarOrigin(selection: rect, toolbar: CGSize(width: size.width - pad * 2, height: size.height - pad * 2),
                                        bounds: v.bounds)
        h.frame = NSRect(x: o.x - pad, y: o.y - pad, width: size.width, height: size.height)
    }

    private func applySize(width: CGFloat?, height: CGFloat?) {
        guard let v = selectionView, let s = v.selection else { return }
        let r = AIOLayout.withSize(s, width: width ?? s.width, height: height ?? s.height, in: v.bounds)
        Log.write("aio.size_entered w=\(width.map { "\(Int($0))" } ?? "-") h=\(height.map { "\(Int($0))" } ?? "-") rect=\(NSStringFromRect(r))")
        v.setSelection(r)
    }

    // MARK: - アクション

    private func perform(_ action: AIOAction) {
        guard let v = selectionView, let local = v.selection else { return }
        Log.write("aio.action kind=\(action.rawValue)")
        let rect = AIOLayout.topLeft(local, boundsHeight: v.bounds.height)
        let screen = screen, app = app
        LastRegion.save(LastRegion(displayID: screen.displayID, rect: rect))
        close(reason: action.rawValue)
        switch action {
        case .capture:
            onCapture?(screen, rect, app)
        case .record:
            recorder.start(screen: screen, rect: rect, app: app)
        case .scrolling:
            scroller.start(screen: screen, rect: rect, app: app)
        }
    }

    // MARK: - 検証フック用

    /// `--aio-snapshot x y w h <png>`: その範囲（マウスのある画面・左上原点のポイント）を選んだ状態の暗幕とツールバーを、画面に出さずに描く
    func snapshot(rect: CGRect, to path: String) -> Bool {
        guard !isOpen else { return false }
        let screen = NSScreen.underMouse
        let p = makePanel(frame: screen.frame)
        defer {
            selectionView = nil
            hosting = nil
        }
        let h = screen.frame.height
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        selectionView?.setSelection(AIOLayout.rect(from: CGPoint(x: rect.minX, y: h - rect.maxY),
                                                   to: CGPoint(x: rect.maxX, y: h - rect.minY), in: bounds))
        guard let view = p.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
