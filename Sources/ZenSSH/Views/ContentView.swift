import SwiftUI

struct ContentView: View {
    @StateObject private var serverStore = ServerStore()
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var snippetStore = SnippetStore()
    @StateObject private var quickCmdStore = QuickCommandStore()
    @ObservedObject private var settings = AppSettings.shared

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showCommandPalette: Bool = false
    @State private var showSettings: Bool = false
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
                        // Render ALL tabs simultaneously — only the active one is visible.
                        // This preserves SSH processes across tab switches.
                        ZStack {
                            ForEach(sessionManager.tabs) { tab in
                                ZStack(alignment: .top) {
                                    TerminalContainerView(
                                        tab: tab,
                                        sessionManager: sessionManager,
                                        settings: settings,
                                        searchText: searchText,
                                        searchActive: searchActive && tab.id == sessionManager.activeTabID,
                                        password: serverStore.password(for: tab.server)
                                    )

                                    // Search overlay — only for active tab
                                    if searchActive && tab.id == sessionManager.activeTabID {
                                        VStack {
                                            HStack {
                                                Spacer()
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
                                                .padding(.top, 8)
                                                .padding(.trailing, 12)
                                            }
                                            Spacer()
                                        }
                                    }
                                }
                                .opacity(tab.id == sessionManager.activeTabID ? 1 : 0)
                                .animation(.none, value: sessionManager.activeTabID)
                                .allowsHitTesting(tab.id == sessionManager.activeTabID)
                                .zIndex(tab.id == sessionManager.activeTabID ? 1 : 0)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

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

                // Broadcast bar floating overlay
                if showBroadcastBar {
                    VStack {
                        Spacer()
                        BroadcastBarView(isVisible: $showBroadcastBar, sessionManager: sessionManager)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 44)
                    }
                }
            }
        }
        .toolbar {
            // NavigationSplitView already provides its own sidebar-toggle button
            // in the navigation area — no need to add a second one manually.
            ToolbarItemGroup(placement: .automatic) {
                if sessionManager.activeTab != nil {
                    Button(action: splitHorizontal) {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .help("左右分屏 (⌘D)")
                    .keyboardShortcut("d", modifiers: .command)

                    Button(action: splitVertical) {
                        Image(systemName: "rectangle.split.1x2")
                    }
                    .help("上下分屏 (⌘⇧D)")
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

                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                }
                .help("设置")
            }
        }
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteView(snippetStore: snippetStore,
                               sessionManager: sessionManager,
                               isVisible: $showCommandPalette)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
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

    private func splitHorizontal() {
        sessionManager.activeTab?.splitFocused(direction: .horizontal)
    }

    private func splitVertical() {
        sessionManager.activeTab?.splitFocused(direction: .vertical)
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

            Text("ZenSSH")
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
