import AVFoundation

/// 録画の mp4 の音声トラック（マイク・システム音）を 1 本に混ぜて書き直す。映像はパススルー（再エンコードしない）。
/// 音量比は 1:1（`AVAssetReaderAudioMixOutput` に AVAudioMix を渡さない）
enum AudioMixer {
    /// 音声トラックの本数（`record.captured audio_tracks=` と、混ぜるかどうかの判定に使う）
    static func audioTrackCount(_ url: URL, done: @escaping (Int) -> Void) {
        Task {
            let n = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count) ?? 0
            await MainActor.run { done(n) }
        }
    }

    /// `src` を混ぜた mp4 を一時ファイルに書き、その URL を main で返す。失敗したら nil（元のファイルには触らない）
    static func mix(_ src: URL, done: @escaping (URL?) -> Void) {
        Task {
            let url = await mixAsync(src)
            await MainActor.run { done(url) }
        }
    }

    private static func mixAsync(_ src: URL) async -> URL? {
        let asset = AVURLAsset(url: src)
        guard let video = try? await asset.loadTracks(withMediaType: .video).first,
              let audios = try? await asset.loadTracks(withMediaType: .audio), audios.count >= 2,
              let videoFormat = try? await video.load(.formatDescriptions).first,
              let transform = try? await video.load(.preferredTransform)
        else {
            Log.write("record.audio_mix_failed step=load")
            return nil
        }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("mycap-mix-\(UUID().uuidString).mp4")
        do {
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)

            let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
            let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audios, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(videoOut), reader.canAdd(audioOut) else { throw MixError.setup }
            reader.add(videoOut)
            reader.add(audioOut)

            let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
            videoIn.transform = transform
            videoIn.expectsMediaDataInRealTime = false
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            audioIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoIn), writer.canAdd(audioIn) else { throw MixError.setup }
            writer.add(videoIn)
            writer.add(audioIn)

            guard reader.startReading(), writer.startWriting() else { throw MixError.start(reader.error ?? writer.error) }
            writer.startSession(atSourceTime: .zero)

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await pump(videoOut, into: videoIn, label: "video") }
                group.addTask { await pump(audioOut, into: audioIn, label: "audio") }
            }
            if reader.status == .failed {
                writer.cancelWriting()
                throw MixError.read(reader.error)
            }
            // 失敗した writer に finishWriting を呼ぶと例外で落ちる
            guard writer.status == .writing else {
                reader.cancelReading()
                writer.cancelWriting()
                throw MixError.write(writer.error)
            }
            await writer.finishWriting()
            guard writer.status == .completed else { throw MixError.write(writer.error) }
            return dst
        } catch {
            Log.write("record.audio_mix_failed error=\(error)")
            try? FileManager.default.removeItem(at: dst)
            return nil
        }
    }

    /// 読めるだけ読んで書く。書き手が詰まったら待つ
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String) async {
        let queue = DispatchQueue(label: "mycap.mix.\(label)")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let buf = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    if !input.append(buf) {
                        // writer が失敗している。markAsFinished は呼ばない（例外になりうる）
                        finished = true
                        cont.resume()
                        return
                    }
                }
            }
        }
    }

    private enum MixError: Error {
        case setup
        case start(Error?)
        case read(Error?)
        case write(Error?)
    }
}
