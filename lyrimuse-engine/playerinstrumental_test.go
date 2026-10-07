package main

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

const playerTestLRC = "[00:01.00]第一句歌词在这里\n[00:05.00]第二句歌词在这里\n[00:09.00]第三句歌词在这里\n" +
	"[00:13.00]第四句歌词在这里\n[00:17.00]第五句歌词在这里\n[00:21.00]第六句歌词在这里\n"

// playingFor 把「正在播的播放器」设成 player,用例结束时清掉。
func playingFor(t *testing.T, player string) {
	t.Helper()
	setNativeLyricSourcesForPlayer(playerBundleIDs[player])
	t.Cleanup(func() { setNativeLyricSourcesForPlayer("") })
}

// rankForPlayerTest:按「解析的是正在放的那首」打分(收集循环给每份结果填 forPlayingTrack)。
func rankForPlayerTest(raw map[string]lyricSourceResult) []scoredLyricCandidateResult {
	for k, r := range raw {
		r.forPlayingTrack = true
		raw[k] = r
	}
	return rankLyricSourceResults("歌手", "歌名", "", 25, raw)
}

func kugouWithLyrics() lyricSourceResult {
	return lyricSourceResult{source: "kugou", lyr: playerTestLRC, matchTitle: "歌名", matchArtist: "歌手", srcDur: 25}
}

func TestPlayerInstrumentalOverridesOtherSourcesLyrics(t *testing.T) {
	playingFor(t, playerNetease)
	raw := map[string]lyricSourceResult{
		"netease": {source: "netease", ne: neteaseInfo{FromLocalClient: true, NoVocals: true, SongID: 1}},
		"kugou":   kugouWithLyrics(),
	}
	scored := rankForPlayerTest(raw)
	if !playerSaysInstrumental(scored) {
		t.Fatalf("网易云在放、它的客户端曲库说这一条没有人声、它自己没给词:该有播放器的纯音乐标记,得到 %+v", scored)
	}
	if got := pickLyricCandidate(scored); got != nil {
		t.Fatalf("播放器说是纯音乐时别的源的词不当冠军,得到 %s(%d)", got.Source, got.Score)
	}
	if ok, src := instrumentalFromScored(scored, "歌手", "歌名", "", 25); !ok || src != "netease" {
		t.Fatalf("纯音乐结论该记在网易云名下,得到 %v %q", ok, src)
	}
}

func TestPlayerInstrumentalYieldsToPlayersOwnLyrics(t *testing.T) {
	playingFor(t, playerNetease)
	raw := map[string]lyricSourceResult{
		"netease": {source: "netease", ne: neteaseInfo{FromLocalClient: true, NoVocals: true, SongID: 1, Lyrics: playerTestLRC, Title: "歌名", Artist: "歌手", DurationSecs: 25}},
		"kugou":   kugouWithLyrics(),
	}
	scored := rankForPlayerTest(raw)
	if playerSaysInstrumental(scored) {
		t.Fatal("播放器自己有这一条的歌词(有词的伴奏版):不该标纯音乐")
	}
	if got := pickLyricCandidate(scored); got == nil {
		t.Fatal("有词的伴奏版照常选歌词")
	}
}

func TestPlayerInstrumentalNeedsThePlayingPlayerAndLocalIdentity(t *testing.T) {
	cases := []struct {
		name   string
		player string
		ne     neteaseInfo
	}{
		{"别的播放器在放:网易云的无人声位只算搜出来的信号", playerQQMusic, neteaseInfo{FromLocalClient: true, NoVocals: true, SongID: 1}},
		{"身份是搜出来的", playerNetease, neteaseInfo{NoVocals: true, SongID: 1}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			playingFor(t, c.player)
			scored := rankForPlayerTest(map[string]lyricSourceResult{"netease": {source: "netease", ne: c.ne}, "kugou": kugouWithLyrics()})
			if playerSaysInstrumental(scored) {
				t.Fatal("不该算播放器自己的纯音乐信号")
			}
			if got := pickLyricCandidate(scored); got == nil || got.Source != "kugou" {
				t.Fatalf("别的源有词时照常用词,得到 %v", got)
			}
		})
	}
}

