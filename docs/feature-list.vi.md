<!-- Được tạo bởi scripts/gen-feature-list.py từ shared/feature-list.json và shared/settings-catalog.json; muốn sửa danh sách, hãy sửa các tệp đó. -->

# Danh sách tính năng của Lyrimuse

[English](feature-list.md) · [简体中文](feature-list.zh-CN.md) · [繁體中文](feature-list.zh-Hant.md) · [日本語](feature-list.ja.md) · [한국어](feature-list.ko.md) · [Español](feature-list.es.md) · [Français](feature-list.fr.md) · [Deutsch](feature-list.de.md) · [Italiano](feature-list.it.md) · [Português (Brasil)](feature-list.pt-BR.md) · Tiếng Việt · [Русский](feature-list.ru.md) · [Українська](feature-list.uk.md) · [ไทย](feature-list.th.md)

Lyrimuse là ứng dụng mã nguồn mở (GPL-3.0) cho máy Mac, hiển thị lời bài hát đồng bộ theo từng chữ, dành cho macOS 14 trở lên trên Apple Silicon và Intel. Ứng dụng hiển thị lời cho Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Soda Music, KKBOX, Amazon Music, LX Music, Kaset, Pear Desktop, reAMP, VOX, Pine Player, foobar2000, MyGo Music, cùng YouTube Music hoặc Spotify Web phát trong trình duyệt: nổi trên màn hình nền, cạnh notch, trên thanh menu, trên Touch Bar hoặc trong cửa sổ lời đầy đủ, kèm bản dịch và phát âm (bính âm, Jyutping tiếng Quảng Đông, romaji tiếng Nhật, Latinh hóa tiếng Hàn). Lyrimuse scrobble lên Last.fm và ListenBrainz, và có thể hiển thị bài bạn đang phát trên Discord. Giao diện có tiếng Anh, tiếng Trung giản thể, tiếng Trung phồn thể, tiếng Nhật, tiếng Hàn, tiếng Tây Ban Nha, tiếng Pháp, tiếng Đức, tiếng Ý, tiếng Bồ Đào Nha (Brazil), tiếng Việt, tiếng Nga, tiếng Ukraina và tiếng Thái. WeRead còn hiển thị nguyên văn đang được đọc trong sách nói dưới dạng phụ đề.

Danh sách này tập hợp mọi tính năng của Lyrimuse: mỗi tính năng làm gì, nằm ở đâu trong cài đặt và có bật sẵn sau khi cài hay không; cuối trang là toàn bộ mục trong cửa sổ Cài đặt. Danh sách được duy trì cùng mã nguồn và cập nhật theo mỗi thay đổi.

## Mục lục

