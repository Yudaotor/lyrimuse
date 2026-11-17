# Lyrimuse URL şeması

*[English](url-scheme.md) · [简体中文](url-scheme.zh-CN.md) · [日本語](url-scheme.ja.md) · [한국어](url-scheme.ko.md) · [Español](url-scheme.es.md) · [Français](url-scheme.fr.md) · [Deutsch](url-scheme.de.md) · [Italiano](url-scheme.it.md) · [Português (Brasil)](url-scheme.pt-BR.md) · [Tiếng Việt](url-scheme.vi.md) · [Русский](url-scheme.ru.md) · [Українська](url-scheme.uk.md) · [ไทย](url-scheme.th.md) · **Türkçe** · [हिन्दी](url-scheme.hi.md)*

`lyrimuse://` ile başlayan bağlantılarla Lyrimuse’u Kestirmeler, Raycast, Alfred, Stream Deck, Terminal (`open 'lyrimuse://…'`) ve benzeri araçlardan denetleyebilirsiniz: pencereleri ve ayar sayfalarını açabilir, şarkı sözlerini gösterip gizleyebilir, oynatmayı denetleyebilir, zamanlamayı kaydırabilir veya şu an çalınanı alabilirsiniz.

Sık kullanılanları Ayarlar › Klavye Kestirmeleri sayfasının altındaki **Derin Bağlantılar** bölümünden kopyalayabilirsiniz. Oradaki herhangi bir kestirmenin üzerine gelerek o eylemin bağlantısını kopyalayın.

## Genel kurallar

- Bağlantılarda büyük/küçük harf ayrımı yapılmaz.
- Lyrimuse’un tanımadığı bir bağlantı hiçbir şey yapmaz ve “Tanınmayan bağlantı” iletisini gösterir.
- Pencere açan her bağlantı `background=1` parametresini kabul eder: pencere görünür, ancak Lyrimuse öne gelmez ve klavye odağını almaz. Örneğin `lyrimuse://lyrics-window?background=1`.
- Aç/kapat eylemleri, hedef durumu belirlemek için `on=1` veya `on=0` kabul eder (`true` / `false` ve `on` / `off` da çalışır); böylece iki kez çalıştırmak aynı sonucu verir. Bu parametre olmadan durumu tersine çevirirler.
- Web sayfaları da `lyrimuse://` bağlantılarını açabilir (tarayıcınız önce sorar). Bu yüzden yalnızca kolayca geri alınabilen eylemler sunulur: aç/kapat, pencere açma, oynatma denetimi ve zamanlama kaydırma. Hiçbiri şarkı sözlerini silmez veya düzenlemez, hesaplarınıza da dokunmaz.

## Pencereleri açma

| Bağlantı | Ne yapar |
|---|---|
| `lyrimuse://lyrics-window` | Şarkı sözü penceresini açar |
| `lyrimuse://lyrics-window/search` | Şarkı sözü penceresini ve “Şarkı Sözü Ara” penceresini açar (`lyrics-search` ile açılanla aynı pencere) |
| `lyrimuse://lyrics-manager` | Şarkı Sözü Yöneticisi’ni açar |
| `lyrimuse://lyrics-search` | Çalan parça için “Şarkı Sözü Ara” penceresini açar |
| `lyrimuse://menubar-panel` | Menü çubuğu panelini açar veya kapatır |
| `lyrimuse://menubar-panel?quick=overlay` | Menü çubuğu panelini bir kutucuğun hızlı ayarlarıyla açar (yalnızca açar, hiçbir zaman kapatmaz). `quick` şunlardan biridir: `overlay`, `notch`, `menubar`, `touchbar`, `lyrics-window`, `lyrics-manager`, `translation`, `romanization`, `overlay-font`, `lyrics-offset`, `lock-position`, `mini-window`, `volume` |
| `lyrimuse://menubar-menu` | Menü çubuğu simgesinin menüsünü açar |
| `lyrimuse://onboarding` | Kurulum kılavuzunu açar |
| `lyrimuse://whats-new` | Yüklü sürümdeki yenilikleri gösterir |

## Ayarları açma

