import AppKit

/// メニューバー常駐 UI（設定画面は作らない）
final class MenuBarController: NSObject, NSMenuDelegate {
    private unowned let app: AppDelegate
    private let statusItem: NSStatusItem
    private var menu: NSMenu!
    private var recordingTimer: Timer?

    init(app: AppDelegate) {
        self.app = app
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        self.menu = menu
        rebuild(menu)
        refreshIcon()
        app.capture.recorder.onStateChange = { [weak self] in self?.refreshRecording() }
        Log.write("menu.installed")
    }

    /// 録画中はアイコンを赤い ● と経過時間に変え、クリックで停止する（メニューは出さない）
    private func refreshRecording() {
        let recorder = app.capture.recorder
        if recorder.state == .recording {
            statusItem.menu = nil
            statusItem.length = NSStatusItem.variableLength
            statusItem.button?.image = nil
            statusItem.button?.target = self
            statusItem.button?.action = #selector(stopRecording(_:))
            updateElapsed()
            if recordingTimer == nil {
                recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateElapsed() }
            }
        } else {
            recordingTimer?.invalidate()
            recordingTimer = nil
            statusItem.button?.attributedTitle = NSAttributedString(string: "")
            statusItem.button?.action = nil
            statusItem.length = NSStatusItem.squareLength
            statusItem.menu = menu
            refreshIcon()
        }
    }

    private func updateElapsed() {
        let seconds = app.capture.recorder.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: NSColor.systemRed])
        title.append(NSAttributedString(string: RecordingFormat.elapsed(seconds),
                                        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)]))
        statusItem.button?.attributedTitle = title
    }

    @objc private func stopRecording(_ sender: Any?) { app.capture.recorder.stop(reason: "menu_bar") }

    /// ホットキーの登録失敗・CleanShot X の起動中は警告アイコンにする
    private func refreshIcon() {
        if !app.failedHotKeys.isEmpty || app.isCleanShotRunning {
            let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "mycap")
            image?.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.image = StatusIcon.make()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
        refreshIcon()
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let region = NSMenuItem(title: "範囲／ウィンドウを撮る（\(HotKeyBindings.region.label)）", action: #selector(captureRegion(_:)), keyEquivalent: "")
        region.target = self
        menu.addItem(region)
        let last = NSMenuItem(title: "前回と同じ範囲を撮る（\(HotKeyBindings.lastRegion.label)）", action: #selector(captureLastRegion(_:)), keyEquivalent: "")
        last.target = self
        last.isEnabled = LastRegion.load() != nil
        menu.addItem(last)
        let full = NSMenuItem(title: "全画面を撮る", action: #selector(captureFullScreen(_:)), keyEquivalent: "")
        full.target = self
        menu.addItem(full)
        let record = NSMenuItem(title: "録画を開始（\(HotKeyBindings.record.label)）", action: #selector(toggleRecording(_:)), keyEquivalent: "")
        record.target = self
        menu.addItem(record)
        let ocr = NSMenuItem(title: "文字を読む（OCR）", action: #selector(captureOCR(_:)), keyEquivalent: "")
        ocr.target = self
        menu.addItem(ocr)
        let history = NSMenuItem(title: "キャプチャ履歴（\(HotKeyBindings.history.label)）", action: #selector(openHistory(_:)), keyEquivalent: "")
        history.target = self
        menu.addItem(history)
        menu.addItem(.separator())
        let closeAll = NSMenuItem(title: "サムネイルを全部閉じる", action: #selector(closeThumbnails(_:)), keyEquivalent: "")
        closeAll.target = self
        closeAll.isEnabled = app.capture.thumbnails.count > 0
        menu.addItem(closeAll)
        let closePins = NSMenuItem(title: "ピンを全部閉じる", action: #selector(closePins(_:)), keyEquivalent: "")
        closePins.target = self
        closePins.isEnabled = app.capture.pins.count > 0
        menu.addItem(closePins)

        var warnings: [String] = []
        if !app.failedHotKeys.isEmpty {
            warnings.append("⚠︎ ホットキーを登録できませんでした: \(app.failedHotKeys.joined(separator: " / "))")
        }
        if app.isCleanShotRunning {
            warnings.append("⚠︎ CleanShot X が起動中です（ホットキーを取り合います）")
        }
        if !warnings.isEmpty {
            menu.addItem(.separator())
            for text in warnings {
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        let version = NSMenuItem(title: Env.versionLabel, action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let about = NSMenuItem(title: "mycap について", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        #if !DEBUG
        let update = NSMenuItem(title: "アップデートを確認…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        update.target = self
        update.isEnabled = app.canCheckForUpdates
        menu.addItem(update)
        #endif
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "終了", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// メニューが閉じ切る前に screencapture を起動すると、選択 UI がメニューの後ろに回ることがあるので 1 拍おく
    @objc private func captureRegion(_ sender: Any?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.app.capture.captureRegion() }
    }
    @objc private func captureLastRegion(_ sender: Any?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.app.capture.captureLastRegion() }
    }
    @objc private func captureFullScreen(_ sender: Any?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.app.capture.captureFullScreen() }
    }
    @objc private func toggleRecording(_ sender: Any?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.app.capture.toggleRecording() }
    }
    @objc private func captureOCR(_ sender: Any?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.app.capture.captureOCR() }
    }
    @objc private func openHistory(_ sender: Any?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.app.capture.history.open() }
    }
    @objc private func closeThumbnails(_ sender: Any?) { app.capture.thumbnails.closeAll() }
    @objc private func closePins(_ sender: Any?) { app.capture.pins.closeAll() }
    @objc private func showAbout(_ sender: Any?) { app.showAbout() }
    #if !DEBUG
    @objc private func checkForUpdates(_ sender: Any?) { app.checkForUpdates() }
    #endif
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}
