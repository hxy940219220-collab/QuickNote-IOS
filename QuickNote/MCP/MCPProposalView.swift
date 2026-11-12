import SwiftUI

struct MCPProposalInbox: View {
    @ObservedObject var store: MCPProposalStore
    let service: NoteMCPService
    let prepareFocus: () -> Void
    let restoreFocus: () -> Void
    @State private var reviewed: MCPProposalCard?

    var body: some View {
        VStack(spacing: 0) {
            if let first = store.pending.first {
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("待确认写入 · \(store.pending.count)")
                            .font(.system(size: 12, weight: .semibold))
                        Text(first.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("查看") {
                        prepareFocus()
                        reviewed = first
                    }
                    .controlSize(.small)
                    .accessibilityLabel("查看写入提议")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 12)
            }
        }
        .sheet(item: $reviewed, onDismiss: restoreFocus) { proposal in
            MCPProposalReview(store: store, service: service, id: proposal.id)
        }
    }
}

private struct MCPProposalReview: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MCPProposalStore
    let service: NoteMCPService
    let id: UUID
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认写入提议").font(.system(size: 17, weight: .semibold))
            Divider()
            if let card = store.pending.first(where: { $0.id == id }) {
                Text("来自 \(card.client)").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(card.title).font(.system(size: 14, weight: .semibold))
                Text(card.location).font(.system(size: 12)).foregroundStyle(.secondary)
                ScrollView {
                    Text(verbatim: card.markdown)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 75, maxHeight: 200)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                if let notice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("拒绝") {
                        service.rejectProposal(id)
                        dismiss()
                    }
                    Button("确认写入") {
                        do {
                            try service.confirmProposal(id)
                            dismiss()
                        } catch {
                            notice = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text(notice ?? "这条提议已处理或过期。")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("完成") { dismiss() }
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .onExitCommand { dismiss() }
    }
}
