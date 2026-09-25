import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// マウスのある画面。常駐アプリでは `NSScreen.main` が key window 基準で当てにならないので、座標から引く
    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? screens.first!
    }

    static func withID(_ id: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == id }
    }
}
