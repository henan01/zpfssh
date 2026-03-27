import SwiftUI

struct ContentView: View {
    @StateObject private var serverStore = ServerStore()
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var snippetStore = SnippetStore()
    @StateObject private var quickCmdStore = QuickCommandStore()
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showCommandPalette: Bool = false
    @State private var showSFTP: Bool = false
    @State private var showSnippets: Bool = false
    @State private var showBroadcastBar: Bool = false
    @State private var searchText: String = ""
    @State private var searchActive: Bool = false
    @State private var showNewServerSheet: Bool = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(serverStore: serverStore, sessionManager: sessionManager)
        } detail: {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    // Tab bar
                    if !sessionManager.tabs.isEmpty {
                        TabBarView(sessionManager: sessionManager) {
                            showNewServerSheet = true
                        }
                    }

                    if !sessionManager.tabs.isEmpty {
                        // Render ALL tabs simultaneously using absolute positioning.
                        // This preserves SSH processes across tab switches AND allows
                        // two tabs to be shown side-by-side (cross-tab split view).
                        GeometryReader { geo in
                            let hasSplit = sessionManager.splitTabID != nil
                            let isHorizontal = sessionManager.splitDirection == .horizontal
                            let dividerThickness: CGFloat = hasSplit ? 14 : 0
                            let available = (isHorizontal ? geo.size.width : geo.size.height) - dividerThickness
                            let ratio = sessionManager.splitRatio
                            let minPrimary: CGFloat = isHorizontal ? 200 : 120
                            let safePrimary = hasSplit
                                ? max(minPrimary, min(available - minPrimary, available * ratio))
                                : available
                            let secondary = hasSplit ? (available - safePrimary) : 0
                            let secondaryOffset = safePrimary + dividerThickness

                            ZStack(alignment: .topLeading) {
                                ForEach(sessionManager.tabs) { tab in
                                    let isActive = tab.id == sessionManager.activeTabID
                                    let isSplit  = tab.id == sessionManager.splitTabID
                                    let visible  = isActive || isSplit
                                    TerminalContainerView(
                                        tab: tab,
                                        settings: settings,
                                        searchText: searchText,
                                        searchActive: searchActive && isActive,
                                        password: serverStore.password(for: tab.server)
                                    )
                                    .frame(
                                        width: isHorizontal
                                            ? (isSplit ? secondary : safePrimary)
                                            : geo.size.width,
                                        height: isHorizontal
                                            ? geo.size.height
                                            : (isSplit ? secondary : safePrimary)
                                    )
                                    .offset(
                                        x: (isHorizontal && isSplit) ? secondaryOffset : 0,
                                        y: (!isHorizontal && isSplit) ? secondaryOffset : 0
                                    )
                                    .opacity(visible ? 1 : 0)
                                    .animation(.none, value: sessionManager.activeTabID)
                                    .animation(.none, value: sessionManager.splitTabID)
                                    .allowsHitTesting(visible)
                                    .zIndex(visible ? 1 : 0)
                                }

                                // Cross-tab split divider
                                if hasSplit {
                                    CrossTabSplitDivider(
                                        direction: sessionManager.splitDirection,
                                        currentPrimaryLength: safePrimary,
                                        available: available,
                                        onRatioChange: { sessionManager.splitRatio = $0 },
                                        onClose: { sessionManager.closeSplit() }
                                    )
                                    .frame(
                                        width: isHorizontal ? dividerThickness : geo.size.width,
                                        height: isHorizontal ? geo.size.height : dividerThickness
                                    )
                                    .offset(
                                        x: isHorizontal ? safePrimary : 0,
                                        y: isHorizontal ? 0 : safePrimary
                                    )
                                    .zIndex(10)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .topTrailing) {
                            // Draggable search bar overlay — shown above the active terminal
                            if searchActive {
                                DraggableFloating {
                                    SearchBarView(
                                        searchText: $searchText,
                                        isVisible: $searchActive,
                                        onNext: {
                                            guard let paneID = sessionManager.activeTab?.focusedPaneID else { return }
                                            NotificationCenter.default.post(
                                                name: .terminalFindNext,
                                                object: nil,
                                                userInfo: ["paneID": paneID, "text": searchText]
                                            )
                                        },
                                        onPrev: {
                                            guard let paneID = sessionManager.activeTab?.focusedPaneID else { return }
                                            NotificationCenter.default.post(
                                                name: .terminalFindPrevious,
                                                object: nil,
                                                userInfo: ["paneID": paneID, "text": searchText]
                                            )
                                        },
                                        matchInfo: ""
                                    )
                                }
                                .padding(.top, 4)
                                .padding(.trailing, 8)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            // Draggable broadcast bar overlay
                            if showBroadcastBar {
                                DraggableFloating {
                                    BroadcastBarView(isVisible: $showBroadcastBar,
                                                     sessionManager: sessionManager)
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 40)
                            }
                        }

                        // Quick command bar — always shown when there are tabs
                        QuickCommandBar(store: quickCmdStore, sessionManager: sessionManager)

                    } else {
                        WelcomeView(
                            onAddServer: { showNewServerSheet = true },
                            onConnect: { server in sessionManager.openTab(for: server) },
                            serverStore: serverStore
                        )
                    }
                }
            }
        }
        .toolbar {
            // NavigationSplitView already provides its own sidebar-toggle button
            // in the navigation area — no need to add a second one manually.
            ToolbarItemGroup(placement: .automatic) {
                if sessionManager.activeTab != nil {
                    Button(action: splitWithExistingTab) {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .help("与相邻标签分屏（保留会话）(⌘D)")
                    .keyboardShortcut("d", modifiers: .command)

                    Button(action: splitVertical) {
                        Image(systemName: "rectangle.split.1x2")
                    }
                    .help("与相邻标签上下分屏（保留会话）(⌘⇧D)")
                    .keyboardShortcut("d", modifiers: [.command, .shift])

                    Button(action: { sessionManager.closeFocusedPane() }) {
                        Image(systemName: "xmark.rectangle")
                    }
                    .help("关闭当前面板 (⌘W)")
                    .keyboardShortcut("w", modifiers: .command)
                }

                Divider()

                Button(action: toggleSearch) {
                    Image(systemName: searchActive
                          ? "magnifyingglass.circle.fill"
                          : "magnifyingglass")
                }
                .help("搜索终端输出 (⌘F)")
                .keyboardShortcut("f", modifiers: .command)

                Button(action: { showSnippets.toggle() }) {
                    Image(systemName: "command.square")
                }
                .help("命令片段 (⌘⇧S)")
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button(action: { showCommandPalette = true }) {
                    Image(systemName: "text.magnifyingglass")
                }
                .help("命令面板 (⌘P)")
                .keyboardShortcut("p", modifiers: .command)

                if sessionManager.activeTab != nil {
                    Button(action: { showSFTP.toggle() }) {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                    .help("SFTP 文件传输 (⌘⇧F)")
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                }

                Button(action: toggleBroadcast) {
                    Image(systemName: sessionManager.isBroadcastMode
                          ? "antenna.radiowaves.left.and.right.circle.fill"
                          : "antenna.radiowaves.left.and.right.circle")
                    .foregroundColor(sessionManager.isBroadcastMode ? .orange : .primary)
                }
                .help("广播命令 (⌘⌥B)")
                .keyboardShortcut("b", modifiers: [.command, .option])

                Divider()

                Button(action: { openSettings() }) {
                    Image(systemName: "gear")
                }
                .help("设置 (⌘,)")
                .keyboardShortcut(",", modifiers: .command)

                Divider()

                // Build badge — shows version + binary timestamp so you can instantly
                // verify you're running the freshest build without opening About.
                BuildBadgeView()
            }
        }
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteView(snippetStore: snippetStore,
                               sessionManager: sessionManager,
                               isVisible: $showCommandPalette)
        }
        .sheet(isPresented: $showNewServerSheet) {
            AddServerView(serverStore: serverStore)
        }
        .sheet(isPresented: $showSnippets) {
            SnippetPanelView(snippetStore: snippetStore, sessionManager: sessionManager)
                .frame(width: 360, height: 500)
        }
        .sheet(isPresented: $showSFTP) {
            if let tab = sessionManager.activeTab {
                SFTPView(server: tab.server,
                         password: serverStore.password(for: tab.server))
                    .frame(width: 520, height: 620)
            }
        }
        .navigationTitle("")
        .onReceive(NotificationCenter.default.publisher(for: .showAddServer)) { _ in
            showNewServerSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in
            showCommandPalette = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSearch)) { _ in
            toggleSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleBroadcast)) { _ in
            toggleBroadcast()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSFTP)) { _ in
            showSFTP.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitHorizontal)) { _ in
            splitHorizontal()
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitVertical)) { _ in
            splitVertical()
        }
    }

    // MARK: - Actions

    private func splitWithExistingTab() {
        _ = sessionManager.splitWithNeighborTab(direction: .horizontal)
    }

    private func splitVertical() {
        _ = sessionManager.splitWithNeighborTab(direction: .vertical)
    }

    private func splitHorizontal() {
        splitWithExistingTab()
    }

    private func toggleSearch() {
        searchActive.toggle()
        if !searchActive { searchText = "" }
    }

    private func toggleBroadcast() {
        if showBroadcastBar {
            showBroadcastBar = false
            sessionManager.isBroadcastMode = false
        } else {
            sessionManager.toggleBroadcastMode()
            showBroadcastBar = true
        }
    }
}

