import Foundation

/// One-time migration from earlier names of the app ("MacScape", before that "Wallscape") to "LiveBloom":
/// data folder, settings and stored paths are carried over.
enum Migration {
    /// Earlier names: defaults domain (bundle ID) and data folder, newest first.
    private static let legacy: [(domain: String, folder: String)] = [
        ("local.macscape.app", "MacScape"),
        ("local.wallscape.app", "Wallscape"),
    ]
    private static let newFolder = "LiveBloom"

    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedToLiveBloom") else { return }
        defer { d.set(true, forKey: "migratedToLiveBloom") }

        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let newDir = base.appendingPathComponent(newFolder, isDirectory: true)
        for old in legacy {
            let oldDir = base.appendingPathComponent(old.folder, isDirectory: true)
            if fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path) {
                try? fm.moveItem(at: oldDir, to: newDir)
            }
        }

        // Carry over settings (old defaults domains) and rewrite paths.
        for old in legacy {
            guard let values = d.persistentDomain(forName: old.domain) else { continue }
            for (key, value) in values where d.object(forKey: key) == nil {
                d.set(rewrite(value), forKey: key)
            }
            // Anyone who had launch at login in an old version keeps it.
            if values["loginItemConfigured"] as? Bool == true, d.object(forKey: "launchAtLoginWanted") == nil {
                d.set(true, forKey: "launchAtLoginWanted")
            }
            d.removePersistentDomain(forName: old.domain)
        }
    }

    /// Replaces "…/Application Support/<old name>" in stored paths (also in keys).
    private static func rewrite(_ value: Any) -> Any {
        switch value {
        case let s as String:
            var out = s
            for old in legacy {
                out = out.replacingOccurrences(of: "/Application Support/\(old.folder)/", with: "/Application Support/\(newFolder)/",
                                               options: .caseInsensitive)
                if out.lowercased().hasSuffix("/application support/\(old.folder.lowercased())") {
                    out = String(out.dropLast(old.folder.count)) + newFolder
                }
            }
            return out
        case let a as [Any]:
            return a.map(rewrite)
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[rewrite(k) as! String] = rewrite(v) }
            return out
        default:
            return value
        }
    }
}
