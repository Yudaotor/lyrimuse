# Lyrimuse, Last.fm’e nasıl skroplar

*[English](scrobbling.md) · [简体中文](scrobbling.zh-CN.md) · [日本語](scrobbling.ja.md) · [한국어](scrobbling.ko.md) · [Español](scrobbling.es.md) · [Français](scrobbling.fr.md) · [Deutsch](scrobbling.de.md) · [Italiano](scrobbling.it.md) · [Português (Brasil)](scrobbling.pt-BR.md) · [Tiếng Việt](scrobbling.vi.md) · [Русский](scrobbling.ru.md) · [Українська](scrobbling.uk.md) · [ไทย](scrobbling.th.md) · **Türkçe***

## 1. Bir dinleme ne zaman sayılır

Bir dinleme, aşağıdaki koşulların **tümü** sağlandığında gönderilir:

| Kural | Değer |
|---|---|
| Yeterince uzun çalındı | parçanın yarısı, en fazla 240 saniye; uzunluk bilinmiyorsa 240 saniye. Yalnızca Last.fm için daha geç noktalar seçilebilir; bkz. §1b |
| Parça yeterince uzun | `≥ 30s` (uzunluğu bilinmeyen parçalar geçer). Kapatılabilir; bkz. §1a |
| Reklam değil | Spotify reklam araları algılanır ve atlanır |

Çalma durumu 5 saniyede bir okunur ve geçen süre gerçek saate göre birikir; böylece duraklatınca sayım durur, ileri sarmak da süreyi şişirmez. İki okuma arasında 60 saniyeden fazla zaman geçmişse (Mac uyku moduna geçmişse veya motor yeniden başlatılmışsa) bu aralık sayıma eklenmez, atılır.

