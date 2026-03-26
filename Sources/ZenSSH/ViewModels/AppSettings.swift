import Foundation
import SwiftUI

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var appearance: AppearanceSettings {
        didSet { save() }
    }
    @Published var restoreOnLaunch: Bool = true {
        didSet { UserDefaults.standard.set(restoreOnLaunch, forKey: "restoreOnLaunch") }
    }
    @Published var confirmBroadcast: Bool = true {
        didSet { UserDefaults.standard.set(confirmBroadcast, forKey: "confirmBroadcast") }
    }
    @Published var scrollbackLines: Int = 10000 {
        didSet { UserDefaults.standard.set(scrollbackLines, forKey: "scrollbackLines") }
    }
    @Published var tabTitleTemplate: String = "{alias}" {
        didSet { UserDefaults.standard.set(tabTitleTemplate, forKey: "tabTitleTemplate") }
    }

    var currentTheme: TerminalTheme {
        TerminalTheme.builtins.first { $0.id == appearance.themeId } ?? TerminalTheme.zenDark
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "appearance"),
           let decoded = try? JSONDecoder().decode(AppearanceSettings.self, from: data) {
            appearance = decoded
        } else {
            appearance = AppearanceSettings()
        }
        restoreOnLaunch = UserDefaults.standard.bool(forKey: "restoreOnLaunch")
        confirmBroadcast = UserDefaults.standard.object(forKey: "confirmBroadcast") as? Bool ?? true
        scrollbackLines = UserDefaults.standard.integer(forKey: "scrollbackLines").nonZero ?? 10000
        tabTitleTemplate = UserDefaults.standard.string(forKey: "tabTitleTemplate") ?? "{alias}"
    }

    private func save() {
        if let data = try? JSONEncoder().encode(appearance) {
            UserDefaults.standard.set(data, forKey: "appearance")
        }
    }
}

extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
