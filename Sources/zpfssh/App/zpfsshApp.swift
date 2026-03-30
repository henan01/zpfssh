import SwiftUI
import AppKit
import Sparkle

@main
struct zpfsshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建连接") {
                    NotificationCenter.default.post(name: .showAddServer, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("终端") {
                Button("左右分屏") {
                    NotificationCenter.default.post(name: .splitHorizontal, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("上下分屏") {
                    NotificationCenter.default.post(name: .splitVertical, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("命令面板") {
                    NotificationCenter.default.post(name: .showCommandPalette, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("搜索输出") {
                    NotificationCenter.default.post(name: .toggleSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("广播命令") {
                    NotificationCenter.default.post(name: .toggleBroadcast, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .option])

                Button("SFTP 面板") {
                    NotificationCenter.default.post(name: .toggleSFTP, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(settings: AppSettings.shared)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        Log.app("应用启动完成 macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        // Start Sparkle's updater so that scheduled automatic checks / downloads / installs can run.
        // The actual policy is configured via Info.plist keys (SUFeedURL, SUPublicEDKey, SUAutomaticallyUpdate, etc).
        if updaterController == nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Log.app("最后窗口关闭，准备退出")
        return true
    }
}

extension Notification.Name {
    static let showAddServer    = Notification.Name("zen.ssh.showAddServer")
    static let splitHorizontal  = Notification.Name("zen.ssh.splitHorizontal")
    static let splitVertical    = Notification.Name("zen.ssh.splitVertical")
    static let showCommandPalette = Notification.Name("zen.ssh.showCommandPalette")
    static let toggleSearch     = Notification.Name("zen.ssh.toggleSearch")
    static let toggleBroadcast  = Notification.Name("zen.ssh.toggleBroadcast")
    static let toggleSFTP       = Notification.Name("zen.ssh.toggleSFTP")
}
