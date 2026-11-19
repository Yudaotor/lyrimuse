<!-- scripts/gen-feature-list.py tarafından shared/feature-list.json ve shared/settings-catalog.json dosyalarından oluşturuldu; listeyi değiştirmek için bu dosyaları düzenleyin. -->

# Lyrimuse Özellikleri

[English](feature-list.md) · [简体中文](feature-list.zh-CN.md) · [繁體中文](feature-list.zh-Hant.md) · [日本語](feature-list.ja.md) · [한국어](feature-list.ko.md) · [Español](feature-list.es.md) · [Français](feature-list.fr.md) · [Deutsch](feature-list.de.md) · [Italiano](feature-list.it.md) · [Português (Brasil)](feature-list.pt-BR.md) · [Tiếng Việt](feature-list.vi.md) · [Русский](feature-list.ru.md) · [Українська](feature-list.uk.md) · [ไทย](feature-list.th.md) · Türkçe · [हिन्दी](feature-list.hi.md)

Lyrimuse, kelime kelime eşzamanlı şarkı sözleri için açık kaynaklı (GPL-3.0) bir Mac uygulamasıdır; Apple Silicon ve Intel işlemcili Mac’lerde macOS 14 veya sonraki sürümlerde çalışır. Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Kuwo, Soda Music, KKBOX, Amazon Music, LX Music, Kaset, Pear Desktop, reAMP, VOX, Pine Player, foobar2000, Cog, Swinsian, Plexamp, MyGo Music, Audirvana ile tarayıcıda çalan YouTube Music veya Spotify Web için şarkı sözlerini gösterir: masaüstünde yüzen, çentiğin yanında, menü çubuğunda, Touch Bar’da veya tam sayfa bir şarkı sözü penceresinde; çeviri ve telaffuzla birlikte (pinyin, Kantonca Jyutping, Japonca romaji, Korece Latin harfleriyle yazım). Last.fm ve ListenBrainz’e skroplar, çaldığınız parçayı Discord’da gösterebilir. Arayüz dilleri: İngilizce, Basitleştirilmiş Çince, Geleneksel Çince, Japonca, Korece, İspanyolca, Fransızca, Almanca, İtalyanca, Brezilya Portekizcesi, Vietnamca, Rusça, Ukraynaca, Tayca ve Türkçe.

Lyrimuse’un tüm özellikleri burada: her birinin ne yaptığı, ayarlarda nerede olduğu ve yüklendikten sonra açık olup olmadığı; sonda Ayarlar penceresindeki tüm ayarlar listelenir. Liste kaynak kodla birlikte tutulur ve her değişiklikte güncellenir.

## İçindekiler

