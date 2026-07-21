<div align="center">

<img src="docs/images/app-icon.png" width="120" alt="Lyrimuse icon">

# Lyrimuse

**Real-time, word-synced lyrics for Apple Music, right on your Mac desktop.**

**Language / 语言:** **English** | [简体中文](README.zh-CN.md)

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![No Apple Developer account needed](https://img.shields.io/badge/Apple%20Developer%20account-not%20required-success)

</div>

Lyrimuse sits quietly in your menu bar and shows a floating lyrics window that follows whatever's playing in Apple Music — word by word, in sync, always on top, across every Space. Think of the "desktop lyrics" experience from NetEase Cloud Music or QQ Music, but native to macOS.

<div align="center">

<img src="docs/images/app-desktop-lyrics.png" width="420" alt="Classic desktop lyrics overlay"><br>
<sub>Classic floating overlay</sub>

<img src="docs/images/app-dynamic-island.png" width="420" alt="Dynamic-Island-style lyrics"><br>
<sub>Dynamic-Island-style capsule (no physical notch required)</sub>

</div>

## Features

### Lyrics that just work
- **Word-by-word synced highlighting**, following playback in real time
- **Four lyrics sources checked automatically** — NetEase Cloud Music, QQ Music, Kugou, and LRCLIB — always picks the best match, no manual searching required
- **Romanization and translation**, shown alongside the original lyrics
- **A full Lyrics Manager window** — browse, hand-edit, delete, or re-search lyrics for any track, with per-track timing offset if the sync ever drifts
- **Works fully offline** in local mode — no network round-trip needed to show lyrics that are already cached

### Show it your way
- **Two floating styles**: a classic desktop overlay, or a Dynamic-Island-style capsule docked at the top of the screen — turn on either, both, or neither
- **Menu bar text mode** — read the current line directly from the status bar instead of a floating window
- **Playback controls** (play/pause, next, previous) built right into the overlay
- **Fully customizable look**: font (or follow the system), size, text/background/shadow colors with savable custom themes, overlay width, position lock
- **Hide during screenshots, recordings, or screen shares** — stays visible to you, invisible to everyone else
- **Auto-hide when paused** so it never sits on your desktop doing nothing

### Just a good Mac citizen
- **Simplified Chinese and English UI**, switches instantly, no restart needed
- **Global keyboard shortcuts** for every action, all left unbound by default so you decide
- **Menu-bar only by design** — doesn't clutter your Dock (optionally toggle Dock visibility if you want it there)

### Optional extras
Everything below is opt-in and off by default — turn on only what you want, right from Settings:

- **Scrobble to [ListenBrainz](https://listenbrainz.org)** and/or **Last.fm** (one click to connect your Last.fm account, no manual token juggling)
- **Bridge your iPhone's plays** (via Last.fm) into the same listening history as your Mac
- **A shareable public "now playing" page** — live playback, history, a guestbook, reactions, a visitor counter, a Top-10-artists leaderboard, a vinyl-record visual, light/dark themes, and rich link previews when shared in chat apps. See the **[Web Features Guide](https://github.com/Yudaotor/nowplaying-workers#readme)** for a full walkthrough with screenshots.
- **A weekly listening digest**, delivered as a push notification (Bark, DingTalk, WeCom, Discord, Feishu, or ServerChan)

Every extra above lives under Settings → **Add-on Features**, and each account card has its own step-by-step setup guide built right in — where to grab an API key or token, how to connect an account, how to get a webhook URL for whichever push platform you pick. The one exception is the web page, which needs its own Cloudflare Worker deployed first — that's why it gets a dedicated guide instead of an in-app popover.

## Getting Started

Lyrimuse ships ad-hoc signed — same as it's always been — so there's no Apple Developer account involved either way you get it. That also means Gatekeeper will flag it as "from an unidentified developer" the first time you open it, regardless of which option below you pick. That's expected, not a bug — see the one-time fix under Option A.

### Option A: Download a pre-built release

1. Grab the latest `Lyrimuse-*-macos.zip` from the [Releases page](https://github.com/Yudaotor/lyrimuse/releases) (a matching `.sha256` file is attached too, if you want to verify the download), unzip it, and drag `Lyrimuse.app` into `/Applications`.
2. On first launch, macOS will refuse to open it — "Lyrimuse can't be opened because Apple cannot check it for malicious software" or "is from an unidentified developer." Clear it once, with whichever of these you're more comfortable with:

   - **Recommended — Terminal (always works):**
     ```bash
     xattr -dr com.apple.quarantine /Applications/Lyrimuse.app
     ```
     Then open the app normally. You only need to do this once per download.
   - **Right-click → Open:** In Finder, right-click (or Control-click) `Lyrimuse.app` and choose **Open**, then confirm **Open** again in the dialog. Doesn't work on every macOS version for every kind of warning — fall back to the Terminal command above if it doesn't clear.
   - **System Settings → Privacy & Security:** Try opening the app once (it'll be blocked), then open **System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway** next to the Lyrimuse warning. Confirm once more if prompted.

   Only run these against a build you actually trust — the one from this repo's own Releases page, or one you built yourself.

### Option B: Build from source

**One-time prerequisites** (skip anything you already have):

```bash
xcode-select --install   # Xcode Command Line Tools, for Swift — skip if `swift --version` already works
brew install go          # any Go ≥ 1.21 — build.sh switches to 1.24.4 automatically via GOTOOLCHAIN
```

Then `build.sh` builds both the app and its background collector in one shot:

```bash
git clone git@github.com:Yudaotor/lyrimuse.git
cd lyrimuse/lyrimuse
./build.sh
```

### After either option

Open Lyrimuse from `/Applications` — the first-run wizard walks you through the two things it actually needs: Automation access to Music.app (so it can read what's currently playing) and enabling its background collector service (so lyrics/artwork keep resolving even when the window's closed). Complete both and lyrics will appear right away (see [lyrimuse/README.md](lyrimuse/README.md) for more build options).

You don't need to configure anything else to get lyrics — every optional extra above is configured later, entirely from Settings.

## Also in This Repo

- [`lyrimuse/`](lyrimuse) — the app itself (Swift, SwiftUI + AppKit)
- [`lyrimuse-collector/`](lyrimuse-collector) — the background engine that resolves lyrics/artwork and feeds them to the app (Go)
- [`Yudaotor/nowplaying-workers`](https://github.com/Yudaotor/nowplaying-workers) — a separate repo with the optional Cloudflare Workers behind the web features above (`state-worker`, `badge-worker`, plus an unrelated personal Feishu-signature `worker`), and its own from-scratch setup guide with real screenshots

## Credits

Design and technical inspiration for the Dynamic-Island-style lyrics window came from [boring.notch](https://github.com/TheBoredTeam/boring.notch), [NotchDrop](https://github.com/Lakr233/NotchDrop), and [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit). The desktop-lyrics concept itself owes a debt to [LyricsX](https://github.com/ddddxxx/LyricsX).
