# French (fr) translation style

Lyrimuse's UI strings live in `lyrimuse/Localization/Localizable.xcstrings`. The key of every entry is the Simplified Chinese source text; the `en` value is the closest reference for meaning and length, and the `es` value shows how another Romance language solved the same length problem. Translate into natural French as it would appear in a macOS app, then run `python3 lyrimuse/Localization/generate-strings.py`.

## Voice

- Address the user as **vous**, like Apple's French macOS. Never tu.
- Follow the wording Apple uses in French macOS and Apple Music (Réglages Système, Musique, Finder, morceau, illustration). When Apple has a term, use it.
- Labels, buttons, menu items, section titles: short noun phrases or an infinitive, sentence case (only the first word and proper names capitalized): « Rechercher les paroles », « Exporter le diagnostic ».
- Descriptions, help text, status and error messages: plain present tense: « Lyrimuse affiche… », « Activez cette option pour… ».
- No trailing period at the end of any string, even long ones. A period between two sentences is fine.
- **Keep it as short as the English.** French runs 20–30 % longer than English and many strings sit in narrow toolbars, segmented controls, tiles and the menu bar. Prefer the shorter word (« Paroles », « Réglages », « Fond » rather than « Arrière-plan »), drop articles in labels where natural (« Masquer les paroles » is fine, but « Taille » beats « Taille de la police » on a toolbar button whose title is already « Police »), and never add words the English doesn't have.
- Single-word labels must stay single words that fit: a long single word cannot wrap, it gets cut mid-word. When the English is one short word, look for a short French word (« Auto », « Fond », « Uni », « Mini »).
- The same thing is always called the same way. Pick the glossary term and reuse it everywhere, including in sentences that refer to a setting by name: the quoted name must match the label exactly.
- A placeholder that is already a duration (« ~12 h ») must not get its own « environ » in the template around it.

## Punctuation and spacing

- French typography: a **no-break space (U+00A0)** before « : », « ; », « ? », « ! » and inside guillemets « like this ». Never a plain space there (the line would break before the mark), never no space. Not before a colon inside a URL or a time (« 12:30 »).
- Apostrophe is the typographic ’ (U+2019), never the straight ' .
- Quotes « » (with the no-break spaces) for UI terms and quoted text.
- Keep `…` (single ellipsis character) where the source has it; buttons that open a dialog end with « … » like macOS (« Exporter… »).
- Keep keyboard symbols (⌘ ⌥ ⇧ ⌃), emoji, `\n`, Markdown (`**`, links) and URLs exactly.
- Numbers and units as in the English, keeping what the English does with the placeholder (« 30 s », « 2 h 5 min »). Decimal values come from the placeholder; do not write a decimal comma by hand in a format string.

## Placeholders and plurals

- Every `%@`, `%d`, `%lld`, `%.1f`, `%1$@`… in the source must appear in the translation with the same number, order of arguments and type. Never turn `%d` into `%@`.
- If French word order needs the arguments in a different order and the source has two or more arguments, switch to positional form (`%2$@ … %1$@`) keeping each argument's type.
- `%%` is a literal percent sign.
- French has singular and plural, and **0 takes the singular** (« 0 écoute »). Where the English entry has plural forms (one / other), give both: one is used for 0 and 1, other for every other count.

## Names that stay as they are

Lyrimuse, Last.fm, ListenBrainz, Discord, Telegram, Slack, Bark, ntfy, Server酱 (ServerChan), Apple Music, Spotify, YouTube Music, Genius, Cloudflare, GitHub, Sparkle, Touch Bar, Dock, Finder, Scrobble.
Chinese music services use the names in the English string (NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Soda Music…).

## Glossary