func TestPlayerInstrumentalOnlyForThePlayingTrack(t *testing.T) {
	playingFor(t, playerNetease)
	raw := map[string]lyricSourceResult{
		"netease": {source: "netease", ne: neteaseInfo{FromLocalClient: true, NoVocals: true, SongID: 1}},
		"kugou":   kugouWithLyrics(),
	}
	scored := rankLyricSourceResults("歌手", "歌名", "", 25, raw)
	if playerSaysInstrumental(scored) {
		t.Fatal("解析的不是在放的那首(补空扫描、全量扫库、专辑预取、手动搜索):播放器的信号不算")
	}
	if got := pickLyricCandidate(scored); got == nil || got.Source != "kugou" {
		t.Fatalf("只剩搜出来的信号时别的源的词照常用,得到 %v", got)
	}
	bg := withBackgroundOutbound(context.Background())
	for _, c := range []struct {
		name string
		ctx  context.Context
		want bool
	}{
		{"在放的那首", context.Background(), true},
		{"后台批量(补空、扫库、专辑预取)", bg, false},
		{"待播队列", withPlayerQueueTrack(bg), true},
		{"手动搜索 / 手动重新匹配", withManualLyricSearch(context.Background()), false},
	} {
		if got := playerSignalApplies(c.ctx); got != c.want {
			t.Errorf("%s: playerSignalApplies = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestPlayerInstrumentalYieldsToPlayersOwnPlainLyrics(t *testing.T) {
	playingFor(t, playerQQMusic)
	own := lyricSourceResult{source: "qq", noVocals: true, identityFromLocalClient: true, lyr: "第一句歌词\n第二句歌词\n第三句歌词", plainOnly: true}
	if scored := rankForPlayerTest(map[string]lyricSourceResult{"qq": own, "kugou": kugouWithLyrics()}); playerSaysInstrumental(scored) {
		t.Fatal("播放器自己有这一条的纯文本歌词(伴奏版):不该标纯音乐")
	}
}

func TestEarlyLyricsHoldsForNativeWhenPlayerHintsNoVocals(t *testing.T) {
	isolateEarlyLyricsState(t)
	earlyLyricsGrace = 20 * time.Millisecond
	noteEnrichPlayingKey("A|T|Al")
	playingFor(t, playerNetease)
	var calls []string
	record := func(_ neteaseInfo, r []scoredLyricCandidateResult) {
		calls = append(calls, pickLyricCandidate(r).Source)
	}
	lineOnly := []scoredLyricCandidateResult{earlyCand("kugou", earlyTermTitle, earlyTermDur, earlyTermLines)}
	for _, hold := range []bool{true, false} {
		calls = nil
		w := newEarlyLyricsWatch(withProvisionalLyrics(withEarlyLyricsTarget(context.Background(), "A|T|Al"), record), "A", "T")
		w.holdForNative = hold
		w.observe(neteaseInfo{}, lineOnly, map[string]bool{"kugou": true})
		select {
		case <-w.graceC():
		case <-time.After(2 * time.Second):
			t.Fatal("宽限计时没到点")
		}
		w.endGrace()
		w.observe(neteaseInfo{}, lineOnly, map[string]bool{"kugou": true})
		if hold && len(calls) != 0 {
			t.Fatalf("本机数据说没有人声、网易云还没回话:宽限期到了也不先上屏,得到 %v", calls)
		}
		if !hold && !slices.Equal(calls, []string{"kugou"}) {
			t.Fatalf("没有这个提示时照旧等满就上,得到 %v", calls)
		}
		if hold {
			w.observe(neteaseInfo{}, lineOnly, map[string]bool{"kugou": true, "netease": true})
			if !slices.Equal(calls, []string{"kugou"}) {
				t.Fatalf("网易云回话、没带纯音乐标记:照常先上屏,得到 %v", calls)
			}
		}
		w.finish(2, 2)
	}
}

func TestPlayerInstrumentalEachPlayer(t *testing.T) {
	cases := []struct {
		player string
		src    string
		res    lyricSourceResult
	}{
		{playerQQMusic, "qq", lyricSourceResult{source: "qq", noVocals: true, identityFromLocalClient: true}},
		{playerQQMusic, "qq", lyricSourceResult{source: "qq", instrumental: true, identityFromLocalClient: true}},
		{playerSoda, "soda", lyricSourceResult{source: "soda", noVocals: true, identityFromLocalClient: true}},
		{playerAppleMusic, "applemusic", lyricSourceResult{source: "applemusic", noVocals: true, identityFromLocalClient: true}},
		{playerSpotify, spotifyLocalLyricsSource, lyricSourceResult{source: spotifyLocalLyricsSource, noVocals: true, identityFromLocalClient: true}},
	}
	for _, c := range cases {
		t.Run(c.player+"/"+c.src, func(t *testing.T) {
			playingFor(t, c.player)
			scored := rankForPlayerTest(map[string]lyricSourceResult{c.src: c.res, "kugou": kugouWithLyrics()})
			if !playerSaysInstrumental(scored) || pickLyricCandidate(scored) != nil {
				t.Fatalf("%s 在放、它自己说没有人声:该按纯音乐处理", c.player)
			}
		})
	}
	// Spotify 本地缓存的信号只在 Spotify 在放时算播放器自己的。
	playingFor(t, playerAppleMusic)
	other := lyricSourceResult{source: spotifyLocalLyricsSource, noVocals: true, identityFromLocalClient: true}
	if scored := rankForPlayerTest(map[string]lyricSourceResult{spotifyLocalLyricsSource: other, "kugou": kugouWithLyrics()}); playerSaysInstrumental(scored) {
		t.Fatal("Apple Music 在放时,Spotify 缓存里的信号不算播放器自己的")
	}
	// Spotify 自己缓存里有这一条的词:照常用词。
	playingFor(t, playerSpotify)
	own := lyricSourceResult{source: spotifyLocalLyricsSource, noVocals: true, identityFromLocalClient: true, lyr: playerTestLRC, matchTitle: "歌名", matchArtist: "歌手", srcDur: 25}
	if scored := rankForPlayerTest(map[string]lyricSourceResult{spotifyLocalLyricsSource: own}); playerSaysInstrumental(scored) || pickLyricCandidate(scored) == nil {
		t.Fatal("Spotify 自己有这一条的词时照常用词")
	}
}

func TestSearchedNoVocalsSignals(t *testing.T) {
	playingFor(t, playerKKBOX)
	placeholder := "[00:00.00]此歌曲为纯音乐，请欣赏"
	for _, c := range []struct {
		name, src string
		res       lyricSourceResult
	}{
		{"QQ 语种纯音乐", "qq", lyricSourceResult{source: "qq", noVocals: true}},
		{"咪咕占位", "migu", lyricSourceResult{source: "migu", lyr: placeholder}},
		{"酷狗语种纯音乐", "kugou", lyricSourceResult{source: "kugou", noVocals: true}},
	} {
		t.Run(c.name, func(t *testing.T) {
			scored := rankForPlayerTest(map[string]lyricSourceResult{c.src: c.res})
			ok, src := instrumentalFromScored(scored, "歌手", "歌名", "", 25)
			if !ok || src != c.src || playerSaysInstrumental(scored) {
				t.Fatalf("搜出来的信号:该有一条 %s 的普通纯音乐标记,得到 %v %q", c.src, ok, src)
			}
		})
	}
	// 搜出来的信号只在没有能用的歌词时起作用:同一个源自己有词就不发标记,别的源有词时照常选词。
	withOwn := kugouWithLyrics()
	withOwn.noVocals = true
	scored := rankForPlayerTest(map[string]lyricSourceResult{"kugou": withOwn})
	if scoredHasInstrumentalMarker(scored) {
		t.Fatal("酷狗自己有词时不发纯音乐标记")
	}
	scored = rankForPlayerTest(map[string]lyricSourceResult{"qq": {source: "qq", noVocals: true}, "kugou": kugouWithLyrics()})
	if got := pickLyricCandidate(scored); got == nil || got.Source != "kugou" {
		t.Fatalf("搜出来的纯音乐信号挡不住别的源的词,得到 %v", got)
	}
}

func TestMergeKeepsPlayerInstrumentalMarker(t *testing.T) {
	searched := scoredLyricCandidateResult{Source: "lrclib", Score: -1, Instrumental: true}
	player := scoredLyricCandidateResult{Source: "netease", Score: -1, Instrumental: true, PlayerInstrumental: true}
	rejected := scoredLyricCandidateResult{Source: "netease", Score: -1, Lyrics: "[00:00.00] 作曲 : 甲\n"}
	out := mergeLyricCandidateRounds("歌手", "歌名", "", 25, []scoredLyricCandidateResult{searched}, []scoredLyricCandidateResult{player, rejected})
	if !playerSaysInstrumental(out) {
		t.Fatalf("播放器的标记压过先到的搜出来的标记;同源只有判废的候选时标记留着,得到 %+v", out)
	}
}

// 解析决策存档要带上「这条标记是播放器给的」,面板才说得清其余候选为什么都没采用。
func TestDecisionKeepsPlayerInstrumentalMarker(t *testing.T) {
	scored := []scoredLyricCandidateResult{{Source: "kugou", Score: 300}, {Source: "netease", Score: -1, Instrumental: true, PlayerInstrumental: true}}
	d := buildLyricsDecision(lyricsDecisionPathFirstResolve, "歌手", "歌名", "", 25, scored, nil, false)
	found := false
	for _, c := range d.Candidates {
		if c.Source == "netease" {
			found = c.Instrumental && c.PlayerInstrumental
		}
	}
	if d.Winner != "" || !found {
		t.Fatalf("没有冠军,标记那行带着 player_instrumental:winner=%q candidates=%+v", d.Winner, d.Candidates)
	}
}

func TestRescoreTurnsInstrumentalOnPlayerMarker(t *testing.T) {
	e := enrichEntry{Lyrics: playerTestLRC, LyricsSource: "kugou"}
	scored := []scoredLyricCandidateResult{{Source: "kugou", Score: 300}, {Source: "netease", Score: -1, Instrumental: true, PlayerInstrumental: true}}
	if !rescoreTurnsInstrumental(e, scored) {
		t.Fatal("播放器说是纯音乐:重评时现有的词改按纯音乐处理")
	}
	e.InstrumentalCleared = true
	if rescoreTurnsInstrumental(e, scored) {
		t.Fatal("用户撤过纯音乐标记的不再标")
	}
}

func testSpotifyTrackWithLanguages(langs ...string) []byte {
	v := pbMsg(pbStr(2, "某首歌"), pbVarint(7, 360000))
	for _, l := range langs {
		v = append(v, pbStr(spotifyTrackLanguageField, l)...)
	}
	return pbMsg(pbVarint(1, 10), pbBytes(2, pbMsg(pbStr(1, "type.googleapis.com/spotify.metadata.Track"), pbBytes(2, v))))
}

func TestSpotifyLocalNoVocals(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Users")
	dir := filepath.Join(root, "acct-user", "primary.ldb")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	testWriteTable(t, filepath.Join(dir, "000123.ldb"), []testLDBEntry{
		{key: string(spotifyXmetaKey(spotifyTrackKind, testSpotifyID1)), seq: 1, value: string(testSpotifyTrackWithLanguages("zxx"))},
		{key: string(spotifyXmetaKey(spotifyTrackKind, testSpotifyID2)), seq: 2, value: string(testSpotifyTrackWithLanguages("en"))},
		{key: string(spotifyXmetaKey(spotifyTrackKind, testSpotifyID3)), seq: 3, value: string(testSpotifyTrackWithLanguages())},
	}, 2, true)
	resetSpotifyISRCCache(t, root)
	for id, want := range map[string]bool{testSpotifyID1: true, testSpotifyID2: false, testSpotifyID3: false, "short": false} {
		if got := spotifyLocalNoVocals(id); got != want {
			t.Errorf("%s: spotifyLocalNoVocals = %v, want %v", id, got, want)
		}
	}
}

func TestApplemusicCatalogNoVocals(t *testing.T) {
	withApplemusicCreds(t, "cn")
	applemusicNoVocalsMu.Lock()
	saved := applemusicNoVocalsCache
	applemusicNoVocalsCache = map[string]bool{}
	applemusicNoVocalsMu.Unlock()
	t.Cleanup(func() {
		applemusicNoVocalsMu.Lock()
		applemusicNoVocalsCache = saved
		applemusicNoVocalsMu.Unlock()
	})
	hits := 0
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/songs/1"):
			hits++
			return http.StatusOK, nil, `{"data":[{"id":"1","attributes":{"audioLocale":"zxx"}}]}`
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/songs/2"):
			return http.StatusOK, nil, `{"data":[{"id":"2","attributes":{"audioLocale":"zh-Hans-CN"}}]}`
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/songs/3"):
			return http.StatusInternalServerError, nil, ""
		}
		return http.StatusNotFound, nil, ""
	})
	for id, want := range map[string]bool{"1": true, "2": false, "3": false, "404": false, "": false} {
		if got := applemusicCatalogNoVocals(qqRoundCtx(), id); got != want {
			t.Errorf("%q: applemusicCatalogNoVocals = %v, want %v", id, got, want)
		}
	}
	applemusicCatalogNoVocals(qqRoundCtx(), "1")
	if hits != 1 {
		t.Errorf("问成的按目录 id 缓存,第二次不该再发请求,实际 %d 次", hits)
	}
	applemusicNoVocalsMu.Lock()
	_, cached := applemusicNoVocalsCache["3"]
	applemusicNoVocalsMu.Unlock()
	if cached {
		t.Error("没问成的不缓存")
	}
}

