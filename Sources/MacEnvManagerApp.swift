import SwiftUI

@main
struct MacEnvManagerApp: App {
    @StateObject private var store = EnvironmentStore()

    var body: some Scene {
        Window("环境变量管理器", id: "main") {
            ContentView()
                .environmentObject(store)
                .tint(Color(red: 0.08, green: 0.58, blue: 0.38))
        }
        .defaultSize(width: 900, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Divider()
                Button("打开备份文件夹") {
                    store.revealBackupFolder()
                }
            }
        }
    }
}
