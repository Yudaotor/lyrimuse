# Desktop lyrics apps for macOS in 2026: Lyrimuse vs LyricsX vs Lyric Fever vs Lyrics Plus

**Language:** **English** | [简体中文](lyrics-apps-comparison.zh-CN.md)

> **Disclosure:** this page is maintained by the author of Lyrimuse, so read it with that in mind.
> Every factual claim below was checked against each project's own public repository and README on
> **2026-09-05**; "—" means a feature is *not advertised* in that project's own materials as of that
> date, not necessarily that it's absent. Corrections are welcome —
> [open an issue](https://github.com/Yudaotor/lyrimuse/issues).

**Is LyricsX still maintained?** Not actively: [LyricsX](https://github.com/ddddxxx/LyricsX)'s last
release was **v1.6.3 in April 2022** — more than four years ago. The repository still receives an
occasional commit (last push July 2026) and the app still works for many people, but there have been
no releases, and issues around newer macOS versions accumulate. That's the main reason this
comparison exists: people searching for a "LyricsX alternative" deserve a factual, current answer.

**What replaced it?** Three actively maintained open-source options, each with a different focus:

- **[Lyric Fever](https://github.com/aviwad/LyricFever)** (MIT) — polished Spotify + Apple Music
  lyrics, macOS 15+. Describes itself as a "spiritual successor to LyricsX".
- **[Lyrics Plus](https://github.com/afeibukaixin/Lyrics-Plus)** (MIT) — lightweight lyrics
  companion for Apple Music, Spotify and system media players, macOS 13+.
- **[Lyrimuse](https://github.com/Yudaotor/lyrimuse)** (GPL-3.0, this project) — word-synced lyrics
  for Apple Music, Spotify **and the Chinese players (QQ Music, NetEase Cloud Music, Kugou)**, plus
  YouTube Music / Spotify Web playing in any browser; 8 lyric sources checked automatically;
  translation, pinyin / Cantonese Jyutping / furigana; Last.fm & ListenBrainz scrobbling with local
  listening stats. macOS 14+.

**What about OSD Lyrics?** It's a Linux desktop-lyrics app, not a macOS one — it shows up in
"LyricsX alternative" lists but won't run on a Mac.

## Side-by-side (facts checked 2026-09-05)

| | **Lyrimuse** | **LyricsX** | **Lyric Fever** | **Lyrics Plus** |
|---|---|---|---|---|
| License · price | GPL-3.0 · free | MPL-2.0 · free | MIT · free | MIT · free |
| Latest release | v1.5.0 (Sep 2026) | v1.6.3 (Apr 2022) | v3.3 (Nov 2025) | no tagged releases checked; repo active (pushed Sep 2026) |
| GitHub stars | 6 (project is 2 months old) | 5,211 | 629 | 38 |
| Minimum macOS | 14 (Sonoma) | 10.11 | 15 (Sequoia) | 13 (Ventura) |
| Players | Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou — any combination | Apple Music, Spotify, Vox, Audirvana, Swinsian (via its MusicPlayer library) | Spotify, Apple Music | Apple Music, Spotify, system media players |
| Web players in a browser | YouTube Music & Spotify Web, synced to the page's own progress | — | — | — |
| Lyric sources checked automatically | 8: NetEase, QQ Music, Kugou, Kuwo, Musixmatch, LRCLIB, LyricFind, AMLL | multiple, via its LyricsKit library | 3: Spotify, LRCLIB, NetEase | optional online providers (count not stated) |
| Word-by-word sync | yes, across sources (incl. the hand-curated AMLL database) | via LRCX word time tags, when the source provides them | — | word-level karaoke timing (per its README) |
| Translation | source community translation when available, else on-device Apple translation (18 target languages) with online fallback | displays source-provided translations | Apple on-device translation | translations (per its README) |
| Romanization | per-line pinyin, **Cantonese Jyutping**, Japanese furigana | — | — | romanization (per its README) |
| Simplified ⇄ Traditional Chinese | yes, independent of UI language | yes | — | — |
| Duet / multi-singer line splitting | yes, when the source marks parts | — | — | — |
| Scrobbling & listening stats | Last.fm + ListenBrainz scrobbling, backfill, local history, charts, listening heatmap | — | — | — |
| Display surfaces | floating overlay, Dynamic-Island-style capsule, menu bar lyrics, full lyrics window | desktop + menu bar | menu bar, fullscreen view, karaoke popup | desktop, menu bar, window, Dynamic Island |
| UI languages | English, Simplified Chinese, Traditional Chinese | multiple (Crowdin) | English, Simplified Chinese | English, Simplified Chinese |

## Which one should you pick?

An honest routing, including the cases where Lyrimuse is *not* the answer:

- **You're on macOS 10.13–12 (older Mac):** LyricsX is the only one of these that runs there.
- **You only use Spotify, on macOS 15+:** Lyric Fever is polished and focused on exactly that.
- **You want something minimal for Apple Music/Spotify on macOS 13+:** Lyrics Plus is the lightest.
- **You listen through QQ Music, NetEase Cloud Music or Kugou; you play YouTube Music or Spotify in
  a browser; you want Cantonese Jyutping or furigana; or you want scrobbling and listening stats in
  the same app:** that's what Lyrimuse is built for — macOS 14+, Apple Silicon and Intel.

One thing to know before installing Lyrimuse: it ships **ad-hoc signed** (no paid Apple developer
account), so the first launch needs one extra step — the
[README's install section](https://github.com/Yudaotor/lyrimuse/blob/main/README.md#getting-started)
covers the one-line Homebrew install that handles it automatically, plus the manual alternatives.
LyricsX is on the Mac App Store; Lyric Fever ships via Homebrew.
