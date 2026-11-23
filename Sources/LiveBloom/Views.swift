import SwiftUI
import AppKit

enum Section: Hashable { case library, workshop, settings }

struct ContentView: View {
    @State private var section: Section? = .library
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var showWelcome = false

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("Bibliothek", systemImage: "photo.on.rectangle.angled").tag(Section.library)
                Label("Workshop", systemImage: "globe").tag(Section.workshop)
                Label("Einstellungen", systemImage: "gearshape").tag(Section.settings)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            switch section ?? .library {
            case .library: LibraryView(goToWorkshop: { section = .workshop })
            case .workshop: WorkshopView(goToSettings: { section = .settings })
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .onAppear { if !onboardingDone { showWelcome = true } }
        .sheet(isPresented: $showWelcome) { WelcomeView(goToSettings: { section = .settings }) }
    }
}

// MARK: - Shared tile

/// Uniform tile: fixed 16:9 preview image, title with a fixed height, footer.
struct WallpaperTile<Preview: View, Footer: View>: View {
    let title: String
    let kind: WallpaperKind
    var isCurrent = false
    var dimmedText: LocalizedStringKey? = nil
    @ViewBuilder var preview: (_ animate: Bool) -> Preview
    @ViewBuilder var footer: () -> Footer
    @State private var hovering = false
    @State private var hoverSettled = false
    @AppStorage("previewAnimation") private var animation: PreviewAnimation = .click

    private var animate: Bool {
        switch animation { case .always: true; case .click: false; case .hover: hoverSettled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.secondary.opacity(0.12)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { preview(animate).environment(\.tileHovering, animation != .click && hoverSettled) }
                .clipped()
                .overlay(alignment: .topLeading) { KindBadge(kind: kind).padding(6) }
                .overlay {
                    if let dimmedText {
                        Color.black.opacity(0.5)
                            .overlay(Text(dimmedText).font(.caption.bold()).foregroundStyle(.white))
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                footer()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 22)
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isCurrent ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isCurrent ? 3 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .scaleEffect(hovering ? 1.02 : 1)
        .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: 8, y: 3)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { h in
            hovering = h
            if !h { hoverSettled = false; return }
            // Only animate after resting briefly – so sweeping across tiles doesn't start
            // video players and stop them again right away (that caused stutters).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                if hovering { hoverSettled = true }
            }
        }
    }
}

private let tileColumns = [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 14)]

