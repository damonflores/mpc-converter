import AppKit
import SwiftUI

@main
struct MPCConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var model: ConverterModel

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _model = StateObject(wrappedValue: ConverterModel(settings: s))
    }

    var body: some Scene {
        Window("MPC Converter", id: "main") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1080, height: 780)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no bundle); harmless inside the .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
