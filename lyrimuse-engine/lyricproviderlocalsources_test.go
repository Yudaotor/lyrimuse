package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// Spotify / Amazon Music 本地歌词、正在放的文件旁的歌词、洛雪、导入库接到 LyricProvider 之后的新旧对拍(夹具在
// lyricproviderlocal_test.go)。本机数据全是用例在临时目录里造的。见 09 章决策 395。

// localParityEnrichCache 把歌词缓存换成 entries(测完换回),几路本机来源按缓存条目里存的编号认这一首。
func localParityEnrichCache(t *testing.T, entries map[string]enrichEntry) {
	t.Helper()
	enrichMu.Lock()
	saved := enrichCache
	enrichCache = entries
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichCache = saved
		enrichMu.Unlock()
	})
}

// localPromoTitle:带宣传尾段的歌名,检索词里尾段会被去掉(searchQueryFields),本机来源要按原样的认。
const localPromoTitle = "如果可以 - 電影《月老》主題曲"

// localPromoQuery:原样标签是「韋禮安 / localPromoTitle / album」时这一轮的检索词,和挂着原样写法的 ctx。
func localPromoQuery(t *testing.T, album string) (artist, title, queryAlbum string, ctx func(context.Context) context.Context) {
	t.Helper()
	artist, title, queryAlbum = searchQueryFields("韋禮安", localPromoTitle, album)
	if title == localPromoTitle {
		t.Fatal("这个用例要检索词跟原样标签不一样")
	}
	return artist, title, queryAlbum, func(ctx context.Context) context.Context {
		return withSearchQueryOriginal(ctx, "韋禮安", localPromoTitle, album)
	}
}

// ---- Spotify 本地歌词(连同播放器自己的无人声信号) ----

// spotifyParityData:一个场景里 Spotify 的本机数据。曲目一律是 testSpotifyID(1)。
type spotifyParityData struct {
	// player:当前播放器的 bundle id。
	player string
	// hint:换曲那一拍记下了这首的曲目 id。
	hint bool
	// lyrics:歌词缓存里这首的应答体;空 = 缓存里没有这首。rawCache 非 nil 时缓存条目原样写这些字节。
	lyrics   string
	rawCache []byte
	// meta:元数据缓存里有这首的歌名、歌手、专辑、时长。
	meta bool
	// languages:非 nil 时元数据缓存里这条曲目带这几种演唱语言(zxx = 没有人声)。
	languages []string
	// cacheAlbum:非空时歌词缓存条目里存着这首的曲目 id,那一条的专辑是它。
	cacheAlbum string
}

func (d spotifyParityData) prepare(artist, title, album string) func(t *testing.T) {
	return func(t *testing.T) {
		t.Helper()
		id, _ := testSpotifyID(1)
		meta := map[int]testSpotifyMeta{}
		if d.meta {
			meta[1] = testSpotifyMeta{title: "Shape of You", album: "÷ (Deluxe)", artists: []string{"Ed Sheeran"}, ms: 233712}
		}
		newTestSpotifyEnv(t, testSpotifyState([][]int{{1}}, 1), meta)
		if d.languages != nil {
			testWriteTable(t, filepath.Join(spotifyActiveUserDir(), "primary.ldb", "000002.ldb"), []testLDBEntry{
				{key: string(spotifyXmetaKey(spotifyTrackKind, id)), seq: 1000, value: string(testSpotifyTrackWithLanguages(d.languages...))},
			}, 2, true)
		}
		dir := t.TempDir()
		useSpotifyLyricsCacheDir(t, dir)
		entry := d.rawCache
		if entry == nil && d.lyrics != "" {
			entry = spotifySimpleCacheEntry(spotifyLyricsKey(id), gzipBytes(t, d.lyrics))
		}
		if entry != nil {
			if err := os.WriteFile(filepath.Join(dir, "aaaaaaaaaaaaaaaa_0"), entry, 0o600); err != nil {
				t.Fatal(err)
			}
		}
		entries := map[string]enrichEntry{}
		if d.cacheAlbum != "" {
			entries[enrichKey(artist, title, d.cacheAlbum)] = enrichEntry{SpotifyTrackID: id}
		}
		localParityEnrichCache(t, entries)
		enrichMu.Lock()
		savedHints, savedLast := spotifyTrackIDHints, spotifyTrackIDLastKey
		spotifyTrackIDHints, spotifyTrackIDLastKey = map[string]string{}, ""
		enrichMu.Unlock()
		t.Cleanup(func() {
			enrichMu.Lock()
			spotifyTrackIDHints, spotifyTrackIDLastKey = savedHints, savedLast
			enrichMu.Unlock()
		})
		withCleanPlaybackHints(t)
		if d.hint {
			noteSpotifyTrackID(artist, title, album, id)
		}
		setNativeLyricSourcesForPlayer(d.player)
		t.Cleanup(func() { setNativeLyricSourcesForPlayer("") })
	}
}