// MARK: - Build Badge

/// Shows app version + binary modification date in the toolbar.
/// The modification date changes on every build, making it easy to confirm
/// whether you're running the latest compiled version.
struct BuildBadgeView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildDate: String {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return "?" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("v\(version)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(buildDate)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .help("版本 \(version)，编译于 \(buildDate)")
    }
}

// MARK: - Cross-Tab Split Divider

/// Divider between two tabs in cross-tab split.
/// Supports both left-right and top-bottom layouts.
struct CrossTabSplitDivider: View {
    let direction: SplitDirection
    let currentPrimaryLength: CGFloat
    let available: CGFloat
    var onRatioChange: (CGFloat) -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Wider invisible hit area for easier grabbing
            Rectangle()
                .fill(Color.clear)
                .frame(width: direction == .horizontal ? 16 : nil,
                       height: direction == .vertical ? 16 : nil)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary.opacity(0.75))
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭分屏 (两个 Tab 连接仍然保留)")
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    let newRatio = max(0.2, min(0.8,
                        (currentPrimaryLength
                         + (direction == .horizontal
                            ? value.translation.width
                            : value.translation.height)) / available))
                    onRatioChange(newRatio)
                }
        )
        .cursor(direction == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }
}

// MARK: - Draggable Floating Panel

