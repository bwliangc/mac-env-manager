import Foundation

@main
struct CoreTests {
    private static var checks = 0

    static func main() throws {
        try testShellQuotingAndExecution()
        try testManagedProfileBlock()
        try testMalformedProfileProtection()
        try testVariableDefaultsAndCoding()
        testConflictDetection()
        print("CoreTests passed: \(checks) checks")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func testShellQuotingAndExecution() throws {
        expect(ShellConfiguration.shellQuote("a'b") == "'a'\\''b'", "single quotes are escaped")

        let variables = [
            ManagedVariable(name: "PLAIN", value: "hello world", isEnabled: true),
            ManagedVariable(name: "QUOTED", value: "a'b", isEnabled: true),
            ManagedVariable(name: "DISABLED", value: "disabled-secret")
        ]
        let rendered = ShellConfiguration.renderEnvironmentFile(variables: variables)
        expect(!rendered.contains("disabled-secret"), "disabled values are omitted from the shell file")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEnvManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("environment.zsh")
        try rendered.write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            "PATH=/usr/bin; export DISABLED=stale; source \"$1\"; printf '%s\\n%s\\n%s\\n%s' \"$PLAIN\" \"$QUOTED\" \"$PATH\" \"${DISABLED+x}\"",
            "test",
            file.path
        ]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        expect(process.terminationStatus == 0, "rendered file is valid zsh")
        expect(result == "hello world\na'b\n/usr/bin\n", "enabled values load, disabled inheritance clears, PATH is preserved")
    }

    private static func testManagedProfileBlock() throws {
        let original = "export EXISTING=1\n"
        let installed = try ShellConfiguration.installManagedBlock(in: original, filename: ".zshrc")
        expect(installed.contains(original.trimmingCharacters(in: .newlines)), "existing profile content is preserved")
        expect(installed.components(separatedBy: ShellConfiguration.markerStart).count == 2, "one managed block is installed")

        let installedAgain = try ShellConfiguration.installManagedBlock(in: installed, filename: ".zshrc")
        expect(installedAgain == installed, "install is idempotent")

        let removed = try ShellConfiguration.removeManagedBlock(from: installed, filename: ".zshrc")
        expect(removed == original.trimmingCharacters(in: .newlines), "managed block can be removed")
    }

    private static func testMalformedProfileProtection() throws {
        let malformed = "export A=1\n\(ShellConfiguration.markerStart)\nsource broken\n"
        do {
            _ = try ShellConfiguration.installManagedBlock(in: malformed, filename: ".zshrc")
            expect(false, "malformed marker must throw")
        } catch EnvironmentManagerError.malformedProfile {
            expect(true, "malformed marker is rejected")
        }
    }

    private static func testVariableDefaultsAndCoding() throws {
        let variable = ManagedVariable(name: "NEW_TEST", value: "saved")
        expect(!variable.isEnabled, "new variables default to disabled")
        let encoded = try JSONEncoder().encode(variable)
        let decoded = try JSONDecoder().decode(ManagedVariable.self, from: encoded)
        expect(decoded == variable && !decoded.isEnabled, "disabled state survives encoding and decoding")
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"LEGACY_TEST","value":"legacy"}
        """
        let migrated = try JSONDecoder().decode(ManagedVariable.self, from: Data(legacy.utf8))
        expect(migrated.isEnabled, "legacy variables remain enabled")
    }

    private static func testConflictDetection() {
        let profile = "export FIRST=1\nSECOND=2\n"
        expect(ShellConfiguration.unmanagedDefinitionLines(for: "FIRST", in: profile) == [1], "export conflict is found")
        expect(ShellConfiguration.unmanagedDefinitionLines(for: "SECOND", in: profile) == [2], "assignment conflict is found")
        expect(ShellConfiguration.unmanagedDefinitionLines(for: "THIRD", in: profile).isEmpty, "missing definition is ignored")
    }
}
