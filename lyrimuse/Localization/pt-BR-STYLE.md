# Brazilian Portuguese (pt-BR) translation style

Lyrimuse's UI strings live in `lyrimuse/Localization/Localizable.xcstrings`. The key of every entry is the Simplified Chinese source text; the `en` value is the closest reference for meaning and length, and the `es` / `fr` values show how other Romance languages solved the same length problem. Translate into natural Brazilian Portuguese as it would appear in a macOS app, then run `python3 lyrimuse/Localization/generate-strings.py`. The same pack is used for Portuguese from Portugal and every other region, so avoid slang and strongly regional words, but always use Brazilian spelling and grammar.

## Voice

- Address the user as **você**, like Apple's Brazilian macOS and iOS (“Escolha…”, “Abra…”, “Ative…”; possessive “seu / sua”). Never tu, never o senhor.
- Follow the wording Apple uses in Brazilian Portuguese macOS and Apple Music (Ajustes do Sistema, Música, música, letra, capa, Reproduzindo). When Apple has a term, use it.
- Labels, buttons, menu items, section titles: short noun phrases or an infinitive / imperative, **sentence case** (only the first word and proper names capitalized): “Buscar letra”, “Exportar diagnóstico”. Apple's own Brazilian menus use Title Case (“Abrir Mesmo Assim”); Lyrimuse's own strings don't, but when a sentence names an Apple UI element, quote Apple's exact capitalization (see the glossary).
- Descriptions, help text, status and error messages: plain present tense: “O Lyrimuse mostra…”, “Ative esta opção para…”. Click is “clique em”. App names take an article in running text when natural (“o Lyrimuse”, “o Spotify”).
- No trailing period at the end of any string, even long ones. A period between two sentences is fine.
- **Keep it as short as the English.** Portuguese runs 20–30 % longer than English and many strings sit in narrow toolbars, segmented controls, tiles and the menu bar. Prefer the shorter word (“Letra”, “Fundo”, “Fonte”), drop articles in labels where natural (“Mostrar letra”, not “Mostrar a letra”), and never add words the English doesn't have.
- Single-word labels must stay single words that fit: a long single word cannot wrap, it gets cut mid-word. When the English is one short word, look for a short Portuguese word (“Auto”, “Mini”, “Sim”); never invent abbreviations with a period unless Apple does — rephrase instead.
- The same thing is always called the same way. Pick the glossary term and reuse it everywhere, including in sentences that refer to a setting by name: the quoted name must match the label exactly.
- A placeholder that is already a duration (“~12 h”) must not get its own “cerca de” in the template around it.
- Status words follow what the thing is: the lyrics engine is a background service, so 运行中 / 未运行 is “Em execução / Parado”, not “Aberto”. A card title must not reuse the label of an option on the same page.

## Punctuation and spacing

- Quotation marks: typographic double quotes “like this” (U+201C … U+201D) for UI terms and quoted text, as Apple's Brazilian macOS does. Never straight " quotes, never « » or „ “.
- Apostrophe (rare in Portuguese, e.g. “d’água”) is the typographic ’ (U+2019), never the straight '.
- No space before : ; ? ! (unlike French).
- Keep `…` (single ellipsis character) where the source has it, with no space before it, like Apple's menus: “Exportar…”, “Escolher…”.
- Keep keyboard symbols (⌘ ⌥ ⇧ ⌃), emoji, `\n`, Markdown (`**`, links) and URLs exactly.
- Numbers and units as in the English, keeping what the English does with the placeholder (“30 s”, “2 h 5 min”). Decimal values come from the placeholder; do not write a decimal comma by hand in a format string. A hand-written decimal outside a placeholder uses a comma (“0,5 s”).
- A clock-time placeholder takes the article: “às %@” (at), “até as %@” (until), “a partir das %@” (from).

## Placeholders and plurals

- Every `%@`, `%d`, `%lld`, `%.1f`, `%1$@`… in the source must appear in the translation with the same number, order of arguments and type. Never turn `%d` into `%@`.
- If Portuguese word order needs the arguments in a different order and the source has two or more arguments, switch to positional form (`%2$@ … %1$@`) keeping each argument's type.
- `%%` is a literal percent sign.
- Brazilian Portuguese has singular and plural, and **0 takes the singular** (“0 música”, like French; CLDR pt one = 0 and 1). Where the English entry has plural forms (one / other), give both: `one` is used for 0 and 1, `other` for every other count. So the `one` form must read naturally with 0 too — when it would not (“0 música adicionada”), use a “Label: %d” construction in both forms (“Músicas adicionadas: %d”).
- Never mix a fixed plural into a singular form (“1 arquivo restaurado (1 adicionados…)” is wrong); use “label: number” for the secondary counts.
- Watch gender and number agreement around placeholders: when the noun is not known, prefer a construction that does not need agreement (“Músicas: %@” rather than an adjective that changes with the count).

## Names that stay as they are

Lyrimuse, Last.fm, ListenBrainz, Discord, Telegram, Slack, Bark, ntfy, Server酱 (ServerChan), Apple Music, Spotify, YouTube Music, Musixmatch, Genius, Cloudflare, GitHub, Sparkle, Touch Bar, Dock, Finder, Scrobble.
Chinese music services use the names in the English string (NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Soda Music…).

## Glossary

