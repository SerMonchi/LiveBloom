import AppKit
import AVFoundation
import Network
import WebKit

// MARK: - Per-wallpaper settings

enum Scaling: String, Codable, CaseIterable, Identifiable, LocalizedLabel {
    case fill = "Füllen", fit = "Einpassen", stretch = "Strecken"
    var id: String { rawValue }
    var gravity: AVLayerVideoGravity {
        switch self { case .fill: .resizeAspectFill; case .fit: .resizeAspect; case .stretch: .resize }
    }
    var cssFit: String {
        switch self { case .fill: "cover"; case .fit: "contain"; case .stretch: "fill" }
    }
}

struct ItemSettings: Codable, Equatable {
    var scaling: Scaling = .fill
    var speed: Double = 1.0
    /// Changed web properties: name → JSON value (e.g. "0.5", "true", "\"1 0 0\"").
    var properties: [String: String] = [:]

    private static let key = "itemSettings"

    static func load(_ id: String) -> ItemSettings {
        guard let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Data],
              let d = all[id], let s = try? JSONDecoder().decode(ItemSettings.self, from: d) else { return ItemSettings() }
        return s
    }

    static func save(_ s: ItemSettings, for id: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        all[id] = s == ItemSettings() ? nil : try? JSONEncoder().encode(s)
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// Target when applying: all displays or a specific one.
enum ScreenTarget: Hashable {
    case all
    case screen(String)
}

struct ScreenInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

extension NSScreen {
    /// Stable identifier of a display (stays the same after a restart).
    var stableID: String {
        guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, uuid) as String? else { return localizedName }
        return s
    }
}

// MARK: - Controller

/// Shows wallpapers in borderless windows at desktop level (behind the desktop icons) –
/// a separate wallpaper per display, like in Wallpaper Engine.
@MainActor
final class WallpaperController: ObservableObject {
    @Published private(set) var assignments: [String: WallpaperItem] = [:]
    @Published private(set) var isPaused = false
    @Published private(set) var screens: [ScreenInfo] = []
    @Published var isMuted: Bool { didSet { defaults.set(isMuted, forKey: "muted"); applyAudio() } }
    @Published var volume: Double { didSet { defaults.set(volume, forKey: "volume"); applyAudio() } }
    @Published var allowWebNetwork: Bool { didSet { defaults.set(allowWebNetwork, forKey: "allowWebNetwork"); updateProxy(); rebuild(force: true) } }
    @Published var webFPS: Int { didSet { defaults.set(webFPS, forKey: "webFPS"); rebuild(force: true) } }

    // Playlist
    @Published private(set) var playlist: [String] { didSet { defaults.set(playlist, forKey: "playlist") } }
    @Published var playlistEnabled: Bool { didSet { defaults.set(playlistEnabled, forKey: "playlistEnabled"); schedulePlaylist() } }
    @Published var playlistMinutes: Int { didSet { defaults.set(playlistMinutes, forKey: "playlistMinutes"); schedulePlaylist() } }
    @Published var playlistShuffle: Bool { didSet { defaults.set(playlistShuffle, forKey: "playlistShuffle") } }

    private let defaults = UserDefaults.standard
    private var renderers: [String: ScreenRenderer] = [:]
    private var defaultItem: WallpaperItem?
    private var userPaused = false
    private var screenOff = false
    private var coveredScreens: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var fullscreenCheck: DispatchWorkItem?
    private var playlistTimer: Timer?
    private var blockRules: WKContentRuleList?
    private var rulesReady = false
    private var lanRules: WKContentRuleList?
    /// Port of the local filtering proxy (nil while it isn't running) – required for web wallpapers with internet.
    private var proxyPort: UInt16?

    /// The wallpaper of the main display (for the menu bar & UI).
    var current: WallpaperItem? {
        if let main = NSScreen.main?.stableID, let i = assignments[main] { return i }
        return assignments.values.first
    }

    func isActive(_ item: WallpaperItem) -> Bool { assignments.values.contains { $0.id == item.id } }
    func screensShowing(_ item: WallpaperItem) -> [String] { assignments.filter { $0.value.id == item.id }.map(\.key) }

