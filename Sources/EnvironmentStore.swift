import AppKit
import Combine
import Foundation

private struct StorageLocations {
    let home: URL
    let appSupport: URL
    let state: URL
    let environment: URL
    let cshEnvironment: URL
    let posixStartup: URL
    let backups: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        appSupport = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MacEnvManager", isDirectory: true)
        state = appSupport.appendingPathComponent("state.json")
        environment = appSupport.appendingPathComponent("environment.zsh")
        cshEnvironment = appSupport.appendingPathComponent("environment.csh")
        posixStartup = appSupport.appendingPathComponent("posix-init.sh")
        backups = appSupport.appendingPathComponent("Backups", isDirectory: true)
    }

    func profile(_ filename: String) -> URL {
        home.appendingPathComponent(filename)
    }
}

private final class FilePersistence {
    private let fileManager: FileManager
    let locations: StorageLocations

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        self.locations = StorageLocations(home: home)
        self.fileManager = fileManager
    }

    var hasStoredState: Bool {
        fileManager.fileExists(atPath: locations.state.path)
    }

    func load() throws -> StoredState {
        guard fileManager.fileExists(atPath: locations.state.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: locations.state)
            return try JSONDecoder().decode(StoredState.self, from: data)
        } catch {
            throw EnvironmentManagerError.storage("state.json 无法读取（\(error.localizedDescription)）")
        }
    }

    func save(_ newState: StoredState) throws {
        do {
            try ensureDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var writes: [(URL, Data)] = [
                (locations.state, try encoder.encode(newState)),
                (locations.environment, Data(ShellConfiguration.renderEnvironmentFile(
                    variables: newState.variables
                ).utf8)),
                (locations.cshEnvironment, Data(ShellConfiguration.renderCshEnvironmentFile(
                    variables: newState.variables
                ).utf8)),
                (locations.posixStartup, Data(ShellConfiguration.posixStartupFile.utf8))
            ]
            let profileFilenames = managedProfileFilenames()
            for filename in profileFilenames {
                let url = locations.profile(filename)
                let original = try readProfile(filename)
                let updated = try ShellConfiguration.installManagedBlock(in: original, filename: filename)
                writes.append((url, Data(updated.utf8)))
            }
            // Bash ignores lower-priority login files, but .profile is always
            // needed by sh/dash/ksh even when Bash uses .bash_profile.
            for filename in [".bash_profile", ".bash_login"] where !profileFilenames.contains(filename) {
                let url = locations.profile(filename)
                guard fileManager.fileExists(atPath: url.path) else { continue }
                let original = try readProfile(filename)
                guard original.contains(ShellConfiguration.markerStart) || original.contains(ShellConfiguration.markerEnd) else { continue }
                let cleaned = try ShellConfiguration.removeManagedBlock(from: original, filename: filename)
                writes.append((url, Data((cleaned.isEmpty ? "" : cleaned + "\n").utf8)))
            }
            // Validate and snapshot every file before the first write so failures
            // cannot leave different shells with different sets of variables.
            var changes: [(url: URL, data: Data, original: Data?, permissions: NSNumber, originalPermissions: NSNumber)] = []
            for (url, data) in writes {
                let original = fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
                let isProfile = url.deletingLastPathComponent() == locations.home
                let originalPermissions = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
                let permissions = isProfile
                    ? (originalPermissions ?? NSNumber(value: 0o600))
                    : NSNumber(value: 0o600)
                if original != data || originalPermissions?.intValue != permissions.intValue {
                    changes.append((url, data, original, permissions, originalPermissions ?? permissions))
                }
            }
            for change in changes {
                try backupIfPresent(change.url, label: change.url.lastPathComponent)
            }
            var attempted: [Int] = []
            do {
                for (index, change) in changes.enumerated() {
                    attempted.append(index)
                    try change.data.write(to: change.url, options: .atomic)
                    try fileManager.setAttributes([.posixPermissions: change.permissions], ofItemAtPath: change.url.path)
                }
            } catch {
                var rollbackFailed = false
                for index in attempted.reversed() {
                    let change = changes[index]
                    do {
                        if let original = change.original {
                            try original.write(to: change.url, options: .atomic)
                            try fileManager.setAttributes([.posixPermissions: change.originalPermissions], ofItemAtPath: change.url.path)
                        } else if fileManager.fileExists(atPath: change.url.path) {
                            try fileManager.removeItem(at: change.url)
                        }
                    } catch {
                        rollbackFailed = true
                    }
                }
                if rollbackFailed {
                    throw EnvironmentManagerError.storage("写入和恢复均失败，请从 Backups 文件夹恢复配置。")
                }
                throw error
            }
            try? pruneBackups(keeping: 40)
        } catch let error as EnvironmentManagerError {
            throw error
        } catch {
            throw EnvironmentManagerError.storage(error.localizedDescription)
        }
    }

    func profileText(_ filename: String) -> String {
        let url = locations.profile(filename)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func unmanagedDefinitionLocations(for name: String) -> [String] {
        managedProfileFilenames().flatMap { filename in
            ShellConfiguration.unmanagedDefinitionLines(
                for: name,
                in: profileText(filename)
            ).map { "\(filename):\($0)" }
        }
    }

    func backupRecords() -> [BackupRecord] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: locations.backups,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                return nil
            }
            return BackupRecord(
                url: url,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                byteCount: Int64(values.fileSize ?? 0)
            )
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func ensureDirectories() throws {
        try fileManager.createDirectory(at: locations.appSupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: locations.backups, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locations.appSupport.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locations.backups.path)
    }

    private func readProfile(_ filename: String) throws -> String {
        let url = locations.profile(filename)
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func managedProfileFilenames() -> [String] {
        let bashLoginCandidates = [".bash_profile", ".bash_login", ".profile"]
        let bashLogin = bashLoginCandidates.first {
            fileManager.fileExists(atPath: locations.profile($0).path)
        } ?? ".bash_profile"

        var filenames = [".zshenv", ".zshrc", ".zprofile", ".zlogin", ".bashrc", ".profile", ".shrc", ".kshrc", ".cshrc", ".login"]
        if !filenames.contains(bashLogin) { filenames.append(bashLogin) }
        // Do not create .tcshrc if absent: it would mask an existing .cshrc.
        if fileManager.fileExists(atPath: locations.profile(".tcshrc").path) {
            filenames.append(".tcshrc")
        }
        return filenames
    }

    private func backupIfPresent(_ url: URL, label: String) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let safeLabel = label.replacingOccurrences(of: "/", with: "-")
        let destination = locations.backups.appendingPathComponent(
            "\(formatter.string(from: Date()))__\(UUID().uuidString.prefix(8))__\(safeLabel).bak"
        )
        try fileManager.copyItem(at: url, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func pruneBackups(keeping limit: Int) throws {
        let records = backupRecords()
        for record in records.dropFirst(limit) {
            try fileManager.removeItem(at: record.url)
        }
    }
}

protocol LaunchctlManaging {
    func value(for name: String) throws -> String?
    func set(name: String, value: String) throws
    func unset(name: String) throws
}

struct SystemLaunchctlClient: LaunchctlManaging {
    func value(for name: String) throws -> String? {
        let result = try run(["getenv", name])
        guard result.status == 0 else { return nil }
        var value = result.stdout
        if value.hasSuffix("\n") {
            value.removeLast()
        }
        return value.isEmpty ? nil : value
    }

    func set(name: String, value: String) throws {
        let result = try run(["setenv", name, value])
        guard result.status == 0 else {
            throw EnvironmentManagerError.launchctl(result.stderr.isEmpty ? "launchctl 返回 \(result.status)" : result.stderr)
        }
    }

    func unset(name: String) throws {
        let result = try run(["unsetenv", name])
        guard result.status == 0 else {
            throw EnvironmentManagerError.launchctl(result.stderr.isEmpty ? "launchctl 返回 \(result.status)" : result.stderr)
        }
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            process.waitUntilExit()
            let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus, stdout, stderr)
        } catch {
            throw EnvironmentManagerError.launchctl(error.localizedDescription)
        }
    }
}

