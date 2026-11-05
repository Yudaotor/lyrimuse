# Thai (th) translation style

Lyrimuse's UI strings live in `lyrimuse/Localization/Localizable.xcstrings`. The key of every entry is the Simplified Chinese source text; translate from it, use the `en` value as the closest reference for meaning and length, and the `ja` / `vi` values to see how other languages without plural forms solved the same problem. Translate into natural Thai as it would appear in a macOS app, then run `python3 lyrimuse/Localization/generate-strings.py`. The same pack is used for every Thai region (th, th-TH).

## Voice

- Write the neutral, written register Apple uses in Thai macOS. Avoid pronouns where the sentence works without one; when a second person is needed, use **คุณ** (“ของคุณ”), never เธอ / ท่าน / นาย. Never add politeness particles (ครับ, ค่ะ, คะ, นะ, จ้า): Apple's Thai strings contain none.
- A request starts with **โปรด** (“โปรดลองอีกครั้งในภายหลัง”), never กรุณา. A question ends with **…หรือไม่** and no question mark (“คุณแน่ใจหรือไม่”).
- Labels, buttons, menu items, section titles: short noun or verb phrases (“ค้นหาเนื้อเพลง”, “ส่งออกการวินิจฉัย”). Instructions are imperative without a subject (“เลือก…”, “เปิด…”, “คลิก…”).
- Descriptions, help text, status and error messages: plain statements (“Lyrimuse แสดง…”, “เปิดตัวเลือกนี้เพื่อ…”). No filler such as “หมายเหตุ:” in front of every sentence.
- Follow the wording Apple uses in Thai macOS and the Music app. When Apple has a term, use it (glossary below). When a sentence names an Apple UI element, quote Apple's exact Thai string.
- No direct translation from Chinese or English word order. Read each sentence as a Thai user would; drop words the sentence does not need.
- **Keep it short.** Many strings sit in narrow toolbars, segmented controls, tiles, the Touch Bar and the menu bar. Use Apple's short forms (เปิด / ปิด, เสร็จสิ้น, ยกเลิก, สี, แบบอักษร, ขนาด, อัตโนมัติ). Thai stacks vowels and tone marks above and below the line, so tall short labels are better than long ones.
- The same thing is always called the same way. Pick the glossary term and reuse it everywhere, including in sentences that refer to a setting by name: the quoted name must match the label exactly, character for character.
- A placeholder that is already a duration (“~12 h”) must not get its own “ประมาณ” in the template around it.
- Status words follow what the thing is: the lyrics engine is a background service, so 运行中 / 未运行 is “กำลังทำงาน / ไม่ได้ทำงาน”, not “เปิดอยู่”. A card title must not reuse the label of an option on the same page.

## Spacing and line breaks

- Thai does not put spaces between words. Put a single space only **between phrases or clauses** (where English would have a comma or a full stop), and **between Thai and Latin letters, digits or a placeholder** on both sides: “เปิด Lyrimuse”, “%d เพลง”, “เนื้อเพลงใน Touch Bar”, “ใน %@”.
- List items are separated by a space, with และ before the last one and no comma: “ศิลปิน อัลบั้ม และเพลง”. A comma is fine between Latin names (“Spotify, Apple Music และ YouTube Music”).
- Never insert zero-width spaces (U+200B) or other invisible characters to create break points: macOS breaks Thai lines with a dictionary already, and invisible characters break search and copy. Never use the non-breaking space.
- **ไม้ยมก ๆ** follows Apple: attached to the word before it, one space after it (“ต่างๆ ที่”, “อื่นๆ”), no space when it ends the string or is followed by punctuation. Do not write “ต่าง ๆ” with a space before ๆ: CoreText may then put ๆ at the start of a line.

## Punctuation

- No full stop at the end of any string (Thai does not use one). Between two sentences, use a space, not a period.
- Quotation marks: typographic double quotes “like this” (U+201C … U+201D). Never straight " quotes, never « » or „ “ or 「」. Leave a space outside the quotes when Thai text surrounds them: เปิด “การตั้งค่าระบบ” แล้ว…
- Keep `…` (single ellipsis character) where the source has it, with no space before it: “ส่งออก…”, “เลือก…”. Never `...`.
- Colons: no space before, one space after (“ศิลปิน: %@”).
- Keep keyboard symbols (⌘ ⌥ ⇧ ⌃), emoji, `\n`, Markdown (`**`, links) and URLs exactly.
- Avoid ฯลฯ in UI text; write “และอื่นๆ” or rephrase.

