import SwiftUI

/// キャプチャ履歴パネルの中身。上にタブ、下に新しい順の横並び
struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    static let thumbSize = CGSize(width: 180, height: 112)

    var body: some View {
        VStack(spacing: 10) {
            tabs
            if model.items.isEmpty {
                Spacer()
                Text(model.kind == .screenshots ? "No screenshots in the last 7 days" : "No videos in the last 7 days")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                strip
            }
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(CaptureHistory.Kind.allCases, id: \.self) { kind in
                let selected = model.kind == kind
                Button { model.select(kind) } label: {
                    Text(kind.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 28) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        HistoryCell(item: item, thumb: model.thumbs[item.id], duration: model.durations[item.id],
                                    age: CaptureHistory.relativeAge(model.now.timeIntervalSince(item.created)),
                                    focused: model.focus == index,
                                    onHover: { model.hover(index) },
                                    onRestore: { model.restore(index) })
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 6)
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }
}

private struct HistoryCell: View {
    let item: HistoryItem
    let thumb: NSImage?
    let duration: TimeInterval?
    let age: String
    let focused: Bool
    let onHover: () -> Void
    let onRestore: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                picture
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 30, height: 30)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: 8, y: 6)
                }
            }
            .frame(width: HistoryView.thumbSize.width, height: HistoryView.thumbSize.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onRestore)

            ZStack {
                if focused {
                    Button(action: onRestore) {
                        Label("Restore", systemImage: "return")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(age)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 26)
        }
        .onHover { if $0 { onHover() } }
    }

    private var picture: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35))
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let duration {
                HStack(spacing: 5) {
                    Image(systemName: "video.fill")
                    Text(CaptureHistory.durationLabel(duration))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(7)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(focused ? Color.accentColor : Color.white.opacity(0.12), lineWidth: focused ? 3 : 1)
        )
    }
}
