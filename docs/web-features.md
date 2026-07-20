# Web Features: Turn "What's Playing" Into a Page You Can Share

**Language / 语言：** **English** | [简体中文](web-features.zh-CN.md)

This document covers one thing: **the public now-playing web page that collector unlocks as a bonus** — what it actually looks like, how data flows, and how to stand up your own copy from scratch.

It's completely independent of, and optional alongside, the Lyrimuse floating lyrics app itself: skip this entirely and the floating lyrics keep showing word-synced lyrics exactly the same, unaffected. The point of this piece is — since collector is already running and capturing "now playing" state anyway, you get a shareable, permanent link almost for free. Drop it into a Feishu signature, a Twitter/X bio, or just keep it around as your own "now playing" homepage.

## What It Looks Like

### Desktop (≥820px lays out as two columns)

Light ambient theme, paused:

![Light theme, paused, two-column layout](images/web-preview-light.png)

Dark ambient theme + vinyl mode (the tonearm lifts when paused and spins at a steady rate while playing — this screenshot happens to catch the paused moment):

![Dark theme + vinyl mode, paused](images/web-preview-vinyl-dark.png)

Both of these are the actual live page the author runs (<https://yudaotor.github.io/nowplaying/?user=yudaotor>) — not staged sample data.

### What Each Module Actually Does

- **Now-playing card**: cover art (with a gentle breathing zoom), title/artist/album, a progress bar (extrapolated in real time client-side, not polled every second), a playback-state pill ("Now Playing" / "Paused" / "Last played · N minutes ago"), and a device icon (Mac / iPhone line icons). If the cover art isn't available yet, the client falls back to an iTunes Search placeholder and swaps in the real cover seamlessly once the server resolves it.
- **Vinyl mode** (💿 top right): shrinks the cover art down to the "label" at the center of a vinyl record, spinning at a steady rate while playing and lifting the tonearm when paused — pure CSS + the Web Animations API, no extra battery cost. It's a toggle against "square cover" mode, remembered per browser via local storage, and doesn't affect what other visitors see.
- **Synced lyrics**: only shown when something is actually playing with a precise progress position (plays mirrored from iPhone via the Last.fm bridge carry no progress data, so only the title shows in that case, no lyrics). Supports both word-by-word highlighting (NetEase's yrc format) and whole-line highlighting, with romanization/translation each on their own line. Manually scrolling the lyrics panel pauses auto-follow; it resumes tracking the current line automatically a few seconds after you stop touching it.
- **Recent playback history**: split into "today" and "earlier," each row tagged with a Mac/iPhone device icon plus a play count for the last 30 days (only shown once it's ≥2, so the list isn't cluttered with uninformative "×1" badges). Today's stats get their own summary line, "Today · N songs · about X hr Y min."
- **Guestbook**: leave a message anonymously (or with a nickname), shared site-wide, capped at the latest 50 entries. Rendered purely via `textContent`, which naturally rules out XSS.
- **Reactions**: a single ❤️ button with a site-wide cumulative like count (not tied to any particular song).
- **Visitor counter**: counted once per browser (deduplicated via `localStorage`) — clearing your cache, switching browsers, or using a private/incognito window will count as a new visit.
- **Top 10 artists (all-time)**: a standing leaderboard ranked by total play count across all history, recomputed once a day (not real-time). The top three get rank badges; avatars come from Deezer, falling back to a circular initial placeholder when unavailable.
- **Theme / immersive mode**: 🌗 (top right) toggles between "ambient" (a blurred version of the cover art as the background) and "light"; ⛶ enters an immersive/fullscreen mode that hides secondary information and enlarges the cover art and lyrics — a good fit for leaving it running on a tablet or a second monitor.
- **Social sharing**: when the link is pasted into WeChat, Slack, Discord, and similar chat tools, it automatically unfurls into a preview card showing the currently-playing title + cover art (without anyone needing to actually click through).

## How Data Flows

```
Mac collector (already running)
  └─ POST /push (on every track change / pause / periodic heartbeat) ──> your own state-worker (Cloudflare Worker + KV)
                                                                                │
                                                                                ├─ GET /now, /history, /top-artists, and other read-only endpoints
                                                                                │        ↓
                                                                                └──> your own deployed web page (web/index.html)
```

- collector has no idea whether the web page or the Worker even exist — it just unconditionally pushes state to whatever address is configured. If state-worker is down or was never deployed, collector carries on exactly as before; the local floating lyrics are unaffected.
- The web page prefers reading from your own state-worker; if state-worker itself is unreachable (or you simply never deployed one), the page automatically falls back to reading straight from ListenBrainz — in that mode you still get "now playing" and history, but the guestbook, reactions, visitor counter, and top-10-artists modules (all of which need to write to KV) won't appear, since they have no ListenBrainz fallback path.
- collector only needs one piece of configuration: `state_relay_url` + `state_relay_token` (matching the "Sync Server URL" + "Access Token" fields on the "Web Push" card in Lyrimuse's Settings). **Fill in both and the whole chain above starts running automatically — there's no separate switch to flip in Settings.** That's the behavior as of 2026-07-20; an earlier version of Settings had an extra "Push status to web widget/badge" toggle here, which has since been removed.

## Building Your Own From Scratch

### Prerequisite

You already have collector running per the main [README](../README.md#toc-collector) (even just a basic `-dry-run` trial run is enough). You don't need ListenBrainz configured to continue — the web page can run entirely on state-worker's own KV storage without depending on ListenBrainz (with one exception: "recent playback history" is only available via ListenBrainz, since state-worker doesn't keep its own history store — see "What This Can't Do" below).

### Step 1: Deploy your own state-worker

The full version of this step (Cloudflare account, KV namespace, custom domain, two secrets) is already written up in the main README — it isn't duplicated here a second time, to avoid the two copies drifting apart over time. Follow it there: [README, "Building state-worker From Scratch"](../README.md#L197-L220) (this section of the README is in Chinese; the GitHub web view link uses a line-number anchor rather than a heading anchor, since it doesn't depend on GitHub's slug-generation rules for headings with Chinese text/parentheses — if that section ever moves, these line numbers need updating to match).

By the end of this step, you'll have:
- A reachable state-worker address (a custom domain or a `*.workers.dev` subdomain)
- A `PUSH_TOKEN` you generated yourself (used to authenticate collector)

### Step 2: Deploy your own web page

```bash
git clone git@github.com:Yudaotor/nowplaying.git web-page
# Host it on any static site (GitHub Pages / Cloudflare Pages both work). Visit it at:
# https://<your-domain>/index.html?user=<your ListenBrainz username>
```

The web page's `RELAY` constant defaults to the author's own `https://np.yudaotor.me` — before deploying your own copy, change this line in `web/index.html` to your own state-worker's address:

```js
const RELAY = (() => { const r = params.get('relay'); if (r === 'off') return ''; return r || 'https://np.yudaotor.me'; })();
```

You don't have to edit the source at all, either — pass `?relay=your-address` on the URL to override it at visit time (for example, `?user=xxx&relay=https://your-worker.workers.dev` when sharing a link). If you want to skip state-worker entirely and rely purely on the ListenBrainz fallback, pass `?relay=off`.

### Step 3: Connect Lyrimuse to state-worker

Open Lyrimuse's menu bar "Settings…" → sidebar "Add-on Features" → "Web Push," and fill in two fields:

- **Sync Server URL**: the state-worker address from step 1
- **Access Token**: the exact same string as the `PUSH_TOKEN` from step 1

That's it — there's no separate switch to go find and turn on. The next time collector restarts (which happens automatically after saving settings), it starts pushing state to this address.

### Step 4: Verify it

1. Visit your own web page address directly and check whether you can see "now playing" or "last played" (rather than getting stuck on "connecting…").
2. Switch tracks, wait a few seconds, and refresh — confirm the title/cover art actually changed. That confirms the collector → state-worker → web page chain is genuinely connected, rather than the page silently reading the ListenBrainz fallback (in fallback mode, there's usually a much longer delay between switching tracks on your Mac and seeing it reflected on the page, and modules like the guestbook won't show up at all).
3. Try leaving a message or clicking the like button on the page, then refresh and confirm it's still there.

## What This Can't Do / Current Limitations

- **The five optional display modules (history / guestbook / reactions / visitor counter / top-10-artists) don't have per-module toggles anymore**: as soon as "Web Push"'s address + token are configured, all five appear together; leave them blank and none of the five appear. (An earlier version had 5 independent toggles for these; they were removed starting 2026-07-20, on the reasoning that "Web Push is an add-on feature to begin with — once it's configured it should push everything, without needing per-item configuration.") If you genuinely only want some of these modules, the only way to do that right now is to edit `web/index.html` yourself and delete the DOM/initialization code for the ones you don't want.
- **The "recent playback history" module is only available through ListenBrainz**: state-worker doesn't maintain its own history store (its KV only holds "current state" and the handful of visitor-interaction modules), so even if you want nothing to do with ListenBrainz and only use state-worker to push "now playing," the history list on the web page still comes from falling back to ListenBrainz directly.
- **Connecting to ListenBrainz directly from within China can be unreliable.** That's the whole reason state-worker (a "China-accelerated relay") exists in the first place — you don't have to deploy it, but without it the page may occasionally spin/stall when accessed from within China.
- **`web/index.html` and `state-worker/src/index.js` each maintain their own, nearly-identical copy of the "parse raw ListenBrainz data" logic** (`fromLB`/`lbHistory`), and both have comments pointing at the other file. This is because they're deployed on two unrelated platforms — GitHub Pages and Cloudflare Workers — with no shared build step that would let them actually share source code. If you need to change this parsing logic, you have to change it in both places, or the two will silently drift out of sync.

## Troubleshooting

**The page is stuck on "Connecting… will retry automatically"** — Check whether the URL has the right `?user=` parameter (your ListenBrainz username), and whether your browser can actually reach your state-worker address (or whether ListenBrainz itself is reachable).

**Track changes take forever to show up, and modules like the guestbook / top-10-artists are missing** — This means the page is currently running on the ListenBrainz fallback path, not genuinely connected to your state-worker. Check: whether Lyrimuse Settings' "Web Push" address + token are filled in and saved (saving triggers an automatic collector restart to pick it up); whether the page's URL accidentally has `?relay=off` on it; and try visiting `https://<your-state-worker-address>/now` directly in a browser to confirm it returns normal JSON (not a 401 or 500).

**`/push` keeps returning 401** — `state_relay_token` (the one you entered in Lyrimuse's settings) and state-worker's `PUSH_TOKEN` (the one set via `wrangler secret put`) must be the exact same string. The most common cause is changing one side and forgetting the other.

**Cover art / artist avatars won't load** — Cover art comes from NetEase's image hosting, and top-10-artist avatars come from Deezer; neither has CDN acceleration aimed at China, so they'll occasionally fail to load due to network issues. The page has a fallback for both cases (cover art falls back to a solid-color background, avatars fall back to a circular-initial placeholder), and nothing else on the page is affected.

**I only want the "now playing" display, not the guestbook and other interactive features** — There's currently no way to enable "some but not all" of these — see "What This Can't Do" above. You'd need to edit `web/index.html` yourself and remove the modules you don't want.
