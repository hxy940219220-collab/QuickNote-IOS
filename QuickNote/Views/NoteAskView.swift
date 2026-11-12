import SwiftUI

struct NoteAskView: View {
    @ObservedObject var controller: NoteAskController
    let answerQuestion: () -> Void
    let openCitation: (NoteAskEvidence) -> Void
    @State private var showsSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            if controller.isIndexBuilding {
                status("索引建立中，结果可能不完整", id: "ask.indexBuilding")
            }
            if let notice = controller.indexMode?.notice {
                status(notice, id: "ask.indexMode")
            }
            if controller.isWaitingForAnswer {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    status(controller.waitingMessage, id: "ask.waiting")
                }
            }
            if let notice = controller.notice {
                status(notice, id: "ask.notice")
            }
            ViewThatFits(in: .vertical) {
                answerContent.fixedSize(horizontal: false, vertical: true)
                ScrollViewReader { proxy in
                    ScrollView { answerContent.id("ask.contentTop") }
                        .onChange(of: controller.answer.isEmpty) { _, isEmpty in
                            if !isEmpty { proxy.scrollTo("ask.contentTop", anchor: .top) }
                        }
                }
            }
        }
        .onChange(of: shouldRevealSources, initial: true) { _, shouldShow in
            if shouldShow { showsSources = true }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Picker("回答模型", selection: Binding(
                get: { controller.destination },
                set: { controller.setDestination($0) }
            )) {
                Text("按设置").tag(NoteAskDestination.configured)
                Text("本机").tag(NoteAskDestination.local)
                Text("云端").tag(NoteAskDestination.cloud)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("ask.destinationPicker")

            Text(controller.destinationName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(controller.destinationName)
                .accessibilityIdentifier("ask.destination")
                .frame(maxWidth: .infinity, alignment: .leading)

            if controller.isRetrieving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在检索")
            }
            if controller.isLoading {
                Button("停止", action: controller.stop)
                    .controlSize(.small)
                    .accessibilityIdentifier("ask.stop")
            } else {
                Button(controller.answer.isEmpty ? "回答" : "重新回答", action: answerQuestion)
                    .controlSize(.small)
                    .disabled(!controller.canAnswer)
                    .accessibilityIdentifier("ask.answerAction")
            }
        }
    }

    private var answerContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !controller.answer.isEmpty {
                Text(linkedAnswer)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "quicknote-ask-citation", let host = url.host,
                              let number = Int(host),
                              let evidence = controller.evidence.first(where: { $0.number == number }) else {
                            return .discarded
                        }
                        openCitation(evidence)
                        return .handled
                    })
                    .accessibilityIdentifier("ask.answer")
            }
            if !controller.evidence.isEmpty {
                sourceDisclosure
                ForEach(visibleEvidence) { evidence in
                    sourceRow(evidence)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleEvidence: [NoteAskEvidence] {
        if showsSources { return controller.evidence }
        let byNumber = Dictionary(uniqueKeysWithValues: controller.evidence.map { ($0.number, $0) })
        return controller.citedNumbers.compactMap { byNumber[$0] }
    }

    private var shouldRevealSources: Bool {
        !controller.evidence.isEmpty && (!controller.isModelAvailable ||
            controller.notice?.contains("未能标注出处") == true ||
            (!controller.isLoading && !controller.answer.isEmpty && controller.citedNumbers.isEmpty))
    }

    private var sourceDisclosure: some View {
        let count = Set(controller.evidence.map { $0.chunk.noteID }).count
        return Button { showsSources.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: showsSources ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                Text("参考了 \(count) 条便签")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showsSources ? "收起检索片段" : "展开检索片段")
        .accessibilityIdentifier("ask.sources")
    }

    private func sourceRow(_ evidence: NoteAskEvidence) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button { openCitation(evidence) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("[\(evidence.number)]")
                            .foregroundStyle(.tint)
                        Text(evidence.chunk.title)
                            .fontWeight(.semibold)
                        Spacer(minLength: 3)
                        Text(evidence.location)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .lineLimit(1)
                    Text(evidence.chunk.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(showsSources ? nil : 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .quickNoteHoverHighlight(cornerRadius: 5)
            .accessibilityIdentifier("ask.reference.\(evidence.number)")

            Button { controller.removeNote(evidence.chunk.noteID) } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("移除这条便签的片段")
            .accessibilityLabel("移除\(evidence.chunk.title)")
            .accessibilityIdentifier("ask.remove.\(evidence.number)")
        }
    }

    private func status(_ message: String, id: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(id)
    }

    private var linkedAnswer: AttributedString {
        let cited = Set(controller.citedNumbers)
        guard !cited.isEmpty else { return AttributedString(controller.answer) }
        var remaining = controller.answer[...]
        var result = AttributedString()
        while let range = remaining.range(of: #"\[[0-9]+\]"#, options: .regularExpression) {
            result.append(AttributedString(String(remaining[..<range.lowerBound])))
            let marker = remaining[range]
            var citation = AttributedString(String(marker))
            if let number = Int(marker.dropFirst().dropLast()), cited.contains(number) {
                citation.link = URL(string: "quicknote-ask-citation://\(number)")
            }
            result.append(citation)
            remaining = remaining[range.upperBound...]
        }
        result.append(AttributedString(String(remaining)))
        return result
    }
}
