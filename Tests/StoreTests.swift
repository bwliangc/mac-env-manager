import Foundation

@main
@MainActor
struct StoreTests {
    private static var checks = 0

    static func main() throws {
        try testAllShellPersistence()
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

        let store = EnvironmentStore(home: root)
        try store.upsertVariable(id: nil, name: "STORE_TEST", value: "hello world")

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
        try expect(
            try shellValue(executable: "/bin/bash", arguments: ["-lic"], home: root, expression: "$STORE_TEST") == "updated",
            "updated value reaches all profiles"
        )
        expect(!store.backups.isEmpty, "updates create backups")
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
          "sessionNames": []
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

        let store = EnvironmentStore(home: root)
        expect(store.state.version == 3, "legacy state migrates to version 3")

        for filename in [".zshrc", ".zprofile", ".bashrc", ".bash_profile"] {
            let text = try String(contentsOf: root.appendingPathComponent(filename))
            expect(text.contains(ShellConfiguration.markerStart), "migration installs \(filename)")
        }

        let staleText = try String(contentsOf: root.appendingPathComponent(".bash_login"))
        expect(!staleText.contains(ShellConfiguration.markerStart), "inactive Bash login block is removed")
        expect(staleText.contains("export KEEP_STALE=1"), "inactive profile content is preserved")

        let migratedState = try String(contentsOf: appSupport.appendingPathComponent("state.json"))
        expect(!migratedState.contains("\"profile\""), "obsolete profile selection is removed from state")
        try expect(
            try shellValue(executable: "/bin/bash", arguments: ["-lic"], home: root, expression: "$MIGRATION_TEST") == "migrated",
            "Bash loads migrated variable"
        )
        try expect(
            try shellValue(executable: "/bin/zsh", arguments: ["-lic"], home: root, expression: "$MIGRATION_TEST") == "migrated",
            "Zsh loads migrated variable"
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
        initialPath: String = "/usr/bin:/bin"
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments + ["printf '%s' \"\(expression)\""]
        process.environment = ["HOME": home.path, "PATH": initialPath]
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
