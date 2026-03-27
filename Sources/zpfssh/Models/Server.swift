import Foundation
import SwiftUI

enum AuthType: String, Codable, CaseIterable {
    case password = "password"
    case privateKey = "privateKey"
    case sshAgent = "sshAgent"

    var displayName: String {
        switch self {
        case .password: return "密码"
        case .privateKey: return "私钥"
        case .sshAgent: return "SSH Agent"
        }
    }
}

enum ServerColor: String, Codable, CaseIterable {
    case blue, green, red, orange, purple, pink, gray, yellow

    var color: Color {
        switch self {
        case .blue:   return .blue
        case .green:  return .green
        case .red:    return .red
        case .orange: return .orange
        case .purple: return .purple
        case .pink:   return .pink
        case .gray:   return .gray
        case .yellow: return .yellow
        }
    }
}

struct Server: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var alias: String
    var host: String
    var port: Int = 22
    var username: String
    var authType: AuthType = .password
    var privateKeyPath: String = ""
    var jumpHost: String = ""
    var color: ServerColor = .blue
    var group: String = ""
    var note: String = ""
    var createdAt: Date = Date()

    var displayTitle: String {
        alias.isEmpty ? "\(username)@\(host)" : alias
    }

    var connectionString: String {
        "\(username)@\(host)"
    }

    func sshArgs(extraArgs: [String] = []) -> [String] {
        var args: [String] = []
        // Always pass port explicitly so ~/.ssh/config overrides don't interfere
        args += ["-p", "\(port)"]
        if authType == .privateKey && !privateKeyPath.isEmpty {
            args += ["-i", privateKeyPath]
        }
        if !jumpHost.isEmpty {
            args += ["-J", jumpHost]
        }
        args += ["-o", "StrictHostKeyChecking=no"]
        args += ["-o", "ServerAliveInterval=60"]
        args += extraArgs
        args.append("\(username)@\(host)")
        return args
    }
}
