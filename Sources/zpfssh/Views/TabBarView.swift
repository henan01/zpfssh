import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tab Bar

struct TabBarView: View {
    @ObservedObject var sessionManager: SessionManager
    var onNewTab: () -> Void

    @State private var renamingTabID: UUID? = nil
    @State private var renameText: String = ""

    var hasSplit: Bool { sessionManager.splitTabID != nil }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(sessionManager.tabs) { tab in
                        TabItemView(
                            tab: tab,
                            isActive: sessionManager.activeTabID == tab.id,
                            isSplitPane: sessionManager.splitTabID == tab.id,
                            isBroadcastTarget: sessionManager.broadcastTargetIDs.contains(tab.id),
                            isBroadcastMode: sessionManager.isBroadcastMode,
                            isRenaming: renamingTabID == tab.id,
                            renameText: $renameText,
                            onActivate: { sessionManager.activateTab(tab) },
                            onClose: { sessionManager.closeTab(tab) },
                            onDuplicate: { sessionManager.duplicateTab(tab) },
                            onSplitPane: { sessionManager.setSplitTab(tab) },
                            onCloseSplit: { sessionManager.closeSplit() },
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

            // ── Split Drop Zone ──────────────────────────────────────────────────
            // This zone lives entirely in SwiftUI (no AppKit view underneath), so
            // onDrop is reliable. Drag any tab's handle (≡) onto this area to open
            // a cross-tab split view. The zone is always visible; it highlights when
            // a tab is dragged over it.
            SplitDropZone(sessionManager: sessionManager, hasSplit: hasSplit)

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

// MARK: - Split Drop Zone

/// A drop target in the tab bar that accepts dragged tab items.
/// Placed here (pure SwiftUI) so it's never obscured by the AppKit terminal views.
private struct SplitDropZone: View {
    @ObservedObject var sessionManager: SessionManager
    let hasSplit: Bool
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: hasSplit
                  ? "rectangle.split.2x1.fill"
                  : "rectangle.split.2x1")
                .font(.system(size: 11))
                .foregroundColor(isTargeted ? .accentColor
                                 : (hasSplit ? .accentColor.opacity(0.7) : .secondary.opacity(0.45)))

            if isTargeted {
                Text("松开分屏")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.accentColor)
            } else if !hasSplit {
                Text("分屏")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.8))
            } else if hasSplit {
                Button(action: { sessionManager.closeSplit() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭分屏（两个 Tab 连接都保留）")
            }
        }
        .frame(height: 36)
        .padding(.horizontal, isTargeted ? 10 : 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isTargeted
                      ? Color.accentColor.opacity(0.12)
                      : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.22),
                    lineWidth: isTargeted ? 1.5 : 1
                )
        )
        .animation(.easeInOut(duration: 0.12), value: isTargeted)
        .onDrop(of: [.text, .plainText], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                guard let str = item as? String,
                      str.hasPrefix("TABSPLIT:"),
                      let uuid = UUID(uuidString: String(str.dropFirst(9))),
                      let tab = sessionManager.tabs.first(where: { $0.id == uuid })
                else { return }
                DispatchQueue.main.async {
                    sessionManager.setSplitTab(tab)
                }
            }
            return true
        }
        .frame(minWidth: 84)
        .layoutPriority(2)
        .help(hasSplit ? "已分屏 · 将另一个标签拖到此处可替换右侧" : "将标签拖到此处进行分屏")
    }
}

// MARK: - Tab Item

struct TabItemView: View {
    @ObservedObject var tab: SessionTab
    let isActive: Bool
    let isSplitPane: Bool
    let isBroadcastTarget: Bool
    let isBroadcastMode: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    var onActivate: () -> Void
    var onClose: () -> Void
    var onDuplicate: () -> Void
    var onSplitPane: () -> Void
    var onCloseSplit: () -> Void
    var onRenameStart: () -> Void
    var onRenameCommit: () -> Void
    var onRenameCancel: () -> Void
    var onResetTitle: () -> Void

    @FocusState private var renameFocused: Bool
    @State private var isHovered: Bool = false
    private var splitDragPayload: NSItemProvider {
        // "TABSPLIT:" prefix distinguishes tab drags from pane-swap drags.
        NSItemProvider(object: "TABSPLIT:\(tab.id.uuidString)" as NSString)
    }

    var body: some View {
        HStack(spacing: 4) {
            // ── Drag handle ─────────────────────────────────────────────────────
            // Isolating drag to its own subview prevents conflict with onTapGesture.
            // On macOS, placing .onDrag on the full tab row competes with tap detection;
            // a dedicated handle removes this ambiguity entirely.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundColor(isHovered ? .secondary.opacity(0.55) : .clear)
                .frame(width: 12)
                .onDrag {
                    splitDragPayload
                }
                .cursor(.openHand)
                .help("拖到右侧分屏区进行分屏")

            // ── Status dot ──────────────────────────────────────────────────────
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            // ── Badges ──────────────────────────────────────────────────────────
            if isSplitPane {
                Image(systemName: "rectangle.righthalf.inset.filled")
                    .font(.system(size: 9))
                    .foregroundColor(.purple.opacity(0.8))
            }

            if isBroadcastMode && isBroadcastTarget {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }

            // ── Title / rename field ─────────────────────────────────────────────
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

            // ── Close button ─────────────────────────────────────────────────────
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                      ? Color.accentColor.opacity(0.15)
                      : (isSplitPane ? Color.purple.opacity(0.08)
                         : (isHovered ? Color.secondary.opacity(0.1) : Color.clear)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isBroadcastMode && isBroadcastTarget
                        ? Color.orange
                        : (isSplitPane
                           ? Color.purple.opacity(0.45)
                           : (isActive ? Color.accentColor.opacity(0.4) : Color.clear)),
                    lineWidth: (isBroadcastMode && isBroadcastTarget) || isSplitPane ? 1.5 : 1
                )
        )
        .onHover { isHovered = $0 }
        .onTapGesture { onActivate() }
        .onDrag {
            splitDragPayload
        }
        .contextMenu {
            // Show split option on any non-active, non-split tab
            if !isActive {
                if isSplitPane {
                    Button("关闭分屏（保留两个标签）") { onCloseSplit() }
                } else {
                    Button("向右分屏显示此标签") { onSplitPane() }
                }
                Divider()
            }
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
