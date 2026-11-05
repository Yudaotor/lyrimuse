# Cách Lyrimuse scrobble lên Last.fm

*[English](scrobbling.md) · [简体中文](scrobbling.zh-CN.md) · [日本語](scrobbling.ja.md) · [한국어](scrobbling.ko.md) · [Español](scrobbling.es.md) · [Français](scrobbling.fr.md) · [Deutsch](scrobbling.de.md) · [Italiano](scrobbling.it.md) · [Português (Brasil)](scrobbling.pt-BR.md) · **Tiếng Việt** · [Русский](scrobbling.ru.md) · [Українська](scrobbling.uk.md) · [ไทย](scrobbling.th.md)*

## 1. Khi nào một lượt phát được tính

Một lượt phát được gửi đi khi thỏa **tất cả** các điều kiện sau:

| Quy tắc | Giá trị |
|---|---|
| Phát đủ lâu | một nửa bài hát, tối đa 240 giây; hoặc 240 giây nếu không biết độ dài. Ngưỡng chặt hơn chỉ dành cho Last.fm: xem §1b |
| Bài hát đủ dài | `≥ 30s` (bài hát không rõ độ dài vẫn được tính). Có thể tắt: xem §1a |
| Không phải quảng cáo | Đoạn quảng cáo của Spotify được nhận diện và bỏ qua |

Trạng thái phát được lấy mẫu 5 giây một lần và thời gian đã phát được tính theo đồng hồ thực, nên tạm dừng sẽ ngừng đếm và tua không làm thời gian tăng lên. Nếu hai lần lấy mẫu cách nhau hơn 60 giây (máy chuyển sang chế độ ngủ, hoặc công cụ lời bài hát được khởi động lại), khoảng đó bị bỏ đi chứ không được tính.

