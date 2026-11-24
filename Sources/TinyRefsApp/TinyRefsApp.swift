import AppKit
import Foundation
import OSLog
import SwiftUI
import TinyRefs

@main
struct TinyRefsApp: App {
    @NSApplicationDelegateAdaptor(DesktopAppDelegate.self) private var appDelegate

    private let directory = ProcessInfo.processInfo.environment["TINYREFS_LIBRARY_DIRECTORY"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? SQLiteLibrary.defaultDirectoryURL

    var body: some Scene {
        WindowGroup("TinyRefs") {
            LibraryWindow(directory: directory)
                .frame(minWidth: 760, minHeight: 460)
        }
        .defaultSize(width: 1190, height: 740)
        .windowToolbarStyle(.unified)
        .commands { LibraryCommands() }
    }
}

@MainActor
private final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    private let isUnbundled = Bundle.main.bundleURL.pathExtension != "app"

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard isUnbundled, let app = notification.object as? NSApplication,
              app.activationPolicy() != .regular else { return }
        if !app.setActivationPolicy(.regular) {
            Logger(subsystem: "org.tinyrefs.app", category: "Lifecycle")
                .error("Could not enable desktop activation for the SwiftPM executable.")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isUnbundled, let app = notification.object as? NSApplication else { return }
        app.activate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard isUnbundled, let app = notification.object as? NSApplication, app.keyWindow == nil else { return }
        app.windows.first(where: { $0.isVisible && $0.canBecomeKey })?.makeKey()
    }
}
