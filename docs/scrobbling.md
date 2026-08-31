# How Lyrimuse scrobbles to Last.fm

*[中文版](scrobbling.zh-CN.md)*

## 1. When a play counts

A play is submitted once **all** of these hold:

| Rule | Value |
|---|---|
| Played long enough | half the track, capped at 240s — or 240s if the length is unknown |
| Track is long enough | `≥ 30s` (tracks of unknown length are allowed through) |
| Not an ad | Spotify ad breaks are detected and skipped |

Playback is sampled every 5 seconds and elapsed time accrues from the wall clock, so pausing stops
the count and seeking does not inflate it. If two samples end up more than 60 seconds apart — the
machine slept, or the collector was restarted — that gap is discarded rather than credited.

These thresholds match [Last.fm's scrobbling guidelines](https://www.last.fm/api/scrobbling).

## 2. What gets sent

`track.scrobble` writes the permanent entry in your history; `track.updateNowPlaying` sets the
"listening now" indicator and stores nothing.

| Field | `track.scrobble` | `track.updateNowPlaying` |
|---|---|---|
| `artist` | ✅ | ✅ |
| `track` | ✅ | ✅ |
| `timestamp` | ✅ | — |
| `album` | when non-empty | when non-empty |
| `duration` | when known | when known |

Nothing else reaches Last.fm. Their API also accepts `mbid`, `albumArtist`, `trackNumber`,
`chosenByUser`, `streamId` and `context` on a scrobble; Lyrimuse sends none of them.

## 3. What is not rewritten

Artist, track and album names are submitted exactly as the player reported them.

The only processing applied is invisible-character cleanup: non-breaking and full-width spaces
become ordinary spaces, zero-width characters and BOMs are removed, runs of whitespace collapse to
one, and leading/trailing whitespace is trimmed. Without it, an invisible non-breaking space
creates a separate artist entity on Last.fm.

Nothing visible is changed — not capitalisation, not Traditional vs Simplified Chinese, not
parenthetical subtitles, not multi-artist credits. `PRINCE` stays `PRINCE`, `無所謂` stays
`無所謂`, and `一口 (The Day You Left Me)` keeps its subtitle.

Why there is no external lookup to "canonicalise" names:

- Lyrimuse used to do exactly that. An audit of a real ~2,500-track library found roughly 200
  rewritten artist names, including `USA for Africa` → `Xtc Planet` and `LBI利比` → `Safehse`.
  Scrobbles already written to a public Last.fm artist page cannot be corrected afterwards — the
  correction database is frozen.
- Last.fm's scrobbling guide states, twice: *"Do not use the corrections returned by the now
  playing service as input for the scrobble request, unless they have been explicitly approved by
  the user."* Its `autocorrect` flag is
  [documented as legacy](https://support.last.fm/t/scrobbles-of-japanese-artists-getting-separated-by-romanization-of-their-name/119906).
- Of nine open-source scrobblers surveyed (Web Scrobbler, Pano Scrobbler, Navidrome, Maloja,
  rescrobbled, mpdscribble, mpdas, Koito, multi-scrobbler), none rewrites artist names from an
  external lookup by default.

## 4. Multi-artist credits

| Setting | Default | Effect |
|---|---|---|
| `lastfm_scrobble_first_artist_only` | **off** | On: `Khalil Fong & Fiona Sit` is submitted as `Khalil Fong` |

Set in `~/.config/lyrimuse/lyrimuse-features.json`; there is no toggle for it in Settings.

Off by default because collapsing is irreversible — turning it on removes Fiona Sit from your
history, while leaving it off costs at most one lightly-listened collaboration entry. Navidrome's
option of the same name (`Lastfm.ScrobbleFirstArtistOnly`) also defaults to off.

When on, splitting is conservative: `/` is handled separately from `,` and `&`, so `K/DA` and
`AC/DC` are not split into `K` and `AC`. It is pure string handling — no lookup, no network call —
so the same input always produces the same result.

## 5. If a scrobble fails

Failures are classified, because the correct response differs. "Record it" below means the play is
written to a local log, which a **backfill** — started manually from the "pending listens" row next
to your recent plays — can submit later.

| What happened | What we do |
|---|---|
| Request provably never left your machine (DNS, dial failure) | Record it; backfill can submit it |
| Server refused it for a reason that means it definitely wasn't stored (bad credentials, rate limit) | Record it; backfill can submit it |
| Sent, but the outcome is unknown (timeout, dropped connection, ambiguous server error) | Record it, but backfill will **never** retry it automatically |
| Server received the track and rejected the content itself | Don't record it; surface the server's actual reason |

The third row exists because a timeout may mean Last.fm stored the play and only the receipt was
lost. Retrying would create a duplicate that has to be deleted by hand, so an ambiguous failure is
never retried automatically.

Backfill only reaches back **13 days**. Once a play has been attempted, the real-time path never
sends it again: the play is marked as attempted *before* the request goes out, not after it
succeeds, so a crash mid-request cannot produce a second submission.

## 6. Where merging happens

Last.fm receives what the player reported, so a library that reports the same person as both
`Khalil Fong` and `方大同` will show two artists there.

Inside Lyrimuse, play counts, charts and "Nth listen" numbers merge them — via
Traditional/Simplified folding, romanised-name aliases, catalogue-noise stripping
(`(Remastered 2014)`, `(feat. …)`, `(Explicit)`) and a per-artist alias table. Merging is done
locally rather than before submission because a wrong merge locally is undone by a refresh, while a
wrong scrobble is a permanent edit to a public page.

## 7. Common questions

**Can I use Lyrimuse without scrobbling?**
Yes, that's the default — nothing is scrobbled until you connect a Last.fm account in
Settings → Add-on Features. Resolving lyrics and artwork is separate: it sends the artist and track
name to the public lyrics providers (Netease, QQ, Kugou, LRCLIB, Musixmatch, AMLL) regardless of
whether an account is connected. Those sources can be narrowed or disabled in Settings.

**Why does the same artist appear twice on my Last.fm profile?**
Your player reported two different names, and both were submitted as reported. Lyrimuse merges them
in its own statistics; merging them on Last.fm requires editing the scrobbles there.

**Can names be cleaned up before sending?**
No. If you want that, the workable form is a user-editable rule table rather than an automatic
lookup — see how [Maloja](https://github.com/krateng/maloja) does it.

**What about plays from my iPhone?**
Lyrimuse never submits them to Last.fm; they get there through Apple's own scrobbling. Lyrimuse
reads them back so they appear in its statistics alongside Mac plays.

**Can artists be merged on Last.fm without rewriting names?**
Not through the API. Last.fm's `mbid` parameter identifies a *track*, not an artist, so there is no
field for saying "these two names are the same person" while leaving both names intact.

**Does the local listening log duplicate my scrobbles?**
No. It records a play only when no Last.fm account is connected, or when a submission failed. With
Last.fm connected and working it stays empty.

---

*Implementation: [`lyrimuse-collector/lastfm.go`](../lyrimuse-collector/lastfm.go)
(`resolveScrobbleArtist`, `scrobble`, `updateNowPlaying`),
[`lyrimuse-collector/poller.go`](../lyrimuse-collector/poller.go)
(`listenThreshold`, `recordFailedMirror`).
Maintainer-facing spec: [`docs/features/12-scrobble-accounts.md`](features/12-scrobble-accounts.md).*
