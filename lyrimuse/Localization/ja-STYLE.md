# Japanese (ja) translation style

Lyrimuse's UI strings live in `lyrimuse/Localization/Localizable.xcstrings`. The key of every entry is the Simplified Chinese source text; the `en` value is the closest reference for meaning and length. Translate into natural Japanese as it would appear in a macOS app, then run `python3 lyrimuse/Localization/generate-strings.py`.

## Voice

- Follow the wording Apple uses in Japanese macOS (System Settings, Music, Finder). When Apple has a term, use it.
- Labels, buttons, menu items, section titles: short noun or verb phrases, no politeness endings (「保存」「キャンセル」「歌詞を検索」).
- Descriptions, help text, status and error messages: です・ます調 (「歌詞が見つかりません」「〜を表示します」).
- No trailing 「。」 at the end of any string, even long ones. Sentence-internal 「。」 between two sentences is fine.
- Keep it as short as the English. Many strings sit in narrow rows, segmented controls and the menu bar.

## Punctuation and spacing

- Full-width 「、」「。」 inside sentences; quotes 「」, nested 『』; full-width parentheses （）.
- No space between Japanese and Latin letters or digits (「Apple Musicで再生」「3曲」).
- Keep `…` (single ellipsis character) where the source has it; buttons that open a dialog end with 「…」 like macOS (「書き出す…」).
- Keep keyboard symbols (⌘ ⌥ ⇧ ⌃), emoji, `\n`, Markdown (`**`, links) and URLs exactly.

## Placeholders

- Every `%@`, `%d`, `%lld`, `%.1f`, `%1$@`… in the source must appear in the translation with the same number, order of arguments and type. Never turn `%d` into `%@`.
- If Japanese word order needs the arguments in a different order and the source has two or more arguments, switch to positional form (`%2$@ … %1$@`) keeping each argument's type.
- `%%` is a literal percent sign.
- Japanese has no plural forms: entries that are plural in English get a single Japanese string.

## Names that stay as they are

Lyrimuse, Last.fm, ListenBrainz, Discord, Telegram, Slack, Bark, ntfy, Server酱 (ServerChan), Apple Music, Spotify, YouTube Music, Genius, Cloudflare, GitHub, Sparkle, Touch Bar, Dock, Finder.
Chinese music services use the names in the English string (NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Soda Music…).

## Glossary

| Simplified Chinese | English | Japanese |
|---|---|---|
| 歌词 | Lyrics | 歌詞 |
| 播放器 | Player | プレーヤー |
| 歌词显示 | Lyrics Display | 歌詞の表示 |
| 快捷键 | Keyboard Shortcuts | キーボードショートカット |
| 通用 | General | 一般 |
| 关于 | About | 情報 |
| 实验室 | Labs | ラボ |
| 推送提醒 | Push Alerts | プッシュ通知 |
| 网页推送 | Web Push | Webプッシュ |
| 关联平台 | Linked Platforms | 連携サービス |
| 桌面悬浮歌词 / 悬浮歌词 | (Desktop) Floating Lyrics | （デスクトップの）フローティング歌詞 |
| 灵动岛 | Notch | ノッチ |
| 菜单栏 | Menu Bar | メニューバー |
| 歌词窗口 | Lyrics Window | 歌詞ウインドウ |
| 歌词管理 | Lyrics Manager | 歌詞マネージャ |
| 歌词库 | Lyrics Library | 歌詞ライブラリ |
| 歌词来源 / 歌词源 | Lyrics Sources | 歌詞ソース |
| 译文 | Translation | 翻訳 |
| 罗马音 | Romanization | ローマ字 |
| 逐字歌词 | Word-by-word lyrics | 単語ごとの歌詞 |
| 打卡 / scrobble | Scrobble | Scrobble（動詞は「Scrobbleする」） |
| 收听记录 | Listening history | 再生履歴 |
| 听歌报告 / 听歌小结 | Listening Report / Digest | リスニングレポート / リスニングまとめ |
| 推送渠道 | Push Channels | 送信先 |
| 偏移 | Offset | オフセット |
| 封面 | Artwork | アートワーク |
| 专辑 / 歌手 / 歌曲 | Album / Artist / Track | アルバム / アーティスト / 曲 |
| 设置 | Settings | 設定 |
| 跟随系统 | Follow System | システムに合わせる |
| 外观 | Appearance | 外観モード |
| 辅助功能 | Accessibility | アクセシビリティ |
| 自动化 | Automation | オートメーション |
| 完全磁盘访问 | Full Disk Access | フルディスクアクセス |
| 登录时打开 | Open at Login | ログイン時に開く |
| 检查更新 | Check for Updates | アップデートを確認 |
| 导入 / 导出 | Import / Export | 読み込む / 書き出す |
| 候选 | Candidates | 候補 |
| 搜索 | Search | 検索 |
| 取消 / 完成 / 好 | Cancel / Done / OK | キャンセル / 完了 / OK |
| 保存 / 删除 / 重置 | Save / Delete / Reset | 保存 / 削除 / リセット |
| 关闭 | Close | 閉じる |
| 高级 | Advanced | 詳細 |
| 诊断 | Diagnostics | 診断 |
