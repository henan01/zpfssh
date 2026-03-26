import SwiftUI

struct TabBarView: View {
    @ObservedObject var sessionManager: SessionManager
    var onNewTab: () -> Void

    @State private var renamingTabID: UUID? = nil
    @State private var renameText: String = ""

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(sessionManager.tabs) { tab in
                        TabItemView(
                            tab: tab,
                            isActive: sessionManager.activeTabID == tab.id,
                            isBroadcastTarget: sessionManager.broadcastTargetIDs.contains(tab.id),
                            isBroadcastMode: sessionManager.isBroadcastMode,
                            isRenaming: renamingTabID == tab.id,
                            renameText: $renameText,
                            onActivate: { sessionManager.activateTab(tab) },
                            onClose: { sessionManager.closeTab(tab) },
                            onDuplicate: { sessionManager.duplicateTab(tab) },
                            onRenameStart: {
                                renamingTabID = tab.id
                                renameText = tab.displayTitle
                            },
                            onRenameCommit: {
                                if renameText.isEmpty {
                                    sessionManager.resetTabTitle(tab)
                                } else {
                                    sessionManager.renameTab(tab, title: renameText)
                                }
                                renamingTabID = nil
                            },
                            onRenameCancel: { renamingTabID = nil },
                            onResetTitle: { sessionManager.resetTabTitle(tab) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            Divider().frame(height: 20)

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 13))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("新建连接 (⌘T)")
        }
        .frame(height: 36)
        .background(.regularMaterial)
    }
}

struct TabItemView: View {
    @ObservedObject var tab: SessionTab
    let isActive: Bool
    let isBroadcastTarget: Bool
    let isBroadcastMode: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    var onActivate: () -> Void
    var onClose: () -> Void
    var onDuplicate: () -> Void
    var onRenameStart: () -> Void
    var onRenameCommit: () -> Void
    var onRenameCancel: () -> Void
    var onResetTitle: () -> Void

    @FocusState private var renameFocused: Bool
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            if isBroadcastMode && isBroadcastTarget {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }

            if isRenaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($renameFocused)
                    .frame(minWidth: 60, maxWidth: 150)
                    .onSubmit { onRenameCommit() }
                    .onAppear { renameFocused = true }
                    .onExitCommand { onRenameCancel() }
            } else {
                Text(tab.displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .frame(maxWidth: 140)
            }

            if (isHovered || isActive) && !isRenaming {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                      ? Color.accentColor.opacity(0.15)
                      : (isHovered ? Color.secondary.opacity(0.1) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isBroadcastMode && isBroadcastTarget
                        ? Color.orange
                        : (isActive ? Color.accentColor.opacity(0.4) : Color.clear),
                    lineWidth: isBroadcastMode && isBroadcastTarget ? 1.5 : 1
                )
        )
        .onHover { isHovered = $0 }
        // Double tap must be declared first so SwiftUI waits for the second tap
        // before falling through to single-tap.
        .onTapGesture(count: 2) { onDuplicate() }
        .onTapGesture(count: 1) { onActivate() }
        .contextMenu {
            Button("复制标签页（新连接）") { onDuplicate() }
            Button("重命名") { onRenameStart() }
            Button("恢复自动标题") { onResetTitle() }
            Divider()
            Button("关闭", role: .destructive) { onClose() }
        }
    }

    var statusColor: Color {
        tab.isConnected ? .green : .gray
    }
}
