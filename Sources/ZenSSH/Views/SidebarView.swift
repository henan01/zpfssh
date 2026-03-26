import SwiftUI

struct SidebarView: View {
    @ObservedObject var serverStore: ServerStore
    @ObservedObject var sessionManager: SessionManager
    @State private var showAddServer: Bool = false
    @State private var editingServer: Server? = nil
    @State private var searchText: String = ""

    var filtered: [Server] {
        if searchText.isEmpty { return serverStore.servers }
        let q = searchText.lowercased()
        return serverStore.servers.filter {
            $0.alias.lowercased().contains(q) ||
            $0.host.lowercased().contains(q) ||
            $0.username.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("搜索服务器...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))

            Divider()

            // Server list
            List {
                if serverStore.groups.isEmpty {
                    // Flat list
                    ForEach(filtered) { server in
                        ServerRowView(server: server,
                                      isConnected: sessionManager.tabs.contains { $0.server.id == server.id && $0.isConnected })
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            sessionManager.openTab(for: server)
                        }
                        .contextMenu {
                            Button("连接") { sessionManager.openTab(for: server) }
                            Button("编辑") { editingServer = server }
                            Divider()
                            Button("删除", role: .destructive) { serverStore.delete(server) }
                        }
                    }
                    .onDelete { serverStore.delete(at: $0) }
                } else {
                    // Grouped
                    let ungrouped = filtered.filter { $0.group.isEmpty }
                    if !ungrouped.isEmpty {
                        Section("未分组") {
                            ForEach(ungrouped) { server in
                                serverRow(server)
                            }
                        }
                    }
                    ForEach(serverStore.groups, id: \.self) { group in
                        let groupServers = filtered.filter { $0.group == group }
                        if !groupServers.isEmpty {
                            Section(group) {
                                ForEach(groupServers) { server in
                                    serverRow(server)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Bottom toolbar
            HStack {
                Button(action: { showAddServer = true }) {
                    Label("添加服务器", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                Spacer()

                Text("\(serverStore.servers.count) 台服务器")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
            }
        }
        .frame(minWidth: 200, idealWidth: 220)
        .sheet(isPresented: $showAddServer) {
            AddServerView(serverStore: serverStore)
        }
        .sheet(item: $editingServer) { server in
            AddServerView(serverStore: serverStore, editingServer: server)
        }
    }

    @ViewBuilder
    func serverRow(_ server: Server) -> some View {
        ServerRowView(server: server,
                      isConnected: sessionManager.tabs.contains { $0.server.id == server.id && $0.isConnected })
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            sessionManager.openTab(for: server)
        }
        .contextMenu {
            Button("连接") { sessionManager.openTab(for: server) }
            Button("编辑") { editingServer = server }
            Divider()
            Button("删除", role: .destructive) { serverStore.delete(server) }
        }
    }
}

struct ServerRowView: View {
    let server: Server
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(server.color.color.opacity(0.2))
                    .frame(width: 28, height: 28)
                Text(String(server.displayTitle.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(server.color.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isConnected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 2)
    }
}
