import Foundation
import AppKit

/// Reads downloaded Workshop wallpapers and custom folders/videos.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var items: [WallpaperItem] = []
    @Published private(set) var extraFolders: [URL] = []

    private let defaults = UserDefaults.standard

    init() {
        extraFolders = (defaults.stringArray(forKey: "extraFolders") ?? []).map { URL(fileURLWithPath: $0) }
        Library.migrateSteamDownloads()
        refresh()
    }

    /// Folders steamcmd reported most recently (if different from the default).
    private var discoveredRoots: [URL] {
        (defaults.stringArray(forKey: "discoveredRoots") ?? []).map { URL(fileURLWithPath: $0) }
    }

    func noteDownloadLocation(_ itemFolder: URL) {
        let root = itemFolder.deletingLastPathComponent().path
        // steamcmd sometimes reports paths in lowercase – don't remember known folders twice.
        let known = (AppPaths.workshopRoots + extraFolders).map { $0.path.lowercased() }
        if known.contains(root.lowercased()) { return }
        var roots = defaults.stringArray(forKey: "discoveredRoots") ?? []
        if !roots.contains(root) { roots.append(root); defaults.set(roots, forKey: "discoveredRoots") }
    }

    func refresh() {
        let roots = AppPaths.workshopRoots + discoveredRoots + extraFolders
        Task.detached(priority: .userInitiated) {
            let found = Library.scan(roots: roots)
            await MainActor.run { self.items = found }
        }
    }

    nonisolated private static func scan(roots: [URL]) -> [WallpaperItem] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [WallpaperItem] = []

        // Avoid duplicates: same path (case-insensitive) or same Workshop ID.
        func add(_ item: WallpaperItem?) {
            guard let item else { return }
            var keys = [item.id.lowercased()]
            if let w = item.workshopID, !w.isEmpty, w.allSatisfy(\.isNumber) { keys.append("ws:" + w) }
            guard keys.allSatisfy({ !seen.contains($0) }) else { return }
            keys.forEach { seen.insert($0) }
            result.append(item)
        }

        for root in roots {
            // The folder itself can be a wallpaper …
            if fm.fileExists(atPath: root.appendingPathComponent("project.json").path) {
                add(WallpaperItem.load(path: root.path))
                continue
            }
            // … or contain wallpaper folders or video files.
            guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                add(WallpaperItem.load(path: child.path))
            }
        }
        return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Moves already downloaded items from the steamcmd folders into the app's own library,
    /// so steamcmd doesn't delete them again.
    static func migrateSteamDownloads() {
        let fm = FileManager.default
        let current = UserDefaults.standard.string(forKey: "currentWallpaper")
        for root in AppPaths.workshopRoots.dropFirst() {   // the first entry is the library itself
            guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            // Only move folders from LiveBloom's own steamcmd paths, not those of the Steam app.
            guard root.path.hasPrefix(AppPaths.support.path) else { continue }
            for child in children where fm.fileExists(atPath: child.appendingPathComponent("project.json").path) {
                let dest = AppPaths.moveIntoLibrary(child, id: child.lastPathComponent)
                if let current, current.lowercased() == child.path.lowercased() {
                    UserDefaults.standard.set(dest.path, forKey: "currentWallpaper")
                }
            }
        }
    }

    func contains(workshopID: String) -> WallpaperItem? {
        items.first { $0.workshopID == workshopID }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Hinzufügen")
        panel.message = String(localized: "Wähle Ordner mit Wallpapern (Workshop-Ordner mit project.json oder Videodateien).")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !extraFolders.contains(url) { extraFolders.append(url) }
        saveFolders()
        refresh()
    }

    func removeFolder(_ url: URL) {
        extraFolders.removeAll { $0 == url }
        saveFolders()
        refresh()
    }

    func moveToTrash(_ item: WallpaperItem) {
        let target = item.mainFile.flatMap { item.id == $0.path ? $0 : nil } ?? item.folder
        try? FileManager.default.trashItem(at: target, resultingItemURL: nil)
        refresh()
    }

    private func saveFolders() {
        defaults.set(extraFolders.map(\.path), forKey: "extraFolders")
    }
}
