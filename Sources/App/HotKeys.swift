import Carbon
import Foundation

/// Carbon の RegisterEventHotKey によるグローバルホットキー。アクセシビリティ許可は要らない
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x4D59_4350 // 'MYCP'

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            DispatchQueue.main.async {
                HotKeyCenter.shared.handlers[hotKeyID.id]?()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// 登録に失敗したら OSStatus を返す（他のアプリが同じ組み合わせを取っている等）
    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> OSStatus {
        registerToken(keyCode: keyCode, modifiers: modifiers, handler: handler).status
    }

    /// 一時的に取るキー（サムネイルにマウスが乗っている間の Esc 等）用。成功したら `unregister` に渡す id を返す
    func registerToken(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> (status: OSStatus, id: UInt32?) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: signature, id: id),
            GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            handlers[id] = handler
            return (status, id)
        }
        return (status, nil)
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers[id] = nil
    }
}

/// mycap が使うホットキー（固定）。常用版は CleanShot X で使っていた ⌘⇧ 系を引き継ぐ（OCR・全画面はメニューからだけ）。
/// dev 版は CleanShot・常用版と並行できるよう ⌃⌥⌘ の別キー。
/// OS 標準のスクショショートカット（⌘⇧3/4/5 等）はシステム設定でオフにしてある前提（2026-09-25 に確認）
enum HotKeyBindings {
    struct Binding {
        let keyCode: Int
        let modifiers: Int
        let label: String
    }

    #if DEBUG
    private static let mods = controlKey | optionKey | cmdKey
    private static let prefix = "⌃⌥⌘"
    #else
    private static let mods = cmdKey | shiftKey
    private static let prefix = "⌘⇧"
    #endif

    static let region = Binding(keyCode: kVK_ANSI_4, modifiers: mods, label: prefix + "4")
    static let record = Binding(keyCode: kVK_ANSI_5, modifiers: mods, label: prefix + "5")
    static let lastRegion = Binding(keyCode: kVK_ANSI_6, modifiers: mods, label: prefix + "6")
}
