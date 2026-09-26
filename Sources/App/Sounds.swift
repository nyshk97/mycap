import AppKit

/// 撮影・録画の開始・録画の停止で鳴らす音。macOS に入っている音を使う（アプリには同梱しない）
enum Sounds {
    private static let dir = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    private static let shot = load("Screen Capture.aif")
    private static let recordStart = load("begin_record.caf")
    private static let recordStop = load("end_record.caf")

    /// 静止画を撮ってサムネイルを出すとき
    static func playShot() { play(shot, "shot") }
    static func playRecordStart() { play(recordStart, "record_start") }
    static func playRecordStop() { play(recordStop, "record_stop") }

    private static func load(_ name: String) -> NSSound? {
        let sound = NSSound(contentsOfFile: dir + name, byReference: true)
        if sound == nil { Log.write("sound.missing file=\(name)") }
        return sound
    }

    private static func play(_ sound: NSSound?, _ what: String) {
        guard let sound else { return }
        // 連続で撮ったときは鳴っている途中から頭に戻して鳴らし直す
        sound.stop()
        sound.play()
        Log.write("sound.played what=\(what)")
    }
}