struct KindBadge: View {
    let kind: WallpaperKind
    var body: some View {
        Text(kind.label)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Preview of a wallpaper on this Mac: animated GIF, or the video itself on hover.
struct LocalThumbnail: View {
    let url: URL?
    let video: URL?
    let animate: Bool
    @State private var videoFrame: NSImage?
    @Environment(\.tileHovering) private var hovering

    private var previewIsAnimated: Bool { url?.pathExtension.lowercased() == "gif" }

    var body: some View {
        ZStack {
            if let url {
                AnimatedPreview(url: url, animates: animate)
            } else if let videoFrame {
                Image(nsImage: videoFrame).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
            // No animated preview image available → play the video itself as the preview.
            // (Videos only on hover – many videos playing at once would be too expensive.)
            if animate, hovering, !previewIsAnimated, let video, AVURLAsset.isPlayableExtension(video.pathExtension) {
                HoverVideo(url: video).transition(.opacity)
            }
        }
        .task(id: video) {
            guard url == nil, let v = video else { return }
            if let cg = await VideoFrame.cgImage(for: v) {
                videoFrame = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}

struct RemoteThumbnail: View {
    let url: URL?
    let animate: Bool
    var body: some View { AnimatedPreview(url: url, animates: animate) }
}

extension AVURLAsset {
    static func isPlayableExtension(_ ext: String) -> Bool { ["mp4", "mov", "m4v"].contains(ext.lowercased()) }
}

import AVFoundation
enum VideoFrame {
    /// Still image from a video (downsampled, asynchronous – doesn't block a thread).
    static func cgImage(for url: URL) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 360)
        return try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    }
}

// MARK: - Library

struct LibraryView: View {
    enum Tab: String, CaseIterable, Identifiable, LocalizedLabel {
        case downloaded = "Auf diesem Mac", subscriptions = "Meine Steam-Abos", favorites = "Favoriten"
        var id: String { rawValue }
    }
    enum LibrarySort: String, CaseIterable, Identifiable, LocalizedLabel {
        case recent = "Zuletzt hinzugefügt", name = "Name", type = "Typ"
        var id: String { rawValue }
    }

    @EnvironmentObject var library: Library
    @EnvironmentObject var player: WallpaperController
    @EnvironmentObject var browser: WorkshopBrowser
    var goToWorkshop: () -> Void
    @AppStorage("libraryTab") private var tab: Tab = .downloaded
    @AppStorage("librarySort") private var sort: LibrarySort = .recent
    @AppStorage("libraryShowUnsupported") private var showUnsupported = false
    @State private var filter = ""
    @State private var selectedID: String?
    @AppStorage("applyTarget") private var applyTarget = "all"

    private var target: ScreenTarget { applyTarget == "all" ? .all : .screen(applyTarget) }
    private var selectedItem: WallpaperItem? { library.items.first { $0.id == selectedID } }

    var body: some View {
        HStack(spacing: 0) {
            libraryContent
            if tab == .downloaded, let item = selectedItem {
                Divider()
                ItemInspector(item: item)
            }
        }
    }

    private var libraryContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in Text(label(for: t)).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 480)
                Spacer()
                if tab == .downloaded {
                    if player.screens.count > 1 {
                        Picker("Anwenden auf", selection: $applyTarget) {
                            Text("Alle Bildschirme").tag("all")
                            ForEach(player.screens) { Text($0.name).tag($0.id) }
                        }
                        .frame(width: 240)
                    }
                    Picker("Sortieren", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 230)
                }
                Toggle("Scenes zeigen", isOn: $showUnsupported)
                    .toggleStyle(.checkbox)
                    .help("Scene-Wallpaper anzeigen – sie können auf dem Mac nicht abgespielt werden")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()

            switch tab {
            case .downloaded: downloaded
            case .subscriptions: SteamListView(list: .subscriptions, showUnsupported: showUnsupported, filter: filter)
            case .favorites: SteamListView(list: .favorites, showUnsupported: showUnsupported, filter: filter)
            }
        }
        .navigationTitle("Bibliothek")
        .searchable(text: $filter, prompt: "Bibliothek filtern")
        .toolbar {
            ToolbarItemGroup {
                Button { library.refresh() } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                Button { library.addFolder() } label: { Label("Ordner hinzufügen", systemImage: "folder.badge.plus") }
                if player.playlist.count > 1 {
                    Button { player.nextInPlaylist() } label: { Label("Nächstes aus Wiedergabeliste", systemImage: "forward.fill") }
                }
                if player.current != nil {
                    Button { player.togglePause() } label: {
                        Label(player.isPaused ? "Fortsetzen" : "Pausieren", systemImage: player.isPaused ? "play.fill" : "pause.fill")
                    }
                    Button { player.clear() } label: { Label("Wallpaper entfernen", systemImage: "xmark.circle") }
                }
            }
        }
    }

    private func label(for t: Tab) -> String {
        switch t {
        case .downloaded: return "\(t.label) (\(library.items.filter { showUnsupported || $0.kind.isSupported }.count))"
        case .subscriptions: return browser.userLists[.subscriptions].map { "\(t.label) (\($0.count))" } ?? t.label
        case .favorites: return browser.userLists[.favorites].map { "\(t.label) (\($0.count))" } ?? t.label
        }
    }

    private var visible: [WallpaperItem] {
        let items = library.items
            .filter { showUnsupported || $0.kind.isSupported }
            .filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
        switch sort {
        case .recent: return items.sorted { $0.added > $1.added }
        case .name: return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .type: return items.sorted { ($0.kind.label, $0.title) < ($1.kind.label, $1.title) }
        }
    }

    @ViewBuilder private var downloaded: some View {
        if visible.isEmpty {
            ContentUnavailableView {
                Label(filter.isEmpty ? "Noch keine Wallpaper auf diesem Mac" : "Keine Treffer", systemImage: "photo.stack")
            } description: {
                Text("Lade deine Steam-Abos herunter, durchsuche den Workshop oder füge einen Ordner mit Videos hinzu.")
            } actions: {
                Button("Meine Steam-Abos zeigen") { tab = .subscriptions }.buttonStyle(.borderedProminent)
                Button("Workshop durchsuchen", action: goToWorkshop)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: tileColumns, spacing: 14) {
                    ForEach(visible) { item in
                        LibraryCard(item: item, isCurrent: player.isActive(item), isSelected: selectedID == item.id,
                                    inPlaylist: player.isInPlaylist(item))
                            .onTapGesture {
                                // Like in Wallpaper Engine: a click selects and applies right away.
                                selectedID = item.id
                                if item.isPlayable { player.set(item, on: target) }
                            }
                            .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder private func contextMenu(for item: WallpaperItem) -> some View {
        if item.isPlayable {
            Button("Auf allen Bildschirmen anwenden") { player.set(item, on: .all) }
            if player.screens.count > 1 {
                Menu("Anwenden auf") {
                    ForEach(player.screens) { s in Button(s.name) { player.set(item, on: .screen(s.id)) } }
                }
            }
            Button(player.isInPlaylist(item) ? "Aus Wiedergabeliste entfernen" : "Zur Wiedergabeliste hinzufügen") { player.togglePlaylist(item) }
            Button("Einstellungen …") { selectedID = item.id }
        }
        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.id)]) }
        if let id = item.workshopID, id.allSatisfy(\.isNumber) {
            Button("Workshop-Seite öffnen") {
                NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!)
            }
        }
        Divider()
        Button("In den Papierkorb legen", role: .destructive) {
            if player.isActive(item) { player.clear() }
            library.moveToTrash(item)
        }
    }
}

