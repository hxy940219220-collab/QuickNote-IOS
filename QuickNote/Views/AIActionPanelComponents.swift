import SwiftUI

struct AIResultDestination: Identifiable, Equatable {
    let id: UUID?
    let title: String

    static let newNote = Self(id: nil, title: "新便签")
}

struct AIPanelQuestionField: View {
    let placeholder: String
    @Binding var text: String
    let canSubmit: Bool
    let sendLabel: String
    let submit: () -> Void
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: 5) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isEditing)
                .onSubmit { if canSubmit { submit() } }
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!canSubmit)
            .accessibilityLabel(sendLabel)
            .help(sendLabel)
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isEditing ? Color.accentColor : Color(nsColor: .separatorColor))
                .allowsHitTesting(false)
        }
    }
}

struct AIHelpButton: View {
    let title: String
    let message: String
    @Binding var isPresented: Bool
    var symbol = "info.circle"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var hasFocus: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .focused($hasFocus)
        .accessibilityLabel(title)
        .accessibilityIdentifier("ai-help")
        .help(title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
                .accessibilityIdentifier("ai-help-message")
                .onExitCommand { isPresented = false }
        }
        .onChange(of: isPresented) { wasPresented, presented in
            if wasPresented && !presented { hasFocus = true }
        }
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
    }
}

struct AIResultFooter: View {
    let destinationTitle: String
    let imported: Bool
    let canStore: Bool
    let partial: Bool
    let destinations: [AIResultDestination]
    let provider: String
    let deliveryNotice: String
    @Binding var showsHelp: Bool
    let selectDestination: (AIResultDestination) -> Void
    let store: () -> Void

    private var storeTitle: String { imported ? "已存入" : "存入 \(destinationTitle)" }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Button(action: store) {
                    Text(storeTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 25)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(storeTitle)
                .help(partial && !imported ? "存入当前已生成的部分结果" : storeTitle)
                if !imported {
                    Rectangle()
                        .fill(.white.opacity(0.4))
                        .frame(width: 1, height: 13)
                        .accessibilityHidden(true)
                    Menu {
                        ForEach([AIResultDestination.newNote] + destinations) { destination in
                            Button(String(destination.title.prefix(48))) { selectDestination(destination) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 25)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("更换存入目标")
                    .help("更换存入目标")
                }
            }
            .foregroundStyle(canStore ? Color.white : Color.secondary)
            .background(canStore ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
            .disabled(!canStore)
            .layoutPriority(1)

            Spacer(minLength: 2)
            if !provider.isEmpty {
                Text(provider == CodexLocalPreferences.destinationName ? "Codex" : provider)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !deliveryNotice.isEmpty {
                AIHelpButton(title: "发送范围与处理来源", message: deliveryNotice, isPresented: $showsHelp)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
