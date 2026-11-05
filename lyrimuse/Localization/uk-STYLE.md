# Ukrainian (uk) translation style

Lyrimuse's UI strings live in `lyrimuse/Localization/Localizable.xcstrings`. The key of every entry is the Simplified Chinese source text; the `en` value is the closest reference for meaning and length, and the `de` / `fr` values show how other long languages solved the same length problem. Translate into natural Ukrainian as it would appear in a macOS app, then run `python3 lyrimuse/Localization/generate-strings.py`. The same pack is used for every Ukrainian region (uk, uk-UA…).

**Ukrainian is not a variant of Russian.** Never translate from the Russian strings or adapt them: the vocabulary differs widely (Параметри, Пошук, Відтворення, Вікно, Показувати — not Настройки, Поиск, Воспроизведение, Окно, Показывать). Calques from Russian (русизми) are mistakes: «на протязі» → «протягом», «приймати участь» → «брати участь», «слідуючий» → «наступний», «співпадати» → «збігатися», «являється» → «є», «в залежності від» → «залежно від», «на даний момент» → «наразі», «вірний» (in the sense of correct) → «правильний», «міроприємство», «так як» → «оскільки / бо».

## Voice

- Address the user as **ви**, lowercase in the middle of a sentence (ваш, вам), like Apple's Ukrainian macOS. Never ти.
- Follow the wording Apple uses in Ukrainian macOS and Apple Music (Параметри, Системні параметри, Музика, смуга меню, Текст, Зараз грає, Типово). When Apple has a term, use it.
- Labels, buttons, menu items, section titles: short noun phrases or an infinitive, **sentence case** (only the first word and proper names capitalized): «Знайти текст», «Експортувати діагностику». Buttons are verbs in the infinitive like Apple's («Зберегти», «Скасувати», «Готово»). Toggles are infinitives or nouns («Показувати переклад»).
- Descriptions, help text, status and error messages: plain present tense, neutral («Lyrimuse показує…», «Увімкніть, щоб…», «Не вдалося…»). Instructions use the imperative plural («Виберіть…», «Відкрийте…»). No filler.
- No trailing period at the end of any string, even long ones. A period between two sentences is fine.
- **Keep it as short as possible.** Ukrainian runs about 30 % longer than English and has long words (Відтворення, Синхронізація, Налаштування). Many strings sit in narrow toolbars, segmented controls, tiles, the Touch Bar and the menu bar, and a single long word cannot wrap — it gets cut in the middle. Prefer the shorter word Apple also uses («Текст», «Шрифт», «Розмір», «Тло», «Колір»), drop words the label does not need, and never add words the source does not have.
- Where the English is one short word, look for one short Ukrainian word («Авто», «Міні», «Увімк.», «Вимк.»). Abbreviate only the way Apple does («Увімк.», «Вимк.», «хв», «с», «год», «мс»); otherwise rephrase.
- An app is «програма», as in Apple's Ukrainian macOS («Програму «%@» не відкрито…»).
- **Case agreement with placeholders.** Ukrainian nouns decline; a name dropped into `%@` (player, song, setting, service) cannot take the right case ending. Put the name where it stays in the nominative: in «quotes», after a colon («Програвач: %@»), at the start of a sentence, or after a generic noun that takes the case instead («у програмі %@»). Brand and app names are not declined. Never write an ending glued to a placeholder («%@а»).
- **Counts.** Ukrainian has four plural categories (see below). Where a phrase around the number would have to agree in a way the plural forms cannot carry, switch to the label form «Додано: %d».
- The same thing is always called the same way. Pick the glossary term and reuse it everywhere, including in sentences that refer to a setting by name: the quoted name must match the label exactly, letter for letter (the label's own capitalization).
- A placeholder that is already a duration («~12 год») must not get its own «близько» in the template around it.
- Status words follow what the thing is: the lyrics engine is a background service, so 运行中 / 未运行 is «Працює / Не працює». A card title must not reuse the label of an option on the same page.
- Prepositions у / в and і / й alternate for euphony as in standard Ukrainian («у вікні», «в Apple Music»; «текст і переклад», «переклад й обкладинка» only when it reads better). Don't overthink it, but don't write «в вікні».

## Spelling and punctuation

- **Ukrainian letters only.** Never ы, э, ъ, ё (Russian). Use і, ї, є, ґ where Ukrainian spelling requires them. Never type a Latin i, a, o, e, c, p, x inside a Cyrillic word (they look the same but break search and spelling): the check rejects mixed-script words.
- **Apostrophe** is part of the word and is **ʼ (U+02BC, modifier letter apostrophe)**, as in Apple's Ukrainian macOS (памʼять, мʼякий, звʼязок, підʼєднати, імʼя). Never ' or ’.
- Quotation marks: «ялинки» (U+00AB … U+00BB) for UI names and quoted text; nested quotes „лапки“ (U+201E … U+201C) only inside an already quoted text. Never straight " quotes, never “…” as the outer pair.
- Dash: em dash with spaces on both sides « — ». Ranges of numbers use an en dash without spaces («1–5»).
- No space before : ; ? ! … . Keep `…` (single ellipsis character) where the source has it: «Експорт…», «Вибрати…».
- Keep keyboard symbols (⌘ ⌥ ⇧ ⌃), emoji, `\n`, Markdown (`**`, links) and URLs exactly.
- Numbers come from placeholders; do not write digit grouping by hand in a format string. A hand-written decimal outside a placeholder uses a comma («0,5 с»), a hand-written thousands separator a space («1 000»).
- Units without a period: с, мс, хв, год, пт («30 с», «2 год 5 хв», «12 пт»). «%@pt» from the source may stay «%@ пт».
- Dates: day before month, month name in the genitive («5 листопада», «20 жовтня»), year «5 листопада 2026 р.»; a month on its own or with a year is nominative («жовтень 2026», «за жовтень 2026»). Numeric short dates «20.10».
- A clock-time placeholder takes the preposition: «о %@» (at), «до %@» (until), «з %@» (from).

## Placeholders and plurals

- Every `%@`, `%d`, `%lld`, `%.1f`, `%1$@`… in the source must appear in the translation with the same number, order of arguments and type. Never turn `%d` into `%@`.
- If Ukrainian word order needs the arguments in a different order and the source has two or more arguments, switch to positional form (`%2$@ … %1$@`) keeping each argument's type.
- `%%` is a literal percent sign.
- **Ukrainian has four plural forms in the catalog.** Where the English entry has plural forms (one / other), write **all four**: `{"one": …, "few": …, "many": …, "other": …}`, each with the same placeholders. CLDR integer rules (same as Russian): **one** = ends in 1 but not 11 (1, 21, 101); **few** = ends in 2–4 but not 12–14 (2, 3, 4, 22, 104); **many** = everything else (0, 5–20, 11–14, 25, 111); **other** is only for fractions — write the genitive singular («1,5 трека»).
  - Example: one «%d трек» (1 трек, 21 трек), few «%d треки» (2 треки, 22 треки), many «%d треків» (5 треків, 11 треків, 0 треків), other «%d трека».
  - Example: one «%d прослуховування», few «%d прослуховування», many «%d прослуховувань», other «%d прослуховування».
  - Adjectives around the number agree too (one «%d новий артист», few «%d нові артисти», many «%d нових артистів»). If a form would need a word that does not fit all its numbers, use «Нових артистів: %d» in all four forms.

## Names that stay as they are

Lyrimuse, Last.fm, ListenBrainz, Discord, Telegram, Slack, Bark, ntfy, Server酱 (ServerChan), Apple Music, Spotify, YouTube Music, Musixmatch, Genius, Cloudflare, GitHub, Sparkle, Touch Bar, Dock, Finder, Safari, Chrome, Arc, Edge, Brave.
Chinese music services use the names in the English string (NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Soda Music…). App and service names are not declined: «у програмі Spotify», «у Last.fm».

## Glossary

Terms checked against Apple's Ukrainian macOS strings, Ukrainian tech media and other apps' Ukrainian UI (report: `~/.config/lyrimuse-i18n/uk/terms-research.md`).

| Simplified Chinese | English | Ukrainian |
|---|---|---|
| 歌词 | Lyrics | Текст (in running text: текст пісні; plural тексти) |
| 播放器 | Player | Програвач (Apple: Мініпрогравач; never «Гравець», that is a game player) |
| 歌手 | Artist | Виконавець |
| 歌曲 / 专辑 | Track / Album | Трек (counts) / пісня (in prose) / Альбом |
| 歌词显示 | Lyrics Display | Показ тексту |
| 快捷键 | Keyboard Shortcuts | Клавіатурні скорочення |
| 通用 | General | Загальні |
| 关于 | About | Про програму |
| 实验室 | Labs | Лабораторія |
| 推送提醒 | Push Alerts | Push-сповіщення |
| 网页推送 | Web Push | Веб-push |
| 关联平台 | Linked Platforms | Повʼязані сервіси |
| 桌面悬浮歌词 / 悬浮歌词 | (Desktop) Floating Lyrics | Плаваючий текст |
| 灵动岛 | Notch | Виріз (灵动岛歌词 = Текст у вирізі) |
| 菜单栏 | Menu Bar | смуга меню (Apple: «на смузі меню», «до смуги меню»; label start: Смуга меню; never «рядок меню») |
| 菜单栏歌词 | Menu Bar Lyrics | Текст на смузі меню |
| 触控栏 | Touch Bar | Touch Bar (preposition «на», as Apple: «Текст на Touch Bar») |
| 歌词窗口 | Lyrics Window | Вікно тексту |
| 歌词管理 | Lyrics Manager | Менеджер текстів |
| 歌词引擎 | Lyrics Engine | рушій текстів (not «движок», a Russian loan) |
| 歌词库 | Lyrics Library | Бібліотека текстів |
| 歌词来源 / 歌词源 | Lyrics Sources | Джерела текстів |
| 网页歌词 | Web Lyrics | Текст у браузері |
| 译文 | Translation | Переклад |
| 罗马音 / 读音 | Romanization / Reading | Вимова (Music.app) |
| 逐字歌词 | Word-by-word lyrics | Текст пословно; short: Пословно (paired with Порядково); 逐字时间轴 пословний таймінг |
| 时间轴 | Timing | Таймінг |
| 卡拉OK效果 | Karaoke | Ефект караоке (short: Караоке) |
| 打卡 / scrobble | Scrobble | скроблінг for the action and settings (verb скроблити, one б); counts and lists use «прослуховування» (Усього прослуховувань, Недавні прослуховування) |
| 收听 / 播放次数 | Listens / Plays | Прослуховування |
| 收听记录 | Listening history | Історія прослуховувань |
| 听歌报告 / 听歌小结 | Listening Report / Digest | Звіт про прослуховування / Підсумки прослуховувань |
| 足迹 / 收听足迹 | Footprints | Хроніка / Хроніка прослуховувань (not «Історія», it clashes with Історія прослуховувань) |
| 收听里程碑 / 下一个里程碑 | Listening Milestones | Рубежі / Наступний рубіж |
| 动态封面 | Animated Artwork | Анімована обкладинка |
| 正在播放 | Now Playing | Зараз грає (status: Відтворюється) |
| 榜单 | Charts | Чарти |
| 喜欢 (Apple Music) | Favorite | До Улюблених (state: В Улюблених; Apple: Додати до Улюблених) |
| 喜欢 (Last.fm Love) | Love | Вподобати (state: Вподобано) |
| 推送渠道 | Push Channels | Канали |
| 偏移 | Offset | Зсув |
| 封面 | Artwork | Обкладинка |
| 设置 | Settings | Параметри (the app's own settings window too; never Налаштування) |
| 系统设置 | System Settings | Системні параметри |
| 全部设置 | All Settings | Усі параметри |
| 默认 / 恢复默认 | Default / Restore Defaults | Типово / Відновити типові (never «за замовчуванням») |
| 跟随系统 | Follow System | Як у системі |
| 外观 | Appearance | Вигляд |
| 背景 | Background | Тло (neuter: прозоре тло) |
| 字体 / 字号 / 字重 | Font / Font size / Weight | Шрифт / Розмір («Розмір перекладу») / Товщина |
| 颜色 | Color | Колір |
| 内容 / 行为 | Content / Behavior | Вміст / Поведінка |
| 布局 / 排版 | Layout | Макет |
| 位置 | Position | Позиція |
| 对齐 | Alignment | Вирівнювання (Зліва / По центру / Справа) |
| 间距 | Spacing | Інтервал |
| 不透明度 | Opacity | Непрозорість |
| 纯色 / 渐变 / 毛玻璃 / 透明 | Solid / Gradient / Frosted Glass / Transparent | Суцільне / Градієнт / Матове скло / Прозоре (agree with neuter «тло») |
| 自动 | Auto | Авто |
| 完整尺寸 / 迷你尺寸 | Full Size / Mini Size | Повний / Міні |
| 已开启 / 未开启 (status) | On / Off | Увімкнено / Вимкнено (very short status cells: Увімк. / Вимк.) |
| 运行中 / 未运行 | Running / Not running | Працює / Не працює |
| 辅助功能 | Accessibility | Доступність |
| 自动化 | Automation | Автоматизація |
| 完全磁盘访问 | Full Disk Access | Повний доступ до диска |
| 通知 | Notifications | Сповіщення |
| 控制中心 | Control Center | Центр керування |
| 隐私与安全性 | Privacy & Security | Приватність і безпека |
| 登录项 | Login Items | Автозапуск (pane: «Автозапуск і розширення») |
| 登录时打开 | Open at Login | Відкривати під час входу |
| 仍要打开 | Open Anyway | Все одно відкрити |
| 迷你播放器 | MiniPlayer | Мініпрогравач |
| 检查更新 | Check for Updates | Перевірити оновлення |
| 导入 / 导出 | Import / Export | Імпорт / Експорт (buttons: Імпортувати / Експортувати) |
| 候选 | Candidates | Варіанти |
| 搜索 | Search | Пошук (button: Шукати / Знайти) |
| 重新匹配 | Rematch | Підібрати знову |
| 取消 / 完成 / 好 | Cancel / Done / OK | Скасувати / Готово / OK |
| 保存 / 删除 / 重置 | Save / Delete / Reset | Зберегти / Видалити / Скинути |
| 关闭 / 退出 | Close / Quit | Закрити / Завершити |
| 高级 | Advanced | Додатково |
| 诊断 | Diagnostics | Діагностика |
| 重试 | Retry | Повторити |
| 密钥 / 令牌 / 钥匙串 | Key / Token / Keychain | Ключ / Токен / Вʼязка ключів |
| 深链 | Deep links | Deep links |
| 快捷指令 | Shortcuts (app) | Швидкі команди |
| 预览 | Preview | Перегляд |
| App | App | програма |

System UI names, exactly as in Ukrainian macOS (checked on this Mac):
- Safari: Параметри › Додатково › «показувати функції для веброзробників»; Розробка › «дозволити JavaScript із подій Apple» (Safari's Ukrainian checkboxes are lowercase; quote them exactly).
- Chrome / Brave: Перегляд › Для розробників › «Дозволити JavaScript від подій Apple». Arc keeps its English menu names in every language («View › Developer › Allow JavaScript from Apple Events»). Edge: Переглянути › Для розробників › «Дозволити сценарії JavaScript від Apple».
- Gatekeeper: «Apple не може підтвердити, що «…» не містить зловмисного програмного забезпечення…», button «Все одно відкрити».
- System Settings: «Приватність і безпека», «Загальні › Автозапуск і розширення», «Центр керування», «Смуга меню», «Брандмауер».

When a term names macOS, Music, Safari or Gatekeeper UI, look up the exact Ukrainian string in the system's own resources instead of guessing: on this Mac the `.loctable` column is `uk` and app folders are `uk.lproj`. A dump of 57 000 English → Ukrainian pairs is at `~/.config/lyrimuse-i18n/uk/apple-uk.json`. Apple's own strings put a no-break space after short words and a no-break hyphen (‑); in Lyrimuse write ordinary spaces and hyphens.