@MainActor
final class EnvironmentStore: ObservableObject {
    @Published private(set) var state: StoredState = .empty
    @Published private(set) var backups: [BackupRecord] = []
    @Published var statusMessage = "就绪"
    @Published var errorMessage: String?

    private let persistence: FilePersistence
    private let launchctl: any LaunchctlManaging

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        launchctl: any LaunchctlManaging = SystemLaunchctlClient(),
        fileManager: FileManager = .default
    ) {
        persistence = FilePersistence(home: home, fileManager: fileManager)
        self.launchctl = launchctl
        do {
            let hadStoredState = persistence.hasStoredState
            var loadedState = try persistence.load()
            state = loadedState
            try persistence.ensureDirectories()

            let requiresMigration = hadStoredState && loadedState.version < StoredState.currentVersion
            if requiresMigration {
                mergeLegacySessionVariables(into: &loadedState)
                loadedState.version = StoredState.currentVersion
                loadedState.legacySessionNames = []
            }
            try persistence.save(loadedState)
            state = loadedState
            try synchronizeGUIEnvironment()
            try synchronizePOSIXStartup()
            if requiresMigration {
                statusMessage = "已升级并同步到 7 种 Shell 与当前 GUI 会话"
            } else if !state.variables.isEmpty {
                statusMessage = "已同步到 7 种 Shell 与当前 GUI 会话"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshBackups()
    }

    var variables: [ManagedVariable] {
        state.variables.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var backupFolder: URL { persistence.locations.backups }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func upsertVariable(id: UUID?, name rawName: String, value: String, isEnabled: Bool? = nil) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        try ShellConfiguration.validateVariable(name: name, value: value)

        var next = state
        var originalVariable: ManagedVariable?
        if let id, let index = next.variables.firstIndex(where: { $0.id == id }) {
            if next.variables.contains(where: { $0.id != id && $0.name == name }) {
                throw EnvironmentManagerError.duplicateName(name)
            }
            originalVariable = next.variables[index]
            next.variables[index].name = name
            next.variables[index].value = value
            next.variables[index].isEnabled = isEnabled ?? next.variables[index].isEnabled
        } else {
            guard !next.variables.contains(where: { $0.name == name }) else {
                throw EnvironmentManagerError.duplicateName(name)
            }
            next.variables.append(ManagedVariable(name: name, value: value, isEnabled: isEnabled ?? false))
        }

        let enabled = isEnabled ?? originalVariable?.isEnabled ?? false
        let renamedFrom = originalVariable?.name == name ? nil : originalVariable?.name
        let previousNewValue = try launchctl.value(for: name)
        let previousOldValue: String?
        if let renamedFrom {
            previousOldValue = try launchctl.value(for: renamedFrom)
        } else {
            previousOldValue = nil
        }

        do {
            if enabled {
                try launchctl.set(name: name, value: value)
            } else {
                try launchctl.unset(name: name)
            }
            if let renamedFrom {
                try launchctl.unset(name: renamedFrom)
            }
        } catch {
            restoreLaunchctl(name: name, value: previousNewValue)
            if let renamedFrom {
                restoreLaunchctl(name: renamedFrom, value: previousOldValue)
            }
            throw error
        }

        do {
            try persistence.save(next)
            state = next
            refreshBackups()
        } catch {
            restoreLaunchctl(name: name, value: previousNewValue)
            if let renamedFrom {
                restoreLaunchctl(name: renamedFrom, value: previousOldValue)
            }
            refreshBackups()
            throw error
        }

        let conflicts = enabled ? persistence.unmanagedDefinitionLocations(for: name) : []
        statusMessage = conflicts.isEmpty
            ? (enabled ? "已启用；新启动的终端和应用生效" : "已停用并保留变量；新启动的终端和应用生效")
            : "已保存到所有环境；\(conflicts.joined(separator: ", ")) 存在同名定义"
    }

    func setVariableEnabled(id: UUID, isEnabled: Bool) throws {
        guard let variable = state.variables.first(where: { $0.id == id }) else { return }
        try upsertVariable(id: id, name: variable.name, value: variable.value, isEnabled: isEnabled)
    }

    func removeVariable(id: UUID) throws {
        guard let variable = state.variables.first(where: { $0.id == id }) else { return }
        var next = state
        next.variables.removeAll { $0.id == id }
        let previousValue = try launchctl.value(for: variable.name)
        do {
            try launchctl.unset(name: variable.name)
        } catch {
            restoreLaunchctl(name: variable.name, value: previousValue)
            throw error
        }

        do {
            try persistence.save(next)
            state = next
            refreshBackups()
        } catch {
            restoreLaunchctl(name: variable.name, value: previousValue)
            refreshBackups()
            throw error
        }
        statusMessage = "已从所有环境删除；新启动的终端和应用生效"
    }

    func refreshBackups() {
        backups = persistence.backupRecords()
    }

    func revealBackupFolder() {
        do {
            try persistence.ensureDirectories()
            NSWorkspace.shared.open(persistence.locations.backups)
        } catch {
            present(error)
        }
    }

    private func mergeLegacySessionVariables(into loadedState: inout StoredState) {
        var names = Set(loadedState.variables.map(\.name))
        for name in loadedState.legacySessionNames where !names.contains(name) {
            let legacyValue: String?
            do {
                legacyValue = try launchctl.value(for: name)
            } catch {
                continue
            }
            guard let legacyValue else { continue }
            do {
                try ShellConfiguration.validateVariable(name: name, value: legacyValue)
            } catch {
                continue
            }
            loadedState.variables.append(ManagedVariable(name: name, value: legacyValue, isEnabled: true))
            names.insert(name)
        }
    }

    private func synchronizeGUIEnvironment() throws {
        for variable in state.variables {
            if variable.isEnabled {
                try launchctl.set(name: variable.name, value: variable.value)
            } else {
                try launchctl.unset(name: variable.name)
            }
        }
    }

    private func synchronizePOSIXStartup() throws {
        let managedPath = persistence.locations.posixStartup.path
        let previousENV = try launchctl.value(for: "ENV")
        let previousOriginal = try launchctl.value(for: "_MAC_ENV_MANAGER_ORIGINAL_ENV")
        do {
            if let previousENV, previousENV != managedPath {
                try launchctl.set(name: "_MAC_ENV_MANAGER_ORIGINAL_ENV", value: previousENV)
            }
            try launchctl.set(name: "ENV", value: managedPath)
        } catch {
            restoreLaunchctl(name: "ENV", value: previousENV)
            restoreLaunchctl(name: "_MAC_ENV_MANAGER_ORIGINAL_ENV", value: previousOriginal)
            throw error
        }
    }

    private func restoreLaunchctl(name: String, value: String?) {
        if let value {
            try? launchctl.set(name: name, value: value)
        } else {
            try? launchctl.unset(name: name)
        }
    }
}
