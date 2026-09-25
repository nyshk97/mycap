import AppKit

/// メニューバー常駐 UI（設定画面は作らない）
final class MenuBarController: NSObject, NSMenuDelegate {
    private unowned let app: AppDelegate
    private let statusItem: NSStatusItem

    init(app: AppDelegate) {
        self.app = app
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuild(menu)
        refreshIcon()
        Log.write("menu.installed")
    }

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

    @objc private func captureRegion(_ sender: Any?) { app.captureRegion() }
    @objc private func showAbout(_ sender: Any?) { app.showAbout() }
    #if !DEBUG
    @objc private func checkForUpdates(_ sender: Any?) { app.checkForUpdates() }
    #endif
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}
