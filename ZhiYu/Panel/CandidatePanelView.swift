import SwiftUI
import Combine
import ZhiYuCore

@MainActor
final class CandidatePanelModel: ObservableObject {
    @Published var isLoading = true
    @Published var loadingNote = "生成中…"
    @Published var status = ""
    @Published var candidates: [String] = []
    @Published var stickerKeyword: String? = nil
    @Published var providerLabel = ""
    var onFill: (String) -> Void = { _ in }
    var onSend: (String) -> Void = { _ in }
    var onSendSticker: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}
}

struct CandidatePanelView: View {
    /// 卡片四周的透明外边距：给阴影留出渲染空间，避免在直角透明窗口的四角被裁成色块。
    /// 控制器据此补偿定位与高度，所以面板视觉位置不变。需 ≥ 阴影外扩范围(radius+|y|)。
    static let shadowPad: CGFloat = 20

    /// 面板内容宽度（不含 shadowPad）。控制器测高/定位时按此计算窗口宽度，故须与此处 frame 同源。
    static let baseWidth: CGFloat = 440

    /// 候选卡片圆角。
    private static let cardCornerRadius: CGFloat = 13
    /// 候选卡片底色不透明度：(默认, 悬停)。
    private static let cardFillOpacity: (normal: Double, hover: Double) = (0.05, 0.12)
    /// 候选卡片描边不透明度：(默认, 悬停)。
    private static let cardStrokeOpacity: (normal: Double, hover: Double) = (0.07, 0.22)

    @ObservedObject var model: CandidatePanelModel
    @State private var appeared = false
    @State private var hoverIndex: Int? = nil
    var scrollable: Bool = false
    var maxHeight: CGFloat = .greatestFiniteMagnitude

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            stickerSuggestion
            footer
        }
        .padding(14)
        .frame(width: Self.baseWidth)
        .frame(maxHeight: scrollable ? maxHeight : nil)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.62))
                )
        )
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .padding(Self.shadowPad)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { appeared = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.white.opacity(0.55)).frame(width: 7, height: 7)
            Text("知语 · 候选回复").font(.headline).foregroundStyle(.white.opacity(0.92))
            Spacer()
        }
    }

    @ViewBuilder private var content: some View {
        if model.isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.loadingNote).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        } else if model.candidates.isEmpty {
            Text(model.status.isEmpty ? "没有候选" : model.status)
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        } else {
            let list = VStack(spacing: 8) {
                ForEach(Array(model.candidates.enumerated()), id: \.offset) { i, c in
                    card(index: i, text: c)
                }
            }
            if scrollable {
                ScrollView { list }
            } else {
                list
            }
        }
    }

    private func card(index i: Int, text c: String) -> some View {
        let bubbles = BubbleSplitter.split(c)
        return HStack(alignment: .top, spacing: 10) {
            Text("\(i + 1)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.15)))
            VStack(alignment: .leading, spacing: 5) {
                if bubbles.count > 1 {
                    ForEach(Array(bubbles.enumerated()), id: \.offset) { _, b in
                        Text(b)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.95))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(.white.opacity(0.06)))
                    }
                } else {
                    Text(bubbles.first ?? c)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.onFill(c) }
            Button { model.onSend(c) } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(7)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("填入并发送")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                .fill(.white.opacity(hoverIndex == i ? Self.cardFillOpacity.hover : Self.cardFillOpacity.normal))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(hoverIndex == i ? Self.cardStrokeOpacity.hover : Self.cardStrokeOpacity.normal), lineWidth: 1)
        )
        .scaleEffect(hoverIndex == i ? 1.012 : 1.0)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(Double(i) * 0.06), value: appeared)
        .animation(.easeOut(duration: 0.14), value: hoverIndex)
        .onHover { inside in hoverIndex = inside ? i : (hoverIndex == i ? nil : hoverIndex) }
    }

    @ViewBuilder private var stickerSuggestion: some View {
        if let kw = model.stickerKeyword, !kw.isEmpty {
            Button { model.onSendSticker(kw) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("发表情：\(kw)")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("用微信表情搜索发出第一个结果")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if !model.providerLabel.isEmpty {
                Circle().fill(Color.white.opacity(0.4)).frame(width: 5, height: 5)
                Text(model.providerLabel).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text("1·2·3 选中  ·  Esc 关闭").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }
}
