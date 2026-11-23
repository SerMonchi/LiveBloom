import Foundation
import AppKit
import Security

// MARK: - API key (in the macOS Keychain, not in plain text in the settings)

enum APIKeyStore {
    private static let key = "steamApiKey"
    private static let service = "local.livebloom.app"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: String?

    static var value: String {
        get {
            lock.lock(); defer { lock.unlock() }
            if let cache { return cache }
            // One-time migration from older versions (plain text in UserDefaults).
            if let old = UserDefaults.standard.string(forKey: key) {
                let v = old.trimmingCharacters(in: .whitespacesAndNewlines)
                if v.isEmpty || writeKeychain(v) { UserDefaults.standard.removeObject(forKey: key) }
                cache = v
                return v
            }
            if let v = readKeychain() { cache = v; return v }
            // One-time migration from "MacScape" (the app's earlier name, different Keychain entry).
            if let v = readKeychain(service: legacyService), !v.isEmpty, writeKeychain(v) {
                deleteKeychain(service: legacyService)
                cache = v
                return v
            }
            cache = ""
            return ""
        }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            lock.lock(); defer { lock.unlock() }
            if v.isEmpty { deleteKeychain() } else { _ = writeKeychain(v) }
            UserDefaults.standard.removeObject(forKey: key)
            cache = v
        }
    }

    private static let legacyService = "local.macscape.app"

    private static var baseQuery: [String: Any] { query(service: service) }

    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    private static func readKeychain(service: String = service) -> String? {
        var q = query(service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    private static func writeKeychain(_ v: String) -> Bool {
        let data = Data(v.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            NSLog("LiveBloom: could not save the API key in the Keychain (\(status))")
            return false
        }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "LiveBloom – Steam Web API key"
        let s = SecItemAdd(add as CFDictionary, nil)
        if s != errSecSuccess { NSLog("LiveBloom: could not save the API key in the Keychain (\(s))") }
        return s == errSecSuccess
    }

    private static func deleteKeychain(service: String = service) { SecItemDelete(query(service: service) as CFDictionary) }
    static func looksValid(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "^[0-9A-Fa-f]{32}$", options: .regularExpression) != nil
    }
}

// MARK: - Workshop search via the Steam Web API

struct WorkshopResult: Identifiable, Hashable {
    let id: String
    let title: String
    let previewURL: URL?
    let tags: [String]
    let subscriptions: Int
    let fileSize: Int64
    let timeUpdated: Int
    let timeCreated: Int
    let shortDescription: String
    let creator: String
    /// Rating 0…1 and votes (like the stars in the Workshop).
    let score: Double?
    let votesUp: Int
    let votesDown: Int

    /// 0–5 stars, derived from the rating the same way Steam does.
    var stars: Int? {
        guard let score, votesUp + votesDown >= 10 else { return nil }
        return max(1, min(5, Int((score * 5).rounded())))
    }

    var kind: WallpaperKind {
        let lower = Set(tags.map { $0.lowercased() })
        for k in [WallpaperKind.video, .web, .scene, .application] where lower.contains(k.rawValue) { return k }
        return .unknown
    }