func TestApplemusicCatalogNoVocalsWithoutAccountStorefront(t *testing.T) {
	withApplemusicCreds(t, "")
	applemusicNoVocalsMu.Lock()
	saved := applemusicNoVocalsCache
	applemusicNoVocalsCache = map[string]bool{}
	applemusicNoVocalsMu.Unlock()
	t.Cleanup(func() {
		applemusicNoVocalsMu.Lock()
		applemusicNoVocalsCache = saved
		applemusicNoVocalsMu.Unlock()
	})
	var asked []string
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		asked = append(asked, r.URL.Path)
		switch {
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/songs/7"):
			return http.StatusOK, nil, `{"data":[{"id":"7","attributes":{"audioLocale":"zxx"}}]}`
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/us/songs/8"):
			return http.StatusOK, nil, `{"data":[{"id":"8","attributes":{"audioLocale":"en-US"}}]}`
		}
		return http.StatusNotFound, nil, ""
	})
	if !applemusicCatalogNoVocals(qqRoundCtx(), "7") {
		t.Fatalf("美区查不到、国区查到 zxx:没有人声,问过 %v", asked)
	}
	asked = nil
	if applemusicCatalogNoVocals(qqRoundCtx(), "8") || len(asked) != 1 {
		t.Fatalf("美区查到了就不再问国区,问过 %v", asked)
	}
	if applemusicCatalogNoVocals(qqRoundCtx(), "9") {
		t.Fatal("两个区都查不到:算有人声")
	}
}

