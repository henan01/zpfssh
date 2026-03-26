import SwiftUI

struct BroadcastBarView: View {
    @Binding var isVisible: Bool
    @ObservedObject var sessionManager: SessionManager
    @State private var inputText: String = ""
    @State private var showConfirm: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Target tabs selector
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sessionManager.tabs) { tab in
                        BroadcastTabChip(
                            tab: tab,
                            isSelected: sessionManager.broadcastTargetIDs.contains(tab.id),
                            onToggle: { sessionManager.toggleBroadcastTarget(tab) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Divider()

            // Input row
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.orange)
                    .font(.system(size: 13))

                Text("广播:")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .bold()

                TextField("输入命令，发送到所有选中标签页...", text: $inputText)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { sendBroadcast() }

                Button("发送") {
                    sendBroadcast()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)

                Button(action: { isVisible = false }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 6)
        .onAppear { isFocused = true }
        .alert("确认广播", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("发送", role: .destructive) {
                doBroadcast()
            }
        } message: {
            let targets = sessionManager.broadcastTargetIDs.count
            Text("将发送命令到 \(targets) 个标签页：\n\(inputText)")
        }
    }

    private func sendBroadcast() {
        let cmd = inputText.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        if AppSettings.shared.confirmBroadcast && sessionManager.broadcastTargetIDs.count > 1 {
            showConfirm = true
        } else {
            doBroadcast()
        }
    }

    private func doBroadcast() {
        sessionManager.broadcast(inputText)
        inputText = ""
    }
}

struct BroadcastTabChip: View {
    let tab: SessionTab
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Circle()
                    .fill(tab.isConnected ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text(tab.displayTitle)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.orange : Color.clear, lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