    init() {
        isMuted = defaults.object(forKey: "muted") as? Bool ?? true
        volume = defaults.object(forKey: "volume") as? Double ?? 0.5
        allowWebNetwork = defaults.bool(forKey: "allowWebNetwork")
        webFPS = defaults.object(forKey: "webFPS") as? Int ?? 30
        playlist = defaults.stringArray(forKey: "playlist") ?? []
        playlistEnabled = defaults.bool(forKey: "playlistEnabled")
        playlistMinutes = defaults.object(forKey: "playlistMinutes") as? Int ?? 30
        playlistShuffle = defaults.object(forKey: "playlistShuffle") as? Bool ?? true

        // Older version: one wallpaper for all displays.
        if let old = defaults.string(forKey: "currentWallpaper") {
            defaults.set(old, forKey: "defaultWallpaper")
            defaults.removeObject(forKey: "currentWallpaper")
        }
        defaultItem = defaults.string(forKey: "defaultWallpaper").flatMap(WallpaperItem.load(path:)).flatMap { $0.isPlayable ? $0 : nil }

        let nc = NotificationCenter.default
        let wnc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        })
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenOff = true; self?.applyPlayback() }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenOff = false; self?.applyPlayback(); self?.scheduleFullscreenCheck() }
            })
        }
        // Fullscreen detection: only check on Space/app switches, no continuous polling.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification] {
            observers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleFullscreenCheck() }
            })
        }

        // Rules that block all internet access for web wallpapers.
        let rules = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "livebloom-offline", encodedContentRuleList: rules) { [weak self] list, error in
            Task { @MainActor in
                guard let self else { return }
                // Security: without a compiled block list there are no web wallpapers (instead of loading them unprotected).
                guard let list else {
                    NSLog("LiveBloom: could not compile the network block rules: \(String(describing: error))")
                    return
                }
                self.blockRules = list
                self.rulesReady = true
                // Now build the deferred web wallpapers (once, without reloading).
                self.rebuild()
            }
        }

        // Even with internet allowed: no access to the home network (router, NAS, localhost services).
        // Only a match on the URL string: it doesn't catch names that resolve to home network addresses via DNS.
        let lanHosts = ["localhost", "127\\.", "0\\.0\\.0\\.0", "10\\.", "192\\.168\\.", "169\\.254\\.",
                        "172\\.1[6-9]\\.", "172\\.2[0-9]\\.", "172\\.3[01]\\.", "\\[", "[^/:]*\\.local[:/]",
                        "[^/:]*\\.local$", "[^/:]*\\.localhost[:/]", "[^/:]*\\.home\\.arpa[:/]", "[^/:]*\\.fritz\\.box[:/]"]
        // In addition only complete hosts: home network names (also without a subdomain), carrier-grade NAT 100.64.0.0/10
        // as a complete IPv4 address and names without a dot (e.g. "nas") – each with an optional
        // trailing dot and port. That way public names like "100.64.example.com" stay reachable.
        let lanNames = ["local", "localhost", "localdomain", "lan", "home", "internal", "home\\.arpa", "fritz\\.box",
                        "myfritz\\.box", "fritz\\.nas", "fritz\\.repeater", "speedport\\.ip", "easy\\.box"]
        let cgnatPrefixes = ["100\\.6[4-9]", "100\\.[7-9][0-9]", "100\\.1[01][0-9]", "100\\.12[0-7]"]
        let fullHosts = lanNames.map { "([^/:]*\\.)?\($0)" } + cgnatPrefixes.map { "\($0)\\.[0-9]+\\.[0-9]+" } + ["[^/:.]+"]
        let anchoredHosts = fullHosts.flatMap { ["\($0)\\.?(:[0-9]*)?/", "\($0)\\.?(:[0-9]*)?$"] }
        let lanRuleObjects: [[String: Any]] = (lanHosts + anchoredHosts).flatMap { host in
            ["https?", "wss?"].map { scheme in
                ["trigger": ["url-filter": "^\(scheme)://([^/@]*@)?\(host)"], "action": ["type": "block"]]
            }
        }
        let lanRules = (try? JSONSerialization.data(withJSONObject: lanRuleObjects)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "livebloom-nolan", encodedContentRuleList: lanRules) { [weak self] list, error in
            Task { @MainActor in
                guard let self else { return }
                guard let list else {
                    NSLog("LiveBloom: could not compile the home network block rules: \(String(describing: error))")
                    return
                }
                self.lanRules = list
                if self.allowWebNetwork { self.rebuild() }
            }
        }
        updateProxy()

        DispatchQueue.main.async { [weak self] in self?.rebuild(); self?.schedulePlaylist() }
        // Note: video wallpapers start right away; web wallpapers are rebuilt once with the rules
        // after the block rules have been compiled (a few milliseconds).
    }

    // MARK: Public control

    func set(_ item: WallpaperItem, on target: ScreenTarget = .all) {
        guard item.isPlayable else { return }
        userPaused = false
        var saved = defaults.dictionary(forKey: "screenAssignments") as? [String: String] ?? [:]
        switch target {
        case .all:
            defaultItem = item
            defaults.set(item.id, forKey: "defaultWallpaper")
            saved = [:]
        case .screen(let id):
            saved[id] = item.id
        }
        defaults.set(saved, forKey: "screenAssignments")
        rebuild()
    }

    func clear(on target: ScreenTarget = .all) {
        switch target {
        case .all:
            defaultItem = nil
            defaults.removeObject(forKey: "defaultWallpaper")
            defaults.removeObject(forKey: "screenAssignments")
        case .screen(let id):
            var saved = defaults.dictionary(forKey: "screenAssignments") as? [String: String] ?? [:]
            saved[id] = ""   // empty entry = show nothing on this display
            defaults.set(saved, forKey: "screenAssignments")
        }
        rebuild()
    }

    func togglePause() {
        userPaused.toggle()
        applyPlayback()
    }

    /// A wallpaper's settings changed → apply them live.
    func settingsChanged(for item: WallpaperItem) {
        let s = ItemSettings.load(item.id)
        for r in renderers.values where r.item.id == item.id { r.apply(settings: s) }
    }

    // MARK: Playlist

    func isInPlaylist(_ item: WallpaperItem) -> Bool { playlist.contains(item.id) }

    func togglePlaylist(_ item: WallpaperItem) {
        if let i = playlist.firstIndex(of: item.id) { playlist.remove(at: i) } else if item.isPlayable { playlist.append(item.id) }
        schedulePlaylist()
    }

    func nextInPlaylist() {
        let items = playlist.compactMap(WallpaperItem.load(path:)).filter(\.isPlayable)
        guard !items.isEmpty else { return }
        let currentID = current?.id
        let next: WallpaperItem
        if playlistShuffle {
            next = items.filter { $0.id != currentID }.randomElement() ?? items[0]
        } else {
            let idx = items.firstIndex { $0.id == currentID } ?? -1
            next = items[(idx + 1) % items.count]
        }
        set(next, on: .all)
    }

    private func schedulePlaylist() {
        playlistTimer?.invalidate()
        playlistTimer = nil
        guard playlistEnabled, playlist.count > 1, playlistMinutes > 0 else { return }
        let t = Timer(timeInterval: TimeInterval(playlistMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPaused else { return }   // don't switch while paused/fullscreen
                self.nextInPlaylist()
            }
        }
        t.tolerance = 30   // allows macOS to coalesce the timer to save energy
        RunLoop.main.add(t, forMode: .common)
        playlistTimer = t
    }

    // MARK: Setup

    /// Run the filtering proxy (checks the actually resolved IP on every connection, against DNS tricks)
    /// only while web wallpapers have internet access.
    private func updateProxy() {
        guard allowWebNetwork else {
            proxyPort = nil
            NetGuardProxy.shared.stop()
            return
        }
        NetGuardProxy.shared.start { [weak self] port in
            Task { @MainActor in
                guard let self, let port, self.allowWebNetwork else { return }
                guard self.proxyPort != port else { return }
                self.proxyPort = port
                self.rebuild(force: true)
            }
        }
    }

    private func rebuild(force: Bool = false) {
        let saved = defaults.dictionary(forKey: "screenAssignments") as? [String: String] ?? [:]
        var newAssignments: [String: WallpaperItem] = [:]
        var alive = Set<String>()
        screens = NSScreen.screens.map { ScreenInfo(id: $0.stableID, name: $0.localizedName) }

        for screen in NSScreen.screens {
            let sid = screen.stableID
            let item: WallpaperItem?
            if let path = saved[sid] {
                item = path.isEmpty ? nil : WallpaperItem.load(path: path).flatMap { $0.isPlayable ? $0 : nil }
            } else {
                item = defaultItem
            }
            guard let item else { continue }
            newAssignments[sid] = item
            alive.insert(sid)

            if let r = renderers[sid], r.item.id == item.id, !force {
                r.updateFrame(screen.frame)
            } else {
                // Only start web wallpapers once the network block rules are compiled (a few ms).
                // Without a matching block list no web wallpaper is started (safe instead of open).
                let rules = allowWebNetwork ? lanRules : (rulesReady ? blockRules : nil)
                if item.kind == .web, rules == nil { continue }
                // With internet only through the filtering proxy; if it isn't running, the web wallpaper stays off.
                if item.kind == .web, allowWebNetwork, proxyPort == nil { continue }
                let old = renderers[sid]
                let new = ScreenRenderer(screenID: sid, frame: screen.frame, item: item,
                                         settings: ItemSettings.load(item.id),
                                         blockRules: rules,
                                         allowNetwork: allowWebNetwork, proxyPort: allowWebNetwork ? proxyPort : nil,
                                         fps: webFPS)
                // The old wallpaper stays until the new one shows its first frame –
                // then it cross-fades. No black flash, no brief glimpse of the desktop.
                if let old { new.onReady = { old.teardown(animated: false) } }
                renderers[sid] = new
            }
        }
        for (sid, r) in renderers where !alive.contains(sid) { r.teardown(animated: true); renderers[sid] = nil }
        assignments = newAssignments
        applyAudio()
        applyPlayback()
        scheduleFullscreenCheck()
    }

    private func applyAudio() {
        // Sound on one display only, so several videos don't play over each other.
        let audible = NSScreen.main?.stableID ?? renderers.keys.first
        for (sid, r) in renderers { r.setAudio(muted: isMuted || sid != audible, volume: volume) }
    }

    private func applyPlayback() {
        for (sid, r) in renderers {
            r.setPaused(userPaused || screenOff || coveredScreens.contains(sid))
        }
        isPaused = userPaused || screenOff || (!renderers.isEmpty && renderers.keys.allSatisfy { coveredScreens.contains($0) })
    }

    // MARK: Fullscreen detection

    private func scheduleFullscreenCheck() {
        fullscreenCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkFullscreen() }
        fullscreenCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func checkFullscreen() {
        guard !renderers.isEmpty else { return }
        let covered = FullscreenDetector.coveredScreenIDs()
        if covered != coveredScreens {
            coveredScreens = covered
            applyPlayback()
        }
    }
}

