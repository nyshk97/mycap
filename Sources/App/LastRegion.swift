import AppKit

/// 「前回と同じ範囲」。ディスプレイ ID と、そのディスプレイ内の左上原点の範囲（ポイント）を UserDefaults に覚える（再起動・更新をまたぐ）
struct LastRegion: Codable {
    let displayID: CGDirectDisplayID
    let rect: CGRect

    private static let defaultsKey = "lastRegion"

    static func load() -> LastRegion? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(LastRegion.self, from: data)
    }

    static func save(_ region: LastRegion) {
        guard let data = try? JSONEncoder().encode(region) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        Log.write("region.remembered display=\(region.displayID) rect=\(NSStringFromRect(region.rect))")
    }
}

/// `screencapture -i` の間のドラッグの始点・終点を拾う。マウスのグローバルモニタはアクセシビリティ許可が要らない
final class DragTracker {
    private var monitor: Any?
    private(set) var down: CGPoint?
    private(set) var up: CGPoint?

    func start() {
        stop()
        down = nil
        up = nil
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let p = NSEvent.mouseLocation
            if event.type == .leftMouseDown {
                self?.down = p
                self?.up = nil
            } else {
                self?.up = p
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
