import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case shell
    case path
    case session

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shell: return "终端变量"
        case .path: return "PATH"
        case .session: return "GUI 会话"
        }
    }

    var systemImage: String {
        switch self {
        case .shell: return "terminal"
        case .path: return "point.3.connected.trianglepath.dotted"
        case .session: return "macwindow"
        }
    }
}

struct ManagedVariable: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }
}

struct PathEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var path: String

    init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }
}

struct StoredState: Codable, Equatable {
    var version: Int
    var variables: [ManagedVariable]
    var pathEntries: [PathEntry]
    var sessionNames: [String]

    static let empty = StoredState(
        version: 3,
        variables: [],
        pathEntries: [],
        sessionNames: []
    )

    private enum CodingKeys: String, CodingKey {
        case version, variables, pathEntries, sessionNames
    }

    init(
        version: Int,
        variables: [ManagedVariable],
        pathEntries: [PathEntry],
        sessionNames: [String]
    ) {
        self.version = version
        self.variables = variables
        self.pathEntries = pathEntries
        self.sessionNames = sessionNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        variables = try container.decodeIfPresent([ManagedVariable].self, forKey: .variables) ?? []
        pathEntries = try container.decodeIfPresent([PathEntry].self, forKey: .pathEntries) ?? []
        sessionNames = try container.decodeIfPresent([String].self, forKey: .sessionNames) ?? []
    }
}

struct SessionVariable: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let value: String?
}

struct BackupRecord: Identifiable {
    let url: URL
    let modifiedAt: Date
    let byteCount: Int64

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum EnvironmentManagerError: LocalizedError {
    case invalidName
    case protectedName(String)
    case duplicateName(String)
    case invalidValue
    case emptySessionValue
    case invalidPath
    case duplicatePath(String)
    case malformedProfile(String)
    case launchctl(String)
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "变量名只能包含字母、数字和下划线，且不能以数字开头。"
        case .protectedName(let name):
            return "\(name) 由 macOS 或 Shell 管理，不能在这里直接覆盖。"
        case .duplicateName(let name):
            return "变量 \(name) 已存在。"
        case .invalidValue:
            return "变量值不能包含换行符或空字符。"
        case .emptySessionValue:
            return "GUI 会话变量的值不能为空。"
        case .invalidPath:
            return "PATH 条目不能为空，也不能包含冒号、换行符或空字符。"
        case .duplicatePath(let path):
            return "PATH 中已包含 \(path)。"
        case .malformedProfile(let file):
            return "\(file) 中的受管区块不完整，已停止写入以保护原文件。"
        case .launchctl(let detail):
            return "无法修改 GUI 会话：\(detail)"
        case .storage(let detail):
            return "无法保存配置：\(detail)"
        }
    }
}