/// Wraps any content in a compact floating panel with a drag handle.
/// Drag the handle bar to reposition the panel freely within its overlay.
struct DraggableFloating<Content: View>: View {
    let content: () -> Content

    @State private var offset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    private var totalOffset: CGSize {
        CGSize(
            width: offset.width + dragTranslation.width,
            height: offset.height + dragTranslation.height
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle strip
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 32, height: 3)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .updating($dragTranslation) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            offset = CGSize(
                                width: offset.width + value.translation.width,
                                height: offset.height + value.translation.height
                            )
                        }
                )
                .cursor(.openHand)

            content()
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 6)
        .offset(totalOffset)
    }
}

// MARK: - Welcome Screen

struct WelcomeView: View {
    var onAddServer: () -> Void
    var onConnect: (Server) -> Void
    @ObservedObject var serverStore: ServerStore

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text("zpfssh")
                    .font(.system(size: 28, weight: .bold))

            Text("轻量原生 SSH 终端管理工具")
                .foregroundColor(.secondary)

            if serverStore.servers.isEmpty {
                Button(action: onAddServer) {
                    Label("添加第一台服务器", systemImage: "plus.circle.fill")
                        .font(.system(size: 15))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                VStack(spacing: 6) {
                    Text("最近连接").font(.caption).foregroundColor(.secondary)
                    ForEach(serverStore.servers.prefix(5)) { server in
                        Button(action: { onConnect(server) }) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(server.color.color.opacity(0.2))
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Text(String(server.displayTitle.prefix(1)).uppercased())
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(server.color.color)
                                    )
                                Text(server.displayTitle)
                                Text(server.connectionString)
                                    .foregroundColor(.secondary).font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 20) {
                ShortcutHint(key: "双击", label: "连接服务器")
                ShortcutHint(key: "⌘P", label: "命令面板")
                ShortcutHint(key: "⌘D", label: "分屏")
                ShortcutHint(key: "⌘W", label: "关闭面板")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct ShortcutHint: View {
    let key: String
    let label: String
    var body: some View {
        VStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }
}
