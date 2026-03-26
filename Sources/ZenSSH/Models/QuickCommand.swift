import Foundation
import SwiftUI

struct QuickCommand: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String          // 显示在按钮上的短名称
    var command: String        // 实际发送的命令
    var color: QuickCommandColor = .blue
    var sortIndex: Int = 0

    enum QuickCommandColor: String, Codable, CaseIterable, Sendable {
        case blue, green, orange, red, purple, gray

        var color: Color {
            switch self {
            case .blue:   return Color(NSColor.systemBlue)
            case .green:  return Color(NSColor.systemGreen)
            case .orange: return Color(NSColor.systemOrange)
            case .red:    return Color(NSColor.systemRed)
            case .purple: return Color(NSColor.systemPurple)
            case .gray:   return Color(NSColor.systemGray)
            }
        }
    }
}

@MainActor
class QuickCommandStore: ObservableObject {
    @Published var commands: [QuickCommand] = []
    private let key = "zen.ssh.quickCommands"

    init() { load() }

    func add(_ cmd: QuickCommand) { commands.append(cmd); save() }

    func update(_ cmd: QuickCommand) {
        if let i = commands.firstIndex(where: { $0.id == cmd.id }) {
            commands[i] = cmd; save()
        }
    }

    func delete(_ cmd: QuickCommand) {
        commands.removeAll { $0.id == cmd.id }; save()
    }

    func move(from src: IndexSet, to dst: Int) {
        commands.move(fromOffsets: src, toOffset: dst); save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(commands) { UserDefaults.standard.set(d, forKey: key) }
    }
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([QuickCommand].self, from: d) else { return }
        commands = decoded
    }
}
