# Italian (it) translation style

Lyrimuse's UI strings live in `lyrimuse/Localization/Localizable.xcstrings`. The key of every entry is the Simplified Chinese source text; the `en` value is the closest reference for meaning and length, and the `es` / `fr` values show how other Romance languages solved the same length problem. Translate into natural Italian as it would appear in a macOS app, then run `python3 lyrimuse/Localization/generate-strings.py`.

## Voice

- Address the user as **tu**, like Apple's Italian macOS and iOS („Fai clic su…“ style imperatives: « Scegli », « Apri », « Attiva »). Never Lei.
- Follow the wording Apple uses in Italian macOS and Apple Music (Impostazioni di Sistema, Musica, Finder, brano, testo, illustrazione, In riproduzione). When Apple has a term, use it.
- Labels, buttons, menu items, section titles: short noun phrases or an imperative / infinitive, sentence case (only the first word and proper names capitalized): “Cerca testo”, “Esporta diagnosi”.
- Descriptions, help text, status and error messages: plain present tense: “Lyrimuse mostra…”, “Attiva questa opzione per…”. Click is “fai clic su”.
- No trailing period at the end of any string, even long ones. A period between two sentences is fine.
- **Keep it as short as the English.** Italian runs 15–30 % longer than English and many strings sit in narrow toolbars, segmented controls, tiles and the menu bar. Prefer the shorter word (“Testo”, “Sfondo”, “Font”), drop articles in labels where natural (“Mostra testo”, not “Mostra il testo”), and never add words the English doesn't have.
- Single-word labels must stay single words that fit: a long single word cannot wrap, it gets cut mid-word. When the English is one short word, look for a short Italian word (“Auto”, “Mini”, “Sì”); never abbreviate with a period unless Apple does — rephrase instead.
- The same thing is always called the same way. Pick the glossary term and reuse it everywhere, including in sentences that refer to a setting by name: the quoted name must match the label exactly.
- A placeholder that is already a duration (“~12 h”) must not get its own “circa” in the template around it.

## Punctuation and spacing

