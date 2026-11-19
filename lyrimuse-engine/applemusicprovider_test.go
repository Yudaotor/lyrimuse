package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

// appleMusicParitySource:Apple Music 的对拍。参照路径是迁移前那个 goroutine 判完跳过之后的整段,播放器原样标签和
// 「能不能用播放器的信号」照收集循环开头的写法现算。凭据在临时配置目录里(用户令牌、店面、一张没过期的 developer token),
// 播放侧的目录 id 提示、Music.app 的歌词缓存、正在放的播放器都清成没有,要它们的场景在 prepare 里设。
var appleMusicParitySource = providerParitySource{
	name: lyricSourceAppleMusic,
	handwritten: func(ctx context.Context, artist, title, srcTitle, album string, durationSecs float64) lyricSourceResult {
		idArtist, idTitle, idAlbum := lyricIdentityFields(ctx, artist, title, album)
		forPlaying := playerSignalApplies(ctx)
		appleID, _ := playbackTrackIDsForRound(ctx, idArtist, idTitle, idAlbum)
		r := applemusicLyric(ctx, artist, srcTitle, album, durationSecs, appleID, lyricSourceISRC(ctx, artist, title, album))
		appleNoVocals := false
		if forPlaying && r.lyrics == "" && playingPlayer() == playerAppleMusic {
			if appleID == "" && !isPlayerQueueTrack(ctx) {
				appleID = waitPlayingAppleCatalogID(ctx, idArtist, idTitle, idAlbum)
			}
			appleNoVocals = appleID != "" && applemusicCatalogNoVocals(ctx, appleID)
		}
		return lyricSourceResult{noVocals: appleNoVocals, source: "applemusic", lyr: r.lyrics, yrc: r.yrc, tr: r.tr, trLang: r.trLang, roma: r.roma, bg: r.bg, songwriters: r.songwriters, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, isrc: r.isrc, plainOnly: r.plainOnly, identityFromLocalClient: r.fromLocalClient || r.fromPlayerCatalogID || appleNoVocals}
	},
	reset: func(t *testing.T) {
		withApplemusicCreds(t, "cn")
		withEmptyApplemusicCache(t)
		withCleanPlaybackHints(t)
		withAppleNoVocalsWait(t, 40*time.Millisecond)
		resetAppleLocalIndex(t, filepath.Join(t.TempDir(), "no-music-app-cache"))
		applemusicNoVocalsMu.Lock()
		savedNoVocals := applemusicNoVocalsCache
		applemusicNoVocalsCache = map[string]bool{}
		applemusicNoVocalsMu.Unlock()
		applemusicDevTokenFetchMu.Lock()
		savedFailedAt := applemusicDevTokenFailedAt
		applemusicDevTokenFailedAt = time.Time{}
		applemusicDevTokenFetchMu.Unlock()
		savedFeatures := features()
		featuresRef().LyricsTranslationLanguage = "zh"
		setNativeLyricSourcesForPlayer("")
		t.Cleanup(func() {
			applemusicNoVocalsMu.Lock()
			applemusicNoVocalsCache = savedNoVocals
			applemusicNoVocalsMu.Unlock()
			applemusicDevTokenFetchMu.Lock()
			applemusicDevTokenFailedAt = savedFailedAt
			applemusicDevTokenFetchMu.Unlock()
			setFeatures(savedFeatures)
			setNativeLyricSourcesForPlayer("")
		})
	},
	cacheKeys: func() []string {
		applemusicMu.Lock()
		defer applemusicMu.Unlock()
		var keys []string
		for k := range applemusicCache {
			keys = append(keys, k)
		}
		return keys
	},
	state: func() []string {
		applemusicDevTokenMu.Lock()
		dev := applemusicDevToken
		applemusicDevTokenMu.Unlock()
		applemusicDevTokenFetchMu.Lock()
		fetchFailed := !applemusicDevTokenFailedAt.IsZero()
		applemusicDevTokenFetchMu.Unlock()
		st := applemusicReadStatus()
		_, devFileErr := os.Stat(applemusicDevTokenPath())
		out := []string{
			"last failure=" + applemusicLastFailureReasonNow(),
			fmt.Sprintf("dev token=%q fetch failed=%v file kept=%v", dev, fetchFailed, devFileErr == nil),
			fmt.Sprintf("status storefront=%q rejected=%v", st.Storefront, st.RejectedAt != 0),
		}
		var more []string
		applemusicNoVocalsMu.Lock()
		for id, v := range applemusicNoVocalsCache {
			more = append(more, fmt.Sprintf("no-vocals cache %s=%v", id, v))
		}
		applemusicNoVocalsMu.Unlock()
		applemusicEnglishTagMu.Lock()
		for sf, tag := range applemusicEnglishTags {
			more = append(more, fmt.Sprintf("english tag %s=%q", sf, tag))
		}
		applemusicEnglishTagMu.Unlock()
		sort.Strings(more)
		return append(append(out, more...), parityEndpointHealth(lyricSourceAppleMusic)...)
	},
	headers:    []string{"Authorization", "Media-User-Token", "Origin"},
	extraHosts: []string{"music.apple.com"},
}

