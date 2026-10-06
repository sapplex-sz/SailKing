import SwiftUI

@main
struct HaiwangApp: App {
    @NSApplicationDelegateAdaptor(HaiwangApplicationDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup(hw("出海王输入法", "SailKing")) {
            SharedWorkspaceView()
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 980, height: 640)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu(hw("跨语言输入", "Translate & Type")) {
                Button(hw("输入法新手设置", "Keyboard setup guide")) {
                    NotificationCenter.default.post(name: .inputMethodSetupRequested, object: nil)
                }
                Divider()
                Button(hw("打开输入面板", "Open Input Panel")) { delegate.showComposer() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
            }
        }
    }
}
