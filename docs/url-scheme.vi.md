# Lược đồ URL của Lyrimuse

*[English](url-scheme.md) · [简体中文](url-scheme.zh-CN.md) · [日本語](url-scheme.ja.md) · [한국어](url-scheme.ko.md) · [Español](url-scheme.es.md) · [Français](url-scheme.fr.md) · [Deutsch](url-scheme.de.md) · [Italiano](url-scheme.it.md) · [Português (Brasil)](url-scheme.pt-BR.md) · **Tiếng Việt** · [Русский](url-scheme.ru.md) · [Українська](url-scheme.uk.md) · [ไทย](url-scheme.th.md)*

Các liên kết bắt đầu bằng `lyrimuse://` cho phép bạn điều khiển Lyrimuse từ Phím tắt, Raycast, Alfred, Stream Deck, Terminal (`open 'lyrimuse://…'`) và các công cụ tương tự: mở cửa sổ và trang cài đặt, hiện hoặc ẩn lời bài hát, điều khiển phát, chỉnh nhanh thời gian lời hoặc lấy thông tin bài đang phát.

Các liên kết thông dụng có thể sao chép từ mục **Deep link** ở cuối Cài đặt › Phím tắt. Di chuột lên phím tắt bất kỳ ở đó để sao chép liên kết của thao tác tương ứng.

## Quy tắc chung

- Liên kết không phân biệt chữ hoa chữ thường.
- Liên kết mà Lyrimuse không nhận ra sẽ không làm gì và hiện “Liên kết không nhận diện được”.
- Mọi liên kết mở cửa sổ đều nhận `background=1`: cửa sổ vẫn hiện ra, nhưng Lyrimuse không chuyển lên phía trước và không lấy tiêu điểm bàn phím. Ví dụ: `lyrimuse://lyrics-window?background=1`.
- Các thao tác bật/tắt nhận `on=1` hoặc `on=0` để đặt trạng thái đích (`true` / `false` và `on` / `off` cũng dùng được), nên chạy hai lần vẫn cho cùng một kết quả. Khi không có tham số này, thao tác sẽ đảo trạng thái hiện tại.
- Trang web cũng có thể mở liên kết `lyrimuse://` (trình duyệt sẽ hỏi bạn trước), vì vậy Lyrimuse chỉ mở ra những thao tác dễ hoàn tác: bật/tắt, mở cửa sổ, điều khiển phát và chỉnh nhanh thời gian lời. Không liên kết nào xóa hay sửa lời bài hát, hoặc động đến tài khoản của bạn.

## Mở cửa sổ

| Liên kết | Chức năng |
|---|---|
| `lyrimuse://lyrics-window` | Mở cửa sổ lời |
| `lyrimuse://lyrics-window/search` | Mở cửa sổ lời và cửa sổ “Tìm lời bài hát” (cũng là cửa sổ mà `lyrics-search` mở) |
| `lyrimuse://lyrics-manager` | Mở Quản lý lời |
| `lyrimuse://lyrics-search` | Mở cửa sổ “Tìm lời bài hát” cho bài hát hiện tại |
| `lyrimuse://menubar-panel` | Mở hoặc đóng bảng thanh menu |
| `lyrimuse://menubar-panel?quick=overlay` | Mở bảng thanh menu ở phần cài đặt nhanh của một ô (chỉ mở, không bao giờ đóng). `quick` là một trong `overlay`, `notch`, `menubar`, `touchbar`, `lyrics-window`, `lyrics-manager` |
| `lyrimuse://menubar-menu` | Mở menu của biểu tượng trên thanh menu |
| `lyrimuse://onboarding` | Mở hướng dẫn thiết lập |
| `lyrimuse://whats-new` | Hiện tính năng mới trong phiên bản đã cài |

## Mở cài đặt

`lyrimuse://settings` mở Cài đặt. Thêm một đường dẫn để đi thẳng đến một trang, và thêm một đoạn nữa để đi đến một mục trên trang đó.