// amParityFake 按接口分发 Apple Music 的请求;没给的接口回 404。
type amParityFake struct {
	// search:按名字搜(/v1/catalog/<店面>/search);核对 developer token 好不好用的那一问也走它(店面 us、term=a)。
	search func(r parityRequest, storefront string) parityReply
	// song:按目录 id 取一条(也是问有没有人声的那一问);isrc:按 ISRC 取这条录音的各个条目。
	song func(r parityRequest, id string) parityReply
	isrc func(r parityRequest, code string) parityReply
	// lyrics:取词,kind 是 syllable-lyrics 或 lyrics。
	lyrics func(r parityRequest, id, kind string) parityReply
	// meStorefront:账号所在区;storefronts:一个区的语言标签;browse:抓 developer token 的网页。
	meStorefront, storefronts, browse func(r parityRequest) parityReply
}

func (f amParityFake) handler() func(parityRequest) parityReply {
	return func(r parityRequest) parityReply {
		path := r.URL.Path
		switch {
		case strings.HasPrefix(r.target, "https://music.apple.com/"):
			if f.browse != nil {
				return f.browse(r)
			}
		case path == "/v1/me/storefront":
			if f.meStorefront != nil {
				return f.meStorefront(r)
			}
		case strings.HasPrefix(path, "/v1/storefronts/"):
			if f.storefronts != nil {
				return f.storefronts(r)
			}
		case strings.HasPrefix(path, "/v1/catalog/"):
			parts := strings.Split(strings.TrimPrefix(path, "/v1/catalog/"), "/")
			switch {
			case len(parts) == 2 && parts[1] == "search" && f.search != nil:
				return f.search(r, parts[0])
			case len(parts) == 2 && parts[1] == "songs" && f.isrc != nil:
				return f.isrc(r, r.URL.Query().Get("filter[isrc]"))
			case len(parts) == 3 && parts[1] == "songs" && f.song != nil:
				return f.song(r, parts[2])
			case len(parts) == 4 && parts[1] == "songs" && f.lyrics != nil:
				return f.lyrics(r, parts[2], parts[3])
			}
		}
		return parityStatus(http.StatusNotFound)
	}
}

const (
	amParityISRC = "TWA530612345"
	// amParityRichTTML:逐字,带官方译文、音译、作者名单和一句背景人声。
	amParityRichTTML = `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="ja"><head><metadata>` +
		`<ttm:agent type="person" xml:id="v1"/><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">` +
		`<translations><translation type="subtitle" xml:lang="zh-Hans"><text for="L1">译文第一行</text><text for="L2">译文第二行</text><text for="L3">译文第三行</text></translation></translations>` +
		`<transliterations><transliteration xml:lang="ja-Latn"><text for="L1">ichi gyou</text><text for="L2">ni gyou</text><text for="L3">san gyou</text></transliteration></transliterations>` +
		`<songwriters><songwriter>作者甲</songwriter><songwriter>作者乙</songwriter></songwriters></iTunesMetadata></metadata></head><body dur="4:16.000"><div begin="1.000" end="6.000">` +
		`<p begin="1.000" end="2.000" itunes:key="L1" ttm:agent="v1"><span begin="1.000" end="1.500">一行</span><span begin="1.500" end="2.000">目</span>` +
		`<span ttm:role="x-bg" begin="1.600" end="1.900"><span begin="1.600" end="1.900">和声</span></span></p>` +
		`<p begin="3.000" end="4.000" itunes:key="L2" ttm:agent="v1"><span begin="3.000" end="3.500">二行</span><span begin="3.500" end="4.000">目</span></p>` +
		`<p begin="5.000" end="6.000" itunes:key="L3" ttm:agent="v1"><span begin="5.000" end="5.500">三行</span><span begin="5.500" end="6.000">目</span></p>` +
		`</div></body></tt>`
)

