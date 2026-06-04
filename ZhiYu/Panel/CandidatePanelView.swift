import SwiftUI
import Combine

@MainActor
final class CandidatePanelModel: ObservableObject {
    @Published var isLoading = true
    @Published var status = ""
    @Published var candidates: [String] = []
    @Published var providerLabel = ""
    var onFill: (String) -> Void = { _ in }
    var onSend: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}
}

private let accentGradient = LinearGradient(
    colors: [Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.27, green: 0.79, blue: 0.96)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

struct CandidatePanelView: View {
    @ObservedObject var model: CandidatePanelModel
    @State private var appeared = false
    @State private var hoverIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            footer
        }
        .padding(14)
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
        )
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.45), radius: 26, y: 14)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { appeared = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(accentGradient).frame(width: 9, height: 9)
            Text("知语 · 候选回复").font(.headline)
            Spacer()
        }
    }

    @ViewBuilder private var content: some View {
        if model.isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("生成中…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        } else if model.candidates.isEmpty {
            Text(model.status.isEmpty ? "没有候选" : model.status)
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        } else {
            VStack(spacing: 8) {
                ForEach(Array(model.candidates.enumerated()), id: \.offset) { i, c in
                    card(index: i, text: c)
                }
            }
        }
    }

    private func card(index i: Int, text c: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(i + 1)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(accentGradient))
            Text(c)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture { model.onFill(c) }
            Button { model.onSend(c) } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(Circle().fill(accentGradient))
            }
            .buttonStyle(.plain)
            .help("填入并发送")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.white.opacity(hoverIndex == i ? 0.13 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    hoverIndex == i ? AnyShapeStyle(accentGradient) : AnyShapeStyle(.white.opacity(0.07)),
                    lineWidth: 1)
        )
        .shadow(color: hoverIndex == i ? .purple.opacity(0.25) : .clear, radius: 10, y: 4)
        .scaleEffect(hoverIndex == i ? 1.015 : 1.0)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(Double(i) * 0.06), value: appeared)
        .animation(.easeOut(duration: 0.14), value: hoverIndex)
        .onHover { inside in hoverIndex = inside ? i : (hoverIndex == i ? nil : hoverIndex) }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if !model.providerLabel.isEmpty {
                Circle().fill(accentGradient).frame(width: 5, height: 5)
                Text(model.providerLabel).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text("1·2·3 选中  ·  Esc 关闭").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }
}
