# Lyrimuse URL Scheme

*[中文版](url-scheme.zh-CN.md)*

Links that start with `lyrimuse://` let you control Lyrimuse from Shortcuts, Raycast, Alfred, Stream Deck, the terminal (`open 'lyrimuse://…'`) and similar tools: open windows and settings pages, show or hide lyrics, control playback, nudge the timing, or get what's playing.

The common ones can be copied from **Deep Links** at the bottom of Settings › Keyboard Shortcuts. Hover over any shortcut there to copy the link for that action.

## General rules

- Links are case-insensitive.
- A link Lyrimuse doesn't recognize does nothing and shows "Unrecognized link".
- Any link that opens a window accepts `background=1`: the window appears, but Lyrimuse doesn't come to the front or take keyboard focus. For example `lyrimuse://lyrics-window?background=1`.
- Toggle actions accept `on=1` or `on=0` to set a target state (`true` / `false` and `on` / `off` work too), so running one twice gives the same result. Without it, they toggle.
- Web pages can open `lyrimuse://` links too (your browser asks first), so only easy-to-undo actions are exposed: toggles, opening windows, playback control and timing nudges. Nothing deletes or edits lyrics or touches your accounts.

## Opening windows

| Link | What it does |
|---|---|
| `lyrimuse://lyrics-window` | Opens the lyrics window |
| `lyrimuse://lyrics-window/search` | Opens the lyrics window and the Search Lyrics window (the same one as `lyrics-search`) |
| `lyrimuse://lyrics-manager` | Opens the Lyrics Manager |
| `lyrimuse://lyrics-search` | Opens the Search Lyrics window for the current song |
| `lyrimuse://menubar-panel` | Opens or closes the menu bar panel |
| `lyrimuse://menubar-panel?quick=overlay` | Opens the menu bar panel on one tile's quick settings (only opens, never closes). `quick` is one of `overlay`, `notch`, `menubar`, `touchbar`, `lyrics-window`, `lyrics-manager` |
| `lyrimuse://menubar-menu` | Pops up the menu bar icon's menu |
| `lyrimuse://onboarding` | Opens the welcome guide |

## Opening settings

`lyrimuse://settings` opens Settings. Add a path to go straight to a page, and one more segment to go to a section on that page.

| Path | Page | Sections |
|---|---|---|
| `/lyrics` | Lyrics | `/fetch` Sources, `/translation` Translation, `/display` Adjust, `/manage` Library |
| `/player` | Player | `/players` Player, `/linkage` Linkage, `/permissions` Permissions & Services |
| `/appearance` | Lyrics Display | `/overlay` Floating Lyrics, `/notch` Notch, `/menu-bar` Menu Bar, `/touch-bar` Touch Bar, `/lyrics-window` Lyrics Window |
| `/shortcuts` | Keyboard Shortcuts | — |
| `/general` | General | — |
| `/about` | About | — |
| `/account/lastfm` | Last.fm | `/stats` Stats, `/chart` Charts, `/on-this-day` Footprint, `/settings` Settings |
| `/account/listenbrainz` | ListenBrainz | — |
| `/account/discord` | Discord | `/display` What's Shown, `/buttons` Buttons, `/privacy` Privacy |
| `/account/relay` | Web Push | — |
| `/account/bark` | Push Alerts | — |
| `/software-update` | Software Update | Add `?check=1` to also check for updates |
| `/lastfm-suggestions` | Last.fm Account Suggestions | — |
| `/labs` | Labs | — |

For example `lyrimuse://settings/appearance/overlay` or `lyrimuse://settings/software-update?check=1`. An unknown path just opens Settings; an unknown section opens the page on the section you last viewed.

## Actions: `lyrimuse://action/<name>`

These are the same actions as the keyboard shortcuts in Settings › Keyboard Shortcuts. They run the same code and show the same feedback.

### Display

