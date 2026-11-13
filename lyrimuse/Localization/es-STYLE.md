# Spanish (es) translation style

Lyrimuse's UI strings live in `lyrimuse/Localization/Localizable.xcstrings`. The key of every entry is the Simplified Chinese source text; the `en` value is the closest reference for meaning and length. Translate into natural, neutral Spanish as it would appear in a macOS app, then run `python3 lyrimuse/Localization/generate-strings.py`.

## Voice

- Neutral Spanish that reads well in Spain and Latin America: address the user as **tú** (never usted, never vosotros), avoid regional words (no "ordenador" / "computadora": say "Mac").
- Follow the wording Apple uses in Spanish macOS (Ajustes del Sistema, Música, Finder). When Apple has a term, use it.
- Labels, buttons, menu items, section titles: short noun phrases or an infinitive, sentence case (only the first word and proper names capitalized): «Buscar letra», «Exportar diagnóstico».
- Descriptions, help text, status and error messages: plain present tense, second person (tú) when the user does something: «Lyrimuse muestra…», «Activa esta opción para…».
- No trailing period at the end of any string, even long ones. A period between two sentences is fine.
- **Keep it as short as the English.** Spanish runs longer than English and many strings sit in narrow toolbars, segmented controls and the menu bar: prefer the shorter word («Letra» over «Letras de las canciones», «Ajustes» over «Configuración»), drop articles in labels where natural («Ocultar letra», not «Ocultar la letra») and never add words the English doesn't have.

## Punctuation and spacing

- Opening marks are required: «¿…?», «¡…!».
- Quotes « » for UI terms («Letra flotante»), “ ” for quoted speech.
- Keep `…` (single ellipsis character) where the source has it; buttons that open a dialog end with «…» like macOS («Exportar…»).
- Keep keyboard symbols (⌘ ⌥ ⇧ ⌃), emoji, `\n`, Markdown (`**`, links) and URLs exactly.
- Numbers and units as in the English («30 s», «2 h 5 min», «50 %» is fine but keep what the English does with the placeholder).

## Placeholders and plurals

- Every `%@`, `%d`, `%lld`, `%.1f`, `%1$@`… in the source must appear in the translation with the same number, order of arguments and type. Never turn `%d` into `%@`.
- If Spanish word order needs the arguments in a different order and the source has two or more arguments, switch to positional form (`%2$@ … %1$@`) keeping each argument's type.
- `%%` is a literal percent sign.
- Spanish has singular and plural. Where the English entry has plural forms (one / other), give both: one for exactly 1, other for every other count (including 0).

## Names that stay as they are

Lyrimuse, Last.fm, ListenBrainz, Discord, Telegram, Slack, Bark, ntfy, Server酱 (ServerChan), Apple Music, Spotify, YouTube Music, Genius, Cloudflare, GitHub, Sparkle, Touch Bar, Dock, Finder, Scrobble.
Chinese music services use the names in the English string (NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Soda Music…).

## Glossary

| Simplified Chinese | English | Spanish |
|---|---|---|
| 歌词 | Lyrics | Letra (letras when several songs) |
| 播放器 | Player | Reproductor |
| 歌词显示 | Lyrics Display | Mostrar letra |
| 快捷键 | Keyboard Shortcuts | Atajos de teclado |
| 通用 | General | General |
| 关于 | About | Acerca de |
| 实验室 | Labs | Laboratorio |
| 推送提醒 | Push Alerts | Avisos push |
| 网页推送 | Web Push | Push web |
| 关联平台 | Linked Platforms | Plataformas vinculadas |
| 桌面悬浮歌词 / 悬浮歌词 | (Desktop) Floating Lyrics | Letra flotante (en el escritorio) |
| 灵动岛 | Notch | Notch |
| 菜单栏 | Menu Bar | Barra de menús |
| 歌词窗口 | Lyrics Window | Ventana de letra |
| 歌词管理 | Lyrics Manager | Gestor de letras |
| 歌词库 | Lyrics Library | Biblioteca de letras |
| 歌词来源 / 歌词源 | Lyrics Sources | Fuentes de letras |
| 译文 | Translation | Traducción |
| 罗马音 | Romanization | Romanización |
| 逐字歌词 | Word-by-word lyrics | Letra palabra por palabra |
| 打卡 / scrobble | Scrobble | Scrobble (verb: hacer scrobble) |
| 收听记录 | Listening history | Historial de escucha |
| 听歌报告 / 听歌小结 | Listening Report / Digest | Informe de escucha / Resumen de escucha |
| 推送渠道 | Push Channels | Canales |
| 偏移 | Offset | Desfase |
| 封面 | Artwork | Ilustración |
| 专辑 / 歌手 / 歌曲 | Album / Artist / Track | Álbum / Artista / Canción |
| 设置 | Settings | Ajustes |
| 跟随系统 | Follow System | Según el sistema |
| 外观 | Appearance | Aspecto |
| 辅助功能 | Accessibility | Accesibilidad |
| 自动化 | Automation | Automatización |
| 完全磁盘访问 | Full Disk Access | Acceso total al disco |
| 登录时打开 | Open at Login | Abrir al iniciar sesión |
| 检查更新 | Check for Updates | Buscar actualizaciones |
| 导入 / 导出 | Import / Export | Importar / Exportar |
| 候选 | Candidates | Candidatas |
| 搜索 | Search | Buscar |
| 取消 / 完成 / 好 | Cancel / Done / OK | Cancelar / OK / Aceptar |
| 保存 / 删除 / 重置 | Save / Delete / Reset | Guardar / Eliminar / Restablecer |
| 关闭 | Close | Cerrar |
| 高级 | Advanced | Avanzado |
| 诊断 | Diagnostics | Diagnóstico |
