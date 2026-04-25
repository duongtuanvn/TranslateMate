import SwiftUI
import AppKit

@main
struct TranslateMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings scene không tự mở window - app là menu bar only.
        // Window settings được mở qua AppDelegate.openSettings().
        Settings {
            EmptyView()
        }
    }
}