func TestSpotifyLocalProviderMatchesHandwrittenRead(t *testing.T) {
	const artist, title, album, secs = "Ed Sheeran", "Shape of You", "÷ (Deluxe)", 233.7
	const lrc = "[00:14.98]First line\n[00:20.50]\n[01:01.23]Second line\n[02:05.00]Third line\n"
	on := func(d spotifyParityData) func(t *testing.T) { return d.prepare(artist, title, album) }
	withLyrics := spotifyParityData{player: spotifyBundleID, hint: true, lyrics: spotifyLyricsTestJSON}
	noVocals := func(player string, lyrics string) spotifyParityData {
		return spotifyParityData{player: player, hint: true, lyrics: lyrics, languages: []string{"zxx"}}
	}
	signal := func(want bool) func(t *testing.T, r lyricSourceResult) {
		return func(t *testing.T, r lyricSourceResult) {
			t.Helper()
			if r.noVocals != want || r.forPlayingTrack != want {
				t.Errorf("播放器无人声信号(应是 %v)跟场景不符:%+v", want, r)
			}
		}
	}
	promoArtist, promoTitle, promoAlbum, promoCtx := localPromoQuery(t, "如果可以")
	runLocalParity(t, spotifyLocalLyricsSource, nil, []localParityCase{
		{
			name: "命中:换曲时记下了曲目 id,缓存里有歌词,没有元数据", artist: artist, title: title, album: album, durationSecs: secs,
			prepare: on(withLyrics), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				want := lyricSourceResult{source: spotifyLocalLyricsSource, lyr: lrc, matchTitle: title, matchArtist: artist, matchAlbum: album}
				if !reflect.DeepEqual(r, want) {
					t.Errorf("结果 %+v\n期望 %+v", r, want)
				}
			},
		},
		{
			name: "命中:歌名歌手专辑时长用元数据缓存里的", artist: "ed sheeran", title: "shape of you", album: "divide", durationSecs: secs,
			prepare: spotifyParityData{player: spotifyBundleID, hint: true, lyrics: spotifyLyricsTestJSON, meta: true}.prepare("ed sheeran", "shape of you", "divide"), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				if r.matchTitle != "Shape of You" || r.matchArtist != "Ed Sheeran" || r.matchAlbum != "÷ (Deluxe)" || r.srcDur != 233.712 || r.identityFromLocalClient {
					t.Errorf("元数据应取自 Spotify 的缓存,不带本机身份:%+v", r)
				}
			},
		},
		{name: "不看当前播放器:用 KKBOX 放时照样读", artist: artist, title: title, album: album, prepare: on(spotifyParityData{player: kkboxBundleID, hint: true, lyrics: spotifyLyricsTestJSON}), present: true, check: signal(false)},
		{
			name: "曲目 id 取自歌词缓存条目:专辑填那一条的", artist: artist, title: title, album: "另一张专辑",
			prepare: on(spotifyParityData{player: spotifyBundleID, lyrics: spotifyLyricsTestJSON, cacheAlbum: "÷"}), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				if r.matchAlbum != "÷" {
					t.Errorf("专辑应填曲目 id 所属的那一条的:%+v", r)
				}
			},
		},
		{
			name: "曲目 id 取自歌词缓存条目:专辑一致的那条", artist: artist, title: title, album: album,
			prepare: on(spotifyParityData{player: spotifyBundleID, lyrics: spotifyLyricsTestJSON, cacheAlbum: album}), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				if r.matchAlbum != album {
					t.Errorf("专辑 %q", r.matchAlbum)
				}
			},
		},
		{name: "没记过曲目 id:没有", artist: artist, title: title, album: album, prepare: on(spotifyParityData{player: spotifyBundleID, lyrics: spotifyLyricsTestJSON})},
		{name: "有曲目 id、缓存里没有这首的歌词:没有", artist: artist, title: title, album: album, prepare: on(spotifyParityData{player: spotifyBundleID, hint: true})},
		{
			name: "歌词缓存条目损坏:没有", artist: artist, title: title, album: album,
			prepare: on(spotifyParityData{player: spotifyBundleID, hint: true, rawCache: spotifySimpleCacheEntry(spotifyLyricsKey("0000000000000000000001"), []byte("not gzip, not json"))}),
		},
		{
			name: "歌词不够句数:没有", artist: artist, title: title, album: album,
			prepare: on(spotifyParityData{player: spotifyBundleID, hint: true, lyrics: `{"lyrics":{"syncType":"LINE_SYNCED","lines":[{"startTimeMs":"1000","words":"only"}]}}`}),
		},
		{
			name: "无人声:正用 Spotify 放、缓存里没有歌词,只交信号", artist: artist, title: title, album: album, prepare: on(noVocals(spotifyBundleID, "")), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				want := lyricSourceResult{source: spotifyLocalLyricsSource, noVocals: true, identityFromLocalClient: true, forPlayingTrack: true}
				if !reflect.DeepEqual(r, want) {
					t.Errorf("结果 %+v\n期望 %+v", r, want)
				}
			},
		},
		{
			name: "无人声:缓存里也有歌词,两样都交", artist: artist, title: title, album: album, prepare: on(noVocals(spotifyBundleID, spotifyLyricsTestJSON)), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				signal(true)(t, r)
				if r.lyr != lrc || !r.identityFromLocalClient {
					t.Errorf("歌词和信号都该在:%+v", r)
				}
			},
		},
		{name: "元数据说有人声:不交信号", artist: artist, title: title, album: album, prepare: on(spotifyParityData{player: spotifyBundleID, hint: true, languages: []string{"en"}})},
		{name: "无人声位有、不是 Spotify 在放:不交信号", artist: artist, title: title, album: album, prepare: on(noVocals(kkboxBundleID, ""))},
		{name: "无人声位有、不是 Spotify 在放:只交歌词", artist: artist, title: title, album: album, prepare: on(noVocals(appleMusicBundleID, spotifyLyricsTestJSON)), present: true, check: signal(false)},
		{name: "无人声位有、手动搜索:不交信号", ctx: localManualRound, artist: artist, title: title, album: album, prepare: on(noVocals(spotifyBundleID, ""))},
		{name: "无人声位有、后台轮次:不交信号", ctx: localBackgroundRound, artist: artist, title: title, album: album, prepare: on(noVocals(spotifyBundleID, ""))},
		{
			name:   "无人声位有、待播队列里的一首:交信号",
			ctx:    func(ctx context.Context) context.Context { return withPlayerQueueTrack(withBackgroundOutbound(ctx)) },
			artist: artist, title: title, album: album, prepare: on(noVocals(spotifyBundleID, "")), present: true, check: signal(true),
		},
		{
			name: "无人声、别的歌那一轮:信号在,身份不算播放器给定", ctx: localOtherTrackRound, artist: artist, title: title, album: album,
			prepare: on(noVocals(spotifyBundleID, "")), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				signal(true)(t, r)
				localIdentityNotGiven(t, r)
			},
		},
		{name: "别名轮不读,无人声信号也不交", ctx: localAliasRound, artist: artist, title: title, album: album, prepare: on(noVocals(spotifyBundleID, spotifyLyricsTestJSON))},
		{name: "带「只查这些源」名单的首轮照样读", ctx: localOnlyListRound, artist: artist, title: title, album: album, prepare: on(noVocals(spotifyBundleID, spotifyLyricsTestJSON)), present: true, check: signal(true)},
		{
			name: "按播放器原样标签认,不按检索词", ctx: promoCtx, artist: promoArtist, title: promoTitle, album: promoAlbum,
			prepare: spotifyParityData{player: spotifyBundleID, hint: true, lyrics: spotifyLyricsTestJSON, languages: []string{"zxx"}}.prepare("韋禮安", localPromoTitle, "如果可以"), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				signal(true)(t, r)
				if r.lyr != lrc {
					t.Errorf("应按原样标签认到曲目 id:%+v", r)
				}
			},
		},
	})
}

// ---- Amazon Music 本地歌词 ----