- Quotation marks: typographic double quotes “like this” (U+201C … U+201D) for UI terms and quoted text, as Apple's Italian macOS does. Never straight " quotes, never « » or „ “.
- Apostrophe is the typographic ’ (U+2019), never the straight ' — Italian elides constantly (l’album, dell’artista, un’app, c’è).
- No space before : ; ? ! (unlike French).
- Keep `…` (single ellipsis character) where the source has it, with no space before it, like Apple's Italian menus: “Esporta…”, “Scegli…”.
- Keep keyboard symbols (⌘ ⌥ ⇧ ⌃), emoji, `\n`, Markdown (`**`, links) and URLs exactly.
- Numbers and units as in the English, keeping what the English does with the placeholder (“30 s”, “2 h 5 min”). Decimal values come from the placeholder; do not write a decimal comma by hand in a format string. A hand-written decimal outside a placeholder uses a comma (“0,5 s”).
- Accented capitals are written with the accent (“È”, not “E'”).

## Placeholders and plurals

- Every `%@`, `%d`, `%lld`, `%.1f`, `%1$@`… in the source must appear in the translation with the same number, order of arguments and type. Never turn `%d` into `%@`.
- If Italian word order needs the arguments in a different order and the source has two or more arguments, switch to positional form (`%2$@ … %1$@`) keeping each argument's type.
- `%%` is a literal percent sign.
- Italian has singular and plural; **0 takes the plural** (“0 brani”). Where the English entry has plural forms (one / other), give both: one for exactly 1, other for every other count.
- Watch gender and number agreement around placeholders: when the noun is not known, prefer a construction that does not need agreement (“Brani: %@” rather than an adjective that changes with the count).

## Names that stay as they are

Lyrimuse, Last.fm, ListenBrainz, Discord, Telegram, Slack, Bark, ntfy, Server酱 (ServerChan), Apple Music, Spotify, YouTube Music, Musixmatch, Genius, Cloudflare, GitHub, Sparkle, Touch Bar, Dock, Finder, Scrobble.
Chinese music services use the names in the English string (NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Soda Music…).

## Glossary

| Simplified Chinese | English | Italian |
|---|---|---|
| 歌词 | Lyrics | Testo (plural Testi) |
| 播放器 | Player | Player |
| 歌词显示 | Lyrics Display | Visualizzazione testo |
| 快捷键 | Keyboard Shortcuts | Scorciatoie da tastiera |
| 通用 | General | Generali |
| 关于 | About | Info |
| 实验室 | Labs | Lab |
| 推送提醒 | Push Alerts | Avvisi push |
| 网页推送 | Web Push | Push web |
| 关联平台 | Linked Platforms | Servizi collegati |
| 桌面悬浮歌词 / 悬浮歌词 | (Desktop) Floating Lyrics | Testo fluttuante |
| 灵动岛 | Notch | Notch |
| 菜单栏 | Menu Bar | Barra dei menu |
| 触控栏 | Touch Bar | Touch Bar |
| 歌词窗口 | Lyrics Window | Finestra testo |
| 歌词管理 | Lyrics Manager | Gestione testi |
| 歌词库 | Lyrics Library | Libreria testi |
| 歌词来源 / 歌词源 | Lyrics Sources | Fonti dei testi |
| 译文 | Translation | Traduzione |
| 罗马音 / 读音 | Romanization / Reading | Pronuncia |
| 逐字歌词 | Word-by-word lyrics | Parola per parola |
| 打卡 / scrobble | Scrobble | Scrobble (verb: scrobblare) |
| 收听 / 播放次数 | Listens / Plays | Ascolti |
| 收听记录 | Listening history | Cronologia ascolti |
| 听歌报告 / 听歌小结 | Listening Report / Digest | Report di ascolto / Riepilogo ascolti |
| 推送渠道 | Push Channels | Canali |
| 偏移 | Offset | Offset |
| 封面 | Artwork | Illustrazione |
| 专辑 / 歌手 / 歌曲 | Album / Artist / Track | Album / Artista / Brano |
| 正在播放 | Now Playing | In riproduzione |
| 设置 | Settings | Impostazioni |
| 系统设置 | System Settings | Impostazioni di Sistema |
| 全部设置 | All Settings | Tutte le impostazioni |
| 跟随系统 | Follow System | Sistema |
| 外观 | Appearance | Aspetto |
| 背景 | Background | Sfondo |
| 字体 | Font | Font |
| 字号 | Font size | Corpo (typographic body size; “Corpo traduzione”, “Corpo pronuncia”) |
| 颜色 | Color | Colore |
| 内容 | Content | Contenuto |
| 行为 | Behavior | Comportamento |
| 布局 / 排版 | Layout | Layout |
| 位置 | Position | Posizione |
| 跟随封面 | Artwork | Illustrazione |
| 纯色 / 渐变 / 毛玻璃 / 透明 | Solid / Gradient / Frosted Glass / Transparent | Uniforme / Gradiente / Smerigliato / Trasparente |
| 自动 | Auto | Auto |
| 完整尺寸 / 迷你尺寸 | Full Size / Mini Size | Completa / Mini |
| 卡拉OK效果 | Karaoke | Karaoke |
| 已开启 / 未开启 (status) | On / Off | Sì / No |
| 辅助功能 | Accessibility | Accessibilità |
| 自动化 | Automation | Automazione |
| 完全磁盘访问 | Full Disk Access | Accesso completo al disco |
| 通知 | Notifications | Notifiche |
| 控制中心 | Control Center | Centro di Controllo |
| 隐私与安全性 | Privacy & Security | Privacy e sicurezza |
| 登录项 | Login Items | Elementi login |
| 仍要打开 | Open Anyway | Apri comunque |
| 迷你播放器 | MiniPlayer | Mini Player |
| 登录时打开 | Open at Login | Apri al login |
| 检查更新 | Check for Updates | Verifica aggiornamenti |
| 导入 / 导出 | Import / Export | Importa / Esporta |
| 候选 | Candidates | Risultati |
| 搜索 | Search | Cerca |
| 重新匹配 | Rematch | Riassocia |
| 取消 / 完成 / 好 | Cancel / Done / OK | Annulla / Fine / OK |
| 保存 / 删除 / 重置 / 恢复默认 | Save / Delete / Reset / Restore Defaults | Salva / Elimina / Reimposta / Ripristina default |
| 关闭 | Close | Chiudi |
| 高级 | Advanced | Avanzate |
| 诊断 | Diagnostics | Diagnosi |

When a term names macOS, Music, Safari or Gatekeeper UI, look up the exact Italian string in the system's own resources (`plutil -p` on the `.loctable` or `it.lproj/*.strings` of the component) instead of guessing.
