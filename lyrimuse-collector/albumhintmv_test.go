package main

import (
	"context"
	"testing"
)

// MV 配专辑用歌曲版时长(albumHintDurationSecs):MV 自己的时长带着片头片尾,拿它配 max(4s, 3%) 的容差配不上。
// 数字取自一次真机现场(见 02 章决策 27 追加):MV 244.221s,各歌词源报歌曲版 159s,另有一条 237s 的别的版本,
// Apple 目录里那首 159.008s。

func swimMVDecision() *lyricsDecision {
	return &lyricsDecision{Winner: "kugou", Candidates: []lyricsDecisionCandidate{
		{Source: "kugou", Artist: "BTS (防弹少年团)", SourceReportedDurationSecs: 159},
		{Source: "musixmatch", Artist: "BTS", SourceReportedDurationSecs: 237},
		{Source: "lrclib", Artist: "BTS", SourceReportedDurationSecs: 159},
	}}
}

func TestDecisionSongDurationSecs(t *testing.T) {
	if got := decisionSongDurationSecs(swimMVDecision()); got != 159 {
		t.Fatalf("胜出候选自报的曲长优先,得到 %v", got)
	}
	// 显示的是哪份歌词就按哪份的曲长,哪怕它跟多数候选不一样。
	minority := swimMVDecision()
	minority.Winner = "musixmatch"
	if got := decisionSongDurationSecs(minority); got != 237 {
		t.Fatalf("胜出候选优先于中位数,得到 %v", got)
	}
	// 胜出的那条没报曲长:退回全部候选的中位数。
	noWinnerDuration := &lyricsDecision{Winner: "qq", Candidates: []lyricsDecisionCandidate{
		{Source: "qq"}, {Source: "kugou", SourceReportedDurationSecs: 159},
		{Source: "musixmatch", SourceReportedDurationSecs: 237}, {Source: "lrclib", SourceReportedDurationSecs: 159},
	}}
	if got := decisionSongDurationSecs(noWinnerDuration); got != 159 {
		t.Fatalf("中位数,得到 %v", got)
	}
	if got := decisionSongDurationSecs(&lyricsDecision{Winner: "kugou", Candidates: []lyricsDecisionCandidate{{Source: "kugou"}}}); got != 0 {
		t.Fatalf("没有任何曲长是 0,得到 %v", got)
	}
	if got := decisionSongDurationSecs(nil); got != 0 {
		t.Fatalf("没有判决是 0,得到 %v", got)
	}
}

func TestAlbumHintDurationSecs(t *testing.T) {
	saved := enrichCache
	defer func() { enrichCache = saved }()
	enrichCache = map[string]enrichEntry{"BTS|SWIM|": {LyricsDecisionApplied: swimMVDecision()}}
	mv := snapshot{Artist: "BTS", Title: "SWIM", Duration: 244.221, NotAudio: true}
	if got := albumHintDurationSecs(mv); got != 159 {
		t.Fatalf("MV 用歌曲版时长,得到 %v", got)
	}
	song := mv
	song.NotAudio = false
	if got := albumHintDurationSecs(song); got != 244.221 {
		t.Fatalf("不是 MV 照用播放器报的时长,得到 %v", got)
	}
	enrichCache = map[string]enrichEntry{}
	if got := albumHintDurationSecs(mv); got != 0 {
		t.Fatalf("判决还没出来不退回 MV 时长,得到 %v", got)
	}
}

// 接线:albumHintFor 对 MV 按歌曲版时长查缓存、配出专辑。候选按 159s 取(同 appleAlbumHint 后台那次),
// 缓存只按 159 这个 key 放 —— 要是还拿 MV 时长去查,key 对不上,这一拍拿不到专辑。
func TestAlbumHintForMusicVideoUsesSongDuration(t *testing.T) {
	savedCache, savedHint, savedMisses, savedInflight, savedLogged :=
		enrichCache, appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintLogged
	defer func() {
		enrichCache, appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintLogged =
			savedCache, savedHint, savedMisses, savedInflight, savedLogged
	}()
	results := []itunesResult{
		{TrackName: "SWIM", ArtistName: "BTS", CollectionName: "ARIRANG", CollectionID: 1868481904, TrackTimeMillis: 159008},
		{TrackName: "SWIM (Instrumental)", ArtistName: "Piano Dreamers", CollectionName: "Piano Dreamers Play BTS, Vol. 4 (Instrumental)", TrackTimeMillis: 160400},
		{TrackName: "Swim", ArtistName: "Henry Green", CollectionName: "Swim - Single", TrackTimeMillis: 243101},
	}
	appleAlbumHintCache = map[string][]albumHintCandidate{
		appleAlbumHintKey("BTS", "SWIM", 159): albumHintCandidatesFromResults(results, "SWIM", 159),
	}
	// 在飞标记挡住后台查询:key 对不上时这一拍只会返回空,不会真的去联网。
	appleAlbumHintInflight = map[string]bool{appleAlbumHintKey("BTS", "SWIM", 244.221): true}
	appleAlbumHintMisses = map[string]int{}
	appleAlbumHintLogged = map[string]string{}
	enrichCache = map[string]enrichEntry{"BTS|SWIM|": {LyricsDecisionApplied: swimMVDecision()}}
	p := &poller{ctx: context.Background()}
	mv := snapshot{Artist: "BTS", Title: "SWIM", Duration: 244.221, NotAudio: true, Bundle: "com.apple.Music"}
	if got := p.albumHintFor(mv); got != "ARIRANG" {
		t.Fatalf("MV 要按歌曲版时长配出 ARIRANG,得到 %q", got)
	}
	// 同一份候选若按 MV 时长取,244s 那条同名歌(另一位歌手)配得上、本尊那条配不上 —— 所以不能拿 MV 时长去配。
	if got := albumHintCandidatesFromResults(results, "SWIM", 244.221); len(got) != 1 || got[0].Artist != "Henry Green" {
		t.Fatalf("按 MV 时长只剩别人的同名歌,得到 %+v", got)
	}
}
