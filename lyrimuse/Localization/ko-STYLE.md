# Korean (ko) translation style

Lyrimuse's UI strings live in `lyrimuse/Localization/Localizable.xcstrings`. The key of every entry is the Simplified Chinese source text; the `en` value is the closest reference for meaning and length. Translate into natural Korean as it would appear in a macOS app, then run `python3 lyrimuse/Localization/generate-strings.py`.

## Voice

- Follow the wording Apple uses in Korean macOS (시스템 설정, 음악, Finder). When Apple has a term, use it.
- Labels, buttons, menu items, section titles: short noun phrases or the plain verb form Apple uses on buttons (「저장」「취소」「가사 검색」).
- Descriptions, help text, status and error messages: 합니다체 (「가사를 찾을 수 없습니다」「~을(를) 표시합니다」).
- No trailing period at the end of any string, even long ones. A period between two sentences is fine.
- Keep it as short as the English. Many strings sit in narrow rows, segmented controls and the menu bar.
- Pick the right particle after placeholders when you can; when the word is unknown, use the combined form 을(를), 이(가), 은(는), (으)로.

## Punctuation and spacing

- Normal Korean word spacing (띄어쓰기). Space between Korean and Latin words as in normal Korean text.
- Quotes ‘ ’ for UI terms, “ ” for quoted speech; half-width parentheses ( ).
- Keep `…` (single ellipsis character) where the source has it; buttons that open a dialog end with 「…」 like macOS (「내보내기…」).
- Keep keyboard symbols (⌘ ⌥ ⇧ ⌃), emoji, `\n`, Markdown (`**`, links) and URLs exactly.

## Placeholders

- Every `%@`, `%d`, `%lld`, `%.1f`, `%1$@`… in the source must appear in the translation with the same number, order of arguments and type. Never turn `%d` into `%@`.
- If Korean word order needs the arguments in a different order and the source has two or more arguments, switch to positional form (`%2$@ … %1$@`) keeping each argument's type.
- `%%` is a literal percent sign.
- Korean has no plural forms: entries that are plural in English get a single Korean string.

## Names that stay as they are

Lyrimuse, Last.fm, ListenBrainz, Discord, Telegram, Slack, Bark, ntfy, Server酱 (ServerChan), Apple Music, Spotify, YouTube Music, Genius, Cloudflare, GitHub, Sparkle, Touch Bar, Dock, Finder.
Chinese music services use the names in the English string (NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Soda Music…).

## Glossary

| Simplified Chinese | English | Korean |
|---|---|---|
| 歌词 | Lyrics | 가사 |
| 播放器 | Player | 플레이어 |
| 歌词显示 | Lyrics Display | 가사 표시 |
| 快捷键 | Keyboard Shortcuts | 키보드 단축키 |
| 通用 | General | 일반 |
| 关于 | About | 정보 |
| 实验室 | Labs | 실험실 |
| 推送提醒 | Push Alerts | 푸시 알림 |
| 网页推送 | Web Push | 웹 푸시 |
| 关联平台 | Linked Platforms | 연결된 서비스 |
| 桌面悬浮歌词 / 悬浮歌词 | (Desktop) Floating Lyrics | (데스크탑) 플로팅 가사 |
| 灵动岛 | Notch | 노치 |
| 菜单栏 | Menu Bar | 메뉴 막대 |
| 歌词窗口 | Lyrics Window | 가사 윈도우 |
| 歌词管理 | Lyrics Manager | 가사 관리자 |
| 歌词库 | Lyrics Library | 가사 보관함 |
| 歌词来源 / 歌词源 | Lyrics Sources | 가사 소스 |
| 译文 | Translation | 번역 |
| 罗马音 | Romanization | 로마자 표기 |
| 逐字歌词 | Word-by-word lyrics | 단어별 가사 |
| 打卡 / scrobble | Scrobble | 스크로블 |
| 收听记录 | Listening history | 재생 기록 |
| 听歌报告 / 听歌小结 | Listening Report / Digest | 청취 리포트 / 청취 요약 |
| 推送渠道 | Push Channels | 알림 채널 |
| 偏移 | Offset | 오프셋 |
| 封面 | Artwork | 아트워크 |
| 专辑 / 歌手 / 歌曲 | Album / Artist / Track | 앨범 / 아티스트 / 노래 |
| 设置 | Settings | 설정 |
| 跟随系统 | Follow System | 시스템 설정에 따름 |
| 外观 | Appearance | 화면 모드 |
| 辅助功能 | Accessibility | 손쉬운 사용 |
| 自动化 | Automation | 자동화 |
| 完全磁盘访问 | Full Disk Access | 전체 디스크 접근 권한 |
| 登录时打开 | Open at Login | 로그인 시 열기 |
| 检查更新 | Check for Updates | 업데이트 확인 |
| 导入 / 导出 | Import / Export | 가져오기 / 내보내기 |
| 候选 | Candidates | 후보 |
| 搜索 | Search | 검색 |
| 取消 / 完成 / 好 | Cancel / Done / OK | 취소 / 완료 / 확인 |
| 保存 / 删除 / 重置 | Save / Delete / Reset | 저장 / 삭제 / 재설정 |
| 关闭 | Close | 닫기 |
| 高级 | Advanced | 고급 |
| 诊断 | Diagnostics | 진단 |
