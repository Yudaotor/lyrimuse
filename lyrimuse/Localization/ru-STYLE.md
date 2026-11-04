# Russian (ru) translation style

Lyrimuse's UI strings live in `lyrimuse/Localization/Localizable.xcstrings`. The key of every entry is the Simplified Chinese source text; the `en` value is the closest reference for meaning and length, and the `de` / `fr` values show how other long languages solved the same length problem. Translate into natural Russian as it would appear in a macOS app, then run `python3 lyrimuse/Localization/generate-strings.py`. The same pack is used for every Russian region (ru, ru-RU, ru-UA, ru-KZ…).

## Voice

- Address the user as **вы**, lowercase, like Apple's current Russian macOS and iOS. Never ты, never capitalized Вы.
- Follow the wording Apple uses in Russian macOS and Apple Music (Настройки, Системные настройки, Музыка, строка меню, текст песни, Исполняется). When Apple has a term, use it.
- Labels, buttons, menu items, section titles: short noun phrases or an infinitive / imperative, **sentence case** (only the first word and proper names capitalized): «Найти текст», «Экспортировать диагностику». Buttons are verbs like Apple's («Сохранить», «Отменить», «Готово»).
- Descriptions, help text, status and error messages: plain present tense, neutral and impersonal where natural («Lyrimuse показывает…», «Включите, чтобы…», «Не удалось…»). No filler, no «Обратите внимание».
- No trailing period at the end of any string, even long ones. A period between two sentences is fine.
- **Keep it as short as possible.** Russian runs about 30 % longer than English and has long words (Воспроизведение, Синхронизация). Many strings sit in narrow toolbars, segmented controls, tiles, the Touch Bar and the menu bar, and a single long word cannot wrap — it gets cut in the middle. Prefer the shorter word that Apple also uses («Текст» rather than «Текст песни» where the context already says lyrics, «Шрифт», «Размер», «Фон», «Цвет»), drop words the label does not need, and never add words the source does not have.
- Where the English is one short word, look for one short Russian word («Авто», «Мини», «Вкл.», «Выкл.»). Abbreviate only the way Apple does («Вкл.», «Выкл.», «мин», «с», «ч», «мс»); otherwise rephrase.
- **Case agreement with placeholders.** Russian nouns decline; a name dropped into `%@` (player, song, setting, service) cannot take the right case ending. Put the name where it stays in the nominative: in «quotes», after a colon («Плеер: %@»), at the start of a sentence, or after a generic noun that takes the case instead («в приложении «%@»», «в плеере %@» only if the name is indeclinable — app names usually are). Never write an ending glued to a placeholder («%@а»).
- **Counts.** Russian has four plural categories (see below). Where a phrase around the number would have to agree in a way the plural forms cannot carry (adjectives, verbs: «добавлено 5 новых»), switch to the label form «Добавлено: %d».
- The same thing is always called the same way. Pick the glossary term and reuse it everywhere, including in sentences that refer to a setting by name: the quoted name must match the label exactly, letter for letter (the label's own case and capitalization).
- A placeholder that is already a duration («~12 ч») must not get its own «около» in the template around it.
- Status words follow what the thing is: the lyrics engine is a background service, so 运行中 / 未运行 is «Работает / Не работает», not «Открыт». A card title must not reuse the label of an option on the same page.

## Spelling and punctuation

- Write **е**, not ё, as Apple's Russian macOS does («Еще раз», «Все равно открыть», «Темный режим»).
- Quotation marks: «ёлочки» (U+00AB … U+00BB) for UI names and quoted text; nested quotes „лапки“ (U+201E … U+201C): «Нажмите „Готово“» only inside an already quoted text. Never straight " quotes, never “…” as the outer pair.
- Dash: em dash with spaces on both sides « — ». Ranges of numbers use an en dash without spaces («1–5»).
- No space before : ; ? ! … (unlike French). Keep `…` (single ellipsis character) where the source has it: «Экспорт…», «Выбрать…».
- Apostrophe (rare, foreign names) is the typographic ’.
- Keep keyboard symbols (⌘ ⌥ ⇧ ⌃), emoji, `\n`, Markdown (`**`, links) and URLs exactly.
- Numbers come from placeholders; do not write digit grouping by hand in a format string. A hand-written decimal outside a placeholder uses a comma («0,5 с»), a hand-written thousands separator a space («1 000»).
- Units without a period: с, мин, ч, мс, пт («30 с», «2 ч 5 мин», «12 пт»). «%@pt» from the source may stay «%@ пт».
- Dates: day before month, month name in the genitive («4 ноября», «20 октября»); a month on its own or with a year is nominative («октябрь 2026»). Numeric short dates «20.10».
- A clock-time placeholder takes the preposition: «в %@» (at), «до %@» (until), «с %@» (from).

## Placeholders and plurals

- Every `%@`, `%d`, `%lld`, `%.1f`, `%1$@`… in the source must appear in the translation with the same number, order of arguments and type. Never turn `%d` into `%@`.
- If Russian word order needs the arguments in a different order and the source has two or more arguments, switch to positional form (`%2$@ … %1$@`) keeping each argument's type.
- `%%` is a literal percent sign.
- **Russian has four plural forms in the catalog.** Where the English entry has plural forms (one / other), write **all four**: `{"one": …, "few": …, "many": …, "other": …}`, each with the same placeholders. CLDR integer rules: **one** = ends in 1 but not 11 (1, 21, 101); **few** = ends in 2–4 but not 12–14 (2, 3, 4, 22, 104); **many** = everything else (0, 5–20, 11–14, 25, 111); **other** is only for fractions — write it the same as **few** («трека», genitive singular, which is what Russian uses after a fraction: «1,5 трека»).
  - Example: one «%d трек» (1 трек, 21 трек), few «%d трека» (2 трека, 22 трека), many «%d треков» (5 треков, 11 треков, 0 треков), other «%d трека».
  - Example: one «%d прослушивание», few «%d прослушивания», many «%d прослушиваний», other «%d прослушивания».
  - Adjectives and verbs around the number agree too (one «%d новый артист», few «%d новых артиста», many «%d новых артистов»). If a form would need a word that does not fit all its numbers, use «Новых артистов: %d» in all four forms.

## Names that stay as they are

Lyrimuse, Last.fm, ListenBrainz, Discord, Telegram, Slack, Bark, ntfy, Server酱 (ServerChan), Apple Music, Spotify, YouTube Music, Musixmatch, Genius, Cloudflare, GitHub, Sparkle, Touch Bar, Dock, Finder, Safari, Chrome, Arc, Edge, Brave.
Chinese music services use the names in the English string (NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Soda Music…). App and service names are not declined: «в приложении Spotify», «в Last.fm».

## Glossary

| Simplified Chinese | English | Russian |
|---|---|---|
| 歌词 | Lyrics | Текст песни (short labels and compounds: Текст; plural тексты) |
| 播放器 | Player | Плеер |
| 歌词显示 | Lyrics Display | Показ текста |
| 快捷键 | Keyboard Shortcuts | Сочетания клавиш |
| 通用 | General | Основные |
| 关于 | About | О программе |
| 实验室 | Labs | Лаборатория |
| 推送提醒 | Push Alerts | Push-уведомления |
| 网页推送 | Web Push | Веб-push |
| 关联平台 | Linked Platforms | Связанные сервисы |
| 桌面悬浮歌词 / 悬浮歌词 | (Desktop) Floating Lyrics | Плавающий текст |
| 灵动岛 | Notch | Вырез |
| 菜单栏 | Menu Bar | Строка меню (in a sentence: строка меню) |
| 触控栏 | Touch Bar | Touch Bar (preposition «в», as Apple: «Текст в Touch Bar», «в панели Touch Bar») |
| 歌词窗口 | Lyrics Window | Окно текста |
| 歌词管理 | Lyrics Manager | Менеджер текстов |
| 歌词库 | Lyrics Library | Библиотека текстов |
| 歌词来源 / 歌词源 | Lyrics Sources | Источники текстов |
| 译文 | Translation | Перевод |
| 罗马音 / 读音 | Romanization / Reading | Произношение (Apple Music: «Перевод и произношение текстов песен») |
| 逐字歌词 | Word-by-word lyrics | Текст по словам; 逐字时间轴 тайминг по словам |
| 时间轴 | Timing | Тайминг |
| 打卡 / scrobble | Scrobble | Скробблинг for the action and settings (verb скробблить); counts and lists use «прослушивания», as Last.fm’s own Russian site does (Всего прослушиваний, Недавние прослушивания) |
| 收听 / 播放次数 | Listens / Plays | Прослушивания |
| 收听记录 | Listening history | История прослушиваний |
| 听歌报告 / 听歌小结 | Listening Report / Digest | Отчет о прослушивании / Итоги прослушивания |
| 推送渠道 | Push Channels | Каналы |
| 偏移 | Offset | Сдвиг |
| 封面 | Artwork | Обложка |
| 专辑 / 歌手 / 歌曲 | Album / Artist / Track | Альбом / Артист / Трек (Apple Music uses песня; both fine, pick трек for counts) |
| 正在播放 | Now Playing | Исполняется |
| 设置 | Settings | Настройки |
| 系统设置 | System Settings | Системные настройки |
| 全部设置 | All Settings | Все настройки |
| 跟随系统 | Follow System | Как в системе |
| 外观 | Appearance | Оформление |
| 背景 | Background | Фон |
| 字体 | Font | Шрифт |
| 字号 | Font size | Размер («Размер перевода», «Размер произношения») |
| 字重 | Weight | Насыщенность |
| 颜色 | Color | Цвет |
| 内容 | Content | Содержимое |
| 行为 | Behavior | Поведение |
| 布局 / 排版 | Layout | Макет |
| 位置 | Position | Положение |
| 对齐 | Alignment | Выравнивание |
| 间距 | Spacing | Интервал |
| 不透明度 | Opacity | Непрозрачность |
| 跟随封面 | Artwork | Как обложка |
| 纯色 / 渐变 / 毛玻璃 / 透明 | Solid / Gradient / Frosted Glass / Transparent | Сплошной / Градиент / Матовое стекло / Прозрачный |
| 自动 | Auto | Авто |
| 完整尺寸 / 迷你尺寸 | Full Size / Mini Size | Полный / Мини |
| 卡拉OK效果 | Karaoke | Караоке |
| 已开启 / 未开启 (status) | On / Off | Включено / Выключено (very short status cells: Вкл. / Выкл.) |
| 运行中 / 未运行 | Running / Not running | Работает / Не работает |
| 辅助功能 | Accessibility | Универсальный доступ |
| 自动化 | Automation | Автоматизация |
| 完全磁盘访问 | Full Disk Access | Доступ к диску |
| 通知 | Notifications | Уведомления |
| 控制中心 | Control Center | Пункт управления |
| 隐私与安全性 | Privacy & Security | Конфиденциальность и безопасность |
| 登录项 | Login Items | Объекты входа (pane: «Объекты входа и расширения») |
| 仍要打开 | Open Anyway | Все равно открыть |
| 迷你播放器 | MiniPlayer | Мини-плеер |
| 登录时打开 | Open at Login | Открывать при входе |
| 检查更新 | Check for Updates | Проверить обновления |
| 导入 / 导出 | Import / Export | Импорт / Экспорт (buttons: Импортировать / Экспортировать) |
| 候选 | Candidates | Варианты |
| 搜索 | Search | Поиск (button: Найти) |
| 重新匹配 | Rematch | Подобрать заново |
| 取消 / 完成 / 好 | Cancel / Done / OK | Отменить / Готово / ОК |
| 保存 / 删除 / 重置 / 恢复默认 | Save / Delete / Reset / Restore Defaults | Сохранить / Удалить / Сбросить / По умолчанию |
| 关闭 | Close | Закрыть |
| 退出 | Quit | Завершить |
| 高级 | Advanced | Дополнительно |
| 诊断 | Diagnostics | Диагностика |
| 重试 | Retry | Повторить |
| 密钥 | Key | Ключ |
| 钥匙串 | Keychain | Связка ключей |
| 令牌 | Token | Токен |
| 足迹 | Footprints | Хроника (收听足迹 = Хроника прослушиваний; «Следы» reads as footprints / traces, «История» clashes with История прослушиваний) |
| 收听里程碑 | Listening Milestones | Рубежи (下一个里程碑 = Следующий рубеж; Russian news says a play count «перешёл рубеж») |
| 深链 | Deep links | Deep links |
| 快捷指令 | Shortcuts (app) | Быстрые команды |
| App | App | приложение |

System UI names, exactly as in Russian macOS:
- Safari: Настройки › Дополнения › «Показывать функции для веб‑разработчиков»; Разработка › «Разрешить событиям Apple Events выполнять JavaScript».
- Chrome / Arc / Brave: Вид › Разработчикам › «Разрешить JavaScript из событий Apple». Edge: Просмотр › Разработчик › «Разрешить JavaScript из событий Apple».
- Gatekeeper: «Apple не удалось подтвердить, что … не содержит вредоносного ПО…», button «Все равно открыть».
- Music: «Исполняется», «Мини-плеер»; System Settings: «Конфиденциальность и безопасность», «Основные › Объекты входа и расширения», «Пункт управления», «Строка меню».

When a term names macOS, Music, Safari or Gatekeeper UI, look up the exact Russian string in the system's own resources instead of guessing: on this Mac the `.loctable` column is `ru` and app folders are `ru.lproj`. A dump of 57 000 English → Russian pairs is at `~/.config/lyrimuse-i18n/ru/apple-ru.json`. Apple's own strings put a no-break space after short words («по умолчанию»); in Lyrimuse write ordinary spaces.
