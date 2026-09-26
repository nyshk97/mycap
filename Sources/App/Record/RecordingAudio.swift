import AVFoundation
import Foundation

/// 録画に入れる音声。オールインワンのツールバーのトグルで切り替え、UserDefaults に覚える（再起動・更新をまたぐ。初期値は両方 OFF）。
/// Recorder は録画の開始時にここを読む（トグルの状態の正はここ 1 か所）
struct RecordingAudio: Equatable {
    var mic: Bool
    var system: Bool

    private static let micKey = "recordingAudio.mic"
    private static let systemKey = "recordingAudio.system"

    static func load() -> RecordingAudio {
        RecordingAudio(mic: UserDefaults.standard.bool(forKey: micKey), system: UserDefaults.standard.bool(forKey: systemKey))
    }

    static func save(_ audio: RecordingAudio) {
        UserDefaults.standard.set(audio.mic, forKey: micKey)
        UserDefaults.standard.set(audio.system, forKey: systemKey)
    }

    /// マイク ON なら許可を確かめる。未決定なら OS のダイアログを出して返事を待つ。
    /// 拒否・制限ならトーストを出してマイクを外す（録画自体は止めない）。`done` は main で呼ぶ
    static func resolve(_ audio: RecordingAudio, done: @escaping (RecordingAudio) -> Void) {
        guard audio.mic else { return done(audio) }
        func denied() {
            Log.write("record.mic_denied")
            Toast.shared.show("マイクの許可が無いので、マイクなしで録ります")
            done(RecordingAudio(mic: false, system: audio.system))
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(audio)
        case .notDetermined:
            Log.write("record.mic_requesting")
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    Log.write("record.mic_answered granted=\(ok)")
                    ok ? done(audio) : denied()
                }
            }
        default:
            denied()
        }
    }
}