// 接线守卫:各源把「没有人声」带进原始应答,播放器说是纯音乐时检索不再换身份重搜。
func TestPlayerInstrumentalSignalsAreWired(t *testing.T) {
	enrich := string(mustRead(t, "enrich.go"))
	for _, n := range []string{
		"qqNoVocals := qqMeta.id != 0 && qqMeta.language == qqLanguagePureMusic",
		"instrumental: qqInstrumental, noVocals: qqNoVocals,",
		"language: r.language, noVocals: r.noVocals,",
		"noVocals := r.fromLocalClient && sodaLocalInstrumental(artist, srcTitle, album, durationSecs)",
		"trackFoundNoLyrics: noLyrics, noVocals: noVocals,",
		"appleNoVocals := forPlaying && r.lyrics == \"\" && appleID != \"\" && playingPlayer() == playerAppleMusic && applemusicCatalogNoVocals(ctx, appleID)",
		"lyricSourceResult{noVocals: appleNoVocals, source: \"applemusic\",",
		"identityFromLocalClient: r.fromLocalClient || appleNoVocals}",
		"if src := playerInstrumentalSource(raw, results); src != \"\" {",
		"forPlaying := playerSignalApplies(ctx)",
		"r.forPlayingTrack = forPlaying\n\t\t\traw[r.source] = r",
		"if forPlaying && playingPlayer() == playerSpotify && spotifyLocalNoVocals(",
		"earlyWatch.holdForNative = playerLocalNoVocalsHint(artist, srcTitle, album, durationSecs)",
		"if !turnedInstrumental && adoptCrossAlbumSiblingLyrics(key, &e) {",
	} {
		if !strings.Contains(enrich, n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
	i := strings.Index(enrich, "func scoredLyricCandidatesStreaming(")
	body := enrich[i:]
	if j := strings.Index(body, "if !hasUsableLyricCandidate(results) && !coverPerformerOnly(ctx) {"); j < 0 ||
		!strings.Contains(body[:j], "if playerSaysInstrumental(results) && !manualLyricSearch(ctx) {\n\t\treturn ne, results\n\t}") {
		t.Error("播放器说是纯音乐时,首轮之后就该返回,排在所有换身份重搜的轮次之前")
	}
	if !strings.Contains(string(mustRead(t, "kugou.go")), "r.noVocals = chosen.TransParam.Language == kugouLanguagePureMusic") {
		t.Error("kugou.go 挑中曲目之后要记下它的语种是不是纯音乐")
	}
	if !strings.Contains(string(mustRead(t, "upcoming.go")), "go resolveEnrichAsync(withBackgroundOutbound(withPlayerQueueTrack(") {
		t.Error("待播队列预取要标成正在放的播放器的队列(withPlayerQueueTrack),播放器的信号才对它们成立")
	}
}
