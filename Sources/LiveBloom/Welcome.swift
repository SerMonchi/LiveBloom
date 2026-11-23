import SwiftUI

/// Welcome screen on first launch – briefly explains the setup and asks about launch at login.
struct WelcomeView: View {
    var goToSettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var launchAtLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Willkommen bei LiveBloom").font(.title2.weight(.semibold))
                    Text("Live-Wallpaper aus dem Wallpaper-Engine-Workshop für deinen Mac.").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Steam-Web-API-Schlüssel eintragen",
                     "Damit kannst du den Workshop durchsuchen und deine Abos sehen. Den Schlüssel gibt es kostenlos unter steamcommunity.com/dev/apikey.")
                step(2, "Bei Steam anmelden",
                     "Zum Herunterladen brauchst du ein Steam-Konto, das Wallpaper Engine besitzt. Dein Passwort geht nur an Valve und wird nicht gespeichert.")
                step(3, "Oder: vom Windows-PC importieren",
                     "Ohne Anmeldung – den Workshop-Ordner vom PC kopieren und in den Einstellungen importieren.")
            }
            Divider()
            Toggle("LiveBloom beim Anmelden am Mac starten", isOn: $launchAtLogin)
            Text("LiveBloom läuft dann still in der Menüleiste und pausiert automatisch, wenn eine App im Vollbild ist.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Später") { finish() }
                Spacer()
                Button("Jetzt einrichten") { finish(); goToSettings() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func step(_ n: Int, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func finish() {
        try? LoginItem.set(launchAtLogin)
        UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        onboardingDone = true
        dismiss()
    }
}