- [Siz açana kadar kapalı](#section-off-by-default)
- [Şarkı sözlerini bulma](#section-lyrics)
- [Çeviri, telaffuz ve satır düzeni](#section-text)
- [Şarkı sözleri nerede ve nasıl görünür](#section-display)
- [Çalarlar ve çalma](#section-players)
- [Skroplama, Last.fm ve paylaşım](#section-listening)
- [Gündelik kullanım](#section-general)
- [Tüm Ayarlar](#section-all-settings)

<a id="section-off-by-default"></a>

## Siz açana kadar kapalı

Bu özellikler yüklendikten sonra kapalıdır. Önce ayarlardan açın (bazıları için ayrıca bir hesap veya izin gerekir):

| Özellik | Nereden açılır |
|---|---|
| [Apple Music’in kendi şarkı sözleri](#feature-apple-music-lyrics) | Ayarlar › Şarkı Sözleri › Kaynak › Şarkı Sözü Kaynakları |
| [Çalarınızın kaydettiği şarkı sözlerini kullanma](#feature-player-local-lyrics) | Ayarlar › Çalar › İzinler ve Hizmetler › Tam Disk Erişimi |
| [Parça dosyasındaki şarkı sözlerine öncelik verme](#feature-prefer-local-file-lyrics) | Ayarlar › Şarkı Sözleri › Kaynak › Parça Dosyasındaki Sözleri Tercih Et |
| [Şarkı sözlerini parça dosyalarına yazma](#feature-lyrics-writeback) | Ayarlar › Deneysel › Parça Dosyalarına Otomatik Yaz |
| [Elle seçilen şarkı sözlerini kilitleme](#feature-lock-hand-picked) | Ayarlar › Şarkı Sözleri › Kaynak › Elle Seçilen Sözleri Kilitle |
| [Çeviri yoksa makine çevirisi](#feature-machine-translation) | Ayarlar › Şarkı Sözleri › Dil › Çeviri Yoksa Otomatik Çevir |
| [Uzun satırları bölme, kısa satırları birleştirme](#feature-split-join-lines) | Ayarlar › Şarkı Sözleri › Zamanlama ve Satır Bölme › Uzun Satırları Böl |
| [Çentik sözleri](#feature-notch-lyrics) | Ayarlar › Şarkı Sözü Görünümü › Çentik › Çentik Sözleri |
| [Menü çubuğu sözleri](#feature-menu-bar-lyrics) | Ayarlar › Şarkı Sözü Görünümü › Menü Çubuğu › Menü Çubuğu Sözleri |
| [Touch Bar sözleri](#feature-touch-bar-lyrics) | Ayarlar › Şarkı Sözü Görünümü › Touch Bar › Touch Bar Sözleri |
| [Yazarken Touch Bar kenara çekilir](#feature-touch-bar-collapse-while-typing) | Ayarlar › Şarkı Sözü Görünümü › Touch Bar › Davranış › Yazarken Daralt |
| [Şarkı sözü penceresinde HDR vurgusu](#feature-lyrics-window-hdr) | Ayarlar › Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Renk › HDR Vurgusu |
| [Mini pencere duraklatıldığında veya tam ekranda gizlenir](#feature-mini-window-auto-hide) | Ayarlar › Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Davranış › Duraklatınca Gizle |
| [Spotify Canvas arka planı](#feature-spotify-canvas) | Ayarlar › Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Arka Plan › Spotify Canvas |
| [Satır geçişi](#feature-line-transition) | Ayarlar › Şarkı Sözü Görünümü › Yüzen Sözler › Yerleşim › Satır Geçişi |
| [Dönüşümlü iki satırlı yerleşim](#feature-alternate-next-line) | Ayarlar › Şarkı Sözü Görünümü › Yüzen Sözler › İçerik › Sonraki Satır Yerleşimi |
| [İşaretçi üzerindeyken soluklaşma](#feature-fade-on-hover) | Ayarlar › Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Üzerine Gelince Soldur |
| [Konumu kilitleme, sürüklemek için uzun basma](#feature-lock-position) | Ayarlar › Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Konumu Kilitle |
| [Ekran görüntülerinde ve ekran paylaşımında gizli](#feature-hide-in-screenshots) | Ayarlar › Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Ekran Resimlerinde Gizle |
| [Duraklatınca gizleme veya küçültme](#feature-hide-when-paused) | Ayarlar › Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Duraklatınca Gizle |
| [Enstrümantallerde ve sözsüz parçalarda gizleme](#feature-hide-when-no-lyrics) | Ayarlar › Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Söz Yoksa Gizle |
| [Şarkı sözü yokken şarkı adı](#feature-title-when-no-lyrics) | Ayarlar › Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Şarkı Sözü Yoksa Parça Adını Göster |
| [Reklamlarda kenara çekilme](#feature-hide-during-ads) | Ayarlar › Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Reklamlarda Gizle |
| [Kilitli ekranda çentik](#feature-notch-show-on-lock-screen) | Ayarlar › Şarkı Sözü Görünümü › Çentik › Davranış › Kilitli Ekranda Göster |
| [Tam ekranda yüzen sözler kenara çekilir](#feature-overlay-hide-in-full-screen) | Ayarlar › Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Tam Ekranda Gizle |
| [Üzerine gelince çentikteki şarkı sözü satırını soldurma](#feature-notch-lyric-row-fade) | Ayarlar › Şarkı Sözü Görünümü › Çentik › Şarkı Sözü Satırı › Üzerine Gelince Soldur |
| [Müziği izleyen ses dalgası](#feature-notch-wave-follows-music) | Ayarlar › Şarkı Sözü Görünümü › Çentik › Sol Kulak › Müzikle Hareket Et |
| [Tarayıcıda şarkı sözleri: ikinci ekran olarak telefon veya tablet ya da OBS tarayıcı kaynağı](#feature-web-lyrics) | Ayarlar › Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Tarayıcıda Şarkı Sözleri |
| [Tarayıcınızda YouTube Music ve Spotify Web](#feature-web-players) | Ayarlar › Çalar › Web |
| [YouTube Music reklamlarını otomatik atlama](#feature-skip-youtube-ads) | Ayarlar › Çalar › Web › YouTube Music Reklamlarını Otomatik Atla |
| [Çalarınızla birlikte açılma ve kapanma](#feature-player-linkage) | Ayarlar › Çalar › Açılış ve Çıkış › Açılışta Çalarları Aç |
| [Last.fm skroplama ve dinleme profili](#feature-lastfm) | Ayarlar › Last.fm › Kurallar › Skroplama Kuralları |
| [ListenBrainz’e de skroplama](#feature-listenbrainz) | Ayarlar › Deneysel › ListenBrainz › Hesap Bilgileri |
| [Çaldığınızı Discord’da gösterme](#feature-discord) | Ayarlar › Discord › Discord’da Göster |
| [Ne dinlediğinizi gösteren paylaşılabilir bir web sayfası](#feature-now-playing-page) | Ayarlar › Deneysel › Web Anlık Bildirimleri › Bağlantı Bilgileri |
| [Günlük, haftalık, aylık ve yıllık dinleme raporları](#feature-digests) | Ayarlar › Anlık Bildirimler › Kanallar |
| [Sessizce başlat](#feature-silent-launch) | Ayarlar › Genel › Başlangıç ve Bildirimler › Sessizce Başlat |
| [Parça değişince bildir](#feature-song-notifications) | Ayarlar › Genel › Başlangıç ve Bildirimler › Parça Değişince Bildir |
| [Otomatik güncellemeler ve beta sürümler](#feature-updates) | Ayarlar › Yazılım Güncelleme › Güncelleme Ayarları › Otomatik Olarak Denetle |

<a id="section-lyrics"></a>

## Şarkı sözlerini bulma

<a id="feature-lyric-sources"></a>

### 16 şarkı sözü kaynağı, otomatik arama

NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, LRCLIB, LyricFind, Deezer, AMLL, Soda Music, VIBE, Genie, PetitLyrics, Zing MP3, Megalobiz ve Apple Music. Her kaynak kapatılabilir, yeniden sıralanabilir veya şu an erişilebilir olup olmadığı test edilebilir.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözleri › Kaynak › Şarkı Sözü Kaynakları

<a id="feature-network-proxy"></a>

### Yurt dışı şarkı sözü kaynakları için vekil sunucuyla yeniden deneme

Yurt dışındaki bir şarkı sözü kaynağına doğrudan ulaşılamadığında Lyrimuse, sistem vekil sunucusu veya Clash gibi yerel bir vekil sunucu üzerinden yeniden dener. Vekil sunucuyu kendiniz de girebilir ya da bu özelliği kapatabilirsiniz. Çin anakarasındaki şarkı sözü kaynaklarına her zaman doğrudan bağlanılır.

- Saptanmış olarak açık
- Ayarlar: Genel › Ağ › Vekil Sunucu

<a id="feature-apple-music-lyrics"></a>

### Apple Music’in kendi şarkı sözleri

Apple Music’in kendi şarkı sözlerini kullanmak için Apple Music hesabınızı Şarkı Sözü Kaynakları bölümünde bağlayın; bu sözlerin çoğu kelime kelime zamanlanmıştır. Apple Music aboneliği gerekir.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözleri › Kaynak › Şarkı Sözü Kaynakları

<a id="feature-matching"></a>

### Akıllı eşleştirme

Saptanmış olarak her sonuç parça adı, sanatçı, süre ve sürüme (canlı, enstrümantal vb.) göre puanlanır ve çalan parçaya en iyi uyan seçilir. Bunun yerine kaynak sırasına geçebilirsiniz: puanlama yapılmaz, sıranızda şarkı sözü olan ilk kaynak kullanılır.

- Ayarlar: Şarkı Sözleri › Kaynak › Eşleştirme Algoritması

<a id="feature-auto-upgrade"></a>

### Eşleştirme iyileşince şarkı sözlerini yeniden seçme

Yeni bir sürüm eşleştirmeyi veya puanlamayı iyileştirdiğinde, mevcut şarkı sözleriniz arka planda yeniden denetlenir ve daha iyisi bulunursa değiştirilir. Bir kez seçilen şarkı sözlerini korumak için bunu kapatın.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözleri › Kaynak › Algoritma Güncellenince Yeniden Seç

<a id="feature-prefetch"></a>

### Sonraki parçanın sözleri önceden hazır

Çalarınızın çalma sırasını okur ve sıradaki birkaç parçanın şarkı sözlerini önceden bulur; okunacak bir sıra yoksa albümün geri kalanını sırayla işler. QQ Music, NetEase Cloud Music, Kugou, Kuwo, Soda Music ve VOX’ta bu özellik Tam Disk Erişimi gerektirir.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözleri › Kaynak › Sıradaki Parçaları Önceden Çözümle
- Ayarlar: Çalar › İzinler ve Hizmetler › Tam Disk Erişimi

<a id="feature-player-local-lyrics"></a>

### Çalarınızın kaydettiği şarkı sözlerini kullanma

Apple Music, Spotify, Kugou, Kuwo, KKBOX, Amazon Music ve LX Music’in bu Mac’e zaten kaydettiği şarkı sözleri doğrudan kullanılabilir: çaların gösterdiği sürümün aynısı, üstelik daha hızlı (Apple Music ve Spotify’da yalnızca çaların sözlerini gösterdiği parçalar için). QQ Music ve NetEase Cloud Music’te parça, çaların yerel arşivinden tanınır; böylece tam o sürüm arama yapılmadan alınır. reAMP, VOX, Pine Player, foobar2000, Cog, Swinsian, MyGo Music ve Audirvana’da, ayrıca Apple Music veya LX Music arşivinizden ya da yerel listenizden yerel bir dosya çaldığında, çalan dosyanın içindeki şarkı sözleri veya aynı adlı .lrc dosyası kullanılır. QQ Music, Kuwo, NetEase Cloud Music ve Kugou için Sistem Ayarları’nda Lyrimuse’a Tam Disk Erişimi verilmesi gerekir; verilmezse şarkı sözleri yine çevrimiçi bulunur.

- Saptanmış olarak kapalı
- Ayarlar: Çalar › İzinler ve Hizmetler › Tam Disk Erişimi

<a id="feature-prefer-local-file-lyrics"></a>

### Parça dosyasındaki şarkı sözlerine öncelik verme

Çalan parça bu Mac’teki bir dosyaysa, çevrimiçi bulunan şarkı sözleriyle karşılaştırılmak yerine önce aynı adlı .lrc dosyası veya dosyaya gömülü şarkı sözleri kullanılır. Yerel dosya çalan her çalarla çalışır. Bu sözler bu sürüme uymuyorsa (örneğin süre tutmuyorsa) şarkı sözleri her zamanki gibi çevrimiçi bulunur.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözleri › Kaynak › Parça Dosyasındaki Sözleri Tercih Et

<a id="feature-lyrics-writeback"></a>

### Şarkı sözlerini parça dosyalarına yazma

Yerel bir MP3, M4A, FLAC, OGG, Opus, WAV veya AIFF dosyası çalarken Şarkı Sözü Yöneticisi’nin ⋯ menüsü parçanın şarkı sözlerini dosyaya yazabilir; böylece diğer çalarlar da bunları gösterebilir. Dosya ancak bir kopyası yazılıp denetlendikten sonra değiştirilir, bu yüzden dosyayı okuyan bir çalar etkilenmez. Apple Music parçalarına şarkı sözleri zaman damgası olmadan yazılır. Deneysel bölümündeki seçenek açıkken şarkı sözleri kesinleşince otomatik olarak yazılır. Diğer uygulamaların yazdığı şarkı sözlerine, üzerine yazmayı da açmadığınız sürece dokunulmaz; bu seçenek önce onları yedekler.

- Saptanmış olarak kapalı
- Ayarlar: Deneysel › Parça Dosyalarına Otomatik Yaz
- Ayarlar: Deneysel › Diğer Uygulamaların Yazdığı Sözlerin Üzerine Yaz

<a id="feature-lock-hand-picked"></a>

### Elle seçilen şarkı sözlerini kilitleme

Açıkken arama sonuçlarından elle seçtiğiniz şarkı sözleri kilitlenir; sonraki otomatik eşleştirme ve yeniden eşleştirme bunları hiçbir zaman değiştirmez.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözleri › Kaynak › Elle Seçilen Sözleri Kilitle

<a id="feature-lyrics-manager"></a>

### Şarkı Sözü Yöneticisi

Herhangi bir parçanın şarkı sözlerine göz atın, düzenleyin, silin veya yeniden arayın; toplu silin ve reklamlarla podcast’lerin geride bıraktığı boş kayıtları temizleyin. Tek bir parçaya kendi zaman kaydırmasını verin. Henüz şarkı sözü olmayan tüm parçaları tek seferde yeniden deneyin ya da tüm arşivi geçerli kurallara göre yeniden eşleştirin; parçalar arasındaki bekleme süresi ayarlanabilir. Elle düzenlediğiniz hiçbir şeye dokunulmaz.

- Ayarlar: Şarkı Sözleri › Şarkı Sözü Arşivi › Şarkı Sözü Arşivi
- Ayarlar: Şarkı Sözleri › Şarkı Sözü Arşivi › Eksik Sözleri Otomatik Eşleştir
- Ayarlar: Şarkı Sözleri › Şarkı Sözü Arşivi › Tüm Arşivi Yeniden Eşleştir
- Ayarlar: Klavye Kestirmeleri › Şarkı Sözü Yöneticisini Aç
- Ayarlar: Şarkı Sözleri › Şarkı Sözü Arşivi › Tarama Aralığı

<a id="feature-song-entries"></a>

### Aynı parçanın kayıtları

Farklı çalarlarda veya farklı albüm sürümlerinden çalınan aynı parça tek parça olarak tanınır: kayıtları tek bir şarkı sözü setini paylaşır, elle yapılan düzenlemeler ve zamanlama düzeltmeleri aktarılır, dinleme sayıları toplanır. Şarkı Sözü Yöneticisi’nde “Bu Parçanın Kayıtları” her kaydın şarkı sözlerini satır satır karşılaştırır; yanlışlıkla eşleşen bir kayıt ayrılabilir ve daha sonra yeniden birleştirilebilir. Her kaydın kendi başına eşleştirilmesi için paylaşımı kapatın.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözleri › Kaynak › Aynı Parçada Sözleri Paylaş

<a id="feature-fix-lyrics"></a>

### Şarkı sözlerini anında değiştirme veya düzeltme

Şarkı sözü penceresinin ⋯ menüsünden başka şarkı sözleri arayın, eşleştirmeyi yeniden çalıştırın veya sözleri kendi metin düzenleyicinizde düzenleyin. Kelime zamanlamalı şarkı sözlerini düzenlemek yalnızca kelimeleri değiştirir, zamanlamalarını hiçbir zaman değiştirmez.

- Ayarlar: Klavye Kestirmeleri › Şarkı Sözü Ara

<a id="feature-import-lyrics"></a>

### Kendi şarkı sözü dosyalarınızı içe aktarma

LRC, Enhanced LRC, TTML, QRC, KRC, YRC veya düz metin şarkı sözlerini tek bir parça için ya da bütün bir klasör hâlinde tek seferde içe aktarın: dosyalar arşivinizdeki parçalarla eşleştirilir ve hiçbir şey yazılmadan önce bir önizlemede gösterilir. İçe aktarılan şarkı sözlerinin mevcut sözlerin yerine mi geçeceğini, yerine geçip kilitleneceğini mi, yoksa yalnızca şarkı sözü olmayan parçaları mı dolduracağını seçin. Henüz çalmadığınız parçaların dosyaları saklanır ve parça ilk kez çalındığında kullanılır. İzlenen bir klasör yeni dosyaları otomatik olarak içe aktarır.

- Ayarlar: Şarkı Sözleri › Şarkı Sözü Arşivi › Şarkı Sözü Klasörü İçe Aktar
- Ayarlar: Şarkı Sözleri › Şarkı Sözü Arşivi › Klasörden İçe Aktarma
- Ayarlar: Şarkı Sözleri › Şarkı Sözü Arşivi › İzlenen Klasör
- Ayarlar: Şarkı Sözleri › Şarkı Sözü Arşivi › İçe Aktarma Arşivi

<a id="feature-offline"></a>

### Çevrimdışı çalışır; şarkı sözleri düz .lrc dosyalarıdır

Bulunan her şarkı sözü Mac’inizde önbelleğe alınır ve bağlantı olmadan da gösterilir. Her parçanın bir .lrc dosyası, çeviri ve telaffuz için de .tr.lrc ve .roma.lrc dosyaları vardır. Kelime zamanlaması saptanmış olarak TTML biçiminde, isterseniz .yrc, Enhanced LRC, QRC veya KRC olarak kaydedilir. Dosyalar saptanmış olarak ~/Library/Application Support/me.yudaotor.lyrimuse/lyrics/ klasöründe durur ve klasör taşınabilir.

- Ayarlar: Şarkı Sözleri › Şarkı Sözü Arşivi › Şarkı Sözü Klasörü
- Ayarlar: Şarkı Sözleri › Şarkı Sözü Arşivi › Kelime Kelime Söz Biçimi

<a id="section-text"></a>

## Çeviri, telaffuz ve satır düzeni

<a id="feature-translation"></a>

### Çeviriler

Şarkı sözleriyle birlikte gelen çeviriler her satırın altında görünür. NetEase Cloud Music, QQ Music ve Kugou’nun çevirileri Çincedir; makine çevirisi ise 17 dil arasından seçtiğiniz çeviri diline göre yapılır. Yüzen sözlerde, şarkı sözü penceresinde, çentikte, menü çubuğunda ve Touch Bar’da çevirinin gösterilip gösterilmeyeceği ayrı ayrı seçilir. Mac’inizin dilleri arasında Çince varsa saptanmış olarak gösterilir.

- Ayarlar: Şarkı Sözleri › Dil › Çeviri Dili
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › İçerik › Çeviri
- Ayarlar: Klavye Kestirmeleri › Çeviriyi Göster/Gizle

<a id="feature-machine-translation"></a>

### Çeviri yoksa makine çevirisi

Hiçbir kaynakta çeviri yoksa şarkı sözleri makineyle çevrilir. macOS 15 veya sonraki sürümlerde dil indirilmişse çeviriyi Apple Translation Mac’inizde yapar ve şarkı sözleri Mac’inizden çıkmaz; aksi takdirde çevrilecek satırlar önce Google Çeviri’ye, ardından MyMemory’ye gönderilir. Çeviri dilleri aynı karttan indirilir.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözleri › Dil › Çeviri Yoksa Otomatik Çevir
- Ayarlar: Şarkı Sözleri › Dil › Çeviri Dilleri

<a id="feature-romanization"></a>

### Telaffuz

Japonca romaji, Korece Latin harfleriyle yazım, Mandarin Çincesi için pinyin ve Kantonca Jyutping, şarkı sözlerinin üstünde kelime kelime; ayrıca Rusça, Tayca, Yunanca ve Hintçe gibi 18 dil daha, her dilin resmî sistemine veya bir ISO standardına göre. Dil satır satır belirlenir, bu yüzden Çince bir parçanın içindeki Japonca bir satır, işaretlenen tek satır olur. Hangi dillerin işaretleneceğini burada seçin; arayüz Çinceyse pinyin başta kapalıdır. Telaffuzun gösterilip gösterilmeyeceği her görünümde ayrı seçilir.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözleri › Dil › Telaffuz Dilleri
- Ayarlar: Şarkı Sözleri › Dil › Japonca Telaffuz
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › İçerik › Telaffuz
- Ayarlar: Klavye Kestirmeleri › Telaffuzu Göster/Gizle

<a id="feature-chinese-script"></a>

### Basitleştirilmiş veya Geleneksel Çince

Uygulamanın kendi dili ne olursa olsun, tüm Çince şarkı sözlerini Basitleştirilmiş veya Geleneksel karakterlerle gösterir.

- Ayarlar: Şarkı Sözleri › Dil › Çince Yazı Biçimi

<a id="feature-split-join-lines"></a>

### Uzun satırları bölme, kısa satırları birleştirme

Yüzen sözler, çentik, menü çubuğu ve Touch Bar, genişliklerine sığmayacak kadar uzun satırları böler ve çok hızlı geçen satırları birleştirir; her biri kendi genişliğine göre. Şarkı sözü penceresi her satırı tek satır olarak tutar. Bölme ve birleştirme ayrı ayrı açılıp kapatılır.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözleri › Zamanlama ve Satır Bölme › Uzun Satırları Böl
- Ayarlar: Şarkı Sözleri › Zamanlama ve Satır Bölme › Kısa Satırları Birleştir

<a id="feature-timing-offset"></a>

### Zaman kaydırma

Tüm şarkı sözlerini daha erken veya daha geç gösterin; isterseniz yalnızca bir çalar için. Tek tek parçalara Şarkı Sözü Yöneticisi’nde kendi kaydırmaları verilir; klavye kestirmeleri de kaydırmayı anında öne alabilir, geciktirebilir veya sıfırlayabilir.

- Ayarlar: Şarkı Sözleri › Zamanlama ve Satır Bölme › Zamanlama Kaydırması
- Ayarlar: Klavye Kestirmeleri › Sözleri Öne Al
- Ayarlar: Klavye Kestirmeleri › Sözleri Geciktir
- Ayarlar: Klavye Kestirmeleri › Şarkı Sözü Kaydırmasını Sıfırla

<a id="section-display"></a>

## Şarkı sözleri nerede ve nasıl görünür

<a id="feature-floating-lyrics"></a>

### Masaüstünde yüzen sözler

Tüm pencerelerin üstünde, her zaman en önde duran ve kelime kelime vurgulanan şarkı sözleri. Sürüklediğiniz yerde bırakın ya da ekranın üst ortasına veya Dock’un hemen üstüne sabitleyin. Birden fazla ekran varsa tek bir ekranda kalabilir veya kullandığınız pencerenin bulunduğu ekranı izleyebilir. Telaffuz, çeviri ve sonraki satır da birlikte gösterilebilir.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Yüzen Sözler
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Konum
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › İçerik › Sonraki Satır
- Ayarlar: Klavye Kestirmeleri › Yüzen Sözleri Göster/Gizle
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Konum › Gösterim Yeri

<a id="feature-notch-lyrics"></a>

### Çentik sözleri

Ekranın üstünde, çentiğin yanında Dynamic Island tarzında bir kapsül; çentiği olmayan Mac’lerde ve harici ekranlarda da çıkar. Her iki yanda parça adı, sanatçı, albüm, kapak, oynatma denetimleri veya geçen ya da kalan süre, hareketli bir ses dalgasının yanında gösterilebilir. Denetimler, sürüklenebilir ilerleme çubuğu, şarkı sözü zamanlaması ve beğenme, şarkı sözü arama gibi hızlı düğmeler için üzerine gelerek genişletin. Reklamlar sırasında kalan süreyi geri sayar.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Çentik Sözleri
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Stil
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Ekran
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Sol Kulak
- Ayarlar: Klavye Kestirmeleri › Çentik Sözlerini Göster/Gizle
- Ayarlar: Klavye Kestirmeleri › Çentiği Geçici Olarak Genişlet
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Genişletildiğinde › Hızlı Eylemler

<a id="feature-menu-bar-lyrics"></a>

### Menü çubuğu sözleri

Geçerli satır doğrudan menü çubuğunda; çok uzunsa kesilmek yerine kayar. Sonraki satır, çeviri veya telaffuz için ikinci bir satır ekleyin. Menü çubuğunun ortasında, çentiği olan ekranlarda çentiğin hemen yanında da durabilir ya da yalnızca parça adını, sanatçıyla veya sanatçısız gösterebilir.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Menü Çubuğu › Menü Çubuğu Sözleri
- Ayarlar: Şarkı Sözü Görünümü › Menü Çubuğu › Yerleşim › Söz Konumu
- Ayarlar: Şarkı Sözü Görünümü › Menü Çubuğu › İçerik › Gösterilenler
- Ayarlar: Şarkı Sözü Görünümü › Menü Çubuğu › İçerik › İkinci Satır
- Ayarlar: Klavye Kestirmeleri › Menü Çubuğu Sözlerini Göster/Gizle

<a id="feature-touch-bar-lyrics"></a>

### Touch Bar sözleri

Touch Bar’lı bir MacBook Pro’da geçerli satır söylendikçe kayar; isterseniz kapak ve oynatma denetimleri de gösterilir. Şarkı sözleri beyaz olabilir, kapağa göre renklenebilir, kendi renginizi kullanabilir veya gökkuşağı gibi akabilir; henüz söylenmemiş kısmın parlaklığı ayarlanabilir. Çalma başlayınca genişleyip duraklatılınca katlanabilir; “Daha Fazla” düğmesi zamanlama, beğenme, karıştırma ve yineleme, ses yüksekliği ve bir ilerleme kaydırıcısı getirir.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Touch Bar › Touch Bar Sözleri
- Ayarlar: Klavye Kestirmeleri › Touch Bar Sözlerini Genişlet/Daralt
- Ayarlar: Şarkı Sözü Görünümü › Touch Bar › Renk › Metin Rengi
- Ayarlar: Şarkı Sözü Görünümü › Touch Bar › Davranış › Çalma Başlayınca Genişlet
- Ayarlar: Şarkı Sözü Görünümü › Touch Bar › Yerleşim › “Daha Fazla” Düğmesini Göster

<a id="feature-touch-bar-collapse-while-typing"></a>

### Yazarken Touch Bar kenara çekilir

İmleç bir metin alanındayken Touch Bar sözleri daralabilir; böylece giriş yöntemi adayları ve yazma önerileri görünür, alandan çıkınca yeniden genişler. Erişilebilirlik izni gerekir.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Touch Bar › Davranış › Yazarken Daralt

<a id="feature-lyrics-window"></a>

### Şarkı sözü penceresi

Apple Music’in şarkı sözü görünümünden esinlenen tam sayfa şarkı sözleri: arkada bulanık kapak, geçerli satıra kayan parçanın tamamı, şarkıcılara göre ayrılan düetler, kendi satırında arka vokaller, uzatılan notalarda büyüyüp parlayan sözler. Arka plan kapağa göre olabilir ya da düz renk, gradyan veya buzlu cam; metin kalınlığı ve boyutu, söylenmiş kısmın rengi, hizalama, satır aralığı ile diğer satırların kararması ve bulanıklığı değiştirilebilir. Telaffuz ve çeviri için ayrı font, kalınlık ve renk seçilebilir. Menü çubuğu simgesinden veya bir kestirmeyle açın.

- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Şarkı Sözü Penceresi
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Arka Plan › Arka Plan
- Ayarlar: Klavye Kestirmeleri › Şarkı Sözü Penceresini Aç
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Yerleşim › Hizalama
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Yerleşim › Denetim Boyutu
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Font › Yazı Ölçeği
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Yerleşim › Satır Aralığı
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Derinlik › Söylenmemişi Karart
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Derinlik › Söyleneni Karart
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Derinlik › Bulanıklık

<a id="feature-lyrics-window-hdr"></a>

### Şarkı sözü penceresinde HDR vurgusu

HDR ekranlarda, şarkı sözü penceresindeki geçerli satırın söylenmiş kısmı normal beyazın ötesinde parlatılır. Saptanmış olarak kapalıdır ve açıkken daha fazla enerji kullanır. Yalnızca tam boyutta.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Renk › HDR Vurgusu

<a id="feature-mini-lyrics-window"></a>

### Mini şarkı sözü penceresi

Küçük bir karta küçültülmüş şarkı sözü penceresi: yalnızca geçerli satır, geçerli ve sonraki satır ya da tam kayan bir sayfa. Arka plan, metin rengi, font, kalınlık, söylenmiş kısmın rengi ve üstteki parça adı, kapak ve süre ayrı ayrı ayarlanır.

- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Yerleşim › Şarkı Sözü Yerleşimi
- Ayarlar: Klavye Kestirmeleri › Mini/Tam Boyuta Geç

<a id="feature-mini-window-auto-hide"></a>

### Mini pencere duraklatıldığında veya tam ekranda gizlenir

Mini pencere, çalma duraklatıldığında veya boştayken kaybolup çalma başlayınca geri gelebilir; bulunduğu ekranda bir uygulama tam ekrandayken (video, oyun) kenara çekilebilir. Her birinin ayrı anahtarı var.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Davranış › Duraklatınca Gizle
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Davranış › Tam Ekranda Gizle

<a id="feature-animated-artwork"></a>

### Hareketli kapak

Apple Music, QQ Music veya NetEase Cloud Music’te hareketli kapağı olan albümler tam boyutlu şarkı sözü penceresinde de hareket eder; Kugou Music’te çaldığınızda hareketli kapağını Kugou Music’in kaydettiği albümler de öyle. Düşük Güç Modu’nda veya “Hareketi Azalt” açıkken duraklar. İndirilen animasyonların ne kadar yer kapladığını görüp bunları temizleyebilirsiniz. Kaynaklar birlikte seçilebilir: Apple Music ve diğer platformlar.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Kapak › Hareketli Kapak
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Kapak › Kaynak
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Kapak › Hareketli Kapak Önbelleği

<a id="feature-spotify-canvas"></a>

### Spotify Canvas arka planı

Bir parçanın Spotify’da döngüsel bir Canvas videosu varsa tam boyutlu şarkı sözü penceresi, bulanık kapak yerine bu videoyu arka plan olarak oynatır. Yalnızca Spotify’ın bu Mac’e zaten kaydettiği videolar kullanılır; bu yüzden Spotify’da çaldığınız parçalar başka bir çalarda çalındığında da videoyla görünür. Düşük Güç Modu’nda veya “Hareketi Azalt” açıkken duraklar.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Arka Plan › Spotify Canvas

<a id="feature-idle-overview"></a>

### Parçalar arasında dinleme özeti

Hiçbir şey çalmıyorken şarkı sözü penceresi son parçayı, sözlerinden bir satırla ve “Sürdür” düğmesiyle gösterir. Last.fm bağlıysa bugün, son 7 günde ve toplamda ne kadar dinlediğinizi, 30 günlük eğilimi, “Geçmişte Bugün” bölümünü ve kapaklarıyla son dinlediklerinizi de gösterir.

<a id="feature-look"></a>

### Görünüş

Font (sistemin ya da kendi .ttf / .otf dosyanız), boyut, kalınlık, metin ve arka plan renkleri, metin opaklığı, kontur ve buzlu cam. Yüzen sözler renk temalarıyla gelir ve kendi temalarınızı kaydedebilirsiniz; metin rengi albüm kapağına göre ayarlanabilir, yüzen sözler, çentik, menü çubuğu ve Touch Bar ayrıca gökkuşağı gibi akabilir. Kestirmelerle ya da ⌘ basılıyken sözlerin üzerinde kaydırarak (fare tekerleği veya iki parmakla kaydırma) yüzen sözler anında büyütülüp küçültülebilir.

- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Tema
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Tema › Temalarım
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Şarkı Sözü Satırı › Şarkı Sözü Rengi
- Ayarlar: Şarkı Sözü Görünümü › Menü Çubuğu › Renk › Gökkuşağı
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Font › Font
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Renk › Buzlu Cam Arka Plan
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Renk › Metin Opaklığı
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Renk › Kontur Kalınlığı
- Ayarlar: Klavye Kestirmeleri › Yüzen Sözlerin Puntosunu Büyüt
- Ayarlar: Klavye Kestirmeleri › Yüzen Sözlerin Puntosunu Küçült

<a id="feature-karaoke"></a>

### Kelime kelime karaoke dolgusu

Her kelime söylendikçe vurgulanır. Yüzen sözler, çentik, menü çubuğu, Touch Bar ve şarkı sözü penceresinin her iki boyutu için ayrı anahtar var; kapalıyken satırın tamamı bir anda vurgulanır.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Renk › Karaoke Efekti
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Şarkı Sözü Satırı › Karaoke Efekti
- Ayarlar: Şarkı Sözü Görünümü › Menü Çubuğu › Renk › Karaoke Efekti
- Ayarlar: Şarkı Sözü Görünümü › Touch Bar › Renk › Karaoke Efekti
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Renk › Karaoke Efekti

<a id="feature-line-transition"></a>

### Satır geçişi

Yüzen sözler sonraki satıra geçerken eski satır yerinde değişmek yerine yukarı kayar ve yenisi onu izler.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Yerleşim › Satır Geçişi

<a id="feature-alternate-next-line"></a>

### Dönüşümlü iki satırlı yerleşim

Yüzen sözler sonraki satırı da tam boyutta gösterebilir: biri solda biri sağda, klasik masaüstü karaoke sözleri gibi sırayla. Az önce söylenen satırın yerine iki sonraki satır gelir, söylenmekte olan satır yerinde kalır.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › İçerik › Sonraki Satır Yerleşimi

<a id="feature-fade-on-hover"></a>

### İşaretçi üzerindeyken soluklaşma

İşaretçi üzerindeyken yüzen sözler saydamlaşır, böylece altındakileri hiçbir zaman kapatmaz. Mini şarkı sözü penceresinin kendi anahtarı var ve soluklaşmışken tıklamaları alttaki pencereye de geçirebilir; mini pencereyi kullanmak için ⌥ tuşunu basılı tutun.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Üzerine Gelince Soldur
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Davranış › Üzerine Gelince Soldur
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Davranış › Soluklaşınca Tıklamaları Geçir

<a id="feature-lock-position"></a>

### Konumu kilitleme, sürüklemek için uzun basma

Yüzen sözleri yerine kilitleyin ya da sürüklemeden önce uzun basmayı zorunlu kılın; böylece yanlışlıkla hiç kaymaz.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Konumu Kilitle
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Basılı Tutup Sürükle
- Ayarlar: Klavye Kestirmeleri › Konumu Kilitle/Kilidi Aç

<a id="feature-hover-controls"></a>

### Üzerine gelince denetimler

Yüzen sözlerin üzerine gelince bir sıra hızlı düğme belirir. Menü çubuğu sözleri de üzerine gelince oynatma denetimlerini gösterebilir.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Üzerine Gelince Denetimleri Göster
- Ayarlar: Şarkı Sözü Görünümü › Menü Çubuğu › Davranış › Üzerine Gelince Denetimleri Göster

<a id="feature-hide-in-screenshots"></a>

### Ekran görüntülerinde ve ekran paylaşımında gizli

Siz şarkı sözlerini görmeye devam ederken ekran görüntüleri, kayıtlar ve paylaşılan ekranlar onları içermez. Yüzen sözlerin, çentiğin ve mini şarkı sözü penceresinin ayrı birer anahtarı var.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Ekran Resimlerinde Gizle
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Davranış › Ekran Resimlerinde Gizle
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Davranış › Ekran Resimlerinde Gizle

<a id="feature-hide-when-paused"></a>

### Duraklatınca gizleme veya küçültme

Çalma duraklatıldığında veya boştayken yüzen sözler ve çentik kaybolur; çentik bunun yerine çentik boyutuna küçülebilir.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Duraklatınca Gizle
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Davranış › Duraklatınca Gizle
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Davranış › Duraklatınca Daralt

<a id="feature-hide-when-no-lyrics"></a>

### Enstrümantallerde ve sözsüz parçalarda gizleme

Parça enstrümantalse ya da arama bitip şarkı sözü bulunamadıysa yüzen sözler ve mini şarkı sözü penceresi gizlenebilir, çentik ve Touch Bar da şarkı sözü satırını katlayabilir. Arama sürerken hiçbir şey gizlenmez. Her birinin ayrı anahtarı var.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Söz Yoksa Gizle
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Davranış › Söz Yoksa Gizle
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Davranış › Söz Yoksa Satırı Daralt
- Ayarlar: Şarkı Sözü Görünümü › Touch Bar › Davranış › Söz Yoksa Daralt

<a id="feature-title-when-no-lyrics"></a>

### Şarkı sözü yokken şarkı adı

Parça enstrümantalse ya da arama şarkı sözü bulamazsa yüzen sözler, durum mesajı yerine şarkı adını ve sanatçıyı gösterir. Menü çubuğu, şarkı sözü yokken ya da arama sürerken şarkı adını gösterir. Her birinin ayrı anahtarı var; menü çubuğununki varsayılan olarak açık.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Şarkı Sözü Yoksa Parça Adını Göster
- Ayarlar: Şarkı Sözü Görünümü › Menü Çubuğu › Davranış › Şarkı Sözü Yoksa Parça Adını Göster

<a id="feature-hide-during-ads"></a>

### Reklamlarda kenara çekilme

Çalar reklam çalarken yüzen sözler ve mini şarkı sözü penceresi gizlenebilir, çentik de üst şeridine küçülebilir; çentiğin üzerine gelince yine genişler. Her birinin ayrı anahtarı var.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Reklamlarda Gizle
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Davranış › Reklamlarda Daralt
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Davranış › Reklamlarda Gizle

<a id="feature-hide-in-full-screen"></a>

### Tam ekranda çentik kenara çekilir

Video, oyun veya herhangi bir uygulama tam ekrandayken çentik sözleri gizlenir.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Davranış › Tam Ekranda Gizle

<a id="feature-notch-show-on-lock-screen"></a>

### Kilitli ekranda çentik

Çentik, kilitli ekranda da çalan parçayı ve şarkı sözlerini göstermeye devam eder.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Davranış › Kilitli Ekranda Göster

<a id="feature-overlay-hide-in-full-screen"></a>

### Tam ekranda yüzen sözler kenara çekilir

Yüzen sözler normalde tam ekran uygulamaların üstünde kalır. Bunu açarsanız video, oyun veya herhangi bir uygulama tam ekrandayken gizlenir, tam ekrandan çıkınca geri gelir.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › Davranış › Tam Ekranda Gizle

<a id="feature-title-on-change"></a>

### Parça değişince başlık belirir

Her yeni parçanın adı ve sanatçısı kısa bir süre çentikten kayarak çıkar, sonra geri girer.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Davranış › Parça Değişince Adını Göster

<a id="feature-listening-milestones"></a>

### Dinleme dönüm noktaları

Bir parça 100., 1.000. veya 10.000. dinlemesine ulaştığında ya da Last.fm toplamınız bir dönüm noktasını geçtiğinde çentik kutlamak için açılır. Last.fm bağlı olmalıdır.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Davranış › Dinleme Dönüm Noktaları

<a id="feature-notch-gestures"></a>

### Çentikte izleme dörtgeni hareketleri

İşaretçi çentiğin üzerindeyken parça değiştirmek için iki parmakla sola veya sağa, sistem ses yüksekliğini ayarlamak için yukarı veya aşağı kaydırın.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Davranış › İzleme Dörtgeni Hareketleri
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Davranış › Ses Tuşlarında Göster

<a id="feature-notch-lyric-row-fade"></a>

### Üzerine gelince çentikteki şarkı sözü satırını soldurma

İşaretçi çentiğin şarkı sözü satırındayken satır genişlemek yerine soluklaşır ve tıklamalar alttaki pencereye geçer; çentik yalnızca çentiğin kendisinden veya yanlarından genişler.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Şarkı Sözü Satırı › Üzerine Gelince Soldur

<a id="feature-notch-multiline-lyrics"></a>

### Genişletilmiş çentikte çok satırlı şarkı sözleri

Çentik işaretçinin altında genişlediğinde şarkı sözü alanı 3, 5 veya 7 satırlık bir listeye dönüşür; geçerli satır kelime kelime vurgulanır ve liste her yeni satırda yukarı kayar. Bir satıra atlamak için onu tıklayın. Şarkı sözü satırı kapalıysa çentik ince bir durum şeridi olarak kalır ve şarkı sözlerini yalnızca genişlediğinde gösterir.

- Saptanmış olarak açık
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Genişletildiğinde › Çok Satırlı Sözler
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Genişletildiğinde › Satır Sayısı

<a id="feature-notch-wave-follows-music"></a>

### Müziği izleyen ses dalgası

Çentikteki ses dalgası, çaların gerçekten çaldığı sesle birlikte hareket eder ve bas seslerden tiz seslere beş banda ayrılır (macOS 14.2 veya sonrası). Lyrimuse yalnızca ses düzeyini okur ve hiçbir sesi kaydetmez; macOS sistem sesini kaydetme izni için bir kez sorar. Bu Mac’te çalmayan müzikte, örneğin iPhone’da çalınanlarda, dalga şarkı sözlerine göre zamanlanmaya devam eder.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Çentik › Sol Kulak › Müzikle Hareket Et

<a id="feature-web-lyrics"></a>

### Tarayıcıda şarkı sözleri: ikinci ekran olarak telefon veya tablet ya da OBS tarayıcı kaynağı

Web tarayıcısında şarkı sözleri. “Tarayıcıda Şarkı Sözleri” şarkı sözü penceresinin gösterdiğinin aynısını gösterir; “OBS Çıkışı” saydam arka planlıdır, yüzen sözlerle aynı font ve renkleri kullanır ve sol üst köşede her zaman, parça değişince ya da hiç gösterilmeyecek şekilde ayarlanabilen bir başlık kartı (parça adı, sanatçı ve kapak) içerir. Her birinin kendi bağlantı noktası ve yerel ağ ayarı var. “Yerel Ağ Erişimine İzin Ver” seçeneğini açana kadar ikisi de yalnızca bu Mac’te kullanılabilir; açınca aynı ağdaki aygıtlar bir QR kodu okutarak, erişim anahtarı içeren bir bağlantıyla bağlanabilir. “Uzaktan Denetime İzin Ver” açıkken sayfa çalmayı da denetleyebilir ve bir satıra atlayabilir.

- Saptanmış olarak kapalı
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Tarayıcıda Şarkı Sözleri
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Tarayıcıda Şarkı Sözleri › Yerel Ağ Erişimine İzin Ver
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › OBS › OBS Çıkışı
- Ayarlar: Şarkı Sözü Görünümü › Yüzen Sözler › OBS › Başlık Kartı
- Ayarlar: Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Tarayıcıda Şarkı Sözleri › Uzaktan Denetime İzin Ver

<a id="section-players"></a>

## Çalarlar ve çalma

<a id="feature-players"></a>

### 22 çalar; birkaçını seçin veya otomatik algılayın

Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Kuwo, Soda Music, LX Music, KKBOX, Amazon Music, Winamp tarzı reAMP, kayıpsız ve yüksek çözünürlüklü yerel çalar VOX, neredeyse her biçimi çalan ücretsiz yerel çalar Pine Player, Windows’tan taşınan klasik yerel çalar foobar2000, chiptune ve tracker biçimlerini de çalan açık kaynaklı yerel çalar Cog, büyük arşivler için yapılmış yerel çalar Swinsian, Plex’in kendi sunucunuz için müzik çaları Plexamp, yerel dosyaları çalan ve eklentilerle başka kaynaklar ekleyen açık kaynaklı MyGo Music, odyofillere yönelik yüksek çözünürlüklü çalar Audirvana, YouTube Music uygulaması Kaset, açık kaynaklı YouTube Music masaüstü uygulaması Pear Desktop ve sesli kitaplar için WeRead. Aynı anda birkaçını seçin ya da macOS’in Şu An Çalınan olarak gösterdiğini izlemesi için otomatikte bırakın. Apple Music radyosu da çalışır; program sunucusu konuşurken istasyon adını ve logosunu gösterir.

- Ayarlar: Çalar › Müzik Uygulamaları

<a id="feature-web-players"></a>

### Tarayıcınızda YouTube Music ve Spotify Web

Tarayıcınızı bir kez eşleyin; içinde çalan müzik de sayfanın kendi ilerlemesini izleyerek şarkı sözü alır. Tek tıklamalı bir denetim, o tarayıcının denetlenip denetlenemeyeceğini önceden söyler. Reklamlar sırasında çentik kalan süreyi ve kaçıncı reklam olduğunu gösterir.

- Saptanmış olarak kapalı
- Ayarlar: Çalar › Web

<a id="feature-skip-youtube-ads"></a>

### YouTube Music reklamlarını otomatik atlama

Tarayıcınızdaki YouTube Music’te veya Pear Desktop’ta reklamlar, Atla düğmesi belirdiği anda atlanır. Kapalıyken reklamı çentikten kendiniz yine atlayabilirsiniz. Erişilebilirlik izni gerekir.

- Saptanmış olarak kapalı
- Ayarlar: Çalar › Web › YouTube Music Reklamlarını Otomatik Atla
- Ayarlar: Çalar › İzinler ve Hizmetler › Erişilebilirlik

<a id="feature-other-players"></a>

### Başka çalarlar ekleme

Listede olmayan çalarlar Uygulamalar klasöründen güvenilen çalarlarınıza eklenebilir; Lyrimuse tanımadığı bir çaların müzik çaldığını fark edince de sorar.

- Ayarlar: Çalar › Diğer Uygulamalar
- Ayarlar: Çalar › Uygulama Ekle…
- Ayarlar: Çalar › Yeni Çalar Uyarıları

<a id="feature-permissions"></a>

### İzinler, yalnızca gerektiği yerde

Apple Music, Spotify, Kaset, VOX, Swinsian ve Audirvana’da çalanı okumak için Otomasyon izni gerekir. QQ Music, Kuwo, NetEase Cloud Music ve Kugou’da kaydedilmiş şarkı sözleri ve çalma sıraları için, Soda Music, VOX ve Cog’da ise çalma sıraları için Tam Disk Erişimi gerekir; Kuwo bu izni favorileri ve yerel kapakları için de kullanır. Amazon Music, Pine Player ve Cog’da ilerleme kalibrasyonu, Pine Player’ın çalma listesi; QQ Music, Kuwo Music, NetEase Cloud Music, Kugou Music, Soda Music, Amazon Music, reAMP, Pine Player, foobar2000 ve Cog’da karıştırma, yineleme ve beğenme düğmeleri; foobar2000 ve Cog’da ses yüksekliği ve başka bir uygulama Şu An Çalınan’ı tutarken QQ Music, Kuwo Music, NetEase Cloud Music, Soda Music, Pine Player, foobar2000, Cog ve MyGo Music’te çalma düğmeleri için Erişilebilirlik gerekir. Web çalarlar için tarayıcıda Otomasyon izni ve tarayıcının “Apple Olayları’ndan JavaScript’e izin ver” seçeneği gerekir. Diğer çalarlar hiçbir şey gerektirmez. Ayarlar her birinin güncel durumunu gösterir.

- Ayarlar: Çalar › İzinler ve Hizmetler › Otomasyon İzni
- Ayarlar: Çalar › İzinler ve Hizmetler › Tam Disk Erişimi
- Ayarlar: Çalar › İzinler ve Hizmetler › Erişilebilirlik

<a id="feature-controls"></a>

### Oynatma denetimleri ve sarma

Şarkı sözü penceresinden veya genişletilmiş çentikten çalın, duraklatın, parça atlayın ve ilerleme çubuğunu sürükleyin. Karıştırma, yineleme, beğenme ve ses yüksekliği çalara bağlıdır: Apple Music, Spotify, Kaset, QQ Music, Kuwo Music, Amazon Music, reAMP, VOX, Pine Player, foobar2000, Cog, Swinsian, Plexamp, Pear Desktop ve tarayıcıdaki YouTube Music bunların bir kısmını ya da tümünü destekler; NetEase Cloud Music, Kugou Music, Soda Music, LX Music ve MyGo Music’te beğenme vardır, LX Music’te ayrıca kendi ayarlarında Open API açılınca ses yüksekliği de vardır. Çalma, duraklatma, parça atlama ve beğenmeye sistem genelinde klavye kestirmeleri atanabilir. Tarayıcıdaki bir video gibi başka bir şey Şu An Çalınan’ı tutarken QQ Music, Kuwo Music, NetEase Cloud Music, Soda Music, Pine Player, foobar2000, Cog ve MyGo Music’te çalma, duraklatma ve parça atlama bu çalarların kendi menüleri veya çalma çubuğu üzerinden yapılır ve sarma kullanılamaz.

- Ayarlar: Şarkı Sözü Görünümü › Çentik › Genişletildiğinde › Denetimleri Göster
- Ayarlar: Klavye Kestirmeleri › Çal/Duraklat
- Ayarlar: Klavye Kestirmeleri › Sonraki Parça
- Ayarlar: Klavye Kestirmeleri › Önceki Parça
- Ayarlar: Klavye Kestirmeleri › Favorilere Ekle/Çıkar
- Ayarlar: Çalar › İzinler ve Hizmetler › LX Music Open API

<a id="feature-song-pages"></a>

### Parçanın sayfasını tek tıkla açma

⋯ menüsünde tek tıklama, parçayı, albümünü veya sanatçısını çaldığınız platformda açar. Apple Music ve KKBOX kendi uygulamalarında açılır, Spotify da uygulamasında parçaya atlar; diğerleri web’de açılır: Spotify albüm ve sanatçıları, QQ Music, Soda Music, Amazon Music ve YouTube Music. Kuwo, NetEase Cloud Music ve Kugou’da yalnızca parça sayfası vardır.

<a id="feature-about-panels"></a>

### Parça, albüm ve sanatçı bilgileri

Haklarında bilgi almak için şarkı sözü penceresinde veya genişletilmiş çentikte parça adını, sanatçıyı ya da albümü tıklayın. Albüm ve sanatçı bilgileri önce Apple Music’ten gelir; olmazsa Soda Music, Kugou Music ve NetEase Cloud Music’ten (yalnızca Çince arayüzde), ardından YouTube Music üzerinden Wikipedia’dan, sonra Last.fm’den. Parça bilgileri QQ Music’ten (yalnızca Çince arayüzde) veya Last.fm’den gelir. Last.fm için hesabınızın bağlı olması gerekir.

<a id="feature-player-linkage"></a>

### Çalarınızla birlikte açılma ve kapanma

Her çalar için ayrı: Lyrimuse açılınca çaları açma, çalar açılınca Lyrimuse’u açma ya da izlediği tüm çalarlar kapandığında Lyrimuse’dan çıkma.

- Saptanmış olarak kapalı
- Ayarlar: Çalar › Açılış ve Çıkış › Açılışta Çalarları Aç
- Ayarlar: Çalar › Açılış ve Çıkış › Çalarla Birlikte Başlat
- Ayarlar: Çalar › Açılış ve Çıkış › Çalarla Birlikte Çık

<a id="section-listening"></a>

## Skroplama, Last.fm ve paylaşım

<a id="feature-lastfm"></a>

### Last.fm skroplama ve dinleme profili

Last.fm’i tek tıkla bağlayın, kopyalanacak jeton yok. Bugünkü, bu haftaki ve tüm zamanların dinlemelerini, sıralama değişimleriyle sanatçı, albüm ve parça listelerini ve Geçmişe Bakış’ı görün: bir güne tıklayınca o günün en çok çalınan parçalarını listeleyen yıllık ısı haritası, dinleme saatleri, sanatçılarınızın nereden geldiği ve Geçmişte Bugün. Son parçalardan herhangi birini tek tıkla beğenin.

- Saptanmış olarak kapalı
- Ayarlar: Last.fm › Kurallar › Skroplama Kuralları

<a id="feature-scrobble-rules"></a>

### Özel skroplama kuralları

Bir dinlemeyi parçanın %50, %75 veya %90’ı çalınınca ya da yalnızca sonuna kadar çalınınca sayın; 30 saniyeden kısa parçalar için karar verin; saptanmış olarak konuk sanatçılar, Çince yazı varyantları ve “- Single” gibi ekler Last.fm kataloğundaki kayda eşlenir, isterseniz her şeyi olduğu gibi gönderin; herhangi bir çaları Last.fm’in tamamen dışında bırakın.

- Ayarlar: Last.fm › Kurallar › Skroplama Zamanı
- Ayarlar: Last.fm › Kurallar › 30 Saniyeden Kısa Parçaları Skropla
- Ayarlar: Last.fm › Kurallar › Eşleştirme Modu
- Ayarlar: Last.fm › Kurallar › Skroplanacak Çalarlar

<a id="feature-local-log"></a>

### Her dinleme önce yerel olarak kaydedilir

Last.fm bağlı değilken yapılan dinlemeler Mac’inizde kaydedilir; bağlandıktan sonra Last.fm sayfasında “Bekleyen Skroplamalar” altındaki “Sonradan Gönder” düğmesini tıklayın. Bağlıyken Last.fm’e ulaşmamış olabilecek bir dinleme Last.fm’le karşılaştırılır ve otomatik olarak yeniden gönderilir. Last.fm yalnızca yaklaşık son iki haftanın dinlemelerini kabul eder.

<a id="feature-listenbrainz"></a>

### ListenBrainz’e de skroplama

Her dinleme aynı okumadan Last.fm’e ve ListenBrainz’e gider, böylece ikisi tutarlı kalır. iPhone’unuzun Last.fm’e gönderdiği dinlemeler de ListenBrainz’e kopyalanabilir. Kenar çubuğunda Deneysel altında.

- Saptanmış olarak kapalı
- Ayarlar: Deneysel › ListenBrainz › Hesap Bilgileri

<a id="feature-discord"></a>

### Çaldığınızı Discord’da gösterme

Profiliniz ve arkadaş listeniz çaları, parça adını, sanatçıyı, kapağı ve bir ilerleme çubuğunu gösterir; parça adına veya sanatçıya tıklamak çaların web sayfasını açar. Albüm satırı söylenmekte olan satırı gösterebilir ve en fazla iki düğme eklenebilir. Metnin nasıl yerleşeceğini, hangi çalarların sayılacağını, duraklatınca kalıp kalmayacağını ve kapağın üzerinde hangi rozetin duracağını seçin; parçayı adlandırmadan yalnızca çaları gösterin ya da bir süreliğine gizleyin.

- Saptanmış olarak kapalı
- Ayarlar: Discord › Discord’da Göster
- Ayarlar: Discord › Gösterilen Çalarlar
- Ayarlar: Discord › Duraklatınca
- Ayarlar: Discord › Geçici Olarak Gizle
- Ayarlar: Discord › Gösterilenler
- Ayarlar: Discord › Düğmeler
- Ayarlar: Discord › Parça Bilgilerini Gizle

<a id="feature-now-playing-page"></a>

### Ne dinlediğinizi gösteren paylaşılabilir bir web sayfası

Ne çaldığınızı ve geçmişinizi gösteren herkese açık bir sayfa; isteğe bağlı ziyaretçi defteri, tepkiler, ziyaretçi sayısı, en çok dinlenen 10 sanatçı ve plak görünümüyle. Canlı çalma ve geçmiş için ListenBrainz tek başına yeter; geri kalanı için kılavuzdaki adımlarla bir Cloudflare Worker kurun. Deneysel altında.

- Saptanmış olarak kapalı
- Ayarlar: Deneysel › Web Anlık Bildirimleri › Bağlantı Bilgileri

<a id="feature-digests"></a>

### Günlük, haftalık, aylık ve yıllık dinleme raporları

Ayarladığınız kanallara gönderilir, istediğiniz kadar kanal olabilir: Bark, ntfy, ServerChan, Feishu, DingTalk, WeCom, Telegram, Discord, Slack veya genel bir webhook. Her kanalda bildirimin nasıl görüneceği önizlenebilir ve deneme gönderilebilir; gönderim geçmişi her bildirimin ulaşıp ulaşmadığını gösterir, ulaşmayanlar yeniden gönderilebilir. Raporlar önceki dönemle karşılaştırma yapar, ilk kez dinlediğiniz sanatçıları belirtir ve ne kadar süre dinlediğinizi tahmin eder; her platform için albüm kapağı ve tam listenin bağlantısıyla biçimlendirilir. Dört raporun her birinin kendi anahtarı ve birden çok kanal varsa kendi kanal seçimi vardır; gönderim saatini (Mac’in geçerli saat diliminde) ve her listede kaç öğe gösterileceğini siz seçersiniz; her kanal tam, kısa veya özet raporu ya da yer tutuculu kendi başlık ve metninizi kullanabilir.

- Saptanmış olarak kapalı
- Ayarlar: Anlık Bildirimler › Kanallar
- Ayarlar: Anlık Bildirimler › Gönderim Saati
- Ayarlar: Anlık Bildirimler › Dinleme Raporları
- Ayarlar: Anlık Bildirimler › Veri Kaynağı
- Ayarlar: Anlık Bildirimler › Liste Başına Öğe
- Ayarlar: Anlık Bildirimler › Günlük Dinleme Raporu
- Ayarlar: Anlık Bildirimler › Haftalık Dinleme Raporu
- Ayarlar: Anlık Bildirimler › Aylık Dinleme Raporu
- Ayarlar: Anlık Bildirimler › Yıllık Dinleme Raporu
- Ayarlar: Anlık Bildirimler › Gönderim Geçmişi

<a id="section-general"></a>

## Gündelik kullanım

<a id="feature-onboarding"></a>

### İlk açılış kurulumu

Lyrimuse’u ilk açtığınızda çalarları seçme, tarayıcı eşleme ve şarkı sözlerinin nerede görüneceğini seçme adımlarında size yol gösterir; gereken her izni denetler, böylece eksik olanı hemen düzeltebilirsiniz.

<a id="feature-language"></a>

### İngilizce, Basitleştirilmiş ve Geleneksel Çince, Japonca, Korece, İspanyolca, Fransızca, Almanca, İtalyanca, Brezilya Portekizcesi, Vietnamca, Rusça, Ukraynaca, Tayca ve Türkçe

Saptanmış olarak sistem dilinizi izler; sistem diliniz bunlardan biri değilse İngilizce kullanılır. Dil değişikliği yeniden başlatmadan hemen geçerli olur.

- Ayarlar: Genel › Görünüş ve Dil › Dil

<a id="feature-appearance"></a>

### Açık, koyu veya otomatik

Ayarlar, Şarkı Sözü Penceresi, Şarkı Sözü Yöneticisi ve menü çubuğu paneli açık veya koyu kalabilir; saptanmış olarak sistemi izlerler. Yüzen sözler yine sistemi izler, çentik ise her zaman koyudur.

- Ayarlar: Genel › Görünüş ve Dil › Görünüş

<a id="feature-shortcuts"></a>

### Sistem genelinde klavye kestirmeleri

Her tür şarkı sözünü (ya da toplantılar ve ekran paylaşımı için hepsini birden) gösterme veya gizleme, şarkı sözü penceresini ve Şarkı Sözü Yöneticisi’ni açma, arama, zamanlama, çalma, beğenme ve çalara geçme işlemlerinin hepsine kestirme atanabilir. Saptanmış olarak hiçbiri atanmamıştır.

- Ayarlar: Klavye Kestirmeleri › Ayarları Aç
- Ayarlar: Klavye Kestirmeleri › Tüm Sözleri Gizle/Geri Getir
- Ayarlar: Klavye Kestirmeleri › Çalara Geç
- Ayarlar: Klavye Kestirmeleri › Menü Çubuğu Panelini Aç/Kapat

<a id="feature-deep-links"></a>

### Derin bağlantılar (lyrimuse://)

lyrimuse:// bağlantıları Kestirmeler uygulamasından, Raycast, Alfred ve benzeri araçlardan herhangi bir Ayarlar sayfasını, şarkı sözü penceresini veya Şarkı Sözü Yöneticisi’ni açar ve çalma, beğenme ya da tüm şarkı sözlerini gizleme gibi kestirme atanabilen her işlemi çalıştırır. Kestirmeler uygulamasından x-callback-url ile açılan bir bağlantı parça adını, sanatçıyı, albümü ve geçerli satırı da geri gönderebilir. “Klavye Kestirmeleri” sayfasındaki “Derin Bağlantılar” kartı tüm bağlantıları kopyalanmaya hazır olarak listeler.

- Ayarlar: Klavye Kestirmeleri › Derin Bağlantılar

<a id="feature-settings-search"></a>

### Aranabilir ayarlar

Ayarlar kenar çubuğunun üstüne yazarak doğrudan bir ayara atlayın; ayar, daraltılmış bölümlerin içinde olsa bile vurgulanır. İngilizce veya Çince arayın.

<a id="feature-menu-bar-panel"></a>

### Menü çubuğu paneli

macOS Denetim Merkezi’nden esinlenen bir panel için menü çubuğu simgesini tıklayın: kapak, şarkı sözleri, ilerleme ve çalma denetimleri içeren, çalan parçayı gösteren bir kart ve her tür şarkı sözünü ve pencereyi açıp kapatan kutucuklar. Sık kullanılan ayarlarını görmek için bir kutucuğa uzun basın veya sağ tıklayın; kutucuk ters döner. İstediğiniz gibi düzenleyin: taşımak için kutucukları sürükleyin, boyutlandırmak için bir köşeyi sürükleyin, kutucuk ve alt çubuk düğmeleri ekleyin veya kaldırın. Boşluk ve ok tuşları çalmayı denetler ve şarkı sözü zamanlamasında ince ayar yapar; paneli bir kestirme de açabilir.

- Saptanmış olarak açık
- Ayarlar: Klavye Kestirmeleri › Menü Çubuğu Panelini Aç/Kapat

<a id="feature-menu-bar-icon"></a>

### Menü çubuğu simgesi

Üç boyutta 12 simge; çalarken müzikle birlikte hareket eder ya da çalan parçanın albüm kapağını gösterir. Gündelik işlemler simgenin menüsündedir.

- Saptanmış olarak açık
- Ayarlar: Genel › Menü Çubuğu ve Dock › Menü Çubuğu Simgesi
- Ayarlar: Genel › Menü Çubuğu ve Dock › Albüm Kapağı
- Ayarlar: Genel › Menü Çubuğu ve Dock › Simge Boyutu
- Ayarlar: Genel › Menü Çubuğu ve Dock › Simge Animasyonu

<a id="feature-dock-icon"></a>

### Dock’ta göster

Yalnızca menü çubuğu simgesini tutmak için kapatın.

- Saptanmış olarak açık
- Ayarlar: Genel › Menü Çubuğu ve Dock › Dock’ta Göster

<a id="feature-launch-at-login"></a>

### Oturum açıldığında aç

Mac’inizde oturum açtığınızda Lyrimuse’u açar.

- Saptanmış olarak açık
- Ayarlar: Genel › Başlangıç ve Bildirimler › Oturum Açıldığında Aç

<a id="feature-silent-launch"></a>

### Sessizce başlat

Hiçbir pencere açmadan, yalnızca menü çubuğu simgesiyle başlar.

- Saptanmış olarak kapalı
- Ayarlar: Genel › Başlangıç ve Bildirimler › Sessizce Başlat

<a id="feature-song-notifications"></a>

### Parça değişince bildir

Her yeni parça için bir sistem bildirimi.

- Saptanmış olarak kapalı
- Ayarlar: Genel › Başlangıç ve Bildirimler › Parça Değişince Bildir

<a id="feature-backup"></a>

### Ayarları yedekleme, yeni Mac’e taşıma

Tüm ayarlarınızı tek bir dosyaya dışa aktarın; dosya saptanmış olarak iCloud Drive’a ya da seçtiğiniz bir klasöre kaydedilir. Yeni bir Mac Lyrimuse’u ilk açtığında dosyayı iCloud’da bulursa içe aktarmayı önerir.

- Ayarlar: Genel › Yedekleme ve Taşıma › iCloud Yedeği
- Ayarlar: Genel › Yedekleme ve Taşıma › Ayarlar Dosyası

<a id="feature-updates"></a>

### Otomatik güncellemeler ve beta sürümler

Yeni sürümleri kendiliğinden denetler; notları okuyup Yazılım Güncelleme sayfasından yükleyin. Yenilikleri erkenden denemek için “Beta Güncellemeleri” seçeneğini açın.

- Saptanmış olarak kapalı
- Ayarlar: Yazılım Güncelleme › Güncelleme Ayarları › Otomatik Olarak Denetle
- Ayarlar: Yazılım Güncelleme › Güncelleme Ayarları › Otomatik Olarak İndir ve Yükle
- Ayarlar: Yazılım Güncelleme › Güncelleme Ayarları › Beta Güncellemeleri

<a id="feature-diagnostics"></a>

### Tek tıkla tanılar ve hata raporları

Günlükleri, çökme raporlarını ve uygulama durumunu, kimlik bilgileri ve kullanıcı adınız çıkarılmış tek bir dosyada toplar. “Sorun Bildir”, sürümünüzün, macOS sürümünün ve çalarınızın önceden doldurulduğu bir GitHub sorun kaydı açar.

- Ayarlar: Hakkında › Tanılar ve Veriler › Tanıları Dışa Aktar
- Ayarlar: Hakkında › Güncellemeler ve Yardım › Sorun Bildir

<a id="feature-telemetry"></a>

### Kapatılabilen anonim kullanım verileri

Neyin önce düzeltileceğine karar vermek için günde en fazla bir kez sürümü, macOS sürümünü, hangi özelliklerin açık olduğunu ve çökme özetlerini geliştiricinin kendi sunucusuna gönderir. Parça adları, sanatçılar, yerel yollar veya hesaplar asla gönderilmez. Saptanmış olarak açıktır; Ayarlar’da veya karşılama ekranında kapatın.

- Ayarlar: Hakkında › Tanılar ve Veriler › Anonim Kullanım Verilerini Paylaş

<a id="section-all-settings"></a>

## Tüm Ayarlar

Ayarlar penceresindeki tüm ayarlar, konumlarına göre; toplam: 345. Bir ayara hemen gitmek için adını kenar çubuğunun üstündeki arama alanına yazın.

### Şarkı Sözleri › Kaynak

- **Şarkı Sözü Kaynakları**
- **Eşleştirme Algoritması**
- **Parça Dosyasındaki Sözleri Tercih Et**: Yerel bir dosya çalınırken önce aynı adlı .lrc dosyası veya dosyaya gömülü şarkı sözleri kullanılır
- **Algoritma Güncellenince Yeniden Seç**: Arka planda yeniden değerlendirilir; daha uygun bir sürüme geçilebilir
- **Aynı Parçada Sözleri Paylaş**: Aynı ses kaydı için çalarlar ve albüm sürümleri arasında tek kopya kullanılır; elle yapılan değişiklikler de eşzamanlanır
- **Elle Seçilen Sözleri Kilitle**: Elle seçtiğiniz şarkı sözleri otomatik eşleştirmeyle asla değiştirilmez
- **Sıradaki Parçaları Önceden Çözümle**: Sıradaki parçaların şarkı sözlerini önceden alır

### Şarkı Sözleri › Dil

- **Çeviri Dili**
- **Çeviri Yoksa Otomatik Çevir**: Önce bu Mac’te çevirir, bu mümkün değilse çevrimiçi çevirir
- **Çeviri Dilleri**: Aygıt üzerinde çeviri için gereken sistem dilleri
- **Çince Yazı Biçimi**
- **Telaffuz Dilleri**
- **Japonca Telaffuz**: Romaji ya da yalnızca kanjiler için hiragana

### Şarkı Sözleri › Zamanlama ve Satır Bölme

- **Uzun Satırları Böl**: Tek satıra sığmayan satırlar bölünüp parça parça gösterilir
- **Kısa Satırları Birleştir**: Bitişik kısa satırlar tek satıra sığıyorsa birleştirilir
- **Zamanlama Kaydırması**: Pozitif değerler şarkı sözlerini erken, negatif değerler geç gösterir

### Şarkı Sözleri › Şarkı Sözü Arşivi

- **Şarkı Sözü Arşivi**
- **Eksik Sözleri Otomatik Eşleştir**: Yalnızca şarkı sözü olmayan veya yalnızca düz metin sözü olan parçalar
- **Tüm Arşivi Yeniden Eşleştir**: Şarkı sözü olan parçalar da dahil; elle düzenlenmiş, kalibre edilmiş ve enstrümantal olanlar hariç
- **Tarama Aralığı**: Parçalar arasındaki saniye sayısı; hız sınırına takılmamak için en az 2 saniye önerilir
- **Şarkı Sözü Klasörü**: Konum değiştirildiğinde mevcut dosyalar yerinde kalır
- **Kelime Kelime Söz Biçimi**
- **Şarkı Sözü Klasörü İçe Aktar**: Bir klasördeki şarkı sözü dosyalarını arşivinizdeki parçalarla eşleştirir; içe aktarmadan önce önizleyebilirsiniz
- **Klasörden İçe Aktarma**
- **İzlenen Klasör**: Klasöre eklenen veya klasörde değişen şarkı sözü dosyaları otomatik olarak içe aktarılır: sözü olmayan parçalara hemen eklenir, sözü olanlar değişmez
- **İçe Aktarma Arşivi**: İçe aktarılan şarkı sözlerini görüntüleyin ve silin

### Çalar

- **Müzik Uygulamaları**
- **Web**: Tarayıcıda çalan müzik için de şarkı sözleri gösterilir. Kullandığınız tarayıcıyı eşlemek için “+” düğmesini tıklayın; çalma konumu doğrudan sayfadan okunur, böylece parça değişince sözler hemen eşzamanlanır
- **Diğer Uygulamalar**: Yukarıda listelenmeyen uygulamalar da çalar olarak kullanılabilir: eklendikten sonra çaldıkları parça gösterilir ve dinleme geçmişinize eklenir
- **Uygulama Ekle…**: “Uygulamalar” klasöründen seçin; çalmaya başlamasını beklemenize gerek yok
- **Yeni Çalar Uyarıları**

### Çalar › Web

- **YouTube Music Reklamlarını Otomatik Atla**: Atlanabilir reklamlar göründüğü anda atlanır

### Çalar › İzinler ve Hizmetler

- **Otomasyon İzni**
- **Tam Disk Erişimi**
- **Erişilebilirlik**
- **LX Music Open API**: Lyrimuse, LX Music’in çalma konumunu bu API üzerinden okur ve ses yüksekliğini ayarlar
- **Pear Desktop API**: Lyrimuse bu API üzerinden Pear Desktop’tan geçerli parçanın kimliğini, türünü ve çalma sırasını okur
- **Şarkı Sözü Motoru**: Oynatma durumunu okur; şarkı sözlerini ve kapağı alır

### Çalar › Açılış ve Çıkış

- **Açılış ve Çıkış**: Yalnızca seçtiğiniz çalarlar listelenir. “Otomatik Algıla” açıkken bu Mac’te yüklü çalarlar da listelenir
- **Açılışta Çalarları Aç**
- **Çalarla Birlikte Başlat**
- **Çalarla Birlikte Çık**

### Şarkı Sözü Görünümü › Yüzen Sözler

- **Yüzen Sözler**
- **OBS**
- **Tema**
- **Genişlik**
- **Konum**
- **Saptanmışlara Dön**: Yalnızca temayı, fontu ve renkleri sıfırlar

### Şarkı Sözü Görünümü › Yüzen Sözler › OBS

- **OBS Çıkışı**: Sözleri yayınınıza tarayıcı kaynağı olarak bindirin; genişliğini ve yüksekliğini OBS tuvalinizin boyutuna ayarlayın
- **Tarayıcı Kaynağı URL’si**
- **Başlık Kartı**: Sol üst köşede parça adını, sanatçıyı ve kapağı gösterir
- **Yerel Ağ Erişimine İzin Ver**: Aynı ağdaki aygıtlar, erişim anahtarı içeren bir bağlantıyla bağlanabilir
- **Erişim Bağlantısı**
- **Yedek Bağlantı (IP Adresi)**
- **Erişim Anahtarını Sıfırla**: Paylaştığınız bağlantılar artık çalışmaz
- **Kapı**: Değiştirdikten sonra OBS’deki URL’yi de güncelleyin

### Şarkı Sözü Görünümü › Yüzen Sözler › Tema

- **Temalarım**

### Şarkı Sözü Görünümü › Yüzen Sözler › Font

- **Font**
- **Kalınlık**
- **Punto**
- **Telaffuz Puntosu**
- **Çeviri Puntosu**
- **Sonraki Satır**

### Şarkı Sözü Görünümü › Yüzen Sözler › Renk

- **Karaoke Efekti**
- **Metin Rengi**
- **Metin Konturu**
- **Kontur Rengi**
- **Kontur Kalınlığı**
- **Metin Opaklığı**
- **Söylenmemiş Kısım Rengi**
- **Arka Plan Rengi**
- **Buzlu Cam Arka Plan**
- **Cam Yoğunluğu**

### Şarkı Sözü Görünümü › Yüzen Sözler › İçerik

- **Telaffuz**
- **Çeviri**
- **Sonraki Satır**
- **Sonraki Satır Yerleşimi**: Dönüşümlü: İki satır aynı boyutta, biri solda biri sağda sırayla söylenir; söylenen satırın yerine ondan sonraki ikinci satır gelir

### Şarkı Sözü Görünümü › Yüzen Sözler › Yerleşim

- **Hizalama**
- **Uzun Satırlar**
- **Satır Geçişi**: Şarkı sözü değişince sonraki satır yerine kayar. Kapalıyken satırlar anında değişir
- **Telaffuz Aralığı**
- **Çeviri Aralığı**
- **Sonraki Satır Aralığı**

### Şarkı Sözü Görünümü › Yüzen Sözler › Davranış

- **Konumu Kilitle**
- **Basılı Tutup Sürükle**
- **Üzerine Gelince Soldur**
- **Üzerine Gelince Denetimleri Göster**
- **Ekran Resimlerinde Gizle**
- **Duraklatınca Gizle**
- **Söz Yoksa Gizle**
- **Reklamlarda Gizle**
- **Tam Ekranda Gizle**
- **Şarkı Sözü Yoksa Parça Adını Göster**

### Şarkı Sözü Görünümü › Yüzen Sözler › Konum

- **Gösterim Yeri**

### Şarkı Sözü Görünümü › Çentik

- **Çentik Sözleri**
- **Stil**
- **Ekran**
- **Sol Kulak**
- **Sağ Kulak**
- **Genişlik**
- **Genişletilmiş Genişlik**
- **Saptanmışlara Dön**: Genişlik ve “Çentik Sözleri” anahtarı değişmez

### Şarkı Sözü Görünümü › Çentik › Stil

- **Genişletilmiş Arka Plan**
- **Köşeler**
- **Genişletilmiş Köşeler**
- **İlerleme Çizgisi**: Genişletilmemişken çalma ilerlemesini gösterir

### Şarkı Sözü Görünümü › Çentik › Sol Kulak

- **Ses Dalgası**: Aynı anda yalnızca bir tarafta gösterilir
- **Müzikle Hareket Et**: Çalardan gelen sese göre hareket eder; Lyrimuse’un sistem sesini kaydetmesine izin vermeniz gerekir. Yalnızca ses düzeyi okunur, ses kaydedilmez

### Şarkı Sözü Görünümü › Çentik › Şarkı Sözü Satırı

- **Daraltıldığında Sözleri Göster**: Kapalıyken yalnızca çentik yüksekliğinde bir şerit kalır, üzerine gelince genişler
- **Hizalama**
- **Şarkı Sözü Rengi**
- **İkinci Satır**
- **Çeviri Yoksa**
- **Telaffuz Yoksa**
- **Genişletilince Sonraki Satırı Önizle**
- **Yükseklik**
- **Karaoke Efekti**
- **Kapağı Göster**
- **Kapak Konumu**
- **Üzerine Gelince Soldur**

### Şarkı Sözü Görünümü › Çentik › Font

- **Font**
- **Kalınlık**
- **Punto**

### Şarkı Sözü Görünümü › Çentik › Genişletildiğinde

- **Çok Satırlı Sözler**: Genişletildiğinde birkaç satır şarkı sözü gösterir, geçerli satır kelime kelime vurgulanır
- **Satır Sayısı**
- **Denetimleri Göster**
- **Kaydırmayı Göster**
- **Hızlı Eylemler**
- **Parça Bilgisi**

### Şarkı Sözü Görünümü › Çentik › Davranış

- **Duraklatınca Daralt**
- **Ekran Resimlerinde Gizle**
- **Duraklatınca Gizle**
- **Söz Yoksa Satırı Daralt**
- **Reklamlarda Daralt**
- **Tam Ekranda Gizle**
- **Kilitli Ekranda Göster**
- **Dinleme Dönüm Noktaları**
- **Parça Değişince Adını Göster**
- **Ses Tuşlarında Göster**
- **İzleme Dörtgeni Hareketleri**

### Şarkı Sözü Görünümü › Menü Çubuğu

- **Menü Çubuğu Sözleri**
- **Saptanmışlara Dön**: Genişlik ve “Menü Çubuğu Sözleri” anahtarı değişmez

### Şarkı Sözü Görünümü › Menü Çubuğu › İçerik

- **Gösterilenler**
- **İkinci Satır**
- **Çeviri Yoksa**
- **Telaffuz Yoksa**
- **Sözlerin Yanındaki Simge**: Simge, çalma ilerlemesini göstermek için alttan yukarı dolar; renkler “Renk” grubundan alınır

### Şarkı Sözü Görünümü › Menü Çubuğu › Yerleşim

- **Söz Konumu**: Ortada: şarkı sözleri uygulama menülerinden, sağdaki simgelerden ve çentikten uzak durarak menü çubuğunun ortasında görünür
- **Gösterim Yeri**
- **Genişlik Modu**: Sabit: her parça ayarlanan genişliği kullanır Uyarlanabilir: her parçanın genişliği şarkı sözlerine göre belirlenir, ayarlanan genişliği aşmaz
- **Hizalama**

### Şarkı Sözü Görünümü › Menü Çubuğu › Renk

- **Karaoke Efekti**
- **Gökkuşağı**: Şarkı sözleri soldan sağa akan gökkuşağı renklerinde görünür, açık renkli menü çubuğunda otomatik olarak koyulaşır; menü açıkken sistem renklerine döner
- **Metin Rengi**
- **Söylenmiş Kısım Rengi**

### Şarkı Sözü Görünümü › Menü Çubuğu › Font

- **Font**
- **Kalınlık**
- **Punto**

### Şarkı Sözü Görünümü › Menü Çubuğu › Genişlik

- **Maksimum Genişlik**

### Şarkı Sözü Görünümü › Menü Çubuğu › Davranış

- **Üzerine Gelince Denetimleri Göster**
- **Şarkı Sözü Yoksa Parça Adını Göster**
- **Duraklatınca Sözleri Koru**: Duraklatıldığında simgeye daralmak yerine geçerli satırda kalır

### Şarkı Sözü Görünümü › Touch Bar

- **Touch Bar Sözleri**
- **Saptanmışlara Dön**: “Touch Bar Sözleri” anahtarı olduğu gibi kalır

### Şarkı Sözü Görünümü › Touch Bar › İçerik

- **İkinci Satır**
- **Çeviri Yoksa**
- **Telaffuz Yoksa**
- **Punto**

### Şarkı Sözü Görünümü › Touch Bar › Yerleşim

- **Hizalama**
- **Kapağı Göster**
- **Kapak Konumu**
- **Denetimleri Göster**: Önceki, Çal/Duraklat ve Sonraki, ayrıca ayarlar düğmesi
- **Denetimlerin Konumu**
- **“Daha Fazla” Düğmesini Göster**: Dokununca çalma konumu, şarkı sözü kalibrasyonu, Favori, Karıştır/Yinele ve Ses Yüksekliği arasında geçiş yapar. Geçerli çaların desteklemediği öğeler gizlenir
- **Genişletilmişken Control Strip’i Gizle**: Şarkı sözleri tüm Touch Bar’ı kaplar. Parlaklık, ses ve diğer sistem düğmelerine ulaşmak için önce soldaki ✕ simgesine dokunarak sözleri daraltın
- **Sistem Control Strip’i**: Touch Bar’ın sağındaki parlaklık, ses ve diğer sistem düğmelerini “Sistem Ayarları › Klavye › Touch Bar Ayarları…” bölümünden ekleyin, kaldırın veya yeniden sıralayın

### Şarkı Sözü Görünümü › Touch Bar › Renk

- **Karaoke Efekti**
- **Metin Rengi**: Beyaz, kapak rengi, özel renk veya gökkuşağı
- **Soluk Metin Parlaklığı**: Söylenmemiş kelimelerin ve ikinci satırın parlaklığı

### Şarkı Sözü Görünümü › Touch Bar › Davranış

- **Çalma Başlayınca Genişlet**: Duraklatmadan sürdürüldüğünde şarkı sözlerini gösterir. Çalarken parça değişince genişlemez; daralttığınız sözler daraltılmış kalır
- **Duraklatınca Daralt**: 10 saniye duraklatıldıktan sonra Control Strip düğmesine daralır, çalma sürdürülünce yeniden genişler
- **Söz Yoksa Daralt**: Yalnızca şarkı sözü olmadığı doğrulandıktan sonra daralır, sözler bulununca yeniden genişler. Arama sırasında gösterilmeye devam eder
- **Yazarken Daralt**: İmleç bir metin alanındayken daralır, böylece giriş yöntemi adayları ve yazma önerileri görünür; alandan çıkınca yeniden genişler. Erişilebilirlik izni gerekir

### Şarkı Sözü Görünümü › Şarkı Sözü Penceresi

- **Şarkı Sözü Penceresi**
- **Tarayıcıda Şarkı Sözleri**: Şarkı Sözü Penceresi’ni web tarayıcısında gösterir
- **Saptanmışlara Dön**

### Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Tarayıcıda Şarkı Sözleri

- **Yerel Adres**
- **Yerel Ağ Erişimine İzin Ver**: Aynı ağdaki aygıtlar, erişim anahtarı içeren bir bağlantıyla bağlanabilir
- **Uzaktan Denetime İzin Ver**: Diğer aygıtlardan çalma denetlenebilir ve sözlere atlanabilir
- **Erişim Bağlantısı**
- **Yedek Bağlantı (IP Adresi)**
- **Erişim Anahtarını Sıfırla**: Paylaştığınız bağlantılar artık çalışmaz
- **Kapı**: Değiştirdikten sonra yeniden bağlanmak için QR kodunu tekrar tarayın

### Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Arka Plan

- **Arka Plan**: Şarkı sözü penceresinin arka planı: kapağa göre, düz renk, gradyan veya buzlu cam
- **Yön**
- **Spotify Canvas** (yalnızca Tam Boyut): Parçanın Spotify’daki döngülü videosunu arka plan yapar; yalnızca Spotify’da çaldığınız parçalar için
- **Cam Yoğunluğu**: Buzlu cam malzeme yoğunluğu (beş düzey)
- **Alt Renk**

### Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Font

- **Punto** (yalnızca Mini): Mini boyutta şarkı sözü puntosu üst sınırı
- **Font**: Şarkı sözü penceresinin şarkı sözü fontu (ana metin, çeviri, telaffuz)
- **Kalınlık**
- **Yazı Ölçeği** (yalnızca Tam Boyut): Pencereye göre ayarlanan yazı boyutunu büyütür veya küçültür; tarayıcıdaki şarkı sözlerinde de geçerlidir
- **Telaffuz Puntosu** (yalnızca Tam Boyut)
- **Çeviri Puntosu** (yalnızca Tam Boyut)
- **Telaffuz Fontu** (yalnızca Tam Boyut)
- **Çeviri Fontu** (yalnızca Tam Boyut)
- **Telaffuz Kalınlığı** (yalnızca Tam Boyut): “Ana Metne Uy” ana metinden iki kademe ince olur
- **Çeviri Kalınlığı** (yalnızca Tam Boyut): “Ana Metne Uy” ana metinden bir kademe ince olur

### Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Yerleşim

- **Uzun Satırlar** (yalnızca Mini): Mini boyutta uzun satırların alt satıra geçmesi veya kaydırılması
- **Şarkı Sözü Yerleşimi** (yalnızca Mini): Tek Satır: yalnızca geçerli satır İki Satır: geçerli satır ve sonraki satır Çok Satır: tam boyuttaki gibi kayan bir sayfa şarkı sözü
- **Satır Aralığı** (yalnızca Tam Boyut)
- **Telaffuz Aralığı** (yalnızca Tam Boyut)
- **Çeviri Aralığı** (yalnızca Tam Boyut)
- **Hizalama** (yalnızca Tam Boyut): Tam Boyut’ta sözlerin hizalaması; “Otomatik” düet seslerine göre hizalar
- **Denetim Boyutu** (yalnızca Tam Boyut): Çalma denetimlerini ve diğer düğmeleri büyütür; tarayıcıdaki şarkı sözlerinde de geçerlidir

### Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Davranış

- **Üzerine Gelince Soldur** (yalnızca Mini)
- **Soluklaşınca Tıklamaları Geçir** (yalnızca Mini): Soluklaştığında tıklamalar alttaki pencereye geçer. Opak yapıp etkileşim kurmak için ⌥ tuşunu basılı tutun
- **Ekran Resimlerinde Gizle** (yalnızca Mini)
- **Duraklatınca Gizle** (yalnızca Mini)
- **Söz Yoksa Gizle** (yalnızca Mini)
- **Reklamlarda Gizle** (yalnızca Mini)
- **Tam Ekranda Gizle** (yalnızca Mini)

### Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Renk

- **Karaoke Efekti**
- **Metin Rengi**: Şarkı sözü penceresinin metin rengi. “Otomatik”, arka planın parlaklığına göre açık ve koyu arasında geçiş yapar
- **Özel Renk**
- **Söylenmiş Kısım Rengi**
- **HDR Vurgusu** (yalnızca Tam Boyut): HDR destekli ekranlarda söylenmiş kısmı parlatır; açıkken daha fazla enerji kullanır
- **Telaffuz Rengi** (yalnızca Tam Boyut)
- **Çeviri Rengi** (yalnızca Tam Boyut)

### Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Derinlik

- **Söylenmemişi Karart** (yalnızca Tam Boyut): Henüz söylenmemiş satırların geçerli satırdan ne kadar koyu olacağı
- **Söyleneni Karart** (yalnızca Tam Boyut): Söylenmiş satırların geçerli satırdan ne kadar koyu olacağı
- **Bulanıklık** (yalnızca Tam Boyut)

### Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › İçerik

- **Telaffuz**
- **Çeviri**
- **İlerleme Çubuğu** (yalnızca Mini): Kapalıyken yalnızca imleç üzerindeyken çalma denetimleriyle birlikte görünür

### Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Üst Bilgi

- **Parça Adı** (yalnızca Mini): Mini boyutun üstünde parça adı, sanatçı ve albüm gösterilir
- **Sanatçı** (yalnızca Mini)
- **Albüm** (yalnızca Mini)
- **Kapak** (yalnızca Mini): Mini boyutun üst bilgisinin yanındaki küçük kapak resmi
- **Süre** (yalnızca Mini): Mini boyutun üstünde geçen süre ve parça uzunluğu gösterilir
- **Genişlik** (yalnızca Mini): Mini boyutta üst bilginin kapladığı pencere genişliği yüzdesi
- **Yükseklik** (yalnızca Mini): Mini boyutta üst bilginin kapladığı pencere yüksekliği yüzdesi; metin ve kapak da buna göre ölçeklenir

### Şarkı Sözü Görünümü › Şarkı Sözü Penceresi › Kapak

- **Hareketli Kapak** (yalnızca Tam Boyut): Yalnızca bazı albümlerde var; Düşük Güç Modu’nda veya “Hareketi Azalt” açıkken duraklar
- **Kaynak** (yalnızca Tam Boyut)
- **Hareketli Kapak Önbelleği** (yalnızca Tam Boyut): İndirilen hareketli kapakların kullandığı disk alanı; silinenler bir sonraki gösterimde yeniden indirilir

### Klavye Kestirmeleri

- **Derin Bağlantılar**: Kestirmeler, Raycast, Alfred gibi araçlardan açılabilir; bir işlemin bağlantısını kopyalamak için imleci yukarıdaki kestirmenin üzerine getirin
- **Yüzen Sözleri Göster/Gizle**
- **Çentik Sözlerini Göster/Gizle**
- **Çentiği Geçici Olarak Genişlet**
- **Menü Çubuğu Sözlerini Göster/Gizle**
- **Touch Bar Sözlerini Genişlet/Daralt**
- **Tüm Sözleri Gizle/Geri Getir**
- **Konumu Kilitle/Kilidi Aç**
- **Çeviriyi Göster/Gizle**
- **Telaffuzu Göster/Gizle**
- **Yüzen Sözlerin Puntosunu Büyüt**
- **Yüzen Sözlerin Puntosunu Küçült**
- **Şarkı Sözü Yöneticisini Aç**
- **Şarkı Sözü Penceresini Aç**
- **Mini/Tam Boyuta Geç**
- **Şarkı Sözü Ara**
- **Ayarları Aç**
- **Çalara Geç**
- **Menü Çubuğu Panelini Aç/Kapat**
- **Sözleri Öne Al**
- **Sözleri Geciktir**
- **Şarkı Sözü Kaydırmasını Sıfırla**
- **Adım**: Her basışta ayarlanan miktar
- **Çal/Duraklat**
- **Sonraki Parça**
- **Önceki Parça**
- **Favorilere Ekle/Çıkar**

### Genel › Menü Çubuğu ve Dock

- **Menü Çubuğu Simgesi**
- **Albüm Kapağı**
- **Simge Boyutu**
- **Simge Animasyonu**
- **Dock’ta Göster**

### Genel › Görünüş ve Dil

- **Görünüş**: Ayarlar, Şarkı Sözü Penceresi, Şarkı Sözü Yöneticisi ve menü çubuğu panelinin renkleri
- **Dil**

### Genel › Başlangıç ve Bildirimler

- **Oturum Açıldığında Aç**
- **Sessizce Başlat**
- **Parça Değişince Bildir**

### Genel › Ağ

- **Vekil Sunucu**

### Genel › Yedekleme ve Taşıma

- **iCloud Yedeği**
- **Ayarlar Dosyası**: Düz metin kimlik bilgileri içerir. Ayarlar ve şarkı sözü arşivi iki dosya olarak dışa aktarılır; içe aktarma tüm ayarları değiştirir
- **Tüm Ayarları Sil**: Yalnızca bu Mac’teki ayarları siler; yedekler ve dışa aktarılan dosyalar korunur. Geri alınamaz

### Deneysel

- **Parça Dosyalarına Otomatik Yaz**: Yerel bir şarkı çalınırken kesinleşen şarkı sözlerini dosyaya yazar
- **Diğer Uygulamaların Yazdığı Sözlerin Üzerine Yaz**: Mevcut şarkı sözleri değiştirilmeden önce yedeklenir

### Yazılım Güncelleme

- **Yazılım Güncelleme**

### Yazılım Güncelleme › Güncelleme Ayarları

- **Otomatik Olarak Denetle**: Günde bir kez yeni sürümü denetler
- **Otomatik Olarak İndir ve Yükle**: Arka planda indirir, Lyrimuse’dan çıktığınızda yükler
- **Beta Güncellemeleri**: Yayın öncesi sürümler; kararsız olabilir

### Hakkında › Güncellemeler ve Yardım

- **Sorun Bildir**: GitHub’da sürüm, macOS ve çalar bilgileri doldurulmuş yeni bir issue açar
- **Yardım Al**: GitHub Discussions’ın Q&A kategorisinde soru sorun
- **Özellik Listesi**: Tüm özellikler, Ayarlar’daki yerleri ve saptanmış durumları

### Hakkında

- **Web Sitesi**
- **Discord Topluluğu**: Diğer kullanıcılarla sohbet edin, soru sorun veya öneride bulunun
- **Telegram Grubu**: Diğer kullanıcılarla sohbet edin, soru sorun veya öneride bulunun
- **QQ Grubu**: Diğer kullanıcılarla sohbet edin, soru sorun veya öneride bulunun
- **Telif Hakkı Bildirimi**
- **Üçüncü Taraf Lisansları**: Açık kaynak bileşenler ve sözlükler
- **Açık Kaynak Lisansı**: GPL-3.0

### Hakkında › Tanılar ve Veriler

- **Tanıları Dışa Aktar**: Günlükler, çökme raporları ve uygulama durumu tek dosyada; hesap kimlik bilgileri çıkarılmıştır. Parça adları ve yerel yollar içinde kalır, herkese açık paylaşmadan önce gözden geçirin
- **Etkinlik Günlüğü**: Şarkı sözü motorunun ham günlüğü, kendi sorun gidermeniz için
- **Veri Klasörü**: Düz metin. Hesap kimlik bilgileri, görünüş ve kestirmeler dahil değildir; her şeyi taşımak için “Yedekleme ve Taşıma” bölümünü kullanın
- **Anonim Kullanım Verilerini Paylaş**: Lyrimuse’u geliştirmeye yardımcı olur: sürüm, sistem, kullanılan özellikler ve çökme raporları. Parça adları ve hesaplar asla gönderilmez
- **Önbellek**: Yeniden alınabilen kapaklar ve sorgu sonuçları

### Deneysel › ListenBrainz

- **Hesap Bilgileri**

### Last.fm › Kurallar

- **Skroplama Kuralları**
- **Eşleştirme Modu**: Last.fm’e gönderilen sanatçı ve parça adı Akıllı: Last.fm’de en çok dinlenen yazımı kullanır, eşleşme yoksa olduğu gibi gönderir. Albüm adlarından “ - Single” / “ - EP” çıkarılır Özel: parça adını ve sanatçıyı ayrı ayrı ayarlayın Ham: çaların bildirdiğini aynen gönderir
- **Parça Adı**
- **Sanatçı**
- **Skroplama Zamanı**
- **30 Saniyeden Kısa Parçaları Skropla**: Açıkken bu parçalar yarısı çalınınca skroplanır. Last.fm’in resmi kuralları bunları skroplamaz
- **Skroplanacak Çalarlar**

### Deneysel › Web Anlık Bildirimleri

- **Bağlantı Bilgileri**

### Anlık Bildirimler

- **Kanallar**: Dinleme raporları etkin tüm kanallara gönderilir. Birden çok kanal varsa aşağıdaki “Dinleme Raporları” bölümünde her rapor için ayrı seçebilirsiniz. Düzenlemek veya test göndermek için bir satırı tıklayın; silmek için sağ tıklayın
- **Gönderim Saati**
- **Dinleme Raporları**
- **Veri Kaynağı**
- **Liste Başına Öğe**: Sanatçı, albüm ve parça listelerinin her birinde kaç öğe gösterileceği
- **Haftalık Dinleme Raporu**
- **Günlük Dinleme Raporu**
- **Aylık Dinleme Raporu**
- **Yıllık Dinleme Raporu**
- **Gönderim Geçmişi**

### Discord

- **Discord’da Göster**: Açıkken dinlediğiniz parça Discord profilinizde ve arkadaş listenizde görünür. Arkadaşlarınız göremiyorsa Discord’da “Kullanıcı Ayarları › Etkinlik Gizliliği” bölümüne gidip etkinlik paylaşımını açın
- **Gösterilenler**
- **“Dinliyor” Önünde**: Profilinizdeki “×× dinliyor” ifadesindeki ××. iOS ve web’deki Discord bunu yok sayar, çalar adını göstermeye devam eder Parça adı veya sanatçı seçildiğinde “Adınızın Altında” için “Çalar” seçilemez
- **Adınızın Altında**: Discord, kullanıcı adınızın altında yalnızca birinci satırı, ikinci satırı veya “Dinliyor” ifadesinden sonrasını gösterebilir. Parça adı da sanatçı da bu konumlardan birinde değilse ilgili seçenek kullanılamaz
- **Kapak Rozeti**
- **Duraklatınca**
- **Parça Bilgileri**
- **Durum Metni**
- **Kapak ve İlerleme**
- **Sanatçı ve Albümü Etiketle**: Sanatçının önüne “Sanatçı:”, albümün önüne “Albüm:” ekler. Parça adı ve sanatçı aynı satırdaysa eklenmez
- **Düğmeler**
- **Özel Düğme**
- **“Çalarda Dinle”**: Bu parçanın geçerli çaların web sitesindeki sayfasını açar; parça adını tıklamakla aynıdır. Sayfa yoksa gizlenir
- **“Lyrimuse’u İndir”**
- **Gizlilik**
- **Geçici Olarak Gizle**
- **Parça Bilgilerini Gizle**: Yalnızca kullandığınız çalar ve ilerleme gösterilir. Parça adı, sanatçı, albüm, şarkı sözleri, bağlantılar ve “Çalarda Dinle” düğmesi gönderilmez
- **İlerleme Çubuğunu Göster**: Kapalıyken ilerleme çubuğu gösterilmez; Discord bunun yerine geçen süreyi gösterir ve bu süre kapatılamaz
- **Gösterilen Çalarlar**
