import AppKit
import Vision

/// 画像から文字を読む（日本語＋英語、精度優先）。結果はクリップボードに載せてトーストで知らせる
enum OCR {
    static func recognize(url: URL, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = recognizeSync(url: url)
            DispatchQueue.main.async { completion(text) }
        }
    }

    private static func recognizeSync(url: URL) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(url: url)
        do {
            try handler.perform([request])
        } catch {
            Log.write("ocr.failed error=\(error)")
            return ""
        }
        let fragments = (request.results ?? []).compactMap { obs -> OCRText.Fragment? in
            guard let top = obs.topCandidates(1).first else { return nil }
            return OCRText.Fragment(top.string, obs.boundingBox)
        }
        return OCRText.assemble(fragments)
    }

    /// 読んだ文字をクリップボードに入れ、冒頭をトーストで見せる（`near` はトーストを出す横の枠）。`copy: false` は検証フック用
    static func recognizeAndCopy(url: URL, source: String, near anchor: NSRect? = nil, copy: Bool = true,
                                 completion: ((String) -> Void)? = nil) {
        let started = Date()
        recognize(url: url) { text in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Log.write("ocr.done source=\(source) chars=\(text.count) lines=\(text.isEmpty ? 0 : text.components(separatedBy: "\n").count) ms=\(ms)")
            if text.isEmpty {
                Toast.shared.show("文字が見つかりませんでした", near: anchor)
            } else {
                if copy {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                let flat = text.replacingOccurrences(of: "\n", with: " ")
                let head = flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
                Toast.shared.show(copy ? "Copied: \(head)" : "（コピーなし）\(head)", near: anchor)
            }
            completion?(text)
        }
    }
}
