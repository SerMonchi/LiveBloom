<p align="center">
  <img src="Resources/icon-1024.png" width="160" alt="LiveBloom app icon">
</p>

<h1 align="center">LiveBloom</h1>

<p align="center">
  Live wallpapers for macOS from the Wallpaper Engine Steam Workshop.<br><br>
  <a href="https://github.com/SerMonchi/LiveBloom/releases/latest"><b>⬇︎ Download the latest version</b></a>
</p>

> Independent hobby project, not affiliated with Valve, Steam or Wallpaper Engine.
> You need your own copy of [Wallpaper Engine](https://store.steampowered.com/app/431960/).

## Features

- Video and web wallpapers, on one or several displays
- Browse the Workshop with filters, see your Steam subscriptions and favorites
- New subscriptions download automatically
- Pauses when an app is fullscreen, launches at login, lives in the menu bar
- 12 languages

Scene wallpapers only work in Wallpaper Engine on Windows.

## Coming next

- **Create your own wallpapers** – turn your own videos, images and animations into live wallpapers right in LiveBloom.
- **LiveBloom gallery** – a built-in browser where everyone can share their wallpapers and download wallpapers from others.

## Requirements

- macOS 15 or later (Apple silicon or Intel)
- A Steam account that owns Wallpaper Engine
- A free [Steam Web API key](https://steamcommunity.com/dev/apikey)

## Install

1. Download `LiveBloom.dmg` and drag LiveBloom into Applications.
2. Open it once and click **Done** when macOS warns you (the app isn't notarized).
3. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

Then enter your API key and sign in to Steam in LiveBloom's settings.

## Build from source

```bash
xcode-select --install
```

```bash
./build.sh
```

`--install` also installs and launches the app, `--dmg` creates a disk image.

## Privacy

LiveBloom only talks to Steam – no ads, no tracking. The API key is stored in the
Keychain, your Steam password goes straight to Valve's `steamcmd` and is never saved.
Web wallpapers run sandboxed without internet access unless you allow it.

## License

The code is [MIT](LICENSE) licensed. The name "LiveBloom", the logo and the app icon are
not – modified versions need their own name and logo. Workshop content belongs to its
creators.
