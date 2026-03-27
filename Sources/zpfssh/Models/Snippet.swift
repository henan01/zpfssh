import Foundation

enum SnippetCategory: String, Codable, CaseIterable, Identifiable {
    var id: String { rawValue }
    case system = "系统监控"
    case docker = "Docker"
    case git = "Git"
    case nginx = "Nginx"
    case database = "数据库"
    case network = "网络"
    case custom = "自定义"
}

struct Snippet: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var command: String
    var description: String = ""
    var category: SnippetCategory = .custom
    var isFavorite: Bool = false
    var createdAt: Date = Date()

    /// Whether the command contains {{placeholder}} parameters
    var hasParameters: Bool {
        command.contains("{{") && command.contains("}}")
    }

    /// Extract parameter names from command
    var parameterNames: [String] {
        var names: [String] = []
        var search = command
        while let start = search.range(of: "{{"),
              let end = search.range(of: "}}", range: start.upperBound..<search.endIndex) {
            let name = String(search[start.upperBound..<end.lowerBound])
            if !names.contains(name) { names.append(name) }
            search = String(search[end.upperBound...])
        }
        return names
    }

    func resolvedCommand(with params: [String: String]) -> String {
        var result = command
        for (key, value) in params {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }
}

extension Snippet {
    static let defaults: [Snippet] = [
        Snippet(name: "查看进程", command: "top -c", category: .system),
        Snippet(name: "磁盘使用", command: "df -h", category: .system),
        Snippet(name: "内存使用", command: "free -h", category: .system),
        Snippet(name: "端口监听", command: "netstat -tlnp", category: .system),
        Snippet(name: "实时日志", command: "tail -f {{log_path}}", description: "实时查看日志文件", category: .system),
        Snippet(name: "系统负载", command: "uptime", category: .system),
        Snippet(name: "CPU信息", command: "lscpu", category: .system),
        Snippet(name: "查看所有容器", command: "docker ps -a", category: .docker),
        Snippet(name: "容器实时日志", command: "docker logs -f {{container}}", description: "实时查看容器日志", category: .docker),
        Snippet(name: "容器资源占用", command: "docker stats", category: .docker),
        Snippet(name: "启动Compose服务", command: "docker-compose up -d", category: .docker),
        Snippet(name: "停止所有容器", command: "docker stop $(docker ps -q)", category: .docker),
        Snippet(name: "提交历史", command: "git log --oneline -20", category: .git),
        Snippet(name: "工作区状态", command: "git status", category: .git),
        Snippet(name: "拉取最新代码", command: "git pull origin {{branch}}", category: .git),
        Snippet(name: "检查Nginx配置", command: "nginx -t", category: .nginx),
        Snippet(name: "热重载Nginx", command: "systemctl reload nginx", category: .nginx),
        Snippet(name: "Nginx状态", command: "systemctl status nginx", category: .nginx),
        Snippet(name: "查看连接状态", command: "ss -s", category: .network),
        Snippet(name: "测试连通性", command: "ping -c 4 {{host}}", category: .network),
        Snippet(name: "路由跟踪", command: "traceroute {{host}}", category: .network),
    ]
}
