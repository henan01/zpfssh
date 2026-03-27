import SwiftUI
import UniformTypeIdentifiers

private let tabUTType = UTType(exportedAs: "com.zpfssh.tab-id")

// MARK: - Tab Bar

struct TabBarView: View {
    @ObservedObject var sessionManager: SessionManager
    var onNewTab: () -> Void

    @State private var renamingTabID: UUID? = nil
    @State private var renameText: String = ""

    var hasSplit: Bool { sessionManager.splitTabID != nil }

    @State private var dragOverTabID: UUID? = nil

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
                            isDragOver: dragOverTabID == tab.id,
                            renameText: $renameText,
                            onActivate: { sessionManager.activateTab(tab) },
                            onClose: { sessionManager.closeTab(tab) },
                            onDuplicate: { sessionManager.duplicateTab(tab) },
                            onSplitTab: { direction, placeFirst in
                                if placeFirst {
                                    // This tab goes to primary (left/top), current active becomes secondary
                                    let oldActiveID = sessionManager.activeTabID
                                    sessionManager.activeTabID = tab.id
                                    sessionManager.splitDirection = direction
                                    sessionManager.splitTabID = oldActiveID
                                } else {
                                    sessionManager.setSplitTab(tab, direction: direction)
                                }
                            },
                            onSplitFocusedPane: { direction, placeFirst in
                                if let activeTab = sessionManager.activeTab {
                                    activeTab.splitPane(
                                        activeTab.focusedPaneID,
                                        direction: direction,
                                        with: activeTab.server,
                                        placeNewFirst: placeFirst
                                    )
                                }
                            },
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
                        .onDrop(of: [tabUTType], delegate: TabReorderDropDelegate(
                            targetTab: tab,
                            sessionManager: sessionManager,
                            dragOverTabID: $dragOverTabID
                        ))
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
        .onDrop(of: [tabUTType], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: tabUTType.identifier) { data, _ in
                guard let data,
                      let payload = String(data: data, encoding: .utf8),
                      payload.hasPrefix("TAB:"),
                      let uuid = UUID(uuidString: String(payload.dropFirst(4))),
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
    var isDragOver: Bool = false
    @Binding var renameText: String
    var onActivate: () -> Void
    var onClose: () -> Void
    var onDuplicate: () -> Void
    /// Cross-tab split: direction + placeFirst (true = this tab goes left/top)
    var onSplitTab: ((SplitDirection, Bool) -> Void)? = nil
    /// Pane split within active tab: direction + placeFirst
    var onSplitFocusedPane: ((SplitDirection, Bool) -> Void)? = nil
    var onCloseSplit: () -> Void
    var onRenameStart: () -> Void
    var onRenameCommit: () -> Void
    var onRenameCancel: () -> Void
    var onResetTitle: () -> Void

    @FocusState private var renameFocused: Bool
    @State private var isHovered: Bool = false

    private var tabDragPayload: NSItemProvider {
        let provider = NSItemProvider()
        let payload = "TAB:\(tab.id.uuidString)"
        provider.registerDataRepresentation(
            forTypeIdentifier: tabUTType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(payload.data(using: .utf8), nil)
            return nil
        }
        return provider
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundColor(isHovered ? .secondary.opacity(0.55) : .clear)
                .frame(width: 12)
                .cursor(.openHand)

            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(tabBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(tabBorderColor, lineWidth: tabBorderWidth)
        )
        .onHover { isHovered = $0 }
        .onTapGesture { onActivate() }
        .onDrag { tabDragPayload }
        .contextMenu {
            if !isActive {
                if isSplitPane {
                    Button("关闭分屏（保留两个标签）") { onCloseSplit() }
                } else {
                    Menu("分屏显示此标签") {
                        Button {
                            onSplitTab?(.horizontal, true)
                        } label: {
                            Label("向左分屏", systemImage: "rectangle.lefthalf.inset.filled")
                        }
                        Button {
                            onSplitTab?(.horizontal, false)
                        } label: {
                            Label("向右分屏", systemImage: "rectangle.righthalf.inset.filled")
                        }
                        Button {
                            onSplitTab?(.vertical, true)
                        } label: {
                            Label("向上分屏", systemImage: "rectangle.tophalf.inset.filled")
                        }
                        Button {
                            onSplitTab?(.vertical, false)
                        } label: {
                            Label("向下分屏", systemImage: "rectangle.bottomhalf.inset.filled")
                        }
                    }
                }
                Divider()
            }

            if isActive {
                Menu("拆分当前窗格") {
                    Button {
                        onSplitFocusedPane?(.horizontal, true)
                    } label: {
                        Label("向左拆分", systemImage: "rectangle.lefthalf.inset.filled")
                    }
                    Button {
                        onSplitFocusedPane?(.horizontal, false)
                    } label: {
                        Label("向右拆分", systemImage: "rectangle.righthalf.inset.filled")
                    }
                    Button {
                        onSplitFocusedPane?(.vertical, true)
                    } label: {
                        Label("向上拆分", systemImage: "rectangle.tophalf.inset.filled")
                    }
                    Button {
                        onSplitFocusedPane?(.vertical, false)
                    } label: {
                        Label("向下拆分", systemImage: "rectangle.bottomhalf.inset.filled")
                    }
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

    private var tabBackground: Color {
        if isDragOver { return Color.accentColor.opacity(0.2) }
        if isActive { return Color.accentColor.opacity(0.15) }
        if isSplitPane { return Color.purple.opacity(0.08) }
        if isHovered { return Color.secondary.opacity(0.1) }
        return Color.clear
    }

    private var tabBorderColor: Color {
        if isDragOver { return .accentColor }
        if isBroadcastMode && isBroadcastTarget { return .orange }
        if isSplitPane { return Color.purple.opacity(0.45) }
        if isActive { return Color.accentColor.opacity(0.4) }
        return .clear
    }

    private var tabBorderWidth: CGFloat {
        if isDragOver { return 2 }
        if (isBroadcastMode && isBroadcastTarget) || isSplitPane { return 1.5 }
        return 1
    }

    var statusColor: Color {
        tab.isConnected ? .green : .gray
    }
}

// MARK: - Tab Reorder Drop Delegate

/// Enables drag-to-reorder tabs by dropping one tab onto another's position.
private struct TabReorderDropDelegate: DropDelegate {
    let targetTab: SessionTab
    let sessionManager: SessionManager
    @Binding var dragOverTabID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [tabUTType])
    }

    func dropEntered(info: DropInfo) {
        dragOverTabID = targetTab.id
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragOverTabID = targetTab.id
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dragOverTabID == targetTab.id {
            dragOverTabID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragOverTabID = nil
        let providers = info.itemProviders(for: [tabUTType])
        guard let provider = providers.first else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: tabUTType.identifier) { data, _ in
            guard let data,
                  let payload = String(data: data, encoding: .utf8),
                  payload.hasPrefix("TAB:"),
                  let sourceID = UUID(uuidString: String(payload.dropFirst(4))) else { return }
            DispatchQueue.main.async {
                guard let sourceIndex = sessionManager.tabs.firstIndex(where: { $0.id == sourceID }),
                      let targetIndex = sessionManager.tabs.firstIndex(where: { $0.id == targetTab.id }),
                      sourceIndex != targetIndex else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    sessionManager.tabs.move(
                        fromOffsets: IndexSet(integer: sourceIndex),
                        toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
                    )
                }
            }
        }
        return true
    }
}