| Simplified Chinese | English | French |
|---|---|---|
| 歌词 | Lyrics | Paroles |
| 播放器 | Player | Lecteur |
| 歌词显示 | Lyrics Display | Affichage des paroles |
| 快捷键 | Keyboard Shortcuts | Raccourcis clavier |
| 通用 | General | Général |
| 关于 | About | À propos |
| 实验室 | Labs | Labo |
| 推送提醒 | Push Alerts | Alertes push |
| 网页推送 | Web Push | Push web |
| 关联平台 | Linked Platforms | Plateformes liées |
| 桌面悬浮歌词 / 悬浮歌词 | (Desktop) Floating Lyrics | Paroles flottantes |
| 灵动岛 | Notch | Encoche |
| 菜单栏 | Menu Bar | Barre des menus |
| 触控栏 | Touch Bar | Touch Bar |
| 歌词窗口 | Lyrics Window | Fenêtre des paroles |
| 歌词管理 | Lyrics Manager | Gestionnaire de paroles |
| 歌词库 | Lyrics Library | Bibliothèque de paroles |
| 歌词来源 / 歌词源 | Lyrics Sources | Sources de paroles |
| 译文 | Translation | Traduction |
| 罗马音 / 读音 | Romanization / Reading | Romanisation |
| 逐字歌词 | Word-by-word lyrics | Paroles mot à mot |
| 打卡 / scrobble | Scrobble | Scrobble (verb: scrobbler) |
| 收听 / 播放次数 | Listens / Plays | Écoutes |
| 收听记录 | Listening history | Historique d’écoute |
| 听歌报告 / 听歌小结 | Listening Report / Digest | Bilan d’écoute / Récap d’écoute |
| 推送渠道 | Push Channels | Canaux |
| 偏移 | Offset | Décalage |
| 封面 | Artwork | Illustration |
| 专辑 / 歌手 / 歌曲 | Album / Artist / Track | Album / Artiste / Morceau |
| 设置 | Settings | Réglages |
| 全部设置 | All Settings | Tous les réglages |
| 跟随系统 | Follow System | Système |
| 外观 | Appearance | Apparence |
| 背景 | Background | Fond |
| 字体 | Font | Police |
| 字号 | Font size | Taille |
| 颜色 | Color | Couleur |
| 内容 | Content | Contenu |
| 行为 | Behavior | Comportement |
| 布局 / 排版 | Layout | Disposition |
| 位置 | Position | Position |
| 跟随封面 | Artwork | Illustration |
| 纯色 / 渐变 / 毛玻璃 / 透明 | Solid / Gradient / Frosted Glass / Transparent | Uni / Dégradé / Dépoli / Transparent |
| 自动 | Auto | Auto |
| 完整尺寸 / 迷你尺寸 | Full Size / Mini Size | Taille complète / Mini |
| 卡拉OK效果 | Karaoke | Karaoké |
| 已开启 / 未开启 | On / Off | Activé / Désactivé |
| 辅助功能 | Accessibility | Accessibilité |
| 自动化 | Automation | Automatisation |
| 完全磁盘访问 | Full Disk Access | Accès complet au disque |
| 登录时打开 | Open at Login | Ouvrir à la connexion |
| 检查更新 | Check for Updates | Rechercher les mises à jour |
| 导入 / 导出 | Import / Export | Importer / Exporter |
| 候选 | Candidates | Résultats |
| 搜索 | Search | Rechercher |
| 重新匹配 | Rematch | Réassocier |
| 副行 | Second Line | Seconde ligne |
| 正在采用… | Applying… | Application… |
| 在 Last.fm 上喜欢 / 已在 Last.fm 上喜欢 | Love / Loved on Last.fm | Coup de cœur sur Last.fm / Coup de cœur ajouté sur Last.fm (Last.fm’s own French wording) |
| 取消 / 完成 / 好 | Cancel / Done / OK | Annuler / Terminé / OK |
| 保存 / 删除 / 重置 / 恢复默认 | Save / Delete / Reset / Restore Defaults | Enregistrer / Supprimer / Réinitialiser / Par défaut |
| 关闭 | Close | Fermer |
| 高级 | Advanced | Avancé |
| 诊断 | Diagnostics | Diagnostic |
