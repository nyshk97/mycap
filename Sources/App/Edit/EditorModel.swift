import AppKit

/// 編集中の状態。描いた要素・選択・ツールバーの値・取り消しの履歴
final class EditorModel: ObservableObject {
    let source: URL
    let image: CGImage
    /// 画像のピクセル / ポイント（Retina の撮影なら 2）。ツールバーの太さ・大きさはポイントで見せ、要素にはピクセルで持つ
    let scale: CGFloat

    @Published var annotations: [Annotation] = [] { didSet { onChange?() } }
    @Published private(set) var selectedID: UUID? { didSet { onChange?() } }
    @Published var tool: Annotation.Kind = .arrow
    @Published private(set) var color = AnnotationColor.red
    /// 矢印の太さ（pt）
    @Published private(set) var arrowPt: Double = 6
    /// 四角の線の太さ（pt）
    @Published private(set) var rectPt: Double = 6
    /// 文字の大きさ（pt）
    @Published private(set) var textPt: Double = 24
    /// モザイクのブロックの一辺（pt）
    @Published private(set) var blockPt: Double = 10
    @Published private(set) var font = AnnotationFont.gothicBold
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// 描き直しが要るとき（キャンバスが受ける）
    var onChange: (() -> Void)?
    var onSave: (() -> Void)?

    private var history = AnnotationHistory()
    /// スライダーを動かし始めたときの要素（離したときに 1 回分の取り消しとして積む）
    private var sliderBefore: [Annotation]?

    init(source: URL, image: CGImage, scale: CGFloat) {
        self.source = source
        self.image = image
        self.scale = scale
    }

    var isDirty: Bool { !annotations.isEmpty }
    var undoDepth: Int { history.undoStack.count }

    var selected: Annotation? { annotations.first { $0.id == selectedID } }

    /// ツールバーが今どの種類の値を見せるか。選んでいる要素があればその種類
    var contextKind: Annotation.Kind { selected?.kind ?? tool }

    // MARK: - 要素

    func newAnnotation(at p: CGPoint) -> Annotation {
        let size: Double
        switch tool {
        case .arrow: size = arrowPt * scale
        case .rect: size = rectPt * scale
        case .mosaic: size = blockPt * scale
        case .text: size = textPt * scale
        }
        return Annotation(kind: tool, start: p, end: p, color: color, size: size, font: font)
    }

    func update(_ id: UUID, _ change: (inout Annotation) -> Void) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&annotations[i])
    }

    func remove(_ id: UUID) {
        annotations.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    /// 選ぶと、ツールバーの値をその要素に合わせる（続けて描くものも同じ見た目になる）
    func select(_ id: UUID?) {
        selectedID = id
        guard let a = selected else { return }
        tool = a.kind
        switch a.kind {
        case .arrow:
            color = a.color
            arrowPt = a.size / scale
        case .rect:
            color = a.color
            rectPt = a.size / scale
        case .mosaic:
            blockPt = a.size / scale
        case .text:
            color = a.color
            textPt = a.size / scale
            font = a.font
        }
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        let before = annotations
        remove(id)
        commit(before: before)
    }

    /// 変更をひとまとまりとして取り消しの履歴に積む（変わっていなければ積まない）
    func commit(before: [Annotation]) {
        guard before != annotations else { return }
        history.record(before)
        refreshUndoFlags()
    }

    func undo() {
        guard let prev = history.undo(annotations) else { return }
        annotations = prev
        if selected == nil { selectedID = nil }
        refreshUndoFlags()
    }

    func redo() {
        guard let next = history.redo(annotations) else { return }
        annotations = next
        if selected == nil { selectedID = nil }
        refreshUndoFlags()
    }

    private func refreshUndoFlags() {
        canUndo = !history.undoStack.isEmpty
        canRedo = !history.redoStack.isEmpty
    }

    // MARK: - ツールバー（選んでいる要素があればそれにも効く）

    func setColor(_ c: AnnotationColor) {
        color = c
        applyToSelected { if $0.kind != .mosaic { $0.color = c } }
    }

    func setFont(_ f: AnnotationFont) {
        font = f
        applyToSelected { if $0.kind == .text { $0.font = f } }
    }

    /// スライダーの値（pt）。今の種類に応じて太さ・文字の大きさ・ブロックのどれか
    var sizePt: Double {
        get {
            switch contextKind {
            case .arrow: arrowPt
            case .rect: rectPt
            case .mosaic: blockPt
            case .text: textPt
            }
        }
        set {
            let kind = contextKind
            switch kind {
            case .arrow: arrowPt = newValue
            case .rect: rectPt = newValue
            case .mosaic: blockPt = newValue
            case .text: textPt = newValue
            }
            let px = newValue * scale
            if let id = selectedID {
                update(id) { $0.size = px }
            }
        }
    }

    static func sizeRange(_ kind: Annotation.Kind) -> ClosedRange<Double> {
        switch kind {
        case .arrow, .rect: 1...20
        case .mosaic: 4...40
        case .text: 10...120
        }
    }

    func sliderEditing(_ editing: Bool) {
        if editing {
            sliderBefore = annotations
        } else if let before = sliderBefore {
            commit(before: before)
            sliderBefore = nil
        }
    }

    private func applyToSelected(_ change: (inout Annotation) -> Void) {
        guard let id = selectedID else { return }
        let before = annotations
        update(id, change)
        commit(before: before)
    }
}
