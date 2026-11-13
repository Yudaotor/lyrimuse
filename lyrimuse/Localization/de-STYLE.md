# German (de) translation style

Lyrimuse's UI strings live in `lyrimuse/Localization/Localizable.xcstrings`. The key of every entry is the Simplified Chinese source text; the `en` value is the closest reference for meaning and length, and the `es` / `fr` values show how other languages solved the same length problem. Translate into natural German as it would appear in a macOS app, then run `python3 lyrimuse/Localization/generate-strings.py`.

## Voice

- Address the user as **du** (lowercase), like Apple's current German macOS and iOS. Never Sie.
- Follow the wording Apple uses in German macOS and Apple Music (Systemeinstellungen, Einstellungen, Musik, Finder, Titel, Cover, Wiedergabe). When Apple has a term, use it.
- Labels, buttons, menu items, section titles: short noun phrases or an infinitive, German capitalization rules (nouns capitalized, otherwise sentence case): „Liedtext suchen“, „Diagnose exportieren“.
- Descriptions, help text, status and error messages: plain present tense, du-form: „Lyrimuse zeigt …“, „Aktiviere diese Option, um …“.
- No trailing period at the end of any string, even long ones. A period between two sentences is fine.
- **Keep it as short as the English.** German runs 20–35 % longer than English and many strings sit in narrow toolbars, segmented controls, tiles and the menu bar. Prefer the shorter word („Text“ over „Liedtext“ where the context already says lyrics, „Schrift“ over „Schriftart“ on a toolbar button), avoid long compounds when a short one exists, and never add words the English doesn't have.
- Single-word labels must stay single words that fit: a long compound cannot wrap and gets cut mid-word. When the English is one short word, look for a short German word („Auto“, „Ein“, „Mini“); never abbreviate with a period („Hintergr.“) — rephrase instead.
- The same thing is always called the same way. Pick the glossary term and reuse it everywhere, including in sentences that refer to a setting by name: the quoted name must match the label exactly.
- A placeholder that is already a duration („~12 Std.“) must not get its own „etwa“ in the template around it.

## Punctuation and spacing

- Quotation marks: German low-high „like this“ (U+201E … U+201C) for UI terms and quoted text. Never straight " quotes, never « ».
- Apostrophe is the typographic ’ (U+2019) when one is needed (rare in German).
- No space before : ; ? ! (unlike French).
- Keep `…` (single ellipsis character) where the source has it; like Apple's German menus, put a space before it: „Exportieren …“, „Sichern unter …“.
- Keep keyboard symbols (⌘ ⌥ ⇧ ⌃), emoji, `\n`, Markdown (`**`, links) and URLs exactly.
- Numbers and units as in the English, keeping what the English does with the placeholder („30 s“, „2 Std. 5 Min.“ only if the English spells units out; otherwise „2 h 5 min“). Decimal values come from the placeholder; do not write a decimal comma by hand in a format string. A hand-written decimal outside a placeholder uses a comma („0,5 s“).

## Placeholders and plurals

- Every `%@`, `%d`, `%lld`, `%.1f`, `%1$@`… in the source must appear in the translation with the same number, order of arguments and type. Never turn `%d` into `%@`.
- If German word order needs the arguments in a different order and the source has two or more arguments, switch to positional form (`%2$@ … %1$@`) keeping each argument's type.
- `%%` is a literal percent sign.
- German has singular and plural; 0 takes the plural. Where the English entry has plural forms (one / other), give both: one for exactly 1, other for every other count.

## Names that stay as they are

Lyrimuse, Last.fm, ListenBrainz, Discord, Telegram, Slack, Bark, ntfy, Server酱 (ServerChan), Apple Music, Spotify, YouTube Music, Genius, Cloudflare, GitHub, Sparkle, Touch Bar, Dock, Finder, Scrobble.
Chinese music services use the names in the English string (NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Soda Music…).

## Glossary

