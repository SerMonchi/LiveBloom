import AppKit

/// Translates a text whose key is only known at runtime (e.g. names of choices).
/// Texts written directly in code are literals in SwiftUI or in `String(localized:)` instead.
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// Choice enums whose German raw value is also the translation key.
/// The raw values stay German because they are stored in the user's settings.
protocol LocalizedLabel: RawRepresentable where RawValue == String {}
extension LocalizedLabel {
    var label: String { L(rawValue) }
}

/// App language. "System language" follows macOS; a chosen language applies after a restart.
enum AppLanguage {
    /// Supported languages, each named in its own language.
    static let supported: [(code: String, name: String)] = [
        ("de", "Deutsch"), ("en", "English"), ("es", "Español"), ("fr", "Français"),
        ("it", "Italiano"), ("pt-BR", "Português (Brasil)"), ("pl", "Polski"), ("tr", "Türkçe"),
        ("ru", "Русский"), ("zh-Hans", "简体中文"), ("ja", "日本語"), ("ko", "한국어"),
    ]

    /// Chosen language ("" = system language).
    static var selected: String { UserDefaults.standard.string(forKey: "appLanguage") ?? "" }

    /// The choice the app was launched with – if it differs, a restart is needed.
    static let launchedWith = selected

    /// Language the interface is currently shown in.
    static var current: String { Bundle.main.preferredLocalizations.first ?? "de" }

    static func select(_ code: String) {
        let d = UserDefaults.standard
        guard supported.contains(where: { $0.code == code }) || code.isEmpty else { return }
        d.set(code, forKey: "appLanguage")
        // "AppleLanguages" in the app's own defaults overrides the macOS language for LiveBloom only.
        if code.isEmpty { d.removeObject(forKey: "AppleLanguages") } else { d.set([code], forKey: "AppleLanguages") }
    }

    /// Quits LiveBloom and relaunches it as soon as the old process has really exited.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        do { try p.run() } catch { return }
        NSApp.terminate(nil)
    }
}
