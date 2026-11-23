import SwiftUI
import AppKit

// MARK: - Properties of web wallpapers (from project.json)

struct WallpaperProperty: Identifiable {
    enum Kind { case slider, bool, color, combo, text, label, unsupported }

    let id: String          // Name in project.json
    let label: String
    let kind: Kind
    let defaultJSON: String // Default value as JSON
    let min: Double
    let max: Double
    let step: Double
    let options: [(label: String, json: String)]
    let order: Int

    static func parse(_ item: WallpaperItem) -> [WallpaperProperty] {
        guard let json = item.propertiesJSON, let data = json.data(using: .utf8),
              let props = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], item.kind == .web else { return [] }
        return props.compactMap { name, raw -> WallpaperProperty? in
            guard let p = raw as? [String: Any] else { return nil }
            let type = (p["type"] as? String ?? "").lowercased()
            let kind: Kind = switch type {
                case "slider": .slider
                case "bool": .bool
                case "color": .color
                case "combo": .combo
                case "textinput": .text
                case "text": .label
                default: .unsupported
            }
            // Wallpaper Engine only uses "schemecolor" internally for the accent color.
            guard kind != .unsupported, name.lowercased() != "schemecolor" else { return nil }
            let value = p["value"] ?? ""
            // isValidJSONObject([…]) also checks single values (inf/NaN would crash when serialized).
            let valueJSON = JSONSerialization.isValidJSONObject([value])
                ? (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                : "null"
            let opts: [(String, String)] = (p["options"] as? [[String: Any]] ?? []).compactMap { o in
                guard let v = o["value"], JSONSerialization.isValidJSONObject([v]),
                      let vj = (try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed)).flatMap({ String(data: $0, encoding: .utf8) })
                else { return nil }
                return (cleanLabel(o["label"] as? String ?? "\(v)"), vj)
            }
            return WallpaperProperty(
                id: name, label: cleanLabel(p["text"] as? String ?? name), kind: kind, defaultJSON: valueJSON,
                min: num(p["min"]) ?? 0, max: num(p["max"]) ?? 100, step: num(p["step"]) ?? 0,
                options: opts, order: (p["order"] as? Int) ?? 0)
        }
        .sorted { $0.order < $1.order }
    }

    /// Finite numbers only: "nan"/"inf" from project.json become nil so the defaults apply.
    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d.isFinite ? d : nil }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s).flatMap { $0.isFinite ? $0 : nil } }
        return nil
    }

    /// Workshop labels often contain HTML or translation keys ("ui_…").
    static func cleanLabel(_ s: String) -> String {
        var t = stripTags(s)
        if t.hasPrefix("ui_") {
            t = t.replacingOccurrences(of: "ui_browse_properties_", with: "").replacingOccurrences(of: "ui_", with: "")
                .replacingOccurrences(of: "_", with: " ").capitalized
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes tags exactly like the regex `<[^>]+>`, but in linear time: the regex scans from
    /// every "<" to the end, so many "<" without ">" cost quadratic time on the main thread.
    /// Works on the NSString's UTF-16 units like ICU so the result stays exactly the same.
    private static func stripTags(_ s: String) -> String {
        let ns = s as NSString
        var u = [unichar](repeating: 0, count: ns.length)
        ns.getCharacters(&u, range: NSRange(location: 0, length: ns.length))
        var out: [unichar] = []
        out.reserveCapacity(u.count)
        var i = 0
        while i < u.count {
            if u[i] == 0x3C { // "<"
                // Without a later ">" no further "<" can start a tag either: the rest stays as is.
                guard let j = u[(i + 1)...].firstIndex(of: 0x3E) else { out += u[i...]; break }
                // "<…>" is dropped and the search continues after the ">"; "<>" stays, just like with the regex.
                if j > i + 1 { i = j + 1; continue }
            }
            out.append(u[i])
            i += 1
        }
        return NSString(characters: out, length: out.count) as String
    }
}

// MARK: - Library sidebar (settings of the selected wallpaper)

struct ItemInspector: View {
    let item: WallpaperItem
    @EnvironmentObject var player: WallpaperController
    @State private var settings = ItemSettings()
    @State private var properties: [WallpaperProperty] = []
    @AppStorage("applyTarget") private var applyTarget = "all"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Color.secondary.opacity(0.12)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { LocalThumbnail(url: item.preview, video: item.kind == .video ? item.mainFile : nil, animate: true).environment(\.tileHovering, true) }
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.headline)
                    HStack {
                        KindBadge(kind: item.kind)
                        if let id = item.workshopID, id.allSatisfy(\.isNumber) {
                            Link("Workshop-Seite", destination: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!)
                                .font(.caption)
                        }
                    }
                }

                if item.isPlayable {
                    applyButtons
                    Divider()
                    playbackSettings
                    if !properties.isEmpty {
                        Divider()
                        propertiesSection
                    }
                    Divider()
                    Toggle("In Wiedergabeliste", isOn: Binding(
                        get: { player.isInPlaylist(item) }, set: { _ in player.togglePlaylist(item) }))
                } else {
                    Text("\(item.kind.label)-Wallpaper laufen nur in Wallpaper Engine unter Windows.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: item.id) {
            settings = ItemSettings.load(item.id)
            properties = WallpaperProperty.parse(item)
        }
    }

    @ViewBuilder private var applyButtons: some View {
        let shown = player.screensShowing(item)
        if player.screens.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Button("Auf allen Bildschirmen") { player.set(item, on: .all) }
                    .buttonStyle(.borderedProminent)
                ForEach(player.screens) { s in
                    Button {
                        player.set(item, on: .screen(s.id))
                    } label: {
                        Label(s.name, systemImage: shown.contains(s.id) ? "checkmark.circle.fill" : "display")
                    }
                }
            }
        } else {
            Button(shown.isEmpty ? "Als Wallpaper setzen" : "Aktiv") { player.set(item, on: .all) }
                .buttonStyle(.borderedProminent)
                .disabled(!shown.isEmpty)
        }
    }

    @ViewBuilder private var playbackSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Darstellung").font(.subheadline.weight(.semibold))
            if item.kind == .video {
                Text("Skalierung")
                Picker("Skalierung", selection: $settings.scaling) {
                    ForEach(Scaling.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    Text("Geschwindigkeit")
                    Spacer()
                    Text(settings.speed, format: .number.precision(.fractionLength(2))).monospacedDigit().foregroundStyle(.secondary)
                    Text("×").foregroundStyle(.secondary)
                }
                Slider(value: $settings.speed, in: 0.25...2, step: 0.05)
            }
            if settings != ItemSettings() {
                Button("Zurücksetzen") { settings = ItemSettings() }
            }
        }
        .onChange(of: settings) { save() }
    }

    @ViewBuilder private var propertiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Eigenschaften").font(.subheadline.weight(.semibold))
            ForEach(properties) { p in propertyRow(p) }
        }
    }

    private func value(_ p: WallpaperProperty) -> String { settings.properties[p.id] ?? p.defaultJSON }
    private func setValue(_ p: WallpaperProperty, _ json: String) {
        settings.properties[p.id] = json == p.defaultJSON ? nil : json
    }

    @ViewBuilder private func propertyRow(_ p: WallpaperProperty) -> some View {
        switch p.kind {
        case .label:
            if !p.label.isEmpty { Text(p.label).font(.caption).foregroundStyle(.secondary) }
        case .bool:
            Toggle(p.label, isOn: Binding(get: { value(p) == "true" || value(p) == "1" }, set: { setValue(p, $0 ? "true" : "false") }))
        case .slider:
            let v = Double(value(p)) ?? p.min
            // `...` traps when lowerBound > upperBound (also with NaN) – so keep the bounds finite and ordered.
            let lo = p.min.isFinite ? p.min : 0
            let hi = max(p.max.isFinite ? p.max : 100, lo + 0.0001)
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(p.label); Spacer(); Text(v, format: .number.precision(.fractionLength(0...2))).foregroundStyle(.secondary).monospacedDigit() }
                Slider(value: Binding(get: { v }, set: { setValue(p, Self.json($0, step: p.step)) }),
                       in: lo...hi)
            }
        case .combo:
            Picker(p.label, selection: Binding(get: { value(p) }, set: { setValue(p, $0) })) {
                ForEach(p.options, id: \.json) { o in Text(o.label).tag(o.json) }
            }
        case .color:
            ColorPicker(p.label, selection: Binding(get: { Self.color(from: value(p)) }, set: { setValue(p, Self.json(color: $0)) }),
                        supportsOpacity: false)
        case .text:
            TextField(p.label, text: Binding(
                get: { (try? JSONSerialization.jsonObject(with: Data(value(p).utf8), options: .fragmentsAllowed)) as? String ?? "" },
                set: { setValue(p, Self.json(string: $0)) }))
        case .unsupported:
            EmptyView()
        }
    }

    private func save() {
        ItemSettings.save(settings, for: item.id)
        player.settingsChanged(for: item)
    }

    // Wallpaper Engine colors are strings "r g b" with values 0…1.
    static func color(from json: String) -> Color {
        let s = (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)) as? String ?? ""
        let c = s.split(separator: " ").compactMap { Double($0) }
        guard c.count >= 3 else { return .white }
        return Color(red: c[0], green: c[1], blue: c[2])
    }

    static func json(color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return json(string: String(format: "%.4f %.4f %.4f", ns.redComponent, ns.greenComponent, ns.blueComponent))
    }

    static func json(string: String) -> String {
        (try? JSONSerialization.data(withJSONObject: string, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    static func json(_ v: Double, step: Double) -> String {
        let r = step > 0 ? (v / step).rounded() * step : v
        // Int(exactly:) instead of Int(_:): the slider bounds come from project.json,
        // values outside the Int range would otherwise crash the app.
        if r == r.rounded() && step >= 1, let i = Int(exactly: r) { return String(i) }
        return String(format: "%.3f", r)
    }
}

// MARK: - Detail view for Workshop items

struct StarRating: View {
    let stars: Int?
    var body: some View {
        if let stars {
            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: i <= stars ? "star.fill" : "star").foregroundStyle(i <= stars ? .yellow : .secondary)
                }
            }
            .font(.caption)
        } else {
            Text("Noch nicht genug Bewertungen").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct WorkshopDetailSheet: View {
    let result: WorkshopResult
    @EnvironmentObject var browser: WorkshopBrowser
    @EnvironmentObject var steam: SteamCMD
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: WallpaperController
    @Environment(\.dismiss) private var dismiss
    @State private var details: WorkshopBrowser.Details?

    var body: some View {
        let local = library.contains(workshopID: result.id)
        VStack(alignment: .leading, spacing: 0) {
            Color.black
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { AnimatedPreview(url: result.previewURL, animates: true) }
                .clipped()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(result.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                        Spacer()
                        KindBadge(kind: result.kind)
                    }
                    HStack(spacing: 16) {
                        StarRating(stars: result.stars)
                        Label(result.subscriptions.formatted(), systemImage: "person.2")
                        if result.fileSize > 0 { Label(ByteCountFormatter.string(fromByteCount: result.fileSize, countStyle: .file), systemImage: "internaldrive") }
                        if let d = details { Label(d.views.formatted(), systemImage: "eye") }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    if let author = details?.author {
                        Text("von \(author)").foregroundStyle(.secondary)
                    }
                    if let u = details?.updated {
                        Text("Aktualisiert am \(u.formatted(date: .long, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                    }
                    let tags = result.tags.filter { !["Wallpaper", "Video", "Web", "Scene", "Application"].contains($0) }
                    if !tags.isEmpty {
                        FlowTags(tags: tags)
                    }
                    let desc = details?.description ?? result.shortDescription
                    if !desc.isEmpty {
                        Text(desc).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !result.kind.isSupported {
                        Label("\(result.kind.label)-Wallpaper laufen nur in Wallpaper Engine unter Windows.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if case .failed(let msg) = steam.states[result.id] {
                        Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("In Steam abonnieren …") {
                    // Opens the page in the Steam app or the browser – subscribe there,
                    // LiveBloom then downloads new subscriptions automatically.
                    guard AppPaths.isValidWorkshopID(result.id),
                          let steamURL = URL(string: "steam://url/CommunityFilePage/\(result.id)") else { return }
                    if NSWorkspace.shared.urlForApplication(toOpen: steamURL) != nil { NSWorkspace.shared.open(steamURL) }
                    else { NSWorkspace.shared.open(result.pageURL) }
                }
                if let local, local.isPlayable {
                    Button(player.isActive(local) ? "Aktiv" : "Anwenden") { player.set(local); dismiss() }
                        .buttonStyle(.borderedProminent).disabled(player.isActive(local))
                } else if result.kind.isSupported {
                    switch steam.states[result.id] {
                    case .queued, .downloading, .done:
                        ProgressView().controlSize(.small)
                    default:
                        Button("Herunterladen") { steam.download(result.id) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!steam.isInstalled || steam.validUsername == nil)
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 640, height: 720)
        .task { details = await browser.details(for: result.id) }
    }
}

struct FlowTags: View {
    let tags: [String]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { chips }
            VStack(alignment: .leading) {
                HStack { chips(Array(tags.prefix(tags.count / 2))) }
                HStack { chips(Array(tags.suffix(from: tags.count / 2))) }
            }
        }
    }
    @ViewBuilder private var chips: some View { chips(tags) }
    @ViewBuilder private func chips(_ t: [String]) -> some View {
        ForEach(t, id: \.self) { tag in
            Text(tag).font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
    }
}

// MARK: - Import from a Windows PC (without Steam sign-in)

@MainActor
final class ImportManager: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var progress = ""
    @Published private(set) var lastResult: String?

    func chooseAndImport(into library: Library) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Importieren")
        panel.message = String(localized: "Wähle den Ordner „431960“ vom Windows-PC (Steam\\steamapps\\workshop\\content\\431960) – z. B. von einem USB-Stick oder einer Netzwerkfreigabe.")
        guard panel.runModal() == .OK, let root = panel.url else { return }
        isImporting = true
        progress = String(localized: "Suche Wallpaper …")
        lastResult = nil
        Task.detached(priority: .utility) {
            let (copied, skipped, unsupported) = Self.importAll(from: root) { msg in
                Task { @MainActor in self.progress = msg }
            }
            await MainActor.run {
                self.isImporting = false
                self.progress = ""
                var parts = [String(localized: "\(copied) importiert")]
                if skipped > 0 { parts.append(String(localized: "\(skipped) schon vorhanden")) }
                if unsupported > 0 { parts.append(String(localized: "\(unsupported) Scenes übersprungen")) }
                self.lastResult = parts.joined(separator: " · ")
                library.refresh()
            }
        }
    }

    /// Copies all video/web wallpapers into the app's own library. Scenes are skipped.
    nonisolated static func importAll(from root: URL, progress: (String) -> Void) -> (Int, Int, Int) {
        let fm = FileManager.default
        var candidates: [URL] = []
        if fm.fileExists(atPath: root.appendingPathComponent("project.json").path) {
            candidates = [root]
        } else {
            candidates = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        var copied = 0, skipped = 0, unsupported = 0
        for (i, folder) in candidates.enumerated() {
            // Don't copy symbolic links from the foreign volume – they could point to
            // arbitrary folders on this Mac.
            if (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            guard let item = WallpaperItem.load(path: folder.path), folder.hasDirectoryPath || item.folder == folder else { continue }
            guard item.kind.isSupported else { unsupported += 1; continue }
            let id = item.workshopID.flatMap { AppPaths.isValidWorkshopID($0) ? $0 : nil } ?? folder.lastPathComponent
            guard !id.contains("/"), !id.hasPrefix(".") else { continue }
            let dest = AppPaths.libraryDir.appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: dest.path) { skipped += 1; continue }
            progress(String(localized: "Kopiere \(i + 1) von \(candidates.count): \(item.title)"))
            if (try? fm.copyItem(at: folder, to: dest)) != nil {
                AppPaths.removeSymlinks(in: dest)
                copied += 1
            }
        }
        return (copied, skipped, unsupported)
    }
}

// MARK: - Subscription sync like in Wallpaper Engine

/// Automatically downloads newly subscribed wallpapers and updates changed ones –
/// at launch and then every 6 hours (only with an API key and Steam sign-in).
@MainActor
final class SubscriptionSync: ObservableObject {
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "autoSync"); schedule() } }
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastMessage: String?

    private var timer: Timer?
    private weak var browser: WorkshopBrowser?
    private weak var steam: SteamCMD?
    private weak var library: Library?

    init() {
        enabled = UserDefaults.standard.object(forKey: "autoSync") as? Bool ?? true
    }

    func start(browser: WorkshopBrowser, steam: SteamCMD, library: Library) {
        self.browser = browser; self.steam = steam; self.library = library
        schedule()
        // Shortly after launch, so the Mac isn't slowed down at login.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in Task { await self?.syncNow() } }
    }

    private func schedule() {
        timer?.invalidate()
        guard enabled else { return }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in Task { await self?.syncNow() } }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func syncNow() async {
        guard enabled, let browser, let steam, let library,
              browser.hasAPIKey, browser.steamID64 != nil, steam.isInstalled, steam.validUsername != nil, !steam.needsLogin else { return }
        await browser.loadUserList(.subscriptions)
        guard let subs = browser.userLists[.subscriptions] else { return }
        var known = UserDefaults.standard.dictionary(forKey: "itemUpdated") as? [String: Int] ?? [:]
        var queued = 0
        for r in subs where r.kind.isSupported {
            if library.contains(workshopID: r.id) == nil {
                steam.download(r.id); queued += 1
            } else if let k = known[r.id], r.timeUpdated > k {
                // Newer version in the Workshop → download again (the folder is replaced afterwards).
                steam.download(r.id); queued += 1
            }
            if known[r.id] == nil || r.timeUpdated > (known[r.id] ?? 0) { known[r.id] = r.timeUpdated }
        }
        UserDefaults.standard.set(known, forKey: "itemUpdated")
        lastSync = Date()
        lastMessage = queued == 0 ? String(localized: "Alles aktuell") : String(localized: "\(queued) Wallpaper werden geladen")
    }
}
