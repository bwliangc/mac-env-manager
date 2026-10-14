import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: EnvironmentStore
    @State private var selectedSection: AppSection? = .variables

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(AppSection.allCases, selection: $selectedSection) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            } detail: {
                switch selectedSection ?? .variables {
                case .variables:
                    EnvironmentVariablesView()
                case .path:
                    PathEntriesView()
                }
            }

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
            DetailHeader(title: "环境变量", subtitle: "7 种 Shell 与当前 GUI 会话 · 自动同步") {
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
            columnHeader(name: "变量名", value: "变量值")
            Divider()

            ZStack {
                List(store.variables, selection: $selectedID) { variable in
                    HStack(spacing: 16) {
                        Text(variable.name)
                            .font(.system(.body, design: .monospaced).weight(.medium))
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
                initialValue: context.variable?.value ?? ""
            ) { name, value in
                try store.upsertVariable(id: context.variable?.id, name: name, value: value)
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

struct PathEntriesView: View {
    @EnvironmentObject private var store: EnvironmentStore
    @State private var selectedID: UUID?
    @State private var showsEditor = false
    @State private var confirmsDelete = false

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return store.pathEntries.firstIndex { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "PATH", subtitle: "7 种 Shell · 优先级从上到下") {
                HStack(spacing: 10) {
                    IconButton(systemImage: "plus", help: "添加目录") { showsEditor = true }
                    IconButton(
                        systemImage: "arrow.up",
                        help: "提高优先级",
                        disabled: selectedIndex == nil || selectedIndex == 0
                    ) {
                        moveSelected(by: -1)
                    }
                    IconButton(
                        systemImage: "arrow.down",
                        help: "降低优先级",
                        disabled: selectedIndex == nil || selectedIndex == store.pathEntries.count - 1
                    ) {
                        moveSelected(by: 1)
                    }
                    IconButton(systemImage: "trash", help: "删除目录", disabled: selectedID == nil) {
                        confirmsDelete = true
                    }
                }
            }

            Divider()
            columnHeader(name: "目录", value: "状态")
            Divider()

            ZStack {
                List(store.pathEntries, selection: $selectedID) { entry in
                    HStack(spacing: 16) {
                        Text(entry.path)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 12)
                        if FileManager.default.fileExists(atPath: entry.path) {
                            Label("可用", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("未找到", systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                    .tag(entry.id)
                    .contextMenu {
                        Button("删除", role: .destructive) {
                            selectedID = entry.id
                            confirmsDelete = true
                        }
                    }
                }
                .listStyle(.inset)

                if store.pathEntries.isEmpty {
                    EmptyListState(title: "暂无 PATH 条目", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
        }
        .sheet(isPresented: $showsEditor) {
            PathEditorSheet { path in
                try store.addPath(path)
            }
        }
        .confirmationDialog("删除所选 PATH 条目？", isPresented: $confirmsDelete) {
            Button("删除", role: .destructive) {
                guard let id = selectedID else { return }
                do {
                    try store.removePath(id: id)
                    selectedID = nil
                } catch {
                    store.present(error)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: store.pathEntries) { entries in
            if let selectedID, !entries.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        }
    }

    private func moveSelected(by offset: Int) {
        guard let selectedID else { return }
        do {
            try store.movePath(id: selectedID, offset: offset)
        } catch {
            store.present(error)
        }
    }
}

private func columnHeader(name: String, value: String) -> some View {
    HStack(spacing: 16) {
        Text(name)
            .frame(width: 230, alignment: .leading)
        Text(value)
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