## Numbers, units and dates

- Arabic digits only, never Thai digits (๐–๙). Numbers come from placeholders; do not write digit grouping by hand. A hand-written decimal uses a point (“0.5 วินาที”), thousands a comma (“1,000”).
- Units: วินาที, นาที, ชั่วโมง (“30 วินาที”, “2 ชั่วโมง 5 นาที”); in tight controls where the English uses “s” / “min” / “h”, “วิ” / “นาที” / “ชม.” are fine. “ms” stays “ms”.
- Counting uses classifiers: songs “%d เพลง”, plays “%d ครั้ง” (“เล่น %d ครั้ง”), artists “%d ราย” or “ศิลปิน %d ราย”, albums “%d อัลบั้ม”, lines “%d บรรทัด”, items “%d รายการ”, days “%d วัน”.
- Dates in app strings come from system formatters (they follow the system calendar, Buddhist era by default in the Thai region). In a hand-written date, day comes before month (“20/10”). Never add พ.ศ. or ค.ศ. by hand.
- A clock-time placeholder takes a preposition: “เวลา %@” (at), “จนถึง %@” (until), “ตั้งแต่ %@” (from).

## Placeholders and plurals

- Every `%@`, `%d`, `%lld`, `%.1f`, `%1$@`… in the source must appear in the translation with the same number, order of arguments and type. Never turn `%d` into `%@`.
- If Thai word order needs the arguments in a different order and the source has two or more arguments, switch to positional form (`%2$@ … %1$@`) keeping each argument's type.
- `%%` is a literal percent sign.
- **Thai nouns do not change with the count** (CLDR th has only the “other” category). Where the English entry has plural forms (one / other), write **one** string, exactly as the Japanese, Korean and Vietnamese entries do: “%d เพลง”, “เล่น %d ครั้ง”.
- A count can also follow the label: “เพลง: %d”, when the classifier would read awkwardly.

## Names that stay in Latin letters

Lyrimuse, Last.fm, ListenBrainz, Discord, Telegram, Slack, Bark, ntfy, Server酱 (ServerChan), Apple Music, Spotify, YouTube Music, Musixmatch, Genius, Cloudflare, GitHub, Sparkle, Mac, macOS, iCloud, AirPlay, Siri, Touch Bar, Dock, Finder, Safari, Spotlight, Chrome, Arc, Edge, Wi‑Fi, URL, API, Webhook, Scrobble (“การ Scrobble”, “Scrobble ไปยัง Last.fm”), Replay, Dynamic Island (Apple's product name only; Lyrimuse's own notch feature is รอยบาก).
Chinese music services use the names in the English string (NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Soda Music…).
Common technical loanwords are written in Thai as Apple does: แอป, ดาวน์โหลด, อัปเดต, รีเซ็ต, แคช, เซิร์ฟเวอร์, โทเค็น, ปลั๊กอิน, วิดเจ็ต, บลูทูธ, เพลย์ลิสต์, อัลบั้ม, แทร็ก, คาราโอเกะ, เอฟเฟ็กต์. Sync is เชื่อมข้อมูล, never ซิงค์.

## Glossary

