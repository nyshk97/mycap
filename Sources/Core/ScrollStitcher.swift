import Accelerate
import Foundation

/// BGRA 8bit のピクセル。行の詰め物（`bytesPerRow > width * 4`）を許す（ScreenCaptureKit のコマはそのまま入れる）
struct PixelBuffer: Equatable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    var data: [UInt8]

    init(width: Int, height: Int, bytesPerRow: Int, data: [UInt8]) {
        precondition(bytesPerRow >= width * 4 && data.count >= bytesPerRow * height)
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.data = data
    }

    /// 詰め物なしで、黒（透明）で埋めたもの
    init(width: Int, height: Int) {
        self.init(width: width, height: height, bytesPerRow: width * 4, data: [UInt8](repeating: 0, count: width * height * 4))
    }

    /// 行 `range` を詰め物なしで取り出す
    func rows(_ range: Range<Int>) -> PixelBuffer {
        Self.stacked([(self, range)], width: width)
    }

    /// 行の区間を上から順に積んで 1 枚にする（詰め物なし）
    static func stacked(_ parts: [(PixelBuffer, Range<Int>)], width: Int) -> PixelBuffer {
        let rowBytes = width * 4
        let total = parts.reduce(0) { $0 + $1.1.count }
        var out = [UInt8](repeating: 0, count: rowBytes * total)
        var y = 0
        out.withUnsafeMutableBytes { dst in
            for (src, range) in parts {
                src.data.withUnsafeBytes { s in
                    for r in range {
                        let from = s.baseAddress! + r * src.bytesPerRow
                        (dst.baseAddress! + y * rowBytes).copyMemory(from: from, byteCount: rowBytes)
                        y += 1
                    }
                }
            }
        }
        return PixelBuffer(width: width, height: total, bytesPerRow: rowBytes, data: out)
    }

    /// 詰め物を除いた中身だけで比べる（テスト用）
    func samePixels(as other: PixelBuffer, ignoringRight: Int = 0) -> Bool {
        guard width == other.width, height == other.height else { return false }
        let n = (width - ignoringRight) * 4
        for y in 0..<height where data[(y * bytesPerRow)..<(y * bytesPerRow + n)] != other.data[(y * other.bytesPerRow)..<(y * other.bytesPerRow + n)] {
            return false
        }
        return true
    }
}

/// スクロールキャプチャのつなぎ。コマを 1 枚ずつ `add` すると、最後につないだコマとのズレ（dy）を行シグネチャの照合で探し、
/// 下へスクロールして新しく見えた行だけを帯として足していく。固定ヘッダ・フッタは最初に dy が決まった組で見つけ、照合から外す。
/// スレッド安全ではない（呼び出し側で 1 本のシリアルキューから使う）
final class ScrollStitcher {
    struct Options {
        /// 出力の高さの上限（ピクセル。ヘッダ＋本体＋フッタ）
        var maxHeight = 30000
        /// 照合から外す右端の幅（ピクセル。オーバーレイのスクロールバー）
        var ignoreRight = 32
        /// 一致とみなす、1 サンプルあたりの輝度の平均絶対誤差（0〜255）の上限
        var acceptScore: Float = 6
        /// 1 位と、離れた dy の 2 位の差がこれ未満なら「あいまい」として捨てる
        var ambiguityMargin: Float = 2
    }

    struct Outcome: Equatable {
        enum Kind: String {
            /// 最初のコマ
            case first
            /// つないだ
            case appended
            /// つないで、高さの上限に達した（以後は受け付けない）
            case limit
            /// 捨てた: 変化なし・上へのスクロール・一致が弱い・あいまい・大きさが違う・上限に達したあと
            case same, upward, weak, ambiguous, size, full
        }
        var kind: Kind
        var dy = 0
        var score: Float = -1
        var accepted: Bool { kind == .first || kind == .appended || kind == .limit }
    }

    let options: Options
    private(set) var frameCount = 0
    private(set) var isFull = false
    /// 固定ヘッダ・フッタの厚さ（ピクセル）。最初に dy が決まった組で決める。決まるまでは nil
    private(set) var header: Int?
    private(set) var footer: Int?

    private var first: PixelBuffer?
    private var last: PixelBuffer?
    private var lastSig: Signature?
    /// 2 枚目以降の、新しく見えた行（詰め物なし）
    private var strips: [PixelBuffer] = []
    private var stripRows = 0

