import SwiftUI

struct BroadcastBarView: View {
    @Binding var isVisible: Bool
    @ObservedObject var sessionManager: SessionManager
    @State private var inputText: String = ""
    @State private var showConfirm: Bool = false
    @State private var showTargets: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Collapsible target selector
            if showTargets {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(sessionManager.tabs) { tab in
                            BroadcastTabChip(
                                tab: tab,
                                isSelected: sessionManager.broadcastTargetIDs.contains(tab.id),
                                onToggle: { sessionManager.toggleBroadcastTarget(tab) }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }

                Divider()
            }

            // Input row
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.orange)
                    .font(.system(size: 12))

                TextField("广播命令...", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isFocused)
                    .onSubmit { sendBroadcast() }

                // Toggle target list
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showTargets.toggle() } }) {
                    Image(systemName: showTargets ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(showTargets ? "收起目标列表" : "展开目标列表")

                Button("发送") {
                    sendBroadcast()
                }
                .font(.system(size: 11))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)

                Button(action: { isVisible = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .padding(.bottom, 2)
        }
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
                    .frame(width: 5, height: 5)
                Text(tab.displayTitle)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isSelected ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.orange : Color.clear, lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