| Simplified Chinese | English | Thai |
|---|---|---|
| 歌词 | Lyrics | เนื้อเพลง |
| 播放器 | Player | เครื่องเล่น (never ผู้เล่น, that is a game player) |
| 歌手 | Artist | ศิลปิน |
| 专辑 / 歌曲 | Album / Track | อัลบั้ม / เพลง |
| 封面 | Artwork | ภาพหน้าปก |
| 动态封面 | Animated Artwork | ภาพหน้าปกเคลื่อนไหว |
| 正在播放 | Now Playing | กำลังเล่นอยู่ (narrow cells: กำลังเล่น) |
| 歌词显示 | Lyrics Display | การแสดงเนื้อเพลง |
| 快捷键 | Keyboard Shortcuts | ปุ่มลัด (page title: ปุ่มลัดแป้นพิมพ์) |
| 通用 | General | ทั่วไป |
| 关于 | About | เกี่ยวกับ |
| 实验室 | Labs | ทดลอง |
| 推送提醒 | Push Alerts | การแจ้งเตือนแบบพุช |
| 关联平台 | Linked Platforms | บริการที่เชื่อมต่อ |
| 灵动岛 | Notch | รอยบาก |
| 灵动岛歌词 | Notch Lyrics | เนื้อเพลงที่รอยบาก |
| 桌面悬浮歌词 / 悬浮歌词 | (Desktop) Floating Lyrics | เนื้อเพลงแบบลอย |
| 菜单栏 | Menu Bar | แถบเมนู (“ในแถบเมนู”) |
| 菜单栏歌词 | Menu Bar Lyrics | เนื้อเพลงในแถบเมนู |
| 触控栏 | Touch Bar | Touch Bar (“เนื้อเพลงใน Touch Bar”) |
| 歌词窗口 | Lyrics Window | หน้าต่างเนื้อเพลง |
| 歌词管理 | Lyrics Manager | ตัวจัดการเนื้อเพลง |
| 歌词库 | Lyrics Library | คลังเนื้อเพลง |
| 歌词引擎 | Lyrics Engine (background service) | บริการเนื้อเพลง |
| 歌词来源 / 歌词源 | Lyrics Sources | แหล่งเนื้อเพลง (never just แหล่ง) |
| 网页歌词 | Web Lyrics | เนื้อเพลงในเบราว์เซอร์ |
| 逐字歌词 | Word-by-word lyrics | เนื้อเพลงแบบคำต่อคำ (segments: ทีละคำ / ทีละบรรทัด) |
| 卡拉OK效果 | Karaoke | เอฟเฟ็กต์คาราโอเกะ (short: คาราโอเกะ) |
| 译文 | Translation | คำแปล |
| 罗马音 / 读音 | Romanization / Reading | การออกเสียง (Apple Music: “คำแปลและการออกเสียงร้องตามเนื้อเพลง”) |
| 喜欢 (Apple Music) | Favorite | รายการโปรด (“เพิ่มไปยังรายการโปรด”) |
| 喜欢 (Last.fm Love) | Love / Loved | ชอบ / ชอบแล้ว |
| 打卡 / scrobble | Scrobble | Scrobble (“การ Scrobble”) |
| 收听 / 播放次数 | Listens / Plays | การฟัง; counts “ฟัง %d ครั้ง” / “เล่น %d ครั้ง” |
| 收听记录 | Listening history | ประวัติการฟัง |
| 听歌报告 / 听歌小结 | Listening Report / Digest | รายงานการฟัง |
| 足迹 | Footprints | ย้อนรอย (“ย้อนรอยการฟัง”) |
| 收听里程碑 | Listening Milestones | เหตุการณ์สำคัญ (next one: เป้าหมายถัดไป) |
| 榜单 | Charts | ชาร์ต |
| 推送渠道 | Push Channels | ช่องทาง |
| 偏移 | Offset | ชดเชยเวลา |
| 设置 | Settings | การตั้งค่า |
| 系统设置 | System Settings | การตั้งค่าระบบ |
| 全部设置 | All Settings | การตั้งค่าทั้งหมด |
| 跟随系统 | Follow System | ตามระบบ |
| 外观 | Appearance | รูปลักษณ์ |
| 背景 | Background | พื้นหลัง |
| 字体 | Font | แบบอักษร |
| 字号 | Font size | ขนาดแบบอักษร (short: ขนาด) |
| 颜色 | Color | สี |
| 内容 | Content | เนื้อหา |
| 行为 | Behavior | การทำงาน |
| 布局 / 排版 | Layout | รูปแบบ / เค้าโครง |
| 位置 | Position | ตำแหน่ง |
| 跟随封面 | Artwork | ตามภาพหน้าปก |
| 纯色 / 渐变 / 毛玻璃 / 透明 | Solid / Gradient / Frosted Glass / Transparent | สีพื้น / ไล่ระดับสี / กระจกฝ้า / โปร่งใส |
| 自动 | Auto | อัตโนมัติ |
| 完整尺寸 / 迷你尺寸 | Full Size / Mini Size | ขนาดเต็ม / ขนาดมินิ (short: เต็ม / มินิ) |
| 已开启 / 未开启 (status) | On / Off | เปิดอยู่ / ปิดอยู่ (very short: เปิด / ปิด) |
| 开启 / 关闭 (action) | Turn On / Turn Off | เปิด / ปิด |
| 运行中 / 未运行 | Running / Not running | กำลังทำงาน / ไม่ได้ทำงาน |
| 辅助功能 | Accessibility | การช่วยการเข้าถึง |
| 自动化 | Automation | การทำงานอัตโนมัติ |
| 完全磁盘访问 | Full Disk Access | การเข้าถึงดิสก์ทั้งหมด |
| 通知 | Notifications | การแจ้งเตือน |
| 控制中心 | Control Center | ศูนย์ควบคุม |
| 隐私与安全性 | Privacy & Security | ความเป็นส่วนตัวและความปลอดภัย |
| 登录项 | Login Items | รายการเข้าสู่ระบบ (pane: “รายการเข้าสู่ระบบและส่วนขยาย”) |
| 仍要打开 | Open Anyway | ยืนยันจะเปิด |
| 迷你播放器 | MiniPlayer | เครื่องเล่นขนาดเล็ก |
| 登录时打开 | Open at Login | เปิดเมื่อเข้าสู่ระบบ |
| 检查更新 | Check for Updates | ตรวจหารายการอัปเดต |
| 导入 / 导出 | Import / Export | นำเข้า / ส่งออก |
| 候选 | Candidates | ผลลัพธ์ |
| 搜索 | Search | ค้นหา |
| 重新匹配 | Rematch | จับคู่ใหม่ |
| 取消 / 完成 / 好 | Cancel / Done / OK | ยกเลิก / เสร็จสิ้น / ตกลง |
| 保存 / 删除 / 移除 | Save / Delete / Remove | บันทึก / ลบ / เอาออก |
| 重置 / 恢复默认 / 默认 | Reset / Restore Defaults / Default | รีเซ็ต / กู้คืนค่าเริ่มต้น / ค่าเริ่มต้น |
| 自定义 | Custom | กำหนดเอง |
| 关闭 (window) | Close | ปิด |
| 退出 | Quit | ออก (“ออกจาก Lyrimuse”) |
| 高级 | Advanced | ขั้นสูง |
| 诊断 | Diagnostics | การวินิจฉัย |
| 重试 | Retry | ลองอีกครั้ง |
| 密钥 | Key | คีย์ |
| 钥匙串 | Keychain | พวงกุญแจ |
| 账号 | Account | บัญชี |
| 登录 / 退出登录 | Sign In / Sign Out | ลงชื่อเข้า / ลงชื่อออก |
| 连接 / 断开 | Connect / Disconnect | เชื่อมต่อ / เลิกเชื่อมต่อ |
| 预览 | Preview | แสดงตัวอย่าง |
| 深链 | Deep links | Deep link |
| App | App | แอป |