| Simplified Chinese | English | Brazilian Portuguese |
|---|---|---|
| 歌词 | Lyrics | Letra (plural Letras) |
| 播放器 | Player | Player (o player, os players) |
| 歌词显示 | Lyrics Display | Exibição da letra |
| 快捷键 | Keyboard Shortcuts | Atalhos de teclado |
| 通用 | General | Geral |
| 关于 | About | Sobre |
| 实验室 | Labs | Labs |
| 推送提醒 | Push Alerts | Alertas push |
| 网页推送 | Web Push | Push web |
| 关联平台 | Linked Platforms | Serviços conectados |
| 桌面悬浮歌词 / 悬浮歌词 | (Desktop) Floating Lyrics | Letra flutuante |
| 灵动岛 | Notch | Notch |
| 菜单栏 | Menu Bar | Barra de menus (Apple's pane name: “Barra de Menus”) |
| 触控栏 | Touch Bar | Touch Bar |
| 歌词窗口 | Lyrics Window | Janela da letra |
| 歌词管理 | Lyrics Manager | Gerenciador de letras |
| 歌词库 | Lyrics Library | Biblioteca de letras |
| 歌词来源 / 歌词源 | Lyrics Sources | Fontes de letras (always in full, never a bare “Fontes”, so it never reads as a font) |
| 译文 | Translation | Tradução |
| 罗马音 / 读音 | Romanization / Reading | Pronúncia |
| 逐字歌词 | Word-by-word lyrics | Palavra por palavra |
| 打卡 / scrobble | Scrobble | Scrobble (verb: fazer scrobble) |
| 收听 / 播放次数 | Listens / Plays | Reproduções |
| 收听记录 | Listening history | Histórico de reprodução |
| 听歌报告 / 听歌小结 | Listening Report / Digest | Relatório de audição / Resumo de audição |
| 推送渠道 | Push Channels | Canais |
| 偏移 | Offset | Deslocamento |
| 封面 | Artwork | Capa |
| 专辑 / 歌手 / 歌曲 | Album / Artist / Track | Álbum / Artista / Música (Apple: “música”; “faixa” only when the English insists on track number / track as a slot) |
| 正在播放 | Now Playing | Reproduzindo |
| 设置 | Settings | Ajustes |
| 系统设置 | System Settings | Ajustes do Sistema |
| 全部设置 | All Settings | Todos os ajustes |
| 跟随系统 | Follow System | Sistema |
| 外观 | Appearance | Aparência |
| 背景 | Background | Fundo |
| 字体 | Font | Fonte |
| 字号 | Font size | Tamanho (“Tamanho da tradução”, “Tamanho da pronúncia”) |
| 颜色 | Color | Cor |
| 内容 | Content | Conteúdo |
| 行为 | Behavior | Comportamento |
| 布局 / 排版 | Layout | Layout |
| 位置 | Position | Posição |
| 跟随封面 | Artwork | Capa |
| 纯色 / 渐变 / 毛玻璃 / 透明 | Solid / Gradient / Frosted Glass / Transparent | Sólido / Degradê / Vidro fosco / Transparente |
| 自动 | Auto | Auto |
| 完整尺寸 / 迷你尺寸 | Full Size / Mini Size | Completo / Mini |
| 卡拉OK效果 | Karaoke | Karaokê |
| 已开启 / 未开启 (status) | On / Off | Ativado / Desativado (very short status cells: Sim / Não) |
| 辅助功能 | Accessibility | Acessibilidade |
| 自动化 | Automation | Automação |
| 完全磁盘访问 | Full Disk Access | Acesso Total ao Disco |
| 通知 | Notifications | Notificações |
| 控制中心 | Control Center | Central de Controle |
| 隐私与安全性 | Privacy & Security | Privacidade e Segurança |
| 登录项 | Login Items | Itens de Início de Sessão (pane: “Itens de Início de Sessão e Extensões”) |
| 仍要打开 | Open Anyway | Abrir Mesmo Assim |
| 迷你播放器 | MiniPlayer | Minirreprodutor |
| 登录时打开 | Open at Login | Abrir ao iniciar sessão |
| 检查更新 | Check for Updates | Buscar atualizações |
| 导入 / 导出 | Import / Export | Importar / Exportar |
| 候选 | Candidates | Resultados |
| 搜索 | Search | Buscar |
| 重新匹配 | Rematch | Buscar de novo |
| 取消 / 完成 / 好 | Cancel / Done / OK | Cancelar / OK / OK |
| 保存 / 删除 / 重置 / 恢复默认 | Save / Delete / Reset / Restore Defaults | Salvar / Apagar / Redefinir / Restaurar padrões |
| 关闭 | Close | Fechar |
| 退出 | Quit | Encerrar |
| 高级 | Advanced | Avançado |
| 诊断 | Diagnostics | Diagnóstico |
| App | App | app (o app) |

Safari's developer settings in Brazilian Portuguese: “Mostrar recursos para desenvolvedores da web” (Ajustes › Avançado) and “Permitir JavaScript de Eventos Apple” (menu Desenvolvedor). Gatekeeper: “A Apple não pôde verificar se o app … está livre de algum malware…”, button “Abrir Mesmo Assim”.

When a term names macOS, Music, Safari or Gatekeeper UI, look up the exact Brazilian Portuguese string in the system's own resources instead of guessing: on this Mac the `.loctable` column is `pt_BR` or `pt`, and app folders are `pt.lproj` (Apple's `pt` is Brazilian; `pt_PT.lproj` is Portugal). A dump of 56 000 English → pt-BR pairs is at `~/.config/lyrimuse-i18n/pt-BR/apple-pt-BR.json`.
