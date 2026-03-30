import Foundation
import SwiftUI

// MARK: - Import / Export types

struct ServerExportFile: Codable {
    var version: Int = 1
    var servers: [ServerExportEntry]
}

struct ServerExportEntry: Codable {
    var server: Server
    var password: String?
}

// MARK: - Store

@MainActor
class ServerStore: ObservableObject {
    @Published var servers: [Server] = []
    @Published var groups: [String] = []

    private let storageKey = "zen.ssh.servers"

    init() {
        load()
    }

    func add(_ server: Server, password: String? = nil) {
        servers.append(server)
        if let pw = password, !pw.isEmpty {
            CredentialService.shared.save(pw, for: server.id)
        }
        updateGroups()
        save()
        Log.server("添加服务器 \(server.host):\(server.port) auth=\(server.authType) id=\(server.id.uuidString.prefix(8))")
    }

    func update(_ server: Server, password: String? = nil) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
            if let pw = password {
                if pw.isEmpty {
                    CredentialService.shared.delete(for: server.id)
                } else {
                    CredentialService.shared.save(pw, for: server.id)
                }
            }
            updateGroups()
            save()
            Log.server("更新服务器 \(server.host):\(server.port) id=\(server.id.uuidString.prefix(8))")
        }
    }

    func delete(_ server: Server) {
        Log.server("删除服务器 \(server.host):\(server.port) id=\(server.id.uuidString.prefix(8))")
        servers.removeAll { $0.id == server.id }
        CredentialService.shared.delete(for: server.id)
        updateGroups()
        save()
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { servers[$0] }
        for s in toDelete { CredentialService.shared.delete(for: s.id) }
        servers.remove(atOffsets: offsets)
        updateGroups()
        save()
    }

    func password(for server: Server) -> String? {
        CredentialService.shared.load(for: server.id)
    }

    func servers(inGroup group: String) -> [Server] {
        servers.filter { $0.group == group }
    }

    func ungroupedServers() -> [Server] {
        servers.filter { $0.group.isEmpty }
    }

    // MARK: – Import / Export

    /// Export all servers (with plaintext passwords) as JSON data.
    func exportData() -> Data? {
        let entries = servers.map { server in
            ServerExportEntry(
                server: server,
                password: CredentialService.shared.load(for: server.id)
            )
        }
        let file = ServerExportFile(servers: entries)
        return try? JSONEncoder().encode(file)
    }

    /// Import servers from exported JSON data.
    /// Existing servers with the same ID are updated; new ones are appended.
    func importData(_ data: Data) throws {
        let file = try JSONDecoder().decode(ServerExportFile.self, from: data)
        Log.server("导入 \(file.servers.count) 个服务器")
        for entry in file.servers {
            if let idx = servers.firstIndex(where: { $0.id == entry.server.id }) {
                servers[idx] = entry.server
                if let pw = entry.password, !pw.isEmpty {
                    CredentialService.shared.save(pw, for: entry.server.id)
                }
            } else {
                servers.append(entry.server)
                if let pw = entry.password, !pw.isEmpty {
                    CredentialService.shared.save(pw, for: entry.server.id)
                }
            }
        }
        updateGroups()
        save()
    }

    // MARK: – Private

    private func updateGroups() {
        let all = servers.compactMap { $0.group.isEmpty ? nil : $0.group }
        var seen = Set<String>()
        groups = all.filter { seen.insert($0).inserted }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Server].self, from: data)
        else {
            Log.server("无已保存服务器数据")
            return
        }
        servers = decoded
        updateGroups()
        Log.server("加载 \(servers.count) 个服务器, \(groups.count) 个分组")
    }
}