// amazonParityCatalog:目录缓存里一条曲目的值。
func amazonParityCatalog(asin, title, album, dur string) string {
	return "\x16\x00\x00\x00\x00\x00\x00\x00serialization::archive\x13\x00\x04\x08\x04\x08\x01\x00\x00\x00" +
		`{"id":"","uniqueId":"` + asin + `","asin":"` + asin + `","title":"` + title + `","duration":"` + dur + `","hasLyrics":true,` +
		`"album":{"name":"` + album + `","asin":"B0TESTALB9","image":""},"artist":{"name":"Khalil Fong","asin":"B0TESTART9"}}`
}

// amazonParityLyrics:Hammer Cache 里一份歌词的值,lines 是「开始毫秒、歌词」两个一组。
func amazonParityLyrics(asin string, lines ...any) string {
	var b strings.Builder
	for i := 0; i+1 < len(lines); i += 2 {
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, `{"startTime":%d,"endTime":%d,"text":%q}`, lines[i], lines[i].(int)+1000, lines[i+1])
	}
	return "\x16\x00\x00\x00\x00\x00\x00\x00serialization::archive\x0f\x00\x04\x08\x04\x08\x01\x00\x00\x00\xe1\x0c\x00\x00\x00\x00\x00\x00" +
		`{"lrcSource":"AMAZON_INTERNAL","lyricsResponseCode":1002,"lyricsSource":"LYRIC_FIND","lyrics":{"lines":[` + b.String() + `]},` +
		`"trackAsinAndMarketplace":{"asin":"` + asin + `","marketplaceId":"ATVPDKIKX0DER"}}`
}

// amazonParityData:一个场景里 Amazon Music 的本机数据。useTempAmazonData 自带 B0TESTAAA2(目录里歌名
// 「I Can't Love You Anymore [Explicit]」、229 秒、有歌词)。
type amazonParityData struct {
	player string
	// currentASIN:App 报的当前曲目的 ASIN(歌手歌名就是这一轮问的);空 = App 没报。
	currentASIN string
	// catalog / hammer:另外往目录缓存、Hammer Cache 里写的条目(键、值两个一组)。
	catalog, hammer []string
	// cached:歌词缓存里记着 Amazon 曲目页的条目,专辑 → ASIN。
	cached map[string]string
	// goneData:两个库目录都指到不存在的路径。
	goneData bool
}

func (d amazonParityData) prepare(artist, title string) func(t *testing.T) {
	return func(t *testing.T) {
		t.Helper()
		localStorage, hammer := useTempAmazonData(t)
		write := func(dir, name string, kv []string) {
			if len(kv) == 0 {
				return
			}
			var entries []testLDBEntry
			for i := 0; i+1 < len(kv); i += 2 {
				entries = append(entries, testLDBEntry{key: kv[i], seq: uint64(100 + i), value: kv[i+1]})
			}
			testWriteLog(t, filepath.Join(dir, name), [][]testLDBEntry{entries})
		}
		write(localStorage, "000016.log", d.catalog)
		write(hammer, "000012.log", d.hammer)
		if d.goneData {
			amazonLocalStorageOverride, amazonHammerCacheOverride = localStorage+"-gone", hammer+"-gone"
		}
		entries := map[string]enrichEntry{}
		for album, asin := range d.cached {
			entries[enrichKey(artist, title, album)] = enrichEntry{AmazonURL: amazonTrackURL("asin://" + asin)}
		}
		localParityEnrichCache(t, entries)
		amazonCachedASINsMu.Lock()
		amazonCachedASINs = nil
		amazonCachedASINsMu.Unlock()
		amazonQueueMu.Lock()
		savedASINs, savedAlbums := amazonQueueASINs, amazonQueueAlbums
		amazonQueueASINs, amazonQueueAlbums = map[string]string{}, map[string]string{}
		amazonQueueMu.Unlock()
		amazonCurrentMu.Lock()
		savedCur := amazonCurrentTrack
		amazonCurrentMu.Unlock()
		t.Cleanup(func() {
			amazonCurrentMu.Lock()
			amazonCurrentTrack = savedCur
			amazonCurrentMu.Unlock()
			amazonQueueMu.Lock()
			amazonQueueASINs, amazonQueueAlbums = savedASINs, savedAlbums
			amazonQueueMu.Unlock()
			amazonCachedASINsMu.Lock()
			amazonCachedASINs = nil
			amazonCachedASINsMu.Unlock()
			setNativeLyricSourcesForPlayer("")
		})
		trackID := ""
		if d.currentASIN != "" {
			trackID = "asin://" + d.currentASIN
		}
		noteAmazonCurrentTrack(amazonMusicBundleID, artist, title, trackID)
		setNativeLyricSourcesForPlayer(d.player)
	}
}

