# Vietnamese (vi) translation style

Lyrimuse's UI strings live in `lyrimuse/Localization/Localizable.xcstrings`. The key of every entry is the Simplified Chinese source text; translate from it (many Lyrimuse terms are Sino-Vietnamese and map naturally), use the `en` value as the closest reference for meaning and length, and the `zh-Hant` / `fr` / `es` values to see how other languages solved the same problem. Translate into natural Vietnamese as it would appear in a macOS app, then run `python3 lyrimuse/Localization/generate-strings.py`. The same pack is used for every Vietnamese region (vi, vi-VN).

## Voice

- Address the user as **bạn**, like Apple's Vietnamese macOS (“Bạn có chắc chắn muốn…”, “máy Mac của bạn”). Never anh / chị / quý khách. In instructions, prefer an imperative with no pronoun (“Chọn…”, “Mở…”, “Bật…”), and add **hãy** only where a sentence would otherwise read abruptly.
- Follow the wording Apple uses in Vietnamese macOS and Apple Music (Cài đặt hệ thống, Nhạc, thanh menu, lời bài hát, Đang phát). When Apple has a term, use it.
- Labels, buttons, menu items, section titles: short noun or verb phrases, **sentence case** (only the first word and proper names capitalized): “Tìm lời bài hát”, “Xuất chẩn đoán”. When a sentence names an Apple UI element, quote Apple's exact spelling and capitalization (see the glossary), e.g. “Quyền riêng tư & Bảo mật”, “Mục đăng nhập & Phần mở rộng”.
- Descriptions, help text, status and error messages: plain present tense, no filler (“Lyrimuse hiển thị…”, “Bật tùy chọn này để…”). Click is “bấm vào” (Apple Vietnamese). Do not prefix every sentence with “Lưu ý:”.
- The same word is always written with the same capitalization: “Lyrimuse”, “thanh menu” inside a sentence, “Thanh menu” only at the start of a label.
- No trailing period at the end of any string, even long ones. A period between two sentences is fine.
- **Keep it as short as possible.** Vietnamese syllables are separated by spaces and text usually runs longer than English. Many strings sit in narrow toolbars, segmented controls, tiles, the Touch Bar and the menu bar. Drop words the label does not need (“Hiện lời” rather than “Hiển thị lời bài hát” where the context already says lyrics; “Lời” is fine as a tab title), use Apple's short forms (Bật / Tắt, Xong, Hủy, Nền, Màu, Cỡ chữ), and never add words the source doesn't have. Where the English is one short word, look for a one- or two-syllable Vietnamese word (“Tự động”, “Mini”, “Có”, “Không”); never invent abbreviations with a period unless Apple does — rephrase instead.
- Avoid classifier stacking and literal translations of Chinese measure words (“一首歌” is “một bài hát”, not “một thủ bài hát”). Avoid “được” passives where an active verb reads naturally.
- The same thing is always called the same way. Pick the glossary term and reuse it everywhere, including in sentences that refer to a setting by name: the quoted name must match the label exactly, letter for letter.
- A placeholder that is already a duration (“~12 h”) must not get its own “khoảng” in the template around it.
- Status words follow what the thing is: the lyrics engine is a background service, so 运行中 / 未运行 is “Đang chạy / Không chạy”, not “Đang mở”. A card title must not reuse the label of an option on the same page.

## Punctuation and spacing

- Quotation marks: typographic double quotes “like this” (U+201C … U+201D), as Apple's Vietnamese macOS does. Never straight " quotes, never « » or „ “ or 「」.
- Apostrophe (rare) is the typographic ’ (U+2019), never the straight '.
- No space before : ; ? ! (unlike French).
- Keep `…` (single ellipsis character) where the source has it, with no space before it: “Xuất…”, “Chọn…”.
- Keep keyboard symbols (⌘ ⌥ ⇧ ⌃), emoji, `\n`, Markdown (`**`, links) and URLs exactly.
- Numbers come from placeholders; do not write digit grouping by hand in a format string. A hand-written decimal outside a placeholder uses a comma (“0,5 giây”), a hand-written thousands separator a dot (“1.000”).
- Units in running text: giây, phút, giờ (“30 giây”, “2 giờ 5 phút”); where the English uses the short unit in a tight control (“30 s”, “5 min”), the short “s” / “phút” / “giờ” is fine. “ms” stays “ms”.
- Dates: day before month (“20/10”), months are numbered (“tháng 10”, “tháng 10 năm 2026”), never a month name.
- A clock-time placeholder takes the preposition: “lúc %@” (at), “đến %@” (until), “từ %@” (from).

