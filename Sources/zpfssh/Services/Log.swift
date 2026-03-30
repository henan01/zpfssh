import Foundation
import os.log

/// 统一日志工具，使用 Apple os_log 框架。
///
/// 用法：
///   Log.ssh("连接到 %@:%d", host, port)
///   Log.ui("切换 tab %@", tabID.uuidString)
///
/// 查看日志：
///   • 终端运行二进制时直接输出到 stderr
///   • Console.app 搜索 subsystem "com.zpf.ssh"
///   • 命令行: `log stream --predicate 'subsystem == "com.zpf.ssh"' --level debug`
enum Log {
    private static let subsystem = "com.zpf.ssh"

    // MARK: - Categories

    private static let sshLog      = Logger(subsystem: subsystem, category: "SSH")
    private static let sessionLog  = Logger(subsystem: subsystem, category: "Session")
    private static let settingsLog = Logger(subsystem: subsystem, category: "Settings")
    private static let serverLog   = Logger(subsystem: subsystem, category: "Server")
    private static let sftpLog     = Logger(subsystem: subsystem, category: "SFTP")
    private static let credLog     = Logger(subsystem: subsystem, category: "Credential")
    private static let keyLog      = Logger(subsystem: subsystem, category: "KeyEvent")
    private static let uiLog       = Logger(subsystem: subsystem, category: "UI")
    private static let zmodemLog   = Logger(subsystem: subsystem, category: "ZModem")
    private static let appLog      = Logger(subsystem: subsystem, category: "App")

    // MARK: - Public API

    /// SSH 连接相关（连接、断开、密码注入、进程启动）
    static func ssh(_ message: String) { sshLog.info("\(message, privacy: .public)") }

    /// 会话管理（tab 创建/关闭/切换、pane 分屏/合并、广播）
    static func session(_ message: String) { sessionLog.info("\(message, privacy: .public)") }

    /// 设置变更（主题、字体、scrollback 等）
    static func settings(_ message: String) { settingsLog.info("\(message, privacy: .public)") }

    /// 服务器存储（增删改、导入导出）
    static func server(_ message: String) { serverLog.info("\(message, privacy: .public)") }

    /// SFTP 文件传输（连接、列目录、上传、下载）
    static func sftp(_ message: String) { sftpLog.info("\(message, privacy: .public)") }

    /// 凭证管理（加密存储、密钥迁移，注意不要记录密码明文）
    static func cred(_ message: String) { credLog.info("\(message, privacy: .public)") }

    /// 键盘事件（Fn 组合键、导航键等）
    static func key(_ message: String) { keyLog.info("\(message, privacy: .public)") }

    /// UI 事件（搜索、拖拽等）
    static func ui(_ message: String) { uiLog.info("\(message, privacy: .public)") }

    /// ZModem 文件传输
    static func zmodem(_ message: String) { zmodemLog.info("\(message, privacy: .public)") }

    /// App 生命周期
    static func app(_ message: String) { appLog.info("\(message, privacy: .public)") }

    // MARK: - Error level

    static func error(_ category: String, _ message: String) {
        Logger(subsystem: subsystem, category: category).error("\(message, privacy: .public)")
    }
}