| Name | What it does | Parameters |
|---|---|---|
| `toggle-overlay` | Shows or hides the floating lyrics | `on` |
| `toggle-notch` | Shows or hides the notch lyrics | `on` |
| `toggle-menubar-lyrics` | Shows or hides the menu bar lyrics | `on` |
| `toggle-touchbar` | Expands or collapses the Touch Bar lyrics (Macs with a Touch Bar only) | — |
| `toggle-all-lyrics` | Hides all lyrics: whichever of the floating, notch and menu bar lyrics are on get hidden, and running it again brings back exactly those | `on` (`0` hides, `1` restores) |
| `toggle-lock-position` | Locks or unlocks the floating lyrics' position | `on` |
| `toggle-translation` | Shows or hides translations | `on` |
| `toggle-romanization` | Shows or hides romanization | `on` |
| `overlay-font-larger` | Makes the floating lyrics larger | — |
| `overlay-font-smaller` | Makes the floating lyrics smaller | — |

### Windows

| Name | What it does | Parameters |
|---|---|---|
| `open-lyrics-manager` | Opens the Lyrics Manager | — |
| `open-lyrics-window` | Opens the lyrics window | — |
| `toggle-lyrics-window-mini` | Switches the lyrics window between mini and full size; if it's closed, opens it in mini size | `on` (`1` mini, `0` full) |
| `search-lyrics` | Opens the Search Lyrics window | — |
| `open-settings` | Opens Settings | — |
| `open-player` | Brings the player you're using to the front | — |

### Lyrics timing

| Name | What it does | Parameters |
|---|---|---|
| `lyrics-advance` | Moves this song's lyrics earlier by one step | `step`: seconds for this nudge (0 to 5); the step from Settings if omitted |
| `lyrics-delay` | Moves this song's lyrics later by one step | `step`, as above |
| `lyrics-offset-reset` | Resets this song's lyrics offset to zero | — |

### Playback

| Name | What it does | Parameters |
|---|---|---|
| `play-pause` | Play / pause | — |
| `next-track` | Next track | — |
| `previous-track` | Previous track | — |
| `toggle-favorite` | Favorites or unfavorites the current song (if the player supports it) | `on` (`1` favorite, `0` remove) |

For example `lyrimuse://action/toggle-overlay?on=0` or `lyrimuse://action/lyrics-advance?step=0.5`.

### Other actions

| Link | What it does |
|---|---|
| `lyrimuse://action/copy-lyric` | Copies the current lyric line to the clipboard; add `?translation=1` to include the translation |
| `lyrimuse://action/surfaces?overlay=1&notch=0&menubar=1` | Sets which lyrics are shown in one go: `overlay` (floating lyrics), `notch`, `menubar`, each `1` to show or `0` to hide. Include only the ones you want to change |
| `lyrimuse://action/lyrics-offset?ms=-300` | Sets this song's lyrics offset to an exact value in milliseconds: positive is earlier, negative is later, within ±10000 |
| `lyrimuse://action/play-mode?mode=shuffle` | Sets the play mode: `mode` is `list`, `shuffle`, `repeat-all` or `repeat-one`. Modes the player can't do fall back to `list` |

## Getting what's playing (x-callback-url)

```
lyrimuse://x-callback-url/now-playing?x-success=<callback URL>
```

Lyrimuse opens the `x-success` URL with what's playing added as parameters (any parameters already on `x-success` are kept):

| Parameter | Value |
|---|---|
| `title` | Song title |
| `artist` | Artist |
| `album` | Album |
| `lyric` | The current lyric line |
| `player` | Player name |
| `playing` | `1` while something is playing, `0` when paused or nothing is loaded (with nothing loaded, the fields above are empty) |

In Shortcuts, use the **Open X-Callback URL** action with `lyrimuse://x-callback-url/now-playing` as the URL. Shortcuts adds `x-success` itself, and the returned parameters become the action's output.

So that web pages can't use this link to see what you're listening to, the callback URL has two limits: it can't be a web, file or script URL (`http`, `https`, `file`, `ftp`, `javascript`, `data`, `about`, `blob`, or `lyrimuse` itself), and on your Mac it has to be opened by an app that isn't a browser. Otherwise nothing is sent back.
