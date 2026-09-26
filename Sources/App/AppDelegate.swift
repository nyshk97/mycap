import AppKit
import ServiceManagement
#if !DEBUG
import Sparkle
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    /// 単一インスタンスの判定を通った後で作る（フックを渡すだけの 2 個目のプロセスで、サムネイルの監視等を作らないため）
    private(set) var capture: CaptureService!
    /// 登録に失敗したホットキーの表示名（メニューバーに出す）
    private(set) var failedHotKeys: [String] = []
    private var purgeTimer: Timer?

    #if !DEBUG
    private var updaterController: SPUStandardUpdaterController?
    #endif

    /// dev 版の検証フック（`--tcc` 等）を既存インスタンスへ渡す通知名
    static let commandNotification = Notification.Name((Bundle.main.bundleIdentifier ?? "mycap") + ".command")
    static let cleanShotBundleID = "pl.maketheweb.cleanshotx"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
        if forwardToRunningInstance(args) { return }
        Log.write("launch pid=\(ProcessInfo.processInfo.processIdentifier) version=\(Env.version) dev=\(Env.isDev) save=\(Env.saveDir.path)")
        ScreenCapturer.logPermission(when: "launch")
        CaptureStore.purge()
        // 起動しっぱなしでも 7 日より古いものが残り続けないよう、1 日 1 回も掃除する
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in CaptureStore.purge() }
        capture = CaptureService()

        registerHotKeys()
        menuBar = MenuBarController(app: self)

        #if !DEBUG
        if isCleanShotRunning { Log.write("cleanshot.running") }
        startUpdater()
        registerLoginItem()
        #endif

        #if DEBUG
        DistributedNotificationCenter.default().addObserver(
            forName: Self.commandNotification, object: nil, queue: .main
        ) { [weak self] note in
            let args = (note.object as? String).flatMap { $0.isEmpty ? nil : $0.components(separatedBy: "\u{1F}") } ?? []
            self?.runHookCommands(args)
        }
        if !args.isEmpty { runHookCommands(args) }
        #endif
    }

    // MARK: - 単一インスタンス

    /// 既に動いているインスタンスがあれば、引数を渡して自分は終了する。渡したら true
    private func forwardToRunningInstance(_ args: [String]) -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return false }
        Log.write("launch.forward_to_running pid=\(others.map(\.processIdentifier)) args=\(args)")
        #if DEBUG
        if !args.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                Self.commandNotification, object: args.joined(separator: "\u{1F}"), userInfo: nil, deliverImmediately: true)
        }
        #endif
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }

    // MARK: - ホットキー

    private func registerHotKeys() {
        let pairs: [(HotKeyBindings.Binding, () -> Void)] = [
            (HotKeyBindings.region, { [weak self] in self?.capture.captureRegion() }),
            (HotKeyBindings.record, { [weak self] in self?.capture.toggleRecording() }),
            (HotKeyBindings.lastRegion, { [weak self] in self?.capture.captureLastRegion() }),
            (HotKeyBindings.history, { [weak self] in self?.capture.history.toggle() }),
        ]
        for (binding, handler) in pairs {
            let status = HotKeyCenter.shared.register(keyCode: binding.keyCode, modifiers: binding.modifiers, handler: handler)
            if status == noErr {
                Log.write("hotkey.registered \(binding.label)")
            } else {
                failedHotKeys.append(binding.label)
                Log.write("hotkey.register_failed \(binding.label) status=\(status)")
            }
        }
        if !failedHotKeys.isEmpty {
            // 起動直後はこちらで気づかせ、以後はメニューバーのアイコンで気づけるようにする
            let alert = NSAlert()
            alert.messageText = "ホットキーを登録できませんでした"
            alert.informativeText = "\(failedHotKeys.joined(separator: " / ")) は他のアプリ（CleanShot X 等）が使っている可能性があります。そのアプリを終了してから mycap を起動し直してください。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// 常用版は CleanShot X と同じホットキーを取り合うので、動いていたらメニューバーで知らせる
    var isCleanShotRunning: Bool {
        #if DEBUG
        return false
        #else
        return !NSRunningApplication.runningApplications(withBundleIdentifier: Self.cleanShotBundleID).isEmpty
        #endif
    }

    // MARK: - メニューから呼ぶ

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: "Version \(Env.version)",
            .version: "",
        ])
    }

    #if !DEBUG
    var canCheckForUpdates: Bool { updaterController != nil }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    /// SUPublicEDKey が未設定のまま Sparkle を起動すると起動時にエラーダイアログが出るので、そのときは起動しない
    private func startUpdater() {
        let key = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String ?? ""
        guard !key.isEmpty, !key.hasPrefix("__") else {
            Log.write("update.disabled reason=no_public_key")
            return
        }
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        Log.write("update.started")
    }

    /// 常用版は初回起動時にログイン項目へ登録する
    private func registerLoginItem() {
        switch SMAppService.mainApp.status {
        case .enabled:
            break
        case .requiresApproval:
            Log.write("login_item.requires_approval")
        default:
            do {
                try SMAppService.mainApp.register()
                Log.write("login_item.registered")
            } catch {
                Log.write("login_item.register_failed \(error)")
            }
        }
    }
    #endif

    // MARK: - 検証フック（dev 版のみ）

    #if DEBUG
    /// `--tcc`: 画面収録の許可の状態をログに出す
    /// `--ingest <png>`: 既存の画像を撮影結果として保存・サムネイルの経路に流す（クリップボードには書かない）
    /// `--full`: マウスのある画面の全画面を撮る（選択 UI が出ないのでフックにできる）
    /// `--remember-region <x> <y> <w> <h>`: マウスのある画面の範囲（左上原点のポイント）を「前回の範囲」にする
    /// `--last-region`: 前回と同じ範囲を撮る（選択 UI が出ないのでフックにできる。許可が要る）
    /// `--dump-thumbs`: サムネイルの並び（最新が先頭）と位置をログに出す
    /// `--save-newest`: 最新のサムネイルの「保存」を押す（保存先は MYCAP_SAVE_DIR で差し替えてから）
    /// `--hover` / `--unhover`: 最新のサムネイルのホバー表示を切り替える（Esc・⌘C 等のキーは取らない）
    /// `--snapshot <png>`: 最新のサムネイルをプロセス内描画で PNG にする
    /// `--close-all`: サムネイルを全部閉じる
    /// `--ocr <png>`: 文字を読んでログとトーストに出す（クリップボードには書かない）
    /// `--pin <png>` / `--dump-pins` / `--close-pins`: ピン留め（`--pin` はクリックしないので key にならない）
    /// `--annotate <png> <json> <out.png>`: 注釈（`[Annotation]` の JSON）を焼き込んで書き出す
    /// `--edit-open <png>`: 編集ウィンドウを開く（アクティブにしない）/ `--edit-load <json>`: 注釈を足す / `--edit-select <n>` / `--edit-color <n>`（プリセットの添字）
    /// `--edit-undo` / `--edit-dump`（要素・選択・取り消しの深さをログへ）/ `--edit-snapshot <png>` / `--edit-save`（保存してサムネイルを置き換える）/ `--edit-close`（確認なしで破棄）
    /// `--history-open [screenshots|videos]`: キャプチャ履歴を開く（アクティブにしない）/ `--history-dump`: タブ・件数・フォーカス・各項目をログへ
    /// `--history-focus <n>` / `--history-kind <screenshots|videos>` / `--history-restore`（フォーカス中を戻す）/ `--history-snapshot <png>` / `--history-close`
    /// `--record-display <秒>`: picker とカウントダウンを飛ばして、マウスのある画面を指定秒数だけ録る（許可が要る）
    /// どれもフォーカスを奪わない。撮影（screencapture -i）は OS の選択 UI が出るのでフックにしない
    private func runHookCommands(_ args: [String]) {
        var queue = args
        while !queue.isEmpty {
            let cmd = queue.removeFirst()
            func arg() -> String? { queue.isEmpty ? nil : queue.removeFirst() }
            switch cmd {
            case "--tcc":
                ScreenCapturer.logPermission(when: "hook")
            case "--ingest":
                if let path = arg() { capture.ingest(path: path) }
            case "--full":
                capture.captureFullScreen()
            case "--remember-region":
                let v = [arg(), arg(), arg(), arg()].compactMap { $0.flatMap(Double.init) }
                if v.count == 4 {
                    LastRegion.save(LastRegion(displayID: NSScreen.underMouse.displayID, rect: CGRect(x: v[0], y: v[1], width: v[2], height: v[3])))
                }
            case "--last-region":
                capture.captureLastRegion()
            case "--dump-thumbs":
                Log.write("hook.thumbs count=\(capture.thumbnails.count) items=\(capture.thumbnails.dump())")
            case "--save-newest":
                capture.thumbnails.saveNewest()
            case "--pin-newest":
                capture.thumbnails.pinNewest()
            case "--hover-pins":
                capture.pins.setHovered(true)
            case "--hover":
                capture.thumbnails.hoverNewest(true)
            case "--unhover":
                capture.thumbnails.hoverNewest(false)
            case "--snapshot":
                let path = arg() ?? "/tmp/mycap-snapshot.png"
                Log.write("hook.snapshot path=\(path) ok=\(capture.thumbnails.snapshotNewest(to: path))")
            case "--close-all":
                capture.thumbnails.closeAll()
            case "--ocr":
                if let path = arg() {
                    OCR.recognizeAndCopy(url: URL(fileURLWithPath: path), source: "hook", copy: false) { text in
                        Log.write("hook.ocr text=\(text.replacingOccurrences(of: "\n", with: "⏎"))")
                    }
                }
            case "--pin":
                if let path = arg() { capture.pins.pin(url: URL(fileURLWithPath: path)) }
            case "--dump-pins":
                Log.write("hook.pins count=\(capture.pins.count) items=\(capture.pins.dump())")
            case "--close-pins":
                capture.pins.closeAll()
            case "--annotate":
                if let src = arg(), let json = arg(), let out = arg() {
                    let list = (try? Data(contentsOf: URL(fileURLWithPath: json))).flatMap { try? JSONDecoder().decode([Annotation].self, from: $0) }
                    let url = list.flatMap { EditService.export(URL(fileURLWithPath: src), annotations: $0, to: URL(fileURLWithPath: out)) }
                    Log.write("hook.annotate ok=\(url != nil) count=\(list?.count ?? -1)")
                }
            case "--edit-open":
                if let src = arg() { capture.editor.open(URL(fileURLWithPath: src), activate: false) }
            case "--edit-load":
                if let json = arg() { capture.editor.load(json: json) }
            case "--edit-select":
                if let n = arg().flatMap(Int.init) { capture.editor.selectIndex(n) }
            case "--edit-color":
                if let n = arg().flatMap(Int.init) { capture.editor.setColor(index: n) }
            case "--edit-undo":
                capture.editor.undo()
            case "--edit-dump":
                Log.write("hook.edit \(capture.editor.dump())")
            case "--edit-snapshot":
                let path = arg() ?? "/tmp/mycap-edit.png"
                Log.write("hook.edit_snapshot path=\(path) ok=\(capture.editor.snapshot(to: path))")
            case "--edit-save":
                capture.editor.save()
            case "--edit-close":
                capture.editor.close()
            case "--record-display":
                if let sec = arg().flatMap(Double.init) { capture.recorder.startForTest(seconds: sec) }
            case "--history-open":
                let kind = queue.first.flatMap(CaptureHistory.Kind.init(rawValue:))
                if kind != nil { queue.removeFirst() }
                capture.history.open(kind: kind ?? .screenshots, activate: false)
            case "--history-dump":
                Log.write("hook.history \(capture.history.dump())")
            case "--history-focus":
                if let n = arg().flatMap(Int.init) { capture.history.focus(n) }
            case "--history-kind":
                if let kind = arg().flatMap(CaptureHistory.Kind.init(rawValue:)) { capture.history.switchKind(kind) }
            case "--history-restore":
                capture.history.restoreFocused()
            case "--history-snapshot":
                let path = arg() ?? "/tmp/mycap-history.png"
                Log.write("hook.history_snapshot path=\(path) ok=\(capture.history.snapshot(to: path))")
            case "--history-close":
                capture.history.close(.hook)
            default:
                Log.write("hook.unknown \(cmd)")
            }
        }
    }
    #endif
}