## Placeholders and plurals

- Every `%@`, `%d`, `%lld`, `%.1f`, `%1$@`… in the source must appear in the translation with the same number, order of arguments and type. Never turn `%d` into `%@`.
- If Vietnamese word order needs the arguments in a different order and the source has two or more arguments, switch to positional form (`%2$@ … %1$@`) keeping each argument's type.
- `%%` is a literal percent sign.
- **Vietnamese nouns do not change with the count** (CLDR vi has only the “other” category). Where the English entry has plural forms (one / other), write **one** string, exactly as the Japanese and Korean entries do: “%d bài hát”, “%d lượt phát”. Never add “các / những” in front of a counted noun.
- A count placed after a noun reads as a label: “Bài hát: %d”. Prefer the number-first form (“%d bài hát”) where it is natural.

## Names that stay as they are

Lyrimuse, Last.fm, ListenBrainz, Discord, Telegram, Slack, Bark, ntfy, Server酱 (ServerChan), Apple Music, Spotify, YouTube Music, Musixmatch, Genius, Cloudflare, GitHub, Sparkle, Touch Bar, Dock, Finder, Scrobble, Safari, Chrome, Arc, Edge.
Chinese music services use the names in the English string (NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Soda Music…).

## Glossary

| Simplified Chinese | English | Vietnamese |
|---|---|---|
| 歌词 | Lyrics | Lời bài hát (short labels and compounds: Lời) |
| 播放器 | Player | Trình phát |
| 歌词显示 | Lyrics Display | Hiển thị lời |
| 快捷键 | Keyboard Shortcuts | Phím tắt |
| 通用 | General | Cài đặt chung |
| 关于 | About | Giới thiệu |
| 实验室 | Labs | Thử nghiệm |
| 推送提醒 | Push Alerts | Thông báo đẩy |
| 网页推送 | Web Push | Đẩy web |
| 关联平台 | Linked Platforms | Dịch vụ liên kết |
| 桌面悬浮歌词 / 悬浮歌词 | (Desktop) Floating Lyrics | Lời nổi |
| 灵动岛 | Notch | Notch |
| 菜单栏 | Menu Bar | Thanh menu |
| 触控栏 | Touch Bar | Touch Bar |
| 歌词窗口 | Lyrics Window | Cửa sổ lời |
| 歌词管理 | Lyrics Manager | Quản lý lời |
| 歌词库 | Lyrics Library | Thư viện lời |
| 歌词来源 / 歌词源 | Lyrics Sources | Nguồn lời bài hát (short: Nguồn lời) |
| 译文 | Translation | Bản dịch |
| 罗马音 / 读音 | Romanization / Reading | Phát âm (Apple Music: “Bản dịch & phát âm lời bài hát”) |
| 逐字歌词 | Word-by-word lyrics | Lời theo từng chữ |
| 打卡 / scrobble | Scrobble | Scrobble |
| 收听 / 播放次数 | Listens / Plays | Lượt phát |
| 收听记录 | Listening history | Lịch sử nghe |
| 听歌报告 / 听歌小结 | Listening Report / Digest | Báo cáo nghe nhạc / Tổng kết nghe nhạc |
| 推送渠道 | Push Channels | Kênh |
| 偏移 | Offset | Độ lệch |
| 封面 | Artwork | Ảnh bìa |
| 专辑 / 歌手 / 歌曲 | Album / Artist / Track | Album / Nghệ sĩ / Bài hát |
| 正在播放 | Now Playing | Đang phát |
| 设置 | Settings | Cài đặt |
| 系统设置 | System Settings | Cài đặt hệ thống |
| 全部设置 | All Settings | Tất cả cài đặt |
| 跟随系统 | Follow System | Hệ thống |
| 外观 | Appearance | Giao diện |
| 背景 | Background | Nền |
| 字体 | Font | Phông chữ (short: Phông) |
| 字号 | Font size | Cỡ chữ (“Cỡ bản dịch”, “Cỡ phát âm”) |
| 颜色 | Color | Màu |
| 内容 | Content | Nội dung |
| 行为 | Behavior | Hành vi |
| 布局 / 排版 | Layout | Bố cục |
| 位置 | Position | Vị trí |
| 跟随封面 | Artwork | Theo ảnh bìa |
| 纯色 / 渐变 / 毛玻璃 / 透明 | Solid / Gradient / Frosted Glass / Transparent | Màu đơn / Dải màu / Kính mờ / Trong suốt |
| 自动 | Auto | Tự động |
| 完整尺寸 / 迷你尺寸 | Full Size / Mini Size | Đầy đủ / Mini |
| 卡拉OK效果 | Karaoke | Karaoke |
| 已开启 / 未开启 (status) | On / Off | Đã bật / Đã tắt (very short status cells: Bật / Tắt) |
| 运行中 / 未运行 | Running / Not running | Đang chạy / Không chạy |
| 辅助功能 | Accessibility | Trợ năng |
| 自动化 | Automation | Tự động hóa |
| 完全磁盘访问 | Full Disk Access | Quyền truy cập đầy đủ vào ổ đĩa |
| 通知 | Notifications | Thông báo |
| 控制中心 | Control Center | Trung tâm điều khiển |
| 隐私与安全性 | Privacy & Security | Quyền riêng tư & Bảo mật |
| 登录项 | Login Items | Mục đăng nhập (pane: “Mục đăng nhập & Phần mở rộng”) |
| 仍要打开 | Open Anyway | Vẫn mở |
| 迷你播放器 | MiniPlayer | MiniPlayer |
| 登录时打开 | Open at Login | Mở khi đăng nhập |
| 检查更新 | Check for Updates | Kiểm tra bản cập nhật |
| 导入 / 导出 | Import / Export | Nhập / Xuất |
| 候选 | Candidates | Kết quả |
| 搜索 | Search | Tìm kiếm (button: Tìm) |
| 重新匹配 | Rematch | Tìm lại |
| 取消 / 完成 / 好 | Cancel / Done / OK | Hủy / Xong / OK |
| 保存 / 删除 / 重置 / 恢复默认 | Save / Delete / Reset / Restore Defaults | Lưu / Xóa / Đặt lại / Khôi phục mặc định |
| 关闭 | Close | Đóng |
| 退出 | Quit | Thoát |
| 高级 | Advanced | Nâng cao |
| 诊断 | Diagnostics | Chẩn đoán |
| 重试 | Retry | Thử lại |
| 密钥 | Key | Khóa |
| 钥匙串 | Keychain | Chuỗi khóa |
| 足迹 | Footprints | Dấu chân |
| 深链 | Deep links | Deep link |
| App | App | ứng dụng (sentence-initial: Ứng dụng) |

Spelling: use the modern tone-mark placement Apple uses (“hóa”, “thủy”, “hủy”, “khóa”, not “hoá”, “thuỷ”, “huỷ”, “khoá”).

System UI names, exactly as in Vietnamese macOS:
- Safari: Cài đặt › Nâng cao › “Hiển thị các tính năng cho nhà phát triển web”; menu Phát triển › “Cho phép JavaScript từ Sự kiện Apple”.
- Chrome / Arc / Brave: Xem › Nhà phát triển › “Cho phép JavaScript từ Apple Events”. Edge: Xem › Nhà phát triển › “Cho phép JavaScript từ Sự kiện của Apple”.
- Gatekeeper: “Apple không thể xác minh rằng “Lyrimuse” không chứa phần mềm độc hại…”, button “Vẫn mở”.

When a term names macOS, Music, Safari or Gatekeeper UI, look up the exact Vietnamese string in the system's own resources instead of guessing: on this Mac the `.loctable` column is `vi` and app folders are `vi.lproj`. A dump of 57 000 English → Vietnamese pairs is at `~/.config/lyrimuse-i18n/vi/apple-vi.json`.
