# Hindi (hi) translation style

Lyrimuse's UI strings live in `lyrimuse/Localization/Localizable.xcstrings`. The key of every entry is the Simplified Chinese source text; translate from it, use the `en` value as the closest reference for meaning and length, and the `ja` / `fr` values to see how a verb-final language (Japanese) and a language whose 0 is also singular (French) solved the same string. Translate into natural Hindi as it would appear in Apple's Hindi macOS, then run `python3 lyrimuse/Localization/generate-strings.py`. The pack is Devanagari Hindi for every region (hi, hi-IN); romanized Hindi (hi-Latn) is not served by it.

## Voice

- Address the user as **आप**, like Apple's Hindi macOS (“आपका Mac”, “क्या आप … चाहते हैं?”). Never तुम or तू.
- Buttons and menu items use the polite imperative, as Apple does: खोलें, दिखाएँ, छिपाएँ, सहेजें, हटाएँ, जोड़ें, चुनें, रद्द करें, डिलीट करें, फिर कोशिश करें. Write the chandrabindu (-एँ), never -एं.
- Follow the wording Apple uses in Hindi macOS and the Music app. When Apple has a term, use it — a dump of 57 000 English → Hindi pairs from this Mac is at `~/.config/lyrimuse-i18n/hi/apple-hi.json`. Apple's Hindi keeps trademarks in Latin letters (Touch Bar, Dock, Finder, Safari, Spotlight, iCloud, AirPlay, Mac) and transliterates most other technical nouns (सेटिंग, मेन्यू बार, डिफ़ॉल्ट, ऑफ़सेट, कैश, टोकन, विजेट, सिंक करें); do the same.
- Descriptions, help text, status and error messages: plain present tense, short sentences (“Lyrimuse गीत के बोल … दिखाता है”, “इसे चालू करने पर …”). No “कृपया” on every line; Apple uses it only when asking the user to retry or wait.
- No trailing punctuation at the end of any string, even long ones: no danda “।” and no “.” at the end (Apple's Hindi keeps them; Lyrimuse does not). Between two sentences write “।” followed by a space.
- **Keep it short.** Hindi in Devanagari is usually wider than English. Many strings sit in narrow toolbars, segmented controls, tiles, the Touch Bar and the menu bar. Drop words the label does not need, prefer Apple's short forms (चालू / बंद, पूर्ण, रद्द करें, रंग, फ़ॉन्ट, आकार, ऑटोमैटिक), and never add words the source doesn't have.
- The same thing is always called the same way. Pick the glossary term and reuse it everywhere, including in sentences that refer to a setting by name: the quoted name must match the label exactly.
- A placeholder that is already a duration (“~12 घंटे”) must not get its own “लगभग” in the template around it.
- Status words follow what the thing is: the lyrics engine is a background service, so 运行中 / 未运行 is “चल रहा है / नहीं चल रहा”, not “चालू / बंद”. A card title must not reuse the label of an option on the same page.

## Gender and agreement

Hindi verbs, participles and the possessive का / की / के agree with the gender and number of a noun. Two consequences.

**Never gender the user.** Avoid forms where the verb agrees with आप (“आप कनेक्ट हो गए / गईं”). Use the imperative (“साइन इन करें”), the ergative with ने so the verb agrees with the object (“आपने 3 गीत सुने”), or make the account or the action the subject (“खाता कनेक्ट हो गया”, “साइन इन हो गया”).

**A placeholder has no known gender.** A song title, an app or player name, a person: whatever ends up in `%@` can be either gender. Rewrite so the verb agrees with a noun you write, in this order of preference:

1. **Apposition noun** that carries the gender: ““%@” गीत चल रहा है” (गीत is masculine), “%@ ऐप नहीं खुल सका” (ऐप is masculine), “%@ प्लेयर”, “%@ खाता”, “%@ स्रोत”.
2. **Passive with को**, which takes the default masculine singular whatever the value is, as Apple does (“%@ को अभी-अभी देखा गया”): “%@ को कनेक्ट किया गया”, “%@ को हटाया गया”.
3. **Colon, placeholder at the end** (menu items, buttons, short status): “खोलें : %@”, “अभी चल रहा है : %@”, “पिछला अपडेट : %@”.
4. **Postposition right after the placeholder**, which needs no agreement: “%@ में”, “%@ पर”, “%@ से”, “%@ के लिए”, “%@ के साथ”, “%@ द्वारा”.

Apple's own default when nothing else works is the masculine singular; use it only then.

**Lyrimuse** is treated as a masculine app name: “Lyrimuse दिखाता है”, “Lyrimuse का”.

## Punctuation and spacing

- **Sentence separator is the danda “।”** (U+0964), like Apple's Hindi (11 800 times vs 54 sentence-final periods). No space before it, one space after it. Never at the very end of a string. Never “॥”.
- **Colon gets a space before it**: “कलाकार : %@”, “बायाँ : %1$@”. Apple's Hindi writes it this way in 1 383 of 1 390 cases (a colon glued to Devanagari reads like the visarga ः). It does not wrap: a line never breaks before a colon. Not in times (12:30), URLs or keyboard shortcuts.
- No space before “?” and “!”. Use “?” after questions, like Apple.
- Quotation marks: “like this” (U+201C … U+201D), as Apple's Hindi does. Never straight " quotes, ‘ ’ as quotes, « » or 「」.
- Keep `…` (single ellipsis character) where the source has it: “एक्सपोर्ट करें…”, “चुनें…”. Never three dots.
- **Arabic digits** (0–9) everywhere, like Apple's Hindi (5 092 times vs 6 Devanagari digits). Never ०–९.
- **Nukta as a combining mark**, as Apple writes it and as NFC keeps it: फ़, ज़, ड़, ढ़ are a base letter plus U+093C. Do not use the precomposed letters U+0958–U+095F. Write text in NFC. Write the nukta in loanwords the way Apple does: ख़ुद, ग़लत, ख़ास, ख़राब, ख़ाली, क़तार, बाक़ी, ग़ायब, तरीक़ा, ग़ैर.
- A space between Devanagari and Latin letters or digits: “Last.fm पर”, “Mac पर”, “5 मिनट”, “macOS 14 में”. A placeholder is followed by a space before the next Devanagari word: “%@ में”, never “%@में”.
- No zero-width joiner / non-joiner and no non-breaking spaces.
- Keep keyboard symbols (⌘ ⌥ ⇧ ⌃), emoji, `\n`, Markdown (`**`, links) and URLs exactly.
- Numbers come from placeholders; do not write digit grouping by hand in a format string. A hand-written decimal uses a point (“0.5 से॰”).
- **Percent sign after the number**: “50%”. In a format string `%d%%`.
- Units: सेकंड / मिनट / घंटे in running text; in tight controls Apple's abbreviations with the abbreviation sign “॰” (U+0970): से॰, मि॰ (“30 से॰”, “5 मि॰”, “2 घं॰ 5 मि॰”). “ms” stays “ms”.
- Dates are day month year (“15 नवंबर 2026”), times 14:30. Leave dates and times to the formatter wherever the source uses a placeholder.
- Lists end with “और” and no comma before it: “Spotify, Apple Music और QQ Music”.

## Placeholders and plurals

- Every `%@`, `%d`, `%lld`, `%.1f`, `%1$@`… in the source must appear in the translation with the same number, order of arguments and type. Never turn `%d` into `%@`.
- Hindi is verb-final; if the arguments need a different order and the source has two or more, switch to positional form (`%2$@ … %1$@`) keeping each argument's type.
- `%%` is a literal percent sign.
- **Hindi has singular and plural, and 0 takes the singular** (CLDR: one = 0 and 1). Where the English entry has plural forms (one / other), give both `{one, other}`: one is used for 0 and 1, other for every other count. Many masculine nouns do not change (1 गीत / 3 गीत, 1 कलाकार / 3 कलाकार), but the verb does (“1 गीत बचा है / 3 गीत बचे हैं”), and feminine nouns do (1 पंक्ति / 3 पंक्तियाँ, 1 सूचना / 3 सूचनाएँ). Write both forms even when they are the same string.

## Names that stay as they are

Lyrimuse, Last.fm, ListenBrainz, Discord, Telegram, Slack, Bark, ntfy, Server酱 (ServerChan), Apple Music, Spotify, YouTube Music, Genius, Musixmatch, Cloudflare, GitHub, Sparkle, Touch Bar, Dock, Finder, Safari, Chrome, Arc, Edge, Spotlight, AirPlay, iCloud, Mac, macOS, Dynamic Island, Liquid Glass, Webhook, URL, API.
Transliterated like Apple: Wi‑Fi → वाई-फ़ाई.
Chinese music services use the names in the English string (NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Soda Music…). DingTalk and Feishu (Lark) have no Hindi UI; quote their option names in English as they appear in their English UI.
The Music app is “संगीत ऐप” in Apple's Hindi; Apple Music the service stays “Apple Music”.

## Glossary

| Simplified Chinese | English | Hindi |
|---|---|---|
| 歌词 | Lyrics | गीत के बोल (Apple, Music). An invariable block, plural masculine (“गीत के बोल नहीं मिले”). Short form inside a phrase: बोल (“बोल दिखाएँ”, “नॉच में बोल”, “बोल का फ़ॉन्ट”). Never बोल alone as a button or tab (it reads as the verb “speak”), never लिरिक्स, never गाने के बोल |
| 歌曲 / 曲目 | Song / Track | गीत (Apple; same form in singular and plural). In a casual instruction Apple's “कोई गाना चलाएँ” is fine |
| 播放器 | Player | प्लेयर (Apple: मिनी प्लेयर). Never खिलाड़ी (game player) |
| 歌手 | Artist | कलाकार |
| 专辑 | Album | ऐल्बम |
| 封面 | Artwork | कवर (Music writes ऐल्बम कलाकृति; Lyrimuse uses the short कवर everywhere) |
| 动态封面 | Animated Artwork | ऐनिमेटेड कवर |
| 歌词显示 | Lyrics Display | बोल का डिस्प्ले |
| 快捷键 | Keyboard Shortcuts | कीबोर्ड शॉर्टकट (short: शॉर्टकट) |
| 通用 | General | सामान्य |
| 关于 | About | जानकारी |
| 实验室 | Labs | प्रयोग |
| 推送提醒 | Push Alerts | पुश सूचनाएँ |
| 网页推送 | Web Push | वेब पुश |
| 关联平台 | Linked Platforms | लिंक की गई सेवाएँ |
| 桌面悬浮歌词 / 悬浮歌词 | (Desktop) Floating Lyrics | फ़्लोटिंग बोल (in sentences: फ़्लोटिंग गीत के बोल) |
| 灵动岛 | Notch | नॉच |
| 灵动岛歌词 | Notch Lyrics | नॉच में बोल |
| 菜单栏 | Menu Bar | मेन्यू बार (“मेन्यू बार में”) |
| 菜单栏歌词 | Menu Bar Lyrics | मेन्यू बार में बोल |
| 触控栏 | Touch Bar | Touch Bar (“Touch Bar पर बोल”) |
| 歌词窗口 | Lyrics Window | बोल विंडो |
| 歌词管理 | Lyrics Manager | बोल मैनेजर (Apple: स्टेज मैनेजर); the action “गीत के बोल प्रबंधित करें” |
| 歌词库 | Lyrics Library | बोल लाइब्रेरी |
| 歌词引擎 | Lyrics Engine | बोल इंजन (Apple: सर्च इंजन) |
| 歌词来源 / 歌词源 | Lyrics Sources | बोल के स्रोत (one: बोल का स्रोत; never a bare “स्रोत” where it is ambiguous) |
| 逐字歌词 | Word-by-word lyrics | शब्द-दर-शब्द बोल; segment pair “शब्द-दर-शब्द / पंक्ति-दर-पंक्ति” (Apple: शब्द-दर-शब्द ट्रांसक्रिप्ट) |
| 译文 | Translation | अनुवाद |
| 罗马音 / 读音 | Romanization / Reading | उच्चारण (Music: “उच्चारण दिखाएँ”); romanized script specifically: रोमन लिपि |
| 卡拉OK效果 | Karaoke | कराओके इफ़ेक्ट |
| 网页歌词 | Web Lyrics | ब्राउज़र में बोल |
| 打卡 / scrobble | Scrobble | स्क्रॉबल करें (verb), स्क्रॉबलिंग (setting / activity); count “%d स्क्रॉबल”; list “हाल के स्क्रॉबल” |
| 收听 / 播放次数 | Listens / Plays | सुनना; count “%d बार सुना गया”, short “%d प्ले” where space is tight |
| 收听记录 | Listening history | सुनने की हिस्ट्री |
| 听歌报告 / 听歌小结 | Listening Report / Digest | सुनने की रिपोर्ट (feminine, same form in plural; short: रिपोर्ट). Never रिपोर्टें |
| 足迹 | Footprints | संगीत का सफ़र; 历年今日 “आज के दिन” |
| 里程碑 | Milestones | उपलब्धियाँ; next one “अगला लक्ष्य” |
| 榜单 | Charts | चार्ट; 最常听 “टॉप गीत / टॉप कलाकार / टॉप ऐल्बम” |
| 喜欢 (Apple Music) | Favorite | पसंदीदा में जोड़ें / पसंदीदा से हटाएँ; state “पसंदीदा” |
| 喜欢 (Last.fm) | Love | पसंद करें / पसंद हटाएँ / पसंद किया गया; list “पसंद किए गए गीत”. Never नापसंद (that is Dislike). When both appear on one screen, prefix the platform: “Last.fm पर पसंद करें” |
| 推送渠道 | Push Channels | चैनल |
| 偏移 | Offset | ऑफ़सेट |
| 正在播放 | Now Playing | अभी चल रहा है; status चल रहा है / नहीं चल रहा; nothing playing “कुछ नहीं चल रहा” |
| 设置 | Settings | सेटिंग (Apple; never सेटिंग्स) |
| 系统设置 | System Settings | सिस्टम सेटिंग |
| 全部设置 | All Settings | सभी सेटिंग |
| 跟随系统 | Follow System | सिस्टम |
| 默认 / 恢复默认 | Default / Restore Defaults | डिफ़ॉल्ट / डिफ़ॉल्ट पर रीसेट करें |
| 外观 | Appearance | प्रकटन |
| 背景 | Background | बैकग्राउंड |
| 字体 | Font | फ़ॉन्ट |
| 字号 | Font size | आकार (“अनुवाद का आकार”, “उच्चारण का आकार”) |
| 颜色 | Color | रंग |
| 内容 | Content | कॉन्टेंट |
| 行为 | Behavior | व्यवहार |
| 布局 / 排版 | Layout | लेआउट |
| 位置 | Position | स्थिति |
| 大小 / 尺寸 | Size | आकार |
| 透明度 / 不透明度 | Opacity | अपारदर्शिता |
| 跟随封面 | Artwork | कवर से |
| 纯色 / 渐变 / 毛玻璃 / 透明 | Solid / Gradient / Frosted Glass / Transparent | सादा रंग / ग्रेडिएंट / फ़्रॉस्टेड ग्लास / पारदर्शी |
| 自动 | Auto | ऑटोमैटिक |
| 完整尺寸 / 迷你尺寸 | Full Size / Mini Size | पूरा आकार / मिनी |
| 已开启 / 未开启 (status) | On / Off | चालू / बंद |
| 运行中 / 未运行 | Running / Not running | चल रहा है / नहीं चल रहा |
| 辅助功能 | Accessibility | ऐक्सेसिबिलिटी |
| 自动化 | Automation | ऑटोमेशन |
| 完全磁盘访问 | Full Disk Access | पूर्ण डिस्क ऐक्सेस |
| 屏幕录制 | Screen Recording | स्क्रीन रिकॉर्डिंग |
| 通知 | Notifications | सूचनाएँ |
| 控制中心 | Control Center | कंट्रोल सेंटर |
| 隐私与安全性 | Privacy & Security | गोपनीयता और सुरक्षा |
| 登录项 | Login Items | लॉगइन आइटम |
| 仍要打开 | Open Anyway | फिर भी खोलें |
| 迷你播放器 | MiniPlayer | मिनी प्लेयर |
| 登录时打开 | Open at Login | लॉगइन पर खोलें |
| 检查更新 | Check for Updates | अपडेट जाँचें |
| 导入 / 导出 | Import / Export | इंपोर्ट करें / एक्सपोर्ट करें |
| 候选 | Candidates | विकल्प |
| 搜索 | Search | खोजें (field placeholder: खोजें) |
| 重新匹配 | Rematch | फिर से मैच करें |
| 取消 / 完成 / 好 | Cancel / Done / OK | रद्द करें / पूर्ण / ठीक |
| 保存 / 删除 / 重置 | Save / Delete / Reset | सहेजें / डिलीट करें / रीसेट करें |
| 关闭 (window) / 关闭 (switch) | Close / Turn Off | बंद करें |
| 打开 (switch) | Turn On | चालू करें |
| 退出 | Quit | बंद करें (Apple; “Lyrimuse बंद करें”) |
| 高级 | Advanced | एडवांस |
| 诊断 | Diagnostics | डायग्नॉस्टिक |
| 日志 | Logs | लॉग |
| 重试 | Retry | फिर कोशिश करें |
| 密钥 | Key | की |
| 令牌 | Token | टोकन |
| 钥匙串 | Keychain | कीचेन |
| 代理 | Proxy | प्रॉक्सी |
| 账号 | Account | खाता |
| 登录 / 退出登录 | Sign In / Sign Out | साइन इन करें / साइन आउट करें |
| 连接 / 断开 | Connect / Disconnect | कनेक्ट करें / डिस्कनेक्ट करें |
| 深链 | Deep links | डीप लिंक |
| 缓存 | Cache | कैश |
| 文件夹 | Folder | फ़ोल्डर |
| App | App | ऐप (plural ऐप्स) |
| 周 / 月 / 年 | Week / Month / Year | सप्ताह / महीना / वर्ष; weekly / monthly / yearly साप्ताहिक / मासिक / वार्षिक |
| 版本 | Version | संस्करण for the app or macOS (“नया संस्करण”); वर्शन for a song or lyrics version (live, remix, a saved version of the lyrics) |
| 自动(副词) / 自动(选项) | automatically / Automatic | अपने-आप for the adverb (“अपने-आप स्किप होता है”); ऑटोमैटिक only as an option label or adjective (“ऑटोमैटिक”, “ऑटोमैटिक मैचिंग”). Never ऑटोमैटिक रूप से |
| 繁体 / 简体 | Traditional / Simplified | पारंपरिक / सरलीकृत (as `Locale("hi")` names them) |
| 歌名 | Title | शीर्षक |
| 无法撤销 | can't be undone | “पहले जैसा नहीं किया जा सकता” |
| 平台 | Platform | प्लैटफ़ॉर्म |
| 无法识别 | unrecognized | अज्ञात |
| 小结 / 听歌报告 | Digest / Listening report | रिपोर्ट; “सुनने की साप्ताहिक / मासिक / वार्षिक रिपोर्ट” |

System UI names, exactly as in Hindi macOS and the browsers' Hindi UI:
- Safari: सेटिंग › एडवांस › “वेब डेवलपर के लिए फ़ीचर दिखाएँ”; menu डेवलप › “Apple इवेंट से JavaScript को अनुमति दें”.
- Chrome: देखें › डेवलपर › “Apple Events से JavaScript की अनुमति दें”. Edge: दृश्य › डेवलपर › “Apple ईवेंट्स से JavaScript की अनुमति दें”. Arc's own menus are English in every language: View › Developer › “Allow JavaScript from Apple Events”.
- Gatekeeper: “Apple द्वारा यह सत्यापित नहीं किया जा सका कि “%@” में ऐसा मालवेयर नहीं है जो आपके Mac को नुक़सान पहुँचा सकता है या आपकी गोपनीयता प्रभावित कर सकता है”, button “फिर भी खोलें”.

When a term names macOS, Music, Safari or Gatekeeper UI, look up the exact Hindi string in the system's own resources instead of guessing: on this Mac the `.loctable` column is `hi` and app folders are `hi.lproj`.