| Simplified Chinese | English | German |
|---|---|---|
| 歌词 | Lyrics | Liedtext (plural Liedtexte; „Text“ when context is clear) |
| 播放器 | Player | Player |
| 歌词显示 | Lyrics Display | Liedtext-Anzeige |
| 快捷键 | Keyboard Shortcuts | Tastaturkurzbefehle |
| 通用 | General | Allgemein |
| 关于 | About | Über |
| 实验室 | Labs | Labor |
| 推送提醒 | Push Alerts | Push-Mitteilungen |
| 网页推送 | Web Push | Web-Push |
| 关联平台 | Linked Platforms | Verknüpfte Dienste |
| 桌面悬浮歌词 / 悬浮歌词 | (Desktop) Floating Lyrics | Schwebender Text |
| 灵动岛 | Notch | Notch |
| 菜单栏 | Menu Bar | Menüleiste |
| 触控栏 | Touch Bar | Touch Bar |
| 歌词窗口 | Lyrics Window | Liedtextfenster |
| 歌词管理 | Lyrics Manager | Liedtext-Verwaltung |
| 歌词库 | Lyrics Library | Liedtext-Bibliothek |
| 歌词来源 / 歌词源 | Lyrics Sources | Liedtextquellen |
| 译文 | Translation | Übersetzung |
| 罗马音 / 读音 | Romanization / Reading | Umschrift |
| 逐字歌词 | Word-by-word lyrics | Wort für Wort |
| 打卡 / scrobble | Scrobble | Scrobbeln (noun: Scrobble) |
| 收听 / 播放次数 | Listens / Plays | Wiedergaben |
| 收听记录 | Listening history | Hörverlauf |
| 听歌报告 / 听歌小结 | Listening Report / Digest | Hörbericht / Hörrückblick |
| 推送渠道 | Push Channels | Kanäle |
| 偏移 | Offset | Versatz |
| 封面 | Artwork | Cover |
| 专辑 / 歌手 / 歌曲 | Album / Artist / Track | Album / Künstler / Titel |
| 设置 | Settings | Einstellungen |
| 全部设置 | All Settings | Alle Einstellungen |
| 跟随系统 | Follow System | System |
| 外观 | Appearance | Erscheinungsbild |
| 背景 | Background | Hintergrund |
| 字体 | Font | Schrift |
| 字号 | Font size | Größe |
| 颜色 | Color | Farbe |
| 内容 | Content | Inhalt |
| 行为 | Behavior | Verhalten |
| 布局 / 排版 | Layout | Layout |
| 位置 | Position | Position |
| 跟随封面 | Artwork | Cover |
| 纯色 / 渐变 / 毛玻璃 / 透明 | Solid / Gradient / Frosted Glass / Transparent | Einfarbig / Verlauf / Milchglas / Transparent |
| 自动 | Auto | Auto |
| 完整尺寸 / 迷你尺寸 | Full Size / Mini Size | Vollgröße / Mini |
| 卡拉OK效果 | Karaoke | Karaoke |
| 已开启 / 未开启 | On / Off | Ein / Aus |
| 辅助功能 | Accessibility | Bedienungshilfen |
| 自动化 | Automation | Automation |
| 完全磁盘访问 | Full Disk Access | Festplattenvollzugriff |
| 登录时打开 | Open at Login | Bei Anmeldung öffnen |
| 检查更新 | Check for Updates | Nach Updates suchen |
| 导入 / 导出 | Import / Export | Importieren / Exportieren |
| 候选 | Candidates | Treffer |
| 搜索 | Search | Suchen |
| 重新匹配 | Rematch | Neu zuordnen |
| 取消 / 完成 / 好 | Cancel / Done / OK | Abbrechen / Fertig / OK |
| 保存 / 删除 / 重置 / 恢复默认 | Save / Delete / Reset / Restore Defaults | Sichern / Löschen / Zurücksetzen / Standard |
| 关闭 | Close | Schließen |
| 高级 | Advanced | Erweitert |
| 诊断 | Diagnostics | Diagnose |