func TestAmazonLocalProviderMatchesHandwrittenRead(t *testing.T) {
	const artist, title = "Ella Langley & Morgan Wallen", "I Can't Love You Anymore"
	on := func(d amazonParityData) func(t *testing.T) { return d.prepare(artist, title) }
	current := amazonParityData{player: amazonMusicBundleID, currentASIN: "B0TESTAAA2"}
	borrowed := amazonParityData{
		player: amazonMusicBundleID, currentASIN: "B0TESTAI01",
		catalog: []string{amazonCatalogKeyPrefix + "B0TESTAI01", amazonParityCatalog("B0TESTAI01", "Ai!", "This Love", "221")},
		hammer:  []string{"B0TESTAI01-ATVPDKIKX0DER", strings.Replace(amazonTestLyricsJSON, "B0TESTAAA2", "B0TESTAI01", 1)},
	}
	twoVersions := amazonParityData{
		player: amazonMusicBundleID, cached: map[string]string{"I Can't Love You Anymore": "B0TESTAAA2", "Greatest Hits": "B0TESTGH01"},
		hammer: []string{"B0TESTGH01-ATVPDKIKX0DER", amazonParityLyrics("B0TESTGH01", 1500, "greatest one", 2500, "greatest two", 3500, "greatest three")},
	}
	promoArtist, promoTitle, _, promoCtx := localPromoQuery(t, "")
	runLocalParity(t, amazonLocalLyricsSource, nil, []localParityCase{
		{
			name: "命中:App 报的当前曲目就是这首,目录里有它", artist: artist, title: title, prepare: on(current), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				localIdentityGiven(t, r)
				if r.matchTitle != "I Can't Love You Anymore [Explicit]" || r.matchArtist != artist || r.matchAlbum != "I Can't Love You Anymore" || r.srcDur != 229 ||
					r.matchCover != "https://m.media-amazon.com/images/I/5194nbHWBoL._SX500_.jpg" || !strings.Contains(r.lyr, "nightstand") {
					t.Errorf("歌名、专辑、时长、封面应取自目录缓存:%+v", r)
				}
			},
		},
		{
			name: "命中:目录里没有这首,歌名歌手用播放器报的", artist: artist, title: title, present: true,
			prepare: on(amazonParityData{player: amazonMusicBundleID, currentASIN: "B0TESTNOCA",
				hammer: []string{"B0TESTNOCA-ATVPDKIKX0DER", amazonParityLyrics("B0TESTNOCA", 1500, "one", 2500, "two", 3500, "three")}}),
			check: func(t *testing.T, r lyricSourceResult) {
				localIdentityGiven(t, r)
				want := lyricSourceResult{source: amazonLocalLyricsSource, lyr: "[00:01.50]one\n[00:02.50]two\n[00:03.50]three\n", matchTitle: title, matchArtist: artist, identityFromLocalClient: true}
				if !reflect.DeepEqual(r, want) {
					t.Errorf("结果 %+v\n期望 %+v", r, want)
				}
			},
		},
		{
			name: "每一句都是整秒:不算本机身份", artist: artist, title: title, present: true,
			prepare: on(amazonParityData{player: amazonMusicBundleID, currentASIN: "B0TESTCOAR",
				hammer: []string{"B0TESTCOAR-ATVPDKIKX0DER", amazonParityLyrics("B0TESTCOAR", 1000, "one", 2000, "two", 3000, "three")}}),
			check: localIdentityNotGiven,
		},
		{name: "正文跟另一首一字不差:照给候选,不算本机身份", artist: "Khalil Fong", title: "Ai!", prepare: borrowed.prepare("Khalil Fong", "Ai!"), present: true, check: localIdentityNotGiven},
		{name: "认得出 ASIN、缓存里没有它的歌词:没有", artist: artist, title: title, prepare: on(amazonParityData{player: amazonMusicBundleID, currentASIN: "B0MISSING0"})},
		{name: "认不出 ASIN:没有", artist: artist, title: title, prepare: on(amazonParityData{player: amazonMusicBundleID})},
		{name: "不是 Amazon Music 在放:不读", artist: artist, title: title, prepare: on(amazonParityData{player: spotifyBundleID, currentASIN: "B0TESTAAA2"})},
		{
			name: "歌词条目损坏:没有", artist: artist, title: title,
			prepare: on(amazonParityData{player: amazonMusicBundleID, currentASIN: "B0TESTBAD1", hammer: []string{"B0TESTBAD1-ATVPDKIKX0DER", "\x16\x00garbage{not json"}}),
		},
		{name: "库目录读不到:没有", artist: artist, title: title, prepare: on(amazonParityData{player: amazonMusicBundleID, currentASIN: "B0TESTAAA2", goneData: true})},
		{
			name: "ASIN 取自歌词缓存条目", artist: artist, title: title, album: "随便哪张", present: true,
			prepare: on(amazonParityData{player: amazonMusicBundleID, cached: map[string]string{"I Can't Love You Anymore": "B0TESTAAA2"}}), check: localIdentityGiven,
		},
		{
			name: "缓存里记着两版:按专辑认到精选集那一版", artist: artist, title: title, album: "Greatest Hits", prepare: on(twoVersions), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				if !strings.Contains(r.lyr, "greatest one") {
					t.Errorf("应认到精选集那一版:%+v", r)
				}
			},
		},
		{
			name: "缓存里记着两版:按专辑认到单曲那一版", artist: artist, title: title, album: "I Can't Love You Anymore", prepare: on(twoVersions), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				if !strings.Contains(r.lyr, "nightstand") {
					t.Errorf("应认到单曲那一版:%+v", r)
				}
			},
		},
		{name: "缓存里记着两版、专辑对不上:没有", artist: artist, title: title, album: "Some Other Album", prepare: on(twoVersions)},
		{
			name: "按播放器原样标签认,不按检索词", ctx: promoCtx, artist: promoArtist, title: promoTitle, present: true,
			prepare: amazonParityData{player: amazonMusicBundleID, currentASIN: "B0TESTAAA2"}.prepare("韋禮安", localPromoTitle), check: localIdentityGiven,
		},
		{name: "别名轮不读", ctx: localAliasRound, artist: artist, title: title, prepare: on(current)},
		{name: "带「只查这些源」名单的首轮照样读", ctx: localOnlyListRound, artist: artist, title: title, prepare: on(current), present: true, check: localIdentityGiven},
		{name: "别的歌那一轮:读到,身份不算播放器给定", ctx: localOtherTrackRound, artist: artist, title: title, prepare: on(current), present: true, check: localIdentityNotGiven},
	})
}

// ---- 正在放的文件旁的歌词 ----

// localFileParityData:一个场景里正在放的那个本地文件。
type localFileParityData struct {
	// player:当前播放器的 bundle id;noted:App 报「正在放这个文件」用的播放器(空 = 同 player)。
	player, noted string
	// audio:音频文件的内容(标签);nil = 一个字节的假文件。
	audio []byte
	// sidecar:同名 .lrc 的内容;nil = 没有这个文件。
	sidecar []byte
	// goneDir:App 报的文件在一个不存在的目录里。
	goneDir bool
}

