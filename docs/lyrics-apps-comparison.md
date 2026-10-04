# Desktop lyrics apps for macOS in 2026: Lyrimuse vs LyricsX vs Lyric Fever

**Language:** **English** | [简体中文](lyrics-apps-comparison.zh-CN.md)

> **Disclosure:** this page is maintained by the author of Lyrimuse, so read it with that in mind.
> Every factual claim below was checked against each project's own public repository, README and
> release notes on **2026-10-04**; "—" means a feature is *not advertised* in that project's own
> materials as of that date, not necessarily that it's absent. Corrections are welcome —
> [open an issue](https://github.com/Yudaotor/lyrimuse/issues).

**Is LyricsX still maintained?** Not actively: [LyricsX](https://github.com/ddddxxx/LyricsX)'s last
release was **v1.6.3 in April 2022**, and its main branch was last changed in May 2022; since then
only the branch that syncs community translations has moved.
That's the question that brings most people to this page, so here is a factual, current comparison
of the actively maintained open-source options:

- **[Lyric Fever](https://github.com/aviwad/LyricFever)** (MIT) — Spotify + Apple Music lyrics,
  macOS 15+. Describes itself as a "spiritual successor to LyricsX".
- **[Lyrimuse](https://github.com/Yudaotor/lyrimuse)** (GPL-3.0, this project) — word-synced lyrics
  for Apple Music, Spotify, Amazon Music **and the Chinese players (QQ Music, NetEase Cloud Music, Kugou, Soda Music) and KKBOX**, plus
  YouTube Music in the Kaset app or in any browser, and Spotify Web; Chinese and international lyric sources checked automatically, with
  **every candidate scored on one scale so the best match wins** (and the decision shown per
  track); translation, readings for Japanese, Korean, Mandarin and Cantonese; Last.fm & ListenBrainz scrobbling
  with local listening stats. macOS 14+, Apple Silicon and Intel.

## Side-by-side (facts checked 2026-10-04)

| | **Lyrimuse** | **LyricsX** | **Lyric Fever** |
|---|---|---|---|
| License · price | GPL-3.0 · free | MPL-2.0 · free | MIT · free |
| Latest release | v1.9.0 (Sep 2026) | v1.6.3 (Apr 2022) | v3.3 (Nov 2025) |
| Minimum macOS | 14 (Sonoma) | 10.11 | 15 (Sequoia) |
| Players | Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Soda Music, KKBOX, Amazon Music, Kaset (YouTube Music) — any combination | Apple Music, Spotify, Vox, Audirvana, Swinsian (via its MusicPlayer library) | Spotify, Apple Music |
| Web players in a browser | YouTube Music & Spotify Web, synced to the page's own progress | — | — |
| Lyric sources checked automatically | NetEase, QQ Music, Kugou, Kuwo, Migu, Musixmatch, LRCLIB, LyricFind, Deezer, AMLL, Soda Music, Apple Music (official, opt-in) | multiple, via its LyricsKit library | 3: Spotify, LRCLIB, NetEase |
| Match selection | every candidate from every source scored on one scale (title / artist / album / reported-duration fit + quality signals like word-level timing); a per-track decision panel shows each candidate's score and why the winner won; manual picks are locked and never overridden | — | — |
| Word-by-word sync | yes, across sources (incl. Apple Music's official timing and the hand-curated AMLL database) | via LRCX word time tags, when the source provides them | — |
| Translation | source community translation when available, else on-device Apple translation (17 target languages) with online fallback | displays source-provided translations | Apple on-device translation, with a per-song source language |
| Readings | Japanese romaji, Korean romanization, Mandarin pinyin, **Cantonese Jyutping**; decided line by line, each language switched separately | — | Japanese romanization |
| Simplified ⇄ Traditional Chinese | yes, independent of UI language | yes | yes, including the Hong Kong and Taiwan variants |
| Duet / multi-singer line splitting | yes, when the source marks parts | — | — |
| Scrobbling & listening stats | Last.fm + ListenBrainz scrobbling, backfill, local history, charts, listening heatmap | — | — |
| Display surfaces | floating overlay, Dynamic-Island-style capsule, menu bar lyrics, full lyrics window | desktop + menu bar | menu bar, fullscreen view, karaoke popup |
| UI languages | English, Simplified Chinese, Traditional Chinese | multiple (Crowdin) | English, Simplified Chinese, Traditional Chinese |

## Where Lyrimuse fits

Lyrimuse is built for listeners the other two don't fully cover: you play music through
**QQ Music, NetEase Cloud Music, Kugou, Soda Music, KKBOX, Amazon Music or Kaset** (not just Apple Music / Spotify); you play
**YouTube Music or Spotify in a browser** and still want desktop lyrics synced to the page's own
progress; you want **Mandarin pinyin, Cantonese Jyutping or Korean romanization** alongside the
original lines; or you want **Last.fm / ListenBrainz scrobbling and listening stats** in the same app that
shows your lyrics — all of it free, open source, and actively maintained.

Matching is also **score-driven rather than first-hit**: anyone who has used multi-source lyrics
apps knows the pain of a wrong version getting picked. Lyrimuse ranks every candidate from every
source on title / artist / album / reported-duration fit plus quality signals such as word-level
timing, shows you each track's decision with per-candidate scores, can upgrade automatically when
a source later offers a cleaner match — and locks any lyric you picked by hand so it's never
overridden.

<p align="center"><img src="images/app-resolution-decision.png" width="560" alt="Resolution decision panel — every candidate scored, and why the winner won"><br><sub>The per-track resolution panel: every candidate's score, and why the winner won.</sub></p>

**Install:** `brew tap yudaotor/lyrimuse && brew trust --cask yudaotor/lyrimuse/lyrimuse && brew install --cask lyrimuse`
(Apple Silicon and Intel; the `brew trust` step is a one-time confirmation Homebrew asks for with
non-official taps), or download from the
[Releases page](https://github.com/Yudaotor/lyrimuse/releases/latest) — full options in
[Getting Started](https://github.com/Yudaotor/lyrimuse/blob/main/README.md#getting-started).
