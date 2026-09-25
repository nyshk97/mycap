import AppKit
import ServiceManagement
#if !DEBUG
import Sparkle
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    /// 単一インスタンスの判定を通った後で作る（フックを渡すだけの 2 個目のプロセスで、壁紙カバー等を作らないため）
    private(set) var capture: CaptureService!
    /// 登録に失敗したホットキーの表示名（メニューバーに出す）
    private(set) var failedHotKeys: [String] = []

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
            (HotKeyBindings.fullScreen, { [weak self] in self?.capture.captureFullScreen() }),
            (HotKeyBindings.ocr, { [weak self] in self?.capture.captureOCR() }),
            (HotKeyBindings.record, { Log.write("hotkey.not_implemented record") }),
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
    /// `--full`: マウスのある画面の全画面を撮る（選択 UI が出ないのでフックにできる。クリップボードには書かない）
    /// `--dump-thumbs`: サムネイルの並び（最新が先頭）と位置をログに出す
    /// `--hover` / `--unhover`: 最新のサムネイルのホバー表示を切り替える（Esc は取らない）
    /// `--snapshot <png>`: 最新のサムネイルをプロセス内描画で PNG にする
    /// `--close-all`: サムネイルを全部閉じる
    /// `--ocr <png>`: 文字を読んでログとトーストに出す（クリップボードには書かない）
    /// `--pin <png>` / `--dump-pins` / `--close-pins`
    /// `--style <png> <out.png>`: 保存済みの整形の設定で書き出す（クリップボードには書かない）
    /// `--style-open <png>` / `--style-snapshot <png>` / `--style-close`: 整形パネル（`--style-open` はアクティブにしない）
    /// `--toggle-cover` / `--dump-cover`: デスクトップアイコン隠し（トグルはユーザーのデスクトップの見た目が変わる）: ピン留め（`--pin` はクリックしないので key にならない）
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
                capture.captureFullScreen(copy: false)
            case "--dump-thumbs":
                Log.write("hook.thumbs count=\(capture.thumbnails.count) items=\(capture.thumbnails.dump())")
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
            case "--style":
                if let src = arg(), let out = arg() {
                    let url = StyleService.export(URL(fileURLWithPath: src), settings: StyleService.settings, to: URL(fileURLWithPath: out))
                    Log.write("hook.style ok=\(url != nil)")
                }
            case "--style-open":
                if let src = arg() { capture.style.open(URL(fileURLWithPath: src), activate: false) }
            case "--style-snapshot":
                let path = arg() ?? "/tmp/mycap-style.png"
                Log.write("hook.style_snapshot path=\(path) ok=\(capture.style.snapshot(to: path))")
            case "--style-close":
                capture.style.close()
            case "--toggle-cover":
                capture.desktopCover.toggle()
            case "--dump-cover":
                Log.write("hook.cover on=\(capture.desktopCover.isOn) windows=\(capture.desktopCover.windowNumbers)")
            default:
                Log.write("hook.unknown \(cmd)")
            }
        }
    }
    #endif
}