// amParitySong:目录里的一条,带 ISRC 和封面模板。
func amParitySong(id, name, artist, album string, ms int, synced bool) applemusicSong {
	s := amTestSong(id, name, artist, album, ms, synced)
	s.Attributes.Isrc = amParityISRC
	s.Attributes.Artwork.URL = "https://is1-ssl.mzstatic.com/image/thumb/Music/abc/{w}x{h}bb.jpg"
	return s
}

func amParityCatalogID() int64 {
	id, _ := strconv.ParseInt(amTestCatalogID, 10, 64)
	return id
}

func TestAppleMusicProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title, album = "王力宏", "公转自转", "公转.自转"
	song := amParitySong("1001", "公转自转", "王力宏", "公转.自转", 256227, true)
	catalogSong := amParitySong(amTestCatalogID, "公转自转", "王力宏", "公转.自转", 256227, true)
	hit := amParityFake{
		search: func(parityRequest, string) parityReply { return parityOK(amTestSearchBody(song)) },
		lyrics: func(_ parityRequest, _, kind string) parityReply {
			if kind == "syllable-lyrics" {
				return parityOK(amTestLyricsBody(amParityRichTTML))
			}
			return parityStatus(http.StatusNotFound)
		},
	}
	with := func(edit func(*amParityFake)) func(parityRequest) parityReply {
		f := hit
		edit(&f)
		return f.handler()
	}
	hinted := func(t *testing.T) { notePlayingAppleCatalogID(artist, title, album, amParityCatalogID()) }
	playingAppleMusic := func(t *testing.T) { setNativeLyricSourcesForPlayer(appleMusicBundleID) }
	hintedAndPlaying := func(t *testing.T) { hinted(t); playingAppleMusic(t) }
	// noLyricsAnywhere:目录里有这一条、标着没有歌词、audioLocale 是 locale;按名字、换英文名、换日区都搜不到。
	noLyricsAnywhere := func(locale string) func(f *amParityFake) {
		return func(f *amParityFake) {
			f.search = func(parityRequest, string) parityReply { return parityOK(amTestSearchBody()) }
			f.song = func(parityRequest, string) parityReply {
				s := catalogSong
				s.Attributes.HasLyrics, s.Attributes.HasTimeSynced, s.Attributes.AudioLocale = false, false, locale
				return parityOK(amTestSongBody(s))
			}
		}
	}
	wantNoVocals := func(want bool) func(t *testing.T, o providerParityOutcome) {
		return func(t *testing.T, o providerParityOutcome) {
			if o.result.noVocals != want || o.result.identityFromLocalClient != want {
				t.Errorf("无人声信号和它带来的本机身份应是 %v:%+v", want, o.result)
			}
		}
	}
	wantFailure := func(reason string) func(t *testing.T, o providerParityOutcome) {
		return func(t *testing.T, o providerParityOutcome) {
			if !strings.Contains(strings.Join(o.state, "\n"), "last failure="+reason+"\n") {
				t.Errorf("失败原因应是 %q:%v", reason, o.state)
			}
		}
	}
	cases := []providerParityCase{
		{
			name: "按名字搜命中:逐字、译文、音译、背景人声、作者、ISRC、封面都带", artist: artist, title: title, album: album, durationSecs: 256,
			handle: hit.handler(), wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				r := o.result
				if !strings.Contains(r.lyr, "一行目") || r.yrc == "" || !strings.Contains(r.tr, "译文第一行") || r.trLang == "" || !strings.Contains(r.roma, "ichi gyou") ||
					r.bg == "" || len(r.songwriters) != 2 || r.matchTitle != "公转自转" || r.matchArtist != "王力宏" || r.matchAlbum != "公转.自转" ||
					!strings.Contains(r.matchCover, "10000x10000") || r.srcDur != 256.227 || r.isrc != amParityISRC || r.plainOnly || r.identityFromLocalClient || r.noVocals {
					t.Errorf("正文、逐字、译文和它的语言、音译、背景人声、作者、歌名、歌手、专辑、封面、时长、ISRC 都该带上,不算本机身份:%+v", r)
				}
				reqs := strings.Join(o.requests, "\n")
				if !strings.Contains(reqs, "Authorization=Bearer test-dev-token") || !strings.Contains(reqs, "Media-User-Token=test-user-token") {
					t.Errorf("搜索带 developer token、取词另带用户令牌:%v", o.requests)
				}
				if len(o.cached) != 1 || o.cached[0] != "王力宏|公转自转|公转.自转|||zh" {
					t.Errorf("进程内缓存的键带歌手、歌名、专辑、目录 id、ISRC、译文语言:%v", o.cached)
				}
			},
		},
		{
			name: "没连过 Apple Music:一个请求都不发,记下没连接",
			prepare: func(t *testing.T) {
				if err := os.Remove(applemusicUserTokenPath()); err != nil {
					t.Fatal(err)
				}
			},
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: hit.handler(), wantRequests: 0, check: wantFailure(lyricFailureReasonAppleMusicNotConnected),
		},
		{
			name: "developer token 取不到:记下原因,不搜",
			prepare: func(t *testing.T) {
				if err := os.Remove(applemusicDevTokenPath()); err != nil {
					t.Fatal(err)
				}
			},
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: hit.handler(), wantRequests: 1,
			check: func(t *testing.T, o providerParityOutcome) {
				wantFailure(lyricFailureReasonAppleMusicNoDevToken)(t, o)
				if !strings.Contains(strings.Join(o.state, "\n"), "fetch failed=true") || !strings.HasPrefix(o.requests[0], "GET https://music.apple.com/") {
					t.Errorf("应去网页抓过一次、记下抓取失败:%v %v", o.state, o.requests)
				}
			},
		},
		{
			name: "用户令牌被拒(取词 401、developer token 还好用):记下令牌被拒", artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.lyrics = func(parityRequest, string, string) parityReply { return parityStatus(http.StatusUnauthorized) }
			}),
			wantRequests: 3,
			check: func(t *testing.T, o providerParityOutcome) {
				wantFailure(lyricFailureReasonAppleMusicTokenRejected)(t, o)
				if !strings.Contains(strings.Join(o.state, "\n"), "rejected=true") || len(o.cached) != 0 {
					t.Errorf("应在状态文件里记下被拒、不进缓存:%v %v", o.state, o.cached)
				}
			},
		},
		{
			name: "取词 401、developer token 也被拒、重抓不到:清掉那张票,不怪用户令牌", artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.search = func(_ parityRequest, storefront string) parityReply {
					if storefront == "us" {
						return parityStatus(http.StatusUnauthorized)
					}
					return parityOK(amTestSearchBody(song))
				}
				f.lyrics = func(parityRequest, string, string) parityReply { return parityStatus(http.StatusUnauthorized) }
			}),
			wantRequests: 4,
			check: func(t *testing.T, o providerParityOutcome) {
				wantFailure(lyricFailureReasonAppleMusicNoDevToken)(t, o)
				if state := strings.Join(o.state, "\n"); !strings.Contains(state, "rejected=false") || !strings.Contains(state, `dev token="" fetch failed=true file kept=false`) {
					t.Errorf("被拒的票应清掉(连文件),用户令牌不记被拒:%v", o.state)
				}
			},
		},
		{
			name: "令牌文件没记店面:问账号所在区并记下,再照常搜",
			prepare: func(t *testing.T) {
				user, _ := json.Marshal(applemusicUserTokenFile{MediaUserToken: "test-user-token", SavedAt: time.Now().Unix()})
				if err := os.WriteFile(applemusicUserTokenPath(), user, 0o600); err != nil {
					t.Fatal(err)
				}
			},
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.meStorefront = func(parityRequest) parityReply { return parityOK(`{"data":[{"id":"cn"}]}`) }
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), `status storefront="cn"`) {
					t.Errorf("问到的店面应记进状态文件:%v", o.state)
				}
			},
		},
		{
			name: "令牌文件没记店面、也问不到:这一路放弃,不猜一个区",
			prepare: func(t *testing.T) {
				user, _ := json.Marshal(applemusicUserTokenFile{MediaUserToken: "test-user-token", SavedAt: time.Now().Unix()})
				if err := os.WriteFile(applemusicUserTokenPath(), user, 0o600); err != nil {
					t.Fatal(err)
				}
			},
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.meStorefront = func(parityRequest) parityReply { return parityStatus(http.StatusInternalServerError) }
			}),
			wantRequests: 1,
		},
		{
			name: "逐字端点没有这首:退到逐行的 /lyrics", artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.lyrics = func(_ parityRequest, _, kind string) parityReply {
					if kind == "lyrics" {
						return parityOK(amTestLyricsBody(amTestLineTTML))
					}
					return parityStatus(http.StatusNotFound)
				}
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.yrc != "" || !strings.Contains(o.result.lyr, "first") {
					t.Errorf("应只有逐行:%+v", o.result)
				}
			},
		},
		{
			name: "只有不带时间轴的正文:交纯文本", artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.lyrics = func(parityRequest, string, string) parityReply { return parityOK(amTestLyricsBody(amTestUntimedTTML)) }
			}),
			wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.plainOnly || !strings.Contains(o.result.lyr, "第一句") {
					t.Errorf("应标 plainOnly:%+v", o.result)
				}
			},
		},
		{
			name: "搜到同名的两条、排前面的那条时长差得远:按时长淘汰它", artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.search = func(parityRequest, string) parityReply {
					return parityOK(amTestSearchBody(amParitySong("900", "公转自转", "王力宏", "公转.自转", 100000, true), song))
				}
			}),
			wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.srcDur != 256.227 {
					t.Errorf("应取时长对得上的那一条:%+v", o.result)
				}
			},
		},
		{
			name: "按名字搜不到:换日区再搜", artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.search = func(_ parityRequest, storefront string) parityReply {
					if storefront == "jp" {
						return parityOK(amTestSearchBody(song))
					}
					return parityOK(amTestSearchBody())
				}
			}),
			wantRequests: 3, wantLyrics: true,
		},
		{
			name: "搜索的主用主机 502:换备用主机", artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.search = func(r parityRequest, _ string) parityReply {
					if strings.Contains(r.target, "//amp-api.music.apple.com/") {
						return parityStatus(http.StatusBadGateway)
					}
					return parityOK(amTestSearchBody(song))
				}
			}),
			wantRequests: 3, wantLyrics: true,
		},
		{
			name: "播放侧记了目录 id:按它直取那一条,不搜,算播放器给定的身份", prepare: hinted,
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.search = nil
				f.song = func(parityRequest, string) parityReply { return parityOK(amTestSongBody(catalogSong)) }
			}),
			wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.identityFromLocalClient || len(o.cached) != 1 || !strings.Contains(o.cached[0], "|"+amTestCatalogID+"|") {
					t.Errorf("应算本机身份、缓存的键带目录 id:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "播放侧记了目录 id、这个区取不到那一条:按名字搜到的是另一条,不算本机身份", prepare: hinted,
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: hit.handler(), wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.identityFromLocalClient {
					t.Errorf("搜到的是另一条,不算本机身份:%+v", o.result)
				}
			},
		},
		{
			name: "播放侧记了目录 id、Music.app 自己的歌词缓存里有:不发请求,本机身份",
			prepare: func(t *testing.T) {
				hinted(t)
				resetAppleLocalIndex(t, writeAppleLocalCache(t, []appleLocalSpec{
					{ID: amTestCatalogID, Name: "公转自转", Rels: map[string]string{"syllable-lyrics": amTestWordTTML}},
				}))
			},
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: hit.handler(), wantRequests: 0, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.identityFromLocalClient || o.result.matchArtist != "某歌手" || o.result.yrc == "" {
					t.Errorf("应是 Music.app 缓存里那份、算本机身份:%+v", o.result)
				}
			},
		},
		{
			name: "播放器报的是繁体标签、检索词转成了简体:播放侧的目录 id 按原样标签认",
			prepare: func(t *testing.T) {
				notePlayingAppleCatalogID("王力宏", "公轉自轉", "公轉.自轉", amParityCatalogID())
			},
			ctx: func(ctx context.Context) context.Context {
				return withSearchQueryOriginal(ctx, "王力宏", "公轉自轉", "公轉.自轉")
			},
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.search = nil
				f.song = func(parityRequest, string) parityReply { return parityOK(amTestSongBody(catalogSong)) }
			}),
			wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.identityFromLocalClient {
					t.Errorf("应按原样标签认出播放侧记的目录 id、算本机身份:%+v", o.result)
				}
			},
		},
		{
			name: "别的歌那一轮:播放侧记的目录 id 不给,照常按名字搜", prepare: hinted, ctx: withOtherTrackRound,
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.song = func(parityRequest, string) parityReply { return parityOK(amTestSongBody(catalogSong)) }
			}),
			wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.identityFromLocalClient || len(o.cached) != 1 || strings.Contains(o.cached[0], amTestCatalogID) {
					t.Errorf("别的歌那一轮不读播放侧的目录 id:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name:   "手上有这条录音的 ISRC:先按 ISRC 直取,不按名字搜",
			ctx:    func(ctx context.Context) context.Context { return withRecordingISRC(ctx, amParityISRC) },
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.search = nil
				f.isrc = func(parityRequest, string) parityReply { return parityOK(amTestISRCBody(song)) }
			}),
			wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 1 || !strings.Contains(o.cached[0], "|"+amParityISRC+"|") || !strings.Contains(strings.Join(o.requests, "\n"), "filter%5Bisrc%5D="+amParityISRC) {
					t.Errorf("应按 ISRC 直取、缓存的键带着它:%v %v", o.cached, o.requests)
				}
			},
		},
		{
			name: "正在用 Apple Music 放、它没给词、目录说这条没有人声:交无人声信号", prepare: hintedAndPlaying,
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(noLyricsAnywhere("zxx")), wantRequests: 4,
			check: func(t *testing.T, o providerParityOutcome) {
				wantNoVocals(true)(t, o)
				if !strings.Contains(strings.Join(o.state, "\n"), "no-vocals cache "+amTestCatalogID+"=true") {
					t.Errorf("目录的结论应按目录 id 记下:%v", o.state)
				}
			},
		},
		{
			name: "正在用 Apple Music 放、它给了词:不问有没有人声", prepare: hintedAndPlaying,
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.song = func(parityRequest, string) parityReply {
					s := catalogSong
					s.Attributes.AudioLocale = "zxx"
					return parityOK(amTestSongBody(s))
				}
			}),
			wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.noVocals || !o.result.identityFromLocalClient {
					t.Errorf("有词就不问无人声,身份照旧来自目录 id:%+v", o.result)
				}
			},
		},
		{
			name: "正在用 Apple Music 放、它没给词、目录说这条有人声:不交", prepare: hintedAndPlaying,
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(noLyricsAnywhere("zh")), wantRequests: 4, check: wantNoVocals(false),
		},
		{
			name: "正在用 Apple Music 放、目录 id 开搜时还没有、搜的途中才核对完:等到它再问有没有人声", prepare: playingAppleMusic,
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: func() func(parityRequest) parityReply {
				inner := with(noLyricsAnywhere("zxx"))
				return func(r parityRequest) parityReply {
					if strings.HasPrefix(r.URL.Path, "/v1/catalog/jp/") {
						notePlayingAppleCatalogID(artist, title, album, amParityCatalogID())
					}
					return inner(r)
				}
			}(),
			wantRequests: 3, check: wantNoVocals(true),
		},
		{
			name: "正在用 Apple Music 放、目录 id 在等的时候才核对完:等到它",
			prepare: func(t *testing.T) {
				playingAppleMusic(t)
				withAppleNoVocalsWait(t, 3*time.Second)
			},
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: func() func(parityRequest) parityReply {
				inner := with(noLyricsAnywhere("zxx"))
				return func(r parityRequest) parityReply {
					if strings.HasPrefix(r.URL.Path, "/v1/catalog/jp/") {
						time.AfterFunc(20*time.Millisecond, func() { notePlayingAppleCatalogID(artist, title, album, amParityCatalogID()) })
					}
					return inner(r)
				}
			}(),
			wantRequests: 3, check: wantNoVocals(true),
		},
		{
			name: "正在用 Apple Music 放、目录 id 一直没有:等满上限,不交", prepare: playingAppleMusic,
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(noLyricsAnywhere("zxx")), wantRequests: 2, check: wantNoVocals(false),
		},
		{
			name: "待播队列里的曲目、目录 id 没有:不等,不交", prepare: playingAppleMusic,
			ctx:    func(ctx context.Context) context.Context { return withBackgroundOutbound(withPlayerQueueTrack(ctx)) },
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(noLyricsAnywhere("zxx")), wantRequests: 2, check: wantNoVocals(false),
		},
		{
			name: "待播队列里的曲目、目录 id 搜的途中才记下:不回头等它,不交", prepare: playingAppleMusic,
			ctx:    func(ctx context.Context) context.Context { return withBackgroundOutbound(withPlayerQueueTrack(ctx)) },
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: func() func(parityRequest) parityReply {
				inner := with(noLyricsAnywhere("zxx"))
				return func(r parityRequest) parityReply {
					if strings.HasPrefix(r.URL.Path, "/v1/catalog/jp/") {
						notePlayingAppleCatalogID(artist, title, album, amParityCatalogID())
					}
					return inner(r)
				}
			}(),
			wantRequests: 2, check: wantNoVocals(false),
		},
		{
			name: "待播队列里的曲目、播放侧记了目录 id:照样问有没有人声", prepare: hintedAndPlaying,
			ctx:    func(ctx context.Context) context.Context { return withBackgroundOutbound(withPlayerQueueTrack(ctx)) },
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(noLyricsAnywhere("zxx")), wantRequests: 4, check: wantNoVocals(true),
		},
		{
			name: "不是 Apple Music 在放:不问有没有人声", prepare: hinted,
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(noLyricsAnywhere("zxx")), wantRequests: 3, check: wantNoVocals(false),
		},
		{
			name: "手动搜索:播放器的信号不用,不问有没有人声", prepare: hintedAndPlaying, ctx: withManualLyricSearch,
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(noLyricsAnywhere("zxx")), wantRequests: 3, check: wantNoVocals(false),
		},
		{
			name: "后台补搜(不是在放的这首):播放器的信号不用", prepare: hintedAndPlaying, ctx: withBackgroundOutbound,
			artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(noLyricsAnywhere("zxx")), wantRequests: 3, check: wantNoVocals(false),
		},
		{
			name: "同一首连问两轮:第二轮读进程内缓存", rounds: 2, artist: artist, title: title, album: album, durationSecs: 256,
			handle: hit.handler(), wantRequests: 2, wantLyrics: true,
		},
		{
			name: "歌名带编号:拿带编号的那份去搜、去挑候选,ISRC 和播放侧的目录 id 按不带编号的认",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "公转自转 (#2)", artist, title, album)
			},
			prepare: hinted,
			artist:  artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.search = func(parityRequest, string) parityReply {
					return parityOK(amTestSearchBody(amParitySong("1001", "公转自转 (#2)", "王力宏", "公转.自转", 256227, true)))
				}
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "公转自转 (#2)" || len(o.cached) != 1 || !strings.HasPrefix(o.cached[0], "王力宏|公转自转 (#2)|公转.自转|"+amTestCatalogID+"|") {
					t.Errorf("应挑中带编号的那条,缓存的键按带编号的歌名、带着按不带编号的歌名认出的目录 id:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "后台吃到 429:后台请求暂停", ctx: withBackgroundOutbound, artist: artist, title: title, album: album, durationSecs: 256,
			handle: with(func(f *amParityFake) {
				f.search = func(parityRequest, string) parityReply { return parityStatus(http.StatusTooManyRequests) }
			}),
			wantRequests: 1,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "background paused amp-api.music.apple.com") {
					t.Errorf("后台档 429 后后台请求应暂停:%v", o.state)
				}
			},
		},
		{
			name: "设置里关掉:播放侧的目录 id、Music.app 的缓存都不读", disabled: true,
			prepare: func(t *testing.T) {
				hintedAndPlaying(t)
				resetAppleLocalIndex(t, writeAppleLocalCache(t, []appleLocalSpec{
					{ID: amTestCatalogID, Name: "公转自转", Rels: map[string]string{"syllable-lyrics": amTestWordTTML}},
				}))
			},
			artist: artist, title: title, album: album, durationSecs: 256, handle: with(noLyricsAnywhere("zxx")),
		},
		{
			name: "熔断冷却:Music.app 的缓存有也不读(没有本机那条腿),记跳过", cooling: true,
			prepare: func(t *testing.T) {
				hintedAndPlaying(t)
				resetAppleLocalIndex(t, writeAppleLocalCache(t, []appleLocalSpec{
					{ID: amTestCatalogID, Name: "公转自转", Rels: map[string]string{"syllable-lyrics": amTestWordTTML}},
				}))
			},
			artist: artist, title: title, album: album, durationSecs: 256, handle: with(noLyricsAnywhere("zxx")), wantSkips: true,
		},
	}
	cases = append(cases, providerParitySkipCases(artist, title, 256)...)
	runProviderParity(t, appleMusicParitySource, cases)
}

func TestAppleMusicProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, appleMusicParitySource, "王力宏", "公转自转", 256)
}

func TestAppleMusicProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, appleMusicParitySource, "王力宏", "公转自转", 256, parityNotFound)
}
