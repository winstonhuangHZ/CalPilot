import AppKit
import SwiftUI

/// The double-clickable CalPilot window.
///
/// The CLI is the same engine; this target only draws it. Everything that touches the
/// calendar still goes through `CalPilotCore`, so the write fencing and the journal apply
/// here exactly as they do on the command line.
@main
struct CalPilotGUI: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("CalPilot") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 900, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("CalPilot") {
                Button("Settings…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Undo Last Batch") { model.undoLastBatch() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Divider()
                Button("Reload Calendar") {
                    Task { await model.reloadCalendar(force: true) }
                }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without this a SwiftUI binary launched from a bundle-less context stays an
        // accessory process and never brings a window forward.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
