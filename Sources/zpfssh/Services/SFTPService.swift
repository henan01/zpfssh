import Foundation
import Citadel
import NIOCore
import Crypto
import Darwin

// MARK: - Data Models

struct RemoteFile: Identifiable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var permissions: String
    var modifiedAt: String
}

struct TransferTask: Identifiable, Sendable {
    var id: UUID = UUID()
    var localPath: String
    var remotePath: String
    var isUpload: Bool
    var progress: Double = 0          // 0.0 – 1.0
    var totalBytes: Int64 = 0
    var transferredBytes: Int64 = 0
    var isCompleted: Bool = false
    var error: String? = nil
    var fileName: String { URL(fileURLWithPath: localPath).lastPathComponent }
}

// MARK: - Errors

enum SFTPServiceError: LocalizedError {
    case notConnected
    case fileReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:            return "未连接到 SFTP 服务器"
        case .fileReadFailed(let p):   return "无法读取文件: \(p)"
        }
    }
}

// MARK: - SFTPService
//
// Pure-Swift SSH/SFTP via Citadel (https://github.com/orlandos-nl/Citadel).
// No /usr/bin/ssh, /usr/bin/scp, or expect scripts are used.
// All transfers run in Swift concurrency Tasks — the UI is never blocked.

@MainActor
final class SFTPService: ObservableObject {

    // MARK: Published state
    @Published var currentRemotePath: String = "/"
    @Published var remoteFiles: [RemoteFile] = []
    @Published var transferQueue: [TransferTask] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    // MARK: Private
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?
    private var server: Server?
    private var password: String?
    private var tunnelProcess: Process?

    // MARK: - Public API

    /// Connect and list the root directory.
    func connect(to server: Server, password: String?) {
        self.server   = server
        self.password = password
        Task {
            do {
                try await establish(to: server, password: password)
                listDirectory("/")
            } catch {
                self.errorMessage = "连接失败: \(error.localizedDescription)"
            }
        }
    }

    /// Connect without triggering a directory listing (used for terminal drag-drop upload).
    func connectForUpload(to server: Server, password: String?) {
        self.server   = server
        self.password = password
        Task { try? await establish(to: server, password: password) }
    }