struct LibraryCard: View {
    let item: WallpaperItem
    let isCurrent: Bool
    var isSelected = false
    var inPlaylist = false

    var body: some View {
        WallpaperTile(title: item.title, kind: item.kind, isCurrent: isCurrent || isSelected,
                      dimmedText: item.isPlayable ? nil : "Auf dem Mac nicht abspielbar") { animate in
            LocalThumbnail(url: item.preview, video: item.kind == .video ? item.mainFile : nil, animate: animate)
        } footer: {
            HStack {
                if isCurrent { Label("Aktiv", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                else if item.isPlayable { Text("Klicken zum Anwenden") }
                if inPlaylist { Image(systemName: "list.bullet").help("In der Wiedergabeliste") }
                Spacer()
                if item.added != .distantPast { Text(item.added, format: .dateTime.day().month().year()) }
            }
        }
        .help(item.isPlayable ? "Klicken, um als Wallpaper zu setzen" : "\(item.kind.label)-Wallpaper werden nicht unterstützt")
    }
}

/// Your Steam subscriptions or favorites – with download status and "Download all".
struct SteamListView: View {
    let list: WorkshopBrowser.UserList
    let showUnsupported: Bool
    let filter: String
    @EnvironmentObject var browser: WorkshopBrowser
    @EnvironmentObject var steam: SteamCMD
    @EnvironmentObject var library: Library

    private var items: [WorkshopResult] { browser.userLists[list] ?? [] }
    private var visible: [WorkshopResult] {
        items.filter { showUnsupported || $0.kind.isSupported }
            .filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
    }
    private var missing: [WorkshopResult] {
        items.filter { $0.kind.isSupported && library.contains(workshopID: $0.id) == nil && steam.states[$0.id] == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let err = browser.userListError {
                Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(10)
            }
            if !items.isEmpty {
                let playable = items.filter { $0.kind.isSupported }.count
                HStack {
                    (Text("\(items.count) Wallpaper · \(playable) auf dem Mac abspielbar")
                     + (items.count > playable ? Text(verbatim: " · ") + Text("\(items.count - playable) Scenes nicht unterstützt") : Text(verbatim: "")))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if !missing.isEmpty {
                        Button("Alle abspielbaren laden (\(missing.count))") { missing.forEach { steam.download($0.id) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!steam.isInstalled || steam.validUsername == nil)
                    }
                    Button { Task { await browser.loadUserList(list) } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Von Steam neu laden")
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
            }
            if browser.userListLoading.contains(list) && items.isEmpty {
                ProgressView("Lade \(list.label) von Steam …").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(list == .favorites ? "Keine Favoriten" : "Keine Abos",
                                       systemImage: list == .favorites ? "star" : "tray",
                                       description: Text(list == .favorites
                                                         ? "Wallpaper, die du im Workshop mit einem Stern markierst, erscheinen hier."
                                                         : "Wallpaper, die du in Wallpaper Engine abonniert hast, erscheinen hier."))
            } else {
                ScrollView {
                    LazyVGrid(columns: tileColumns, spacing: 14) {
                        ForEach(visible) { r in WorkshopCard(result: r) }
                    }
                    .padding(20)
                }
            }
        }
        .task(id: list) { if browser.userLists[list] == nil { await browser.loadUserList(list) } }
    }
}

// MARK: - Workshop

struct WorkshopView: View {
    @EnvironmentObject var browser: WorkshopBrowser
    @EnvironmentObject var steam: SteamCMD
    var goToSettings: () -> Void
    @State private var linkInput = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if !steam.isInstalled || steam.validUsername == nil || steam.needsLogin {
                    SetupBanner(goToSettings: goToSettings)
                }
                searchBar
                Divider()
                results
            }
            Divider()
            WorkshopFilterPanel()
                .frame(width: 240)
        }
        .navigationTitle("Workshop")
        .task { if browser.results.isEmpty && browser.hasAPIKey { await browser.reload() } }
        .onChange(of: browser.filterKey) { Task { await browser.reload() } }
        .toolbar {
            ToolbarItem {
                Button { NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/app/\(wallpaperEngineAppID)/workshop/")!) } label: {
                    Label("Im Browser öffnen", systemImage: "safari")
                }.help("Workshop im Browser öffnen – Links kannst du hier einfügen")
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Workshop durchsuchen …", text: $browser.searchText)
                    .textFieldStyle(.plain)
                if !browser.searchText.isEmpty {
                    Button { browser.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            TextField("oder Workshop-Link einfügen", text: $linkInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
                .onSubmit { Task { await browser.lookup(linkInput) } }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if let total = browser.totalCount, !browser.results.isEmpty {
                        Text("\(total.formatted()) Wallpaper")
                    }
                    if !browser.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("· sortiert nach Relevanz")
                    }
                    Spacer()
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 14)

                if let err = browser.errorMessage, browser.results.isEmpty {
                    VStack(spacing: 12) {
                        Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if !browser.hasAPIKey { Button("API-Schlüssel eintragen", action: goToSettings) }
                    }
                    .frame(maxWidth: .infinity).padding(40)
                }
                LazyVGrid(columns: tileColumns, spacing: 14) {
                    ForEach(browser.results) { r in
                        WorkshopCard(result: r)
                            .onAppear { if r.id == browser.results.last?.id { Task { await browser.loadMore() } } }
                    }
                }
                .padding(20)
                if browser.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
            }
        }
    }
}

/// Filter bar on the right, laid out like the Wallpaper Engine Workshop.
struct WorkshopFilterPanel: View {
    @EnvironmentObject var browser: WorkshopBrowser

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group("Sortieren nach") {
                    Picker("", selection: $browser.sort) {
                        ForEach(WorkshopBrowser.Sort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    if browser.sort == .popular {
                        Picker("Zeitraum", selection: $browser.period) {
                            ForEach(WorkshopBrowser.Period.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                group("Typ") {
                    Picker("", selection: $browser.typeFilter) {
                        ForEach(WorkshopBrowser.TypeFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text("Scene-Wallpaper laufen nur unter Windows und werden ausgeblendet.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                group("Altersfreigabe") {
                    Picker("", selection: $browser.ageFilter) {
                        ForEach(WorkshopBrowser.AgeFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                }
                group("Genre") {
                    Picker("", selection: $browser.genre) {
                        Text("Alle Genres").tag(String?.none)
                        Divider()
                        ForEach(WorkshopBrowser.genres, id: \.tag) { g in Text(g.label).tag(Optional(g.tag)) }
                    }
                    .labelsHidden()
                }
                group("Auflösung") {
                    Picker("", selection: $browser.resolution) {
                        Text("Alle Auflösungen").tag(String?.none)
                        Divider()
                        ForEach(WorkshopBrowser.resolutions, id: \.self) { r in
                            (r == "Other resolution" ? Text("Andere") : Text(verbatim: r)).tag(Optional(r))
                        }
                    }
                    .labelsHidden()
                }
                if browser.hasActiveFilters {
                    Button("Filter zurücksetzen") { browser.resetFilters() }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private func group<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }
}

struct SetupBanner: View {
    @EnvironmentObject var steam: SteamCMD
    var goToSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(steam.needsLogin
                 ? "Zum Herunterladen musst du dich einmal bei Steam anmelden (Einstellungen → Steam-Anmeldung)."
                 : "Zum Herunterladen brauchst du steamcmd und dein Steam-Konto (mit Wallpaper Engine).")
            Spacer()
            Button("Einrichten", action: goToSettings)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12))
    }
}

struct WorkshopCard: View {
    let result: WorkshopResult
    @EnvironmentObject var steam: SteamCMD
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: WallpaperController
    @State private var showDetails = false

    var body: some View {
        let local = library.contains(workshopID: result.id)
        WallpaperTile(title: result.title, kind: result.kind,
                      isCurrent: local.map { player.isActive($0) } ?? false,
                      dimmedText: result.kind.isSupported ? nil : "Auf dem Mac nicht abspielbar") { animate in
            RemoteThumbnail(url: result.previewURL, animate: animate)
        } footer: {
            HStack(spacing: 8) {
                if case .failed(let msg) = steam.states[result.id] {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(msg)
                    Text("Fehler").foregroundStyle(.red).help(msg)
                } else {
                    if let stars = result.stars {
                        Label("\(stars)", systemImage: "star.fill").help("\(stars) von 5 Sternen")
                    }
                    Label(result.subscriptions.formatted(.number.notation(.compactName)), systemImage: "person.2")
                    if result.fileSize > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: result.fileSize, countStyle: .file))
                    }
                }
                Spacer()
                actionButton(local: local)
            }
        }
        .onTapGesture { showDetails = true }
        .sheet(isPresented: $showDetails) { WorkshopDetailSheet(result: result) }
        .contextMenu {
            Button("Workshop-Seite öffnen") { NSWorkspace.shared.open(result.pageURL) }
            if case .failed = steam.states[result.id] { Button("Erneut laden") { steam.retry(result.id) } }
        }
    }

    @ViewBuilder private func actionButton(local: WallpaperItem?) -> some View {
        if let local {
            if local.isPlayable {
                Button(player.isActive(local) ? "Aktiv" : "Anwenden") { player.set(local) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(player.isActive(local))
            }
        } else if result.kind.isSupported {
            switch steam.states[result.id] {
            case .queued: Text("Wartet …")
            case .downloading: ProgressView().controlSize(.small)
            case .done: ProgressView().controlSize(.small).task { library.refresh() }
            case .failed: Button("Erneut") { steam.retry(result.id) }.controlSize(.small)
            case nil:
                Button { steam.download(result.id) } label: { Label("Laden", systemImage: "arrow.down.circle") }
                    .controlSize(.small)
                    .disabled(!steam.isInstalled || steam.validUsername == nil)
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var sync: SubscriptionSync
    @EnvironmentObject var importer: ImportManager
    @EnvironmentObject var steam: SteamCMD
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: WallpaperController
    @EnvironmentObject var browser: WorkshopBrowser
    @State private var apiKey = APIKeyStore.value
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var password = ""
    @State private var guardCode = ""
    @AppStorage("previewAnimation") private var previewAnimation: PreviewAnimation = .click
    @State private var language = AppLanguage.selected

    var body: some View {
        Form {
            SwiftUI.Section {
                Picker("Sprache der App", selection: $language) {
                    Text("Systemsprache").tag("")
                    Divider()
                    ForEach(AppLanguage.supported, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                }
                .onChange(of: language) { AppLanguage.select(language) }
                if language != AppLanguage.launchedWith {
                    HStack {
                        Text("Die neue Sprache gilt nach einem Neustart von LiveBloom.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Jetzt neu starten") { AppLanguage.relaunch() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } header: {
                // Always in English too, so the setting can be found again in any language.
                Label { Text("Sprache") + Text(verbatim: AppLanguage.current == "en" ? "" : " · Language") } icon: { Image(systemName: "globe") }
            }
            SwiftUI.Section("1 · Workshop-Suche (API-Schlüssel)") {
                HStack {
                    TextField("Steam-Web-API-Schlüssel hier einfügen (⌘V)", text: $apiKey)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: apiKey) { saveKey() }
                        .onSubmit(saveKey)
                    Button("Einfügen") {
                        if let s = NSPasteboard.general.string(forType: .string) { apiKey = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .help("Schlüssel aus der Zwischenablage einfügen")
                    if !apiKey.isEmpty {
                        Button("Löschen") { apiKey = "" }
                    }
                }
                HStack {
                    if apiKey.isEmpty {
                        Text("Damit kannst du den Workshop direkt in der App durchsuchen.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if APIKeyStore.looksValid(apiKey) {
                        Label("Schlüssel gespeichert", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Gespeichert, sieht aber unvollständig aus (Steam-Schlüssel haben 32 Zeichen).", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Link("Schlüssel holen", destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
                }
            }

            SwiftUI.Section("2 · Herunterladen (Steam-Anmeldung)") {
                Text("Der API-Schlüssel erlaubt nur die Suche. Zum Herunterladen verlangt Steam eine Anmeldung mit einem Konto, das Wallpaper Engine besitzt. Das Passwort geht über eine private Verbindung direkt an Valves steamcmd und wird nicht gespeichert – danach bleibst du angemeldet. Ohne Anmeldung: Ordner vom Windows-PC importieren (unten).")
                    .font(.caption).foregroundStyle(.secondary)
                if !steam.rosettaAvailable {
                    Text("steamcmd braucht Rosetta. Installiere es im Terminal mit: softwareupdate --install-rosetta")
                        .font(.caption).foregroundStyle(.red)
                }
                if !steam.isInstalled {
                    HStack {
                        Button(steam.isInstalling ? "Installiere …" : "steamcmd installieren") { Task { await steam.install() } }
                            .disabled(steam.isInstalling)
                        if steam.isInstalling { ProgressView().controlSize(.small) }
                    }
                }
                TextField("Steam-Login-Name", text: $steam.username)
                    .textContentType(.username)
                SecureField("Passwort", text: $password)
                    .textContentType(.password)
                    .onSubmit(startLogin)
                if steam.loginState == .needsCode {
                    TextField("Steam-Guard-Code (aus E-Mail oder Steam-App)", text: $guardCode)
                        .onSubmit(startLogin)
                }
                HStack {
                    switch steam.loginState {
                    case .running:
                        ProgressView().controlSize(.small); Text("Melde an …")
                    case .waitingForPhone:
                        ProgressView().controlSize(.small); Text("Bestätige die Anmeldung in der Steam-App auf deinem Handy.")
                    case .needsCode:
                        Image(systemName: "key.fill").foregroundStyle(.orange); Text("Steam möchte einen Steam-Guard-Code.")
                    case .success:
                        Label("Angemeldet – Downloads sind bereit", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let msg):
                        Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    case .idle:
                        if steam.hasSavedLogin && !steam.needsLogin {
                            Label("Angemeldet – du bleibst angemeldet", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    Spacer()
                    Button(steam.loginState == .needsCode ? "Code bestätigen" : "Anmelden", action: startLogin)
                        .buttonStyle(.borderedProminent)
                        .disabled(!steam.isInstalled || steam.validUsername == nil
                                  || (steam.loginState == .needsCode ? guardCode.isEmpty : password.isEmpty)
                                  || steam.loginState == .running || steam.loginState == .waitingForPhone)
                    if steam.loginState == .running || steam.loginState == .waitingForPhone || steam.loginState == .needsCode {
                        Button("Abbrechen") { steam.cancelLogin() }
                    }
                }
            }

            SwiftUI.Section("Wiedergabe") {
                Toggle("Ton stumm", isOn: $player.isMuted)
                Slider(value: $player.volume, in: 0...1) { Text("Lautstärke") }
                    .disabled(player.isMuted)
                Picker("Vorschauen in der Übersicht bewegen", selection: $previewAnimation) {
                    ForEach(PreviewAnimation.allCases) { Text($0.label).tag($0) }
                }
                Text("Pausiert automatisch, wenn eine andere App im Vollbild läuft.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try LoginItem.set(on); loginError = nil } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }

            SwiftUI.Section("Web-Wallpaper") {
                Toggle("Internetzugriff erlauben", isOn: $player.allowWebNetwork)
                Text("Aus Sicherheitsgründen aus: Web-Wallpaper dürfen dann nichts aus dem Internet laden oder senden und nur Dateien aus ihrem eigenen Ordner lesen. Nur einschalten, wenn ein Wallpaper z. B. Wetterdaten braucht.")
                    .font(.caption).foregroundStyle(.secondary)
                if player.allowWebNetwork {
                    Label("Achtung: Jedes Web-Wallpaper kann jetzt beliebige Internet-Server erreichen. Verbindungen zu Geräten in deinem Heimnetz (Router, NAS, localhost) und zu diesem Mac werden über einen Filter blockiert – die öffentliche Adresse deines Routers kann er aber nicht immer erkennen. Nur mit Wallpapern nutzen, deren Ersteller du vertraust.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("Bildrate", selection: $player.webFPS) {
                    Text("15 FPS (sparsam)").tag(15)
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                }
            }

            SwiftUI.Section("Wiedergabeliste") {
                Toggle("Wallpaper automatisch wechseln", isOn: $player.playlistEnabled)
                Picker("Wechseln alle", selection: $player.playlistMinutes) {
                    ForEach([5, 10, 15, 30, 60, 120, 240], id: \.self) { m in Text(m < 60 ? "\(m) Minuten" : m == 60 ? "1 Stunde" : "\(m / 60) Stunden").tag(m) }
                }
                .disabled(!player.playlistEnabled)
                Toggle("Zufällige Reihenfolge", isOn: $player.playlistShuffle)
                    .disabled(!player.playlistEnabled)
                Text(player.playlist.isEmpty
                     ? "Füge Wallpaper per Rechtsklick in der Bibliothek hinzu."
                     : "\(player.playlist.count) Wallpaper in der Wiedergabeliste. Während Vollbild-Apps wird nicht gewechselt.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section("Abos abgleichen") {
                Toggle("Neue und aktualisierte Abos automatisch laden", isOn: $sync.enabled)
                HStack {
                    if let d = sync.lastSync {
                        Text("Zuletzt: \(d.formatted(date: .omitted, time: .shortened)) – \(sync.lastMessage ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Prüft beim Start und alle 6 Stunden, was du in Wallpaper Engine abonniert hast.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Jetzt abgleichen") { Task { await sync.syncNow() } }
                        .disabled(!sync.enabled)
                }
            }

            SwiftUI.Section("Vom Windows-PC importieren (ohne Steam-Anmeldung)") {
                Text("Kopiere am PC den Ordner Steam\\steamapps\\workshop\\content\\431960 auf einen USB-Stick oder öffne ihn über eine Netzwerkfreigabe und wähle ihn hier aus. LiveBloom übernimmt alle Video- und Web-Wallpaper in die eigene Bibliothek.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if importer.isImporting {
                        ProgressView().controlSize(.small)
                        Text(importer.progress).font(.caption).lineLimit(1)
                    } else if let r = importer.lastResult {
                        Label(r, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Ordner auswählen …") { importer.chooseAndImport(into: library) }
                        .disabled(importer.isImporting)
                }
            }

            SwiftUI.Section("Eigene Ordner") {
                ForEach(library.extraFolders, id: \.self) { url in
                    HStack {
                        Text(url.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Entfernen") { library.removeFolder(url) }
                    }
                }
                Button("Ordner hinzufügen …") { library.addFolder() }
            }

            SwiftUI.Section("steamcmd-Protokoll") {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(steam.log.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                    .onChange(of: steam.log.count) { proxy.scrollTo(steam.log.count - 1) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Einstellungen")
    }

    private func startLogin() {
        if steam.loginState == .needsCode {
            steam.submitCode(guardCode)
            guardCode = ""
            return
        }
        let pw = password
        password = ""   // Don't keep the password in the form longer than necessary
        Task { await steam.login(password: pw) }
    }

    private func saveKey() {
        let old = APIKeyStore.value
        APIKeyStore.value = apiKey
        if APIKeyStore.value != old && APIKeyStore.looksValid(apiKey) { Task { await browser.reload() } }
    }

}
