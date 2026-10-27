import Foundation

struct ManagedVariable: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var value: String
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, value: String, isEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.value = value
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, value, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
        // All variables in older releases were active; preserve that behavior.
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

struct StoredState: Codable, Equatable {
    static let currentVersion = 6

    var version: Int
    var variables: [ManagedVariable]
    var legacySessionNames: [String]

    static let empty = StoredState(
        version: currentVersion,
        variables: [],
        legacySessionNames: []
    )

    private enum CodingKeys: String, CodingKey {
        case version, variables, sessionNames
    }

    init(
        version: Int,
        variables: [ManagedVariable],
        legacySessionNames: [String] = []
    ) {
        self.version = version
        self.variables = variables
        self.legacySessionNames = legacySessionNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        variables = try container.decodeIfPresent([ManagedVariable].self, forKey: .variables) ?? []
        legacySessionNames = try container.decodeIfPresent([String].self, forKey: .sessionNames) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(variables, forKey: .variables)
    }
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
        case .malformedProfile(let file):
            return "\(file) 中的受管区块不完整，已停止写入以保护原文件。"
        case .launchctl(let detail):
            return "无法修改 GUI 会话：\(detail)"
        case .storage(let detail):
            return "无法保存配置：\(detail)"
        }
    }
}
