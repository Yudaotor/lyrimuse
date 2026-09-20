# How Lyrimuse scrobbles to Last.fm

*[中文版](scrobbling.zh-CN.md)*

## 1. When a play counts

A play is submitted once **all** of these hold:

| Rule | Value |
|---|---|
| Played long enough | half the track, capped at 240s — or 240s if the length is unknown. Stricter points for Last.fm only — see §1b |
| Track is long enough | `≥ 30s` (tracks of unknown length are allowed through). Can be switched off — see §1a |
| Not an ad | Spotify ad breaks are detected and skipped |

Playback is sampled every 5 seconds and elapsed time accrues from the wall clock, so pausing stops
the count and seeking does not inflate it. If two samples end up more than 60 seconds apart — the
machine slept, or the collector was restarted — that gap is discarded rather than credited.

These thresholds match [Last.fm's scrobbling guidelines](https://www.last.fm/api/scrobbling).

### 1a. Tracks under 30 seconds

Settings → Accounts → Last.fm → *Scrobble* → **Tracks under 30 seconds** (`scrobble_short_tracks`,
default **off**). Last.fm's rule *"The track must be longer than 30 seconds"* is a client-side rule —
the server does not reject short tracks and has no "too short" ignore code — and every mainstream
scrobbler honours it, so Lyrimuse does too by default. Turning it on lets short tracks count once
they pass the half-played rule (a 20-second track needs 10 seconds). It is a **Last.fm-only** setting:
short tracks are scrobbled to Last.fm (and recorded in the local log that feeds Last.fm backfill) but
are never submitted to ListenBrainz, whose behaviour is unchanged either way.

### 1b. Scrobble point

Settings → Accounts → Last.fm → *Scrobble* → **Scrobble Point** (`lastfm_scrobble_point`, default
**50%**). How far into a track a play must get before it is scrobbled to Last.fm:

| Setting | Value | Scrobbled when |
|---|---|---|
| **50%** (default) | `50` | Last.fm's rule above: half the track, capped at 4 minutes |
| 75% / 90% | `75` / `90` | 75% / 90% of the track's length has been played — played time only, no 4-minute cap |
| Track End | `end` | the track plays through to its end; skipping ahead does not count |

Last.fm's rule is a floor, so there is no setting below 50%. It is **Last.fm-only**: ListenBrainz and
the web relay still submit at the 50% point; only the Last.fm scrobble (and the local log that feeds
Last.fm backfill) waits for the chosen point. A track skipped before the point sends nothing to
Last.fm — that is the setting doing its job, not a lost scrobble. Tracks of unknown length follow the
default rule.

*Track End* is judged from the last observed playback position when the track changes: within 12
seconds of the end (10% of the length for short tracks) counts as played through, so a player's
crossfade or a gapless transition does not withhold the scrobble.

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

On the ListenBrainz path, and on Last.fm's *All* and *First only* modes, artist, track and album
names are submitted exactly as the player reported them. (Last.fm's *Smart* mode rewrites the
artist and track to match the catalogue entry — see the next section.)

The only processing applied is invisible-character cleanup: non-breaking and full-width spaces
become ordinary spaces, zero-width characters and BOMs are removed, runs of whitespace collapse to
one, and leading/trailing whitespace is trimmed. Without it, an invisible non-breaking space
creates a separate artist entity on Last.fm.

Nothing visible is changed — not capitalisation, not Traditional vs Simplified Chinese, not
parenthetical subtitles, not multi-artist credits. `PRINCE` stays `PRINCE`, `無所謂` stays
`無所謂`, and `一口 (The Day You Left Me)` keeps its subtitle.

Why there is no external lookup to "canonicalise" names by default:

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

## 4. Matching mode

Settings → Accounts → Last.fm → *Scrobble* → **Matching Mode**
(`lastfm_match_mode` in `~/.config/lyrimuse/lyrimuse-features.json`):

| Mode | Value | Effect |
|---|---|---|
| **Smart** (default on fresh installs) | `smart` | Finds this track's entry in Last.fm's catalogue and sends that entry's artist and title (below) |
| Custom | `custom` | Pick which parts may change — see below |
| **Raw** (default on existing installs) | `raw` | Exactly what the player reports, no network call |

*Custom* expands into three switches:

| Switch | Value | Effect |
|---|---|---|
| Rewrite artist | `lastfm_match_artist` | The artist may be replaced with the catalogue entry's spelling |
| Rewrite track name | `lastfm_match_track` | The title may be replaced with the catalogue entry's spelling |
| Collaborations: first artist only | `lastfm_match_first_artist_only` | Truncates a joint credit to its first artist (`Khalil Fong & Fiona Sit` → `Khalil Fong`) — pure string handling, no network call |

With only one rewrite dimension enabled, **a candidate is only accepted if the other field already
matches** — otherwise the result would be a combination that does not exist in the catalogue, which
lands back on a ghost entry with one listener: you.

"First artist only" differs from the other two: it applies **only when nothing was matched**. A
matched spelling is already the entry Last.fm recognises, and truncating it would turn it into an
entry that does not exist — `Hall & Oates / Maneater` (800k listeners) would become `Hall`. So
"truncate only, no matching" is byte-for-byte the old *First only* mode, still without a network call.

*Raw* stays the default wherever a `lyrimuse-features.json` already exists, because truncating a
credit is irreversible — it removes Fiona Sit from your history. Navidrome's option of the same name
(`Lastfm.ScrobbleFirstArtistOnly`) also defaults to off.

Splitting is conservative: `/` is handled separately from `,` and `&`, so `K/DA` and `AC/DC` are not
split into `K` and `AC`.

### Smart mode

What the player reports and what Last.fm's catalogue calls the same recording are often not the
same characters, and submitting as-is lands the play on a "ghost" entry — no MBID, no album, zero
duration, one listener: you. Measured on David Tao's 《那个女孩》: the player reports
`陶喆, 卢广仲 / 那个女孩`, which Last.fm does not have at all; the Simplified `陶喆 / 那个女孩` has
126 listeners; and the track's actual entry is the Traditional **`陶喆 / 那個女孩` — 889 listeners,
4,580 plays, with a catalogue duration**. Last.fm's own `autocorrect` does not help: it does not map
between Traditional and Simplified Chinese.

So *Smart* looks the track up before submitting:

1. `track.getInfo` as reported. **If it has an MBID**, nothing is touched, forever. An MBID is the
   strongest signal of a real catalogue identity, and it is what keeps a properly credited
   collaboration (Hall & Oates) from being moved onto a solo page by "more listeners".
2. Otherwise candidates are collected from **exactly three places**: as reported, the first credited
   artist, and entries under that artist whose title folds to the same key
   (`artist.getTopTracks`, which is already ordered by listeners).
3. Among the candidates Last.fm actually has catalogued (an MBID, or ≥ 500 listeners, or a catalogue
   duration — a ghost entry has none of the three), the most-listened one wins, its duration is
   verified, and its artist and track are what get submitted — decided once, kept forever. If no
   candidate qualifies, it is sent as reported and re-checked after 90 days.

It deliberately does **not** use `track.search`: that searches the literal string, which neither
finds the Traditional entry nor excludes same-title-different-song hits like
`张泽熙 / 那个女孩`. Title folding only folds spelling differences of one recording — Traditional
vs Simplified, variant characters, diacritics, featured credits (`(feat. X)`) and reissue tags
(`(Remastered 2014)`, `(Bonus Track)`). **Live, Remix, acoustic and instrumental markers are always
kept**: those are different recordings. The winning candidate also has to pass a duration check
(rejected if both sides know a duration and they differ by more than 8 seconds).

Measured over 240 real tracks: 33 rewritten, 162 sent as-is, 45 undecidable. Examples:

| Reported | Sent | Listeners |
|---|---|---|
| `周杰倫 / 手写的从前` | `周杰倫 / 手寫的從前` | 100 → 4,515 |
| `Wang Leehom / 奇遇的起点` | `王力宏 / 奇遇的起點` | 1 → 144 |
| `SZA & Phoebe Bridgers / Ghost in the Machine` | `SZA / Ghost in the Machine (feat. Phoebe Bridgers)` | 175 → 856,376 |
| `PRINCE / Walk Don't Walk (2023 Remaster)` | `Prince / Walk Don't Walk` | 231 → 16,178 |

Any lookup failure (network, rate limit, malformed answer, unreachable track list) sends the tags as
reported and caches nothing, so a hiccup never becomes a permanent decision. Decisions live in
`~/.config/lyrimuse/lyrimuse-lastfm-catalog.json` with the evidence that produced them; delete the
file to re-decide everything.

The legacy keys are still read but no longer written, and migrate without changing behaviour:
`lastfm_scrobble_artist_mode` maps `smart` → Smart, `all` → Raw, and `first` → Custom with only
"first artist only" enabled; the older boolean `lastfm_scrobble_first_artist_only=true` is
equivalent to `first`.

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
(`listenThreshold`, `recordFailedMirror`).*