func (d localFileParityData) prepare(artist, title string) func(t *testing.T) {
	return func(t *testing.T) {
		t.Helper()
		dir := t.TempDir()
		audio := filepath.Join(dir, "Song.mp3")
		body := d.audio
		if body == nil {
			body = []byte{0}
		}
		if err := os.WriteFile(audio, body, 0o644); err != nil {
			t.Fatal(err)
		}
		if d.sidecar != nil {
			if err := os.WriteFile(filepath.Join(dir, "Song.lrc"), d.sidecar, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		if d.goneDir {
			audio = filepath.Join(dir, "gone", "Song.mp3")
		}
		noted := d.noted
		if noted == "" {
			noted = d.player
		}
		noteLocalFileCurrentTrack(noted, artist, title, audio)
		setNativeLyricSourcesForPlayer(d.player)
		t.Cleanup(func() {
			noteLocalFileCurrentTrack("", "", "", "")
			setNativeLyricSourcesForPlayer("")
		})
	}
}

func TestLocalFileProviderMatchesHandwrittenRead(t *testing.T) {
	const artist, title, secs = "Hawk Nelson", "Sold Out", 201.5
	const timed = "[00:01.00]I'm sold out\n[00:05.00]second line\n"
	// 双语行:同一个时间戳下原文、译文各一行,原样交给排序层(烘入译文在那边摘)。
	const bilingual = "[00:01.00]I'm sold out\n[00:01.00]我卖光了\n[00:05.00]second line\n[00:05.00]第二句\n"
	on := func(d localFileParityData) func(t *testing.T) { return d.prepare(artist, title) }
	sidecar := localFileParityData{player: reampBundleID, sidecar: []byte(timed)}
	embedded := func(text string) []byte {
		return append(id3Tag(3, id3Frame(3, "USLT", usltBody(3, []byte(text)))), 0xFF, 0xFB)
	}
	promoArtist, promoTitle, _, promoCtx := localPromoQuery(t, "")
	runLocalParity(t, localFileLyricsSource, nil, []localParityCase{
		{
			name: "命中:同名 .lrc", artist: artist, title: title, durationSecs: secs, prepare: on(sidecar), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				want := lyricSourceResult{source: localFileLyricsSource, lyr: timed, matchTitle: title, matchArtist: artist, srcDur: secs, identityFromLocalClient: true}
				if !reflect.DeepEqual(r, want) {
					t.Errorf("结果 %+v\n期望 %+v", r, want)
				}
			},
		},
		{
			name: "同名 .lrc 是双语行:两行都原样交", artist: artist, title: title, durationSecs: secs,
			prepare: on(localFileParityData{player: reampBundleID, sidecar: []byte(bilingual)}), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				if r.lyr != bilingual || r.tr != "" || r.plainOnly {
					t.Errorf("双语行不在这一层拆:%+v", r)
				}
			},
		},
		{
			name: "时长没给:自报时长是 0", artist: artist, title: title, prepare: on(sidecar), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				if r.srcDur != 0 {
					t.Errorf("自报时长应是这一轮的时长:%+v", r)
				}
			},
		},
		{
			name: "同名 .lrc 是 UTF-16", artist: artist, title: title, durationSecs: secs,
			prepare: on(localFileParityData{player: reampBundleID, sidecar: utf16LE(timed)}), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				if r.lyr != timed {
					t.Errorf("应解码成同一份正文:%q", r.lyr)
				}
			},
		},
		{
			name: "没有 .lrc、文件标签里有带时间的歌词", artist: artist, title: title, durationSecs: secs,
			prepare: on(localFileParityData{player: reampBundleID, audio: embedded("[00:01.00]embedded line\r\n[00:03.00]more\r\n")}), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				if r.lyr != "[00:01.00]embedded line\n[00:03.00]more\n" || r.plainOnly {
					t.Errorf("应退到内嵌歌词:%+v", r)
				}
			},
		},
		{
			name: "文件标签里只有不带时间的歌词:交成纯文本", artist: artist, title: title, durationSecs: secs,
			prepare: on(localFileParityData{player: reampBundleID, audio: embedded("first line\r\nsecond line")}), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				if !r.plainOnly || r.lyr != "first line\nsecond line" || !r.identityFromLocalClient {
					t.Errorf("应交成纯文本:%+v", r)
				}
			},
		},
		{
			name: "同名 .lrc 优先于内嵌", artist: artist, title: title, durationSecs: secs,
			prepare: on(localFileParityData{player: reampBundleID, audio: embedded("[00:01.00]embedded line\r\n"), sidecar: []byte(timed)}), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				if r.lyr != timed {
					t.Errorf("应用同名 .lrc:%q", r.lyr)
				}
			},
		},
		{name: "没有 .lrc 也没有内嵌歌词:没有", artist: artist, title: title, durationSecs: secs, prepare: on(localFileParityData{player: reampBundleID})},
		{name: "同名 .lrc 是空文件:没有", artist: artist, title: title, durationSecs: secs, prepare: on(localFileParityData{player: reampBundleID, sidecar: []byte{}})},
		{name: "文件所在的目录读不到:没有", artist: artist, title: title, durationSecs: secs, prepare: on(localFileParityData{player: reampBundleID, sidecar: []byte(timed), goneDir: true})},
		{name: "问的不是正在放的这首(预解析的下一首):没有", artist: artist, title: "Diamonds", durationSecs: secs, prepare: on(sidecar)},
		{
			name: "不是放本地文件的播放器在放:不读", artist: artist, title: title, durationSecs: secs,
			prepare: on(localFileParityData{player: kkboxBundleID, noted: reampBundleID, sidecar: []byte(timed)}),
		},
		{
			name: "App 没报正在放的是哪个文件:没有", artist: artist, title: title, durationSecs: secs,
			prepare: on(localFileParityData{player: reampBundleID, noted: kkboxBundleID, sidecar: []byte(timed)}),
		},
		{
			name: "Spotify 放本地文件时也读", artist: artist, title: title, durationSecs: secs,
			prepare: on(localFileParityData{player: spotifyBundleID, sidecar: []byte(timed)}), present: true, check: localIdentityGiven,
		},
		{name: "VOX 在放", artist: artist, title: title, durationSecs: secs, prepare: on(localFileParityData{player: voxBundleID, sidecar: []byte(timed)}), present: true, check: localIdentityGiven},
		{
			name: "按播放器原样标签认,不按检索词", ctx: promoCtx, artist: promoArtist, title: promoTitle, durationSecs: secs, present: true,
			prepare: sidecar.prepare("韋禮安", localPromoTitle),
			check: func(t *testing.T, r lyricSourceResult) {
				if r.matchTitle != localPromoTitle || r.matchArtist != "韋禮安" {
					t.Errorf("歌名歌手应是播放器原样的:%+v", r)
				}
			},
		},
		{name: "别名轮不读", ctx: localAliasRound, artist: artist, title: title, durationSecs: secs, prepare: on(sidecar)},
		{name: "带「只查这些源」名单的首轮照样读", ctx: localOnlyListRound, artist: artist, title: title, durationSecs: secs, prepare: on(sidecar), present: true, check: localIdentityGiven},
		{name: "别的歌那一轮:读到,身份不算播放器给定", ctx: localOtherTrackRound, artist: artist, title: title, durationSecs: secs, prepare: on(sidecar), present: true, check: localIdentityNotGiven},
	})
}

// ---- 洛雪存下的歌词(SQLite 那条腿、开放 API 那条腿) ----

// lxParityData:一个场景里洛雪的本机数据。列表默认是 lxTestList,正在放的是 temp 列表第 3 首《一样的月光》。
type lxParityData struct {
	player string
	// tracks:非 nil 时换成这份列表,正在放的是 temp 列表第 1 首。
	tracks []lxTestTrack
	// lyrics:库里存的歌词。
	lyrics []lxTestLyric
	// sql:建好库之后再执行的语句(往列表里加本地歌)。
	sql string
	// api:非 nil 时洛雪的开放 API 开着,按路径回这些应答体(/status、/lyric-all)。
	api map[string]string
	// corruptDB:数据库文件换成一堆垃圾;goneData:数据目录指到不存在的路径。
	corruptDB, goneData bool
}