// MARK: - A single display

@MainActor
final class ScreenRenderer: NSObject, WKNavigationDelegate, WKUIDelegate {
    let screenID: String
    let item: WallpaperItem
    private let window: NSWindow
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerView: PlayerView?
    private var webView: WKWebView?
    private var still: NSImageView?
    private var settings: ItemSettings
    private var paused = false
    private let isNativeVideo: Bool
    var isWeb: Bool { webView != nil }

    init(screenID: String, frame: NSRect, item: WallpaperItem, settings: ItemSettings,
         blockRules: WKContentRuleList?, allowNetwork: Bool, proxyPort: UInt16?, fps: Int) {
        self.screenID = screenID
        self.item = item
        self.settings = settings
        let file = item.mainFile!
        isNativeVideo = item.kind == .video && AVURLAsset.isPlayableExtension(file.pathExtension)

        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        super.init()

        if isNativeVideo {
            let q = AVQueuePlayer()
            q.preventsDisplaySleepDuringVideoPlayback = false
            q.automaticallyWaitsToMinimizeStalling = false
            player = q
            loadVideo(file: file, withAudio: false)
            let v = PlayerView(player: q)
            playerView = v
            window.contentView = v
        } else {
            let wv = makeWebView(file: file, blockRules: blockRules, proxyPort: proxyPort, fps: fps)
            let container = NSView()
            wv.autoresizingMask = [.width, .height]
            let s = NSImageView()
            s.imageScaling = .scaleAxesIndependently
            s.autoresizingMask = [.width, .height]
            s.isHidden = true
            container.addSubview(wv)
            container.addSubview(s)
            window.contentView = container
            wv.frame = container.bounds
            s.frame = container.bounds
            webView = wv
            still = s
        }
        window.setFrame(frame, display: true)
        window.alphaValue = 0          // only show once the first frame is ready
        window.orderFront(nil)
        apply(settings: settings)
        if let playerView {
            readyObservation = playerView.layerRef.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async { self?.markReady() }
            }
        }
        // Safety net: show after 3 seconds at the latest.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.markReady() }
    }

    private var hasAudio = false
    private var loadGeneration = 0

    /// Builds the endless loop. When muted only the video track is played: no audio decoding,
    /// and the loop ends exactly on the last frame – a longer audio track otherwise causes
    /// a brief stutter or a black moment at the loop point.
    private func loadVideo(file: URL, withAudio: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        Task { @MainActor in
            let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            var templateItem = AVPlayerItem(asset: asset)
            if let video = try? await asset.loadTracks(withMediaType: .video).first,
               let range = try? await video.load(.timeRange) {
                let comp = AVMutableComposition()
                if let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                   (try? vt.insertTimeRange(range, of: video, at: .zero)) != nil {
                    vt.preferredTransform = (try? await video.load(.preferredTransform)) ?? .identity
                    if withAudio, let audio = try? await asset.loadTracks(withMediaType: .audio).first,
                       let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        // Trim the audio to the video length so the loop stays clean.
                        let aRange = (try? await audio.load(.timeRange)) ?? range
                        let dur = CMTimeMinimum(aRange.duration, range.duration)
                        try? at.insertTimeRange(CMTimeRange(start: aRange.start, duration: dur), of: audio, at: .zero)
                    }
                    templateItem = AVPlayerItem(asset: comp)
                }
            }
            guard generation == loadGeneration, let player else { return }
            looper?.disableLooping()
            player.removeAllItems()
            looper = AVPlayerLooper(player: player, templateItem: templateItem)
            hasAudio = withAudio
            player.defaultRate = Float(settings.speed)
            if !paused { player.rate = Float(settings.speed) }
        }
    }

    func updateFrame(_ frame: NSRect) {
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    var onReady: (() -> Void)?
    private(set) var isReady = false
    private var readyObservation: NSKeyValueObservation?

    private func markReady() {
        guard !isReady else { return }
        isReady = true
        readyObservation = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            window.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.onReady?()
                self?.onReady = nil
            }
        })
    }

    func teardown(animated: Bool = false) {
        readyObservation = nil
        onReady = nil
        if animated {
            let w = window
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                w.animator().alphaValue = 0
            }, completionHandler: { [self] in Task { @MainActor in self.finishTeardown() } })
        } else {
            finishTeardown()
        }
    }

    private func finishTeardown() {
        player?.pause()
        looper = nil
        player = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        window.orderOut(nil)
        window.close()
    }

    func apply(settings: ItemSettings) {
        self.settings = settings
        if let player {
            playerView?.gravity = settings.scaling.gravity
            player.defaultRate = Float(settings.speed)
            if !paused { player.rate = Float(settings.speed) }
        }
        if let webView {
            if item.kind == .web {
                webView.evaluateJavaScript(Self.propertyScript(item: item, settings: settings), completionHandler: nil)
            } else {
                webView.evaluateJavaScript("""
                document.querySelectorAll('video').forEach(function(v){v.playbackRate=\(settings.speed);v.style.objectFit='\(settings.scaling.cssFit)';});
                """, completionHandler: nil)
            }
        }
    }

    func setAudio(muted: Bool, volume: Double) {
        // Sound is needed but the loop only has video → rebuild once with audio.
        if !muted, !hasAudio, isNativeVideo, let file = item.mainFile { loadVideo(file: file, withAudio: true) }
        player?.isMuted = muted
        player?.volume = Float(volume)
        webView?.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(m){m.muted=\(muted);m.volume=\(volume);});", completionHandler: nil)
    }

    func setPaused(_ p: Bool) {
        guard p != paused || (!p && player?.rate == 0) else { return }
        paused = p
        if let player {
            if p { player.pause() } else { player.rate = Float(settings.speed) }
        }
        if let webView, let still {
            webView.setAllMediaPlaybackSuspended(p, completionHandler: nil)
            if p {
                // Show a still image and hide the web view: WebKit then stops
                // animations and JavaScript timers – practically no CPU/GPU load anymore.
                webView.takeSnapshot(with: nil) { [weak self] img, _ in
                    guard let self, self.paused else { return }
                    still.image = img
                    still.isHidden = false
                    webView.isHidden = true
                }
            } else {
                webView.isHidden = false
                still.isHidden = true
                still.image = nil
            }
        }
    }

    // MARK: Web wallpapers (sandboxed)

    private func makeWebView(file: URL, blockRules: WKContentRuleList?, proxyPort: UInt16?, fps: Int) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Don't store anything permanently (no cookies/tracking data).
        cfg.websiteDataStore = .nonPersistent()
        // With internet access: all connections through the filtering proxy (rejects home network IPs).
        if let proxyPort, let p = NWEndpoint.Port(rawValue: proxyPort) {
            cfg.websiteDataStore.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: p))]
        }
        // Local files only inside the wallpaper's own folder (see loadFileURL below).
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        // WebRTC and camera/microphone interfaces off: WebRTC (STUN/TURN) bypasses the block list
        // and could otherwise send data out despite "no internet".
        for key in ["peerConnectionEnabled", "mediaDevicesEnabled"] {
            let setter = Selector("_set" + key.prefix(1).uppercased() + key.dropFirst() + ":")
            if cfg.preferences.responds(to: setter) { cfg.preferences.setValue(false, forKey: key) }
        }
        if let blockRules { cfg.userContentController.add(blockRules) }

        // Compatibility layer for Workshop web wallpapers.
        let shim = """
        window.wallpaperRegisterAudioListener = window.wallpaperRegisterAudioListener || function(){};
        window.wallpaperRegisterMediaStatusListener = window.wallpaperRegisterMediaStatusListener || function(){};
        window.wallpaperRequestRandomFileForProperty = window.wallpaperRequestRandomFileForProperty || function(){};
        window.addEventListener('load', function(){ setTimeout(function(){
          try { var l = window.wallpaperPropertyListener;
                if (l && l.applyGeneralProperties) l.applyGeneralProperties({fps: \(fps)});
                if (l && l.setPaused) l.setPaused(false);
          } catch(e) {}
        }, 30); });
        """
        cfg.userContentController.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if item.kind == .web {
            let props = Self.propertyScript(item: item, settings: settings)
            cfg.userContentController.addUserScript(WKUserScript(
                source: "window.addEventListener('load', function(){ setTimeout(function(){ \(props) }, 60); });",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = self
        wv.uiDelegate = self

        if item.kind == .web {
            wv.loadFileURL(file, allowingReadAccessTo: item.folder)
        } else {
            // Formats AVFoundation can't play (e.g. WebM): our own static player page.
            let src = file.absoluteString
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            // Content Security Policy: no script at all may run on this page.
            let html = """
            <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src file:; style-src 'unsafe-inline'"></head>
            <body style="margin:0;background:#000;overflow:hidden">
            <video src="\(src)" autoplay loop muted playsinline
              style="position:fixed;inset:0;width:100vw;height:100vh;object-fit:\(settings.scaling.cssFit)"></video>
            </body></html>
            """
            // Put the player page next to the video if possible – then read access to this folder is enough.
            let folder = file.deletingLastPathComponent()
            let local = folder.appendingPathComponent(".livebloom-player.html")
            // Clean up the player page with the app's earlier name.
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(".macscape-player.html"))
            if folder.path.hasPrefix(AppPaths.libraryDir.path), (try? html.write(to: local, atomically: true, encoding: .utf8)) != nil {
                wv.loadFileURL(local, allowingReadAccessTo: folder)
            } else {
                // Videos from custom folders: static page without scripts (see CSP above).
                let htmlURL = AppPaths.support.appendingPathComponent("video-player.html")
                try? html.write(to: htmlURL, atomically: true, encoding: .utf8)
                // Read access only to the smallest common folder of the player page and the video, not to "/".
                wv.loadFileURL(htmlURL, allowingReadAccessTo: Self.commonAncestor(htmlURL, file))
            }
        }
        return wv
    }

    /// Smallest common folder of two files (for tightly limited read access).
    static func commonAncestor(_ a: URL, _ b: URL) -> URL {
        let pa = a.standardizedFileURL.deletingLastPathComponent().pathComponents
        let pb = b.standardizedFileURL.deletingLastPathComponent().pathComponents
        var prefix: [String] = []
        for (x, y) in zip(pa, pb) {
            guard x == y else { break }
            prefix.append(x)
        }
        return URL(fileURLWithPath: NSString.path(withComponents: prefix.isEmpty ? ["/"] : prefix), isDirectory: true)
    }

    /// Applies default and changed properties through the Wallpaper Engine interface.
    static func propertyScript(item: WallpaperItem, settings: ItemSettings) -> String {
        guard let json = item.propertiesJSON, let data = json.data(using: .utf8),
              var props = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        for (name, raw) in settings.properties {
            guard var p = props[name] as? [String: Any],
                  let v = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed) else { continue }
            p["value"] = v
            props[name] = p
        }
        // Invalid numbers (inf/NaN) would throw an uncatchable exception when serialized.
        guard JSONSerialization.isValidJSONObject(props),
              let out = try? JSONSerialization.data(withJSONObject: props), let s = String(data: out, encoding: .utf8) else { return "" }
        return "try { var l = window.wallpaperPropertyListener; if (l && l.applyUserProperties) l.applyUserProperties(\(s)); } catch(e) {}"
    }

    // Only load content from the wallpaper's own folder; wallpapers must not navigate away.
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            let url = action.request.url
            let scheme = url?.scheme?.lowercased() ?? ""
            if scheme == "about" || scheme == "data" || scheme == "blob" { decisionHandler(.allow); return }
            if let url, url.isFileURL {
                // Only files in the wallpaper's own folder (with "/" so that e.g. "…/123" doesn't unlock "…/1234")
                // and our own video player page – not the rest of Application Support
                // (which also holds the steamcmd sign-in data).
                let p = url.standardizedFileURL.resolvingSymlinksInPath().path
                let base = item.folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
                let player = AppPaths.support.appendingPathComponent("video-player.html").standardizedFileURL.resolvingSymlinksInPath().path
                let ok = p.hasPrefix(base) || (item.kind != .web && p == player)
                decisionHandler(ok ? .allow : .cancel)
                return
            }
            // Web pages at most in embedded frames (and only if allowed).
            let isSubframe = action.targetFrame.map { !$0.isMainFrame } ?? false
            decisionHandler(isSubframe && (scheme == "https" || scheme == "http") ? .allow : .cancel)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            // Wait briefly so the wallpaper has drawn its first frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.markReady() }
        }
    }

    // No new windows, no camera/microphone.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    nonisolated func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                             initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                             decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        MainActor.assumeIsolated { decisionHandler(.deny) }
    }
}

/// NSView whose layer is an AVPlayerLayer.
final class PlayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    var layerRef: AVPlayerLayer { playerLayer }
    var gravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
        // Mark as opaque: macOS doesn't have to let anything underneath show through when compositing
        // the screen (saves work in the window server on every video frame).
        playerLayer.isOpaque = true
        layer = playerLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// Detects on which displays other apps are running fullscreen. A fullscreen window is
/// a normal window (layer 0) that exactly fills a display including the menu bar area –
/// maximized windows leave the menu bar free and therefore don't count.
enum FullscreenDetector {
    @MainActor
    static func coveredScreenIDs() -> Set<String> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let rects: [CGRect] = list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        }
        var covered = Set<String>()
        for screen in NSScreen.screens {
            // NSScreen uses a bottom-left origin, CGWindow a top-left origin.
            let f = screen.frame
            let cg = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
            if rects.contains(where: { abs($0.minX - cg.minX) < 1 && abs($0.minY - cg.minY) < 1
                && abs($0.width - cg.width) < 1 && abs($0.height - cg.height) < 1 }) {
                covered.insert(screen.stableID)
            }
        }
        return covered
    }
}
