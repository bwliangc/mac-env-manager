import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: EnvironmentStore

    var body: some View {
        VStack(spacing: 0) {
            EnvironmentVariablesView()

            Divider()
            StatusBar()
        }
        .frame(minWidth: 900, minHeight: 520)
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            ),
            actions: {
                Button("好", role: .cancel) { store.errorMessage = nil }
            },
            message: {
                Text(store.errorMessage ?? "未知错误")
            }
        )
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var store: EnvironmentStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(store.statusMessage)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("备份 \(store.backups.count)")
                .foregroundStyle(.secondary)
            Button {
                store.revealBackupFolder()
            } label: {
                Image(systemName: "folder")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示备份")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }
}

private struct DetailHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 18)
        .frame(height: 70)
        .background(.background)
    }
}

private struct IconButton: View {
    let systemImage: String
    let help: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
    }
}

struct EnvironmentVariablesView: View {
    @EnvironmentObject private var store: EnvironmentStore
    @State private var selectedID: UUID?
    @State private var editor: VariableEditorContext?
    @State private var revealsValues = false
    @State private var confirmsDelete = false

    private var selectedVariable: ManagedVariable? {
        store.variables.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "环境变量", subtitle: "勾选启用 · 同步到 7 种 Shell 与当前 GUI 会话") {
                HStack(spacing: 10) {
                    IconButton(
                        systemImage: revealsValues ? "eye.slash" : "eye",
                        help: revealsValues ? "隐藏变量值" : "显示变量值"
                    ) {
                        revealsValues.toggle()
                    }
                    IconButton(systemImage: "plus", help: "添加变量") {
                        editor = VariableEditorContext(variable: nil)
                    }
                    IconButton(systemImage: "pencil", help: "编辑变量", disabled: selectedVariable == nil) {
                        if let selectedVariable {
                            editor = VariableEditorContext(variable: selectedVariable)
                        }
                    }
                    IconButton(systemImage: "trash", help: "删除变量", disabled: selectedVariable == nil) {
                        confirmsDelete = true
                    }
                }
            }

            Divider()
            columnHeader()
            Divider()

            ZStack {
                List(store.variables, selection: $selectedID) { variable in
                    HStack(spacing: 16) {
                        Toggle("启用", isOn: Binding(
                            get: { variable.isEnabled },
                            set: { isEnabled in
                                do {
                                    try store.setVariableEnabled(id: variable.id, isEnabled: isEnabled)
                                } catch {
                                    store.present(error)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("启用 \(variable.name)")
                        .help(variable.isEnabled ? "取消勾选以停用，保留变量" : "勾选以启用变量")
                        .frame(width: 50)
                        Text(variable.name)
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .foregroundStyle(variable.isEnabled ? .primary : .secondary)
                            .frame(width: 230, alignment: .leading)
                        Text(revealsValues ? variable.value : maskedValue(variable.value))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(revealsValues ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .tag(variable.id)
                    .contextMenu {
                        Button("编辑") { editor = VariableEditorContext(variable: variable) }
                        Button(variable.isEnabled ? "停用" : "启用") {
                            do {
                                try store.setVariableEnabled(id: variable.id, isEnabled: !variable.isEnabled)
                            } catch {
                                store.present(error)
                            }
                        }
                        Button("删除", role: .destructive) {
                            selectedID = variable.id
                            confirmsDelete = true
                        }
                    }
                    .onTapGesture(count: 2) {
                        selectedID = variable.id
                        editor = VariableEditorContext(variable: variable)
                    }
                }
                .listStyle(.inset)

                if store.variables.isEmpty {
                    EmptyListState(title: "暂无环境变量", systemImage: "terminal")
                }
            }
        }
        .sheet(item: $editor) { context in
            VariableEditorSheet(
                title: context.variable == nil ? "添加环境变量" : "编辑环境变量",
                initialName: context.variable?.name ?? "",
                initialValue: context.variable?.value ?? "",
                initialIsEnabled: context.variable?.isEnabled ?? false
            ) { name, value, isEnabled in
                try store.upsertVariable(id: context.variable?.id, name: name, value: value, isEnabled: isEnabled)
            }
        }
        .confirmationDialog("删除所选变量？", isPresented: $confirmsDelete) {
            Button("删除", role: .destructive) {
                guard let id = selectedID else { return }
                do {
                    try store.removeVariable(id: id)
                    selectedID = nil
                } catch {
                    store.present(error)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: store.variables) { variables in
            if let selectedID, !variables.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        }
    }
}

private func columnHeader() -> some View {
    HStack(spacing: 16) {
        Text("启用")
            .frame(width: 50)
        Text("变量名")
            .frame(width: 230, alignment: .leading)
        Text("变量值")
        Spacer()
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 28)
    .frame(height: 30)
    .background(Color(nsColor: .controlBackgroundColor))
}

private func maskedValue(_ value: String) -> String {
    String(repeating: "•", count: min(max(value.count, 6), 14))
}
