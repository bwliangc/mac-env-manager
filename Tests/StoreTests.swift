import Foundation

private final class FakeLaunchctlClient: LaunchctlManaging {
    var values: [String: String]
    var failingSets: Set<String> = []
    var failingUnsets: Set<String> = []

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func value(for name: String) throws -> String? {
        values[name]
    }

    func set(name: String, value: String) throws {
        guard !failingSets.contains(name) else {
            throw EnvironmentManagerError.launchctl("测试中的 setenv 失败")
        }
        values[name] = value
    }

    func unset(name: String) throws {
        guard !failingUnsets.contains(name) else {
            throw EnvironmentManagerError.launchctl("测试中的 unsetenv 失败")
        }
        values.removeValue(forKey: name)
    }
}

private final class FailingFileManager: FileManager, @unchecked Sendable {
    var failingFilename: String?

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if URL(fileURLWithPath: path).lastPathComponent == failingFilename {
            failingFilename = nil
            throw EnvironmentManagerError.storage("测试中的写盘中断")
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

@main
@MainActor
struct StoreTests {
    private static var checks = 0

    static func main() throws {
        try testAllShellPersistence()
        try testSevenShellFamilies()
        try testCustomPOSIXStartupAndRepair()
        try testRenameRemovalAndStartupSync()
        try testLaunchctlFailureDoesNotPersist()
        try testPersistenceFailureRollsBackGUIEnvironment()
        try testPartialWriteRollback()
        try testLegacyMigration()
        print("StoreTests passed: \(checks) checks")
    }

    private static func testAllShellPersistence() throws {
        let root = temporaryHome(named: "AllShells")
        defer { try? FileManager.default.removeItem(at: root) }

        try "export KEEP_PROFILE=1\n".write(
            to: root.appendingPathComponent(".profile"),
            atomically: true,
            encoding: .utf8
        )

        let launchctl = FakeLaunchctlClient()
        let store = EnvironmentStore(home: root, launchctl: launchctl)
        try store.upsertVariable(id: nil, name: "STORE_TEST", value: "hello world")
        expect(launchctl.values["STORE_TEST"] == "hello world", "new variable reaches the GUI session")

        let appSupport = root
            .appendingPathComponent("Library/Application Support/MacEnvManager", isDirectory: true)
        let stateURL = appSupport.appendingPathComponent("state.json")
        let environmentURL = appSupport.appendingPathComponent("environment.zsh")

        expect(FileManager.default.fileExists(atPath: stateURL.path), "state file is created")
        expect(FileManager.default.fileExists(atPath: environmentURL.path), "environment file is created")
        expect(permissions(of: stateURL) == 0o600, "state file permissions are 0600")
        expect(permissions(of: environmentURL) == 0o600, "environment file permissions are 0600")

        for filename in [".zshrc", ".zprofile", ".bashrc", ".profile"] {
            let text = try String(contentsOf: root.appendingPathComponent(filename))
            expect(text.contains(ShellConfiguration.markerStart), "\(filename) integration is installed")
        }
        expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent(".bash_profile").path),
            "existing .profile remains the Bash login target"
        )

        try expect(
            try shellValue(executable: "/bin/zsh", arguments: ["-ic"], home: root, expression: "$STORE_TEST") == "hello world",
            "interactive Zsh loads managed variable"
        )
        try expect(
            try shellValue(executable: "/bin/zsh", arguments: ["-lic"], home: root, expression: "$STORE_TEST") == "hello world",
            "login Zsh loads managed variable"
        )
        try expect(
            try shellValue(executable: "/bin/bash", arguments: ["-ic"], home: root, expression: "$STORE_TEST") == "hello world",
            "interactive Bash loads managed variable"
        )
        try expect(
            try shellValue(executable: "/bin/bash", arguments: ["-lic"], home: root, expression: "$STORE_TEST") == "hello world",
            "login Bash loads managed variable"
        )

        let bin = root.appendingPathComponent("tools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try store.addPath(bin.path)
        let zshPath = try shellValue(
            executable: "/bin/zsh",
            arguments: ["-ic"],
            home: root,
            expression: "$PATH",
            initialPath: "/usr/bin:/bin"
        )
        let bashPath = try shellValue(
            executable: "/bin/bash",
            arguments: ["-ic"],
            home: root,
            expression: "$PATH",
            initialPath: "/usr/bin:/bin"
        )
        expect(zshPath.hasPrefix(bin.path + ":"), "Zsh receives managed PATH")
        expect(bashPath.hasPrefix(bin.path + ":"), "Bash receives managed PATH")

        let variableID = try required(store.variables.first?.id, "saved variable has an id")
        try store.upsertVariable(id: variableID, name: "STORE_TEST", value: "updated")
        expect(launchctl.values["STORE_TEST"] == "updated", "updated value reaches the GUI session")
        try expect(
            try shellValue(executable: "/bin/bash", arguments: ["-lic"], home: root, expression: "$STORE_TEST") == "updated",
            "updated value reaches all profiles"
        )
        expect(!store.backups.isEmpty, "updates create backups")
    }

    private static func testRenameRemovalAndStartupSync() throws {
        let root = temporaryHome(named: "Lifecycle")
        defer { try? FileManager.default.removeItem(at: root) }

        let firstLaunchctl = FakeLaunchctlClient()
        let store = EnvironmentStore(home: root, launchctl: firstLaunchctl)
        try store.upsertVariable(id: nil, name: "ORIGINAL_NAME", value: "managed")
        let variableID = try required(store.variables.first?.id, "lifecycle variable has an id")

        firstLaunchctl.values["RENAMED_VALUE"] = "external"
        try store.upsertVariable(id: variableID, name: "RENAMED_VALUE", value: "renamed")
        expect(firstLaunchctl.values["ORIGINAL_NAME"] == nil, "rename removes the old GUI name")
        expect(firstLaunchctl.values["RENAMED_VALUE"] == "renamed", "rename sets the new GUI name")

        try store.removeVariable(id: variableID)
        expect(firstLaunchctl.values["RENAMED_VALUE"] == nil, "delete removes the GUI variable")

        try store.upsertVariable(id: nil, name: "STARTUP_SYNC", value: "restored")
        let secondLaunchctl = FakeLaunchctlClient()
        let reloadedStore = EnvironmentStore(home: root, launchctl: secondLaunchctl)
        expect(reloadedStore.variables.contains(where: { $0.name == "STARTUP_SYNC" }), "saved variable reloads")
        expect(secondLaunchctl.values["STARTUP_SYNC"] == "restored", "launch restores the GUI session")
    }

    private static func testSevenShellFamilies() throws {
        let root = temporaryHome(named: "SevenShells")
        defer { try? FileManager.default.removeItem(at: root) }
        // Real configurations may already have distinct Bash and C-shell files.
        for filename in [".bash_profile", ".tcshrc", ".cshrc", ".profile"] {
            try "# Existing user configuration\n".write(to: root.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        let launchctl = FakeLaunchctlClient()
        let store = EnvironmentStore(home: root, launchctl: launchctl)
        let specialValue = "  中文 a'b\" $HOME `uname` \\ !history ; $(uname) * [x]\t  "
        try store.upsertVariable(id: nil, name: "ALL_SHELL_TEST", value: specialValue)
        try store.upsertVariable(id: nil, name: "EMPTY_TEST", value: "")
        let firstPath = root.appendingPathComponent("tools with spaces/[x]!/bin").path
        let secondPath = root.appendingPathComponent("second/bin").path
        try store.addPath(firstPath)
        try store.addPath(secondPath)

        let executables = ["/bin/bash", "/opt/homebrew/bin/bash", "/bin/zsh", "/bin/sh", "/bin/dash", "/bin/ksh", "/bin/csh", "/bin/tcsh"]
        let posixENV = try required(launchctl.values["ENV"], "GUI session receives the POSIX startup bridge")
        for executable in executables where FileManager.default.isExecutableFile(atPath: executable) {
            let isCsh = executable.hasSuffix("csh")
            let modes = isCsh ? [["-c"], ["-l"]] : [["-ic"], ["-lic"]]
            for arguments in modes {
                let bridge = arguments == ["-ic"] ? ["ENV": posixENV] : [:]
                let value = try shellValue(executable: executable, arguments: arguments, home: root, expression: "$ALL_SHELL_TEST", additionalEnvironment: bridge)
                expect(value == specialValue, "\(executable) \(arguments) preserves special characters")
                let path = try shellValue(executable: executable, arguments: arguments, home: root, expression: "$PATH", additionalEnvironment: bridge)
                expect(path.hasPrefix(firstPath + ":" + secondPath + ":"), "\(executable) \(arguments) preserves PATH order and spaces")
                expect(path.components(separatedBy: ":").filter { $0 == firstPath }.count == 1, "\(executable) \(arguments) does not duplicate PATH")
                let empty = try shellValue(executable: executable, arguments: arguments, home: root, expression: "$EMPTY_TEST", additionalEnvironment: bridge)
                expect(empty.isEmpty, "\(executable) \(arguments) preserves an empty value")
            }
        }
        for filename in [".profile", ".shrc", ".kshrc", ".cshrc", ".tcshrc", ".login", ".zshenv"] {
            let text = try String(contentsOf: root.appendingPathComponent(filename))
            expect(text.contains(ShellConfiguration.markerStart), "new integration installs \(filename)")
        }
        let support = root.appendingPathComponent("Library/Application Support/MacEnvManager")
        for filename in ["environment.zsh", "environment.csh", "posix-init.sh"] {
            expect(permissions(of: support.appendingPathComponent(filename)) == 0o600, "\(filename) is private")
        }
        expect(launchctl.values["PATH"] == nil, "terminal PATH never changes the GUI PATH")

        let variableID = try required(store.variables.first(where: { $0.name == "ALL_SHELL_TEST" })?.id, "unified variable has an id")
        try store.upsertVariable(id: variableID, name: "RENAMED_TEST", value: "updated")
        for executable in ["/bin/dash", "/bin/ksh", "/bin/tcsh"] {
            let arguments = executable.hasSuffix("csh") ? ["-c"] : ["-ic"]
            let value = try shellValue(executable: executable, arguments: arguments, home: root, expression: "$RENAMED_TEST", additionalEnvironment: ["ENV": posixENV])
            expect(value == "updated", "\(executable) receives a renamed variable")
        }
        try store.removeVariable(id: variableID)
        for filename in ["environment.zsh", "environment.csh"] {
            let text = try String(contentsOf: support.appendingPathComponent(filename))
            expect(!text.contains("RENAMED_TEST") && !text.contains("ALL_SHELL_TEST"), "delete removes both names from \(filename)")
        }
    }

    private static func testCustomPOSIXStartupAndRepair() throws {
        let root = temporaryHome(named: "CustomStartup")
        defer { try? FileManager.default.removeItem(at: root) }
        let customENV = root.appendingPathComponent("custom env.sh")
        try "export CUSTOM_STARTUP=preserved\nexport MANAGED_TEST=stale\n".write(to: customENV, atomically: true, encoding: .utf8)
        let launchctl = FakeLaunchctlClient(values: ["ENV": customENV.path])
        let store = EnvironmentStore(home: root, launchctl: launchctl)
        try store.upsertVariable(id: nil, name: "MANAGED_TEST", value: "managed")
        let bridge = [
            "ENV": try required(launchctl.values["ENV"], "custom ENV gets a bridge"),
            "_MAC_ENV_MANAGER_ORIGINAL_ENV": customENV.path
        ]
        expect(launchctl.values["_MAC_ENV_MANAGER_ORIGINAL_ENV"] == customENV.path, "original GUI ENV is preserved")
        for executable in ["/bin/sh", "/bin/dash", "/bin/ksh"] {
            let value = try shellValue(executable: executable, arguments: ["-ic"], home: root, expression: "$CUSTOM_STARTUP:$MANAGED_TEST", additionalEnvironment: bridge)
            expect(value == "preserved:managed", "\(executable) loads custom ENV before managed variables")
        }
        try "# Removed integration\n".write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let reloaded = EnvironmentStore(home: root, launchctl: launchctl)
        expect(reloaded.errorMessage == nil, "startup repairs missing integration")
        let repaired = try String(contentsOf: root.appendingPathComponent(".zshrc"))
        expect(repaired.contains("# Removed integration") && repaired.contains(ShellConfiguration.markerStart), "repair preserves user content")
        expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".tcshrc").path), "absence of .tcshrc preserves .cshrc loading")
    }