func (d lxParityData) prepare(t *testing.T) {
	t.Helper()
	if d.tracks != nil {
		withLXMusicData(t, d.tracks, d.lyrics, "temp", 0, "")
	} else {
		withLXMusicData(t, lxTestList, d.lyrics, "temp", 2, "")
	}
	if d.sql != "" {
		lxTestSQL(t, d.sql)
	}
	if d.corruptDB {
		if err := os.WriteFile(lxMusicDBPath(), []byte("this is not a sqlite database"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if d.goneData {
		lxMusicDataDirOverride += "-gone"
	}
	savedBase := lxMusicOpenAPIBaseOverride
	lxMusicOpenAPIBaseOverride = ""
	if d.api != nil {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			body, ok := d.api[r.URL.Path]
			if !ok {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			fmt.Fprint(w, body)
		}))
		t.Cleanup(srv.Close)
		lxMusicOpenAPIBaseOverride = srv.URL
	}
	setNativeLyricSourcesForPlayer(d.player)
	t.Cleanup(func() {
		lxMusicOpenAPIBaseOverride = savedBase
		setNativeLyricSourcesForPlayer("")
	})
}

func TestLXMusicLocalProviderMatchesHandwrittenRead(t *testing.T) {
	const artist, title, secs = "徐佳莹", "一样的月光", 240.0
	stored := []lxTestLyric{
		{"kw_3", "raw", "lyric", "[00:01.00]第一句\n[00:02.00]第二句\n[00:03.00]第三句"},
		{"kw_3", "raw", "lxlyric", "[00:01.000]<0,500>第<500,500>一句"},
		{"kw_3", "raw", "tlyric", "[00:01.00]line one\n[00:02.00]line two\n[00:03.00]line three"},
		{"kw_3", "raw", "rlyric", "[00:01.00]di yi ju\n[00:02.00]di er ju\n[00:03.00]di san ju"},
	}
	inDB := lxParityData{player: lxMusicBundleID, lyrics: stored}
	const apiStatus = `{"name":"夜空中最亮的星","singer":"逃跑计划","albumName":"世界","duration":252.3}`
	const apiLyric = `{"lyric":"[00:01.00]夜空中最亮的星","tlyric":"","rlyric":"","lxlyric":"[00:01.000]<0,500>夜<500,500>空"}`
	api := func(status, lyric string) lxParityData {
		return lxParityData{player: lxMusicBundleID, api: map[string]string{"/status": status, "/lyric-all": lyric}}
	}
	localSongs := `INSERT INTO my_list_music_info VALUES ('local_1','temp','本地歌','某人','local','03:20','{"filePath":"/Users/x/Music/某人 - 本地歌.flac","albumName":"本地专辑"}');` +
		`INSERT INTO my_list_music_info_order VALUES ('temp','local_1',4);` +
		`INSERT INTO my_list_music_info VALUES ('local_2','temp','改过词','某人','local','03:00','{"filePath":"/Users/x/Music/改过词.mp3"}');` +
		`INSERT INTO my_list_music_info_order VALUES ('temp','local_2',5);`
	local := lxParityData{player: lxMusicBundleID, sql: localSongs, lyrics: []lxTestLyric{
		{"local_1", "raw", "lyric", "[00:01.00]搜来的第一句\n[00:02.00]搜来的第二句"},
		{"local_2", "raw", "lyric", "[00:01.00]搜来的"},
		{"local_2", "edited", "lyric", "[00:01.00]改过的"},
	}}
	cancelled := func(ctx context.Context) context.Context {
		ctx, cancel := context.WithCancel(ctx)
		cancel()
		return ctx
	}
	// 同名两个录音都不在正在放的那个列表里:只能按登记的时长挑。
	twoRecordings := lxParityData{
		player: lxMusicBundleID,
		tracks: []lxTestTrack{
			{"temp", "kw_1", "小半", "陈粒", "04:57", "小梦大半"},
			{"default", "kw_a", "倔强", "五月天", "04:20", "神的孩子都在跳舞"},
			{"love", "kw_b", "倔强", "五月天", "05:10", "现场专辑"},
		},
		lyrics: []lxTestLyric{{"kw_a", "raw", "lyric", "[00:01.00]录音室版"}, {"kw_b", "raw", "lyric", "[00:01.00]现场版"}},
	}
	promo := lxParityData{
		player: lxMusicBundleID,
		tracks: []lxTestTrack{{"temp", "kw_p", localPromoTitle, "韋禮安", "04:32", "如果可以"}},
		lyrics: []lxTestLyric{{"kw_p", "raw", "lyric", "[00:01.00]如果可以"}},
	}
	promoArtist, promoTitle, _, promoCtx := localPromoQuery(t, "")
	runLocalParity(t, lxMusicLocalLyricsSource, nil, []localParityCase{
		{
			name: "同名两个录音:按时长认到现场那一条", artist: "五月天", title: "倔强", durationSecs: 310, prepare: twoRecordings.prepare, present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				if !strings.Contains(r.lyr, "现场版") || r.matchAlbum != "现场专辑" || r.srcDur != 310 {
					t.Errorf("应认到 310 秒的那一条:%+v", r)
				}
			},
		},
		{
			name: "同名两个录音:按时长认到录音室那一条", artist: "五月天", title: "倔强", durationSecs: 260, prepare: twoRecordings.prepare, present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				if !strings.Contains(r.lyr, "录音室版") {
					t.Errorf("应认到 260 秒的那一条:%+v", r)
				}
			},
		},
		{name: "同名两个录音、时长都对不上:没有", artist: "五月天", title: "倔强", durationSecs: 500, prepare: twoRecordings.prepare},
		{
			name: "按播放器原样标签认,不按检索词", ctx: promoCtx, artist: promoArtist, title: promoTitle, durationSecs: 272, prepare: promo.prepare, present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				localIdentityGiven(t, r)
				if r.matchTitle != localPromoTitle {
					t.Errorf("应认到带宣传尾段的那一条:%+v", r)
				}
			},
		},
		{name: "检索词对不上、也没记原样标签:没有", artist: promoArtist, title: promoTitle, durationSecs: 272, prepare: promo.prepare},
		{
			name: "库里有:整行、逐字、译文、音译都交", artist: artist, title: title, durationSecs: secs, prepare: inDB.prepare, present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				localIdentityGiven(t, r)
				if !strings.Contains(r.lyr, "第二句") || r.yrc == "" || !strings.Contains(r.tr, "line two") || !strings.Contains(r.roma, "di er ju") ||
					r.matchTitle != title || r.matchArtist != artist || r.matchAlbum != "LaLa首张创作专辑" || r.srcDur != 240 {
					t.Errorf("库里那几样应都交上来:%+v", r)
				}
			},
		},
		{name: "库里没存这首的词、开放 API 没开:没有", artist: "陈粒", title: "小半", durationSecs: 297, prepare: inDB.prepare},
		{name: "洛雪列表里没有这首、开放 API 没开:没有", artist: "五月天", title: "倔强", durationSecs: 260, prepare: inDB.prepare},
		{
			name: "正在放的那一条不是这首:在列表里按歌名歌手找到", artist: "周杰伦", title: "晴天", durationSecs: 269, present: true,
			prepare: lxParityData{player: lxMusicBundleID, lyrics: []lxTestLyric{{"kw_2", "raw", "lyric", "[00:01.00]故事的小黄花\n[00:02.00]从出生那年就飘着"}}}.prepare,
			check: func(t *testing.T, r lyricSourceResult) {
				localIdentityGiven(t, r)
				if r.matchAlbum != "叶惠美" || r.srcDur != 269 {
					t.Errorf("应认到 temp 列表里那一条:%+v", r)
				}
			},
		},
		{
			name: "库里没有、开放 API 有", artist: "逃跑计划", title: "夜空中最亮的星", durationSecs: 252, prepare: api(apiStatus, apiLyric).prepare, present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				localIdentityGiven(t, r)
				if !strings.Contains(r.lyr, "夜空中最亮的星") || r.yrc == "" || r.matchAlbum != "世界" || r.srcDur != 252.3 || r.matchArtist != "逃跑计划" {
					t.Errorf("应取自开放 API:%+v", r)
				}
			},
		},
		{name: "开放 API 在放的不是这一首:没有", artist: "五月天", title: "倔强", durationSecs: 252, prepare: api(apiStatus, apiLyric).prepare},
		{name: "开放 API 也没有词:没有", artist: "逃跑计划", title: "夜空中最亮的星", durationSecs: 252, prepare: api(apiStatus, `{"lyric":"","tlyric":"","rlyric":"","lxlyric":""}`).prepare},
		{name: "开放 API 回的不是 JSON:没有", artist: "逃跑计划", title: "夜空中最亮的星", durationSecs: 252, prepare: api("<html>", "<html>").prepare},
		{
			name: "库里和开放 API 都有:用库里的", artist: artist, title: title, durationSecs: secs, present: true,
			prepare: lxParityData{player: lxMusicBundleID, lyrics: stored, api: map[string]string{"/status": `{"name":"一样的月光","singer":"徐佳莹","albumName":"API 专辑","duration":240}`, "/lyric-all": apiLyric}}.prepare,
			check: func(t *testing.T, r lyricSourceResult) {
				if r.matchAlbum != "LaLa首张创作专辑" || !strings.Contains(r.lyr, "第二句") {
					t.Errorf("库里有时不问开放 API:%+v", r)
				}
			},
		},
		{name: "本地歌没改过的那份是搜来的:不算本机身份", artist: "某人", title: "本地歌", durationSecs: 200, prepare: local.prepare, present: true, check: localIdentityNotGiven},
		{
			name: "本地歌用户改过的那份照算本机身份", artist: "某人", title: "改过词", durationSecs: 180, prepare: local.prepare, present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				localIdentityGiven(t, r)
				if !strings.Contains(r.lyr, "改过的") {
					t.Errorf("应用改过的那份:%+v", r)
				}
			},
		},
		{name: "不是在用洛雪放:不读", artist: artist, title: title, durationSecs: secs, prepare: lxParityData{player: spotifyBundleID, lyrics: stored}.prepare},
		{name: "数据库损坏:没有", artist: artist, title: title, durationSecs: secs, prepare: lxParityData{player: lxMusicBundleID, lyrics: stored, corruptDB: true}.prepare},
		{name: "数据目录读不到:没有", artist: artist, title: title, durationSecs: secs, prepare: lxParityData{player: lxMusicBundleID, lyrics: stored, goneData: true}.prepare},
		{name: "这一轮开搜前已取消:没有", ctx: cancelled, artist: artist, title: title, durationSecs: secs, prepare: inDB.prepare},
		{name: "别名轮不读", ctx: localAliasRound, artist: artist, title: title, durationSecs: secs, prepare: inDB.prepare},
		{name: "带「只查这些源」名单的首轮照样读", ctx: localOnlyListRound, artist: artist, title: title, durationSecs: secs, prepare: inDB.prepare, present: true, check: localIdentityGiven},
		{name: "别的歌那一轮:读到,身份不算播放器给定", ctx: localOtherTrackRound, artist: artist, title: title, durationSecs: secs, prepare: inDB.prepare, present: true, check: localIdentityNotGiven},
	})
}