System UI names, exactly as in Thai macOS:
- Safari: การตั้งค่า › ขั้นสูง › “แสดงคุณสมบัติสำหรับนักพัฒนาเว็บ”; menu พัฒนา › “อนุญาต JavaScript จากเหตุการณ์ Apple”.
- Chrome (and Brave, which has no Thai pack on this Mac): มุมมอง › นักพัฒนาซอฟต์แวร์ › “อนุญาตให้เรียกใช้ JavaScript จากกิจกรรมใน Apple”. Edge: มุมมอง › นักพัฒนา › “อนุญาต JavaScript จากเหตุการณ์ Apple”. Arc keeps its English menu names in every language: “View › Developer › Allow JavaScript from Apple Events”.
- Gatekeeper: “Apple ไม่สามารถตรวจสอบยืนยันว่า “Lyrimuse” ไม่มีมัลแวร์…”, title “ไม่ได้เปิด “Lyrimuse””, button “ยืนยันจะเปิด”.

When a term names macOS, Music, Safari or Gatekeeper UI, look up the exact Thai string in the system's own resources instead of guessing: on this Mac the `.loctable` column is `th` and app folders are `th.lproj`. A dump of 57 000 English → Thai pairs is at `~/.config/lyrimuse-i18n/th/apple-th.json`; the term research behind the glossary is `~/.config/lyrimuse-i18n/th/terms-research.md`.