| Đường dẫn | Trang | Mục |
|---|---|---|
| `/lyrics` | Lời bài hát | `/fetch` hoặc `/sources` Nguồn, `/translation` hoặc `/language` Ngôn ngữ, `/display` hoặc `/timing` Mốc thời gian, `/manage` hoặc `/library` Thư viện lời |
| `/player` | Trình phát | `/players` Trình phát, `/linkage` Mở & thoát, `/permissions` Quyền & dịch vụ |
| `/appearance` | Hiển thị lời | `/overlay` Lời nổi, `/notch` Notch, `/menu-bar` Thanh menu, `/touch-bar` Touch Bar, `/lyrics-window` Cửa sổ lời |
| `/shortcuts` | Phím tắt | — |
| `/general` | Cài đặt chung | — |
| `/about` | Giới thiệu | — |
| `/account/lastfm` | Last.fm | `/stats` Thống kê, `/chart` Bảng xếp hạng, `/on-this-day` Dấu chân, `/settings` Quy tắc |
| `/account/listenbrainz` | ListenBrainz | — |
| `/account/discord` | Discord | `/display` Nội dung, `/buttons` Nút, `/privacy` Quyền riêng tư |
| `/account/relay` | Đẩy web | — |
| `/account/bark` | Thông báo đẩy | — |
| `/software-update` | Cập nhật phần mềm | Thêm `?check=1` để kiểm tra bản cập nhật luôn |
| `/lastfm-suggestions` | Gợi ý cho tài khoản Last.fm | — |
| `/labs` | Thử nghiệm | — |

Ví dụ: `lyrimuse://settings/appearance/overlay` hoặc `lyrimuse://settings/software-update?check=1`. Đường dẫn không xác định chỉ mở Cài đặt; mục không xác định sẽ mở trang đó ở mục bạn xem gần nhất.

## Thao tác: `lyrimuse://action/<name>`

Đây chính là các thao tác của phím tắt trong Cài đặt › Phím tắt. Chúng chạy cùng một đoạn mã và hiện cùng một phản hồi.

### Hiển thị

| Tên | Chức năng | Tham số |
|---|---|---|
| `toggle-overlay` | Hiện hoặc ẩn lời nổi | `on` |
| `toggle-notch` | Hiện hoặc ẩn lời trên Notch | `on` |
| `peek-notch` | Mở rộng lời trên Notch trong vài giây; chạy lại để đóng sớm | — |
| `toggle-menubar-lyrics` | Hiện hoặc ẩn lời trên thanh menu | `on` |
| `toggle-touchbar` | Mở rộng hoặc thu gọn lời trên Touch Bar (chỉ với máy Mac có Touch Bar) | — |
| `toggle-all-lyrics` | Ẩn mọi lời: lời nổi, lời trên Notch và lời trên thanh menu, cái nào đang bật sẽ bị ẩn, và chạy lại sẽ hiện lại đúng những cái đó | `on` (`0` ẩn, `1` khôi phục) |
| `toggle-lock-position` | Khóa hoặc mở khóa vị trí của lời nổi | `on` |
| `toggle-translation` | Hiện hoặc ẩn bản dịch | `on` |
| `toggle-romanization` | Hiện hoặc ẩn phát âm | `on` |
| `overlay-font-larger` | Phóng to lời nổi | — |
| `overlay-font-smaller` | Thu nhỏ lời nổi | — |

### Cửa sổ

| Tên | Chức năng | Tham số |
|---|---|---|
| `open-lyrics-manager` | Mở Quản lý lời | — |
| `open-lyrics-window` | Mở cửa sổ lời | — |
| `toggle-lyrics-window-mini` | Chuyển cửa sổ lời giữa cỡ mini và cỡ đầy đủ; nếu cửa sổ đang đóng thì mở ở cỡ mini | `on` (`1` mini, `0` đầy đủ) |
| `search-lyrics` | Mở cửa sổ “Tìm lời bài hát” | — |
| `open-settings` | Mở Cài đặt | — |
| `open-player` | Đưa trình phát bạn đang dùng lên phía trước | — |
| `toggle-menubar-panel` | Mở hoặc đóng bảng trên thanh menu, giống như bấm vào biểu tượng | — |

