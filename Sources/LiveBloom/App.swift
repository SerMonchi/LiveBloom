import SwiftUI
import ServiceManagement

@main
struct LiveBloomApp: App {
    init() {
        // Must run before anything else so data from the app's old name is carried over.
        Migration.run()
        _ = AppLanguage.launchedWith   // Remember the language at launch (for the "restart required" hint)
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library()
    @StateObject private var player = WallpaperController()
    @StateObject private var steam = SteamCMD()
    @StateObject private var browser = WorkshopBrowser()
    @StateObject private var sync = SubscriptionSync()
    @StateObject private var importer = ImportManager()

    var body: some Scene {
        Window("LiveBloom", id: "main") {
            ContentView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(steam)
                .environmentObject(browser)
                .environmentObject(sync)
                .environmentObject(importer)
                .onAppear {
                    // While the window is open: regular app with a Dock icon.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
                .onDisappear {
                    // Window closed: menu bar only, no Dock icon.
                    NSApp.setActivationPolicy(.accessory)
                    // Release preview image memory – nothing needs it in the background.
                    PreviewCache.shared.releaseMemory()
                }
        }
        .defaultSize(width: 1100, height: 720)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(player)
        } label: {
            MenuBarLabel()
                .onAppear {
                    // Runs even without an open window (e.g. after launch at login).
                    steam.onDownloaded = { [weak library] url in
                        library?.noteDownloadLocation(url)
                        library?.refresh()
                    }
                    sync.start(browser: browser, steam: steam, library: library)
                }
        }
    }
}

/// The menu bar icon always exists – on a normal launch we open the window from here.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image)
            .onAppear {
                AppDelegate.openMain = {
                    openWindow(id: "main")
                    // If the window was minimized to the Dock, bring it back.
                    for w in NSApp.windows where w.isMiniaturized && w.level == .normal { w.deminiaturize(nil) }
                    NSApp.activate()
                }
                if !AppDelegate.launchedAtLogin && !AppDelegate.didOpenInitialWindow {
                    AppDelegate.didOpenInitialWindow = true
                    DispatchQueue.main.async { AppDelegate.openMain?() }
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var launchedAtLogin = false
    static var didOpenInitialWindow = false
    static var openMain: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Was the app launched at login? Then stay quietly in the menu bar.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            Self.launchedAtLogin = true
        }
        if CommandLine.arguments.contains("--background") { Self.launchedAtLogin = true }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch at login is offered by the welcome screen on first launch (WelcomeView). If it is wanted but
        // not registered (e.g. after renaming/moving the app), it is registered again.
        if UserDefaults.standard.bool(forKey: "launchAtLoginWanted"), !LoginItem.isEnabled {
            try? LoginItem.set(true)
        }
    }

    /// Click in Launchpad/Dock while the app is already running → open the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // `flag` also counts the wallpaper windows at desktop level – so check ourselves
        // whether the main window is open. Otherwise clicking in Launchpad/Finder does nothing.
        let mainWindowVisible = sender.windows.contains { $0.isVisible && $0.level == .normal && $0.canBecomeMain }
        if !mainWindowVisible { Self.openMain?() } else { sender.activate() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarContent: View {
    @EnvironmentObject var player: WallpaperController

    var body: some View {
        if let current = player.current {
            Text(current.title)
            if player.isPaused { Text("Pausiert") }
            Button(player.isPaused ? "Fortsetzen" : "Pausieren") { player.togglePause() }
            Button(player.isMuted ? "Ton an" : "Ton aus") { player.isMuted.toggle() }
            if player.playlist.count > 1 { Button("Nächstes Wallpaper") { player.nextInPlaylist() } }
            Button("Wallpaper entfernen") { player.clear() }
        } else {
            Text("Kein Wallpaper aktiv")
        }
        Divider()
        Button("Bibliothek öffnen …") { AppDelegate.openMain?() }
        Divider()
        Button("LiveBloom beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        UserDefaults.standard.set(on, forKey: "launchAtLoginWanted")
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