    func listDirectory(_ path: String) {
        Task {
            self.isLoading    = true
            self.errorMessage = nil
            do {
                try await ensureConnected()
                guard let sftp = sftpClient else { throw SFTPServiceError.notConnected }

                let names = try await sftp.listDirectory(atPath: path)
                let entries = names.flatMap { $0.components }
                let files: [RemoteFile] = entries.compactMap { entry -> RemoteFile? in
                    let name = entry.filename
                    guard name != "." && name != ".." else { return nil }
                    let attrs   = entry.attributes
                    let isDir   = attrs.isDirectory
                    let size    = Int64(attrs.size ?? 0)
                    let perms   = formatPermissions(attrs.permissions ?? 0, isDir: isDir)
                    let modDate = attrs.accessModificationTime.map { formatDate($0.modificationTime) } ?? ""
                    let rpath   = path == "/" ? "/\(name)" : "\(path)/\(name)"
                    return RemoteFile(name: name, path: rpath,
                                     isDirectory: isDir, size: size,
                                     permissions: perms, modifiedAt: modDate)
                }
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }

                self.isLoading          = false
                self.currentRemotePath  = path
                self.remoteFiles        = files

            } catch {
                self.isLoading    = false
                self.errorMessage = "无法列出目录: \(error.localizedDescription)"
            }
        }
    }

    /// Upload a local file to the server with chunked progress reporting.
    func uploadFile(localURL: URL, toRemotePath remotePath: String) {
        var task = TransferTask(localPath: localURL.path,
                                remotePath: remotePath,
                                isUpload: true)
        let taskID = task.id
        transferQueue.append(task)

        Task {
            do {
                guard let data = try? Data(contentsOf: localURL) else {
                    throw SFTPServiceError.fileReadFailed(localURL.path)
                }
                let totalBytes = Int64(data.count)
                self.mutatetask(id: taskID) { $0.totalBytes = totalBytes }

                try await ensureConnected()
                guard let sftp = sftpClient else { throw SFTPServiceError.notConnected }

                let handle = try await sftp.openFile(
                    filePath: remotePath,
                    flags: SFTPOpenFileFlags([.write, .create, .truncate])
                )

                let chunkSize = 65_536  // 64 KB
                var offset = 0
                while offset < data.count {
                    let end   = min(offset + chunkSize, data.count)
                    let slice = data[offset..<end]
                    var buf   = ByteBufferAllocator().buffer(capacity: slice.count)
                    buf.writeBytes(slice)
                    try await handle.write(buf, at: UInt64(offset))
                    offset = end
                    let xferred = Int64(offset)
                    self.mutatetask(id: taskID) {
                        $0.transferredBytes = xferred
                        $0.progress = Double(xferred) / Double(max(totalBytes, 1))
                    }
                }
                try await handle.close()
                self.mutatetask(id: taskID) { $0.isCompleted = true; $0.progress = 1.0 }

            } catch {
                self.mutatetask(id: taskID) {
                    $0.error = error.localizedDescription; $0.isCompleted = true
                }
            }
        }
    }

    /// Download a remote file to a local URL with chunked progress reporting.
    func downloadFile(remotePath: String, toLocalURL localURL: URL) {
        var task = TransferTask(localPath: localURL.path,
                                remotePath: remotePath,
                                isUpload: false)
        let taskID = task.id
        transferQueue.append(task)

        Task {
            do {
                try await ensureConnected()
                guard let sftp = sftpClient else { throw SFTPServiceError.notConnected }

                // Stat first to get the total size (best-effort)
                let totalBytes: Int64
                if let attrs = try? await sftp.getAttributes(at: remotePath),
                   let sz = attrs.size {
                    totalBytes = Int64(sz)
                } else {
                    totalBytes = 0
                }
                self.mutatetask(id: taskID) { $0.totalBytes = totalBytes }

                let handle    = try await sftp.openFile(filePath: remotePath, flags: .read)
                var allData   = Data()
                var offset: UInt64 = 0
                let chunkSize: UInt32 = 65_536

                while true {
                    var buf      = try await handle.read(from: offset, length: chunkSize)
                    let readable = buf.readableBytes
                    guard readable > 0,
                          let bytes = buf.readBytes(length: readable) else { break }
                    allData.append(contentsOf: bytes)
                    offset += UInt64(readable)
                    let xferred = Int64(offset)
                    self.mutatetask(id: taskID) {
                        $0.transferredBytes = xferred
                        $0.progress = totalBytes > 0
                            ? Double(xferred) / Double(totalBytes) : 0
                    }
                    if readable < Int(chunkSize) { break }   // EOF
                }
                try await handle.close()
                try allData.write(to: localURL)
                self.mutatetask(id: taskID) { $0.isCompleted = true; $0.progress = 1.0 }

            } catch {
                self.mutatetask(id: taskID) {
                    $0.error = error.localizedDescription; $0.isCompleted = true
                }
            }
        }
    }

    func deleteTransferTask(id: UUID) {
        transferQueue.removeAll { $0.id == id }
    }

    // MARK: - Connection helpers

    private func establish(to server: Server, password: String?) async throws {
        let (ssh, sftp, tunnel) = try await Self.makeConnection(server: server, password: password)
        self.tunnelProcess?.terminate()
        self.tunnelProcess = tunnel
        self.sshClient  = ssh
        self.sftpClient = sftp
    }

    private nonisolated static func makeConnection(
        server: Server,
        password: String?
    ) async throws -> (SSHClient, SFTPClient, Process?) {
        var connectHost = server.host
        var connectPort = server.port
        var tunnelProcess: Process? = nil

        if !server.jumpHost.isEmpty {
            let (proc, localPort) = try startSSHTunnel(to: server)
            tunnelProcess = proc
            connectHost = "127.0.0.1"
            connectPort  = localPort
            // Give the tunnel ~2 s to establish before connecting
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        let authMethod: SSHAuthenticationMethod
        switch server.authType {
        case .password:
            authMethod = .passwordBased(username: server.username,
                                        password: password ?? "")
        case .privateKey:
            authMethod = buildKeyAuthStatic(server: server, fallback: password)
        case .sshAgent:
            authMethod = .passwordBased(username: server.username,
                                        password: password ?? "")
        }
        let client = try await SSHClient.connect(
            host: connectHost,
            port: connectPort,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        let sftp = try await client.openSFTP()
        return (client, sftp, tunnelProcess)
    }

    // Launches: ssh -N -L 127.0.0.1:localPort:targetHost:targetPort jumpHost
    private nonisolated static func startSSHTunnel(
        to server: Server
    ) throws -> (Process, Int) {
        let localPort = try allocFreePort()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-N",
            "-L", "127.0.0.1:\(localPort):\(server.host):\(server.port)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            server.jumpHost
        ]
        proc.standardInput  = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        try proc.run()
        return (proc, localPort)
    }

    private nonisolated static func allocFreePort() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw SFTPServiceError.notConnected }
        defer { Darwin.close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = 0
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw SFTPServiceError.notConnected }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var bound2 = sockaddr_in()
        withUnsafeMutablePointer(to: &bound2) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        return Int(CFSwapInt16BigToHost(bound2.sin_port))
    }

    private func ensureConnected() async throws {
        guard sftpClient == nil, let server = server else { return }
        try await establish(to: server, password: password)
    }

    private nonisolated static func buildKeyAuthStatic(server: Server,
                               fallback: String?) -> SSHAuthenticationMethod {
        let path = server.privateKeyPath
        guard !path.isEmpty,
              let pem = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .passwordBased(username: server.username, password: fallback ?? "")
        }
        // Ed25519
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: pem) {
            return .ed25519(username: server.username, privateKey: key)
        }
        // P-256
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return .p256(username: server.username, privateKey: key)
        }
        // Fallback
        return .passwordBased(username: server.username, password: fallback ?? "")
    }

    // MARK: - Mutation helper (always on MainActor)

    private func mutatetask(id: UUID, _ block: (inout TransferTask) -> Void) {
        if let idx = transferQueue.firstIndex(where: { $0.id == id }) {
            block(&transferQueue[idx])
        }
    }

    // MARK: - Formatting

    private func formatPermissions(_ raw: UInt32, isDir: Bool) -> String {
        let type: Character
        switch raw & 0xF000 {
        case 0x4000: type = "d"
        case 0xA000: type = "l"
        default:     type = "-"
        }
        let defs: [(UInt32, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return String(type) + String(defs.map { raw & $0.0 != 0 ? $0.1 : "-" })
    }

    private func formatDate(_ date: Date) -> String {
        let fmt  = DateFormatter()
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        fmt.dateFormat = sameYear ? "MMM dd HH:mm" : "MMM dd  yyyy"
        return fmt.string(from: date)
    }
}

// MARK: - SFTPFileAttributes helpers

private extension SFTPFileAttributes {
    var isDirectory: Bool {
        guard let p = permissions else { return false }
        return (p & 0xF000) == 0x4000   // S_IFDIR
    }
}
