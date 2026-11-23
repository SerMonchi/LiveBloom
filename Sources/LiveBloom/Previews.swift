import SwiftUI
import AppKit
import AVFoundation

/// How previews are animated.
enum PreviewAnimation: String, CaseIterable, Identifiable, LocalizedLabel {
    /// Tiles show a still image; animation only starts after clicking (details / sidebar).
    case click = "Nur beim Anklicken", hover = "Beim Darüberfahren", always = "Immer"
    var id: String { rawValue }
}

/// Cache for preview images (raw data, so GIF animations are preserved).
final class PreviewCache: @unchecked Sendable {
    static let shared = PreviewCache()
    private let cache = NSCache<NSURL, NSData>()
    init() { cache.totalCostLimit = 40 * 1024 * 1024 }

    /// Releases all cached preview data and returns the memory to the system.
    func releaseMemory() {
        cache.removeAllObjects()
        // Wait briefly until the closed tiles have let go of their images.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = malloc_zone_pressure_relief(nil, 0) }
    }

    func data(for url: URL) async -> Data? {
        if let d = cache.object(forKey: url as NSURL) { return d as Data }
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = try? await URLSession.shared.data(from: url).0
        }
        if let data { cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count) }
        return data
    }
}

/// Image (also animated GIF) that fills its area; only animates when `animates` is on.
struct AnimatedPreview: NSViewRepresentable {
    let url: URL?
    let animates: Bool

    func makeNSView(context: Context) -> FillImageView { FillImageView() }
    func updateNSView(_ view: FillImageView, context: Context) {
        view.url = url
        view.animates = animates
    }
    static func dismantleNSView(_ view: FillImageView, coordinator: ()) { view.stopAnimation() }
}

/// Shows a preview image as a layer ("aspect fill", scaled on the GPU). GIFs are played with ImageIO:
/// the frames are decoded in the background and the main thread only sets the
/// finished image – so many previews run smoothly and efficiently at the same time.
final class FillImageView: NSView {
    private let contentLayer = CALayer()
    private var loadTask: Task<Void, Never>?
    private var still: CGImage?
    private var gifData: Data?
    /// Incremented on every start/stop; older animations stop themselves when it changes.
    private var animationToken = 0

    var url: URL? { didSet { if url != oldValue { load() } } }
    var animates = false { didSet { if animates != oldValue { updateAnimation() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        contentLayer.contentsGravity = .resizeAspectFill
        contentLayer.masksToBounds = true
        // No implicit cross-fades on every frame.
        contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(contentLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Pass clicks on to SwiftUI.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        contentLayer.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        contentLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    private var occlusionObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o); occlusionObserver = nil }
        if let window {
            // Covered or minimized window: pause the animation; visible: keep it running.
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            }
            visibilityChanged()
        } else {
            releaseImages()
        }
    }

    /// Window closed or minimized: release images (saves memory).
    /// When it becomes visible again, the tile reloads its image – from the cache if it is still there.
    private var released = false

    private func visibilityChanged() {
        guard let window else { releaseImages(); return }
        // Closed or minimized: release images. Only covered: keep the still image
        // and just pause the animation (otherwise empty tiles flash when switching back).
        if !window.isVisible || window.isMiniaturized {
            releaseImages()
        } else if released {
            released = false
            load()
        } else {
            updateAnimation()
        }
    }

    private func releaseImages() {
        guard !released else { return }
        released = true
        loadTask?.cancel()
        stopAnimation()
        contentLayer.contents = nil
        still = nil
        gifData = nil
    }

    deinit {
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func load() {
        released = false
        loadTask?.cancel()
        stopAnimation()
        contentLayer.contents = nil
        still = nil
        gifData = nil
        isGIFSource = false
        guard let url else { return }
        let scale = window?.backingScaleFactor ?? 2
        let maxPixel = max(bounds.width, bounds.height, 320) * scale * 1.2
        loadTask = Task { [weak self] in
            // Loading and downsampling run in the background; only thread-safe data comes back.
            let result: (CGImage?, Bool, Data)? = await Task.detached(priority: .utility) {
                guard let data = await PreviewCache.shared.data(for: url) else { return nil }
                return (FillImageView.downsampleCG(data, maxPixel: maxPixel), data.starts(with: [0x47, 0x49, 0x46]), data)
            }.value
            guard let self, !Task.isCancelled, self.url == url, let (cg, isGIF, data) = result else { return }
            self.still = cg
            self.isGIFSource = isGIF
            self.gifData = (isGIF && self.animates) ? data : nil
            self.contentLayer.contents = cg
            self.updateAnimation()
        }
    }

    private var isGIFSource = false
    private var gifLoadTask: Task<Void, Never>?

    private func updateAnimation() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let visible = window?.occlusionState.contains(.visible) ?? false
        guard animates, !reduceMotion, visible, isGIFSource else {
            stopAnimation()
            return
        }
        // Fetch the GIF data only now (when clicked/shown) – from the cache or the network.
        guard let data = gifData else {
            guard gifLoadTask == nil, let url else { return }
            gifLoadTask = Task { [weak self] in
                let data = await Task.detached(priority: .userInitiated) { await PreviewCache.shared.data(for: url) }.value
                guard let self else { return }
                self.gifLoadTask = nil
                guard self.url == url, let data else { return }
                self.gifData = data
                self.updateAnimation()
            }
            return
        }
        animationToken += 1
        let token = animationToken
        CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] _, image, stop in
            MainActor.assumeIsolated {
                guard let self, self.animationToken == token else { stop.pointee = true; return }
                self.contentLayer.contents = image
            }
        }
    }

    func stopAnimation() {
        animationToken += 1   // a running animation stops itself on the next frame
        gifLoadTask?.cancel(); gifLoadTask = nil
        gifData = nil         // release the GIF data while not animating
        if still != nil { contentLayer.contents = still }
    }

    nonisolated static func downsampleCG(_ data: Data, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        // Animated previews often start with a black fade-in frame – so for the still image
        // take a frame from the first third (as is also shown in the Workshop).
        let count = CGImageSourceGetCount(src)
        if count > 3, let frame = CGImageSourceCreateThumbnailAtIndex(src, count / 3, options) { return frame }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options)
    }

    nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> NSImage? {
        guard let cg = downsampleCG(data, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Whether the mouse is (briefly) resting on a tile – for video previews that only run then.
private struct TileHoveringKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var tileHovering: Bool {
        get { self[TileHoveringKey.self] }
        set { self[TileHoveringKey.self] = newValue }
    }
}

/// Plays a local video muted in a loop (for the hover preview).
struct HoverVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> HoverVideoView { HoverVideoView(url: url) }
    func updateNSView(_ view: HoverVideoView, context: Context) {}
    static func dismantleNSView(_ view: HoverVideoView, coordinator: ()) { view.stop() }
}

final class HoverVideoView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()

    init(url: URL) {
        super.init(frame: .zero)
        player.isMuted = true
        let item = AVPlayerItem(url: url)
        item.preferredPeakBitRate = 4_000_000
        looper = AVPlayerLooper(player: player, templateItem: item)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer = playerLayer
        wantsLayer = true
        player.play()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func stop() { player.pause(); looper = nil; player.removeAllItems() }
}