    private static func testPartialWriteRollback() throws {
        let root = temporaryHome(named: "PartialWrite")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FailingFileManager()
        let launchctl = FakeLaunchctlClient()
        let store = EnvironmentStore(home: root, launchctl: launchctl, fileManager: fileManager)
        try store.upsertVariable(id: nil, name: "PARTIAL_OLD", value: "original")
        let id = try required(store.variables.first?.id, "partial write variable has an id")
        let support = root.appendingPathComponent("Library/Application Support/MacEnvManager")
        let filenames = ["state.json", "environment.zsh", "environment.csh", "posix-init.sh"]
        let before = try filenames.map { try Data(contentsOf: support.appendingPathComponent($0)) }
        launchctl.values["PARTIAL_NEW"] = "external"
        fileManager.failingFilename = "environment.csh"
        do {
            try store.upsertVariable(id: id, name: "PARTIAL_NEW", value: "changed")
            expect(false, "partial disk write must reject the rename")
        } catch EnvironmentManagerError.storage {
            expect(true, "partial disk write rejects the rename")
        }
        for (index, filename) in filenames.enumerated() {
            try expect(Data(contentsOf: support.appendingPathComponent(filename)) == before[index], "rollback restores exact bytes of \(filename)")
        }
        expect(store.variables.first?.name == "PARTIAL_OLD", "partial write leaves in-memory state unchanged")
        expect(launchctl.values["PARTIAL_OLD"] == "original", "partial write restores old GUI variable")
        expect(launchctl.values["PARTIAL_NEW"] == "external", "partial write restores unrelated GUI value")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: support.appendingPathComponent("environment.csh").path)
        let reloaded = EnvironmentStore(home: root, launchctl: launchctl)
        expect(reloaded.errorMessage == nil, "unchanged configuration reloads successfully")
        expect(permissions(of: support.appendingPathComponent("environment.csh")) == 0o600, "startup repairs permissions even when file contents are unchanged")
    }

    private static func testPersistenceFailureRollsBackGUIEnvironment() throws {
        let root = temporaryHome(named: "Rollback")
        defer { try? FileManager.default.removeItem(at: root) }

        let launchctl = FakeLaunchctlClient()
        let store = EnvironmentStore(home: root, launchctl: launchctl)
        try store.upsertVariable(id: nil, name: "ROLLBACK_OLD", value: "original")
        let variableID = try required(store.variables.first?.id, "rollback variable has an id")

        try "keep=1\n\(ShellConfiguration.markerStart)\n".write(
            to: root.appendingPathComponent(".zshrc"),
            atomically: true,
            encoding: .utf8
        )
        launchctl.values["ROLLBACK_NEW"] = "external"

        do {
            try store.upsertVariable(id: variableID, name: "ROLLBACK_NEW", value: "changed")
            expect(false, "malformed profile must reject a rename")
        } catch EnvironmentManagerError.malformedProfile {
            expect(true, "malformed profile rejects a rename")
        }

        expect(store.variables.first?.name == "ROLLBACK_OLD", "failed rename keeps in-memory state")
        expect(launchctl.values["ROLLBACK_OLD"] == "original", "failed rename restores the old GUI name")
        expect(launchctl.values["ROLLBACK_NEW"] == "external", "failed rename restores the previous GUI value")

        let appSupport = root.appendingPathComponent("Library/Application Support/MacEnvManager")
        let stateText = try String(contentsOf: appSupport.appendingPathComponent("state.json"))
        let environmentText = try String(contentsOf: appSupport.appendingPathComponent("environment.zsh"))
        expect(stateText.contains("ROLLBACK_OLD") && !stateText.contains("ROLLBACK_NEW"), "failed rename restores state.json")
        expect(environmentText.contains("ROLLBACK_OLD") && !environmentText.contains("ROLLBACK_NEW"), "failed rename restores the environment file")
    }

    private static func testLaunchctlFailureDoesNotPersist() throws {
        let root = temporaryHome(named: "LaunchctlFailure")
        defer { try? FileManager.default.removeItem(at: root) }

        let launchctl = FakeLaunchctlClient()
        launchctl.failingSets.insert("SET_FAILURE")
        let store = EnvironmentStore(home: root, launchctl: launchctl)

        do {
            try store.upsertVariable(id: nil, name: "SET_FAILURE", value: "value")
            expect(false, "setenv failure must reject a new variable")
        } catch EnvironmentManagerError.launchctl {
            expect(true, "setenv failure rejects a new variable")
        }
        expect(store.variables.isEmpty, "setenv failure leaves state unchanged")

        try store.upsertVariable(id: nil, name: "UNSET_FAILURE", value: "value")
        let variableID = try required(store.variables.first?.id, "unset failure variable has an id")
        launchctl.failingUnsets.insert("UNSET_FAILURE")
        do {
            try store.removeVariable(id: variableID)
            expect(false, "unsetenv failure must reject deletion")
        } catch EnvironmentManagerError.launchctl {
            expect(true, "unsetenv failure rejects deletion")
        }
        expect(store.variables.first?.name == "UNSET_FAILURE", "unsetenv failure leaves persisted state unchanged")
        expect(launchctl.values["UNSET_FAILURE"] == "value", "unsetenv failure restores the GUI value")
    }

    private static func testLegacyMigration() throws {
        let root = temporaryHome(named: "Migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let appSupport = root
            .appendingPathComponent("Library/Application Support/MacEnvManager", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let variableID = UUID().uuidString
        let legacyJSON = """
        {
          "version": 2,
          "profile": "bash",
          "variables": [{"id": "\(variableID)", "name": "MIGRATION_TEST", "value": "migrated"}],
          "pathEntries": [],
          "sessionNames": ["MIGRATION_TEST", "LEGACY_GUI_ONLY", "MISSING_GUI_VALUE"]
        }
        """
        try Data(legacyJSON.utf8).write(to: appSupport.appendingPathComponent("state.json"))

        try "export KEEP_LOGIN=1\n".write(
            to: root.appendingPathComponent(".bash_profile"),
            atomically: true,
            encoding: .utf8
        )
        let staleBashLogin = try ShellConfiguration.installManagedBlock(
            in: "export KEEP_STALE=1\n",
            filename: ".bash_login"
        )
        try staleBashLogin.write(
            to: root.appendingPathComponent(".bash_login"),
            atomically: true,
            encoding: .utf8
        )

        let launchctl = FakeLaunchctlClient(values: [
            "MIGRATION_TEST": "stale-session-value",
            "LEGACY_GUI_ONLY": "legacy-gui-value"
        ])
        let store = EnvironmentStore(home: root, launchctl: launchctl)
        expect(store.state.version == StoredState.currentVersion, "legacy state migrates to the current version")
        expect(store.variables.contains(where: { $0.name == "LEGACY_GUI_ONLY" && $0.value == "legacy-gui-value" }), "legacy GUI-only value joins the unified list")
        expect(!store.variables.contains(where: { $0.name == "MISSING_GUI_VALUE" }), "missing legacy GUI value is skipped")
        expect(launchctl.values["MIGRATION_TEST"] == "migrated", "persistent value wins over a duplicate legacy GUI value")

        for filename in [".zshrc", ".zprofile", ".bashrc", ".bash_profile"] {
            let text = try String(contentsOf: root.appendingPathComponent(filename))
            expect(text.contains(ShellConfiguration.markerStart), "migration installs \(filename)")
        }

        let staleText = try String(contentsOf: root.appendingPathComponent(".bash_login"))
        expect(!staleText.contains(ShellConfiguration.markerStart), "inactive Bash login block is removed")
        expect(staleText.contains("export KEEP_STALE=1"), "inactive profile content is preserved")

        let migratedState = try String(contentsOf: appSupport.appendingPathComponent("state.json"))
        expect(!migratedState.contains("\"profile\""), "obsolete profile selection is removed from state")
        expect(!migratedState.contains("\"sessionNames\""), "obsolete GUI name list is removed from state")
        try expect(
            try shellValue(executable: "/bin/bash", arguments: ["-lic"], home: root, expression: "$MIGRATION_TEST") == "migrated",
            "Bash loads migrated variable"
        )
        try expect(
            try shellValue(executable: "/bin/zsh", arguments: ["-lic"], home: root, expression: "$MIGRATION_TEST") == "migrated",
            "Zsh loads migrated variable"
        )
        try expect(
            try shellValue(executable: "/bin/bash", arguments: ["-lic"], home: root, expression: "$LEGACY_GUI_ONLY") == "legacy-gui-value",
            "legacy GUI-only value reaches Bash"
        )
    }

    private static func temporaryHome(named name: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEnvManager\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        checks += 1
        guard try condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
        checks += 1
        return value
    }

    private static func permissions(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func shellValue(
        executable: String,
        arguments: [String],
        home: URL,
        expression: String,
        initialPath: String = "/usr/bin:/bin",
        additionalEnvironment: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        let command = "/usr/bin/printf '%s' \"\(expression)\""
        if arguments == ["-l"] {
            // Login argv[0] with -c exercises .login without forcing job control
            // in a test process with no tty (tcsh -l emits warnings on stdout).
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["--noprofile", "--norc", "-c", "exec -a \"$1\" \"$2\" -c \"$3\"", "login-test", "-" + URL(fileURLWithPath: executable).lastPathComponent, executable, command]
        } else {
            process.arguments = arguments + [command]
        }
        process.environment = ["HOME": home.path, "PATH": initialPath, "TERM": "dumb"].merging(additionalEnvironment) { _, new in new }
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw EnvironmentManagerError.storage("shell test failed: \(detail)")
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
