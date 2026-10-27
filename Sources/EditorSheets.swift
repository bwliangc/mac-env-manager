import SwiftUI

struct VariableEditorContext: Identifiable {
    let id = UUID()
    let variable: ManagedVariable?
}

struct VariableEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    let title: String
    let initialName: String
    let initialValue: String
    let onSave: (String, String, Bool) throws -> Void

    @State private var name: String
    @State private var value: String
    @State private var isEnabled: Bool
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
        initialIsEnabled: Bool = false,
        onSave: @escaping (String, String, Bool) throws -> Void
    ) {
        self.title = title
        self.initialName = initialName
        self.initialValue = initialValue
        self.onSave = onSave
        _name = State(initialValue: initialName)
        _value = State(initialValue: initialValue)
        _isEnabled = State(initialValue: initialIsEnabled)
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

                Toggle("启用此变量", isOn: $isEnabled)
                    .toggleStyle(.checkbox)
                    .help("勾选后同步启用；取消勾选仅保存变量")

                if looksSensitive {
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
        .frame(width: 460, height: looksSensitive ? 350 : 320)
        .onAppear {
            focusedField = .name
        }
    }

    private func save() {
        do {
            try onSave(name, value, isEnabled)
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
