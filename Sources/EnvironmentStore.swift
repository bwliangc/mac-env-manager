import AppKit
import Combine
import Foundation

private struct StorageLocations {
    let home: URL
    let appSupport: URL
    let state: URL
    let environment: URL
    let backups: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        appSupport = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MacEnvManager", isDirectory: true)
        state = appSupport.appendingPathComponent("state.json")
        environment = appSupport.appendingPathComponent("environment.zsh")
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
            try backupIfPresent(locations.state, label: "state.json")
            try backupIfPresent(locations.environment, label: "environment.zsh")

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(newState)
            try writeSecure(data, to: locations.state)

            let environmentText = ShellConfiguration.renderEnvironmentFile(
                variables: newState.variables,
                pathEntries: newState.pathEntries
            )
            try writeSecure(Data(environmentText.utf8), to: locations.environment)

            let profileFilenames = managedProfileFilenames()
            try installProfiles(profileFilenames)
            try removeManagedBlocks(except: Set(profileFilenames))

            try pruneBackups(keeping: 40)
        } catch let error as EnvironmentManagerError {
            throw error
        } catch {
            throw EnvironmentManagerError.storage(error.localizedDescription)
        }
    }

    func saveStateOnly(_ newState: StoredState) throws {
        do {
            try ensureDirectories()
            try backupIfPresent(locations.state, label: "state.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try writeSecure(encoder.encode(newState), to: locations.state)
            try pruneBackups(keeping: 40)
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

    private func installProfiles(_ filenames: [String]) throws {
        for filename in filenames {
            let url = locations.profile(filename)
            let original = profileText(filename)
            let updated = try ShellConfiguration.installManagedBlock(in: original, filename: filename)
            guard updated != original else { continue }
            try backupIfPresent(url, label: filename)
            try writeProfile(updated, to: url)
        }
    }

    private func managedProfileFilenames() -> [String] {
        let bashLoginCandidates = [".bash_profile", ".bash_login", ".profile"]
        let bashLogin = bashLoginCandidates.first {
            fileManager.fileExists(atPath: locations.profile($0).path)
        } ?? ".bash_profile"

        return [".zshrc", ".zprofile", ".bashrc", bashLogin]
    }

    private func removeManagedBlocks(except filenamesToKeep: Set<String>) throws {
        let knownProfiles = [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".bash_login", ".profile"]
        for filename in knownProfiles where !filenamesToKeep.contains(filename) {
            let url = locations.profile(filename)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let original = profileText(filename)
            guard original.contains(ShellConfiguration.markerStart) || original.contains(ShellConfiguration.markerEnd) else {
                continue
            }
            let updated = try ShellConfiguration.removeManagedBlock(from: original, filename: filename)
            guard updated != original.trimmingCharacters(in: .newlines) else { continue }
            try backupIfPresent(url, label: filename)
            let text = updated.isEmpty ? "" : updated + "\n"
            try writeProfile(text, to: url)
        }
    }

    func migrateToAllShells(_ newState: StoredState) throws {
        try save(newState)
    }

    private func writeProfile(_ text: String, to url: URL) throws {
        let existingPermissions = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        try Data(text.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: existingPermissions ?? NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    private func writeSecure(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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

private struct LaunchctlClient {
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
    @Published private(set) var sessionVariables: [SessionVariable] = []
    @Published private(set) var backups: [BackupRecord] = []
    @Published var statusMessage = "就绪"
    @Published var errorMessage: String?

    private let persistence: FilePersistence
    private let launchctl = LaunchctlClient()

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        persistence = FilePersistence(home: home)
        do {
            let hadStoredState = persistence.hasStoredState
            var loadedState = try persistence.load()

            if hadStoredState, loadedState.version < 3 {
                loadedState.version = 3
                try persistence.migrateToAllShells(loadedState)
                statusMessage = "已应用到 Bash 与 Zsh；新终端会话生效"
            }
            state = loadedState
            try persistence.ensureDirectories()
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshSessionVariables()
        refreshBackups()
    }

    var variables: [ManagedVariable] {
        state.variables.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var pathEntries: [PathEntry] { state.pathEntries }
    var backupFolder: URL { persistence.locations.backups }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func upsertVariable(id: UUID?, name rawName: String, value: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        try ShellConfiguration.validateVariable(name: name, value: value)

        var next = state
        if let id, let index = next.variables.firstIndex(where: { $0.id == id }) {
            if next.variables.contains(where: { $0.id != id && $0.name == name }) {
                throw EnvironmentManagerError.duplicateName(name)
            }
            next.variables[index].name = name
            next.variables[index].value = value
        } else {
            guard !next.variables.contains(where: { $0.name == name }) else {
                throw EnvironmentManagerError.duplicateName(name)
            }
            next.variables.append(ManagedVariable(name: name, value: value))
        }

        try commit(next)
        let conflicts = persistence.unmanagedDefinitionLocations(for: name)
        statusMessage = conflicts.isEmpty
            ? "已保存；新终端会话生效"
            : "已保存；\(conflicts.joined(separator: ", ")) 存在同名定义"
    }

    func removeVariable(id: UUID) throws {
        var next = state
        next.variables.removeAll { $0.id == id }
        try commit(next)
        statusMessage = "已删除；新终端会话生效"
    }

    func addPath(_ rawPath: String) throws {
        let path = try ShellConfiguration.normalizePath(rawPath, home: persistence.locations.home)
        guard !state.pathEntries.contains(where: { $0.path == path }) else {
            throw EnvironmentManagerError.duplicatePath(path)
        }
        var next = state
        next.pathEntries.append(PathEntry(path: path))
        try commit(next)
        statusMessage = "PATH 已更新；新终端会话生效"
    }

    func removePath(id: UUID) throws {
        var next = state
        next.pathEntries.removeAll { $0.id == id }
        try commit(next)
        statusMessage = "PATH 已更新；新终端会话生效"
    }

    func movePath(id: UUID, offset: Int) throws {
        guard let source = state.pathEntries.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard state.pathEntries.indices.contains(destination) else { return }
        var next = state
        next.pathEntries.swapAt(source, destination)
        try commit(next)
        statusMessage = "PATH 顺序已更新"
    }

    func setSessionVariable(name rawName: String, value: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        try ShellConfiguration.validateVariable(name: name, value: value)
        guard !value.isEmpty else {
            throw EnvironmentManagerError.emptySessionValue
        }
        let previous = try launchctl.value(for: name)
        try launchctl.set(name: name, value: value)

        var next = state
        if !next.sessionNames.contains(name) {
            next.sessionNames.append(name)
            next.sessionNames.sort()
        }

        do {
            try persistence.saveStateOnly(next)
            state = next
        } catch {
            if let previous {
                try? launchctl.set(name: name, value: previous)
            } else {
                try? launchctl.unset(name: name)
            }
            throw error
        }

        refreshSessionVariables()
        refreshBackups()
        statusMessage = "已应用到当前 GUI 登录会话"
    }

    func removeSessionVariable(name: String) throws {
        let previous = try launchctl.value(for: name)
        try launchctl.unset(name: name)
        var next = state
        next.sessionNames.removeAll { $0 == name }
        do {
            try persistence.saveStateOnly(next)
            state = next
        } catch {
            if let previous {
                try? launchctl.set(name: name, value: previous)
            }
            throw error
        }
        refreshSessionVariables()
        refreshBackups()
        statusMessage = "已从当前 GUI 登录会话移除"
    }

    func refreshSessionVariables() {
        sessionVariables = state.sessionNames.sorted().map { name in
            SessionVariable(name: name, value: try? launchctl.value(for: name))
        }
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

    private func commit(_ next: StoredState) throws {
        try persistence.save(next)
        state = next
        refreshBackups()
    }
}
