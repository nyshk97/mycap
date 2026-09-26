import AppKit
import SwiftUI

enum AIOAction: String {
    case capture, scrolling, record
}

/// ツールバーと W × H 欄の状態。範囲そのものは `AIOSelectionView` が持ち、ここへは大きさだけ写す
final class AIOModel: ObservableObject {
    /// 選んだ範囲の大きさ（ポイント）
    @Published var size: CGSize = .zero
    /// 録画に入れる音声の表示用の写し。正は UserDefaults（`RecordingAudio`）で、開くときに読み直す
    @Published var audio = RecordingAudio.load()

    /// ツールバーのトグル。UserDefaults に書く（Recorder は録画の開始時にそちらを読む）
    func toggleAudio(mic: Bool) {
        if mic { audio.mic.toggle() } else { audio.system.toggle() }
        RecordingAudio.save(audio)
        Log.write("aio.audio_toggled kind=\(mic ? "mic" : "system") on=\(mic ? audio.mic : audio.system)")
    }
    var onAction: ((AIOAction) -> Void)?
    /// W / H 欄で Enter を押した（変えなかった側は nil）
    var onSizeEntered: ((CGFloat?, CGFloat?) -> Void)?
    /// W / H 欄の編集を終えた（Enter・Esc）。フォーカスを暗幕に戻す
    var onEditEnded: (() -> Void)?
}

/// CleanShot X の All-In-One に倣ったツールバー。Capture / Scrolling ｜ Recording と、右に W × H
struct AIOToolbar: View {
    @ObservedObject var model: AIOModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                AIOToolButton(title: "Capture", symbol: "viewfinder") { model.onAction?(.capture) }
                AIOToolButton(title: "Scrolling", symbol: "arrow.down", help: "スクロールしながら縦に長く撮る") { model.onAction?(.scrolling) }
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 38).padding(.horizontal, 4)
                AIOToolButton(title: "Recording", symbol: "video") { model.onAction?(.record) }
                AIOAudioToggle(title: "Mic", on: model.audio.mic, onSymbol: "mic", offSymbol: "mic.slash",
                               help: "録画にマイクの音を入れる") { model.toggleAudio(mic: true) }
                AIOAudioToggle(title: "Sound", on: model.audio.system, onSymbol: "speaker.wave.2", offSymbol: "speaker.slash",
                               help: "録画に Mac から出る音を入れる") { model.toggleAudio(mic: false) }
            }
            .padding(6)
            .background(AIOCapsule())

            HStack(spacing: 6) {
                sizeBox(AIOSizeField(value: model.size.width) { model.onSizeEntered?($0, nil) } onEnd: { model.onEditEnded?() })
                Text("×").foregroundStyle(.white.opacity(0.5))
                sizeBox(AIOSizeField(value: model.size.height) { model.onSizeEntered?(nil, $0) } onEnd: { model.onEditEnded?() })
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background(AIOCapsule())
        }
        .fixedSize()
        .padding(10) // 影の分
    }

    /// NSTextField は縦に中央揃えできないので、背景と高さは SwiftUI 側で持つ
    private func sizeBox(_ field: AIOSizeField) -> some View {
        field
            .frame(width: 64, height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}

private struct AIOCapsule: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(white: 0.13, opacity: 0.94))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }
}

private struct AIOToolButton: View {
    let title: String
    let symbol: String
    var help: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).frame(height: 20)
                Text(title).font(.system(size: 11.5))
            }
            .foregroundStyle(.white.opacity(0.92))
            .frame(minWidth: 64)
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hovered ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help ?? "")
    }
}

/// 録画の音声のトグル。OFF は斜線のアイコンを薄く、ON は白く
private struct AIOAudioToggle: View {
    let title: String
    let on: Bool
    let onSymbol: String
    let offSymbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: on ? onSymbol : offSymbol).font(.system(size: 15, weight: .medium)).frame(height: 20)
                Text(title).font(.system(size: 11.5))
            }
            .foregroundStyle(.white.opacity(on ? 0.92 : 0.4))
            .frame(minWidth: 44)
            .padding(.horizontal, 4)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hovered ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// W / H の数値欄。Enter で反映して編集を終え、Esc で元の値に戻して編集を終える（どちらも暗幕の Enter・Esc には流さない）
private struct AIOSizeField: NSViewRepresentable {
    let value: CGFloat
    let onCommit: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: "")
        f.isBordered = false
        f.drawsBackground = false
        f.textColor = .white
        f.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        f.alignment = .center
        f.focusRingType = .none
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.currentEditor() == nil { f.stringValue = "\(Int(value))" }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AIOSizeField
        init(parent: AIOSizeField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if let v = Double(control.stringValue.trimmingCharacters(in: .whitespaces)), v > 0 {
                    parent.onCommit(CGFloat(v))
                }
                parent.onEnd()
                control.stringValue = "\(Int(parent.value))"
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                control.stringValue = "\(Int(parent.value))"
                parent.onEnd()
                return true
            default:
                return false
            }
        }
    }
}