    init(options: Options = Options()) {
        self.options = options
    }

    /// 今つないである画像の高さ（ピクセル）
    var height: Int { (first?.height ?? 0) + stripRows }

    func add(_ frame: PixelBuffer) -> Outcome {
        guard let last, let lastSig else {
            let sig = Signature(frame, ignoreRight: options.ignoreRight)
            first = frame
            self.last = frame
            self.lastSig = sig
            frameCount = 1
            isFull = frame.height >= options.maxHeight
            return Outcome(kind: .first)
        }
        guard !isFull else { return Outcome(kind: .full) }
        guard frame.width == last.width, frame.height == last.height else { return Outcome(kind: .size) }
        let sig = Signature(frame, ignoreRight: options.ignoreRight)
        let h = frame.height

        // 全部の行が同じ位置のまま変わらなければ、照合せずに捨てる（画面が止まっていてもコマは届き続ける）
        var t = 0
        while t < h, lastSig.sameRow(sig, t) { t += 1 }
        if t == h { return Outcome(kind: .same) }
        // 上端・下端の帯。決まっていなければ、この組で同じ位置のまま変わらない行を数える（それぞれ H/3 まで）
        let top: Int, bottom: Int
        if let header, let footer {
            top = header
            bottom = footer
        } else {
            var b = 0
            while b < h - t, lastSig.sameRow(sig, h - 1 - b) { b += 1 }
            top = min(t, h / 3)
            bottom = min(b, h / 3)
        }

        let m = match(lastSig, sig, top: top, bottom: bottom)
        guard m.kind == .appended else { return m }
        if header == nil {
            header = top
            footer = bottom
        }
        let dy = m.dy
        let allowed = options.maxHeight - height
        let take = min(dy, allowed)
        let end = h - bottom
        if take > 0 {
            strips.append(frame.rows((end - dy)..<(end - dy + take)))
            stripRows += take
        }
        self.last = frame
        self.lastSig = sig
        frameCount += 1
        if take < dy || height >= options.maxHeight {
            isFull = true
            return Outcome(kind: .limit, dy: dy, score: m.score)
        }
        return m
    }

    /// つないだ画像全体（ヘッダ＋本体＋フッタ）。コマが無ければ nil
    func compose() -> PixelBuffer? {
        guard let first else { return nil }
        return PixelBuffer.stacked(segments(), width: first.width)
    }

    /// 下端の `rows` 行だけ（ライブプレビュー用）
    func composeTail(rows: Int) -> PixelBuffer? {
        guard let first else { return nil }
        var need = max(1, rows)
        var parts: [(PixelBuffer, Range<Int>)] = []
        for (buf, range) in segments().reversed() where need > 0 {
            let n = min(need, range.count)
            parts.insert((buf, (range.upperBound - n)..<range.upperBound), at: 0)
            need -= n
        }
        return PixelBuffer.stacked(parts, width: first.width)
    }

    /// 上から順の区間: 最初のコマのヘッダ、最初のコマの本体、足した帯、最後につないだコマのフッタ
    private func segments() -> [(PixelBuffer, Range<Int>)] {
        guard let first, let last else { return [] }
        let h = first.height
        let top = header ?? 0, bottom = footer ?? 0
        var parts: [(PixelBuffer, Range<Int>)] = [(first, 0..<top), (first, top..<(h - bottom))]
        parts += strips.map { ($0, 0..<$0.height) }
        parts.append((last, (h - bottom)..<h))
        return parts.filter { !$0.1.isEmpty }
    }

    // MARK: - 照合

