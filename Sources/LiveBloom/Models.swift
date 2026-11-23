import Foundation

/// Steam app ID of Wallpaper Engine – whose Workshop we read.
let wallpaperEngineAppID = "431960"

enum WallpaperKind: String {
    case video, web, scene, application, unknown

    var label: String {
        switch self {
        case .video: return String(localized: "Video")
        case .web: return String(localized: "Web")
        case .scene: return String(localized: "Scene")
        case .application: return String(localized: "App")
        case .unknown: return String(localized: "Unbekannt")
        }
    }

    var isSupported: Bool { self == .video || self == .web }
}

struct WallpaperItem: Identifiable, Hashable {
    /// Path of the folder (Workshop item) or the video file.
    let id: String
    let folder: URL
    let title: String
    let kind: WallpaperKind
    let mainFile: URL?
    let preview: URL?
    let workshopID: String?
    /// Raw properties from project.json (for web wallpapers).
    let propertiesJSON: String?
    /// When the wallpaper arrived on this Mac (for "Recently added").
    var added: Date = .distantPast

    var isPlayable: Bool {
        guard kind.isSupported, let f = mainFile else { return false }
        return FileManager.default.fileExists(atPath: f.path)
    }

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv"]

    /// Loads a wallpaper from a Workshop folder (with project.json) or a video file.
    static func load(path: String) -> WallpaperItem? {
        guard var item = loadRaw(path: path) else { return nil }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        item.added = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
        return item
    }

    private static func loadRaw(path: String) -> WallpaperItem? {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return loadFolder(url) }
        guard videoExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return WallpaperItem(
            id: url.path, folder: url.deletingLastPathComponent(),
            title: url.deletingPathExtension().lastPathComponent,
            kind: .video, mainFile: url, preview: nil, workshopID: nil, propertiesJSON: nil)
    }

    private static func loadFolder(_ folder: URL) -> WallpaperItem? {
        let pj = folder.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: pj),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
        let kind = WallpaperKind(rawValue: ((obj["type"] as? String) ?? "").lowercased()) ?? .unknown
        // Security: file references from the Workshop must not lead outside the item's own folder
        // (e.g. "../../…"); symbolic links are resolved and checked as well.
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        func contained(_ rel: String?) -> URL? {
            guard let rel, !rel.isEmpty, !rel.hasPrefix("/") else { return nil }
            let u = folder.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
            return u.path.hasPrefix(base) ? u : nil
        }
        let file = contained(obj["file"] as? String)
        let preview = contained(obj["preview"] as? String)
        let workshopID = obj["workshopid"].map { "\($0)" } ?? folder.lastPathComponent

        var props: String?
        // isValidJSONObject up front: numbers like -1e400 become -inf when parsed, and
        // writing them back throws an ObjC exception that `try?` doesn't catch (app crash).
        if let general = obj["general"] as? [String: Any],
           let p = general["properties"] as? [String: Any],
           JSONSerialization.isValidJSONObject(p),
           let pd = try? JSONSerialization.data(withJSONObject: p) {
            props = String(data: pd, encoding: .utf8)
        }

        return WallpaperItem(
            id: folder.path, folder: folder, title: title, kind: kind,
            mainFile: file, preview: preview, workshopID: workshopID, propertiesJSON: props)
    }
}

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LiveBloom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }
    static var steamcmdDir: URL { support.appendingPathComponent("steamcmd", isDirectory: true) }
    /// The app's own library folder – steamcmd cleans up its Workshop folder, so
    /// finished downloads are moved here.
    static var libraryDir: URL {
        let d = support.appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Workshop IDs are plain numbers – everything else is rejected (protects folder names,
    /// steamcmd calls and links from manipulated values).
    static func isValidWorkshopID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 20 && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// Moves a downloaded Workshop item into the app's own library.
    @discardableResult
    static func moveIntoLibrary(_ folder: URL, id: String) -> URL {
        guard isValidWorkshopID(id) else { return folder }
        let fm = FileManager.default
        let dest = libraryDir.appendingPathComponent(id, isDirectory: true)
        guard folder.standardizedFileURL.path.lowercased() != dest.standardizedFileURL.path.lowercased() else { return dest }
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: folder, to: dest)
            removeSymlinks(in: dest)
            return dest
        } catch {
            return folder
        }
    }

    /// Removes all symbolic links in a library wallpaper folder. Wallpapers don't need
    /// any; otherwise a link could make files outside the folder reachable for web wallpapers.
    static func removeSymlinks(in dir: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            try? fm.removeItem(at: u)
        }
    }

    /// Separate "home" for steamcmd (sign-in and cache kept apart from the Steam app).
    static var steamHome: URL {
        let d = support.appendingPathComponent("steamhome", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d
    }
    static var steamInstallDir: URL { support.appendingPathComponent("steam", isDirectory: true) }

    /// Possible places where steamcmd stores Workshop items.
    static var workshopRoots: [URL] {
        let rel = "steamapps/workshop/content/\(wallpaperEngineAppID)"
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            libraryDir,
            steamInstallDir.appendingPathComponent(rel),
            steamHome.appendingPathComponent("Library/Application Support/Steam/\(rel)"),
            steamcmdDir.appendingPathComponent(rel),
            home.appendingPathComponent("Library/Application Support/Steam/\(rel)"),
        ]
    }
}
