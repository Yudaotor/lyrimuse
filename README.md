<div align="center">

<img src="docs/images/app-icon.png" width="120" alt="Lyrimuse icon">

# Lyrimuse

**Real-time, word-synced lyrics for Apple Music, QQ Music, NetEase Cloud Music, or Spotify — right on your Mac desktop.**

**Language / 语言:** **English** | [简体中文](README.zh-CN.md)

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon%20%2B%20Intel-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![No Apple Developer account needed](https://img.shields.io/badge/Apple%20Developer%20account-not%20required-success)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

</div>

Lyrimuse sits quietly in your menu bar and shows a floating lyrics window that follows whatever's playing — Apple Music, QQ Music, NetEase Cloud Music, or Spotify, your choice (or just let it auto-detect) — word by word, in sync, always on top, across every Space. Think of the "desktop lyrics" experience from NetEase Cloud Music, but native to macOS.

<div align="center">

<img src="docs/images/app-desktop-lyrics.png" width="420" alt="Classic desktop lyrics overlay"><br>
<sub>Classic floating overlay</sub>

<img src="docs/images/app-dynamic-island.png" width="420" alt="Dynamic-Island-style lyrics"><br>
<sub>Dynamic-Island-style capsule (no physical notch required)</sub>

</div>

## Features

### Lyrics that just work
- **Word-by-word synced highlighting**, following playback in real time
- **Five lyrics sources checked automatically** — NetEase Cloud Music, QQ Music, Kugou, Musixmatch, and LRCLIB — always picks the best match, no manual searching required
- **Romanization and translation**, shown alongside the original lyrics — translation language is configurable when the Musixmatch source has a community translation available
- **A full Lyrics Manager window** — browse, hand-edit, delete, or re-search lyrics for any track, with per-track timing offset if the sync ever drifts
- **Works fully offline** in local mode — no network round-trip needed to show lyrics that are already cached

### Show it your way
- **Choose your player, or let it auto-detect**: reads what's playing from Apple Music (via Automation access), or QQ Music / NetEase Cloud Music / Spotify (via macOS's system-level MediaRemote — no permission needed); pick once during onboarding, switch anytime in Settings, or leave it on auto-detect to follow whichever app macOS currently considers "Now Playing"
- **Three ways to display it**: a classic desktop overlay, a Dynamic-Island-style capsule docked at the top of the screen (optionally with a blurred-cover-art background), or a proper resizable Lyrics Window with the full lyric sheet and auto-scroll — turn on any combination, or none
- **Menu bar text mode** — read the current line directly from the status bar instead of a floating window
- **Playback controls** (play/pause, next, previous) built right into the overlay, working with whichever player you've selected
- **Click-through by default, drag with a long-press** — the classic overlay never blocks clicks meant for whatever's behind it; press and hold it to reposition it, or lock its position entirely from the menu bar
- **Fully customizable look**: font (or follow the system), size, text/background/shadow colors with savable custom themes, overlay width
- **Hide during screenshots, recordings, or screen shares** — stays visible to you, invisible to everyone else
- **Auto-hide when paused** so it never sits on your desktop doing nothing

### Just a good Mac citizen
- **Simplified Chinese and English UI**, switches instantly, no restart needed
- **Global keyboard shortcuts** for every action, all left unbound by default so you decide
- **Menu-bar only by design** — doesn't clutter your Dock (optionally toggle Dock visibility if you want it there)
- **Checks for updates on its own** (or on demand from the menu bar) — no need to keep revisiting the Releases page
- **Scrobble to Last.fm**, connected in one click right from the main Accounts section — no manual token juggling
- **Optional companion launch** with your chosen player, in either direction — launch one when the other opens
- **Export or import your whole configuration** to move to a new Mac, plus a one-click diagnostics export for troubleshooting

### Optional extras
Everything below is opt-in and off by default — turn on only what you want, right from Settings:

- **Also scrobble to [ListenBrainz](https://listenbrainz.org)** — connect it alongside Last.fm and every play is submitted to both from the exact same real-time read of your player, so the two histories never drift apart; your iPhone's plays (recorded via Last.fm) get automatically bridged into ListenBrainz too, for one unified history across both devices instead of two separate ones
- **A shareable public "now playing" page** — live playback, history, a guestbook, reactions, a visitor counter, a Top-10-artists leaderboard, a vinyl-record visual, light/dark themes, and rich link previews when shared in chat apps. See the **[Web Features Guide](https://github.com/Yudaotor/nowplaying-workers#readme)** for a full walkthrough with screenshots.
- **A weekly listening digest**, delivered as a push notification (Bark, DingTalk, WeCom, Discord, Feishu, or ServerChan)

Every extra above lives under Settings → **Add-on Features**, and each account card has its own step-by-step setup guide built right in — where to grab an API key or token, how to connect an account, how to get a webhook URL for whichever push platform you pick. The web page is the one that gets a dedicated guide instead of an in-app popover, but it's not a hard requirement either: configuring ListenBrainz alone already lets the page show live playback and history, no Cloudflare Worker needed. Deploying one on top adds the guestbook, reactions, visitor counter, Top-10-artists leaderboard, and lower-latency updates — see the guide if you want those.

## Getting Started

Lyrimuse ships ad-hoc signed — same as it's always been — so there's no Apple Developer account involved with any option below. That also means Gatekeeper will flag it as "from an unidentified developer" the first time it's opened, downloaded any way except Option A below (which clears it automatically) — that's expected, not a bug, and Option B covers the one-time manual fix.

### Option A: Install via Homebrew (recommended)

```bash
brew tap yudaotor/lyrimuse
brew trust --cask yudaotor/lyrimuse/lyrimuse   # one-time -- Homebrew requires this for any non-official tap
brew install --cask lyrimuse
```

This clears the one-time Gatekeeper quarantine automatically as part of installing, so there's no follow-up step — open Lyrimuse from `/Applications` (or Spotlight) right after `brew install` finishes. `brew upgrade --cask lyrimuse` picks up new releases the same way.

### Option B: Download a pre-built release manually

1. Grab it from the [Releases page](https://github.com/Yudaotor/lyrimuse/releases). **Check which Mac you have first** ( → About This Mac → "Chip": `Apple M…` is Apple Silicon, `Intel Core…` is Intel):

   | Your Mac | Download |
   | --- | --- |
   | Apple Silicon (M1 and later) | `Lyrimuse-*-macos.dmg` or `.zip` |
   | Intel | `Lyrimuse-*-macos-intel.dmg` or `.zip` |

   With the dmg, double-click to mount and drag `Lyrimuse.app` onto the `Applications` shortcut next to it; with the zip, unzip and drag `Lyrimuse.app` into `/Applications`. Both formats install exactly the same app, and the zip comes with a `.sha256` if you want to verify the download (`shasum -c Lyrimuse-*.zip.sha256` from the same folder).

   The only difference between the two downloads is architecture: the one without a suffix is Apple Silicon only, while `-intel` carries both Intel and Apple Silicon code. `-intel` does run on Apple Silicon, but there is no reason to use it there — it is twice the size, and macOS 27 and later will warn that the app "needs to be updated" because it contains Intel code (Apple is removing Rosetta in macOS 28; nothing is actually wrong with the app).

   The in-app updater serves the Apple Silicon build only. Intel users are never offered an update — Sparkle correctly skips it and reports "you're up to date" rather than pushing a build that would not open — so check back here for a newer `-intel` download.
2. On first launch, macOS will refuse to open it — "Lyrimuse can't be opened because Apple cannot check it for malicious software" or "is from an unidentified developer." Clear it once, with whichever of these you're more comfortable with:

   - **Recommended — Terminal (always works):**
     ```bash
     xattr -dr com.apple.quarantine /Applications/Lyrimuse.app
     ```
     Then open the app normally. You only need to do this once per download.
   - **Right-click → Open:** In Finder, right-click (or Control-click) `Lyrimuse.app` and choose **Open**, then confirm **Open** again in the dialog. Doesn't work on every macOS version for every kind of warning — fall back to the Terminal command above if it doesn't clear.
   - **System Settings → Privacy & Security:** Try opening the app once (it'll be blocked), then open **System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway** next to the Lyrimuse warning. Confirm once more if prompted.

   Only run these against a build you actually trust — the one from this repo's own Releases page, or one you built yourself.

### Option C: Build from source

**One-time prerequisites** (skip anything you already have):

```bash
xcode-select --install   # Xcode Command Line Tools, for Swift — skip if `swift --version` already works
brew install go          # any Go ≥ 1.21 — build.sh switches to 1.24.4 automatically via GOTOOLCHAIN
```

Then `build.sh` builds both the app and its background collector in one shot:

```bash
git clone https://github.com/Yudaotor/lyrimuse.git
cd lyrimuse/lyrimuse
./build.sh              # this machine's architecture
./build.sh --universal  # arm64 + x86_64 (the compatibility build shipped for Intel)
```

`build.sh` ends by listing the architectures of every binary in the bundle and flags anything that does not match the target — a missing slice or an extra one. Don't assemble release assets by hand: `./package.sh` builds each architecture once and produces a zip + sha256 + dmg for each, refusing to package if the architectures are wrong.

QQ Music / NetEase Cloud Music / Spotify / auto-detect support additionally needs [ungive/media-control](https://github.com/ungive/media-control) — `build.sh` installs it via Homebrew automatically if it's missing, so this isn't a step you need to do yourself either.

### After any option

Open Lyrimuse from `/Applications` — the first-run wizard walks you through picking a player (Apple Music, QQ Music, NetEase Cloud Music, Spotify, or auto-detect), granting Automation access to Music.app if you picked Apple Music (the others need no extra permission), and enabling its background collector service (so lyrics/artwork keep resolving even when the window's closed). Complete the wizard and lyrics will appear right away (see [lyrimuse/README.md](lyrimuse/README.md) for more build options).

You don't need to configure anything else to get lyrics — every optional extra above is configured later, entirely from Settings.

## Project Layout

This repo is the app:

- [`lyrimuse/`](lyrimuse) — the app itself (Swift, SwiftUI + AppKit)
- [`lyrimuse-collector/`](lyrimuse-collector) — the background engine that resolves lyrics/artwork and feeds them to the app (Go); built and bundled into the app automatically

The optional web experience lives in two sibling repos, so you can fork either without touching the app:

| Repo | Role |
|---|---|
| [`Yudaotor/nowplaying`](https://github.com/Yudaotor/nowplaying) | The shareable "now playing" web page itself, plus a fork-ready template |
| [`Yudaotor/nowplaying-workers`](https://github.com/Yudaotor/nowplaying-workers) | The Cloudflare Worker relay + live README badge behind it, with a complete from-scratch setup guide |

```
this repo (app + collector)  ──push──▶  nowplaying-workers (relay)  ◀──read──  nowplaying (web page)
```

## Credits

Design and technical inspiration for the Dynamic-Island-style lyrics window came from [boring.notch](https://github.com/TheBoredTeam/boring.notch), [NotchDrop](https://github.com/Lakr233/NotchDrop), and [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit). The desktop-lyrics concept itself owes a debt to [LyricsX](https://github.com/ddddxxx/LyricsX).