`lyrimuse://settings` Ayarlar’ı açar. Doğrudan bir sayfaya gitmek için bir yol, o sayfadaki bir bölüme gitmek için yola bir öğe daha ekleyin.

| Yol | Sayfa | Bölümler |
|---|---|---|
| `/lyrics` | Şarkı Sözleri | `/fetch` veya `/sources` Kaynak, `/translation` veya `/language` Dil, `/display` veya `/timing` Zamanlama, `/manage` veya `/library` Şarkı Sözü Arşivi |
| `/player` | Çalar | `/players` Çalar, `/linkage` Açılış ve Çıkış, `/permissions` İzinler ve Hizmetler |
| `/appearance` | Şarkı Sözü Görünümü | `/overlay` Yüzen Sözler, `/notch` Çentik, `/menu-bar` Menü Çubuğu, `/touch-bar` Touch Bar, `/lyrics-window` Şarkı Sözü Penceresi |
| `/shortcuts` | Klavye Kestirmeleri | — |
| `/general` | Genel | — |
| `/about` | Hakkında | — |
| `/account/lastfm` | Last.fm | `/stats` İstatistikler, `/chart` Listeler, `/on-this-day` Geçmişe Bakış, `/settings` Kurallar |
| `/account/listenbrainz` | ListenBrainz | — |
| `/account/discord` | Discord | `/display` Gösterilenler, `/buttons` Düğmeler, `/privacy` Gizlilik |
| `/account/relay` | Web Anlık Bildirimleri | — |
| `/account/bark` | Anlık Bildirimler | — |
| `/software-update` | Yazılım Güncelleme | Güncellemeleri de denetlemek için `?check=1` ekleyin |
| `/lastfm-suggestions` | Last.fm Hesap Önerileri | — |
| `/labs` | Deneysel | — |

Örneğin `lyrimuse://settings/appearance/overlay` veya `lyrimuse://settings/software-update?check=1`. Bilinmeyen bir yol yalnızca Ayarlar’ı açar; bilinmeyen bir bölüm ise sayfayı en son baktığınız bölümde açar.

## Eylemler: `lyrimuse://action/<name>`

Bunlar Ayarlar › Klavye Kestirmeleri’ndeki klavye kestirmeleriyle aynı eylemlerdir. Aynı kodu çalıştırır ve aynı geri bildirimi gösterirler.

### Görüntüleme

| Ad | Ne yapar | Parametreler |
|---|---|---|
| `toggle-overlay` | Yüzen şarkı sözlerini gösterir veya gizler | `on` |
| `toggle-notch` | Çentik sözlerini gösterir veya gizler | `on` |
| `peek-notch` | Çentik sözlerini birkaç saniyeliğine genişletir; erken kapatmak için yeniden çalıştırın | — |
| `toggle-menubar-lyrics` | Menü çubuğu sözlerini gösterir veya gizler | `on` |
| `toggle-touchbar` | Touch Bar sözlerini genişletir veya daraltır (yalnızca Touch Bar’lı Mac’lerde) | — |
| `toggle-all-lyrics` | Tüm şarkı sözlerini gizler: yüzen sözler, çentik sözleri ve menü çubuğu sözlerinden hangileri açıksa gizlenir; yeniden çalıştırmak tam olarak bunları geri getirir | `on` (`0` gizler, `1` geri getirir) |
| `toggle-lock-position` | Yüzen şarkı sözlerinin konumunu kilitler veya kilidini açar | `on` |
| `toggle-translation` | Çevirileri gösterir veya gizler | `on` |
| `toggle-romanization` | Telaffuzu gösterir veya gizler | `on` |
| `overlay-font-larger` | Yüzen şarkı sözlerini büyütür | — |
| `overlay-font-smaller` | Yüzen şarkı sözlerini küçültür | — |

### Pencereler

