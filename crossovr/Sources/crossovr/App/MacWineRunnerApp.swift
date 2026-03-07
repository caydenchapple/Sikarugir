import SwiftUI
import AppKit

// Forces the app into .regular activation policy so windows receive
// keyboard events when launched as a plain executable (not a .app bundle).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct MacWineRunnerApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var bottleManager    = BottleManager.shared
    @StateObject private var engineDownloader = EngineDownloader.shared
    @StateObject private var systemDetector   = SystemDetector.shared
    @StateObject private var catalog          = AppCatalogManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bottleManager)
                .environmentObject(engineDownloader)
                .environmentObject(systemDetector)
                .environmentObject(catalog)
                .frame(minWidth: 920, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(bottleManager)
                .environmentObject(engineDownloader)
                .environmentObject(systemDetector)
        }
    }
}

// MARK: - Menu Commands

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Install Application…") {
                NotificationCenter.default.post(name: .createBottle, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command])
        }
    }
}

extension Notification.Name {
    static let createBottle = Notification.Name("MacWineRunner.createBottle")
}
