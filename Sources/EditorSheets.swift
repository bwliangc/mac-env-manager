import AppKit
import SwiftUI

struct VariableEditorContext: Identifiable {
    let id = UUID()
    let variable: ManagedVariable?
}

struct SessionEditorContext: Identifiable {
    let id = UUID()
    let variable: SessionVariable?
}

struct VariableEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    let title: String
    let initialName: String
    let initialValue: String
    let locksName: Bool
    let storesPlaintext: Bool
    let onSave: (String, String) throws -> Void

    @State private var name: String
    @State private var value: String
    @State private var revealsValue = false
    @State private var errorMessage: String?

    private enum Field {
        case name
        case value
    }

    init(
        title: String,
        initialName: String = "",
        initialValue: String = "",
        locksName: Bool = false,
        storesPlaintext: Bool,
        onSave: @escaping (String, String) throws -> Void
    ) {
        self.title = title
        self.initialName = initialName
        self.initialValue = initialValue
        self.locksName = locksName
        self.storesPlaintext = storesPlaintext
        self.onSave = onSave
        _name = State(initialValue: initialName)
        _value = State(initialValue: initialValue)
    }

    private var looksSensitive: Bool {
        let upper = name.uppercased()
        return ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "CREDENTIAL"]
            .contains { upper.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                TextField("变量名", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(locksName)
                    .focused($focusedField, equals: .name)

                HStack(spacing: 8) {
                    Group {
                        if revealsValue {
                            TextField("变量值", text: $value)
                        } else {
                            SecureField("变量值", text: $value)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($focusedField, equals: .value)

                    Button {
                        revealsValue.toggle()
                    } label: {
                        Image(systemName: revealsValue ? "eye.slash" : "eye")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(revealsValue ? "隐藏变量值" : "显示变量值")
                }

                if storesPlaintext && looksSensitive {
                    Label("该值会以仅当前用户可读的明文保存", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 4)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: storesPlaintext && looksSensitive ? 310 : 280)
        .onAppear {
            focusedField = locksName ? .value : .name
        }
    }

    private func save() {
        do {
            try onSave(name, value)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PathEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    let onSave: (String) throws -> Void

    @State private var path = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加 PATH 条目")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                HStack(spacing: 8) {
                    TextField("/opt/example/bin", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .focused($isFocused)

                    Button {
                        chooseDirectory()
                    } label: {
                        Image(systemName: "folder")
                            .frame(width: 18, height: 18)
                    }
                    .help("选择文件夹")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 4)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 500, height: 230)
        .onAppear { isFocused = true }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func save() {
        do {
            try onSave(path)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct EmptyListState: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