| Ad | Ne yapar | Parametreler |
|---|---|---|
| `open-lyrics-manager` | Şarkı Sözü Yöneticisi’ni açar | — |
| `open-lyrics-window` | Şarkı sözü penceresini açar | — |
| `toggle-lyrics-window-mini` | Şarkı sözü penceresini mini ve tam boyut arasında değiştirir; pencere kapalıysa mini boyutta açar | `on` (`1` mini, `0` tam boyut) |
| `search-lyrics` | “Şarkı Sözü Ara” penceresini açar | — |
| `open-settings` | Ayarlar’ı açar | — |
| `open-player` | Kullandığınız çaları öne getirir | — |
| `toggle-menubar-panel` | Menü çubuğu simgesini tıklamak gibi menü çubuğu panelini açar veya kapatır | — |

### Şarkı sözü zamanlaması

| Ad | Ne yapar | Parametreler |
|---|---|---|
| `lyrics-advance` | Bu parçanın şarkı sözlerini bir adım öne alır | `step`: bu kaydırmanın saniye cinsinden miktarı (0 ile 5 arası); verilmezse Ayarlar’daki adım kullanılır |
| `lyrics-delay` | Bu parçanın şarkı sözlerini bir adım geriye alır | `step`, yukarıdaki gibi |
| `lyrics-offset-reset` | Bu parçanın şarkı sözü kaydırmasını sıfırlar | — |

### Oynatma

| Ad | Ne yapar | Parametreler |
|---|---|---|
| `play-pause` | Çal / duraklat | — |
| `next-track` | Sonraki parça | — |
| `previous-track` | Önceki parça | — |
| `toggle-favorite` | Çalan parçayı favorilere ekler veya favorilerden çıkarır (çalar destekliyorsa) | `on` (`1` ekler, `0` çıkarır) |

Örneğin `lyrimuse://action/toggle-overlay?on=0` veya `lyrimuse://action/lyrics-advance?step=0.5`.

### Diğer eylemler

| Bağlantı | Ne yapar |
|---|---|
| `lyrimuse://action/copy-lyric` | Geçerli şarkı sözü satırını panoya kopyalar; çeviriyi de eklemek için `?translation=1` ekleyin |
| `lyrimuse://action/surfaces?overlay=1&notch=0&menubar=1` | Hangi şarkı sözlerinin gösterileceğini tek seferde ayarlar: `overlay` (yüzen sözler), `notch`, `menubar`; her biri göstermek için `1`, gizlemek için `0`. Yalnızca değiştirmek istediklerinizi yazın |
| `lyrimuse://action/lyrics-offset?ms=-300` | Bu parçanın şarkı sözü kaydırmasını milisaniye cinsinden tam bir değere ayarlar: pozitif değer öne, negatif değer geriye alır; aralık ±10000 |
| `lyrimuse://action/play-mode?mode=shuffle` | Çalma modunu ayarlar: `mode` değeri `list`, `shuffle`, `repeat-all` veya `repeat-one` olur. Çaların desteklemediği modlarda `list` kullanılır |

## Şu an çalınanı alma (x-callback-url)

```
lyrimuse://x-callback-url/now-playing?x-success=<callback URL>
```

Lyrimuse, şu an çalınanı parametre olarak ekleyip `x-success` URL’sini açar (`x-success` üzerinde zaten bulunan parametreler korunur):

| Parametre | Değer |
|---|---|
| `title` | Parça adı |
| `artist` | Sanatçı |
| `album` | Albüm |
| `lyric` | Geçerli şarkı sözü satırı |
| `player` | Çalar adı |
| `playing` | Bir şey çalarken `1`, duraklatıldığında veya hiçbir şey yüklü değilken `0` (hiçbir şey yüklü değilken yukarıdaki alanlar boştur) |

Kestirmeler’de **X-Callback URL’yi Aç** eylemini kullanın ve URL olarak `lyrimuse://x-callback-url/now-playing` girin. Kestirmeler `x-success` parametresini kendisi ekler; döndürülen parametreler eylemin çıktısı olur.

Web sayfalarının bu bağlantıyla ne dinlediğinizi görememesi için geri çağırma URL’sine iki sınır konur: web, dosya veya betik URL’si olamaz (`http`, `https`, `file`, `ftp`, `javascript`, `data`, `about`, `blob` ya da `lyrimuse`’un kendisi) ve Mac’inizde tarayıcı olmayan bir uygulama tarafından açılmalıdır. Aksi takdirde hiçbir şey geri gönderilmez.