    var pageURL: URL { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")! }

    init?(json d: [String: Any]) {
        // Only purely numeric IDs (otherwise crashes when building links, or manipulated links/paths).
        guard let id = d["publishedfileid"].map({ "\($0)" }), AppPaths.isValidWorkshopID(id) else { return nil }
        if let r = d["result"] as? Int, r != 1 { return nil }
        self.id = id
        title = d["title"] as? String ?? id
        // Load preview images over encrypted connections only.
        previewURL = (d["preview_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        tags = (d["tags"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String }
        subscriptions = (d["subscriptions"] as? Int) ?? Int("\(d["subscriptions"] ?? "0")") ?? 0
        fileSize = Int64("\(d["file_size"] ?? "0")") ?? 0
        timeUpdated = (d["time_updated"] as? Int) ?? 0
        timeCreated = (d["time_created"] as? Int) ?? 0
        shortDescription = (d["short_description"] as? String) ?? (d["file_description"] as? String) ?? (d["description"] as? String) ?? ""
        creator = d["creator"].map { "\($0)" } ?? ""
        let votes = d["vote_data"] as? [String: Any]
        score = votes?["score"] as? Double
        votesUp = votes?["votes_up"] as? Int ?? 0
        votesDown = votes?["votes_down"] as? Int ?? 0
    }
}

@MainActor
final class WorkshopBrowser: ObservableObject {
    // Sort orders like in the Wallpaper Engine Workshop.
    enum Sort: String, CaseIterable, Identifiable, LocalizedLabel {
        case popular = "Beliebteste", topRated = "Bestbewertet", newest = "Neueste", subscribers = "Meiste Abonnenten"
        var id: String { rawValue }
        var queryType: Int {
            switch self { case .topRated: 0; case .newest: 1; case .popular: 3; case .subscribers: 9 }
        }
    }

    enum Period: Int, CaseIterable, Identifiable {
        case day = 1, week = 7, month = 30, quarter = 90, halfYear = 180, year = 365, allTime = -1
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .day: String(localized: "Heute"); case .week: String(localized: "Diese Woche"); case .month: String(localized: "Dieser Monat"); case .quarter: String(localized: "Letzte 3 Monate")
            case .halfYear: String(localized: "Letzte 6 Monate"); case .year: String(localized: "Letztes Jahr"); case .allTime: String(localized: "Gesamte Zeit")
            }
        }
    }

    enum TypeFilter: String, CaseIterable, Identifiable, LocalizedLabel {
        case supported = "Video & Web", video = "Video", web = "Web"
        var id: String { rawValue }
    }

    enum AgeFilter: String, CaseIterable, Identifiable, LocalizedLabel {
        case everyone = "Jugendfrei", questionable = "Bis „Fragwürdig“", all = "Alle"
        var id: String { rawValue }
    }

    /// Genre and resolution tags as they are named in the Workshop (checked against Steam).
    static let genres: [(tag: String, label: String)] = [
        ("Abstract", String(localized: "Abstrakt")), ("Animal", String(localized: "Tiere")), ("Anime", String(localized: "Anime")), ("Cartoon", String(localized: "Cartoon")), ("CGI", String(localized: "CGI")),
        ("Cyberpunk", String(localized: "Cyberpunk")), ("Fantasy", String(localized: "Fantasy")), ("Game", String(localized: "Spiele")), ("Girls", String(localized: "Girls")), ("Guys", String(localized: "Guys")),
        ("Landscape", String(localized: "Landschaft")), ("Medieval", String(localized: "Mittelalter")), ("Memes", String(localized: "Memes")), ("MMD", String(localized: "MMD")), ("Music", String(localized: "Musik")),
        ("Nature", String(localized: "Natur")), ("Pixel art", String(localized: "Pixel-Art")), ("Relaxing", String(localized: "Entspannend")), ("Retro", String(localized: "Retro")), ("Sci-Fi", String(localized: "Sci-Fi")),
        ("Sports", String(localized: "Sport")), ("Technology", String(localized: "Technik")), ("Television", String(localized: "Film & TV")), ("Vehicle", String(localized: "Fahrzeuge")),
    ]
    static let resolutions: [String] = [
        "1920 x 1080", "2560 x 1440", "3840 x 2160", "1366 x 768", "1280 x 720",
        "Ultrawide 2560 x 1080", "Ultrawide 3440 x 1440", "Portrait 1080 x 1920", "Dual 3840 x 1080", "Other resolution",
    ]

    // Filters
    @Published var searchText = ""
    @Published var sort: Sort = .popular
    @Published var period: Period = .week
    @Published var typeFilter: TypeFilter = .supported
    @Published var ageFilter: AgeFilter = .everyone
    @Published var genre: String? = nil
    @Published var resolution: String? = nil

    // Results
    @Published var results: [WorkshopResult] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var canLoadMore = false
    @Published private(set) var totalCount: Int?

    // The user's own lists (subscriptions / favorites – what you have in Wallpaper Engine on your PC)
    enum UserList: String, CaseIterable, Identifiable {
        case subscriptions = "mysubscriptions", favorites = "myfavorites"
        var id: String { rawValue }
        var label: String { self == .subscriptions ? String(localized: "Meine Abos") : String(localized: "Favoriten") }
    }
    @Published private(set) var userLists: [UserList: [WorkshopResult]] = [:]
    @Published private(set) var userListLoading: Set<UserList> = []
    @Published var userListError: String?

    private var cursor = "*"
    private var requestID = 0

    var apiKey: String { APIKeyStore.value }
    var hasAPIKey: Bool { !apiKey.isEmpty }

    /// Separate session for all requests with the API key in the URL – without a URL cache,
    /// so the key doesn't end up in plain text in the on-disk cache (Cache.db).
    private static let apiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    /// Steam ID from the steamcmd sign-in (remembered when signing in).
    var steamID64: String? {
        guard let s = UserDefaults.standard.string(forKey: "steamAccountID"), let a = UInt64(s), a > 0 else { return nil }
        return String(76561197960265728 + a)
    }

    /// Changes whenever a filter changes – triggers a reload.
    var filterKey: String {
        [searchText.trimmingCharacters(in: .whitespaces), sort.rawValue, String(period.rawValue), typeFilter.rawValue,
         ageFilter.rawValue, genre ?? "", resolution ?? ""].joined(separator: "|")
    }

    var hasActiveFilters: Bool {
        sort != .popular || period != .week || typeFilter != .supported || ageFilter != .everyone || genre != nil || resolution != nil
    }

    func resetFilters() {
        sort = .popular; period = .week; typeFilter = .supported; ageFilter = .everyone; genre = nil; resolution = nil
    }

    func reload() async {
        cursor = "*"
        results = []
        totalCount = nil
        canLoadMore = false
        await loadPage()
    }

    func loadMore() async {
        guard canLoadMore, !isLoading else { return }
        await loadPage()
    }

    private func tagParams() -> [URLQueryItem] {
        var required: [String] = []
        var excluded: [String] = []
        switch typeFilter {
        case .supported: excluded += ["Scene", "Application", "Preset"]
        case .video: required.append("Video")
        case .web: required.append("Web")
        }
        switch ageFilter {
        case .everyone: required.append("Everyone")
        case .questionable: excluded.append("Mature")
        case .all: break
        }
        if let genre { required.append(genre) }
        if let resolution { required.append(resolution) }
        return required.enumerated().map { URLQueryItem(name: "requiredtags[\($0)]", value: $1) }
            + excluded.enumerated().map { URLQueryItem(name: "excludedtags[\($0)]", value: $1) }
    }

    private func loadPage() async {
        guard hasAPIKey else {
            errorMessage = String(localized: "Für die Workshop-Suche brauchst du einen Steam-Web-API-Schlüssel (siehe Einstellungen). Alternativ kannst du oben einen Workshop-Link einfügen.")
            return
        }
        requestID += 1
        let myRequest = requestID
        isLoading = true
        errorMessage = nil
        defer { if myRequest == requestID { isLoading = false } }

        let search = searchText.trimmingCharacters(in: .whitespaces)
        var c = URLComponents(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!
        var q: [URLQueryItem] = [
            .init(name: "key", value: apiKey),
            .init(name: "appid", value: wallpaperEngineAppID),
            .init(name: "query_type", value: String(search.isEmpty ? sort.queryType : 12)),
            .init(name: "cursor", value: cursor),
            .init(name: "numperpage", value: "40"),
            .init(name: "return_previews", value: "true"),
            .init(name: "return_tags", value: "true"),
            .init(name: "return_vote_data", value: "true"),
            .init(name: "return_short_description", value: "true"),
            .init(name: "match_all_tags", value: "true"),
        ]
        if sort == .popular && search.isEmpty { q.append(.init(name: "days", value: String(period.rawValue))) }
        if !search.isEmpty { q.append(.init(name: "search_text", value: search)) }
        q += tagParams()
        c.queryItems = q

        do {
            let (data, resp) = try await Self.apiSession.data(from: c.url!)
            guard myRequest == requestID else { return }   // the filter has changed in the meantime
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                errorMessage = http.statusCode == 403
                    ? String(localized: "Steam hat den API-Schlüssel abgelehnt. Prüfe ihn in den Einstellungen.")
                    : String(localized: "Steam antwortet mit Fehler \(http.statusCode).")
                return
            }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let response = obj?["response"] as? [String: Any] ?? [:]
            let list = (response["publishedfiledetails"] as? [[String: Any]] ?? []).compactMap(WorkshopResult.init(json:))
            let next = response["next_cursor"] as? String
            if let t = response["total"] as? Int { totalCount = t }
            let existing = Set(results.map(\.id))
            results += list.filter { !existing.contains($0.id) }
            canLoadMore = !(next ?? "").isEmpty && next != cursor && !list.isEmpty
            cursor = next ?? cursor
            if results.isEmpty { errorMessage = String(localized: "Keine Treffer für diese Filter.") }
        } catch {
            guard myRequest == requestID else { return }
            errorMessage = String(localized: "Workshop konnte nicht geladen werden: \(error.localizedDescription)")
        }
    }

    /// Loads your subscriptions or favorites from Steam (needs an API key + a one-time sign-in).
    func loadUserList(_ list: UserList) async {
        guard hasAPIKey else { userListError = String(localized: "Trag zuerst deinen API-Schlüssel in den Einstellungen ein."); return }
        guard let steamID = steamID64 else { userListError = String(localized: "Melde dich zuerst in den Einstellungen bei Steam an."); return }
        userListLoading.insert(list)
        userListError = nil
        defer { userListLoading.remove(list) }

        var all: [WorkshopResult] = []
        var page = 1
        do {
            while page <= 20 {
                var c = URLComponents(string: "https://api.steampowered.com/IPublishedFileService/GetUserFiles/v1/")!
                c.queryItems = [
                    .init(name: "key", value: apiKey), .init(name: "steamid", value: steamID),
                    .init(name: "appid", value: wallpaperEngineAppID), .init(name: "type", value: list.rawValue),
                    .init(name: "numperpage", value: "100"), .init(name: "page", value: String(page)),
                    .init(name: "return_tags", value: "true"), .init(name: "return_previews", value: "true"),
                    .init(name: "return_vote_data", value: "true"), .init(name: "return_short_description", value: "true"),
                ]
                let (data, resp) = try await Self.apiSession.data(from: c.url!)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    userListError = String(localized: "Steam antwortet mit Fehler \(http.statusCode).")
                    return
                }
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let response = obj?["response"] as? [String: Any] ?? [:]
                let items = (response["publishedfiledetails"] as? [[String: Any]] ?? []).compactMap(WorkshopResult.init(json:))
                all += items
                let total = response["total"] as? Int ?? all.count
                if items.isEmpty || all.count >= total { break }
                page += 1
            }
            userLists[list] = all
        } catch {
            userListError = String(localized: "Liste konnte nicht geladen werden: \(error.localizedDescription)")
        }
    }