Bu eşikler [Last.fm’in skroplama yönergeleriyle](https://www.last.fm/api/scrobbling) uyumludur.

### 1a. 30 saniyeden kısa parçalar

Ayarlar → Bağlı Hizmetler → Last.fm → *Kurallar* → **30 Saniyeden Kısa Parçaları Skropla** (`scrobble_short_tracks`, saptanmış olarak **kapalı**). Last.fm’in *“The track must be longer than 30 seconds”* (parça 30 saniyeden uzun olmalıdır) kuralı istemci tarafında uygulanan bir kuraldır: sunucu kısa parçaları reddetmez ve “çok kısa” için bir yok sayma kodu da yoktur. Yaygın skroplayıcıların hepsi bu kurala uyar, Lyrimuse da saptanmış olarak uyar. Bu ayarı açarsanız kısa parçalar, yarısı çalınmış olma kuralını geçtiğinde sayılır (20 saniyelik bir parça için 10 saniye yeter). Bu ayar **yalnızca Last.fm** içindir: kısa parçalar Last.fm’e skroplanır (ve Last.fm’e sonradan gönderimi besleyen yerel günlüğe yazılır), ama ListenBrainz’e hiç gönderilmez; ListenBrainz’in davranışı her iki durumda da aynı kalır.

### 1b. Skroplama zamanı

Ayarlar → Bağlı Hizmetler → Last.fm → *Kurallar* → **Skroplama Zamanı** (`lastfm_scrobble_point`, saptanmış: **%50**). Bir dinlemenin Last.fm’e skroplanması için parçanın ne kadarının çalınmış olması gerektiğini belirler:

| Ayar | Değer | Ne zaman skroplanır |
|---|---|---|
| **%50** (saptanmış) | `50` | Yukarıdaki Last.fm kuralı: parçanın yarısı, en fazla 4 dakika |
| %75 / %90 | `75` / `90` | Parça uzunluğunun %75’i / %90’ı çalındığında; yalnızca çalınan süre sayılır, 4 dakika sınırı yoktur |
| Parça Sonu | `end` | Parça sonuna kadar çalındığında; ileri atlamak sayılmaz |

Last.fm’in kuralı bir alt sınırdır, bu yüzden %50’nin altında bir ayar yoktur. Bu ayar **yalnızca Last.fm** içindir: ListenBrainz ve web aktarıcısı yine %50 noktasında gönderir; yalnızca Last.fm skroplaması (ve Last.fm’e sonradan gönderimi besleyen yerel günlük) seçilen noktayı bekler. Bu noktadan önce atlanan bir parça Last.fm’e hiçbir şey göndermez; bu kaybolan bir skroplama değil, ayarın işini yapmasıdır. Uzunluğu bilinmeyen parçalar saptanmış kurala uyar.

*Parça Sonu*, parça değiştiğinde son gözlenen çalma konumuna bakılarak belirlenir: sona 12 saniyeden az kalmışsa (kısa parçalarda uzunluğun %10’u) parça sonuna kadar çalınmış sayılır; böylece çaların çapraz geçişi veya boşluksuz geçiş skroplamayı engellemez.

## 2. Neler gönderilir

`track.scrobble` geçmişinize kalıcı bir kayıt yazar; `track.updateNowPlaying` ise “şu an dinliyor” göstergesini ayarlar ve hiçbir şey saklamaz.

| Alan | `track.scrobble` | `track.updateNowPlaying` |
|---|---|---|
| `artist` | ✅ | ✅ |
| `track` | ✅ | ✅ |
| `timestamp` | ✅ | — |
| `album` | boş değilse | boş değilse |
| `duration` | biliniyorsa | biliniyorsa |

Last.fm’e bunlardan başka hiçbir şey gitmez. Last.fm API’si bir skroplamada `mbid`, `albumArtist`, `trackNumber`, `chosenByUser`, `streamId` ve `context` alanlarını da kabul eder; Lyrimuse bunların hiçbirini göndermez.

## 3. Neler yeniden yazılmaz

ListenBrainz yolunda ve Last.fm’in *Tümü* ve *Yalnızca ilki* modlarında sanatçı, parça ve albüm adları tam olarak çaların bildirdiği gibi gönderilir. (Last.fm’in *Akıllı* modu sanatçıyı ve parça adını katalogdaki kayda uyacak şekilde yeniden yazar; bkz. sonraki bölüm.)

Uygulanan tek işlem görünmez karakter temizliğidir: bölünemez boşluklar ve tam genişlikli boşluklar sıradan boşluğa dönüştürülür, sıfır genişlikli karakterler ve BOM’lar silinir, art arda gelen boşluklar teke indirilir, baştaki ve sondaki boşluklar kırpılır. Bu temizlik yapılmazsa görünmez bir bölünemez boşluk Last.fm’de ayrı bir sanatçı kaydı oluşturur.

Görünen hiçbir şey değiştirilmez: büyük/küçük harf, Geleneksel ya da Basitleştirilmiş Çince, parantez içindeki alt başlıklar ve birden çok sanatçılı künyeler olduğu gibi kalır. `PRINCE` yine `PRINCE`, `無所謂` yine `無所謂` olarak kalır; `一口 (The Day You Left Me)` da alt başlığını korur.

Adları “standart biçime getirmek” için saptanmış olarak neden dış bir sorgu yapılmıyor:

- Lyrimuse eskiden tam olarak bunu yapıyordu. Yaklaşık 2.500 parçalık gerçek bir arşivin denetiminde, aralarında `USA for Africa` → `Xtc Planet` ve `LBI利比` → `Safehse` de bulunan yaklaşık 200 yeniden yazılmış sanatçı adı çıktı. Herkese açık bir Last.fm sanatçı sayfasına yazılmış skroplamalar sonradan düzeltilemez; düzeltme veritabanı dondurulmuştur.
- Last.fm’in skroplama kılavuzu bunu iki kez söyler: *“Do not use the corrections returned by the now playing service as input for the scrobble request, unless they have been explicitly approved by the user.”* (Kullanıcı açıkça onaylamadıkça, “now playing” hizmetinin döndürdüğü düzeltmeleri skroplama isteğinde girdi olarak kullanmayın.) `autocorrect` bayrağı ise [eski bir özellik olarak belgelenmiştir](https://support.last.fm/t/scrobbles-of-japanese-artists-getting-separated-by-romanization-of-their-name/119906).
- İncelenen dokuz açık kaynak skroplayıcıdan (Web Scrobbler, Pano Scrobbler, Navidrome, Maloja, rescrobbled, mpdscribble, mpdas, Koito, multi-scrobbler) hiçbiri saptanmış olarak sanatçı adlarını dış bir sorguya göre yeniden yazmaz.

## 4. Eşleştirme modu

Ayarlar → Bağlı Hizmetler → Last.fm → *Kurallar* → **Eşleştirme Modu** (`~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-features.json` içindeki `lastfm_match_mode`):

| Mod | Değer | Etkisi |
|---|---|---|
| **Akıllı** (yeni kurulumlarda saptanmış) | `smart` | Bu parçanın Last.fm kataloğundaki kaydını bulur ve o kaydın sanatçısını ve parça adını gönderir (aşağıya bakın) |
| Özel | `custom` | Hangi kısımların değişebileceğini siz seçersiniz; aşağıya bakın |
| **Ham** (mevcut kurulumlarda saptanmış) | `raw` | Tam olarak çaların bildirdiği gönderilir, ağ isteği yapılmaz |

*Özel*, her alan için bir tane olmak üzere iki satır ekler:

| Satır | Seçenek | Etkisi |
|---|---|---|
| **Parça Adı** | Eşleşme | Parça adı katalog kaydındaki yazımla değiştirilebilir ve albüm adından ` - Single` / ` - EP` çıkarılır (`lastfm_match_track`) |
| | Ham | Parça adı bildirildiği gibi gönderilir |
| **Sanatçı** | Eşleşme | Sanatçı adı katalog kaydındaki yazımla değiştirilebilir (`lastfm_match_artist`) |
| | Yalnızca İlki | Ortak bir künyeyi ilk sanatçıya kısaltır (`Khalil Fong & Fiona Sit` → `Khalil Fong`); yalnızca metin işlemedir, ağ isteği yapılmaz (`lastfm_match_first_artist_only`) |
| | Ham | Sanatçı adı bildirildiği gibi gönderilir |

İki satırdan yalnızca birinde *Eşleşme* seçiliyse **bir aday ancak diğer alan zaten eşleşiyorsa kabul edilir**; yoksa katalogda bulunmayan bir birleşim ortaya çıkar ve dinleme yine tek dinleyicisi siz olan hayalet bir kayda düşer.

*Yalnızca İlki* ile *Eşleşme* farklı çalışır: *Yalnızca İlki* **yalnızca hiçbir şey eşleşmediğinde** uygulanır. Eşleşen bir yazım zaten Last.fm’in tanıdığı kayıttır; onu kısaltmak var olmayan bir kayıt üretir: `Hall & Oates / Maneater` (800 bin dinleyici) `Hall` olurdu. Bu yüzden Parça Adı *Ham* ile Sanatçı *Yalnızca İlki* birleşimi, eski *Yalnızca ilki* moduyla bayt bayt aynıdır ve yine ağ isteği yapmaz.

Bir `lyrimuse-features.json` dosyasının zaten bulunduğu her kurulumda saptanmış mod *Ham* olarak kalır, çünkü bir künyeyi kısaltmak geri alınamaz: Fiona Sit’i geçmişinizden siler. Navidrome’un aynı adlı seçeneği (`Lastfm.ScrobbleFirstArtistOnly`) de saptanmış olarak kapalıdır.

Bölme temkinlidir: `/`, `,` ve `&` işaretlerinden ayrı ele alınır; böylece `K/DA` ve `AC/DC`, `K` ve `AC` olarak bölünmez.

### Akıllı mod

Çaların bildirdiği ad ile Last.fm kataloğunun aynı ses kaydına verdiği ad çoğu zaman aynı karakterlerden oluşmaz; olduğu gibi gönderilen dinleme “hayalet” bir kayda düşer: MBID yok, albüm yok, süre sıfır, tek dinleyici var, o da siz. David Tao’nun 《那个女孩》 parçasında ölçüldü: çalar `陶喆, 卢广仲 / 那个女孩` bildirir ve Last.fm’de bu hiç yoktur; Basitleştirilmiş `陶喆 / 那个女孩` kaydının 126 dinleyicisi vardır; parçanın asıl kaydı ise Geleneksel **`陶喆 / 那個女孩`: 889 dinleyici, 4.580 dinleme, katalogda kayıtlı bir süre**. Last.fm’in kendi `autocorrect` özelliği işe yaramaz: Geleneksel ve Basitleştirilmiş Çince arasında eşleme yapmaz.

Bu yüzden *Akıllı*, göndermeden önce parçayı sorgular:

1. Bildirildiği hâliyle `track.getInfo`. **Kaydın bir MBID’si varsa** hiçbir şeye dokunulmaz, hiçbir zaman. MBID, gerçek bir katalog kimliğinin en güçlü işaretidir ve doğru künyelenmiş bir ortak çalışmanın (Hall & Oates) “daha çok dinleyici” gerekçesiyle solo bir sayfaya taşınmasını önleyen de odur.
2. Yoksa adaylar **tam olarak üç yerden** toplanır: bildirildiği hâliyle, künyedeki ilk sanatçı ve o sanatçının, parça adı aynı anahtara indirgenen kayıtları (`artist.getTopTracks`; zaten dinleyici sayısına göre sıralıdır).
3. Last.fm’in gerçekten kataloğunda bulunan adaylar (MBID’si, en az 500 dinleyicisi veya katalogda süresi olanlar; hayalet bir kaydın bu üçünden hiçbiri yoktur) arasında en çok dinleneni kazanır, süresi doğrulanır ve onun sanatçısı ile parça adı gönderilir; karar bir kez verilir, hep korunur. Uygun aday yoksa bildirildiği gibi gönderilir ve 90 gün sonra yeniden denetlenir.

`track.search` bilerek **kullanılmaz**: metni harfiyen arar; bu yüzden ne Geleneksel kaydı bulur ne de `张泽熙 / 那个女孩` gibi adı aynı ama şarkısı farklı sonuçları dışarıda bırakır. Parça adı indirgemesi yalnızca tek bir ses kaydının yazım farklarını birleştirir: Geleneksel ve Basitleştirilmiş Çince, varyant karakterler, aksan işaretleri, konuk sanatçı künyeleri (`(feat. X)`) ve yeniden yayın etiketleri (`(Remastered 2014)`, `(Bonus Track)`). **Live, Remix, akustik ve enstrümantal işaretleri her zaman korunur**: bunlar farklı ses kayıtlarıdır. Kazanan aday ayrıca bir süre denetiminden de geçmelidir (iki tarafın da süresi biliniyorsa ve aradaki fark 8 saniyeyi aşıyorsa reddedilir).

240 gerçek parça üzerinde ölçüldü: 33 parça yeniden yazıldı, 162 parça olduğu gibi gönderildi, 45 parçada karar verilemedi. Örnekler:

| Bildirilen | Gönderilen | Dinleyici |
|---|---|---|
| `周杰倫 / 手写的从前` | `周杰倫 / 手寫的從前` | 100 → 4.515 |
| `Wang Leehom / 奇遇的起点` | `王力宏 / 奇遇的起點` | 1 → 144 |
| `SZA & Phoebe Bridgers / Ghost in the Machine` | `SZA / Ghost in the Machine (feat. Phoebe Bridgers)` | 175 → 856.376 |
| `PRINCE / Walk Don't Walk (2023 Remaster)` | `Prince / Walk Don't Walk` | 231 → 16.178 |

Herhangi bir sorgu hatasında (ağ, istek sınırı, bozuk yanıt, ulaşılamayan parça listesi) etiketler bildirildiği gibi gönderilir ve hiçbir şey önbelleğe alınmaz; böylece geçici bir aksaklık hiçbir zaman kalıcı bir karara dönüşmez. Kararlar, onlara yol açan kanıtlarla birlikte `~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-lastfm-catalog.json` dosyasında tutulur; her şeyin yeniden kararlaştırılması için dosyayı silin.

Eski anahtarlar hâlâ okunur ama artık yazılmaz ve davranış değişmeden taşınır: `lastfm_scrobble_artist_mode` için `smart` → Akıllı, `all` → Ham, `first` ise Parça Adı Ham, Sanatçı Yalnızca İlki olarak ayarlanmış Özel olur; daha eski mantıksal değer `lastfm_scrobble_first_artist_only=true`, `first` ile eşdeğerdir.

## 5. Skroplama başarısız olursa

Hatalar sınıflandırılır, çünkü doğru tepki duruma göre değişir. Aşağıda “günlüğe yazılır”, dinlemenin yerel bir günlüğe yazıldığı anlamına gelir; **sonradan gönderme** bu dinlemeleri daha sonra gönderebilir. Sonradan gönderme, son dinlemelerinizin altındaki “gönderilecek dinleme” sayısının yanındaki **Sonradan Gönder** ile elle başlatılır.

| Ne oldu | Ne yapıyoruz |
|---|---|
| İsteğin Mac’inizden hiç çıkmadığı kesin (DNS, bağlantı kurulamadı) | Günlüğe yazılır; sonradan gönderme onu gönderebilir |
| Sunucu, kesinlikle saklanmadığı anlamına gelen bir nedenle reddetti (geçersiz kimlik bilgileri, istek sınırı) | Günlüğe yazılır; sonradan gönderme onu gönderebilir |
| Gönderildi ama sonucu bilinmiyor (zaman aşımı, kopan bağlantı, belirsiz sunucu hatası) | Günlüğe yazılır, ama sonradan gönderme onu **hiçbir zaman** otomatik olarak yeniden denemez |
| Sunucu parçayı aldı ve içeriğin kendisini reddetti | Günlüğe yazılmaz; sunucunun bildirdiği asıl neden gösterilir |

Üçüncü satırın nedeni şu: zaman aşımı, Last.fm’in dinlemeyi sakladığı ve yalnızca onayın kaybolduğu anlamına gelebilir. Yeniden denemek elle silinmesi gereken bir kopya oluşturur; bu yüzden belirsiz bir hata hiçbir zaman otomatik olarak yeniden denenmez.

Sonradan gönderme yalnızca **13 gün** geriye uzanır. Bir dinleme bir kez denendikten sonra gerçek zamanlı yol onu bir daha göndermez: dinleme, istek başarılı olduktan *sonra* değil, istek gönderilmeden *önce* denendi olarak işaretlenir; böylece istek sırasında yaşanan bir çökme ikinci bir gönderime yol açamaz.

## 6. Birleştirme nerede yapılır

Last.fm çaların bildirdiğini alır; bu yüzden aynı kişiyi hem `Khalil Fong` hem `方大同` olarak bildiren bir arşiv orada iki sanatçı gösterir.

Lyrimuse içinde dinleme sayıları, listeler ve “N. dinleme” numaraları bunları birleştirir: Geleneksel/Basitleştirilmiş Çince indirgemesi, adların Latin harfli yazımları için takma adlar, katalog eklerinin ayıklanması (`(Remastered 2014)`, `(feat. …)`, `(Explicit)`) ve sanatçı başına bir takma ad tablosu sayesinde. Birleştirme göndermeden önce değil yerelde yapılır, çünkü yerelde yanlış bir birleştirme bir yenilemeyle geri alınır, yanlış bir skroplama ise herkese açık bir sayfada kalıcı bir değişikliktir.

## 7. Sık sorulan sorular

**Lyrimuse’u skroplama olmadan kullanabilir miyim?**
Evet, saptanmış durum budur: Ayarlar → Bağlı Hizmetler’de bir Last.fm hesabı bağlayana kadar hiçbir şey skroplanmaz. Şarkı sözü ve kapak bulmak ayrı bir iştir: bir hesap bağlı olsun ya da olmasın, sanatçı ve parça adını herkese açık şarkı sözü sağlayıcılarına (Netease, QQ, Kugou, LRCLIB, AMLL) gönderir. Bu kaynaklar Ayarlar’da daraltılabilir veya kapatılabilir.

**Neden aynı sanatçı Last.fm profilimde iki kez görünüyor?**
Çalarınız iki farklı ad bildirdi ve ikisi de bildirildiği gibi gönderildi. Lyrimuse bunları kendi istatistiklerinde birleştirir; Last.fm’de birleştirmek için oradaki skroplamaları düzenlemeniz gerekir.

**Adlar göndermeden önce düzeltilebilir mi?**
Hayır. Bunu istiyorsanız işe yarayacak yol otomatik bir sorgu değil, kullanıcının düzenleyebildiği bir kural tablosudur; [Maloja](https://github.com/krateng/maloja) projesinin bunu nasıl yaptığına bakın.

**iPhone’umdaki dinlemeler ne olacak?**
Lyrimuse bunları hiçbir zaman Last.fm’e göndermez; oraya Apple’ın kendi skroplamasıyla ulaşırlar. Lyrimuse bunları geri okur, böylece istatistiklerde Mac’teki dinlemelerle birlikte görünürler.

**Sanatçılar adları yeniden yazmadan Last.fm’de birleştirilebilir mi?**
API üzerinden olmaz. Last.fm’in `mbid` parametresi bir sanatçıyı değil, bir *parçayı* tanımlar; bu yüzden iki adı da olduğu gibi bırakıp “bu iki ad aynı kişi” demeye yarayan bir alan yoktur.

**Yerel dinleme günlüğü skroplamalarımı ikinci kez kaydeder mi?**
Hayır. Bir dinlemeyi yalnızca bağlı bir Last.fm hesabı yoksa veya bir gönderim başarısız olduysa kaydeder. Last.fm bağlı ve sorunsuz çalışıyorsa günlük boş kalır.

---

*Kaynak kodu: [`lyrimuse-engine/lastfm.go`](../lyrimuse-engine/lastfm.go)
(`resolveScrobbleArtist`, `scrobble`, `updateNowPlaying`),
[`lyrimuse-engine/poller.go`](../lyrimuse-engine/poller.go)
(`listenThreshold`, `recordFailedMirror`).*
