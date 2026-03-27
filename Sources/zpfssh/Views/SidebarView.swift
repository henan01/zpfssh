import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var serverStore: ServerStore
    @ObservedObject var sessionManager: SessionManager
    @State private var showAddServer: Bool = false
    @State private var editingServer: Server? = nil
    @State private var searchText: String = ""
    @State private var showExporter: Bool = false
    @State private var showImporter: Bool = false
    @State private var exportFileDocument: ServerExportDocument? = nil
    @State private var importErrorMessage: String = ""
    @State private var showImportError: Bool = false

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
            HStack(spacing: 4) {
                Button(action: { showAddServer = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .padding(.vertical, 6)
                .help("添加服务器")

                Spacer()

                Button(action: triggerImport) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)
                .help("导入连接配置")

                Button(action: triggerExport) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
                .help("导出连接配置（含密码明文）")
            }
        }
        .frame(minWidth: 200, idealWidth: 220)
        .sheet(isPresented: $showAddServer) {
            AddServerView(serverStore: serverStore)
        }
        .sheet(item: $editingServer) { server in
            AddServerView(serverStore: serverStore, editingServer: server)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportFileDocument,
            contentType: .json,
            defaultFilename: "zpfssh-servers.json"
        ) { _ in
            exportFileDocument = nil
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json]
        ) { result in
            handleImport(result)
        }
        .alert("导入失败", isPresented: $showImportError) {
            Button("确定") {}
        } message: {
            Text(importErrorMessage)
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

    private func triggerExport() {
        guard let data = serverStore.exportData() else { return }
        exportFileDocument = ServerExportDocument(data: data)
        showExporter = true
    }

    private func triggerImport() {
        showImporter = true
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let data = try Data(contentsOf: url)
                try serverStore.importData(data)
            } catch {
                importErrorMessage = error.localizedDescription
                showImportError = true
            }
        case .failure(let error):
            importErrorMessage = error.localizedDescription
            showImportError = true
        }
    }
}

// MARK: - FileDocument for export

struct ServerExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let fileData = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = fileData
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Row view

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