    struct Details {
        var description: String
        var author: String?
        var views: Int
        var favorited: Int
        var created: Date?
        var updated: Date?
    }

    /// Detailed info for the detail view (description, author, views …).
    func details(for id: String) async -> Details? {
        guard hasAPIKey else { return nil }
        var c = URLComponents(string: "https://api.steampowered.com/IPublishedFileService/GetDetails/v1/")!
        c.queryItems = [.init(name: "key", value: apiKey), .init(name: "publishedfileids[0]", value: id),
                        .init(name: "strip_description_bbcode", value: "true"), .init(name: "includevotes", value: "true")]
        guard let (data, _) = try? await Self.apiSession.data(from: c.url!),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = ((obj["response"] as? [String: Any])?["publishedfiledetails"] as? [[String: Any]])?.first else { return nil }
        var out = Details(description: d["file_description"] as? String ?? "",
                          author: nil,
                          views: d["views"] as? Int ?? 0,
                          favorited: d["favorited"] as? Int ?? 0,
                          created: (d["time_created"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                          updated: (d["time_updated"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) })
        if let creator = d["creator"].map({ "\($0)" }), !creator.isEmpty {
            var u = URLComponents(string: "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/")!
            u.queryItems = [.init(name: "key", value: apiKey), .init(name: "steamids", value: creator)]
            if let (ud, _) = try? await Self.apiSession.data(from: u.url!),
               let uo = try? JSONSerialization.jsonObject(with: ud) as? [String: Any],
               let p = ((uo["response"] as? [String: Any])?["players"] as? [[String: Any]])?.first {
                out.author = p["personaname"] as? String
            }
        }
        return out
    }

    /// Look up single items by link or ID – works without an API key.
    func lookup(_ input: String) async {
        let ids = Self.extractIDs(from: input)
        guard !ids.isEmpty else { errorMessage = String(localized: "Kein Workshop-Link oder keine ID erkannt."); return }
        requestID += 1
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var req = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = "itemcount=\(ids.count)"
        for (i, id) in ids.enumerated() { body += "&publishedfileids[\(i)]=\(id)" }
        req.httpBody = Data(body.utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let raw = (obj?["response"] as? [String: Any])?["publishedfiledetails"] as? [[String: Any]] ?? []
            let wrongApp = raw.filter { "\($0["consumer_app_id"] ?? "")" != wallpaperEngineAppID && $0["result"] as? Int == 1 }
            let list = raw.filter { "\($0["consumer_app_id"] ?? "")" == wallpaperEngineAppID }.compactMap(WorkshopResult.init(json:))
            results = list
            totalCount = list.count
            canLoadMore = false
            if list.isEmpty {
                errorMessage = wrongApp.isEmpty ? String(localized: "Item nicht gefunden oder nicht öffentlich.") : String(localized: "Das ist kein Wallpaper-Engine-Item.")
            }
        } catch {
            errorMessage = String(localized: "Nachschlagen fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    static func extractIDs(from input: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "(?:id=)?(\\d{6,})")
        let ns = input as NSString
        return pattern.matches(in: input, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }
}

// MARK: - steamcmd (downloads Workshop items with your own Steam account)

@MainActor
final class SteamCMD: ObservableObject {
    enum LoginState: Equatable {
        case idle, running, waitingForPhone, needsCode, success
        case failed(String)
    }

    enum DownloadState: Equatable {
        case queued, downloading, done(URL), failed(String)
    }

    @Published private(set) var isInstalled = false
    /// steamcmd has stored a sign-in session (no need to sign in again).
    @Published private(set) var hasSavedLogin = false
    @Published private(set) var isInstalling = false
    @Published private(set) var rosettaAvailable = true
    @Published private(set) var log: [String] = []
    @Published private(set) var states: [String: DownloadState] = [:]
    @Published var needsLogin = false
    @Published private(set) var loginState: LoginState = .idle
    @Published var username: String { didSet { UserDefaults.standard.set(username, forKey: "steamUser") } }

    /// Called after every successful download.
    var onDownloaded: ((URL) -> Void)?

    private var queue: [String] = []
    private var isRunningQueue = false
    private var current: Process?

    private var dir: URL { AppPaths.steamcmdDir }
    private var script: URL { dir.appendingPathComponent("steamcmd.sh") }

    /// Only checks whether steamcmd has stored a session – the content is never read or shown.
    func refreshSavedLogin() {
        let cfg = AppPaths.steamHome.appendingPathComponent("Library/Application Support/Steam/config/config.vdf")
        let text = (try? String(contentsOf: cfg, encoding: .utf8)) ?? ""
        hasSavedLogin = text.contains("\"ConnectCache\"")
    }

    var validUsername: String? {
        let u = username.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty, u.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { return nil }
        return u
    }

    init() {
        username = UserDefaults.standard.string(forKey: "steamUser") ?? ""
        isInstalled = FileManager.default.fileExists(atPath: script.path)
        refreshSavedLogin()
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
            p.arguments = ["-x86_64", "/usr/bin/true"]
            let ok: Bool
            if (try? p.run()) != nil { p.waitUntilExit(); ok = p.terminationStatus == 0 } else { ok = false }
            await MainActor.run { self.rosettaAvailable = ok }
        }
    }

    // Installation from Valve's official CDN.
    func install() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        append(String(localized: "steamcmd wird von Valve heruntergeladen …"))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let src = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!
            let (tmp, resp) = try await URLSession.shared.download(from: src)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { append(String(localized: "Download fehlgeschlagen.")); return }
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", tmp.path, "-C", dir.path]
            try tar.run()
            tar.waitUntilExit()
            guard FileManager.default.fileExists(atPath: script.path) else { append(String(localized: "Entpacken fehlgeschlagen.")); return }
            guard Self.verifyValveSignature(at: dir.appendingPathComponent("steamcmd")) else {
                append(String(localized: "Sicherheitsprüfung fehlgeschlagen: steamcmd ist nicht von Valve signiert – wird nicht verwendet."))
                try? FileManager.default.removeItem(at: dir)
                return
            }
            append(String(localized: "Erster Start – steamcmd aktualisiert sich (kann ein paar Minuten dauern) …"))
            _ = await run(["+quit"])
            isInstalled = true
            append(String(localized: "steamcmd ist bereit. Melde dich jetzt in den Einstellungen an."))
        } catch {
            append(String(localized: "Fehler: \(error.localizedDescription)"))
        }
    }

    func download(_ id: String) {
        guard AppPaths.isValidWorkshopID(id) else { return }
        if case .downloading = states[id] { return }
        if case .queued = states[id] { return }
        states[id] = .queued
        queue.append(id)
        if !isRunningQueue { Task { await processQueue() } }
    }

    func retry(_ id: String) {
        states[id] = nil
        download(id)
    }

    func cancelAll() {
        for id in queue { states[id] = nil }
        queue.removeAll()
        current?.terminate()
    }

    private func processQueue() async {
        isRunningQueue = true
        while !queue.isEmpty {
            let id = queue.removeFirst()
            states[id] = .downloading
            let state = await downloadOne(id)
            states[id] = state
            if case .done(let url) = state { onDownloaded?(url) }
        }
        isRunningQueue = false
    }

    private func downloadOne(_ id: String) async -> DownloadState {
        guard isInstalled else { return .failed(String(localized: "steamcmd ist nicht installiert.")) }
        guard let user = validUsername else { return .failed(String(localized: "Steam-Benutzername fehlt.")) }
        append(String(localized: "Lade \(id) …"))

        var downloaded: URL?
        var errorText: String?
        let status = await run([
            "+force_install_dir", AppPaths.steamInstallDir.path,
            "+login", user,
            "+workshop_download_item", wallpaperEngineAppID, id,
            "+quit",
        ], onLine: { line, proc in
            let lower = line.lowercased()
            if lower.contains("cached credentials not found") || lower.contains("password:") || lower.contains("steam guard")
                || lower.contains("two-factor") || lower.contains("login failure") {
                errorText = String(localized: "Nicht angemeldet – bitte in den Einstellungen bei „Steam-Anmeldung“ anmelden.")
                Task { @MainActor in self.needsLogin = true }
                proc.terminate()
            } else if line.hasPrefix("Success. Downloaded item"), let r = line.range(of: "to \"") {
                let rest = line[r.upperBound...]
                if let end = rest.lastIndex(of: "\"") { downloaded = URL(fileURLWithPath: String(rest[..<end])) }
            } else if line.hasPrefix("ERROR!") {
                errorText = line.contains("Access Denied") || line.contains("No subscription")
                    ? String(localized: "Kein Zugriff – dein Steam-Konto muss Wallpaper Engine besitzen.")
                    : line
            }
        })

        // Only accept the reported path if it is exactly the expected Workshop item in one of the
        // known Workshop folders – otherwise unexpected output could move an arbitrary
        // folder into the library.
        if let d = downloaded {
            let real = d.standardizedFileURL.resolvingSymlinksInPath()
            let inRoot = AppPaths.workshopRoots.contains { root in
                real.deletingLastPathComponent().path == root.standardizedFileURL.resolvingSymlinksInPath().path
            }
            if !(inRoot && real.lastPathComponent == id) {
                append(String(localized: "Unerwarteter Download-Pfad wird ignoriert: \(d.path)"))
                downloaded = nil
            }
        }
        if let downloaded {
            let safe = AppPaths.moveIntoLibrary(downloaded, id: id)
            append("Fertig: \(safe.lastPathComponent)")
            return .done(safe)
        }
        // Fallback: look for the folder in the known places.
        if status == 0, errorText == nil,
           let found = AppPaths.workshopRoots.map({ $0.appendingPathComponent(id) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return .done(AppPaths.moveIntoLibrary(found, id: id))
        }
        return .failed(errorText ?? String(localized: "Download fehlgeschlagen (Code \(status))."))
    }

    // MARK: Sign-in directly in the app

    private var loginInput: FileHandle?
    private var loginProcess: Process?

    /// Signs in to steamcmd with username + password.
    /// Password and Steam Guard code are passed through a private pipe (stdin) –
    /// they appear neither in the process list nor in the log and are not stored.
    func login(password: String) async {
        guard isInstalled else { loginState = .failed(String(localized: "steamcmd ist noch nicht installiert.")); return }
        guard let user = validUsername else { loginState = .failed(String(localized: "Bitte gib deinen Steam-Login-Namen ein.")); return }
        guard !password.isEmpty else { loginState = .failed(String(localized: "Bitte gib dein Passwort ein.")); return }
        loginState = .running
        append(String(localized: "Anmeldung als \(user) …"))

        let input = Pipe()
        loginInput = input.fileHandleForWriting
        let secret = SecretBox(password)
        var result: LoginState?

        // Answer prompts (without a line ending).
        let prompt: (String, Process) -> Void = { tail, proc in
            let t = tail.lowercased()
            if t.hasSuffix("password:") {
                if let pw = secret.take() {
                    input.fileHandleForWriting.write(Data((pw + "\n").utf8))
                } else {
                    result = .failed(String(localized: "Benutzername oder Passwort ist falsch."))
                    proc.terminate()
                }
            } else if t.hasSuffix("code:") {
                Task { @MainActor in self.loginState = .needsCode }
            }
        }
        // Evaluate complete lines.
        let line: (String, Process) -> Void = { text, proc in
            let l = text.lowercased()
            if l.contains("waiting for user info...ok") || l.contains("logged in ok") {
                result = .success
            } else if l.contains("confirm") && (l.contains("mobile") || l.contains("steam app")) {
                Task { @MainActor in if self.loginState == .running { self.loginState = .waitingForPhone } }
            } else if l.contains("invalid password") {
                result = .failed(String(localized: "Benutzername oder Passwort ist falsch."))
                proc.terminate()
            } else if l.contains("rate limit") {
                result = .failed(String(localized: "Zu viele Versuche – bitte warte ein paar Minuten."))
                proc.terminate()
            } else if l.contains("invalid login auth code") || l.contains("code mismatch") {
                result = .failed(String(localized: "Der Steam-Guard-Code war falsch. Bitte erneut anmelden."))
                proc.terminate()
            } else if l.contains("failed") && l.contains("login") {
                result = .failed(text)
                proc.terminate()
            }
        }
        _ = await run(["+force_install_dir", AppPaths.steamInstallDir.path, "+login", user, "+quit"],
                      stdin: input, onPartial: prompt) { text, proc in
            line(text, proc)
            Task { @MainActor in self.append(text) }
        }
        secret.clear()
        loginInput = nil
        loginProcess = nil
        let final = result ?? .failed(String(localized: "Anmeldung nicht bestätigt. Details stehen im Protokoll unten."))
        loginState = final
        if final == .success { needsLogin = false; append(String(localized: "Angemeldet ✔")) }
        refreshSavedLogin()
    }

    /// Pass a Steam Guard code to the running sign-in.
    func submitCode(_ code: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, let input = loginInput else { return }
        input.write(Data((c + "\n").utf8))
        loginState = .running
    }

    func cancelLogin() {
        current?.terminate()
        loginState = .idle
    }

    /// Checks that steamcmd is signed by Valve (team ID MXGJJ98X76) and unmodified.
    nonisolated static func verifyValveSignature(at url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--verify", "--strict", "-R=anchor apple generic and certificate leaf[subject.OU] = \"MXGJJ98X76\"", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func resetLoginState() { loginState = .idle }

    /// Remembers the Steam account ID from lines like "Logging in user 'x' [U:1:12345] …".
    nonisolated static func rememberAccountID(from line: String) {
        guard let r = line.range(of: #"\[U:1:(\d+)\]"#, options: .regularExpression) else { return }
        let digits = line[r].filter(\.isNumber).dropFirst()  // remove the "1" from "U:1:"
        if let id = UInt64(String(digits)), id > 0 { UserDefaults.standard.set(String(id), forKey: "steamAccountID") }
    }

    // MARK: Process

    private func run(_ args: [String], log shouldLog: Bool = true, stdin: Pipe? = nil,
                     onPartial: ((String, Process) -> Void)? = nil,
                     onLine: ((String, Process) -> Void)? = nil) async -> Int32 {
        // Before every start, check that steamcmd is still Valve's original (it updates itself).
        let binary = dir.appendingPathComponent("steamcmd")
        let signed = await Task.detached { SteamCMD.verifyValveSignature(at: binary) }.value
        guard signed else {
            append(String(localized: "Sicherheitsprüfung fehlgeschlagen: steamcmd ist nicht (mehr) von Valve signiert. Bitte in den Einstellungen neu installieren."))
            isInstalled = false
            return -2
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + args
        p.currentDirectoryURL = dir
        // Separate data folder for steamcmd so it doesn't overwrite the sign-in session
        // of the Steam app (which would otherwise use the same folder).
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = AppPaths.steamHome.path
        p.environment = env
        // An open pipe instead of /dev/null: steamcmd then waits at a password prompt
        // instead of sending an empty password to Steam (= a failed sign-in attempt).
        let input = stdin ?? Pipe()
        p.standardInput = input
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        current = p

        let lineBuffer = LineBuffer()
        let lastTail = SecretBox("")
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            for line in lineBuffer.feed(data) {
                SteamCMD.rememberAccountID(from: line)
                onLine?(line, p)
                if shouldLog { Task { @MainActor in self?.append(line) } }
            }
            // Prompts ("password:") end without a line break.
            if let tail = lineBuffer.peek(), !tail.isEmpty, lastTail.swap(tail) != tail {
                onPartial?(tail, p)
                let t = tail.lowercased()
                if onPartial == nil, t.contains("password:") || t.contains("code:") {
                    onLine?(tail, p)   // Downloads: this is how the prompt is detected and aborted
                }
            }
        }

        let status: Int32 = await withCheckedContinuation { cont in
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd() {
                    for line in lineBuffer.feed(rest) + lineBuffer.flush() { onLine?(line, proc) }
                }
                cont.resume(returning: proc.terminationStatus)
            }
            do { try p.run() } catch {
                p.terminationHandler = nil
                cont.resume(returning: -1)
            }
        }
        try? input.fileHandleForWriting.close()
        current = nil
        return status
    }

    private func append(_ line: String) {
        guard !line.isEmpty else { return }
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}

/// Splits process output into lines (thread-safe).
final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: buffer[buffer.startIndex..<idx], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...idx)
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { lines.append(t) }
        }
        return lines
    }

    /// Last line that isn't finished yet (e.g. a prompt).
    func peek() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        return String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let t = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll()
        return t.isEmpty ? [] : [t]
    }
}

/// Holds the password only until steamcmd asks for it; after that it is gone.
final class SecretBox: @unchecked Sendable {
    private var value: String?
    private let lock = NSLock()
    init(_ v: String) { value = v }
    func take() -> String? { lock.lock(); defer { lock.unlock() }; let v = value; value = nil; return v }
    func clear() { lock.lock(); value = nil; lock.unlock() }
    /// Sets a new value and returns the old one.
    func swap(_ v: String) -> String? { lock.lock(); defer { lock.unlock() }; let old = value; value = v; return old }
}
