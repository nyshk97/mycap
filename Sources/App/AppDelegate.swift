import AppKit
import ServiceManagement
#if !DEBUG
import Sparkle
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private let capturer = ScreenCapturer()
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
            (HotKeyBindings.region, { [weak self] in self?.captureRegion() }),
            (HotKeyBindings.fullScreen, { Log.write("hotkey.not_implemented full_screen") }),
            (HotKeyBindings.ocr, { Log.write("hotkey.not_implemented ocr") }),
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

    // MARK: - キャプチャ

    /// Phase 1: 画面収録の許可の検証用の最小経路。撮れたかと許可の状態をログに出すだけ（保存・コピーは Phase 2）
    func captureRegion() {
        capturer.capture(.interactive) { url in
            guard let url else {
                Log.write("capture.cancelled")
                return
            }
            let size = NSImage(contentsOf: url)?.representations.first.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "?"
            Log.write("capture.region.captured path=\(url.path) px=\(size)")
        }
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
    /// `--tcc`: 画面収録の許可の状態をログに出す（画面にもフォーカスにも触らない）
    private func runHookCommands(_ args: [String]) {
        for cmd in args {
            switch cmd {
            case "--tcc":
                ScreenCapturer.logPermission(when: "hook")
            default:
                Log.write("hook.unknown \(cmd)")
            }
        }
    }
    #endif
}