- [Tắt cho đến khi bạn bật](#section-off-by-default)
- [Tìm lời bài hát](#section-lyrics)
- [Bản dịch, phát âm và xử lý dòng lời](#section-text)
- [Lời hiển thị ở đâu và trông ra sao](#section-display)
- [Trình phát và điều khiển phát](#section-players)
- [Scrobble, Last.fm và chia sẻ](#section-listening)
- [Dùng hằng ngày](#section-general)
- [Toàn bộ cài đặt](#section-all-settings)

<a id="section-off-by-default"></a>

## Tắt cho đến khi bạn bật

Các tính năng này tắt sau khi cài. Hãy bật chúng trong cài đặt trước (một số còn cần tài khoản hoặc quyền truy cập):

| Tính năng | Bật ở đâu |
|---|---|
| [Lời bài hát của chính Apple Music](#feature-apple-music-lyrics) | Cài đặt › Lời bài hát › Nguồn › Nguồn lời bài hát |
| [Dùng lời mà trình phát đã lưu sẵn](#feature-player-local-lyrics) | Cài đặt › Trình phát › Quyền & dịch vụ › Quyền truy cập đầy đủ vào ổ đĩa |
| [Ưu tiên lời trong tệp bài hát](#feature-prefer-local-file-lyrics) | Cài đặt › Lời bài hát › Nguồn › Ưu tiên lời trong tệp bài hát |
| [Khóa lời đã chọn thủ công](#feature-lock-hand-picked) | Cài đặt › Lời bài hát › Nguồn › Khóa lời đã chọn thủ công |
| [Tự dịch khi không có bản dịch](#feature-machine-translation) | Cài đặt › Lời bài hát › Ngôn ngữ › Tự dịch khi không có bản dịch |
| [Tách dòng dài, gộp dòng ngắn](#feature-split-join-lines) | Cài đặt › Lời bài hát › Thời gian & ngắt câu › Tách dòng dài |
| [Lời trên Notch](#feature-notch-lyrics) | Cài đặt › Hiển thị lời › Notch › Lời trên Notch |
| [Lời trên thanh menu](#feature-menu-bar-lyrics) | Cài đặt › Hiển thị lời › Thanh menu › Lời trên thanh menu |
| [Lời trên Touch Bar](#feature-touch-bar-lyrics) | Cài đặt › Hiển thị lời › Touch Bar › Lời trên Touch Bar |
| [Tô sáng HDR cho cửa sổ lời](#feature-lyrics-window-hdr) | Cài đặt › Hiển thị lời › Cửa sổ lời › Màu › Tô sáng HDR |
| [Cửa sổ mini ẩn khi tạm dừng hoặc toàn màn hình](#feature-mini-window-auto-hide) | Cài đặt › Hiển thị lời › Cửa sổ lời › Hành vi › Ẩn khi tạm dừng |
| [Nền Spotify Canvas](#feature-spotify-canvas) | Cài đặt › Hiển thị lời › Cửa sổ lời › Nền › Spotify Canvas |
| [Hiệu ứng chuyển dòng](#feature-line-transition) | Cài đặt › Hiển thị lời › Lời nổi › Bố cục › Hiệu ứng chuyển dòng |
| [Mờ đi khi con trỏ ở trên](#feature-fade-on-hover) | Cài đặt › Hiển thị lời › Lời nổi › Hành vi › Làm mờ khi di chuột qua |
| [Khóa vị trí, nhấn giữ để kéo](#feature-lock-position) | Cài đặt › Hiển thị lời › Lời nổi › Hành vi › Khóa vị trí |
| [Ẩn khỏi ảnh chụp màn hình và chia sẻ màn hình](#feature-hide-in-screenshots) | Cài đặt › Hiển thị lời › Lời nổi › Hành vi › Ẩn khi chụp màn hình |
| [Ẩn hoặc thu nhỏ khi tạm dừng](#feature-hide-when-paused) | Cài đặt › Hiển thị lời › Lời nổi › Hành vi › Ẩn khi tạm dừng |
| [Ẩn khi nhạc không lời và bài không có lời](#feature-hide-when-no-lyrics) | Cài đặt › Hiển thị lời › Lời nổi › Hành vi › Ẩn khi nhạc không lời/không có lời |
| [Tự ẩn khi có quảng cáo](#feature-hide-during-ads) | Cài đặt › Hiển thị lời › Lời nổi › Hành vi › Ẩn khi có quảng cáo |
| [Notch trên Màn hình khóa](#feature-notch-show-on-lock-screen) | Cài đặt › Hiển thị lời › Notch › Hành vi › Hiện trên màn hình khóa |
| [Lời nổi tự ẩn khi toàn màn hình](#feature-overlay-hide-in-full-screen) | Cài đặt › Hiển thị lời › Lời nổi › Hành vi › Ẩn khi toàn màn hình |
| [Làm mờ dòng lời trên Notch khi di chuột](#feature-notch-lyric-row-fade) | Cài đặt › Hiển thị lời › Notch › Dòng lời › Làm mờ khi di chuột qua |
| [Lời trên web: điện thoại hoặc máy tính bảng làm màn hình phụ, hoặc nguồn trình duyệt OBS](#feature-web-lyrics) | Cài đặt › Hiển thị lời › Cửa sổ lời › Lời trên web |
| [YouTube Music và Spotify Web trong trình duyệt](#feature-web-players) | Cài đặt › Trình phát › Web |
| [Tự động bỏ qua quảng cáo YouTube Music](#feature-skip-youtube-ads) | Cài đặt › Trình phát › Web › Tự bỏ qua quảng cáo |
| [Mở và thoát cùng trình phát](#feature-player-linkage) | Cài đặt › Trình phát › Mở & thoát › Mở trình phát khi khởi động |
| [Scrobble lên Last.fm và hồ sơ nghe nhạc](#feature-lastfm) | Cài đặt › Last.fm › Quy tắc › Quy tắc Scrobble |
| [Scrobble cả lên ListenBrainz](#feature-listenbrainz) | Cài đặt › Thử nghiệm › ListenBrainz › Thông tin tài khoản |
| [Hiển thị bài bạn đang phát trên Discord](#feature-discord) | Cài đặt › Discord › Hiện trên Discord |
| [Trang web đang phát có thể chia sẻ](#feature-now-playing-page) | Cài đặt › Thử nghiệm › Đẩy web › Thông tin kết nối |
| [Tổng kết nghe nhạc hằng ngày, hằng tuần, hằng tháng và hằng năm](#feature-digests) | Cài đặt › Thông báo đẩy › Kênh |
| [Khởi động ẩn](#feature-silent-launch) | Cài đặt › Cài đặt chung › Khởi động & thông báo › Khởi động ẩn |
| [Thông báo khi đổi bài](#feature-song-notifications) | Cài đặt › Cài đặt chung › Khởi động & thông báo › Thông báo khi đổi bài |
| [Tự động cập nhật và bản beta](#feature-updates) | Cài đặt › Cập nhật phần mềm › Cài đặt cập nhật › Tự động kiểm tra |

<a id="section-lyrics"></a>

## Tìm lời bài hát

<a id="feature-lyric-sources"></a>

### 15 nguồn lời bài hát, tìm tự động

NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Musixmatch, LRCLIB, LyricFind, Deezer, AMLL, Soda Music, VIBE, Genie, PetitLyrics và Apple Music. Mỗi nguồn đều có thể tắt, sắp xếp lại hoặc kiểm tra xem hiện có kết nối được không.

- Bật theo mặc định
- Cài đặt: Lời bài hát › Nguồn › Nguồn lời bài hát

<a id="feature-network-proxy"></a>

### Thử lại nguồn lời nước ngoài qua proxy

Khi không kết nối trực tiếp được tới một nguồn lời nước ngoài, Lyrimuse thử lại qua proxy hệ thống hoặc proxy cục bộ như Clash. Bạn cũng có thể tự nhập máy chủ proxy, hoặc tắt tính năng này. Các nguồn lời ở Trung Quốc đại lục luôn kết nối trực tiếp.

- Bật theo mặc định
- Cài đặt: Cài đặt chung › Mạng › Proxy

<a id="feature-apple-music-lyrics"></a>

### Lời bài hát của chính Apple Music

Kết nối tài khoản Apple Music trong “Nguồn lời bài hát” để dùng lời bài hát của chính Apple Music, nhiều bài có thời gian theo từng chữ. Cần gói đăng ký Apple Music.

- Tắt theo mặc định
- Cài đặt: Lời bài hát › Nguồn › Nguồn lời bài hát

<a id="feature-matching"></a>

### Khớp thông minh

Theo mặc định, mỗi kết quả được chấm điểm theo tên bài hát, nghệ sĩ, thời lượng và phiên bản (bản live, bản không lời…), và kết quả phù hợp nhất với bài đang phát sẽ được chọn. Bạn cũng có thể chuyển sang “Theo thứ tự ưu tiên”: không chấm điểm, dùng nguồn đầu tiên theo thứ tự của bạn có lời bài hát.

- Cài đặt: Lời bài hát › Nguồn › Thuật toán khớp

<a id="feature-auto-upgrade"></a>

### Chọn lại lời khi cách khớp được cải thiện

Khi một phiên bản mới cải thiện cách khớp hoặc chấm điểm, Lyrimuse kiểm tra lại lời bạn đã có ở chế độ nền và thay thế nếu tìm thấy bản tốt hơn. Tắt tùy chọn này để giữ nguyên lời sau khi đã chọn.

- Bật theo mặc định
- Cài đặt: Lời bài hát › Nguồn › Chọn lại khi thuật toán được cập nhật

<a id="feature-prefetch"></a>

### Lời sẵn sàng trước bài tiếp theo

Lyrimuse đọc hàng đợi của trình phát và tìm trước lời cho vài bài tiếp theo; khi không có hàng đợi để đọc, ứng dụng tìm lời cho các bài còn lại trong album. QQ Music, NetEase Cloud Music, Kugou, Soda Music và VOX cần Quyền truy cập đầy đủ vào ổ đĩa cho việc này.

- Bật theo mặc định
- Cài đặt: Lời bài hát › Nguồn › Xử lý trước bài sắp phát
- Cài đặt: Trình phát › Quyền & dịch vụ › Quyền truy cập đầy đủ vào ổ đĩa

<a id="feature-player-local-lyrics"></a>

### Dùng lời mà trình phát đã lưu sẵn

Lời bài hát mà Apple Music, Spotify, Kugou, KKBOX, Amazon Music và LX Music đã lưu trên máy Mac này có thể dùng trực tiếp: đúng phiên bản trình phát hiển thị, lại nhanh hơn (với Apple Music và Spotify, chỉ có ở những bài mà trình phát đã từng hiển thị lời). Với QQ Music và NetEase Cloud Music, bài hát được nhận diện qua thư viện cục bộ của trình phát, nên Lyrimuse lấy đúng phiên bản đó mà không cần tìm kiếm. Với reAMP, VOX, Pine Player và foobar2000, cũng như khi Apple Music hoặc LX Music phát một tệp cục bộ trong thư viện hoặc danh sách cục bộ, Lyrimuse dùng lời nhúng trong tệp đang phát hoặc tệp .lrc cùng tên. QQ Music, NetEase Cloud Music và Kugou cần bật Quyền truy cập đầy đủ vào ổ đĩa cho Lyrimuse trong Cài đặt hệ thống; nếu không, lời vẫn được tìm trên mạng.

- Tắt theo mặc định
- Cài đặt: Trình phát › Quyền & dịch vụ › Quyền truy cập đầy đủ vào ổ đĩa

<a id="feature-prefer-local-file-lyrics"></a>

### Ưu tiên lời trong tệp bài hát

Khi bài đang phát là một tệp trên máy Mac này, Lyrimuse dùng trước tệp .lrc cùng tên hoặc lời nhúng trong tệp, thay vì so sánh với lời tìm được trên mạng. Tính năng hoạt động với mọi trình phát có phát tệp cục bộ. Nếu lời đó không khớp với phiên bản này (ví dụ thời lượng không khớp), Lyrimuse tìm lời trên mạng như bình thường.

- Tắt theo mặc định
- Cài đặt: Lời bài hát › Nguồn › Ưu tiên lời trong tệp bài hát

<a id="feature-lock-hand-picked"></a>

### Khóa lời đã chọn thủ công

Khi bật, lời bạn tự chọn từ kết quả tìm kiếm sẽ bị khóa, các lần tự động khớp và tìm lại sau đó không thay thế được.

- Tắt theo mặc định
- Cài đặt: Lời bài hát › Nguồn › Khóa lời đã chọn thủ công

<a id="feature-lyrics-manager"></a>

### Quản lý lời

Duyệt, sửa, xóa hoặc tìm lại lời của bất kỳ bài hát nào, xóa hàng loạt, và dọn các mục trống do quảng cáo và podcast để lại. Đặt độ lệch thời gian riêng cho từng bài. Thử lại cùng lúc mọi bài chưa có lời, hoặc tìm lại lời cho cả thư viện theo quy tắc hiện tại, với khoảng nghỉ giữa các bài có thể điều chỉnh; mọi thứ bạn đã sửa thủ công đều được giữ nguyên.

- Cài đặt: Lời bài hát › Thư viện lời › Thư viện lời
- Cài đặt: Lời bài hát › Thư viện lời › Tự động tìm lời còn thiếu
- Cài đặt: Lời bài hát › Thư viện lời › Tìm lại lời cho cả thư viện
- Cài đặt: Phím tắt › Mở Quản lý lời
- Cài đặt: Lời bài hát › Thư viện lời › Khoảng cách quét

<a id="feature-song-entries"></a>

### Mục của cùng một bài hát

Cùng một bài hát phát trên các trình phát khác nhau hoặc từ các bản phát hành khác nhau được nhận diện là một bài: các mục dùng chung một bộ lời, chỉnh sửa thủ công và hiệu chỉnh thời gian được áp dụng chung, lượt phát được cộng dồn. Trong Quản lý lời, “Mục cùng bài” so sánh lời của từng mục theo từng dòng; mục bị khớp nhầm có thể tách ra và sau này hợp nhất lại. Tắt tính năng dùng chung để mỗi mục được khớp lời riêng.

- Bật theo mặc định
- Cài đặt: Lời bài hát › Nguồn › Dùng chung lời cho các mục cùng bài

<a id="feature-fix-lyrics"></a>

### Đổi hoặc sửa lời ngay tại chỗ

Từ menu ⋯ của cửa sổ lời, tìm lời khác, khớp lại lần nữa, hoặc sửa lời trong trình soạn thảo văn bản của bạn. Khi sửa lời theo từng chữ, chỉ chữ thay đổi, thời gian giữ nguyên.

- Cài đặt: Phím tắt › Tìm lời bài hát

<a id="feature-import-lyrics"></a>

### Nhập tệp lời của riêng bạn

Nhập lời LRC, LRC nâng cao, TTML, QRC, KRC, YRC hoặc văn bản thuần cho một bài, hoặc cả một thư mục cùng lúc: Lyrimuse ghép từng tệp với bài hát trong thư viện và cho bạn xem trước rồi mới ghi. Chọn để lời nhập vào thay thế lời hiện tại, thay thế và khóa, hoặc chỉ bổ sung cho bài chưa có lời. Tệp của bài bạn chưa phát được giữ lại và dùng khi bài đó phát lần đầu. Thư mục theo dõi tự động nhập tệp mới.

- Cài đặt: Lời bài hát › Thư viện lời › Nhập thư mục lời
- Cài đặt: Lời bài hát › Thư viện lời › Cách nhập thư mục
- Cài đặt: Lời bài hát › Thư viện lời › Thư mục theo dõi
- Cài đặt: Lời bài hát › Thư viện lời › Thư viện nhập

<a id="feature-offline"></a>

### Dùng được khi ngoại tuyến; lời là tệp .lrc thông thường

Mọi lời tìm được đều được lưu đệm trên máy Mac của bạn và hiển thị cả khi không có kết nối. Mỗi bài có một tệp .lrc, cùng .tr.lrc và .roma.lrc cho bản dịch và phát âm. Thời gian theo từng chữ mặc định lưu dạng TTML, hoặc dạng .yrc, LRC nâng cao, QRC hay KRC. Theo mặc định, các tệp nằm trong ~/Library/Application Support/me.yudaotor.lyrimuse/lyrics/, và có thể chuyển thư mục sang nơi khác.

- Cài đặt: Lời bài hát › Thư viện lời › Thư mục lời bài hát
- Cài đặt: Lời bài hát › Thư viện lời › Định dạng lời theo từng chữ

<a id="section-text"></a>

## Bản dịch, phát âm và xử lý dòng lời

<a id="feature-translation"></a>

### Bản dịch

Bản dịch đi kèm lời bài hát hiển thị dưới mỗi dòng. NetEase Cloud Music, QQ Music và Kugou dịch sang tiếng Trung; Musixmatch và bản dịch máy theo ngôn ngữ dịch bạn chọn, trong 17 ngôn ngữ. Lời nổi, cửa sổ lời, Notch, thanh menu và Touch Bar có thể bật hoặc tắt riêng. Mặc định hiển thị khi các ngôn ngữ trên máy Mac của bạn có tiếng Trung.

- Cài đặt: Lời bài hát › Ngôn ngữ › Ngôn ngữ dịch
- Cài đặt: Hiển thị lời › Lời nổi › Nội dung › Bản dịch
- Cài đặt: Phím tắt › Hiện/ẩn bản dịch

<a id="feature-machine-translation"></a>

### Tự dịch khi không có bản dịch

Khi không nguồn nào có bản dịch, lời được dịch máy. Trên macOS 15 trở lên và đã tải ngôn ngữ về, Apple Translation dịch ngay trên máy Mac và lời không rời khỏi máy; nếu không, các dòng cần dịch được gửi tới Google Dịch, rồi đến MyMemory. Ngôn ngữ dịch được tải về ngay trong thẻ này.

- Tắt theo mặc định
- Cài đặt: Lời bài hát › Ngôn ngữ › Tự dịch khi không có bản dịch
- Cài đặt: Lời bài hát › Ngôn ngữ › Gói ngôn ngữ dịch

<a id="feature-romanization"></a>

### Phát âm

Romaji tiếng Nhật, Latinh hóa tiếng Hàn, bính âm tiếng Quan Thoại và Jyutping tiếng Quảng Đông, hiển thị theo từng từ phía trên lời, cùng 18 ngôn ngữ khác như tiếng Nga, tiếng Thái, tiếng Hy Lạp và tiếng Hindi theo hệ thống chính thức của từng ngôn ngữ hoặc tiêu chuẩn ISO. Ngôn ngữ được xác định theo từng dòng, nên trong một bài hát tiếng Trung chỉ dòng tiếng Nhật được đánh dấu. Chọn ngôn ngữ cần đánh dấu tại đây; với giao diện tiếng Trung, bính âm mặc định tắt. Mỗi vị trí hiển thị có thể bật hoặc tắt riêng.

- Bật theo mặc định
- Cài đặt: Lời bài hát › Ngôn ngữ › Ngôn ngữ phát âm
- Cài đặt: Lời bài hát › Ngôn ngữ › Phát âm tiếng Nhật
- Cài đặt: Hiển thị lời › Lời nổi › Nội dung › Phát âm
- Cài đặt: Phím tắt › Hiện/ẩn phát âm

<a id="feature-chinese-script"></a>

### Tiếng Trung giản thể hoặc phồn thể

Hiển thị toàn bộ lời tiếng Trung bằng chữ giản thể hoặc phồn thể, bất kể giao diện ứng dụng dùng ngôn ngữ nào.

- Cài đặt: Lời bài hát › Ngôn ngữ › Chuyển phồn thể/giản thể

<a id="feature-split-join-lines"></a>

### Tách dòng dài, gộp dòng ngắn

Lời nổi, Notch, thanh menu và Touch Bar tách các dòng quá dài so với chiều rộng và gộp các dòng lướt qua quá nhanh, mỗi nơi theo chiều rộng riêng. Cửa sổ lời vẫn giữ mỗi câu một dòng. Hai công tắc riêng biệt.

- Tắt theo mặc định
- Cài đặt: Lời bài hát › Thời gian & ngắt câu › Tách dòng dài
- Cài đặt: Lời bài hát › Thời gian & ngắt câu › Gộp dòng ngắn

<a id="feature-timing-offset"></a>

### Độ lệch thời gian

Đưa toàn bộ lời sớm hơn hoặc muộn hơn, có thể chỉ cho một trình phát. Từng bài có độ lệch riêng trong Quản lý lời, và phím tắt có thể đẩy sớm, lùi muộn hoặc đặt lại độ lệch ngay khi đang nghe.

- Cài đặt: Lời bài hát › Thời gian & ngắt câu › Độ lệch thời gian
- Cài đặt: Phím tắt › Hiện lời sớm hơn
- Cài đặt: Phím tắt › Hiện lời muộn hơn
- Cài đặt: Phím tắt › Đặt lại độ lệch lời

<a id="section-display"></a>

## Lời hiển thị ở đâu và trông ra sao

<a id="feature-floating-lyrics"></a>

### Lời nổi trên màn hình nền

Lời bài hát nổi trên mọi cửa sổ, luôn ở trên cùng, sáng lên theo từng chữ. Để lời ở bất cứ chỗ nào bạn kéo tới, hoặc ghim ở giữa phía trên màn hình hay ngay trên Dock. Khi có nhiều màn hình, lời có thể ở yên trên một màn hình hoặc đi theo màn hình chứa cửa sổ bạn đang dùng. Phát âm, bản dịch và dòng tiếp theo có thể hiển thị kèm.

- Bật theo mặc định
- Cài đặt: Hiển thị lời › Lời nổi › Lời nổi
- Cài đặt: Hiển thị lời › Lời nổi › Vị trí
- Cài đặt: Hiển thị lời › Lời nổi › Nội dung › Dòng tiếp theo
- Cài đặt: Phím tắt › Hiện/ẩn Lời nổi
- Cài đặt: Hiển thị lời › Lời nổi › Vị trí › Hiện trên

<a id="feature-notch-lyrics"></a>

### Lời trên Notch

Một khung kiểu Dynamic Island cạnh notch ở đầu màn hình; máy Mac không có notch và màn hình ngoài cũng có. Mỗi bên có thể hiển thị tên bài hát, nghệ sĩ, album, ảnh bìa, nút điều khiển phát, hoặc thời gian đã phát hay còn lại, bên cạnh sóng âm chuyển động. Di chuột lên để mở rộng, với nút điều khiển, thanh tiến trình tua được, căn thời gian lời và các nút nhanh như thích hay tìm lời. Khi có quảng cáo, Notch đếm ngược thời gian còn lại.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Notch › Lời trên Notch
- Cài đặt: Hiển thị lời › Notch › Phong cách
- Cài đặt: Hiển thị lời › Notch › Màn hình
- Cài đặt: Hiển thị lời › Notch › Tai trái
- Cài đặt: Phím tắt › Hiện/ẩn lời trên Notch
- Cài đặt: Phím tắt › Xem nhanh Notch
- Cài đặt: Hiển thị lời › Notch › Khi mở rộng › Tác vụ nhanh

<a id="feature-menu-bar-lyrics"></a>

### Lời trên thanh menu

Dòng hiện tại hiển thị ngay trên thanh menu, tự cuộn khi quá dài thay vì bị cắt. Thêm dòng thứ hai cho dòng tiếp theo, bản dịch hoặc phát âm. Lời cũng có thể nằm giữa thanh menu, sát cạnh notch trên màn hình có notch, hoặc chỉ hiển thị tên bài hát, kèm hoặc không kèm nghệ sĩ.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Thanh menu › Lời trên thanh menu
- Cài đặt: Hiển thị lời › Thanh menu › Bố cục › Vị trí
- Cài đặt: Hiển thị lời › Thanh menu › Nội dung › Nội dung
- Cài đặt: Hiển thị lời › Thanh menu › Nội dung › Dòng phụ
- Cài đặt: Phím tắt › Hiện/ẩn lời trên thanh menu

<a id="feature-touch-bar-lyrics"></a>

### Lời trên Touch Bar

Trên MacBook Pro có Touch Bar, dòng hiện tại cuộn theo lời đang hát, có thể kèm ảnh bìa và nút điều khiển phát. Lời có thể màu trắng, theo ảnh bìa, dùng màu bạn chọn hoặc chạy màu cầu vồng, với độ sáng phần chưa hát có thể điều chỉnh. Lời có thể mở rộng khi bắt đầu phát và thu gọn khi tạm dừng, còn nút “Thêm” mở ra căn thời gian, thích, xáo trộn và lặp lại, âm lượng và thanh tiến trình.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Touch Bar › Lời trên Touch Bar
- Cài đặt: Phím tắt › Mở rộng/thu gọn lời trên Touch Bar
- Cài đặt: Hiển thị lời › Touch Bar › Màu › Màu chữ
- Cài đặt: Hiển thị lời › Touch Bar › Hành vi › Tự mở rộng khi bắt đầu phát
- Cài đặt: Hiển thị lời › Touch Bar › Bố cục › Hiện nút “Thêm”

<a id="feature-lyrics-window"></a>

### Cửa sổ lời

Lời toàn trang theo phong cách màn hình lời bài hát của Apple Music: nền là ảnh bìa làm mờ, cả bài cuộn tới dòng hiện tại, song ca tách theo người hát, bè phụ trên dòng riêng, nốt ngân dài phóng to và phát sáng. Nền có thể theo ảnh bìa hoặc dùng màu đơn, dải màu hay kính mờ; độ đậm chữ, màu phần đã hát và căn lề đều đổi được. Mở cửa sổ từ biểu tượng trên thanh menu hoặc bằng phím tắt.

- Cài đặt: Hiển thị lời › Cửa sổ lời › Cửa sổ lời
- Cài đặt: Hiển thị lời › Cửa sổ lời › Nền › Nền
- Cài đặt: Phím tắt › Mở Cửa sổ lời
- Cài đặt: Hiển thị lời › Cửa sổ lời › Bố cục › Căn chỉnh

<a id="feature-lyrics-window-hdr"></a>

### Tô sáng HDR cho cửa sổ lời

Trên màn hình HDR, phần đã hát của dòng hiện tại trong cửa sổ lời sáng hơn màu trắng thông thường. Mặc định tắt và tốn pin hơn khi bật. Chỉ có ở cỡ Đầy đủ.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Cửa sổ lời › Màu › Tô sáng HDR

<a id="feature-mini-lyrics-window"></a>

### Cửa sổ lời mini

Cửa sổ lời thu nhỏ thành một thẻ nhỏ: chỉ dòng hiện tại, dòng hiện tại và dòng tiếp theo, hoặc cả trang cuộn. Nền, màu chữ, phông chữ, độ đậm, màu phần đã hát cùng tên bài hát, ảnh bìa và thời gian ở phía trên đều đặt riêng.

- Cài đặt: Hiển thị lời › Cửa sổ lời › Bố cục › Bố cục lời
- Cài đặt: Phím tắt › Đổi Mini/Đầy đủ

<a id="feature-mini-window-auto-hide"></a>

### Cửa sổ mini ẩn khi tạm dừng hoặc toàn màn hình

Cửa sổ mini có thể biến mất khi tạm dừng hoặc không phát và hiện lại khi bắt đầu phát, cũng như tự ẩn khi có ứng dụng toàn màn hình trên màn hình đó (video, trò chơi). Mỗi tùy chọn có công tắc riêng.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Cửa sổ lời › Hành vi › Ẩn khi tạm dừng
- Cài đặt: Hiển thị lời › Cửa sổ lời › Hành vi › Ẩn khi toàn màn hình

<a id="feature-animated-artwork"></a>

### Ảnh bìa động

Album có ảnh bìa động trên Apple Music, QQ Music hoặc NetEase Cloud Music cũng chuyển động trong cửa sổ lời cỡ Đầy đủ, cả những album mà Kugou Music đã lưu ảnh bìa động khi bạn phát ở đó. Ảnh bìa động tạm dừng ở Chế độ nguồn điện thấp hoặc khi bật Giảm chuyển động. Bạn có thể xem các ảnh động đã tải về chiếm bao nhiêu dung lượng và xóa chúng.

- Bật theo mặc định
- Cài đặt: Hiển thị lời › Cửa sổ lời › Ảnh bìa › Ảnh bìa động
- Cài đặt: Hiển thị lời › Cửa sổ lời › Ảnh bìa › Bộ nhớ đệm ảnh bìa động

<a id="feature-spotify-canvas"></a>

### Nền Spotify Canvas

Khi bài hát có video Canvas lặp lại trên Spotify, cửa sổ lời cỡ Đầy đủ phát video đó làm nền thay cho ảnh bìa làm mờ. Chỉ dùng video Spotify đã lưu trên máy Mac này, nên bài bạn đã phát trong Spotify sẽ có, kể cả khi phát bằng trình phát khác. Video tạm dừng ở Chế độ nguồn điện thấp hoặc khi bật Giảm chuyển động.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Cửa sổ lời › Nền › Spotify Canvas

<a id="feature-idle-overview"></a>

### Tổng quan nghe nhạc giữa các bài

Khi không có gì đang phát, cửa sổ lời hiển thị bài cuối cùng kèm một dòng lời của bài đó và nút “Tiếp tục”. Khi đã kết nối Last.fm, cửa sổ còn cho biết bạn đã nghe bao nhiêu hôm nay, trong 7 ngày qua và tổng cộng, xu hướng 30 ngày, “Ngày này năm xưa” và các lượt phát gần đây kèm ảnh bìa.

<a id="feature-look"></a>

### Giao diện

Phông chữ (của hệ thống, hoặc tệp .ttf / .otf của bạn), cỡ chữ, độ đậm, màu chữ và màu nền, viền chữ và kính mờ. Lời nổi có sẵn các chủ đề màu và có thể lưu chủ đề của riêng bạn; màu chữ có thể theo ảnh bìa album, còn lời nổi, Notch, thanh menu và Touch Bar có thể chạy màu cầu vồng. Phím tắt, hoặc giữ ⌘ và cuộn trên lời (con lăn chuột hoặc vuốt hai ngón), cũng có thể phóng to hay thu nhỏ lời nổi ngay lập tức.

- Cài đặt: Hiển thị lời › Lời nổi › Chủ đề
- Cài đặt: Hiển thị lời › Lời nổi › Chủ đề › Chủ đề của tôi
- Cài đặt: Hiển thị lời › Notch › Dòng lời › Màu lời
- Cài đặt: Hiển thị lời › Thanh menu › Màu › Cầu vồng
- Cài đặt: Hiển thị lời › Lời nổi › Phông chữ › Phông chữ
- Cài đặt: Hiển thị lời › Lời nổi › Màu › Nền kính mờ
- Cài đặt: Phím tắt › Tăng cỡ Lời nổi
- Cài đặt: Phím tắt › Giảm cỡ Lời nổi

<a id="feature-karaoke"></a>

### Hiệu ứng karaoke theo từng chữ

Mỗi chữ sáng lên khi được hát. Lời nổi, Notch, thanh menu, Touch Bar và cả hai cỡ của cửa sổ lời đều có công tắc riêng; khi tắt, cả dòng sáng lên cùng lúc.

- Bật theo mặc định
- Cài đặt: Hiển thị lời › Lời nổi › Màu › Hiệu ứng karaoke
- Cài đặt: Hiển thị lời › Notch › Dòng lời › Hiệu ứng karaoke
- Cài đặt: Hiển thị lời › Thanh menu › Màu › Hiệu ứng karaoke
- Cài đặt: Hiển thị lời › Touch Bar › Màu › Hiệu ứng karaoke
- Cài đặt: Hiển thị lời › Cửa sổ lời › Màu › Hiệu ứng karaoke

<a id="feature-line-transition"></a>

### Hiệu ứng chuyển dòng

Khi lời nổi chuyển sang dòng tiếp theo, dòng cũ trượt lên và dòng mới theo sau, thay vì thay thế tại chỗ.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Lời nổi › Bố cục › Hiệu ứng chuyển dòng

<a id="feature-fade-on-hover"></a>

### Mờ đi khi con trỏ ở trên

Lời nổi mờ đi khi con trỏ ở trên, nên không bao giờ che nội dung bên dưới. Cửa sổ lời mini có công tắc riêng, và khi mờ đi còn có thể cho thao tác bấm xuyên qua tới cửa sổ bên dưới; giữ ⌥ để dùng cửa sổ mini.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Lời nổi › Hành vi › Làm mờ khi di chuột qua
- Cài đặt: Hiển thị lời › Cửa sổ lời › Hành vi › Làm mờ khi di chuột qua
- Cài đặt: Hiển thị lời › Cửa sổ lời › Hành vi › Bấm xuyên qua khi mờ

<a id="feature-lock-position"></a>

### Khóa vị trí, nhấn giữ để kéo

Khóa lời nổi tại chỗ, hoặc yêu cầu nhấn giữ rồi mới kéo được, để lời không bao giờ bị di chuyển nhầm.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Lời nổi › Hành vi › Khóa vị trí
- Cài đặt: Hiển thị lời › Lời nổi › Hành vi › Bấm và giữ để kéo
- Cài đặt: Phím tắt › Khóa/Mở khóa vị trí

<a id="feature-hover-controls"></a>

### Nút điều khiển khi di chuột

Trỏ vào lời nổi sẽ hiện một hàng nút nhanh. Lời trên thanh menu cũng có thể hiện nút điều khiển phát khi di chuột lên.

- Bật theo mặc định
- Cài đặt: Hiển thị lời › Lời nổi › Hành vi › Hiện điều khiển khi di chuột
- Cài đặt: Hiển thị lời › Thanh menu › Hành vi › Hiện điều khiển khi di chuột

<a id="feature-hide-in-screenshots"></a>

### Ẩn khỏi ảnh chụp màn hình và chia sẻ màn hình

Ảnh chụp màn hình, bản ghi màn hình và màn hình chia sẻ đều không có lời, trong khi bạn vẫn thấy bình thường. Lời nổi và Notch mỗi nơi có một công tắc.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Lời nổi › Hành vi › Ẩn khi chụp màn hình
- Cài đặt: Hiển thị lời › Notch › Hành vi › Ẩn khi chụp màn hình

<a id="feature-hide-when-paused"></a>

### Ẩn hoặc thu nhỏ khi tạm dừng

Lời nổi và Notch biến mất khi tạm dừng hoặc không phát; Notch cũng có thể chỉ thu về bằng kích thước notch.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Lời nổi › Hành vi › Ẩn khi tạm dừng
- Cài đặt: Hiển thị lời › Notch › Hành vi › Ẩn khi tạm dừng
- Cài đặt: Hiển thị lời › Notch › Hành vi › Thu gọn khi tạm dừng

<a id="feature-hide-when-no-lyrics"></a>

### Ẩn khi nhạc không lời và bài không có lời

Khi bài hát là nhạc không lời, hoặc đã tìm xong mà không thấy lời, lời nổi và cửa sổ lời mini có thể ẩn, còn Notch và Touch Bar có thể thu gọn dòng lời. Không có gì bị ẩn khi việc tìm kiếm vẫn đang chạy. Mỗi nơi có công tắc riêng.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Lời nổi › Hành vi › Ẩn khi nhạc không lời/không có lời
- Cài đặt: Hiển thị lời › Cửa sổ lời › Hành vi › Ẩn khi nhạc không lời/không có lời
- Cài đặt: Hiển thị lời › Notch › Hành vi › Thu gọn dòng lời khi nhạc không lời/không có lời
- Cài đặt: Hiển thị lời › Touch Bar › Hành vi › Thu gọn khi nhạc không lời/không có lời

<a id="feature-hide-during-ads"></a>

### Tự ẩn khi có quảng cáo

Khi trình phát đang phát quảng cáo, lời nổi có thể ẩn và Notch có thể thu về dải trên cùng; di chuột lên Notch vẫn mở rộng được. Mỗi nơi có công tắc riêng.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Lời nổi › Hành vi › Ẩn khi có quảng cáo
- Cài đặt: Hiển thị lời › Notch › Hành vi › Thu gọn khi có quảng cáo

<a id="feature-hide-in-full-screen"></a>

### Notch tự ẩn khi toàn màn hình

Lời trên Notch thu gọn lại khi video, trò chơi hay bất kỳ ứng dụng nào đang ở chế độ toàn màn hình.

- Bật theo mặc định
- Cài đặt: Hiển thị lời › Notch › Hành vi › Ẩn khi toàn màn hình

<a id="feature-notch-show-on-lock-screen"></a>

### Notch trên Màn hình khóa

Notch vẫn hiển thị bài đang phát và lời bài hát trên Màn hình khóa.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Notch › Hành vi › Hiện trên màn hình khóa

<a id="feature-overlay-hide-in-full-screen"></a>

### Lời nổi tự ẩn khi toàn màn hình

Bình thường lời nổi luôn nằm trên các ứng dụng toàn màn hình. Bật tùy chọn này để lời ẩn đi khi video, trò chơi hay bất kỳ ứng dụng nào ở chế độ toàn màn hình, rồi hiện lại khi bạn thoát chế độ đó.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Lời nổi › Hành vi › Ẩn khi toàn màn hình

<a id="feature-title-on-change"></a>

### Hiện tên bài khi đổi bài

Tên bài hát và nghệ sĩ của mỗi bài mới trượt ra khỏi Notch trong chốc lát, rồi thu vào lại.

- Bật theo mặc định
- Cài đặt: Hiển thị lời › Notch › Hành vi › Hiện tên bài khi đổi bài

<a id="feature-listening-milestones"></a>

### Cột mốc nghe nhạc

Khi một bài hát đạt lượt phát thứ 100, 1.000 hoặc 10.000, hoặc tổng lượt phát trên Last.fm vượt qua một cột mốc, Notch mở ra để chúc mừng. Cần kết nối Last.fm.

- Bật theo mặc định
- Cài đặt: Hiển thị lời › Notch › Hành vi › Cột mốc nghe nhạc

<a id="feature-notch-gestures"></a>

### Cử chỉ bàn di chuột trên Notch

Khi con trỏ ở trên Notch, vuốt sang trái hoặc phải bằng hai ngón để chuyển bài, hoặc lên xuống để chỉnh âm lượng hệ thống.

- Bật theo mặc định
- Cài đặt: Hiển thị lời › Notch › Hành vi › Cử chỉ bàn di chuột
- Cài đặt: Hiển thị lời › Notch › Hành vi › Hiện khi bấm phím âm lượng

<a id="feature-notch-lyric-row-fade"></a>

### Làm mờ dòng lời trên Notch khi di chuột

Khi con trỏ ở trên dòng lời của Notch, dòng này mờ đi thay vì mở rộng và các thao tác bấm xuyên qua tới cửa sổ bên dưới; Notch chỉ mở rộng từ chính notch hoặc hai bên.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Notch › Dòng lời › Làm mờ khi di chuột qua

<a id="feature-notch-multiline-lyrics"></a>

### Lời nhiều dòng khi Notch mở rộng

Khi Notch mở rộng dưới con trỏ, vùng lời trở thành danh sách 3, 5 hoặc 7 dòng, dòng hiện tại sáng lên theo từng chữ và danh sách cuộn lên ở mỗi dòng mới; bấm vào một dòng để nhảy tới đó. Nếu tắt dòng lời, Notch vẫn là một dải trạng thái mảnh và chỉ hiện lời khi mở rộng.

- Bật theo mặc định
- Cài đặt: Hiển thị lời › Notch › Khi mở rộng › Lời nhiều dòng
- Cài đặt: Hiển thị lời › Notch › Khi mở rộng › Số dòng

<a id="feature-web-lyrics"></a>

### Lời trên web: điện thoại hoặc máy tính bảng làm màn hình phụ, hoặc nguồn trình duyệt OBS

Lời bài hát trong trình duyệt web. “Lời trên web” hiển thị đúng những gì cửa sổ lời hiển thị; “Đầu ra OBS” có nền trong suốt, cùng phông chữ và màu với lời nổi, kèm thẻ tên bài (tên bài hát, nghệ sĩ và ảnh bìa) ở góc trên bên trái, có thể luôn hiện, hiện khi đổi bài hoặc không hiện. Mỗi chế độ có cổng và cài đặt mạng cục bộ riêng. Cả hai chỉ dùng được trên máy Mac này cho đến khi bạn bật “Cho phép truy cập mạng cục bộ”; khi đó, thiết bị trong cùng mạng có thể quét mã QR để kết nối, qua một liên kết kèm khóa truy cập. Khi bật “Cho phép điều khiển từ xa”, trang web còn có thể điều khiển phát và nhảy tới một dòng.

- Tắt theo mặc định
- Cài đặt: Hiển thị lời › Cửa sổ lời › Lời trên web
- Cài đặt: Hiển thị lời › Cửa sổ lời › Lời trên web › Cho phép truy cập mạng cục bộ
- Cài đặt: Hiển thị lời › Lời nổi › OBS › Đầu ra OBS
- Cài đặt: Hiển thị lời › Lời nổi › OBS › Thẻ tên bài
- Cài đặt: Hiển thị lời › Cửa sổ lời › Lời trên web › Cho phép điều khiển từ xa

<a id="section-players"></a>

## Trình phát và điều khiển phát

<a id="feature-players"></a>

### 17 trình phát, chọn nhiều hoặc tự động nhận diện

Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Soda Music, MyGo Music, LX Music, KKBOX, Amazon Music, reAMP (theo phong cách Winamp), VOX (trình phát cục bộ cho nhạc lossless và hi-res), Pine Player (trình phát cục bộ miễn phí, phát được gần như mọi định dạng), foobar2000 (trình phát cục bộ kinh điển chuyển từ Windows sang), Kaset (ứng dụng YouTube Music) và Pear Desktop (ứng dụng YouTube Music mã nguồn mở cho máy tính). Chọn nhiều trình phát cùng lúc, hoặc để tự động theo trình phát mà macOS hiển thị trong Đang phát. Radio Apple Music cũng được hỗ trợ, hiển thị tên và logo đài khi người dẫn chương trình nói. WeRead còn hiển thị nguyên văn đang được đọc trong sách nói dưới dạng phụ đề.

- Cài đặt: Trình phát › Ứng dụng nhạc

<a id="feature-web-players"></a>

### YouTube Music và Spotify Web trong trình duyệt

Ghép đôi trình duyệt một lần là nhạc phát trong đó cũng có lời, theo đúng tiến độ của trang. Một lần kiểm tra bằng một lần bấm cho bạn biết trước trình duyệt đó có điều khiển được không. Khi có quảng cáo, Notch hiển thị thời gian còn lại và đó là quảng cáo thứ mấy.

- Tắt theo mặc định
- Cài đặt: Trình phát › Web

<a id="feature-skip-youtube-ads"></a>

### Tự động bỏ qua quảng cáo YouTube Music

Lyrimuse bỏ qua quảng cáo của YouTube Music trong trình duyệt hoặc Pear Desktop ngay khi nút “Bỏ qua” xuất hiện. Khi tắt, bạn vẫn có thể tự bỏ qua từ Notch. Cần quyền Trợ năng.

- Tắt theo mặc định
- Cài đặt: Trình phát › Web › Tự bỏ qua quảng cáo
- Cài đặt: Trình phát › Quyền & dịch vụ › Quyền Trợ năng

<a id="feature-other-players"></a>

### Thêm trình phát khác

Trình phát không có trong danh sách có thể được thêm vào trình phát đã tin cậy từ thư mục Ứng dụng, và Lyrimuse sẽ hỏi khi phát hiện một trình phát lạ đang phát nhạc.

- Cài đặt: Trình phát › Ứng dụng khác
- Cài đặt: Trình phát › Thêm ứng dụng…
- Cài đặt: Trình phát › Nhắc khi có trình phát mới

<a id="feature-permissions"></a>

### Chỉ xin quyền khi cần

Apple Music, Spotify, Kaset và VOX cần quyền Tự động hóa để đọc bài đang phát. QQ Music, NetEase Cloud Music và Kugou cần Quyền truy cập đầy đủ vào ổ đĩa cho lời đã lưu và hàng đợi, còn Soda Music và VOX cần quyền này cho hàng đợi. Những thứ sau cần quyền Trợ năng: hiệu chỉnh tiến độ của Amazon Music và Pine Player, danh sách phát của Pine Player, các nút xáo trộn, lặp lại và thích của QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, Amazon Music, reAMP, Pine Player và foobar2000, âm lượng của foobar2000, và các nút phát của QQ Music, NetEase Cloud Music, Soda Music, Pine Player và foobar2000 khi một ứng dụng khác đang giữ Đang phát. Trình phát web cần quyền Tự động hóa cho trình duyệt và tùy chọn “Cho phép JavaScript từ Sự kiện Apple” của trình duyệt. Các trình phát khác không cần gì. Cài đặt hiển thị trạng thái hiện tại của từng quyền. MyGo Music không cần quyền Tự động hóa hay Quyền truy cập đầy đủ vào ổ đĩa và không có điều khiển thích, xáo trộn, lặp lại hoặc âm lượng. Khi được cấp quyền Trợ năng, Lyrimuse có thể dùng menu của MyGo Music để tạm dừng, tiếp tục và chuyển về bài trước hoặc sang bài sau khi ứng dụng khác giữ quyền điều khiển phương tiện của hệ thống. Nếu không cấp quyền, lời cơ bản và điều khiển phát khi trình phát đang giữ quyền điều khiển vẫn hoạt động bình thường. Không thể tua khi trình phát mất quyền điều khiển.

- Cài đặt: Trình phát › Quyền & dịch vụ › Quyền Tự động hóa
- Cài đặt: Trình phát › Quyền & dịch vụ › Quyền truy cập đầy đủ vào ổ đĩa
- Cài đặt: Trình phát › Quyền & dịch vụ › Quyền Trợ năng

<a id="feature-controls"></a>

### Điều khiển phát và tua

Phát, tạm dừng, chuyển bài và kéo thanh tiến trình từ cửa sổ lời hoặc Notch khi mở rộng. Xáo trộn, lặp lại, thích và âm lượng tùy theo trình phát: Apple Music, Spotify, Kaset, QQ Music, Amazon Music, reAMP, VOX, Pine Player, foobar2000, Pear Desktop và YouTube Music trong trình duyệt hỗ trợ một phần hoặc tất cả; NetEase Cloud Music, Kugou Music, Soda Music và LX Music có nút thích, LX Music còn có âm lượng khi bật Open API trong cài đặt của nó. Phát, tạm dừng, chuyển bài và thích có thể gán phím tắt toàn cục. Khi một thứ như video trong trình duyệt đang giữ Đang phát, việc phát, tạm dừng và chuyển bài của QQ Music, NetEase Cloud Music, Soda Music, MyGo Music, Pine Player và foobar2000 đi qua menu hoặc thanh phát của chính chúng, và không tua được.

- Cài đặt: Hiển thị lời › Notch › Khi mở rộng › Hiện điều khiển
- Cài đặt: Phím tắt › Phát/Tạm dừng
- Cài đặt: Phím tắt › Bài tiếp theo
- Cài đặt: Phím tắt › Bài trước
- Cài đặt: Phím tắt › Ưa thích/Bỏ ưa thích
- Cài đặt: Trình phát › Quyền & dịch vụ › LX Music Open API

<a id="feature-song-pages"></a>

### Mở trang bài hát bằng một lần bấm

Một lần bấm trong menu ⋯ sẽ mở bài hát, album hoặc nghệ sĩ trên nền tảng bạn đang nghe. Apple Music và KKBOX mở trong ứng dụng của chúng, Spotify nhảy tới bài hát trong ứng dụng; các trang còn lại mở trên web: album và nghệ sĩ Spotify, QQ Music, Soda Music, Amazon Music và YouTube Music. NetEase Cloud Music và Kugou chỉ có trang bài hát.

<a id="feature-about-panels"></a>

### Giới thiệu bài hát, album và tiểu sử nghệ sĩ

Bấm vào tên bài hát, nghệ sĩ hoặc album trong cửa sổ lời hoặc Notch khi mở rộng để đọc thông tin. Giới thiệu album và tiểu sử nghệ sĩ lấy từ Apple Music trước; nếu không có thì từ Soda Music, Kugou Music và NetEase Cloud Music (chỉ với giao diện tiếng Trung), rồi Wikipedia qua YouTube Music, sau đó là Last.fm. Giới thiệu bài hát lấy từ QQ Music (chỉ với giao diện tiếng Trung) hoặc Last.fm. Last.fm cần kết nối tài khoản của bạn.

<a id="feature-player-linkage"></a>

### Mở và thoát cùng trình phát

Đặt riêng cho từng trình phát: mở trình phát khi Lyrimuse mở, mở Lyrimuse khi trình phát mở, hoặc thoát Lyrimuse khi mọi trình phát mà Lyrimuse theo dõi đều đã thoát.

- Tắt theo mặc định
- Cài đặt: Trình phát › Mở & thoát › Mở trình phát khi khởi động
- Cài đặt: Trình phát › Mở & thoát › Khởi động cùng trình phát
- Cài đặt: Trình phát › Mở & thoát › Thoát theo trình phát

<a id="section-listening"></a>

## Scrobble, Last.fm và chia sẻ

<a id="feature-lastfm"></a>

### Scrobble lên Last.fm và hồ sơ nghe nhạc

Kết nối Last.fm bằng một lần bấm, không cần sao chép token. Xem lượt nghe hôm nay, tuần này và từ trước đến nay, bảng xếp hạng nghệ sĩ, album và bài hát kèm thay đổi thứ hạng, và “Dấu chân”: bản đồ nhiệt cả năm (bấm vào một ngày để xem các bài phát nhiều nhất hôm đó), khung giờ nghe, nơi các nghệ sĩ bạn nghe đến từ, và “Ngày này năm xưa”. Yêu thích bất kỳ bài nào vừa nghe chỉ bằng một lần bấm.

- Tắt theo mặc định
- Cài đặt: Last.fm › Quy tắc › Quy tắc Scrobble

<a id="feature-scrobble-rules"></a>

### Quy tắc scrobble tùy chỉnh

Tính một lượt phát ở mức 50%, 75%, 90% hoặc chỉ khi phát hết; chọn có tính bài ngắn hơn 30 giây hay không; theo mặc định, nghệ sĩ góp giọng, biến thể chữ Hán và hậu tố như “- Single” được khớp với mục chính thức trong danh mục Last.fm, hoặc bạn có thể gửi mọi thứ nguyên trạng; loại hẳn một trình phát bất kỳ khỏi Last.fm.

- Cài đặt: Last.fm › Quy tắc › Thời điểm Scrobble
- Cài đặt: Last.fm › Quy tắc › Scrobble bài ngắn hơn 30 giây
- Cài đặt: Last.fm › Quy tắc › Chế độ khớp
- Cài đặt: Last.fm › Quy tắc › Trình phát được Scrobble

<a id="feature-local-log"></a>

### Mọi lượt phát đều được ghi trên máy trước

Lượt phát khi chưa kết nối Last.fm được ghi lại trên máy Mac của bạn; sau khi kết nối, bấm vào “Gửi bù” trong “Lượt phát chờ gửi bù” trên trang Last.fm. Lượt phát có thể chưa tới được Last.fm trong lúc đã kết nối sẽ được đối chiếu với Last.fm và tự động gửi lại. Last.fm chỉ nhận lượt phát trong khoảng hai tuần gần nhất.

<a id="feature-listenbrainz"></a>

### Scrobble cả lên ListenBrainz

Mỗi lượt phát được gửi tới Last.fm và ListenBrainz từ cùng một lần đọc trạng thái, nên hai bên luôn khớp nhau. Lượt phát mà iPhone gửi tới Last.fm cũng có thể sao chép sang ListenBrainz. Nằm trong “Thử nghiệm” ở thanh bên.

- Tắt theo mặc định
- Cài đặt: Thử nghiệm › ListenBrainz › Thông tin tài khoản

<a id="feature-discord"></a>

### Hiển thị bài bạn đang phát trên Discord

Hồ sơ và danh sách bạn bè hiển thị trình phát, tên bài hát, nghệ sĩ, ảnh bìa và thanh tiến trình; bấm vào tên bài hoặc nghệ sĩ sẽ mở trang web của trình phát. Dòng album có thể hiển thị câu lời đang hát, và có thể thêm tối đa hai nút. Chọn cách bố trí chữ, tính những trình phát nào, có giữ lại khi tạm dừng không và huy hiệu nào nằm trên ảnh bìa, chỉ hiển thị trình phát mà không nêu tên bài, hoặc ẩn đi một lúc.

- Tắt theo mặc định
- Cài đặt: Discord › Hiện trên Discord
- Cài đặt: Discord › Trình phát được hiện
- Cài đặt: Discord › Khi tạm dừng
- Cài đặt: Discord › Tạm ẩn
- Cài đặt: Discord › Nội dung
- Cài đặt: Discord › Nút
- Cài đặt: Discord › Ẩn thông tin bài hát

<a id="feature-now-playing-page"></a>

### Trang web đang phát có thể chia sẻ

Một trang công khai cho thấy bài bạn đang phát và lịch sử nghe, có thể thêm sổ lưu bút, biểu cảm, bộ đếm lượt truy cập, top 10 nghệ sĩ và giao diện đĩa than. Chỉ cần ListenBrainz là có trạng thái phát theo thời gian thực và lịch sử; với phần còn lại, triển khai một Cloudflare Worker theo hướng dẫn. Nằm trong “Thử nghiệm”.

- Tắt theo mặc định
- Cài đặt: Thử nghiệm › Đẩy web › Thông tin kết nối

<a id="feature-digests"></a>

### Tổng kết nghe nhạc hằng ngày, hằng tuần, hằng tháng và hằng năm

Gửi tới các kênh bạn thiết lập, bao nhiêu kênh cũng được: Bark, ntfy, ServerChan, Feishu, DingTalk, WeCom, Telegram, Discord, Slack hoặc webhook chung. Mỗi kênh có thể xem trước bản tin gửi đi trông thế nào và gửi thử, còn lịch sử gửi cho biết từng lần gửi có tới nơi không, kèm nút gửi lại cho những lần chưa tới. Báo cáo so sánh với kỳ trước, nêu các nghệ sĩ bạn nghe lần đầu và ước tính bạn đã nghe bao lâu, được trình bày theo từng nền tảng kèm ảnh bìa album và liên kết tới bảng xếp hạng đầy đủ. Mỗi loại trong bốn loại có công tắc riêng và, khi có nhiều kênh, có thể chọn kênh riêng; bạn chọn giờ gửi (theo múi giờ hiện tại của máy Mac) và số mục đứng đầu hiển thị trong mỗi danh sách, còn mỗi kênh có thể dùng báo cáo đầy đủ, rút gọn hoặc tổng quan, hoặc tiêu đề và nội dung của riêng bạn với phần giữ chỗ.

- Tắt theo mặc định
- Cài đặt: Thông báo đẩy › Kênh
- Cài đặt: Thông báo đẩy › Giờ gửi
- Cài đặt: Thông báo đẩy › Báo cáo nghe nhạc
- Cài đặt: Thông báo đẩy › Nguồn dữ liệu
- Cài đặt: Thông báo đẩy › Số mục mỗi loại
- Cài đặt: Thông báo đẩy › Báo cáo hằng ngày
- Cài đặt: Thông báo đẩy › Tổng kết hằng tuần
- Cài đặt: Thông báo đẩy › Tổng kết hằng tháng
- Cài đặt: Thông báo đẩy › Tổng kết hằng năm
- Cài đặt: Thông báo đẩy › Lịch sử gửi

<a id="section-general"></a>

## Dùng hằng ngày

<a id="feature-onboarding"></a>

### Thiết lập khi mở lần đầu

Lần đầu bạn mở Lyrimuse, ứng dụng hướng dẫn bạn chọn trình phát, ghép đôi trình duyệt và chọn nơi hiển thị lời, đồng thời kiểm tra từng quyền cần thiết để bạn bổ sung ngay những gì còn thiếu.

<a id="feature-language"></a>

### Tiếng Anh, tiếng Trung giản thể và phồn thể, tiếng Nhật, tiếng Hàn, tiếng Tây Ban Nha, tiếng Pháp, tiếng Đức, tiếng Ý, tiếng Bồ Đào Nha (Brazil), tiếng Việt, tiếng Nga, tiếng Ukraina và tiếng Thái

Mặc định theo ngôn ngữ hệ thống, và dùng tiếng Anh khi ngôn ngữ hệ thống không nằm trong số này; đổi ngôn ngữ có hiệu lực ngay, không cần khởi động lại.

- Cài đặt: Cài đặt chung › Giao diện & ngôn ngữ › Ngôn ngữ

<a id="feature-appearance"></a>

### Sáng, tối hoặc tự động

Cài đặt, cửa sổ lời, Quản lý lời và bảng trên thanh menu có thể luôn sáng hoặc luôn tối; theo mặc định, chúng theo hệ thống. Lời nổi vẫn theo hệ thống, còn Notch luôn tối.

- Cài đặt: Cài đặt chung › Giao diện & ngôn ngữ › Giao diện

<a id="feature-shortcuts"></a>

### Phím tắt toàn cục

Hiện hoặc ẩn từng loại lời (hoặc tất cả cùng lúc, khi họp và chia sẻ màn hình), mở cửa sổ lời và Quản lý lời, tìm lời, căn thời gian, điều khiển phát, thích và chuyển sang trình phát đều có thể gán phím tắt. Mặc định không gán phím nào.

- Cài đặt: Phím tắt › Mở Cài đặt
- Cài đặt: Phím tắt › Ẩn/hiện mọi lời
- Cài đặt: Phím tắt › Chuyển sang trình phát
- Cài đặt: Phím tắt › Mở/đóng bảng trên thanh menu

<a id="feature-deep-links"></a>

### Deep link (lyrimuse://)

Liên kết lyrimuse:// mở bất kỳ trang nào trong Cài đặt, cửa sổ lời hoặc Quản lý lời, và chạy mọi thao tác có thể gán phím tắt, như điều khiển phát, thích hay ẩn toàn bộ lời, từ ứng dụng Phím tắt, Raycast, Alfred và các công cụ tương tự. Khi mở bằng x-callback-url từ ứng dụng Phím tắt, liên kết còn có thể trả về tên bài hát, nghệ sĩ, album và dòng hiện tại. Thẻ “Deep link” trên trang “Phím tắt” liệt kê mọi liên kết, sẵn sàng để sao chép.

- Cài đặt: Phím tắt › Deep link

<a id="feature-settings-search"></a>

### Tìm kiếm trong cài đặt

Gõ ở đầu thanh bên của Cài đặt để nhảy thẳng tới một cài đặt và tô sáng nó, kể cả trong các mục đang thu gọn. Tìm bằng tiếng Anh hoặc tiếng Trung.

<a id="feature-menu-bar-icon"></a>

### Biểu tượng trên thanh menu

12 biểu tượng với ba kích cỡ, chuyển động theo nhạc khi đang phát, hoặc ảnh bìa album của bài đang phát. Các thao tác thường dùng nằm trong menu của biểu tượng.

- Bật theo mặc định
- Cài đặt: Cài đặt chung › Thanh menu & Dock › Biểu tượng thanh menu
- Cài đặt: Cài đặt chung › Thanh menu & Dock › Ảnh bìa album
- Cài đặt: Cài đặt chung › Thanh menu & Dock › Cỡ biểu tượng
- Cài đặt: Cài đặt chung › Thanh menu & Dock › Hoạt ảnh biểu tượng

<a id="feature-dock-icon"></a>

### Hiển thị trong Dock

Tắt để chỉ giữ biểu tượng trên thanh menu.

- Bật theo mặc định
- Cài đặt: Cài đặt chung › Thanh menu & Dock › Hiển thị trong Dock

<a id="feature-launch-at-login"></a>

### Mở khi đăng nhập

Mở Lyrimuse khi bạn đăng nhập vào máy Mac.

- Bật theo mặc định
- Cài đặt: Cài đặt chung › Khởi động & thông báo › Mở khi đăng nhập

<a id="feature-silent-launch"></a>

### Khởi động ẩn

Khởi động mà không mở cửa sổ nào, chỉ có biểu tượng trên thanh menu.

- Tắt theo mặc định
- Cài đặt: Cài đặt chung › Khởi động & thông báo › Khởi động ẩn

<a id="feature-song-notifications"></a>

### Thông báo khi đổi bài

Một thông báo hệ thống cho mỗi bài mới.

- Tắt theo mặc định
- Cài đặt: Cài đặt chung › Khởi động & thông báo › Thông báo khi đổi bài

<a id="feature-backup"></a>

### Sao lưu cài đặt, chuyển sang máy Mac mới

Xuất toàn bộ cài đặt ra một tệp, mặc định lưu vào iCloud Drive hoặc vào thư mục bạn chọn; khi máy Mac mới mở Lyrimuse lần đầu và tìm thấy tệp này trong iCloud, ứng dụng sẽ đề nghị nhập.

- Cài đặt: Cài đặt chung › Sao lưu & di chuyển › Sao lưu iCloud
- Cài đặt: Cài đặt chung › Sao lưu & di chuyển › Tệp cài đặt

<a id="feature-updates"></a>

### Tự động cập nhật và bản beta

Tự kiểm tra phiên bản mới; đọc ghi chú phát hành và cài đặt từ trang “Cập nhật phần mềm”. Bật “Bản cập nhật beta” để dùng thử tính năng mới sớm hơn.

- Tắt theo mặc định
- Cài đặt: Cập nhật phần mềm › Cài đặt cập nhật › Tự động kiểm tra
- Cài đặt: Cập nhật phần mềm › Cài đặt cập nhật › Tự động tải về và cài đặt
- Cài đặt: Cập nhật phần mềm › Cài đặt cập nhật › Bản cập nhật beta

<a id="feature-diagnostics"></a>

### Chẩn đoán và báo lỗi bằng một lần bấm

Gói nhật ký, báo cáo sự cố và trạng thái ứng dụng vào một tệp, đã loại bỏ thông tin đăng nhập và tên người dùng của bạn. “Báo cáo sự cố” mở một issue trên GitHub, điền sẵn phiên bản, macOS và trình phát của bạn.

- Cài đặt: Giới thiệu › Chẩn đoán & dữ liệu › Xuất chẩn đoán
- Cài đặt: Giới thiệu › Cập nhật & trợ giúp › Báo cáo sự cố

<a id="feature-telemetry"></a>

### Dữ liệu sử dụng ẩn danh, có thể tắt

Tối đa một lần mỗi ngày, Lyrimuse gửi phiên bản, macOS, các tính năng đang bật và bản tóm tắt sự cố tới máy chủ riêng của tác giả, để quyết định nên sửa gì trước. Không bao giờ gửi tên bài hát, nghệ sĩ, đường dẫn cục bộ hay tài khoản. Mặc định bật; tắt trong Cài đặt hoặc trên màn hình chào mừng.

- Cài đặt: Giới thiệu › Chẩn đoán & dữ liệu › Gửi dữ liệu sử dụng ẩn danh

<a id="section-all-settings"></a>

## Toàn bộ cài đặt

Toàn bộ mục trong cửa sổ Cài đặt, theo vị trí: tổng cộng 313 mục. Gõ tên vào ô tìm kiếm ở đầu thanh bên của Cài đặt để đi thẳng tới mục đó.

### Lời bài hát › Nguồn

- **Nguồn lời bài hát**
- **Thuật toán khớp**
- **Ưu tiên lời trong tệp bài hát**: Khi phát tệp trên máy, dùng trước tệp .lrc cùng tên hoặc lời nhúng trong tệp
- **Chọn lại khi thuật toán được cập nhật**: Đánh giá lại trong nền, có thể đổi sang bản phù hợp hơn
- **Dùng chung lời cho các mục cùng bài**: Cùng một bản thu dùng chung một bản lời trên mọi trình phát và phiên bản album, chỉnh sửa thủ công cũng đồng bộ
- **Khóa lời đã chọn thủ công**: Lời chọn thủ công không bao giờ bị thay khi tự động khớp
- **Xử lý trước bài sắp phát**: Lấy trước lời cho các bài sắp phát

### Lời bài hát › Ngôn ngữ

- **Ngôn ngữ dịch**
- **Tự dịch khi không có bản dịch**: Ưu tiên dịch trên máy này, không dịch được mới dịch trực tuyến
- **Gói ngôn ngữ dịch**: Gói ngôn ngữ hệ thống cần cho dịch trên máy
- **Chuyển phồn thể/giản thể**
- **Ngôn ngữ phát âm**
- **Phát âm tiếng Nhật**: Romaji, hoặc chỉ thêm hiragana cho chữ Hán

### Lời bài hát › Thời gian & ngắt câu

- **Tách dòng dài**: Khi một dòng không hiển thị hết, tách thành nhiều đoạn và hiện lần lượt
- **Gộp dòng ngắn**: Gộp các dòng ngắn liền kề khi vừa một dòng
- **Độ lệch thời gian**: Giá trị dương làm lời hiện sớm hơn, giá trị âm làm lời hiện muộn hơn

### Lời bài hát › Thư viện lời

- **Thư viện lời**
- **Tự động tìm lời còn thiếu**: Chỉ tìm bài hát chưa có lời hoặc chỉ có lời văn bản thuần
- **Tìm lại lời cho cả thư viện**: Gồm cả bài đã có lời, trừ bài đã sửa thủ công, đã hiệu chỉnh và nhạc không lời
- **Khoảng cách quét**: Số giây chờ giữa hai bài hát; nên để ít nhất 2 giây để tránh bị giới hạn tốc độ
- **Thư mục lời bài hát**: Sau khi đổi vị trí, các tệp hiện có sẽ không được di chuyển theo
- **Định dạng lời theo từng chữ**
- **Nhập thư mục lời**: Ghép tệp lời trong thư mục với bài hát trong thư viện lời, có xem trước khi nhập
- **Cách nhập thư mục**
- **Thư mục theo dõi**: Tệp lời mới hoặc đã sửa trong thư mục được tự động nhập: bài chưa có lời được bổ sung ngay, bài đã có lời giữ nguyên
- **Thư viện nhập**: Xem và xóa lời đã nhập

### Trình phát

- **Ứng dụng nhạc**
- **Web**: Phát nhạc trong trình duyệt cũng hiện được lời. Bấm vào “+” để ghép đôi trình duyệt bạn dùng; vị trí phát được đọc trực tiếp từ trang web nên lời đồng bộ ngay sau khi chuyển bài
- **Ứng dụng khác**: Ứng dụng không có ở trên cũng có thể dùng làm trình phát: sau khi thêm, bài hát đang phát trong đó sẽ hiện lời và được tính vào lịch sử nghe
- **Thêm ứng dụng…**: Chọn từ “Ứng dụng”, không cần đợi ứng dụng bắt đầu phát
- **Nhắc khi có trình phát mới**

### Trình phát › Web

- **Tự bỏ qua quảng cáo**: Tự bỏ qua quảng cáo có thể bỏ qua ngay khi xuất hiện

### Trình phát › Quyền & dịch vụ

- **Quyền Tự động hóa**
- **Quyền truy cập đầy đủ vào ổ đĩa**
- **Quyền Trợ năng**
- **LX Music Open API**: Lyrimuse đọc vị trí phát của LX Music và chỉnh âm lượng qua API này
- **API của Pear Desktop**: Lyrimuse đọc ID, loại của bài đang phát và hàng chờ phát từ Pear Desktop qua API này
- **Công cụ lời bài hát**: Đọc trạng thái phát, lấy lời bài hát và ảnh bìa

### Trình phát › Mở & thoát

- **Mở & thoát cùng trình phát**: Chỉ liệt kê các trình phát đã chọn; khi bật “Tự động nhận diện”, các trình phát đã cài trên máy Mac này cũng được liệt kê
- **Mở trình phát khi khởi động**
- **Khởi động cùng trình phát**
- **Thoát theo trình phát**

### Hiển thị lời › Lời nổi

- **Lời nổi**
- **OBS**
- **Chủ đề**
- **Chiều rộng**
- **Vị trí**
- **Khôi phục mặc định**: Chỉ khôi phục chủ đề, phông chữ và màu

### Hiển thị lời › Lời nổi › OBS

- **Đầu ra OBS**: Phủ lời lên khung hình phát trực tiếp dưới dạng nguồn trình duyệt, đặt chiều rộng và chiều cao bằng kích thước canvas OBS
- **URL nguồn trình duyệt**
- **Thẻ tên bài**: Hiện tên bài, nghệ sĩ và ảnh bìa ở góc trên bên trái
- **Cho phép truy cập mạng cục bộ**: Thiết bị trong cùng mạng có thể truy cập qua liên kết có khóa
- **Liên kết truy cập**
- **Liên kết dự phòng (địa chỉ IP)**
- **Đặt lại khóa truy cập**: Các liên kết đã chia sẻ sẽ hết hiệu lực
- **Cổng**: Sau khi đổi, cần cập nhật địa chỉ trong OBS

### Hiển thị lời › Lời nổi › Chủ đề

- **Chủ đề của tôi**

### Hiển thị lời › Lời nổi › Phông chữ

- **Phông chữ**
- **Độ đậm**
- **Cỡ**
- **Cỡ phát âm**
- **Cỡ bản dịch**
- **Cỡ dòng kế tiếp**

### Hiển thị lời › Lời nổi › Màu

- **Hiệu ứng karaoke**
- **Màu chữ**
- **Viền chữ**
- **Màu viền**
- **Màu chưa hát**
- **Màu nền**
- **Nền kính mờ**
- **Độ dày kính**

### Hiển thị lời › Lời nổi › Nội dung

- **Phát âm**
- **Bản dịch**
- **Dòng tiếp theo**

### Hiển thị lời › Lời nổi › Bố cục

- **Căn chỉnh**
- **Dòng dài**
- **Hiệu ứng chuyển dòng**: Khi chuyển dòng, dòng tiếp theo di chuyển từ vị trí cũ lên dòng hiện tại; khi tắt, dòng đổi ngay lập tức
- **Giãn cách phát âm**
- **Giãn cách bản dịch**
- **Giãn cách dòng sau**

### Hiển thị lời › Lời nổi › Hành vi

- **Khóa vị trí**
- **Bấm và giữ để kéo**
- **Làm mờ khi di chuột qua**
- **Hiện điều khiển khi di chuột**
- **Ẩn khi chụp màn hình**
- **Ẩn khi tạm dừng**
- **Ẩn khi nhạc không lời/không có lời**
- **Ẩn khi có quảng cáo**
- **Ẩn khi toàn màn hình**

### Hiển thị lời › Lời nổi › Vị trí

- **Hiện trên**

### Hiển thị lời › Notch

- **Lời trên Notch**
- **Phong cách**
- **Màn hình**
- **Tai trái**
- **Tai phải**
- **Chiều rộng**
- **Độ rộng khi mở rộng**
- **Khôi phục mặc định**: Không gồm độ rộng và công tắc “Lời trên Notch”

### Hiển thị lời › Notch › Phong cách

- **Nền khi mở rộng**
- **Bo góc**
- **Bo góc khi mở rộng**
- **Đường tiến trình**: Hiện tiến trình phát khi chưa mở rộng

### Hiển thị lời › Notch › Tai trái

- **Sóng âm**: Mỗi lúc chỉ hiện ở một bên

### Hiển thị lời › Notch › Dòng lời

- **Hiện lời khi thu gọn**: Khi tắt, bình thường chỉ giữ dải cao bằng notch, khi di chuột để mở rộng vẫn hiển thị như thường
- **Căn chỉnh**
- **Màu lời**
- **Dòng phụ**
- **Xem trước dòng tiếp theo khi mở rộng**
- **Chiều cao**
- **Hiệu ứng karaoke**
- **Hiện ảnh bìa**
- **Vị trí ảnh bìa**
- **Làm mờ khi di chuột qua**

### Hiển thị lời › Notch › Phông chữ

- **Phông chữ**
- **Độ đậm**
- **Cỡ**

### Hiển thị lời › Notch › Khi mở rộng

- **Lời nhiều dòng**: Hiện nhiều dòng lời khi mở rộng, dòng hiện tại sáng dần theo từng chữ
- **Số dòng**
- **Hiện điều khiển**
- **Hiện độ lệch lời**
- **Tác vụ nhanh**
- **Thông tin bài hát**

### Hiển thị lời › Notch › Hành vi

- **Thu gọn khi tạm dừng**
- **Ẩn khi chụp màn hình**
- **Ẩn khi tạm dừng**
- **Thu gọn dòng lời khi nhạc không lời/không có lời**
- **Thu gọn khi có quảng cáo**
- **Ẩn khi toàn màn hình**
- **Hiện trên màn hình khóa**
- **Cột mốc nghe nhạc**
- **Hiện tên bài khi đổi bài**
- **Hiện khi bấm phím âm lượng**
- **Cử chỉ bàn di chuột**

### Hiển thị lời › Thanh menu

- **Lời trên thanh menu**
- **Khôi phục mặc định**: Không gồm chiều rộng và công tắc “Lời trên thanh menu”

### Hiển thị lời › Thanh menu › Nội dung

- **Nội dung**
- **Dòng phụ**
- **Biểu tượng cạnh lời**: Biểu tượng được tô đầy từ dưới lên để thể hiện tiến độ phát, màu lấy từ nhóm “Màu”

### Hiển thị lời › Thanh menu › Bố cục

- **Vị trí**: Giữa thanh menu: lời hiện ở giữa thanh menu, tránh menu ứng dụng, biểu tượng bên phải và notch
- **Hiện trên**
- **Chế độ chiều rộng**: Cố định: mọi bài hát dùng chiều rộng đã đặt Thích ứng: chiều rộng theo lời của từng bài, không vượt quá chiều rộng đã đặt
- **Căn chỉnh**

### Hiển thị lời › Thanh menu › Màu

- **Hiệu ứng karaoke**
- **Cầu vồng**: Lời chuyển màu cầu vồng chạy từ trái sang phải, tự tối đi trên thanh menu sáng; trở lại màu hệ thống khi mở menu
- **Màu chữ**
- **Màu đã hát**

### Hiển thị lời › Thanh menu › Phông chữ

- **Phông chữ**
- **Độ đậm**
- **Cỡ**

### Hiển thị lời › Thanh menu › Chiều rộng

- **Độ rộng tối đa**

### Hiển thị lời › Thanh menu › Hành vi

- **Hiện điều khiển khi di chuột**
- **Hiện tên bài khi không có lời**: Hiện tên bài ở vị trí lời khi bài hát không có lời hoặc đang tìm lời

### Hiển thị lời › Touch Bar

- **Lời trên Touch Bar**
- **Khôi phục mặc định**: Không gồm công tắc “Lời trên Touch Bar”

### Hiển thị lời › Touch Bar › Nội dung

- **Dòng phụ**
- **Khi không có bản dịch**
- **Khi không có phát âm**
- **Cỡ**

### Hiển thị lời › Touch Bar › Bố cục

- **Căn chỉnh**
- **Hiện ảnh bìa**
- **Vị trí ảnh bìa**
- **Hiện điều khiển**: Nút Trước, Phát/Tạm dừng, Tiếp và nút cài đặt
- **Vị trí nút điều khiển**
- **Hiện nút “Thêm”**: Chạm để chuyển sang vị trí phát, hiệu chỉnh lời, Ưa thích, Xáo trộn/Lặp lại và Âm lượng. Mục nào trình phát hiện tại không hỗ trợ sẽ bị ẩn
- **Ẩn Control Strip khi mở rộng**: Lời chiếm toàn bộ Touch Bar. Để chỉnh độ sáng, âm lượng và các nút hệ thống khác, hãy chạm vào ✕ ở đầu bên trái để thu gọn lời trước
- **Control Strip hệ thống**: Các nút hệ thống như độ sáng, âm lượng ở bên phải Touch Bar; có thể thêm, bớt hoặc sắp xếp lại trong Cài đặt hệ thống › Bàn phím › Cài đặt Touch Bar…

### Hiển thị lời › Touch Bar › Màu

- **Hiệu ứng karaoke**
- **Màu chữ**: Trắng, theo ảnh bìa, màu tùy chỉnh hoặc cầu vồng
- **Độ sáng phần mờ**: Độ sáng của chữ chưa hát và dòng phụ

### Hiển thị lời › Touch Bar › Hành vi

- **Tự mở rộng khi bắt đầu phát**: Hiện lời khi tiếp tục phát sau khi tạm dừng. Chuyển bài trong lúc phát không mở rộng, lời bạn đã thu gọn sẽ giữ thu gọn
- **Tự thu gọn khi tạm dừng**: Thu gọn thành nút trên Control Strip sau 10 giây tạm dừng, tự mở rộng lại khi tiếp tục phát
- **Thu gọn khi nhạc không lời/không có lời**: Chỉ thu gọn khi đã xác nhận không có lời, tự mở rộng lại khi tìm thấy lời. Vẫn hiện bình thường trong lúc tìm

### Hiển thị lời › Cửa sổ lời

- **Cửa sổ lời**
- **Lời trên web**: Hiện cửa sổ lời trong trình duyệt web
- **Khôi phục mặc định**

### Hiển thị lời › Cửa sổ lời › Lời trên web

- **Địa chỉ cục bộ**
- **Cho phép truy cập mạng cục bộ**: Thiết bị trong cùng mạng có thể truy cập qua liên kết có khóa
- **Cho phép điều khiển từ xa**: Điều khiển phát và chuyển tới dòng lời từ thiết bị khác
- **Liên kết truy cập**
- **Liên kết dự phòng (địa chỉ IP)**
- **Đặt lại khóa truy cập**: Các liên kết đã chia sẻ sẽ hết hiệu lực
- **Cổng**: Sau khi đổi, cần quét lại mã để kết nối

### Hiển thị lời › Cửa sổ lời › Nền

- **Nền**: Nền của Cửa sổ lời: theo ảnh bìa, màu đơn, dải màu hoặc kính mờ
- **Hướng**
- **Spotify Canvas** (chỉ Đầy đủ): Dùng video lặp của bài trên Spotify làm nền; chỉ với bài bạn đã phát trong Spotify
- **Độ dày kính**: Độ dày chất liệu kính mờ (năm mức)
- **Màu phía dưới**

### Hiển thị lời › Cửa sổ lời › Phông chữ

- **Cỡ** (chỉ Mini): Cỡ chữ lời tối đa ở cỡ Mini
- **Phông chữ**: Phông chữ lời trong Cửa sổ lời (lời, bản dịch, phát âm)
- **Độ đậm**

### Hiển thị lời › Cửa sổ lời › Bố cục

- **Dòng dài** (chỉ Mini): Xuống dòng hoặc cuộn khi một dòng quá dài ở cỡ Mini
- **Bố cục lời** (chỉ Mini): Một dòng: chỉ hiện dòng hiện tại Hai dòng: hiện dòng hiện tại và dòng tiếp theo Nhiều dòng: giống cỡ đầy đủ, cuộn cả trang lời
- **Căn chỉnh** (chỉ Đầy đủ): Căn lề lời ở cỡ đầy đủ; “Tự động” căn theo bè song ca

### Hiển thị lời › Cửa sổ lời › Hành vi

- **Làm mờ khi di chuột qua** (chỉ Mini)
- **Bấm xuyên qua khi mờ** (chỉ Mini): Khi mờ, thao tác bấm sẽ xuyên qua tới cửa sổ bên dưới. Giữ ⌥ để hiện rõ lại và thao tác
- **Ẩn khi tạm dừng** (chỉ Mini)
- **Ẩn khi nhạc không lời/không có lời** (chỉ Mini)
- **Ẩn khi toàn màn hình** (chỉ Mini)

### Hiển thị lời › Cửa sổ lời › Màu

- **Hiệu ứng karaoke**
- **Màu chữ**: Màu chữ của Cửa sổ lời; “Tự động” chuyển giữa sáng và tối theo độ sáng của nền
- **Màu tùy chỉnh**
- **Màu đã hát**
- **Tô sáng HDR** (chỉ Đầy đủ): Làm sáng phần đã hát trên màn hình hỗ trợ HDR, tốn pin hơn khi bật

### Hiển thị lời › Cửa sổ lời › Nội dung

- **Phát âm**
- **Bản dịch**
- **Thanh tiến trình** (chỉ Mini): Khi tắt, chỉ hiện cùng điều khiển phát lúc di chuột lên

### Hiển thị lời › Cửa sổ lời › Phần đầu

- **Tên bài** (chỉ Mini): Hiện tên bài, nghệ sĩ và album ở phía trên cỡ Mini
- **Nghệ sĩ** (chỉ Mini)
- **Album** (chỉ Mini)
- **Ảnh bìa** (chỉ Mini): Ảnh bìa thu nhỏ bên trái thông tin phía trên của cỡ Mini
- **Thời gian** (chỉ Mini): Hiện thời gian đã phát và thời lượng bài ở phía trên cỡ Mini
- **Chiều rộng** (chỉ Mini): Phần trăm chiều rộng cửa sổ dành cho thông tin phía trên của cỡ Mini
- **Chiều cao** (chỉ Mini): Phần trăm chiều cao cửa sổ dành cho thông tin phía trên của cỡ Mini; cỡ chữ và ảnh bìa co giãn theo

### Hiển thị lời › Cửa sổ lời › Ảnh bìa

- **Ảnh bìa động** (chỉ Đầy đủ): Chỉ một số album có; tự tạm dừng khi ở Chế độ nguồn điện thấp hoặc khi bật “Giảm chuyển động”
- **Bộ nhớ đệm ảnh bìa động** (chỉ Đầy đủ): Dung lượng ổ đĩa do ảnh bìa động đã tải về sử dụng; sau khi xóa sẽ tải lại khi hiển thị lần sau

### Phím tắt

- **Deep link**: Mở được từ Phím tắt, Raycast, Alfred và các công cụ tương tự; di chuột lên phím tắt ở trên để sao chép liên kết của thao tác đó
- **Hiện/ẩn Lời nổi**
- **Hiện/ẩn lời trên Notch**
- **Xem nhanh Notch**
- **Hiện/ẩn lời trên thanh menu**
- **Mở rộng/thu gọn lời trên Touch Bar**
- **Ẩn/hiện mọi lời**
- **Khóa/Mở khóa vị trí**
- **Hiện/ẩn bản dịch**
- **Hiện/ẩn phát âm**
- **Tăng cỡ Lời nổi**
- **Giảm cỡ Lời nổi**
- **Mở Quản lý lời**
- **Mở Cửa sổ lời**
- **Đổi Mini/Đầy đủ**
- **Tìm lời bài hát**
- **Mở Cài đặt**
- **Chuyển sang trình phát**
- **Mở/đóng bảng trên thanh menu**
- **Hiện lời sớm hơn**
- **Hiện lời muộn hơn**
- **Đặt lại độ lệch lời**
- **Bước nhảy**: Mức điều chỉnh mỗi lần nhấn
- **Phát/Tạm dừng**
- **Bài tiếp theo**
- **Bài trước**
- **Ưa thích/Bỏ ưa thích**

### Cài đặt chung › Thanh menu & Dock

- **Biểu tượng thanh menu**
- **Ảnh bìa album**
- **Cỡ biểu tượng**
- **Hoạt ảnh biểu tượng**
- **Hiển thị trong Dock**

### Cài đặt chung › Giao diện & ngôn ngữ

- **Giao diện**: Màu sắc của Cài đặt, Cửa sổ lời, Quản lý lời và bảng thanh menu
- **Ngôn ngữ**

### Cài đặt chung › Khởi động & thông báo

- **Mở khi đăng nhập**
- **Khởi động ẩn**
- **Thông báo khi đổi bài**

### Cài đặt chung › Mạng

- **Proxy**

### Cài đặt chung › Sao lưu & di chuyển

- **Sao lưu iCloud**
- **Tệp cài đặt**: Chứa thông tin xác thực dạng văn bản thuần; xuất thành hai tệp cài đặt và thư viện lời, nhập sẽ ghi đè toàn bộ cài đặt
- **Xóa tất cả cài đặt**: Chỉ xóa cài đặt trên máy Mac này, bản sao lưu và tệp đã xuất không bị ảnh hưởng; không thể hoàn tác

### Cập nhật phần mềm

- **Cập nhật phần mềm**

### Cập nhật phần mềm › Cài đặt cập nhật

- **Tự động kiểm tra**: Kiểm tra phiên bản mới mỗi ngày một lần
- **Tự động tải về và cài đặt**: Tải về trong nền, cài đặt khi thoát Lyrimuse
- **Bản cập nhật beta**: Bản phát hành trước, có thể không ổn định

### Giới thiệu › Cập nhật & trợ giúp

- **Báo cáo sự cố**: Tạo issue mới trên GitHub, tự động kèm phiên bản, hệ thống và thông tin trình phát
- **Nhận trợ giúp**: Đặt câu hỏi trong mục Q&A của GitHub Discussions
- **Danh sách tính năng**: Mọi tính năng, vị trí trong Cài đặt và trạng thái mặc định

### Giới thiệu

- **Trang web**
- **Cộng đồng Discord**: Trò chuyện với người dùng khác, đặt câu hỏi hoặc góp ý
- **Nhóm Telegram**: Trò chuyện với người dùng khác, đặt câu hỏi hoặc góp ý
- **Nhóm QQ**: Trò chuyện với người dùng khác, đặt câu hỏi hoặc góp ý
- **Thông báo bản quyền**
- **Giấy phép của bên thứ ba**: Thành phần mã nguồn mở và từ điển
- **Giấy phép mã nguồn mở**: GPL-3.0

### Giới thiệu › Chẩn đoán & dữ liệu

- **Xuất chẩn đoán**: Gói nhật ký, báo cáo sự cố và trạng thái chạy vào một tệp, đã loại bỏ thông tin đăng nhập tài khoản; vẫn chứa tên bài hát và đường dẫn trên máy, hãy kiểm tra trước khi đăng công khai
- **Nhật ký hoạt động**: Nhật ký gốc của công cụ lời bài hát, để bạn tự kiểm tra lỗi
- **Thư mục dữ liệu**: Văn bản thuần túy, không gồm thông tin đăng nhập tài khoản, giao diện và phím tắt; để chuyển toàn bộ, hãy dùng “Sao lưu & di chuyển”
- **Gửi dữ liệu sử dụng ẩn danh**: Giúp cải thiện Lyrimuse: phiên bản, hệ thống, tính năng đã dùng và báo cáo sự cố, không gồm tên bài và tài khoản
- **Bộ nhớ đệm**: Ảnh bìa và kết quả tra cứu có thể lấy lại

### Thử nghiệm › ListenBrainz

- **Thông tin tài khoản**

### Last.fm › Quy tắc

- **Quy tắc Scrobble**
- **Chế độ khớp**: Tên nghệ sĩ và tên bài gửi lên Last.fm Thông minh: dùng cách viết có nhiều người nghe nhất trên Last.fm, nếu không khớp thì gửi nguyên như cũ; tên album bỏ “ - Single”, “ - EP” Tùy chỉnh: đặt riêng tên bài và nghệ sĩ Nguyên bản: gửi đúng nội dung trình phát báo
- **Tên bài**
- **Nghệ sĩ**
- **Thời điểm Scrobble**
- **Scrobble bài ngắn hơn 30 giây**: Khi bật, ghi Scrobble khi phát quá nửa; quy tắc chính thức của Last.fm không ghi các bài này
- **Trình phát được Scrobble**

### Thử nghiệm › Đẩy web

- **Thông tin kết nối**

### Thông báo đẩy

- **Kênh**: Báo cáo nghe nhạc được gửi đến mọi kênh đang bật; khi có nhiều kênh, có thể chọn riêng cho từng báo cáo ở “Báo cáo nghe nhạc” bên dưới. Bấm vào một hàng để sửa hoặc gửi thử, bấm chuột phải để xóa
- **Giờ gửi**
- **Báo cáo nghe nhạc**
- **Nguồn dữ liệu**
- **Số mục mỗi loại**: Số nghệ sĩ, album, bài hát đứng đầu được liệt kê
- **Tổng kết hằng tuần**
- **Báo cáo hằng ngày**
- **Tổng kết hằng tháng**
- **Tổng kết hằng năm**
- **Lịch sử gửi**

### Discord

- **Hiện trên Discord**: Khi bật, bài hát bạn đang nghe sẽ hiện trên hồ sơ Discord và trong danh sách bạn bè. Nếu bạn bè không thấy, hãy bật chia sẻ trạng thái hoạt động trong Discord ở “Cài đặt người dùng › Quyền riêng tư hoạt động”
- **Nội dung**
- **Sau “Đang nghe”**: Phần ×× trong “Đang nghe ××” trên hồ sơ. Discord trên iOS và web không hỗ trợ mục này, vẫn hiện tên trình phát Khi chọn tên bài hát hoặc nghệ sĩ ở đây, “Hiện dưới tên của bạn” không thể chọn “Trình phát” nữa
- **Hiện dưới tên của bạn**: Discord chỉ hiện Dòng 1, Dòng 2 hoặc phần sau “Đang nghe” dưới tên người dùng. Nếu cả tên bài hát và nghệ sĩ đều không nằm ở các vị trí này, tùy chọn tương ứng sẽ không dùng được
- **Huy hiệu ảnh bìa**
- **Khi tạm dừng**
- **Thông tin bài hát**
- **Văn bản trạng thái**
- **Ảnh bìa và tiến trình**
- **Thêm nhãn cho nghệ sĩ và album**: Thêm “Trình bày:” trước nghệ sĩ và “Album:” trước album. Không thêm khi tên bài hát và nghệ sĩ ở cùng một dòng
- **Nút**
- **Nút tùy chỉnh**
- **“Nghe trên trình phát”**: Mở trang của bài hát này trên trang web của trình phát hiện tại, giống như bấm vào tên bài hát. Ẩn khi không có trang tương ứng
- **“Tải Lyrimuse”**
- **Quyền riêng tư**
- **Tạm ẩn**
- **Ẩn thông tin bài hát**: Chỉ hiện trình phát đang dùng và tiến trình, không gửi tên bài hát, nghệ sĩ, album, lời, liên kết và nút “Nghe trên trình phát”
- **Hiện thanh tiến trình**: Khi tắt sẽ không có thanh tiến trình; Discord chuyển sang hiện thời gian đã phát và không tắt được bộ đếm này
- **Trình phát được hiện**
