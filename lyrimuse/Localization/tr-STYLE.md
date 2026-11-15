# Turkish (tr) translation style

Lyrimuse's UI strings live in `lyrimuse/Localization/Localizable.xcstrings`. The key of every entry is the Simplified Chinese source text; translate from it, use the `en` value as the closest reference for meaning and length, and the `ja` / `de` values to see how a verb-final language without plurals (Japanese) and a long-word Latin language (German) solved the same string. Translate into natural Turkish as it would appear in a macOS app, then run `python3 lyrimuse/Localization/generate-strings.py`. The same pack is used for every Turkish region (tr, tr-TR, tr-CY).

## Voice

- Address the user with the polite **siz**, like Apple's Turkish macOS: instructions use the -in / -ın imperative (“Ayarlar’ı açın”, “Bir parça çalın”), questions use -iniz / musunuz (“…silmek istediğinizden emin misiniz?”), possessives use -iniz (“Mac’iniz”). Never sen.
- Buttons and menu items use the bare verb stem, as Apple does: Aç, Kapat, Sil, Kaydet, Ekle, Vazgeç, Bitti, Yeniden Dene. Confirmation titles use the passive question: “Silinsin mi?”, “Kaydedilsin mi?”.
- Follow the wording Apple uses in Turkish macOS and Music (Ayarlar, Sistem Ayarları, Menü Çubuğu, Şarkı Sözleri, Şu An Çalınan, Parça). When Apple has a term, use it — a dump of 57 000 English → Turkish pairs from this Mac is at `~/.config/lyrimuse-i18n/tr/apple-tr.json`.
- Descriptions, help text, status and error messages: plain present tense, no filler (“Lyrimuse şarkı sözlerini … gösterir”, “Bunu açarsanız …”). Do not open every sentence with “Not:”.
- No trailing period at the end of any string, even long ones (Apple's Turkish keeps them; Lyrimuse does not). A period between two sentences is fine.
- **Keep it as short as possible.** Turkish words grow with suffixes and many strings sit in narrow toolbars, segmented controls, tiles, the Touch Bar and the menu bar. Drop words the label does not need (“Sözleri Göster” where the context already says lyrics; “Sözler” is fine as a tab title), use Apple's short forms (Açık / Kapalı, Bitti, Vazgeç, Renk, Font, Boyut, Otomatik), and never add words the source doesn't have. Abbreviations only where Apple uses them (sn, dk, sa).
- The same thing is always called the same way. Pick the glossary term and reuse it everywhere, including in sentences that refer to a setting by name: the quoted name must match the label exactly, letter for letter and in the same capitalization.
- A placeholder that is already a duration (“~12 sa”) must not get its own “yaklaşık” in the template around it.
- Status words follow what the thing is: the lyrics engine is a background service, so 运行中 / 未运行 is “Çalışıyor / Çalışmıyor”, not “Açık”. A card title must not reuse the label of an option on the same page.

## Capitalization

- Follow the capitalization of the English string, as Apple's Turkish does (98 % of Title Case English stays Title Case, 97 % of sentence case stays sentence case):
  - **Title Case** for buttons, menu items, window and sheet titles, section and card headers, tab and segment titles where the English is Title Case: every word capitalized except ve, veya, ile, için, de / da, ki (“Menü Çubuğunda Göster”, “Yine de Aç”, “Şarkı Sözü Penceresi”).
  - **Sentence case** for settings row labels written in sentence case in English, descriptions, hints, errors and anything that reads as a sentence.
- **i / İ and ı / I are different letters.** The capital of i is **İ** (İptal, İndir, İzin Ver, İleri Düzey); the capital of ı is **I** (Işık, Isı). Never write “Iptal” or “Indir”. When a word is capitalized in Title Case, check this on every word that starts with i.
- Month and weekday names are capitalized when they name a date (15 Kasım 2026), lowercase when used generically.
- Lyrimuse's own feature names are ordinary nouns inside a sentence (lowercase, no apostrophe: “çentik sözlerini açın”); they take Title Case only as labels and headers.

## Suffixes after names, numbers and placeholders

Turkish attaches case and possessive suffixes to words, and the suffix vowel and consonant follow the last syllable of that word (vowel harmony, consonant assimilation). That has two consequences.

**Proper names, brands, abbreviations and numbers you write out** take the suffix after a typographic apostrophe ’ (U+2019), following TDK and Apple: Spotify’da, Last.fm’e, Discord’da, Touch Bar’da, Mac’inizde, Finder’da, Sistem Ayarları’nda, macOS 14’te. **Lyrimuse** is suffixed by its pronunciation (/lirimyuz/): Lyrimuse’u, Lyrimuse’a, Lyrimuse’da, Lyrimuse’dan, Lyrimuse’un, Lyrimuse’la.

**A placeholder (`%@`, `%d`, `%lld`, `%1$@`…) never takes a suffix.** The suffix depends on the value that ends up there (a song title, an app name, a number), so any fixed suffix is wrong for part of the values. Apple's Turkish never does it either (0 of 14 064 placeholders). The checker rejects `%@’u`, `%d’den`, `%@daki`. Rewrite instead, in this order of preference:

1. **Apposition noun carrying the suffix** (what the thing is): “%@ uygulamasında”, ““%@” parçasını”, “%@ sanatçısının”, “%@ kaynağından”, “%@ hesabına”, “%@ tarihinde”, “%@ çalarında”.
2. **A postposition that needs no case**: “%@ için”, “%@ ile”, “%@ tarafından”, “%@ üzerinden”.
3. **Colon, placeholder at the end in the nominative** (menu items, buttons, short status): “Aç: %@”, “Şu an çalınan: %@”, “Son güncelleme: %@”.
4. **Placeholder as a modifier**, the suffix goes on the following noun: “%@ Ayarları”, ““%@” şarkı sözleri”.
5. **“%@ adlı …”** for people and user-chosen names: “%@ adlı kullanıcı”, “%@ adlı kanal”.
6. **Numbers**: put the counted noun after the number and let the noun carry the suffix: “%d dakikadan uzun”, “%d parçayı”, “en az %d dakika”. Never “%d’den”, never a bare number with a suffix.

## Punctuation and spacing

- Quotation marks: “like this” (U+201C … U+201D), as Apple's Turkish macOS does. Never straight " quotes, « », „ “ or 「」.
- Apostrophe is always the typographic ’ (U+2019), never the straight '.
- No space before : ; ? ! and no space before ….
- Keep `…` (single ellipsis character) where the source has it: “Dışa Aktar…”, “Seç…”.
- Keep keyboard symbols (⌘ ⌥ ⇧ ⌃), emoji, `\n`, Markdown (`**`, links) and URLs exactly.
- Numbers come from placeholders; do not write digit grouping by hand in a format string. A hand-written decimal uses a comma (“0,5 sn”), a thousands separator a dot (“1.000”).
- **Percent sign goes before the number**: “%50”. In a format string write `%%%d` / `%%%@` (percent first).
- Units: saniye / dakika / saat in running text; in tight controls the Apple abbreviations sn, dk, sa (“30 sn”, “5 dk”, “2 sa 5 dk”). “ms” stays “ms”.
- Times are 14:30 (colon), dates day-month-year (“15 Kasım 2026”, “15.11”). Leave dates and times to the formatter wherever the source uses a placeholder.
- Lists end with “ve” and no comma before it: “Spotify, Apple Music ve QQ Music”.

## Placeholders and plurals

- Every `%@`, `%d`, `%lld`, `%.1f`, `%1$@`… in the source must appear in the translation with the same number, order of arguments and type. Never turn `%d` into `%@`.
- Turkish is verb-final; if the arguments need a different order and the source has two or more, switch to positional form (`%2$@ … %1$@`) keeping each argument's type.
- `%%` is a literal percent sign.
- **A noun after a number stays singular** (“3 parça”, “12 dinleme”, “%d sanatçı”). Where the English entry has plural forms (one / other), write **one** string, exactly as the Japanese, Korean, Vietnamese and Thai entries do. Never write “%d parçalar”.

## Names that stay as they are

Lyrimuse, Last.fm, ListenBrainz, Discord, Telegram, Slack, Bark, ntfy, Server酱 (ServerChan), Apple Music, Spotify, YouTube Music, Genius, Musixmatch, Cloudflare, GitHub, Sparkle, Touch Bar, Dock, Finder, Safari, Chrome, Arc, Edge, Spotlight, Wi‑Fi, AirPlay, iCloud, Mac, macOS, Dynamic Island, Webhook, URL, API.
Chinese music services use the names in the English string (NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Soda Music…). DingTalk and Feishu (Lark) ship a Turkish UI only partially; quote their option names in English as they appear in their English UI.

## Glossary

| Simplified Chinese | English | Turkish |
|---|---|---|
| 歌词 | Lyrics | Şarkı sözleri (labels: Şarkı Sözleri; very short: Sözler); as a modifier: şarkı sözü |
| 播放器 | Player | Çalar (Apple: Mini Çalar); “%@ çaları” only where needed |
| 歌曲 / 曲目 | Song / Track | Parça (Apple Music, Last.fm) |
| 歌手 | Artist | Sanatçı |
| 专辑 | Album | Albüm |
| 封面 | Artwork | Kapak |
| 动态封面 | Animated Artwork | Hareketli Kapak |
| 歌词显示 | Lyrics Display | Şarkı Sözü Görünümü |
| 快捷键 | Keyboard Shortcuts | Klavye Kestirmeleri (short: Kestirmeler) |
| 通用 | General | Genel |
| 关于 | About | Hakkında |
| 实验室 | Labs | Deneysel |
| 推送提醒 | Push Alerts | Anlık Bildirimler |
| 网页推送 | Web Push | Web Anlık Bildirimleri |
| 关联平台 | Linked Platforms | Bağlı Hizmetler |
| 桌面悬浮歌词 / 悬浮歌词 | (Desktop) Floating Lyrics | Yüzen Sözler (in sentences: yüzen şarkı sözleri) |
| 灵动岛 | Notch | Çentik |
| 灵动岛歌词 | Notch Lyrics | Çentik Sözleri |
| 菜单栏 | Menu Bar | Menü Çubuğu (in sentences: menü çubuğu) |
| 菜单栏歌词 | Menu Bar Lyrics | Menü Çubuğu Sözleri |
| 触控栏 | Touch Bar | Touch Bar |
| 歌词窗口 | Lyrics Window | Şarkı Sözü Penceresi |
| 歌词管理 | Lyrics Manager | Şarkı Sözü Yöneticisi |
| 歌词库 | Lyrics Library | Şarkı Sözü Arşivi |
| 歌词引擎 | Lyrics Engine | Şarkı sözü motoru |
| 歌词来源 / 歌词源 | Lyrics Sources | Şarkı Sözü Kaynakları (one source: şarkı sözü kaynağı; never bare “Kaynak” where it is ambiguous) |
| 逐字歌词 | Word-by-word lyrics | Kelime kelime şarkı sözleri; segment pair “Kelime kelime / Satır satır” (English is “Word-timed / Line-timed”) |
| 译文 | Translation | Çeviri |
| 罗马音 / 读音 | Romanization / Reading | Telaffuz (Music: “Telaffuzu Göster”) |
| 卡拉OK效果 | Karaoke | Karaoke Efekti |
| 网页歌词 | Web Lyrics | Tarayıcıda Şarkı Sözleri |
| 打卡 / scrobble | Scrobble | skropla (verb), Skroplama (noun, setting); count “%d skroplama”; list “Son skroplamalar” (Last.fm Turkish) |
| 收听 / 播放次数 | Listens / Plays | dinleme (“%d dinleme”); Apple's column “Çalma Sayısı” where it names Music's own field. Never “dinlenme” (rest) |
| 收听记录 | Listening history | Dinleme Geçmişi |
| 听歌报告 / 听歌小结 | Listening Report / Digest | Dinleme Raporu (plural Dinleme Raporları; short: Raporlar) |
| 足迹 | Footprints | Geçmişe Bakış; 历年今日 “Geçmişte Bugün” |
| 里程碑 | Milestones | Dönüm Noktaları; next one “Sonraki hedef” |
| 榜单 | Charts | Listeler |
| 喜欢 (Apple Music) | Favorite | Favorilere Ekle / Favorilerden Çıkar; state “Favorilerde” |
| 喜欢 (Last.fm) | Love | Beğen / Beğeniyi Kaldır / Beğenildi; list “Sevilen parçalar” |
| 推送渠道 | Push Channels | Kanallar |
| 偏移 | Offset | Kaydırma |
| 正在播放 | Now Playing | Şu An Çalınan; status Çalıyor / Çalmıyor |
| 设置 | Settings | Ayarlar |
| 系统设置 | System Settings | Sistem Ayarları (suffixed: Sistem Ayarları’nda) |
| 全部设置 | All Settings | Tüm Ayarlar |
| 跟随系统 | Follow System | Sistem |
| 默认 / 恢复默认 | Default / Restore Defaults | Saptanmış / Saptanmışlara Dön (Apple; never Varsayılan) |
| 外观 | Appearance | Görünüş |
| 背景 | Background | Arka Plan |
| 字体 | Font | Font |
| 字号 | Font size | Punto (“Çeviri Puntosu”, “Telaffuz Puntosu”) |
| 颜色 | Color | Renk |
| 内容 | Content | İçerik |
| 行为 | Behavior | Davranış |
| 布局 / 排版 | Layout | Yerleşim |
| 位置 | Position | Konum |
| 大小 / 尺寸 | Size | Boyut |
| 透明度 / 不透明度 | Opacity | Opaklık |
| 跟随封面 | Artwork | Kapağa Göre |
| 纯色 / 渐变 / 毛玻璃 / 透明 | Solid / Gradient / Frosted Glass / Transparent | Düz Renk / Gradyan / Buzlu Cam / Saydam |
| 自动 | Auto | Otomatik |
| 完整尺寸 / 迷你尺寸 | Full Size / Mini Size | Tam Boyut / Mini |
| 已开启 / 未开启 (status) | On / Off | Açık / Kapalı |
| 运行中 / 未运行 | Running / Not running | Çalışıyor / Çalışmıyor |
| 辅助功能 | Accessibility | Erişilebilirlik |
| 自动化 | Automation | Otomasyon |
| 完全磁盘访问 | Full Disk Access | Tam Disk Erişimi |
| 屏幕录制 | Screen Recording | Ekran Kaydı |
| 通知 | Notifications | Bildirimler |
| 控制中心 | Control Center | Denetim Merkezi |
| 隐私与安全性 | Privacy & Security | Gizlilik ve Güvenlik |
| 登录项 | Login Items | Oturum Açma Öğeleri (pane: “Oturum Açma Öğeleri ve Genişletmeler”) |
| 仍要打开 | Open Anyway | Yine de Aç |
| 迷你播放器 | MiniPlayer | Mini Çalar |
| 登录时打开 | Open at Login | Oturum Açıldığında Aç |
| 检查更新 | Check for Updates | Güncellemeleri Denetle |
| 导入 / 导出 | Import / Export | İçe Aktar / Dışa Aktar |
| 候选 | Candidates | Adaylar |
| 搜索 | Search | Ara (field placeholder: Ara) |
| 重新匹配 | Rematch | Yeniden Eşleştir |
| 取消 / 完成 / 好 | Cancel / Done / OK | Vazgeç / Bitti / Tamam |
| 保存 / 删除 / 重置 | Save / Delete / Reset | Kaydet / Sil / Sıfırla |
| 关闭 (window) / 关闭 (switch) | Close / Turn Off | Kapat |
| 打开 (switch) | Turn On | Aç |
| 退出 | Quit | Çık |
| 高级 | Advanced | İleri Düzey |
| 诊断 | Diagnostics | Tanılar |
| 日志 | Logs | Günlükler |
| 重试 | Retry | Yeniden Dene |
| 密钥 | Key | Anahtar |
| 令牌 | Token | Jeton |
| 钥匙串 | Keychain | Anahtar Zinciri |
| 代理 | Proxy | Vekil Sunucu |
| 账号 | Account | Hesap |
| 登录 / 退出登录 | Sign In / Sign Out | Giriş Yap / Çıkış Yap |
| 连接 / 断开 | Connect / Disconnect | Bağlan / Bağlantıyı Kes |
| 深链 | Deep links | Derin bağlantılar |
| 缓存 | Cache | Önbellek |
| 文件夹 | Folder | Klasör |
| App | App | uygulama (sentence-initial: Uygulama) |

System UI names, exactly as in Turkish macOS and the browsers' Turkish UI:
- Safari: Ayarlar › İleri Düzey › “Web geliştiriciler için özellikleri göster”; menu Geliştir › “Apple Olayları’ndan JavaScript’e izin ver”.
- Chrome / Brave: Görünüm › Geliştirici › “Apple Events’ten JavaScript’e izin ver”. Edge: Görüntüle › Geliştirici › “Apple Etkinlikleri’nden JavaScript’e izin ver”. Arc's own menus are English in every language: View › Developer › “Allow JavaScript from Apple Events”. (The browsers write straight apostrophes; we write ’ like everywhere else.)
- Gatekeeper: “Apple, “%@” öğesinin Mac’inize zarar verebilecek veya gizliliğinizi ihlal edebilecek bir kötü amaçlı yazılım içermediğini doğrulayamadı”, button “Yine de Aç”.

When a term names macOS, Music, Safari or Gatekeeper UI, look up the exact Turkish string in the system's own resources instead of guessing: on this Mac the `.loctable` column is `tr` and app folders are `tr.lproj`.
