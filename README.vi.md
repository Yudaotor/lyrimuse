<div align="center">

<img src="docs/images/app-icon.png" width="120" alt="Biểu tượng Lyrimuse">

# Lyrimuse

**Lời bài hát trên màn hình nền, thiết kế lại cho máy Mac.**

**Language / 语言 / 語言 / 言語 / 언어 / Idioma / Langue / Sprache / Lingua / Язык / Мова / ภาษา:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Italiano](README.it.md) | [Português (Brasil)](README.pt-BR.md) | **Tiếng Việt** | [Русский](README.ru.md) | [Українська](README.uk.md) | [ไทย](README.th.md)

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon%20%2B%20Intel-blue)
[![Latest release](https://img.shields.io/github/v/release/Yudaotor/lyrimuse)](https://github.com/Yudaotor/lyrimuse/releases/latest)
[![Last commit](https://img.shields.io/github/last-commit/Yudaotor/lyrimuse/dev)](https://github.com/Yudaotor/lyrimuse/commits/dev)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/Yudaotor)
[![Discord](https://img.shields.io/badge/Discord-Join-5865F2?logo=discord&logoColor=white)](https://discord.gg/N7gVy66Gp3)
[![Telegram](https://img.shields.io/badge/Telegram-Join-26A5E4?logo=telegram&logoColor=white)](https://t.me/lyrimuse)
[![QQ](https://img.shields.io/badge/QQ-Join-1EBAFC?logo=qq&logoColor=white)](https://qm.qq.com/q/Nb4TlwfnQy)

</div>

https://github.com/user-attachments/assets/88b951ee-4ecf-4985-b1cb-eee6afdd5510

Lyrimuse là ứng dụng lời bài hát trên màn hình nền, mã nguồn mở, dành cho macOS. Ứng dụng nằm trên thanh menu và tô sáng lời theo từng chữ khi bài hát phát: nổi phía trên mọi cửa sổ, trên thanh menu, trong khung kiểu Dynamic Island dưới tai thỏ, trên Touch Bar hoặc trong một cửa sổ lời đầy đủ. Lyrimuse hoạt động với 17 trình phát, gồm Apple Music, Spotify, Amazon Music và ứng dụng YouTube Music Kaset, cùng các trình phát web trong trình duyệt, và chọn kết quả khớp nhất từ 15 nguồn lời bài hát, kèm bản dịch và phát âm khi bạn cần. Ứng dụng còn lưu hồ sơ nghe nhạc Last.fm và scrobble các lượt phát của bạn.

**Chuyển từ LyricsX sang?** LyricsX không có bản phát hành mới nào kể từ tháng 4 năm 2022. Lyrimuse làm được những gì LyricsX từng làm, vẫn liên tục được cập nhật, và hỗ trợ thêm các trình phát tiếng Trung, KKBOX, Amazon Music, Kaset, Pear Desktop, reAMP, VOX, Pine Player, MyGo Music, foobar2000 và trình phát web. Chi tiết có trong [bản so sánh với LyricsX và Lyric Fever](docs/lyrics-apps-comparison.md), mọi điểm đều đã được kiểm chứng.

**Cài đặt** bằng Homebrew, trên Apple Silicon hoặc Intel. Homebrew cũng tự xử lý giúp bạn cảnh báo Gatekeeper ở lần mở đầu tiên. Muốn tự tải về? Lấy [bản phát hành mới nhất](https://github.com/Yudaotor/lyrimuse/releases/latest) rồi xem [Bắt đầu](#bắt-đầu).

```bash
brew tap yudaotor/lyrimuse
brew trust --cask yudaotor/lyrimuse/lyrimuse   # one-time: Homebrew asks you to trust non-official taps
brew install --cask lyrimuse
```

<img src="docs/images/hero-surfaces.jpg" alt="Các cách hiển thị lời của Lyrimuse — cửa sổ lời kiểu Apple Music, khung kiểu Dynamic Island, lời nổi tô sáng theo từng chữ, lời trên thanh menu">
<p align="center"><sub>Bốn cách hiển thị lời: Cửa sổ lời, khung kiểu Dynamic Island, lời nổi tô sáng theo từng chữ và thanh menu</sub></p>

<img src="docs/images/hero-engine.jpg" alt="Công cụ lời bài hát của Lyrimuse — Quản lý lời, bảng quyết định chọn lời cho từng bài với điểm của mọi ứng viên">
<p align="center"><sub>Quản lý lời, tìm thủ công với điểm cho mọi kết quả, và bảng cho biết vì sao một bài hát nhận được lời hiện tại</sub></p>

<img src="docs/images/hero-profile.jpg" alt="Hồ sơ nghe nhạc của Lyrimuse — thống kê Last.fm, bảng xếp hạng, tổng quan khi không phát nhạc, bản đồ nhiệt nghe nhạc cả năm">
<p align="center"><sub>Số liệu và bảng xếp hạng Last.fm của bạn, phần tổng quan hiện ra khi không phát gì, và bản đồ nhiệt kiểu GitHub cho cả năm</sub></p>

<img src="docs/images/hero-customize.jpg" alt="Cài đặt Lyrimuse — trình chỉnh sửa có xem trước trực tiếp, chọn nhiều trình phát kể cả trình phát web, lời trên Touch Bar">
<p align="center"><sub>Mọi trang cài đặt đều có bản xem trước trực tiếp, bạn có thể chọn nhiều trình phát (kể cả trình phát web), và menu thả xuống trên thanh menu lo phần còn lại</sub></p>

## Tính năng

> Mỗi tính năng nằm ở đâu trong Cài đặt, và bật hay tắt sau khi cài: xem **[danh sách tính năng](docs/feature-list.vi.md)**.

### Lời theo từng chữ đồng bộ, tự động tìm khớp
- **Tô sáng theo từng chữ**, bám sát bài hát khi đang phát.
- **15 nguồn lời bài hát, tự tìm giúp bạn**: NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Musixmatch, LRCLIB, LyricFind (qua YouTube Music), Deezer, AMLL (cơ sở dữ liệu lời theo từng chữ do cộng đồng tuyển chọn thủ công), Soda Music (có thời gian theo từng chữ riêng), VIBE và Genie (cả hai mạnh về nhạc Hàn), PetitLyrics (mạnh về nhạc Nhật), và lời bài hát của Apple Music nếu bạn kết nối tài khoản trong Cài đặt. Lời của Apple Music cần gói đăng ký, và nhiều bài trong đó có thời gian theo từng chữ. Bạn không bao giờ phải tự tìm.
- **Bản dịch và phát âm** ngay dưới lời gốc. Nếu nguồn có bản dịch của cộng đồng, bạn nhận bản đó. Nếu không, hãy bật “Dịch dự phòng của hệ thống” trong Cài đặt (mặc định tắt), máy Mac sẽ dịch lời bằng framework Translation của Apple nên lời không rời khỏi máy tính của bạn, và một trình dịch trực tuyến sẽ thay thế khi cách đó không dùng được. Có 17 ngôn ngữ đích. Lyrimuse chọn phát âm theo từng dòng: một bài tiếng Trung có một dòng tiếng Nhật chỉ có phát âm ở đúng dòng đó, chứ không phải pinyin khắp các dòng còn lại. Bài tiếng Quảng Đông có Jyutping nhận biết theo cả từ. Với tiếng Nhật, bạn có thể chọn furigana thay cho romaji: hiragana chỉ đặt trên chữ Hán, tiện nếu bạn học tiếng Nhật qua bài hát. Thêm 18 ngôn ngữ khác, gồm tiếng Nga, tiếng Thái, tiếng Hy Lạp và tiếng Hindi, cũng có phát âm, theo cách La-tinh hóa chính thức của từng ngôn ngữ hoặc theo một tiêu chuẩn ISO.
- **Song ca tách theo người hát.** Khi nguồn (hoặc một mục AMLL) đánh dấu ai hát dòng nào, mỗi phần hiện riêng thay vì hai giọng dồn vào một khối.
- **Những nét Apple Music trong Cửa sổ lời**: bè nền nằm trên dòng riêng dưới dòng chính, các dòng song ca chồng nhau cùng sáng lên cho đến khi cả hai hát xong, và những từ tiếng Anh ngân dài phồng lên, phát sáng như cách Apple Music làm.
- **Chữ Giản thể hoặc Phồn thể** cho lời tiếng Trung, đặt riêng, không phụ thuộc ngôn ngữ của ứng dụng.
- **Quản lý lời**, khi bạn muốn sắp xếp lại. Duyệt, sửa, xóa hoặc tìm lại lời cho bất kỳ bài nào, xóa nhiều bài cùng lúc, và dọn các mục trống do quảng cáo và podcast để lại. Nếu thời gian của một bài bị lệch, chỉ chỉnh riêng bài đó. Một nút thử lại mọi bài vẫn chưa có lời, và lần quét lại toàn bộ chọn lại lời cho cả thư viện theo quy tắc khớp hiện tại. Những gì bạn đã sửa tay đều được giữ nguyên. Bạn cũng có thể nhập tệp .lrc hoặc cả một thư mục, kể cả cho bài chưa từng phát, hoặc để ứng dụng theo dõi một thư mục.
- **Một bài hát, một bộ lời.** Lyrimuse nhận ra cùng một bài hát dù phát trong các trình phát khác nhau hay từ các bản phát hành khác nhau: các mục của bài dùng chung lời và những chỉnh sửa tay của bạn, và lượt phát được cộng dồn. “Mục cùng bài” trong Quản lý lời so sánh các mục theo từng dòng và tách riêng mục bị khớp nhầm.
- **Sửa lời ngay từ Cửa sổ lời.** Tìm lời khác, tìm lại cho bài hát, hoặc sửa trong trình soạn thảo văn bản của bạn. Khi sửa lời theo từng chữ, chỉ phần chữ thay đổi, nên mọi chữ vẫn giữ nguyên thời gian của nó.
- **Hoạt động ngoại tuyến** với mọi bài đã có lời trong bộ nhớ đệm.

### Hồ sơ nghe nhạc Last.fm và scrobble
- **Hồ sơ nghe nhạc đầy đủ.** Kết nối Last.fm bằng một cú bấm trong phần tài khoản (không cần sao chép và dán token), bạn sẽ có tổng số lượt phát hôm nay, 7 ngày qua và từ trước đến nay, chỉ báo “đang scrobble” trực tiếp, và các lượt phát gần đây kèm ảnh bìa, mỗi lượt có nút trái tim để yêu thích (hoặc bỏ yêu thích) trên Last.fm. Theo mặc định, mỗi lượt phát được gửi dưới dạng bài tương ứng trong danh mục của Last.fm, nên tên nghệ sĩ song ca, cách viết Giản thể / Phồn thể và các đuôi như “ - Single” hay “(Remastered)” đều về đúng trang bài hát thật; chuyển sang “Nguyên bản” trong Cài đặt để gửi đúng những gì trình phát báo. ListenBrainz luôn nhận thẻ gốc ([cách scrobble hoạt động](docs/scrobbling.vi.md)).
- **Nghệ sĩ, album và bài hát hàng đầu** trong 7 ngày, 30 ngày, một năm qua hoặc từ trước đến nay, mỗi mục kèm mức tăng giảm so với kỳ trước. Bấm vào một nghệ sĩ để xem những bài của họ mà bạn nghe nhiều nhất.
- **Dấu chân**, một thẻ riêng. Mở đầu là các con số tích lũy: đã bao nhiêu ngày kể từ lần scrobble đầu tiên, bao nhiêu ngày trong đó có nghe nhạc và trung bình mỗi ngày, ngày nghe nhiều nhất, chuỗi hiện tại và chuỗi dài nhất, năm nay tính đến giờ so với cùng kỳ một năm trước, và bạn còn cách cột mốc tròn số tiếp theo bao xa. Bên dưới là bản đồ nhiệt cả năm kiểu GitHub (bấm vào một ngày để xem bạn nghe gì nhiều nhất), bạn nghe vào giờ nào và thứ mấy, các nghệ sĩ hàng đầu đến từ đâu, và “Ngày này năm xưa” với những gì bạn đã nghe vào ngày này các năm trước.
- **Mọi lượt phát đều được lưu trên máy Mac trước**, kể cả trước khi bạn kết nối Last.fm. Kết nối sau rồi gửi khoảng hai tuần gần nhất chỉ bằng một cú bấm (Last.fm không nhận lượt phát cũ hơn).
- **Bạn quyết định khi nào một lượt phát được tính**: ở mức 50% như mặc định của Last.fm, ở 75% hoặc 90%, hoặc chỉ khi bài hát thực sự phát hết. ListenBrainz không bị ảnh hưởng. Bạn cũng có thể loại hẳn một trình phát khỏi Last.fm để lượt phát của nó không bao giờ xuất hiện trong lịch sử của bạn.
- **Cùng lịch sử đó cũng hiện trong Cửa sổ lời** khi không phát gì, nên bạn thấy phần tổng quan thay vì một màn hình trống (xem thêm bên dưới).

### Lời nổi, lời trên thanh menu, Dynamic Island, Touch Bar hoặc cửa sổ lời đầy đủ
- **Dùng nhiều trình phát, hoặc để Lyrimuse tự chọn.** Lyrimuse đọc Apple Music, Spotify và Kaset qua quyền Tự động hóa. QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, KKBOX, Amazon Music và LX Music được đọc qua MediaRemote của macOS và không cần quyền nào. Bật bất kỳ tổ hợp nào trong Cài đặt, hoặc để ở chế độ tự động nhận diện, ứng dụng sẽ theo trình phát mà macOS đang hiển thị là Đang phát.
- **Radio Apple Music cũng dùng được.** Lời theo kịp từng bài trên một đài. Khi người dẫn chương trình đang nói, bạn thấy tên và logo của đài chứ không phải bài trước đó. Radio có độ lệch thời gian riêng, nên bạn chỉ cần chỉnh một đài một lần rồi không phải bận tâm nữa.
- **Trình phát trong trình duyệt cũng vậy.** Ghép đôi trình duyệt một lần, YouTube Music hoặc Spotify Web sẽ hoạt động như mọi trình phát khác, với lời đồng bộ theo chính thanh tiến trình của trang. Một bài kiểm tra bằng một cú bấm cho bạn biết ngay từ đầu trình duyệt có điều khiển được hay không. Trong lúc có quảng cáo, khung Dynamic Island chuyển sang màu đen và cho biết còn bao lâu, đây là quảng cáo thứ mấy trên tổng số bao nhiêu. Quảng cáo YouTube Music có nút bỏ qua, hoặc có thể được bỏ qua tự động.
- **Chọn cách bạn muốn xem**, kết hợp tùy ý hoặc không dùng cách nào:
  - lời nổi trên màn hình nền mà bạn có thể kéo đến bất cứ đâu, hoặc ghim ở chính giữa phía trên hay ngay trên Dock;
  - khung kiểu Dynamic Island ở phía trên màn hình, có thể hiện ảnh bìa album và làm mờ ảnh đó phía sau khung, làm nhạt dòng lời để cú bấm xuyên qua được, và hiện trên Màn hình khóa nếu bạn bật;
  - Touch Bar trên những chiếc MacBook Pro có Touch Bar, với dòng lời cuộn theo khi hát, kèm ảnh bìa album và nút điều khiển phát nếu bạn muốn;
  - Cửa sổ lời có thể đổi kích thước, mô phỏng trang lời bài hát của Apple Music, với hai cột, ảnh bìa làm mờ ở nền, cả bài cuộn theo dòng hiện tại, ảnh bìa động khi Apple Music có ảnh bìa chuyển động cho album, và video Spotify Canvas lặp lại của bài hát làm nền khi bài có video này. Chữ được tô dần khi hát, với độ đậm, màu đã hát và căn chỉnh do bạn chọn, và “Tô sáng HDR” có thể làm phần đã hát sáng hơn cả màu trắng trên màn hình HDR.
- **Lời trên thanh menu (chế độ chữ).** Dòng hiện tại nằm ngay trên thanh menu. Dòng dài sẽ cuộn thay vì bị cắt giữa chừng (bạn có thể chuyển lại kiểu cắt). Hàng thứ hai có thể hiện dòng tiếp theo, bản dịch hoặc phát âm, và khung Dynamic Island cũng làm được như vậy.
- **Kéo thanh tiến trình để tua**, trong Cửa sổ lời và trong khung Dynamic Island.
- **Xáo trộn, lặp lại, Ưa thích và âm lượng** ngay trong Cửa sổ lời, với những trình phát cho phép: Apple Music, Spotify, Kaset, QQ Music, Amazon Music và YouTube Music trong trình duyệt hỗ trợ một phần hoặc tất cả, còn NetEase Cloud Music, Kugou Music, Soda Music và LX Music có Ưa thích. Ưa thích cũng có trong khung Dynamic Island khi mở rộng, và có thể gán phím tắt.
- **Mở bài hát tại nơi của nó** từ menu “⋯” hoặc bảng thông tin. Apple Music mở trong ứng dụng, Spotify chuyển đến bài đang phát, còn KKBOX mở bài hát, album hoặc nghệ sĩ trong ứng dụng của chính nó. QQ Music, Soda Music, Spotify, Amazon Music và YouTube Music (khi bạn phát trong Kaset) mở trang bài hát, album hoặc nghệ sĩ trên web, còn NetEase Cloud Music mở trang bài hát. Lyrimuse đã có liên kết từ lúc tải lời hoặc đọc được từ dữ liệu của chính trình phát trên máy Mac, nên không cần tìm gì cả.
- **Khi không phát gì**, Cửa sổ lời hiện tổng số hôm nay và tuần này, thẻ “Ngày này năm xưa” và các lượt phát gần đây kèm ảnh bìa, mỗi lượt liên kết đến trang album hoặc nghệ sĩ trong Apple Music.
- **Cửa sổ lời cỡ mini**: một thẻ nhỏ hiện một dòng, hai dòng hoặc toàn bộ lời cuộn, với nền, màu chữ, phông chữ, độ đậm và màu đã hát riêng; có thể tắt hiệu ứng karaoke theo từng chữ cho riêng cỡ này.
- **Lời trên web cho điện thoại, máy tính bảng hoặc buổi phát trực tiếp.** Mở Cửa sổ lời trong trình duyệt trên thiết bị khác và dùng làm màn hình thứ hai, với nút điều khiển phát và chạm để nhảy đến dòng nếu bạn cho phép. “Đầu ra OBS” đưa lời nổi vào buổi phát trực tiếp dưới dạng nguồn trình duyệt trong suốt. Cả hai chỉ dùng được trên máy Mac này cho đến khi bạn cho phép truy cập mạng cục bộ, và các thiết bị khác kết nối bằng cách quét mã QR.
- **Giới thiệu bài hát, giới thiệu album và tiểu sử nghệ sĩ.** Bấm vào tên bài, nghệ sĩ hoặc album trong Cửa sổ lời hoặc khung Dynamic Island mở rộng để đọc về chúng. Giới thiệu album và tiểu sử nghệ sĩ lấy từ Apple Music, hoặc, khi Apple Music không có, từ Soda Music (bài phát trong Soda Music, chỉ khi giao diện tiếng Trung), Kugou Music (bài phát trong Kugou Music, chỉ khi giao diện tiếng Trung), NetEase Cloud Music (chỉ khi giao diện tiếng Trung), các bài Wikipedia mà YouTube Music hiển thị (theo ngôn ngữ giao diện) hoặc Last.fm; giới thiệu bài hát lấy từ QQ Music (chỉ khi giao diện tiếng Trung) hoặc Last.fm.
- **Tùy chỉnh theo ý bạn**: phông chữ (phông hệ thống, hoặc tệp .ttf / .otf của riêng bạn), cỡ chữ, màu chữ / nền / bóng, chủ đề đã lưu hoặc màu lấy từ ảnh bìa album hiện tại, độ rộng của lời nổi, cùng màu lời cầu vồng chuyển động.
- **Ẩn khi chụp màn hình, quay màn hình và chia sẻ màn hình.** Bạn vẫn thấy, người khác thì không.
- **Tự ẩn khi bạn tạm dừng**, để không nằm trên màn hình nền mà chẳng làm gì. Ứng dụng cũng có thể tránh sang một bên khi phát nhạc không lời hoặc bài không có lời, và khi có ứng dụng toàn màn hình, và lời nổi có thể theo bạn sang màn hình chứa cửa sổ bạn đang dùng.

### Những chi tiết hằng ngày
- **Tiếng Anh, tiếng Trung Giản thể, tiếng Trung Phồn thể, tiếng Nhật, tiếng Hàn, tiếng Tây Ban Nha, tiếng Pháp, tiếng Đức, tiếng Ý, tiếng Bồ Đào Nha (Brazil), tiếng Việt, tiếng Nga, tiếng Ukraina và tiếng Thái**, và đổi ngôn ngữ có hiệu lực ngay, không cần khởi động lại. Thấy chỗ dịch còn vụng? Pull request luôn được chào đón; mỗi ngôn ngữ có một hướng dẫn văn phong trong `lyrimuse/Localization/`.
- **Liquid Glass trên macOS 26.** Cài đặt, bảng thanh menu, Cửa sổ lời, Quản lý lời và hướng dẫn thiết lập đều dùng Liquid Glass, và hầu hết có thể giữ giao diện sáng hoặc tối thay vì theo hệ thống.
- **Phím tắt** cho mọi thao tác, từ ẩn toàn bộ lời đến thích bài hát. Mặc định không gán phím nào, nên bạn tự chọn phím. Mọi thao tác cũng có liên kết `lyrimuse://` để gọi từ ứng dụng Phím tắt, Raycast hoặc Alfred, và từ Phím tắt, một liên kết có thể trả về bài đang phát ([URL Scheme](docs/url-scheme.vi.md)).
- **Tìm kiếm trong Cài đặt.** Gõ vào thanh bên, ứng dụng sẽ cuộn đến hàng khớp và tô sáng hàng đó, mở cả nhóm đang thu gọn nếu cần.
- **Tự cập nhật.** Ứng dụng tự kiểm tra, hoặc kiểm tra khi bạn yêu cầu từ thanh menu. Bản cập nhật được cài từ trang Cập nhật phần mềm trong Cài đặt, có ghi chú phát hành và tiến trình ngay tại đó, và bạn có thể chọn nhận bản beta.
- **Khởi động cùng trình phát**, đặt riêng cho từng trình phát và theo cả hai chiều: mở trình phát khi Lyrimuse mở, mở Lyrimuse khi trình phát mở, và nếu muốn, thoát Lyrimuse khi mọi trình phát mà ứng dụng theo dõi đều đã thoát.
- **Khởi động ẩn** nếu bạn muốn ứng dụng khởi động mà không mở cửa sổ nào, chỉ có biểu tượng trên thanh menu.
- **Chuyển sang máy Mac mới?** Xuất toàn bộ thiết lập rồi nhập vào máy mới. Nếu có sự cố, còn có nút xuất chẩn đoán chỉ bằng một cú bấm.

### Tiện ích tùy chọn

<details>
<summary>ListenBrainz, trạng thái Discord, trang “đang phát” để chia sẻ, và bản tổng kết theo ngày / tuần / tháng / năm</summary>

Tất cả đều tắt cho đến khi bạn bật trong Cài đặt:

- **Scrobble cả lên [ListenBrainz](https://listenbrainz.org).** Mỗi lượt phát được gửi đến cả hai dịch vụ từ cùng một lần đọc trình phát, nên hai lịch sử luôn khớp nhau. Lượt phát từ iPhone (ghi qua Last.fm) cũng được sao chép sang ListenBrainz, nên bạn có một lịch sử chung cho cả hai thiết bị thay vì hai.
- **Trang “đang phát” công khai để chia sẻ**: trạng thái phát trực tiếp, lịch sử, sổ lưu bút, biểu cảm, bộ đếm lượt truy cập, bảng 10 nghệ sĩ hàng đầu, giao diện đĩa than, chủ đề sáng và tối, cùng bản xem trước liên kết đầy đủ trong các ứng dụng trò chuyện. **[Hướng dẫn tính năng web](https://github.com/Yudaotor/nowplaying-workers#readme)** giải thích từng bước kèm ảnh chụp màn hình.
- **Tổng kết nghe nhạc hằng ngày, hằng tuần, hằng tháng và hằng năm**, gửi đến bao nhiêu kênh tùy thích: Bark, ntfy, ServerChan, Feishu, DingTalk, WeCom, Telegram, Discord, Slack hoặc webhook chung. Mỗi kênh có thể gửi thử, và lịch sử gửi cho biết những gì đã đến nơi.
- **Hiện bài bạn đang nghe trên Discord.** Hồ sơ và danh sách bạn bè của bạn hiện trình phát bạn đang dùng, bài hát, nghệ sĩ, ảnh bìa album và thanh tiến trình, còn tên bài và nghệ sĩ liên kết đến trang của chúng trên trang web của trình phát đó. Dòng album có thể hiện dòng lời đang hát, và bạn có thể thêm tối đa hai nút. Một huy hiệu nhỏ của Lyrimuse hoặc của trình phát nằm ở góc ảnh bìa (hoặc không có), và bài đang tạm dừng có thể vẫn hiện kèm biểu tượng tạm dừng. Bạn chọn trình phát nào được tính, có thể chỉ hiện trình phát mà không nêu tên bài, và có thể tạm ẩn một lúc.

ListenBrainz và “Đẩy web” nằm trong **Thử nghiệm** ở thanh bên của Cài đặt, “Thông báo đẩy” nằm cùng các mục khác, còn Discord có mục riêng gần đầu danh sách. Mỗi thẻ đi kèm các bước thiết lập riêng: lấy khóa API hoặc token ở đâu, kết nối tài khoản thế nào, lấy URL webhook cho dịch vụ đẩy ra sao. Trang web là phần duy nhất có hướng dẫn riêng, và bạn không cần làm hết. Chỉ cần thiết lập ListenBrainz, trang đã hiện trạng thái phát trực tiếp và lịch sử, không cần Cloudflare Worker. Hãy triển khai một Worker nếu bạn muốn thêm sổ lưu bút, biểu cảm, bộ đếm lượt truy cập, bảng 10 nghệ sĩ hàng đầu và cập nhật nhanh hơn; hướng dẫn có nói cách làm.

</details>

## Bắt đầu

Các bản phát hành được ký bằng chứng chỉ riêng của dự án, không phải Apple Developer ID, nên không cách nào dưới đây cần tài khoản Apple Developer. Đổi lại, lần đầu bạn mở ứng dụng, Gatekeeper sẽ báo ứng dụng “đến từ một nhà phát triển chưa được xác định”. Homebrew (Cách A) xử lý việc này giúp bạn. Với các cách khác, đây là điều bình thường, không phải lỗi, và Cách B chỉ cách vượt qua một lần.
### Cách 0: Giao việc cài đặt cho AI

Bạn đang dùng một AI agent có thể dùng Terminal trên máy Mac (Claude Code, Codex CLI, Gemini CLI, …)? Dán nguyên khối bên dưới vào agent đó, nó sẽ làm mọi việc trong Cách A/B giúp bạn. Hướng dẫn chỉ cho phép agent cài đúng ứng dụng này. Agent sẽ không dùng `sudo` hay động đến các cài đặt bảo mật toàn hệ thống:

```text
Please install Lyrimuse — an open-source macOS menu-bar lyrics app
(https://github.com/Yudaotor/lyrimuse) — on this Mac, following these rules exactly:

1. Preferred path (if `brew` exists):
     brew tap yudaotor/lyrimuse
     brew trust --cask yudaotor/lyrimuse/lyrimuse
     brew install --cask lyrimuse
   If this Homebrew doesn't know the `trust` subcommand, skip that line — older
   versions don't need it.
2. If Homebrew is not installed, do NOT install Homebrew. Instead: check the CPU
   with `uname -m`, download the latest release asset from
   https://github.com/Yudaotor/lyrimuse/releases — `Lyrimuse-v<version>-macos.zip`
   for arm64, `Lyrimuse-v<version>-macos-intel.zip` for x86_64 — verify it against
   its `.sha256` file (`shasum -c`), unzip, move `Lyrimuse.app` into
   /Applications, then clear the Gatekeeper quarantine flag on that one app only:
     xattr -dr com.apple.quarantine /Applications/Lyrimuse.app
3. Safety rails: no `sudo` anywhere (nothing here needs it); never run
   `spctl --master-disable` or otherwise weaken Gatekeeper system-wide; never
   remove the quarantine flag from anything except /Applications/Lyrimuse.app.
4. Do not build from source unless I explicitly ask.
5. Launch it (`open -a Lyrimuse`) and verify it is running (`pgrep -x Lyrimuse`
   prints a PID).
6. A first-run wizard will appear — that part is mine to click through. Tell me
   it will ask me to pick a music player, to grant Automation access to
   Music.app and/or Spotify (only if I pick them), and to enable the background
   lyrics engine — then hand control back to me.
Finally, report what you did and anything that failed.
```

### Cách A: Cài bằng Homebrew (khuyên dùng)

```bash
brew tap yudaotor/lyrimuse
brew trust --cask yudaotor/lyrimuse/lyrimuse   # one-time: Homebrew asks you to trust non-official taps
brew install --cask lyrimuse
```

Quá trình cài đặt tự động gỡ cờ cách ly Gatekeeper một lần, nên không cần bước nào tiếp theo. Mở Lyrimuse từ `/Applications` (hoặc Spotlight) ngay sau khi `brew install` chạy xong. `brew upgrade --cask lyrimuse` nhận các bản phát hành mới theo cùng cách.

### Cách B: Tự tải bản phát hành dựng sẵn

1. Tải từ [trang Releases](https://github.com/Yudaotor/lyrimuse/releases). **Trước tiên hãy kiểm tra máy Mac của bạn** ( → Giới thiệu về máy Mac này → “Chip”: `Apple M…` là Apple Silicon, `Intel Core…` là Intel):

   | Máy Mac của bạn | Tải về |
   | --- | --- |
   | Apple Silicon (M1 trở lên) | `Lyrimuse-*-macos.dmg` hoặc `.zip` |
   | Intel | `Lyrimuse-*-macos-intel.dmg` hoặc `.zip` |

   Với dmg, bấm đúp để gắn ảnh đĩa rồi kéo `Lyrimuse.app` vào lối tắt `Applications` bên cạnh; với zip, giải nén rồi kéo `Lyrimuse.app` vào `/Applications`. Cả hai định dạng cài cùng một ứng dụng, và bản zip kèm tệp `.sha256` nếu bạn muốn xác minh bản tải về (`shasum -c Lyrimuse-*.zip.sha256` trong cùng thư mục).

   Khác biệt duy nhất giữa hai bản tải về là kiến trúc: bản không có hậu tố chỉ dành cho Apple Silicon, còn `-intel` chứa mã cho cả Intel và Apple Silicon. `-intel` vẫn chạy được trên Apple Silicon, nhưng không có lý do gì để dùng ở đó: dung lượng gấp đôi, và từ macOS 27 trở đi hệ thống sẽ cảnh báo ứng dụng “cần được cập nhật” vì chứa mã Intel (Apple sẽ loại bỏ Rosetta trong macOS 28; ứng dụng thực ra không có vấn đề gì).

   **Cả hai kiến trúc đều được tự động cập nhật trong ứng dụng.** Nguồn cập nhật liệt kê hai mục cho cùng một phiên bản, mỗi mục cho một kiến trúc: Apple Silicon nhận bản không hậu tố, Intel nhận bản `-intel`, và Sparkle tự chọn theo từng máy. (Từ v1.4.0 trở về trước chỉ phục vụ Apple Silicon; người dùng Intel phải tự quay lại đây tải.)
2. Ở lần mở đầu tiên, macOS sẽ từ chối mở ứng dụng, với thông báo “Apple không thể xác minh rằng ‘Lyrimuse’ không chứa phần mềm độc hại…” hoặc “…đến từ một nhà phát triển chưa được xác định”. Hãy gỡ chặn một lần, bằng cách nào bạn thấy thoải mái nhất:

   - **Terminal (khuyên dùng, luôn hiệu quả):**
     ```bash
     xattr -dr com.apple.quarantine /Applications/Lyrimuse.app
     ```
     Sau đó mở ứng dụng như bình thường. Mỗi lần tải về chỉ cần làm một lần.
   - **Bấm chuột phải → Mở:** Trong Finder, bấm chuột phải (hoặc giữ Control và bấm) vào `Lyrimuse.app` rồi chọn **Mở**, sau đó xác nhận **Mở** một lần nữa trong hộp thoại. Cách này không hiệu quả trên mọi phiên bản macOS với mọi loại cảnh báo, nên nếu cảnh báo vẫn còn, hãy dùng lệnh Terminal ở trên.
   - **Cài đặt hệ thống → Quyền riêng tư & Bảo mật:** Thử mở ứng dụng một lần (ứng dụng sẽ bị chặn), sau đó mở **Cài đặt hệ thống → Quyền riêng tư & Bảo mật**, cuộn xuống cuối và bấm **Vẫn mở** bên cạnh cảnh báo về Lyrimuse. Xác nhận thêm một lần nếu được hỏi.

   Chỉ làm vậy với bản dựng bạn thực sự tin tưởng: bản từ trang Releases của kho này, hoặc bản do chính bạn dựng.

### Cách C: Dựng từ mã nguồn

**Điều kiện cần, chỉ thiết lập một lần** (bỏ qua những gì bạn đã có):

```bash
xcode-select --install   # Xcode Command Line Tools, for Swift — skip if `swift --version` already works
brew install go          # any Go ≥ 1.21 — build.sh switches to 1.24.4 automatically via GOTOOLCHAIN
```

Sau đó `build.sh` dựng cả ứng dụng lẫn công cụ lời bài hát (tiến trình nền tên `lyrimuse-engine`) trong một lần:

```bash
git clone https://github.com/Yudaotor/lyrimuse.git
cd lyrimuse/lyrimuse
./build.sh              # this machine's architecture
./build.sh --universal  # arm64 + x86_64 (the compatibility build shipped for Intel)
```

Cuối cùng, `build.sh` liệt kê kiến trúc của mọi tệp nhị phân trong gói và đánh dấu những gì không khớp với mục tiêu, dù là thiếu một slice hay thừa một slice. Đừng tự ghép tệp phát hành bằng tay: `./package.sh` dựng mỗi kiến trúc một lần và tạo zip + sha256 + dmg cho từng kiến trúc, và từ chối đóng gói nếu kiến trúc sai.

Để hỗ trợ QQ Music / NetEase Cloud Music / Kugou Music / Soda Music / KKBOX / Amazon Music / LX Music / Spotify / Kaset / tự động nhận diện, cần thêm [ungive/media-control](https://github.com/ungive/media-control). `build.sh` tự cài công cụ này qua Homebrew nếu còn thiếu, nên đây cũng không phải bước bạn cần tự làm.

### Sau khi cài bằng bất kỳ cách nào

Mở Lyrimuse từ `/Applications`. Trình hướng dẫn lần đầu sẽ dẫn bạn chọn trình phát (Apple Music, QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, KKBOX, Amazon Music, Spotify, Kaset, Pear Desktop, reAMP, VOX, Pine Player, MyGo Music, foobar2000, WeRead, LX Music hoặc tự động nhận diện), cấp quyền Tự động hóa nếu bạn chọn Apple Music, Spotify, Kaset hoặc VOX (các trình phát khác không cần quyền để đọc thông tin bài hát cơ bản), và bật công cụ lời bài hát (để lời bài hát/ảnh bìa vẫn được tìm ngay cả khi cửa sổ đã đóng). Hoàn tất trình hướng dẫn là lời bài hát hiện ra ngay (xem [lyrimuse/README.md](lyrimuse/README.md) để biết thêm tùy chọn dựng).

Chỉ vậy là đủ để có lời bài hát. Các tiện ích tùy chọn có thể thiết lập sau trong Cài đặt, bất cứ khi nào bạn muốn.

## Câu hỏi thường gặp

### Làm sao để lời Apple Music nổi trên màn hình nền máy Mac, luôn ở trên cùng?
Bật lời nổi trên màn hình nền trong Cài đặt. Lời nổi luôn nằm trên mọi cửa sổ, ở mọi Space. Kéo đến bất cứ đâu bạn thích, hoặc ghim ở chính giữa phía trên hay ngay trên Dock. Nếu lời có thời gian theo từng chữ, mỗi chữ được tô dần khi hát. Bạn có thể ẩn lời nổi khi chụp màn hình, quay màn hình và chia sẻ màn hình, và cho lời nổi biến mất khi nhạc tạm dừng. Cách này hoạt động y hệt với QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, KKBOX, Amazon Music, LX Music, Spotify, Kaset và trình phát web.

### Có thể hiện lời Spotify trên thanh menu của máy Mac không?
Có. Bật chế độ chữ trên thanh menu, dòng hiện tại sẽ xuất hiện trên thanh menu, cho Spotify hay bất kỳ trình phát nào được hỗ trợ. Dòng dài sẽ cuộn thay vì bị cắt, và hàng thứ hai có thể hiện dòng tiếp theo, bản dịch hoặc phát âm. Bạn không cần kết nối tài khoản Spotify. Lyrimuse xin quyền Tự động hóa cho Spotify một lần, để biết chính xác vị trí phát và để các nút điều khiển phát hoạt động. Nếu bạn từ chối, lời vẫn hiện, nhưng thời gian lấy từ MediaRemote của macOS và có thể lệch khoảng một giây.

### Có lời theo từng chữ cho QQ Music, NetEase Cloud Music, Kugou hoặc Soda Music không?
Có, miễn là lời có thời gian theo từng chữ. NetEase Cloud Music, QQ Music, Kugou, Soda Music, Musixmatch, AMLL và Apple Music thường có, và những dòng đó được tô dần theo từng chữ. Lời chỉ có thời gian theo dòng sẽ sáng cả dòng cùng lúc. Trình phát cũng không giới hạn nguồn lời: một bài đang phát trong Soda Music vẫn có thể nhận lời theo từng chữ của QQ Music nếu lời đó đạt điểm cao nhất.

### Có cần tài khoản Apple Developer để cài đặt không?
Không. Các bản phát hành được ký bằng chứng chỉ riêng của dự án thay vì Apple Developer ID, nên cả bạn lẫn dự án đều không cần tài khoản này. Đó cũng là lý do có bước Gatekeeper một lần, như mô tả ở phần Bắt đầu phía trên.

### Lyrimuse có trên Mac App Store không?
Không. Cài bằng Homebrew (Cách A ở trên) hoặc tải từ [trang Releases](https://github.com/Yudaotor/lyrimuse/releases) (Cách B). Dù chọn cách nào, sau đó bản cập nhật đều đến qua ứng dụng.

### Lyrimuse có miễn phí không?
Có. Lyrimuse là phần mềm mã nguồn mở theo giấy phép GPL-3.0. Không có phiên bản trả phí, không có mua hàng trong ứng dụng và không cần đăng ký tài khoản. Có dùng Last.fm và các dịch vụ khác hay không là tùy bạn. Nếu thấy hữu ích và muốn ủng hộ, bạn có thể [tài trợ trên GitHub](https://github.com/sponsors/Yudaotor) hoặc [mời tác giả một ly cà phê](https://yudaotor.github.io/donate/) qua Alipay hoặc WeChat Pay.

### Có điều khiển được QQ Music, NetEase Cloud Music hoặc Soda Music khi ứng dụng khác đang giữ quyền điều khiển phương tiện của hệ thống không?
Có. Khi một thứ như video trong trình duyệt đang chiếm mục Đang phát của macOS, các phím phương tiện của hệ thống sẽ điều khiển nó; khi đó Lyrimuse sẽ bấm phát/tạm dừng, bài trước và bài tiếp theo trên thanh menu của chính QQ Music, MyGo Music hoặc NetEase Cloud Music, hoặc trên thanh phát của Soda Music, mà vẫn để trình phát chạy nền. Việc này cần quyền Trợ năng (Cài đặt → Trình phát); nếu chưa có, các nút đó sẽ mở trang cài đặt này. Ở trạng thái này không tua được. Trên macOS 27, quyền này nằm trong **Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Điều khiển thiết bị và truy cập dữ liệu**; các phiên bản trước gọi là **Trợ năng**.

### Lyrimuse có hoạt động với Spotify, QQ Music hoặc NetEase Cloud Music không, hay chỉ với Apple Music?
Hoạt động với tất cả các trình phát đó, cùng MyGo Music, Kugou Music, Soda Music, KKBOX, Amazon Music, Kaset (một ứng dụng YouTube Music), Pear Desktop (ứng dụng YouTube Music mã nguồn mở cho máy tính), trình phát kiểu Winamp reAMP, trình phát nhạc cục bộ lossless và hi-res VOX, trình phát nhạc cục bộ miễn phí Pine Player phát được gần như mọi định dạng, trình phát nhạc cục bộ kinh điển foobar2000 chuyển từ Windows sang, và LX Music mã nguồn mở, tổng cộng 17 trình phát. Hoặc để Lyrimuse tự động nhận diện bất cứ thứ gì macOS hiển thị là Đang phát. Apple Music, Spotify, Kaset và VOX xin quyền Tự động hóa (Spotify, Kaset và VOX dùng quyền này để có thời gian chính xác và các nút điều khiển phát). 13 trình phát còn lại không cần quyền để đọc thông tin bài hát cơ bản qua MediaRemote của macOS; nút xáo trộn, lặp lại và thích của QQ Music, NetEase Cloud Music, Kugou Music, Soda Music và Amazon Music, cùng xáo trộn, lặp lại và âm lượng của reAMP và foobar2000, cần quyền Trợ năng; Pine Player dùng quyền này để đọc thanh tiến trình, vì trình phát này chỉ báo vị trí chính xác đến từng giây. Với KKBOX, Amazon Music hoặc LX Music, lời mà ứng dụng đó đã lưu cho bài hát cũng được xem xét, và Lyrimuse không bao giờ liên hệ với ứng dụng nào trong số đó. MyGo Music không cần quyền Tự động hóa hay Quyền truy cập đầy đủ vào ổ đĩa và không có điều khiển thích, xáo trộn, lặp lại hoặc âm lượng. Khi được cấp quyền Trợ năng, Lyrimuse có thể dùng menu của MyGo Music để tạm dừng, tiếp tục và chuyển về bài trước hoặc sang bài sau khi ứng dụng khác giữ quyền điều khiển phương tiện của hệ thống. Nếu không cấp quyền, lời cơ bản và điều khiển phát khi trình phát đang giữ quyền điều khiển vẫn hoạt động bình thường. Không thể tua khi trình phát mất quyền điều khiển. WeRead còn hiển thị nguyên văn đang được đọc trong sách nói dưới dạng phụ đề.

### Có hiện được lời KKBOX hoặc Amazon Music trên máy Mac không?
Có. Cả hai được đọc qua MediaRemote của macOS, nên không cần cấp quyền gì, và lời của chúng hiện trong lời nổi, thanh menu, khung Dynamic Island và Cửa sổ lời như mọi trình phát khác. Nếu KKBOX hoặc Amazon Music đã lưu lời cho bài hát, lời đó cũng được xem xét và được cộng thêm điểm. Lyrimuse không bao giờ đăng nhập vào hai dịch vụ này hay gửi cho chúng bất cứ thứ gì. Các nguồn khác vẫn được tìm, nên nếu một nguồn có kết quả tốt hơn, chẳng hạn có thời gian theo từng chữ, nguồn đó sẽ thắng.


### Có hoạt động với LX Music (洛雪音乐) không?
Có. LX Music được đọc qua MediaRemote của macOS, nên không cần cấp quyền gì. Khi bạn phát một bài trong LX Music, lời mà LX Music đã lưu cho bài đó (theo từng chữ khi nền tảng có) cũng được xem xét và được cộng thêm điểm, và các bài tiếp theo trong danh sách bạn đang phát được chuẩn bị lời trước. Lyrimuse chỉ đọc dữ liệu của LX Music trên máy Mac và không bao giờ gửi gì cho ứng dụng này.

### Có hoạt động với ứng dụng YouTube Music trên máy tính không?
Có, với [Kaset](https://github.com/sozercan/kaset), một ứng dụng YouTube Music gốc, mã nguồn mở cho máy Mac. Lyrimuse đọc Kaset qua quyền Tự động hóa, nhờ đó có thời gian chính xác và các nút điều khiển phát hoạt động, và lời của chính YouTube Music nằm trong số các ứng viên. [Pear Desktop](https://github.com/pear-devs/pear-desktop), ứng dụng máy tính mã nguồn mở, cũng dùng được qua mục Đang phát của macOS, không cần thêm quyền. YouTube Music trong trình duyệt cũng dùng được, xem bên dưới.

### Lời trên màn hình nền trông như thế nào?
Giống karaoke trên màn hình nền. Dòng hiện tại nổi trên các cửa sổ, mỗi chữ được tô dần khi hát nếu lời có thời gian theo từng chữ, và bản dịch hoặc phát âm có thể nằm cùng. Bạn có thể đổi phông chữ, cỡ chữ, màu chữ, màu nền, màu bóng và độ rộng, và để màu chữ theo ảnh bìa album. Lời cũng có thể hiện trên thanh menu, trong khung kiểu Dynamic Island dưới tai thỏ, hoặc trong cửa sổ lời đầy đủ kiểu Apple Music, kết hợp tùy ý.

### Khung Dynamic Island có hoạt động trên máy Mac không có tai thỏ không?
Có. Trên màn hình không có tai thỏ, như MacBook đời cũ hoặc màn hình ngoài, khung nằm ở chính giữa phía trên, cao bằng thanh menu. Bạn chọn màn hình hiển thị khung trong Cài đặt.

### Lời bài hát có hoạt động khi không có kết nối internet không?
Có, với mọi bài mà ứng dụng đã tìm được lời, vì lời đó được lưu trong bộ nhớ đệm trên máy Mac. Lần tra cứu đầu tiên cho một bài cần kết nối mạng, dịch trực tuyến cũng vậy.

### Dữ liệu của tôi có rời khỏi máy Mac không?
Để tìm lời, ứng dụng phải hỏi các nguồn lời về bài đang phát: NetEase, QQ, Kugou, Kuwo, Migu, Musixmatch, LRCLIB, LyricFind, Deezer, AMLL, Soda Music, VIBE, Genie, PetitLyrics, và Apple Music nếu bạn đã kết nối. Ảnh bìa lấy từ iTunes Search API. Theo mặc định, việc dịch diễn ra trên máy Mac, và văn bản lời chỉ được gửi đến trình dịch trực tuyến (dịch trên web của Google, sau đó là MyMemory) khi cần dự phòng. Lịch sử nghe, lời trong bộ nhớ đệm và cài đặt nằm trong các tệp trên máy Mac, trừ khi bạn kết nối Last.fm, ListenBrainz hoặc trạm chuyển tiếp web tùy chọn. Dữ liệu sử dụng ẩn danh (phiên bản, tính năng nào đang bật, tóm tắt sự cố; không bao giờ có tên bài hát hay tài khoản) được gửi mỗi ngày một lần theo mặc định, và bạn có thể tắt trong Cài đặt › Giới thiệu. Danh sách đầy đủ nằm ở phần [Giấy phép và bản quyền](#giấy-phép-và-bản-quyền) bên dưới.

### Có phát âm tiếng Nhật/tiếng Hàn hoặc bản dịch tiếng Trung cho lời bài hát không?
Có. Lyrimuse chọn phát âm theo từng dòng, nên bài hát pha trộn nhiều ngôn ngữ chỉ có phát âm ở đúng chỗ cần. Tiếng Nhật có thể hiện romaji hoặc furigana (hiragana trên chữ Hán). Bản dịch lấy từ bản dịch cộng đồng của nguồn lời khi có, nếu không thì từ dịch máy trên thiết bị hoặc trực tuyến sau khi bạn bật “Dịch dự phòng của hệ thống” (mặc định tắt), sang bất kỳ ngôn ngữ nào trong 17 ngôn ngữ.

### Lyrimuse hỗ trợ những phiên bản macOS nào?
macOS 14 Sonoma trở lên (Sequoia, Tahoe và mới hơn), trên Apple Silicon hoặc Intel. Dịch trên máy Mac cần macOS 15 Sequoia trở lên; trên macOS 14 chỉ dùng được trình dịch trực tuyến.

### Có hỗ trợ máy Mac Intel không?
Có, với một bản dựng universal riêng (xem Cách B ở trên). Tự động cập nhật cũng hoạt động trên Intel từ v1.5.0, nên phiên bản mới xuất hiện giống như trên Apple Silicon.

### Có hiện được lời cho YouTube Music hoặc Spotify phát trong trình duyệt không?
Có. Ghép đôi trình duyệt một lần trong Cài đặt, YouTube Music hoặc Spotify Web sẽ hoạt động như mọi trình phát khác. Lời bám theo chính thanh tiến trình của trang thay vì đoán, và bài kiểm tra bằng một cú bấm cho bạn biết trước khi bắt tay vào việc trình duyệt có điều khiển được hay không.

### Có scrobble Apple Music lên Last.fm trên máy Mac được không?
Có, đó là nửa còn lại của ứng dụng. Kết nối Last.fm bằng một cú bấm trong Cài đặt, mọi lượt phát từ Apple Music (hoặc bất kỳ trình phát nào được hỗ trợ) đều được scrobble, kèm trạng thái “đang phát” trực tiếp. Lượt phát được lưu trên máy Mac trước, nên những lượt trước khi bạn kết nối không bị mất: sau khi kết nối, bấm “Gửi bù” để gửi những lượt trong khoảng hai tuần gần nhất. Bạn chọn khi nào một lượt phát được tính (50%, 75%, 90% hoặc cả bài), có thể loại trừ một số trình phát, và có thể gửi cả lên ListenBrainz cùng lúc.

### Lyrimuse làm thế nào để tránh chọn sai lời?
Lyrimuse không lấy nguồn đầu tiên trả lời. Mọi kết quả từ mọi nguồn đều được chấm điểm theo cùng một cách: tên bài, nghệ sĩ, album và thời lượng khớp đến đâu, cộng thêm những yếu tố như có thời gian theo từng chữ hay không. Điểm cao nhất thắng. Bạn có thể xem quyết định đó cho bất kỳ bài nào, với điểm của mọi ứng viên và lý do kết quả thắng được chọn. Nếu sau này có kết quả khớp hơn, Lyrimuse có thể tự chuyển sang, nhưng lời bạn chọn tay sẽ bị khóa và không bao giờ bị thay. Tìm thủ công hiện cùng điểm số và nhãn đó, nên bạn dễ nhận ra phiên bản sai trước khi chọn.

### Nếu lời bị lệch thời gian hoặc sai thì sao?
Nếu thời gian bị lệch, hãy chỉnh độ lệch cho bài đó; độ lệch sẽ được ghi nhớ. Nếu sai lời hoặc sai phiên bản, hãy mở tìm thủ công. Bạn sẽ thấy mọi kết quả từ mọi nguồn kèm điểm, và lời bạn chọn sẽ bị khóa, nên tính năng tự động khớp không thay nó. Bạn cũng có thể sửa tay lời của bất kỳ bài nào trong Quản lý lời.

### Có lưu lời thành tệp .lrc được không?
Lời vốn đã được lưu như vậy. Mỗi bài có lời đều có một tệp `.lrc` với thời gian theo dòng, cùng `.tr.lrc` cho bản dịch và `.roma.lrc` cho phát âm khi có. Thời gian theo từng chữ được lưu riêng, mặc định ở dạng TTML. Trong Cài đặt, bạn có thể chuyển sang `.yrc` (định dạng YRC của NetEase), LRC nâng cao, QRC hoặc KRC để trình phát khác đọc được, và giữ nhiều định dạng cùng lúc. Các tệp nằm trong `~/Library/Application Support/me.yudaotor.lyrimuse/lyrics/`, và bạn có thể chuyển thư mục này sang chỗ khác trong Cài đặt.

### LyricsX còn được duy trì không, và Lyrimuse khác LyricsX hay Lyric Fever ở điểm nào?
Bản phát hành cuối cùng của LyricsX là v1.6.3, vào tháng 4 năm 2022. LyricsX chạy trên macOS 10.11 trở lên và hoạt động với Apple Music, Spotify và vài trình phát cũ. Lyric Fever tập trung vào Spotify và Apple Music và cần macOS 15. Lyrimuse cần macOS 14 và bổ sung QQ Music, NetEase Cloud Music, Kugou, Soda Music, KKBOX, Amazon Music, Kaset, Pear Desktop, reAMP, VOX, Pine Player, MyGo Music, foobar2000 và LX Music, các trình phát trong trình duyệt, phát âm theo từng dòng (pinyin / Jyutping tiếng Quảng Đông / phát âm tiếng Nhật và tiếng Hàn) cùng phát âm cho 18 ngôn ngữ khác như tiếng Nga và tiếng Thái, và scrobble lên Last.fm / ListenBrainz kèm thống kê nghe nhạc của riêng bạn. Bảng so sánh chi tiết có trên [trang so sánh](docs/lyrics-apps-comparison.md).
## Giấy phép và bản quyền

- **Bản thân Lyrimuse theo giấy phép [GPL-3.0](LICENSE).** Các thành phần mã nguồn mở và dữ liệu từ điển đi kèm trong ứng dụng (media-control, Sparkle, KeyboardShortcuts, cùng từ điển OpenCC và rime-cantonese) giữ giấy phép riêng của chúng; toàn văn nằm trong [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES), tệp này cũng được đóng gói trong ứng dụng và có thể mở từ **Cài đặt → Giới thiệu → Giấy phép của bên thứ ba**.
- **Lời bài hát, ảnh bìa và siêu dữ liệu bài hát thuộc về chủ sở hữu quyền tương ứng.** Lyrimuse chỉ tra cứu, lưu đệm và hiển thị chúng: những gì các API lời bài hát công khai trả về được lưu trên chính máy Mac của bạn (`~/Library/Application Support/me.yudaotor.lyrimuse/`) để bạn tự xem. Lyrimuse không lưu trữ trên máy chủ, chuyển tiếp hay phân phối lại lời bài hát hoặc ảnh bìa, và bạn có thể xóa bộ nhớ đệm bất cứ lúc nào từ Quản lý lời hoặc bằng cách xóa thư mục đó.
- **Lyrimuse là dự án mã nguồn mở độc lập.** Lyrimuse không liên kết với, không được chứng thực bởi và không có quan hệ với Apple, Tencent (QQ Music), NetEase (NetEase Cloud Music), Kugou, Kuwo, Douyin (Soda Music), KKBOX, Amazon (Amazon Music), China Mobile (Migu Music), Spotify, Kaset, LX Music, Google (YouTube Music, Google Translate), Last.fm, ListenBrainz, MusicBrainz, Musixmatch, LRCLIB, LyricFind, Deezer, Naver (VIBE), KT (Genie), SyncPower (PetitLyrics), AMLL hay SponsorBlock. Tên và nhãn hiệu thuộc về chủ sở hữu của chúng và chỉ xuất hiện ở đây để nêu những trình phát, nguồn lời và dịch vụ có liên quan.
- **Đây là mọi thứ rời khỏi máy Mac của bạn.** Khi tìm lời, Lyrimuse gửi nghệ sĩ, tên bài và album của bài hát (cùng thời lượng, với các nguồn chấp nhận) đến 15 nguồn lời bài hát nêu trên; khi không nguồn nào khớp, tên nghệ sĩ cũng được gửi đến MusicBrainz để tra các tên gọi khác (tính năng “Khớp thông minh” của Last.fm cũng làm vậy với những nghệ sĩ chưa gặp trước đó), và các bảng xếp hạng tra cứu nghệ sĩ của chúng tại đó theo MusicBrainz ID để lấy quốc gia/khu vực và liên kết. Ảnh bìa và trang khi không phát gửi nghệ sĩ + tên bài đến iTunes Search API; với Kaset hoặc Pear Desktop, ảnh bìa mà trình phát báo được tải về từ máy chủ hình ảnh của YouTube Music (googleusercontent.com), và mỗi ID video mới mà Kaset phát được gửi đến YouTube Music một lần để kiểm tra xem đó có phải là một tập podcast không (những tập này không được coi là bài hát). Khi bật Open API của LX Music, Lyrimuse chỉ giao tiếp với cổng riêng của LX Music trên máy Mac này, và khi hệ thống không có ảnh bìa cho bài hát, Lyrimuse tải ảnh bìa mà LX Music chỉ đến, một lần. Giới thiệu album và tiểu sử nghệ sĩ yêu cầu trang Apple Music công khai của album và nghệ sĩ theo Apple Music ID — không dùng tài khoản Apple nào; khi giao diện bằng tiếng Trung và Apple Music không có tiểu sử nghệ sĩ hay giới thiệu album, NetEase Cloud Music ID của bài hát được dùng để tra các nghệ sĩ được ghi tên và album của bài, rồi lấy phần giới thiệu nghệ sĩ hoặc album đó của NetEase theo ID, cũng không cần đăng nhập. Với giao diện tiếng Trung, giới thiệu bài hát cũng yêu cầu thông tin chi tiết của bài từ QQ Music theo ID bài hát QQ Music, cũng không cần đăng nhập. Khi QQ Music đang phát, thông tin chi tiết đó được yêu cầu một lần cho mỗi bài ở mọi ngôn ngữ giao diện, để phân biệt sách nói và các chương trình nói khác với bài hát (phụ đề của chúng vẫn hiện, nhưng chúng không được scrobble hay hiển thị như một bài hát). Khi Apple Music không có ảnh bìa động cho album, ID album QQ Music của album được gửi đến QQ Music để kiểm tra ảnh bìa động; nếu có, địa chỉ video được yêu cầu theo ID video QQ Music trong lúc Cửa sổ lời đang mở, và video được tải từ máy chủ video của QQ Music (tencentmusic.com), không cần đăng nhập. Nếu QQ Music cũng không có, NetEase Cloud Music ID của bài hát được gửi đến NetEase để kiểm tra, dưới danh tính khách ẩn danh mà NetEase cấp cho khách truy cập không có tài khoản; video lấy từ máy chủ video của NetEase (126.net). Khi Kugou đang phát, nghệ sĩ và tên bài được gửi đến tìm kiếm web của Kugou một lần để tìm trang web của bài hát, không cần đăng nhập. Nền Spotify Canvas của Cửa sổ lời chỉ đọc bộ nhớ đệm mà Spotify lưu trên máy Mac và không yêu cầu gì từ Spotify; video tìm thấy ở đó được tải một lần từ CDN của Spotify (canvaz.scdn.co), chỉ gửi địa chỉ của video. Giới thiệu album và tiểu sử nghệ sĩ cũng có thể tìm album trên YouTube Music theo tên nghệ sĩ và tên album (bài phát trong Kaset hoặc YouTube Music trên web dùng ID album và ID nghệ sĩ mà trình phát báo) và lấy mô tả Wikipedia trên trang album và trang nghệ sĩ; với bài phát trong Soda Music, trang chia sẻ công khai của album và nghệ sĩ được yêu cầu theo các ID mà Soda Music báo. Cả hai đều không cần tài khoản. Với giao diện tiếng Trung, đối với bài mà LX Music phát từ Kuwo, Kuwo ID của bài được gửi đến Kuwo để tra ID album và ID nghệ sĩ, rồi phần giới thiệu album và nghệ sĩ được yêu cầu theo các ID đó, cũng không cần đăng nhập. Với bài phát trong Kugou Music, công cụ lời bài hát hỏi Kugou một lần xem tệp đang phát thuộc album nào; với giao diện tiếng Trung, phần giới thiệu album của Kugou sau đó được yêu cầu theo ID album đó và phần giới thiệu nghệ sĩ theo ID của nghệ sĩ album, cũng không cần đăng nhập. Dịch máy dự phòng (mặc định tắt, và chỉ dùng khi không có bản dịch trên thiết bị của Apple) gửi **chính văn bản lời bài hát**, theo từng đoạn, đến điểm cuối dịch trên web của Google trước, và phần nào vẫn chưa dịch được thì gửi đến MyMemory; yêu cầu gửi MyMemory mang một tham số e-mail được tạo ngẫu nhiên — không bao giờ là e-mail của bạn. Khi một video âm nhạc phát trong YouTube Music, bốn ký tự đầu tiên của mã băm SHA-256 của ID video được gửi đến SponsorBlock để tìm các đoạn không phải nhạc của video, giúp lời khớp với hình; từ đó SponsorBlock không thể biết đó là video nào. Tên miền của Musixmatch được phân giải bằng DNS-over-HTTPS qua Cloudflare (1.1.1.1) và Google (8.8.8.8). Trang Giới thiệu hỏi GitHub API số sao tối đa sáu giờ một lần, và nếu bạn chọn nhận bản cập nhật beta, hỏi danh sách bản phát hành tối đa mỗi giờ một lần; việc kiểm tra bản cập nhật tải appcast từ GitHub Releases và không gửi hồ sơ hệ thống. “Gửi dữ liệu sử dụng ẩn danh” được bật theo mặc định (Cài đặt › Giới thiệu › Chẩn đoán & dữ liệu; màn hình chào mừng ở lần mở đầu tiên có cùng công tắc này). Tối đa mỗi ngày một lần, tùy chọn này gửi đến máy chủ riêng của tác giả (telemetry.yudaotor.me, một Cloudflare Worker) một ID cài đặt ngẫu nhiên được tạo trên máy Mac, Lyrimuse là bản cài mới hay được nâng cấp từ phiên bản cũ, phiên bản Lyrimuse và macOS, chip, ngôn ngữ giao diện và ngôn ngữ hệ thống, khu vực đặt trong cài đặt macOS, những tính năng đang bật (cách hiển thị lời, trình phát đã chọn, bao nhiêu nguồn lời đang bật, công tắc bản dịch và phát âm, các tài khoản như Last.fm đã kết nối hay chưa, những trình phát và trình duyệt bên thứ ba bạn tin cậy (chỉ bundle ID), những trình phát web bạn đã ghép đôi, Lyrimuse được cài bằng Homebrew hay tải trực tiếp, tên các cài đặt bạn đã đổi khỏi mặc định (không gửi giá trị), những quyền mà trình phát đã chọn còn thiếu), những trình phát đã phát nhạc trong các ngày trước, số lần ứng dụng bị treo và số lần bạn mở cửa sổ lời, tự chọn lời, chỉnh thời gian hoặc chia sẻ thẻ lời, cùng số bài đã phát có lời đồng bộ theo từng chữ, theo dòng hay chỉ có văn bản, là nhạc không lời hay không tìm thấy lời, và trong số bài có lời thì mỗi ngôn ngữ có bao nhiêu bài (xét theo lời); khi Lyrimuse hoặc công cụ lời bài hát gặp sự cố, tùy chọn này cũng gửi bản tóm tắt sự cố (loại ngoại lệ và tên hàm trên ngăn xếp, đã bỏ đường dẫn). Tùy chọn này không bao giờ gửi tên bài hát, nghệ sĩ, album, đường dẫn cục bộ, tên tài khoản hay thông tin đăng nhập; máy chủ không lưu địa chỉ IP, chỉ lưu quốc gia hoặc khu vực mà Cloudflare suy ra từ địa chỉ đó. Tắt đi thì không có gì được gửi. Ngoài ra, chỉ có các dịch vụ do bạn tự kết nối: Last.fm, ListenBrainz, các nền tảng thông báo đẩy, trạm chuyển tiếp web tùy chọn (trang 10 nghệ sĩ hàng đầu của trạm này tra ảnh đại diện nghệ sĩ trên Deezer). Khi bật “Hiện trên Discord” trong cài đặt Discord, tên bài, nghệ sĩ, album, tên trình phát, tiến trình phát, URL ảnh bìa và liên kết đến bài hát và nghệ sĩ (cùng dòng lời đang hát và liên kết của các nút, nếu bạn bật) được chuyển cho ứng dụng Discord trên máy Mac, ứng dụng này hiển thị chúng trên hồ sơ của bạn; ảnh bìa là ảnh do chính trình phát cung cấp, ảnh đã có trên trạm chuyển tiếp web của bạn, hoặc cùng ảnh đó trên NetEase Cloud Music, QQ Music hay Apple Music (khi công cụ lời bài hát chuyển sang ảnh bìa riêng của trình phát, nó tải ảnh thu nhỏ của ảnh đó một lần để kiểm tra xem có khớp không) khi có thể; nếu không, ảnh bìa được tra trên iTunes theo ID bài hát hoặc ID album Apple Music (hoặc theo nghệ sĩ + tên bài), và với video không có ảnh nào khác, URL ảnh thu nhỏ YouTube của video được dùng. Với Apple Music, việc tra theo ID bài hát vẫn chạy cả khi trạm chuyển tiếp đã có ảnh bìa, để lấy trang của nghệ sĩ. Sau khi kết nối, ảnh đại diện Discord hiện trong Cài đặt (và trang trí ảnh đại diện của bạn, nếu có, cho phần xem trước) được tải từ máy chủ hình ảnh của Discord (cdn.discordapp.com), và trong lúc trang Discord trong Cài đặt đang mở, phần xem trước tải ảnh bìa từ URL trong trạng thái của bạn để vẽ. Khi ảnh bìa của chính trình phát nhỏ, công cụ lời bài hát tải ảnh thu nhỏ của ảnh bìa tương ứng trên NetEase Cloud Music, QQ Music hoặc Apple Music, của ảnh bìa mà chính trình phát lưu (gồm máy chủ hình ảnh của KKBOX và Amazon Music, cùng máy chủ hình ảnh của Kuwo và Migu đứng sau ảnh bìa của LX Music), và của các ảnh bìa đi kèm kết quả từ nguồn lời (như máy chủ hình ảnh của Kugou, Soda Music, Deezer và Musixmatch), để kiểm tra xem có phải cùng một ảnh không; khi URL ảnh bìa không ghi kích thước, công cụ còn tải phần đầu của ảnh để đọc kích thước. Chỉ URL ảnh được gửi đi. Khi bật “Lời trên web” hoặc “Đầu ra OBS” (cả hai mặc định tắt), Lyrimuse phục vụ một trang trên máy Mac này (cổng 3939 và 3940 trừ khi bạn đổi); chỉ máy Mac này mở được trang cho đến khi bạn bật “Cho phép truy cập mạng cục bộ”, sau đó các thiết bị trong mạng của bạn có liên kết (liên kết chứa một khóa ngẫu nhiên) có thể xem lời hiện tại, ảnh bìa và tiến trình, và khi bật “Cho phép điều khiển từ xa”, có thể điều khiển phát. Lyrimuse không tự gửi gì đi đâu cả. Mọi yêu cầu gửi ra ngoài đều được ghi vào nhật ký kiểm tra cục bộ — chỉ máy chủ và thao tác, không bao giờ có tham số hay thông tin đăng nhập — và “Xuất chẩn đoán” có kèm nhật ký này.

## Khắc phục sự cố

Nếu lời không hiện, mở **Nguồn lời bài hát** trong Cài đặt và bấm **Kiểm tra** để xem nguồn nào không kết nối được. Nếu vẫn chưa ổn, dùng **Xuất chẩn đoán** và đính kèm tệp vào một [issue](https://github.com/Yudaotor/lyrimuse/issues); tệp đã gồm toàn bộ kết quả tự kiểm tra của dịch vụ nền.

<details>
<summary>Tự kiểm tra bằng dòng lệnh</summary>

Cùng phép kiểm tra đó, chạy từ Terminal:

```sh
/Applications/Lyrimuse.app/Contents/Resources/lyrimuse-engine healthcheck
/Applications/Lyrimuse.app/Contents/Resources/lyrimuse-engine healthcheck -local-only  # no network
/Applications/Lyrimuse.app/Contents/Resources/lyrimuse-engine healthcheck -json
```

</details>

## Phản hồi

- **Sự cố và ý tưởng**: trong ứng dụng, mở Cài đặt › Giới thiệu › **Báo cáo sự cố**, hoặc bấm chuột phải vào biểu tượng trên thanh menu rồi chọn **Trợ giúp › Báo cáo sự cố…**. Thao tác này mở một issue mới trên GitHub, điền sẵn phiên bản, macOS và trình phát hiện tại của bạn; chọn loại báo cáo: lỗi, thiếu hoặc sai lời, yêu cầu hỗ trợ trình phát, hoặc yêu cầu tính năng.
- **Sai lời cho một bài**: mở **Tìm lời bài hát** cho bài đó trong **Quản lý lời** rồi bấm **Không tìm thấy lời đúng? Hãy báo trên GitHub** ở góc dưới bên trái. Thông tin bài hát, nguồn lời đang dùng và các nguồn đã trả về kết quả sẽ được gửi kèm.
- **Câu hỏi**: hỏi trong [mục Q&A](https://github.com/Yudaotor/lyrimuse/discussions/categories/q-a) của Discussions.
- **Trò chuyện với người dùng khác**: tham gia [máy chủ Discord](https://discord.gg/N7gVy66Gp3), [nhóm Telegram](https://t.me/lyrimuse) hoặc [nhóm QQ](https://qm.qq.com/q/Nb4TlwfnQy) (791558369, bằng tiếng Trung). Bạn cũng có thể đặt câu hỏi, báo sự cố hoặc đề xuất tính năng ở đó; trên Discord còn có kênh trò chuyện và diễn đàn phản hồi riêng cho tiếng Trung.
- **Không có tài khoản GitHub**: gửi email đến yudaotor@qq.com. Nút phong bì trên hàng **Báo cáo sự cố** trong Cài đặt › Giới thiệu sẽ điền sẵn phiên bản và macOS của bạn; bấm chuột phải vào nút để sao chép địa chỉ.
- **Vấn đề bảo mật**: báo cáo riêng tư theo hướng dẫn trong [SECURITY.md](SECURITY.md), không đăng trong issue công khai.

## Gỡ cài đặt

Kéo `Lyrimuse.app` vào Thùng rác là **chưa** đủ. Công cụ lời bài hát (tên tiến trình `lyrimuse-engine`) được
đăng ký với launchd dưới dạng tác vụ `KeepAlive`, nên LaunchAgent của nó vẫn còn lại và
launchd cứ tiếp tục cố khởi động một tệp nhị phân không còn tồn tại.

```sh
lyrimuse/scripts/uninstall.sh              # report only — shows what is installed
lyrimuse/scripts/uninstall.sh --services   # unregister both launchd jobs, keep your data
lyrimuse/scripts/uninstall.sh --purge      # also delete config, caches, logs and settings
```

Chạy không kèm đối số sẽ không thay đổi gì; script chỉ cho bạn biết những gì đang có trên
hệ thống. `--purge` liệt kê mọi thứ sắp xóa, cảnh báo trong đó có bao nhiêu tệp lời
đã xuất, và yêu cầu bạn gõ `yes`.

`--services` giữ nguyên cài đặt của bạn. `--purge` xóa cả cài đặt
(`defaults delete me.yudaotor.lyrimuse`), vì nếu để lại, việc cài lại sẽ rơi vào
ngõ cụt: LaunchAgent đã mất nên công cụ lời bài hát chưa được cài, nhưng ứng dụng vẫn nghĩ
đã thiết lập xong — nên trình hướng dẫn lẽ ra sẽ cài công cụ không bao giờ xuất hiện, và màn hình nền cứ đứng ở
“đang tìm lời bài hát”.

## Cấu trúc dự án

Kho này là ứng dụng:

- [`lyrimuse/`](lyrimuse) — bản thân ứng dụng (Swift, SwiftUI + AppKit)
- [`lyrimuse-engine/`](lyrimuse-engine) — công cụ chạy nền tìm lời bài hát/ảnh bìa và cung cấp cho ứng dụng (Go); được tự động dựng và đóng gói vào ứng dụng

<details>
<summary>Trang web tùy chọn: hai kho anh em</summary>

Trải nghiệm web tùy chọn nằm ở hai kho anh em, nên bạn có thể fork bất kỳ kho nào mà không động đến ứng dụng:

| Kho | Vai trò |
|---|---|
| [`Yudaotor/nowplaying`](https://github.com/Yudaotor/nowplaying) | Chính trang web “đang phát” để chia sẻ, kèm một mẫu sẵn sàng để fork |
| [`Yudaotor/nowplaying-workers`](https://github.com/Yudaotor/nowplaying-workers) | Trạm chuyển tiếp Cloudflare Worker + huy hiệu README trực tiếp đứng sau trang đó, kèm hướng dẫn thiết lập đầy đủ từ đầu |

```
this repo (app + engine)  ──push──▶  nowplaying-workers (relay)  ◀──read──  nowplaying (web page)
```

</details>

## Lời cảm ơn

Cảm ơn [LyricsX](https://github.com/ddddxxx/LyricsX), dự án đã cho thấy lời bài hát trên màn hình nền máy Mac có thể như thế nào.

<details>
<summary>Các dự án mã nguồn mở và dữ liệu cộng đồng mà Lyrimuse dựa vào</summary>

- [media-control](https://github.com/ungive/media-control) và [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter): đọc nội dung đang phát trên macOS
- [Sparkle](https://github.com/sparkle-project/Sparkle): cập nhật trong ứng dụng
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts): phím tắt toàn cục
- [OpenCC](https://github.com/BYVoid/OpenCC): chuyển đổi tiếng Trung Giản thể / Phồn thể
- [rime-cantonese](https://github.com/rime/rime-cantonese): Jyutping tiếng Quảng Đông
- [AMLL TTML DB](https://github.com/amll-dev/amll-ttml-db): lời theo từng chữ do cộng đồng tạo
- [LRCLIB](https://lrclib.net): cơ sở dữ liệu lời đồng bộ mở
- [SponsorBlock](https://sponsor.ajay.app): các đoạn không phải nhạc trong video âm nhạc

</details>

Văn bản giấy phép nằm trong [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
