import SwiftUI
import Combine

@MainActor
final class CandidatePanelModel: ObservableObject {
    @Published var isLoading = true
    @Published var status = ""
    @Published var candidates: [String] = []
    var onFill: (String) -> Void = { _ in }
    var onSend: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}
}

struct CandidatePanelView: View {
    @ObservedObject var model: CandidatePanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("生成中…") }
                    .padding(8)
            } else if model.candidates.isEmpty {
                Text(model.status.isEmpty ? "没有候选" : model.status)
                    .foregroundStyle(.secondary).padding(8)
            } else {
                ForEach(Array(model.candidates.enumerated()), id: \.offset) { i, c in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 14)
                        Text(c)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { model.onFill(c) }
                        Button("发送") { model.onSend(c) }
                    }
                    .padding(8)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .cornerRadius(8)
                }
            }
        }
        .padding(8)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