// ---- 导入库 ----

// importParityRecords 往这一趟的导入库里存几条;cache 非 nil 时歌词缓存换成它(按时长挑变体那条 key 要读)。
func importParityRecords(cache map[string]enrichEntry, recs ...importedLyricsRecord) func(t *testing.T) {
	return func(t *testing.T) {
		t.Helper()
		if cache == nil {
			cache = map[string]enrichEntry{}
		}
		localParityEnrichCache(t, cache)
		if len(recs) == 0 {
			return
		}
		if err := saveImportedLyrics(recs...); err != nil {
			t.Fatal(err)
		}
	}
}

func TestImportLibraryProviderMatchesHandwrittenRead(t *testing.T) {
	const artist, title, album = "A", "Song", "Album"
	lyr := lrcBodyEn(20, 10)
	full := importedLyricsRecord{
		Key: enrichKey(artist, title, album), Lyrics: lyr, YRC: "[1000,500](1000,500,0)word", Tr: "[00:00.00]译文", TrLang: "zh-Hans",
		Roma: "[00:00.00]roma", BG: "[1000,500](1200,300,0)(oh)",
	}
	plain := importedLyricsRecord{Key: enrichKey(artist, title, album), Lyrics: lyr}
	bySong := importedLyricsRecord{Lyrics: lrcBodyEn(4, 6), Identities: []importedIdentity{{Artist: "Nobody Here", Title: "No Such Song"}}}
	variants := map[string]enrichEntry{"C|Live|Album": {DurationSecs: 200}, "C|Live~dur2|Album": {DurationSecs: 300}}
	promoArtist, promoTitle, promoAlbum, promoCtx := localPromoQuery(t, "如果可以")
	lyricsAre := func(want string) func(t *testing.T, r lyricSourceResult) {
		return func(t *testing.T, r lyricSourceResult) {
			t.Helper()
			if r.lyr != want || r.identityFromLocalClient || r.forPlayingTrack {
				t.Errorf("应拿到那一份、不带本机身份:%+v", r)
			}
		}
	}
	runLocalParity(t, importLyricsSource, nil, []localParityCase{
		{
			name: "按这首的 key 命中:整行、逐字、译文、音译、背景人声、译文语言都交", artist: artist, title: title, album: album, durationSecs: 200,
			prepare: importParityRecords(nil, full), present: true,
			check: func(t *testing.T, r lyricSourceResult) {
				want := lyricSourceResult{
					source: importLyricsSource, lyr: lyr, yrc: full.YRC, tr: full.Tr, roma: full.Roma, bg: full.BG, trLang: "zh-Hans",
					matchTitle: title, matchArtist: artist, matchAlbum: album,
				}
				if !reflect.DeepEqual(r, want) {
					t.Errorf("结果 %+v\n期望 %+v", r, want)
				}
			},
		},
		{name: "原 key 对上的不看时长", artist: artist, title: title, album: album, durationSecs: 400, prepare: importParityRecords(nil, plain), present: true, check: lyricsAre(lyr)},
		{name: "时长没给", artist: artist, title: title, album: album, prepare: importParityRecords(nil, plain), present: true, check: lyricsAre(lyr)},
		{name: "宽松 key 对上、时长吻合", artist: "a", title: "song", album: "ALBUM", durationSecs: 200, prepare: importParityRecords(nil, plain), present: true, check: lyricsAre(lyr)},
		{name: "宽松 key 对上但末句超出时长:没有", artist: "a", title: "song", album: "ALBUM", durationSecs: 100, prepare: importParityRecords(nil, plain)},
		{name: "专辑不同的另一条写法:没有", artist: artist, title: title, album: "Other Album", durationSecs: 200, prepare: importParityRecords(nil, plain)},
		{name: "按身份存的那份:歌手歌名认得出", artist: "Nobody Here", title: "No Such Song", album: "Some Album", prepare: importParityRecords(nil, bySong), present: true, check: lyricsAre(lrcBodyEn(4, 6))},
		{name: "按身份存的那份:时长对不上不认", artist: "Nobody Here", title: "No Such Song", durationSecs: 300, prepare: importParityRecords(nil, bySong)},
		{name: "按身份存的那份:歌手不对不认", artist: "Somebody Else", title: "No Such Song", prepare: importParityRecords(nil, bySong)},
		{name: "库里没有这首:没有", artist: artist, title: title, album: album, durationSecs: 200, prepare: importParityRecords(nil)},
		{
			name: "同名两个录音:300 秒的拿「~dur2」那条自己的", artist: "C", title: "Live", album: "Album", durationSecs: 300, present: true,
			prepare: importParityRecords(variants, importedLyricsRecord{Key: "C|Live|Album", Lyrics: lrcBodyEn(20, 9)}, importedLyricsRecord{Key: "C|Live~dur2|Album", Lyrics: lrcBodyEn(28, 10)}),
			check:   lyricsAre(lrcBodyEn(28, 10)),
		},
		{
			name: "同名两个录音:200 秒的拿原 key 那条", artist: "C", title: "Live", album: "Album", durationSecs: 200, present: true,
			prepare: importParityRecords(variants, importedLyricsRecord{Key: "C|Live|Album", Lyrics: lrcBodyEn(20, 9)}, importedLyricsRecord{Key: "C|Live~dur2|Album", Lyrics: lrcBodyEn(28, 10)}),
			check:   lyricsAre(lrcBodyEn(20, 9)),
		},
		{
			name: "同名两个录音、只存了原 key 那条:300 秒的不拿", artist: "C", title: "Live", album: "Album", durationSecs: 300,
			prepare: importParityRecords(variants, importedLyricsRecord{Key: "C|Live|Album", Lyrics: lrcBodyEn(20, 9)}),
		},
		{
			name: "导入库的索引损坏:没有", artist: artist, title: title, album: album, durationSecs: 200,
			prepare: func(t *testing.T) {
				importParityRecords(nil, plain)(t)
				entries, err := os.ReadDir(importedLyricsDir())
				if err != nil || len(entries) == 0 {
					t.Fatalf("导入库目录里应有文件:%v %v", entries, err)
				}
				for _, e := range entries {
					if err := os.WriteFile(filepath.Join(importedLyricsDir(), e.Name()), []byte("{broken"), 0o644); err != nil {
						t.Fatal(err)
					}
				}
			},
		},
		{
			name: "不看播放器:用 KKBOX 放时照样读", artist: artist, title: title, album: album, durationSecs: 200, present: true,
			prepare: func(t *testing.T) {
				importParityRecords(nil, plain)(t)
				setNativeLyricSourcesForPlayer(kkboxBundleID)
				t.Cleanup(func() { setNativeLyricSourcesForPlayer("") })
			},
			check: lyricsAre(lyr),
		},
		{
			name: "按播放器原样标签认,不按检索词", ctx: promoCtx, artist: promoArtist, title: promoTitle, album: promoAlbum, durationSecs: 200, present: true,
			prepare: importParityRecords(nil, importedLyricsRecord{Key: enrichKey("韋禮安", localPromoTitle, "如果可以"), Lyrics: lyr}),
			check: func(t *testing.T, r lyricSourceResult) {
				lyricsAre(lyr)(t, r)
				if r.matchTitle != localPromoTitle || r.matchArtist != "韋禮安" || r.matchAlbum != "如果可以" {
					t.Errorf("歌名歌手专辑应是播放器原样的:%+v", r)
				}
			},
		},
		{name: "别名轮不读", ctx: localAliasRound, artist: artist, title: title, album: album, durationSecs: 200, prepare: importParityRecords(nil, plain)},
		{name: "带「只查这些源」名单的首轮照样读", ctx: localOnlyListRound, artist: artist, title: title, album: album, durationSecs: 200, prepare: importParityRecords(nil, plain), present: true, check: lyricsAre(lyr)},
		{name: "别的歌那一轮照样读", ctx: localOtherTrackRound, artist: artist, title: title, album: album, durationSecs: 200, prepare: importParityRecords(nil, plain), present: true, check: lyricsAre(lyr)},
		{name: "手动搜索照样读", ctx: localManualRound, artist: artist, title: title, album: album, durationSecs: 200, prepare: importParityRecords(nil, plain), present: true, check: lyricsAre(lyr)},
	})
}