### Thời gian lời

| Tên | Chức năng | Tham số |
|---|---|---|
| `lyrics-advance` | Đẩy lời của bài này sớm hơn một bước | `step`: số giây cho lần chỉnh này (0 đến 5); bỏ trống thì dùng bước nhảy trong Cài đặt |
| `lyrics-delay` | Lùi lời của bài này muộn hơn một bước | `step`, như trên |
| `lyrics-offset-reset` | Đặt lại độ lệch lời của bài này về 0 | — |

### Phát lại

| Tên | Chức năng | Tham số |
|---|---|---|
| `play-pause` | Phát/Tạm dừng | — |
| `next-track` | Bài tiếp theo | — |
| `previous-track` | Bài trước | — |
| `toggle-favorite` | Thêm hoặc bỏ bài hiện tại khỏi mục ưa thích (nếu trình phát hỗ trợ) | `on` (`1` ưa thích, `0` bỏ) |

Ví dụ: `lyrimuse://action/toggle-overlay?on=0` hoặc `lyrimuse://action/lyrics-advance?step=0.5`.

### Thao tác khác

| Liên kết | Chức năng |
|---|---|
| `lyrimuse://action/copy-lyric` | Sao chép dòng lời hiện tại vào bảng nhớ tạm; thêm `?translation=1` để kèm bản dịch |
| `lyrimuse://action/surfaces?overlay=1&notch=0&menubar=1` | Đặt cùng lúc những lời nào được hiện: `overlay` (lời nổi), `notch`, `menubar`, mỗi tham số là `1` để hiện hoặc `0` để ẩn. Chỉ cần ghi những tham số bạn muốn đổi |
| `lyrimuse://action/lyrics-offset?ms=-300` | Đặt độ lệch lời của bài này đúng bằng một giá trị tính bằng mili giây: số dương là sớm hơn, số âm là muộn hơn, trong khoảng ±10000 |
| `lyrimuse://action/play-mode?mode=shuffle` | Đặt chế độ phát: `mode` là `list`, `shuffle`, `repeat-all` hoặc `repeat-one`. Chế độ nào trình phát không hỗ trợ sẽ quay về `list` |

## Lấy bài đang phát (x-callback-url)

```
lyrimuse://x-callback-url/now-playing?x-success=<callback URL>
```

Lyrimuse mở URL `x-success` kèm thông tin bài đang phát dưới dạng tham số (các tham số sẵn có trên `x-success` vẫn được giữ nguyên):

| Tham số | Giá trị |
|---|---|
| `title` | Tên bài hát |
| `artist` | Nghệ sĩ |
| `album` | Album |
| `lyric` | Dòng lời hiện tại |
| `player` | Tên trình phát |
| `playing` | `1` khi đang phát, `0` khi tạm dừng hoặc chưa có bài nào (khi chưa có bài, các trường ở trên đều trống) |

Trong ứng dụng Phím tắt, dùng tác vụ **Mở URL X-Callback** với URL là `lyrimuse://x-callback-url/now-playing`. Phím tắt tự thêm `x-success`, và các tham số trả về trở thành đầu ra của tác vụ.

Để trang web không thể dùng liên kết này xem bạn đang nghe gì, URL gọi lại có hai giới hạn: không được là URL web, tệp hay script (`http`, `https`, `file`, `ftp`, `javascript`, `data`, `about`, `blob`, hoặc chính `lyrimuse`), và trên máy Mac của bạn, URL này phải được mở bởi một ứng dụng không phải trình duyệt. Nếu không, sẽ không có gì được gửi lại.