Các ngưỡng này khớp với [hướng dẫn scrobble của Last.fm](https://www.last.fm/api/scrobbling).

### 1a. Bài hát dưới 30 giây

Cài đặt → Dịch vụ liên kết → Last.fm → *Quy tắc* → **Scrobble bài ngắn hơn 30 giây** (`scrobble_short_tracks`, mặc định **tắt**). Quy tắc của Last.fm *“The track must be longer than 30 seconds”* (bài hát phải dài hơn 30 giây) là quy tắc phía máy khách: máy chủ không từ chối bài ngắn và không có mã bỏ qua kiểu “quá ngắn”. Mọi trình scrobble phổ biến đều tuân theo quy tắc này, nên theo mặc định Lyrimuse cũng vậy. Khi bật tùy chọn này, bài ngắn được tính sau khi qua quy tắc phát một nửa (bài 20 giây cần 10 giây). Đây là cài đặt **chỉ dành cho Last.fm**: bài ngắn được scrobble lên Last.fm (và ghi vào nhật ký cục bộ dùng để gửi bù cho Last.fm) nhưng không bao giờ được gửi tới ListenBrainz; hành vi của ListenBrainz vẫn như cũ dù bật hay tắt.

### 1b. Thời điểm Scrobble

Cài đặt → Dịch vụ liên kết → Last.fm → *Quy tắc* → **Thời điểm Scrobble** (`lastfm_scrobble_point`, mặc định **50%**). Một bài hát phải phát đến đâu thì mới được scrobble lên Last.fm:

| Cài đặt | Giá trị | Scrobble khi |
|---|---|---|
| **50%** (mặc định) | `50` | đạt quy tắc của Last.fm ở trên: một nửa bài hát, tối đa 4 phút |
| 75% / 90% | `75` / `90` | đã phát 75% / 90% độ dài bài hát; chỉ tính thời gian thực sự phát, không giới hạn 4 phút |
| Hết bài | `end` | bài hát phát đến hết; tua tới không được tính |

Quy tắc của Last.fm là mức sàn, nên không có cài đặt nào dưới 50%. Cài đặt này **chỉ dành cho Last.fm**: ListenBrainz và trạm chuyển tiếp web vẫn gửi ở mốc 50%; chỉ lượt scrobble Last.fm (và nhật ký cục bộ dùng để gửi bù cho Last.fm) chờ đến mốc đã chọn. Bài hát bị bỏ qua trước mốc đó sẽ không gửi gì lên Last.fm: đó là cài đặt đang làm đúng việc của nó, không phải lượt scrobble bị mất. Bài hát không rõ độ dài theo quy tắc mặc định.

*Hết bài* được xét theo vị trí phát cuối cùng ghi nhận được khi chuyển bài: còn dưới 12 giây là hết bài (với bài ngắn là 10% độ dài) thì được tính là đã phát hết, nên hiệu ứng đan xen của trình phát hay chuyển bài liên tục không làm mất lượt scrobble.

## 2. Nội dung được gửi

`track.scrobble` ghi một mục vĩnh viễn vào lịch sử của bạn; `track.updateNowPlaying` bật chỉ báo “đang nghe” và không lưu gì.

| Trường | `track.scrobble` | `track.updateNowPlaying` |
|---|---|---|
| `artist` | ✅ | ✅ |
| `track` | ✅ | ✅ |
| `timestamp` | ✅ | — |
| `album` | khi không trống | khi không trống |
| `duration` | khi biết | khi biết |

Không có gì khác được gửi tới Last.fm. API của Last.fm cũng nhận `mbid`, `albumArtist`, `trackNumber`, `chosenByUser`, `streamId` và `context` khi scrobble; Lyrimuse không gửi trường nào trong số đó.

## 3. Những gì không bị viết lại

Với ListenBrainz, và ở các chế độ *Tất cả* và *Chỉ người đầu tiên* của Last.fm, tên nghệ sĩ, bài hát và album được gửi đúng như trình phát báo. (Chế độ *Thông minh* của Last.fm viết lại nghệ sĩ và bài hát cho khớp với mục trong danh mục: xem phần tiếp theo.)

Xử lý duy nhất là dọn ký tự vô hình: khoảng trắng không ngắt và khoảng trắng toàn độ rộng được đổi thành khoảng trắng thường, ký tự độ rộng bằng 0 và BOM bị xóa, nhiều khoảng trắng liên tiếp được gộp thành một, khoảng trắng ở đầu và cuối bị cắt bỏ. Nếu không làm vậy, một khoảng trắng không ngắt vô hình sẽ tạo ra một nghệ sĩ riêng trên Last.fm.

Không có gì nhìn thấy được bị thay đổi: không đổi chữ hoa chữ thường, không đổi giữa chữ Hán phồn thể và giản thể, không bỏ tiêu đề phụ trong ngoặc, không tách tên nhiều nghệ sĩ. `PRINCE` vẫn là `PRINCE`, `無所謂` vẫn là `無所謂`, và `一口 (The Day You Left Me)` giữ nguyên tiêu đề phụ.

Vì sao theo mặc định không tra cứu bên ngoài để “chuẩn hóa” tên:

- Lyrimuse từng làm đúng như vậy. Khi kiểm tra một thư viện thật có khoảng 2.500 bài, có khoảng 200 tên nghệ sĩ bị viết lại, trong đó có `USA for Africa` → `Xtc Planet` và `LBI利比` → `Safehse`. Các lượt scrobble đã ghi vào trang nghệ sĩ công khai trên Last.fm thì không thể sửa lại về sau: cơ sở dữ liệu chỉnh sửa đã bị đóng băng.
- Hướng dẫn scrobble của Last.fm nói hai lần: *“Do not use the corrections returned by the now playing service as input for the scrobble request, unless they have been explicitly approved by the user.”* (không dùng các chỉnh sửa do dịch vụ now playing trả về làm đầu vào cho yêu cầu scrobble, trừ khi người dùng đã chấp thuận rõ ràng). Cờ `autocorrect` của Last.fm
  [được ghi là tính năng cũ](https://support.last.fm/t/scrobbles-of-japanese-artists-getting-separated-by-romanization-of-their-name/119906).
- Trong chín trình scrobble mã nguồn mở được khảo sát (Web Scrobbler, Pano Scrobbler, Navidrome, Maloja, rescrobbled, mpdscribble, mpdas, Koito, multi-scrobbler), không trình nào mặc định viết lại tên nghệ sĩ dựa trên tra cứu bên ngoài.

## 4. Chế độ khớp

Cài đặt → Dịch vụ liên kết → Last.fm → *Quy tắc* → **Chế độ khớp**
(`lastfm_match_mode` trong `~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-features.json`):

| Chế độ | Giá trị | Tác dụng |
|---|---|---|
| **Thông minh** (mặc định khi cài mới) | `smart` | Tìm mục của bài hát này trong danh mục của Last.fm và gửi nghệ sĩ và tên bài của mục đó (xem bên dưới) |
| Tùy chỉnh | `custom` | Chọn phần nào được phép thay đổi: xem bên dưới |
| **Nguyên bản** (mặc định khi đã cài từ trước) | `raw` | Gửi đúng những gì trình phát báo, không truy cập mạng |

*Tùy chỉnh* thêm hai hàng, mỗi hàng cho một trường:

| Hàng | Tùy chọn | Tác dụng |
|---|---|---|
| **Tên bài** | Khớp | Tên bài có thể được thay bằng cách viết của mục trong danh mục, và ` - Single` / ` - EP` bị bỏ khỏi tên album (`lastfm_match_track`) |
| | Nguyên bản | Tên bài được gửi đúng như được báo |
| **Nghệ sĩ** | Khớp | Nghệ sĩ có thể được thay bằng cách viết của mục trong danh mục (`lastfm_match_artist`) |
| | Chỉ người đầu tiên | Rút phần ghi tên chung về nghệ sĩ đầu tiên (`Khalil Fong & Fiona Sit` → `Khalil Fong`); chỉ xử lý chuỗi, không truy cập mạng (`lastfm_match_first_artist_only`) |
| | Nguyên bản | Nghệ sĩ được gửi đúng như được báo |

Khi chỉ một trong hai hàng chọn *Khớp*, **ứng viên chỉ được chấp nhận nếu trường còn lại đã khớp sẵn**; nếu không, kết quả sẽ là một tổ hợp không có trong danh mục và lại rơi vào một mục ma chỉ có một người nghe: chính bạn.

*Chỉ người đầu tiên* khác với *Khớp*: nó **chỉ áp dụng khi không khớp được gì**. Cách viết đã khớp vốn là mục mà Last.fm nhận ra, cắt bớt sẽ biến nó thành một mục không tồn tại: `Hall & Oates / Maneater` (800 nghìn người nghe) sẽ thành `Hall`. Vì vậy Tên bài hát *Nguyên bản* cùng Nghệ sĩ *Chỉ người đầu tiên* giống hệt từng byte chế độ *Chỉ người đầu tiên* cũ, vẫn không truy cập mạng.

*Nguyên bản* vẫn là mặc định ở mọi nơi đã có sẵn `lyrimuse-features.json`, vì cắt phần ghi tên chung là không thể hoàn tác: Fiona Sit sẽ bị xóa khỏi lịch sử của bạn. Tùy chọn cùng tên của Navidrome (`Lastfm.ScrobbleFirstArtistOnly`) cũng mặc định tắt.

Việc tách tên rất thận trọng: `/` được xử lý riêng với `,` và `&`, nên `K/DA` và `AC/DC` không bị tách thành `K` và `AC`.

### Chế độ Thông minh

Thứ trình phát báo và tên mà danh mục của Last.fm đặt cho cùng một bản thu thường không giống nhau từng ký tự, và gửi nguyên như vậy sẽ khiến lượt phát rơi vào một mục “ma”: không MBID, không album, thời lượng bằng 0, một người nghe: chính bạn. Đo thực tế với 《那个女孩》 của David Tao: trình phát báo `陶喆, 卢广仲 / 那个女孩`, mục mà Last.fm hoàn toàn không có; bản giản thể `陶喆 / 那个女孩` có 126 người nghe; còn mục thật của bài hát là bản phồn thể **`陶喆 / 那個女孩`: 889 người nghe, 4.580 lượt phát, có thời lượng trong danh mục**. Chính `autocorrect` của Last.fm cũng không giúp được: nó không chuyển đổi giữa chữ Hán phồn thể và giản thể.

Vì vậy *Thông minh* tra cứu bài hát trước khi gửi:

1. `track.getInfo` với nội dung như được báo. **Nếu có MBID**, không động vào gì nữa, vĩnh viễn. MBID là tín hiệu mạnh nhất cho thấy bài hát có danh tính thật trong danh mục, và chính nó giữ cho một bản hợp tác được ghi tên đúng (Hall & Oates) không bị chuyển sang trang solo chỉ vì “nhiều người nghe hơn”.
2. Nếu không, ứng viên được thu thập từ **đúng ba nguồn**: nội dung như được báo, nghệ sĩ được ghi tên đầu tiên, và các mục của nghệ sĩ đó có tên bài quy về cùng một khóa
   (`artist.getTopTracks`, vốn đã được sắp xếp theo số người nghe).
3. Trong các ứng viên mà Last.fm thực sự có trong danh mục (có MBID, hoặc ≥ 500 người nghe, hoặc có thời lượng trong danh mục; mục ma không có điều nào trong ba điều này), ứng viên được nghe nhiều nhất sẽ thắng, thời lượng của nó được kiểm tra, và nghệ sĩ cùng tên bài của nó là thứ được gửi đi: quyết định một lần, giữ mãi mãi. Nếu không ứng viên nào đạt, bài hát được gửi như được báo và kiểm tra lại sau 90 ngày.

Chế độ này cố ý **không** dùng `track.search`: phương thức đó tìm theo chuỗi nguyên văn, vừa không tìm ra mục phồn thể, vừa không loại được những bài cùng tên nhưng khác bài như
`张泽熙 / 那个女孩`. Việc quy đổi tên bài chỉ xóa khác biệt về cách viết của cùng một bản thu: phồn thể và giản thể, chữ dị thể, dấu phụ, phần ghi nghệ sĩ góp giọng (`(feat. X)`) và nhãn phát hành lại (`(Remastered 2014)`, `(Bonus Track)`). **Nhãn Live, Remix, acoustic và instrumental luôn được giữ lại**: đó là những bản thu khác. Ứng viên thắng còn phải qua bước kiểm tra thời lượng (bị loại nếu cả hai bên đều biết thời lượng và chênh nhau hơn 8 giây).

Đo trên 240 bài hát thật: 33 bài được viết lại, 162 bài gửi nguyên như cũ, 45 bài không quyết định được. Ví dụ:

| Được báo | Được gửi | Người nghe |
|---|---|---|
| `周杰倫 / 手写的从前` | `周杰倫 / 手寫的從前` | 100 → 4.515 |
| `Wang Leehom / 奇遇的起点` | `王力宏 / 奇遇的起點` | 1 → 144 |
| `SZA & Phoebe Bridgers / Ghost in the Machine` | `SZA / Ghost in the Machine (feat. Phoebe Bridgers)` | 175 → 856.376 |
| `PRINCE / Walk Don't Walk (2023 Remaster)` | `Prince / Walk Don't Walk` | 231 → 16.178 |

Mọi lỗi tra cứu (mạng, giới hạn tần suất, phản hồi sai định dạng, không lấy được danh sách bài hát) đều khiến thẻ được gửi như được báo và không lưu gì vào bộ nhớ đệm, nên một trục trặc nhất thời không bao giờ trở thành quyết định vĩnh viễn. Các quyết định nằm trong
`~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-lastfm-catalog.json` cùng với bằng chứng dẫn đến chúng; xóa tệp này để quyết định lại toàn bộ.

Các khóa cài đặt cũ vẫn được đọc nhưng không còn được ghi, và được chuyển sang khóa mới mà không đổi hành vi:
`lastfm_scrobble_artist_mode` ánh xạ `smart` → Thông minh, `all` → Nguyên bản, và `first` → Tùy chỉnh với Tên bài hát là Nguyên bản và Nghệ sĩ là Chỉ người đầu tiên; giá trị boolean cũ hơn `lastfm_scrobble_first_artist_only=true` tương đương với `first`.

## 5. Khi scrobble thất bại

Lỗi được phân loại, vì mỗi loại cần cách xử lý khác nhau. “Ghi lại” ở bảng dưới nghĩa là lượt phát được ghi vào nhật ký cục bộ, để về sau **gửi bù** có thể gửi đi; gửi bù được bắt đầu thủ công bằng nút **Gửi bù** bên cạnh số “lượt phát chờ gửi bù” dưới danh sách các lượt phát gần đây.

| Chuyện gì đã xảy ra | Lyrimuse làm gì |
|---|---|
| Yêu cầu chắc chắn chưa từng rời khỏi máy Mac của bạn (DNS, không kết nối được) | Ghi lại; gửi bù có thể gửi nó |
| Máy chủ từ chối vì một lý do cho thấy chắc chắn chưa được lưu (thông tin xác thực sai, giới hạn tần suất) | Ghi lại; gửi bù có thể gửi nó |
| Đã gửi nhưng không rõ kết quả (hết thời gian chờ, mất kết nối, lỗi máy chủ không rõ ràng) | Ghi lại, nhưng gửi bù sẽ **không bao giờ** tự động thử lại |
| Máy chủ đã nhận bài hát và từ chối chính nội dung đó | Không ghi lại; hiển thị lý do thực sự từ máy chủ |

Hàng thứ ba có mặt vì hết thời gian chờ có thể nghĩa là Last.fm đã lưu lượt phát và chỉ có phản hồi xác nhận bị mất. Thử lại sẽ tạo ra một bản trùng phải xóa bằng tay, nên lỗi không rõ ràng không bao giờ được tự động thử lại.

Gửi bù chỉ lùi lại tối đa **13 ngày**. Khi một lượt phát đã được thử gửi, đường gửi theo thời gian thực sẽ không bao giờ gửi lại nó: lượt phát được đánh dấu là đã thử *trước* khi yêu cầu được gửi đi, chứ không phải sau khi thành công, nên dù bị sập giữa chừng cũng không thể gửi trùng lần thứ hai.

## 6. Gộp diễn ra ở đâu

Last.fm nhận đúng những gì trình phát báo, nên một thư viện ghi cùng một người vừa là
`Khalil Fong` vừa là `方大同` sẽ hiện thành hai nghệ sĩ ở đó.

Trong Lyrimuse, số lượt phát, bảng xếp hạng và số “Lượt phát thứ N” gộp chúng lại: nhờ quy đổi phồn thể/giản thể, bí danh theo tên phiên âm Latin, loại bỏ nhãn thừa của danh mục
(`(Remastered 2014)`, `(feat. …)`, `(Explicit)`) và bảng bí danh riêng cho từng nghệ sĩ. Việc gộp được làm cục bộ chứ không làm trước khi gửi, vì gộp sai ở máy chỉ cần làm mới là hoàn tác được, còn scrobble sai là một chỉnh sửa vĩnh viễn trên trang công khai.

## 7. Câu hỏi thường gặp

**Có dùng được Lyrimuse mà không scrobble không?**
Có, đó là mặc định: không có gì được scrobble cho đến khi bạn kết nối tài khoản Last.fm trong Cài đặt → Dịch vụ liên kết. Việc tìm lời bài hát và ảnh bìa là chuyện riêng: việc này gửi tên nghệ sĩ và tên bài tới các nguồn lời bài hát công khai (Netease, QQ, Kugou, LRCLIB, Musixmatch, AMLL) dù có kết nối tài khoản hay không. Có thể thu hẹp hoặc tắt các nguồn này trong Cài đặt.

**Vì sao cùng một nghệ sĩ xuất hiện hai lần trên hồ sơ Last.fm của tôi?**
Trình phát của bạn báo hai tên khác nhau, và cả hai đều được gửi đúng như được báo. Lyrimuse gộp chúng trong thống kê của chính nó; muốn gộp trên Last.fm thì phải sửa các lượt scrobble ở đó.

**Có thể làm sạch tên trước khi gửi không?**
Không. Nếu bạn cần việc này, cách làm khả thi là một bảng quy tắc người dùng tự sửa được chứ không phải tra cứu tự động: xem cách [Maloja](https://github.com/krateng/maloja) làm.

**Còn lượt phát từ iPhone thì sao?**
Lyrimuse không bao giờ gửi chúng lên Last.fm; chúng đến đó qua tính năng scrobble riêng của Apple. Lyrimuse đọc lại chúng để chúng hiện trong thống kê cùng với lượt phát trên máy Mac.

**Có thể gộp nghệ sĩ trên Last.fm mà không viết lại tên không?**
Không thể qua API. Tham số `mbid` của Last.fm xác định một *bài hát*, không phải một nghệ sĩ, nên không có trường nào để nói “hai tên này là cùng một người” mà vẫn giữ nguyên cả hai tên.

**Nhật ký nghe cục bộ có trùng với các lượt scrobble của tôi không?**
Không. Nhật ký này chỉ ghi một lượt phát khi chưa kết nối tài khoản Last.fm, hoặc khi gửi thất bại. Khi Last.fm đã kết nối và hoạt động bình thường, nhật ký này luôn trống.

---

*Triển khai: [`lyrimuse-engine/lastfm.go`](../lyrimuse-engine/lastfm.go)
(`resolveScrobbleArtist`, `scrobble`, `updateNowPlaying`),
[`lyrimuse-engine/poller.go`](../lyrimuse-engine/poller.go)
(`listenThreshold`, `recordFailedMirror`).*