    /// 最後につないだコマ `a` と今のコマ `b` の本体（上端 `top`・下端 `bottom` を除いた行）で、一番よく一致する dy を探す。
    /// 行ごとの粗い特徴で候補を絞り、細かいシグネチャで確かめる
    private func match(_ a: Signature, _ b: Signature, top: Int, bottom: Int) -> Outcome {
        let body = a.rows - top - bottom
        let minOverlap = max(8, body / 8)
        let maxShift = body - minOverlap
        guard maxShift >= 1 else { return Outcome(kind: .weak) }

        var coarse: [(dy: Int, score: Float)] = []
        coarse.reserveCapacity(maxShift * 2 + 1)
        for dy in -maxShift...maxShift {
            coarse.append((dy, Self.difference(a.coarse, b.coarse, stride: Signature.coarseCount,
                                               aRow: top + max(dy, 0), bRow: top + max(-dy, 0), rows: body - abs(dy))))
        }
        coarse.sort { $0.score < $1.score }
        // 近い dy ばかりにならないよう、2px 以内のものは飛ばして候補を選ぶ
        var picked: [Int] = []
        for c in coarse where picked.count < 12 && !picked.contains(where: { abs($0 - c.dy) <= 2 }) {
            picked.append(c.dy)
        }
        let fine = picked.map { dy in
            (dy: dy, score: Self.difference(a.fine, b.fine, stride: a.samples,
                                            aRow: top + max(dy, 0), bRow: top + max(-dy, 0), rows: body - abs(dy)))
        }.sorted { $0.score < $1.score }
        guard let best = fine.first else { return Outcome(kind: .weak) }
        guard best.score <= options.acceptScore else { return Outcome(kind: .weak, dy: best.dy, score: best.score) }
        if let second = fine.dropFirst().first(where: { abs($0.dy - best.dy) > 2 }),
           second.score < best.score + options.ambiguityMargin {
            return Outcome(kind: .ambiguous, dy: best.dy, score: best.score)
        }
        if best.dy == 0 { return Outcome(kind: .same, score: best.score) }
        if best.dy < 0 { return Outcome(kind: .upward, dy: best.dy, score: best.score) }
        return Outcome(kind: .appended, dy: best.dy, score: best.score)
    }

    /// 行 `aRow` からの `rows` 行と、行 `bRow` からの `rows` 行の、1 サンプルあたりの平均絶対誤差
    private static func difference(_ a: [Float], _ b: [Float], stride: Int, aRow: Int, bRow: Int, rows: Int) -> Float {
        let n = rows * stride
        guard n > 0 else { return .infinity }
        var tmp = [Float](repeating: 0, count: n)
        var sum: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                vDSP_vsub(pb.baseAddress! + bRow * stride, 1, pa.baseAddress! + aRow * stride, 1, &tmp, 1, vDSP_Length(n))
            }
        }
        vDSP_svemg(tmp, 1, &sum, vDSP_Length(n))
        return sum / Float(n)
    }
}

/// 1 行ごとの輝度の並び（横に間引いたもの）と、それを 8 ブロックに平均した粗い特徴
private struct Signature {
    static let coarseCount = 8
    let rows: Int
    let samples: Int
    let fine: [Float]
    let coarse: [Float]

    init(_ f: PixelBuffer, ignoreRight: Int) {
        let usable = f.width - ignoreRight >= 16 ? f.width - ignoreRight : f.width
        let s = min(256, usable)
        let rowCount = f.height
        rows = rowCount
        samples = s
        var xs = [Int](repeating: 0, count: s)
        for i in 0..<s { xs[i] = min(usable - 1, usable * (2 * i + 1) / (2 * s)) }
        var fine = [Float](repeating: 0, count: rowCount * s)
        var coarse = [Float](repeating: 0, count: rowCount * Self.coarseCount)
        f.data.withUnsafeBufferPointer { d in
            for y in 0..<rowCount {
                let base = y * f.bytesPerRow
                var block = [Float](repeating: 0, count: Self.coarseCount)
                for i in 0..<s {
                    let p = base + xs[i] * 4
                    // BGRA
                    let v = 0.114 * Float(d[p]) + 0.587 * Float(d[p + 1]) + 0.299 * Float(d[p + 2])
                    fine[y * s + i] = v
                    block[i * Self.coarseCount / s] += v
                }
                let per = Float(s) / Float(Self.coarseCount)
                for k in 0..<Self.coarseCount { coarse[y * Self.coarseCount + k] = block[k] / per }
            }
        }
        self.fine = fine
        self.coarse = coarse
    }

    /// 同じ位置の行が（ほぼ）同じか。固定ヘッダ・フッタの帯を数えるのに使う
    func sameRow(_ other: Signature, _ y: Int) -> Bool {
        var sum: Float = 0
        for i in 0..<samples { sum += abs(fine[y * samples + i] - other.fine[y * samples + i]) }
        return sum / Float(samples) < 1.5
    }
}
