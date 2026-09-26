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

/// `screencapture -i` の間のドラッグの始点・終点を拾う。
/// `screencapture -i` がマウスを握っている間はグローバルモニタにマウスイベントが届かない（常に no_drag だった）ので、
/// ボタンの状態と位置をウィンドウサーバーからポーリングする。どちらも許可は要らない
final class DragTracker {
    private var timer: Timer?
    private var pressed = false
    private(set) var down: CGPoint?
    private(set) var up: CGPoint?

    func start() {
        stop()
        down = nil
        up = nil
        pressed = false
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        // 離した直後に screencapture が終わってポーリングが離した瞬間を拾えなかったときは、今の位置を終点にする
        if pressed {
            sample()
            if pressed { up = NSEvent.mouseLocation }
        }
    }

    private func sample() {
        let isDown = NSEvent.pressedMouseButtons & 1 != 0
        let p = NSEvent.mouseLocation
        if isDown, !pressed {
            down = p
            up = nil
        } else if !isDown, pressed {
            up = p
        }
        pressed = isDown
    }
}
