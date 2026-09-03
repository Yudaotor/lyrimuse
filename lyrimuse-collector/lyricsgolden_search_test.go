// lyricsgolden_search_test.go — **检索层**的回归金标:一个源对一首歌返回的那一批搜索结果里,该选谁。
//
// 第一层(lyricsgolden_test.go)守的是"拿到各源的最终候选之后怎么打分挑冠军";这一层守的是再往前
// 一步——各源自己的**身份闸 + 挑选**:同名歌里混着翻唱/演奏/卡拉OK/另一场演唱会/另一位歌手的同名歌,
// 源模块要在自己的搜索结果里挑出"就是本地这首"的那一条,挑不出就宁可空手(第 09 章那几条真实错配
// ——打上花火→春雷、The One 演唱会→录音室版、孤独探戈落在错场次——都是死在这一步)。
//
// 四个源有自己的挑选逻辑,四个纯函数各接一份样本:
//   - netease:neteasePickSong(2026-09-04 从 resolveNeteaseInfo 的 pick 闭包提出)
//   - qq:qqCollectCandidates(strict / loose 两档)→ qqPickCandidateWithAlbum(有本地专辑名)/ qqPickCandidate
//   - kugou:pickKugouSearchCandidate(含 lyricRecordingTriangleMatches 第三档)
//   - lrclib:pickLRCLIBSearchResultDetailed(先带时间戳、再纯文本兜底)
//
// 样本 = 真实搜索结果的**元数据**(id / 歌名 / 歌手 / 专辑 / 自报时长 / 语种)+ 本地查询词 + 期望的挑选
// 结果。歌名/歌手/专辑不是歌词正文,不置乱;只有 lrclib 的搜索结果自带正文,那部分照第一层的规矩置乱。
// 样本在 testdata/lyricsgolden/search/<id>.json,由 TestLyricsSearchGoldenCapture 联网采集(默认跳过)。
//
// 挑选结果"对不对"同样不信缓存:goldenJudgeSearchPick 要求选中的那条歌名过闸、歌手对得上、自报时长
// 偏差 ≤3%、版本限定词一致、live 声明对称;选了空的样本要求这批结果里**确实没有**满足这些条件的
// 候选(否则就是"有像样的候选却放弃了"——那是有争议的边界,不进金标)。
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

const lyricsSearchGoldenDir = "testdata/lyricsgolden/search"

var lyricsSearchGoldenSources = []string{"netease", "qq", "kugou", "lrclib"}

type searchGoldenFixture struct {
	ID         string      `json:"id"`
	Source     string      `json:"source"`
	Note       string      `json:"note,omitempty"`
	Track      goldenTrack `json:"track"`
	CapturedAt string      `json:"captured_at"`
	// Query:这个源的挑选函数实际拿到的查询词与时长(qq 的挑选不看时长,记 0)。
	Query goldenQuery `json:"query"`
	// LocalDurationSecs:本地曲长。挑选函数没拿到时长的源(qq)用它来核对选中那条的自报时长。
	LocalDurationSecs float64 `json:"local_duration_secs"`
	// Items:该源这一次搜索返回的全部条目,按返回顺序。
	Items []searchGoldenItem `json:"items"`
	// AlbumLookup(qq 特有):候选没自带专辑名时,生产会按 qqAlbumLookupBudget 的预算去查详情——采集时
	// 用同一个纯函数、同一份预算逻辑真的查一遍并记下 mid → 专辑名,回放时照表还原,不联网。
	AlbumLookup map[string]string  `json:"album_lookup,omitempty"`
	Expect      searchGoldenExpect `json:"expect"`
	Judge       searchGoldenJudge  `json:"judge"`
}

// searchGoldenItem 是四个源搜索结果的公共形态;各源特有字段按需填。
type searchGoldenItem struct {
	// ID:netease 歌曲 id / qq mid / kugou hash / lrclib 用 "#序号"(接口不返回 id)。
	ID     string `json:"id"`
	Title  string `json:"title"`
	Artist string `json:"artist,omitempty"`
	// Artists:netease 的歌手是数组(合唱曲每人一条),原样保留;其它源用 Artist 一个字段。
	Artists      []string `json:"artists,omitempty"`
	Album        string   `json:"album,omitempty"`
	AlbumID      string   `json:"album_id,omitempty"`
	DurationSecs float64  `json:"duration_secs,omitempty"`
	// Language:kugou trans_param.language 的原始字符串("国语"/"粤语")。
	Language string `json:"language,omitempty"`
	// lrclib 特有:instrumental 标记与(置乱后的)正文。
	Instrumental bool   `json:"instrumental,omitempty"`
	SyncedLyrics string `json:"synced_lyrics,omitempty"`
	PlainLyrics  string `json:"plain_lyrics,omitempty"`
}

type searchGoldenExpect struct {
	// PickedID:最终选中的条目 id;"" = 这批结果里一条都不认。
	PickedID string `json:"picked_id"`
	// qq 特有:strict / loose 两档身份闸各放行了哪些 mid(按顺序),以及不看专辑时 qqPickCandidate 会选谁。
	AcceptedStrict []string `json:"accepted_strict,omitempty"`
	AcceptedLoose  []string `json:"accepted_loose,omitempty"`
	PickedNoAlbum  string   `json:"picked_no_album,omitempty"`
	// lrclib 特有:选中的那条是不是纯文本兜底。
	PlainOnly bool `json:"plain_only,omitempty"`
}

// searchGoldenJudge:选中那条的独立判据(见 goldenJudgeSearchPick)。
type searchGoldenJudge struct {
	TitleAccepted          bool    `json:"title_accepted"`
	ArtistMatches          bool    `json:"artist_matches"`
	SourceDurationDeltaPct float64 `json:"source_duration_delta_pct"` // -1 = 该条没自报时长
	VersionTagsOK          bool    `json:"version_tags_ok"`
	LiveMismatch           bool    `json:"live_mismatch"`
	// PlausibleAlternatives:选空时,这批结果里满足"歌名过闸 + 歌手对得上 + 时长 ≤3%"的条目数——
	// 必须是 0,不然"选空"就不是没有争议的结论。
	PlausibleAlternatives int `json:"plausible_alternatives"`
}

// ---------- 加载 ----------

func loadSearchGoldenFixtures(t *testing.T) []*searchGoldenFixture {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(lyricsSearchGoldenDir, "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(files)
	var out []*searchGoldenFixture
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		var fx searchGoldenFixture
		if err := json.Unmarshal(raw, &fx); err != nil {
			t.Fatalf("解析 %s: %v", f, err)
		}
		if want := strings.TrimSuffix(filepath.Base(f), ".json"); fx.ID != want {
			t.Fatalf("%s: id=%q 与文件名不一致", f, fx.ID)
		}
		out = append(out, &fx)
	}
	return out
}

// ---------- 各源 ↔ 公共形态 ----------

func searchItemsFromNetease(songs []neSearchSong) []searchGoldenItem {
	out := make([]searchGoldenItem, 0, len(songs))
	for _, s := range songs {
		it := searchGoldenItem{ID: strconv.FormatInt(s.ID, 10), Title: s.Name, Album: s.Album.Name, DurationSecs: s.Duration / 1000}
		if s.Album.ID != 0 {
			it.AlbumID = strconv.FormatInt(s.Album.ID, 10)
		}
		for _, a := range s.Artists {
			it.Artists = append(it.Artists, a.Name)
		}
		out = append(out, it)
	}
	return out
}

func neteaseSongsFromItems(items []searchGoldenItem) []neSearchSong {
	out := make([]neSearchSong, 0, len(items))
	for _, it := range items {
		var s neSearchSong
		s.ID, _ = strconv.ParseInt(it.ID, 10, 64)
		s.Name = it.Title
		s.Album.Name = it.Album
		s.Album.ID, _ = strconv.ParseInt(it.AlbumID, 10, 64)
		s.Duration = it.DurationSecs * 1000
		for _, a := range it.Artists {
			s.Artists = append(s.Artists, struct {
				Name string `json:"name"`
			}{Name: a})
		}
		out = append(out, s)
	}
	return out
}

func searchItemsFromQQ(items []qqSearchItem) []searchGoldenItem {
	out := make([]searchGoldenItem, 0, len(items))
	for _, s := range items {
		out = append(out, searchGoldenItem{ID: s.Mid, Title: s.Name, Artist: s.Singer, Album: s.Album, DurationSecs: s.Interval})
	}
	return out
}

func qqItemsFromSearch(items []searchGoldenItem) []qqSearchItem {
	out := make([]qqSearchItem, 0, len(items))
	for _, it := range items {
		out = append(out, qqSearchItem{Mid: it.ID, Name: it.Title, Singer: it.Artist, Album: it.Album, Interval: it.DurationSecs})
	}
	return out
}

func searchItemsFromKugou(songs []kugouSong) []searchGoldenItem {
	out := make([]searchGoldenItem, 0, len(songs))
	for _, s := range songs {
		out = append(out, searchGoldenItem{ID: s.Hash, Title: s.SongName, Artist: s.SingerName, Album: s.AlbumName, AlbumID: s.AlbumID, DurationSecs: s.Duration, Language: s.TransParam.Language})
	}
	return out
}

func kugouSongsFromItems(items []searchGoldenItem) []kugouSong {
	out := make([]kugouSong, 0, len(items))
	for _, it := range items {
		var s kugouSong
		s.Hash, s.SongName, s.SingerName, s.AlbumName, s.AlbumID, s.Duration = it.ID, it.Title, it.Artist, it.Album, it.AlbumID, it.DurationSecs
		s.TransParam.Language = it.Language
		out = append(out, s)
	}
	return out
}

func searchItemsFromLRCLIB(items []lrclibSearchItem) []searchGoldenItem {
	out := make([]searchGoldenItem, 0, len(items))
	for i, s := range items {
		out = append(out, searchGoldenItem{ID: "#" + strconv.Itoa(i), Title: s.TrackName, Artist: s.ArtistName, Album: s.AlbumName, DurationSecs: s.Duration, Instrumental: s.Instrumental, SyncedLyrics: s.SyncedLyrics, PlainLyrics: s.PlainLyrics})
	}
	return out
}

func lrclibItemsFromSearch(items []searchGoldenItem) []lrclibSearchItem {
	out := make([]lrclibSearchItem, 0, len(items))
	for _, it := range items {
		out = append(out, lrclibSearchItem{TrackName: it.Title, ArtistName: it.Artist, AlbumName: it.Album, Duration: it.DurationSecs, Instrumental: it.Instrumental, SyncedLyrics: it.SyncedLyrics, PlainLyrics: it.PlainLyrics})
	}
	return out
}

// ---------- 回放 ----------

// runSearchGolden 用生产的挑选函数算出 expect。
func runSearchGolden(fx *searchGoldenFixture) searchGoldenExpect {
	q := fx.Query
	var e searchGoldenExpect
	switch fx.Source {
	case "netease":
		if p := neteasePickSong(neteaseSongsFromItems(fx.Items), q.Artist, q.Title, q.Album, q.DurationSecs); p != nil {
			e.PickedID = strconv.FormatInt(p.ID, 10)
		}
	case "qq":
		items := qqItemsFromSearch(fx.Items)
		strict := qqCollectCandidates(items, q.Artist, q.Title, true)
		loose := qqCollectCandidates(items, q.Artist, q.Title, false)
		for _, c := range strict {
			e.AcceptedStrict = append(e.AcceptedStrict, c.mid)
		}
		for _, c := range loose {
			e.AcceptedLoose = append(e.AcceptedLoose, c.mid)
		}
		cands := strict
		if len(cands) == 0 {
			cands = loose
		}
		if len(cands) == 0 {
			break
		}
		if c, ok := qqPickCandidate(cands, q.Artist); ok {
			e.PickedNoAlbum = c.mid
		}
		// 跟 resolveQQMusicMatch 同一条路:有本地专辑名先走专辑档(候选没自带专辑名时生产会去查一次,
		// 样本里查不了 → 恒空,等于"这条没有专辑信息"),专辑档没选出够格的再退到不看专辑的挑选。
		// 专辑档"有 best 但 bestScore==0"那一支在生产里会先去专辑维度检索(网络),这里没有,退到 best 本身。
		// 生产在"有 best 但专辑分为 0"时会先走专辑维度检索(网络),失败才退回 best;这里没有那一步,
		// 直接退回 best——差别只在那条网络路径,挑选结果是否站得住由 goldenJudgeSearchPick 另行把关。
		if q.Album != "" {
			best, haveBest, _ := qqPickCandidateWithAlbum(cands, q.Artist, q.Album, func(mid string) string { return fx.AlbumLookup[mid] })
			if haveBest {
				e.PickedID = best.mid
				break
			}
		}
		e.PickedID = e.PickedNoAlbum
	case "kugou":
		if p := pickKugouSearchCandidate(kugouSongsFromItems(fx.Items), q.Artist, q.Title, q.Album, q.DurationSecs); p != nil {
			e.PickedID = p.Hash
		}
	case "lrclib":
		items := lrclibItemsFromSearch(fx.Items)
		best, plainOnly := pickLRCLIBSearchResultDetailed(items, q.Artist, q.Title, q.Album, q.DurationSecs, false)
		if best == nil {
			best, plainOnly = pickLRCLIBSearchResultDetailed(items, q.Artist, q.Title, q.Album, q.DurationSecs, true)
		}
		if best != nil {
			for i := range items {
				if &items[i] == best {
					e.PickedID = fx.Items[i].ID
				}
			}
			e.PlainOnly = plainOnly
		}
	}
	return e
}

func searchGoldenItemByID(fx *searchGoldenFixture, id string) *searchGoldenItem {
	for i := range fx.Items {
		if fx.Items[i].ID == id {
			return &fx.Items[i]
		}
	}
	return nil
}

func searchGoldenItemArtist(it searchGoldenItem) string {
	if len(it.Artists) > 0 {
		return strings.Join(it.Artists, "/")
	}
	return it.Artist
}

// searchGoldenItemPlausible:这条搜索结果像不像"就是本地这首"——歌名过闸 + 歌手对得上(合 credit
// 交集档)+ 自报时长 ≤3%(没自报的按时长这一项放行)。给"选空"的样本核对用。
func searchGoldenItemPlausible(q goldenQuery, localDur float64, it searchGoldenItem) bool {
	if !lyricTitleAccepted(it.Title, q.Title) {
		return false
	}
	artistOK := false
	if len(it.Artists) > 0 {
		for _, a := range it.Artists {
			if artistMatches(a, q.Artist) {
				artistOK = true
			}
		}
	} else {
		artistOK = lyricSourceArtistMatches(it.Artist, q.Artist) || looseContains(it.Artist, q.Artist)
	}
	if !artistOK {
		return false
	}
	if it.DurationSecs > 0 && localDur > 0 && 100*abs(it.DurationSecs-localDur)/localDur > 3 {
		return false
	}
	return true
}

func goldenComputeSearchJudge(fx *searchGoldenFixture, e searchGoldenExpect) searchGoldenJudge {
	j := searchGoldenJudge{SourceDurationDeltaPct: -1}
	q := fx.Query
	localDur := q.DurationSecs
	if localDur <= 0 {
		localDur = fx.LocalDurationSecs
	}
	if e.PickedID == "" {
		for _, it := range fx.Items {
			if searchGoldenItemPlausible(q, localDur, it) {
				j.PlausibleAlternatives++
			}
		}
		return j
	}
	it := searchGoldenItemByID(fx, e.PickedID)
	if it == nil {
		return j
	}
	j.TitleAccepted = lyricTitleAccepted(it.Title, q.Title)
	j.ArtistMatches = false
	if len(it.Artists) > 0 {
		for _, a := range it.Artists {
			if artistMatches(a, q.Artist) {
				j.ArtistMatches = true
			}
		}
	} else {
		// 跟 qq 的 loose 档同一口径:「关浩德Walter」对「关浩德」算对得上——歌名精确 + 自报时长 ≤3%
		// 两道硬闸还在,歌手这一项只要沾边就行。
		j.ArtistMatches = lyricSourceArtistMatches(it.Artist, q.Artist) || looseContains(it.Artist, q.Artist)
	}
	if it.DurationSecs > 0 && localDur > 0 {
		j.SourceDurationDeltaPct = 100 * abs(it.DurationSecs-localDur) / localDur
	}
	j.VersionTagsOK = !versionTagsMismatch(q.Title, q.Album, it.Title, it.Album) &&
		!liveAlbumIdentityConflict(q.Artist, q.Album, it.Title, it.Album)
	localLive := recordingVersionTags(q.Title, q.Album)["live"] || albumHasLiveMarker(q.Album)
	itemLive := recordingVersionTags(it.Title, it.Album)["live"] || albumHasLiveMarker(it.Album)
	j.LiveMismatch = localLive != itemLive
	return j
}

// goldenJudgeSearchPick:选中的那条必须每一项都站得住;选空则必须真的没有像样的候选。
func goldenJudgeSearchPick(e searchGoldenExpect, j searchGoldenJudge) error {
	if e.PickedID == "" {
		if j.PlausibleAlternatives > 0 {
			return fmt.Errorf("选了空,但这批结果里有 %d 条歌名/歌手/时长都对得上的候选——放弃的理由有争议", j.PlausibleAlternatives)
		}
		return nil
	}
	var problems []string
	if !j.TitleAccepted {
		problems = append(problems, "选中的歌名没过 lyricTitleAccepted")
	}
	if !j.ArtistMatches {
		problems = append(problems, "选中的歌手对不上")
	}
	if j.SourceDurationDeltaPct > 3 {
		problems = append(problems, fmt.Sprintf("选中的自报时长偏差 %.1f%% > 3%%", j.SourceDurationDeltaPct))
	}
	if !j.VersionTagsOK {
		problems = append(problems, "版本限定词不一致或另一场演出")
	}
	if j.LiveMismatch {
		problems = append(problems, "一边是现场录音一边不是")
	}
	if len(problems) > 0 {
		return fmt.Errorf("%s", strings.Join(problems, ";"))
	}
	return nil
}

// ---------- 测试 ----------

func TestLyricsSearchGolden(t *testing.T) {
	fixtures := loadSearchGoldenFixtures(t)
	if len(fixtures) == 0 {
		t.Skip("testdata/lyricsgolden/search 还没有样本")
	}
	for _, fx := range fixtures {
		fx := fx
		t.Run(fx.ID, func(t *testing.T) {
			got := runSearchGolden(fx)
			var diffs []string
			if got.PickedID != fx.Expect.PickedID {
				diffs = append(diffs, fmt.Sprintf("选中: 期望 %s, 实际 %s", searchGoldenDescribe(fx, fx.Expect.PickedID), searchGoldenDescribe(fx, got.PickedID)))
			}
			if a, b := strings.Join(fx.Expect.AcceptedStrict, ","), strings.Join(got.AcceptedStrict, ","); a != b {
				diffs = append(diffs, fmt.Sprintf("strict 档放行: 期望 [%s], 实际 [%s]", a, b))
			}
			if a, b := strings.Join(fx.Expect.AcceptedLoose, ","), strings.Join(got.AcceptedLoose, ","); a != b {
				diffs = append(diffs, fmt.Sprintf("loose 档放行: 期望 [%s], 实际 [%s]", a, b))
			}
			if fx.Expect.PickedNoAlbum != got.PickedNoAlbum {
				diffs = append(diffs, fmt.Sprintf("不看专辑的挑选: 期望 %s, 实际 %s", fx.Expect.PickedNoAlbum, got.PickedNoAlbum))
			}
			if fx.Expect.PlainOnly != got.PlainOnly {
				diffs = append(diffs, fmt.Sprintf("纯文本兜底: 期望 %v, 实际 %v", fx.Expect.PlainOnly, got.PlainOnly))
			}
			if len(diffs) == 0 {
				return
			}
			if goldenUpdateEnabled() {
				if !goldenSemanticAccepted(fx.ID) {
					t.Errorf("检索层挑选变了,不允许静默改写:\n  %s\n确认之后加 LYRICS_GOLDEN_ACCEPT_SEMANTIC=%s 再跑", strings.Join(diffs, "\n  "), fx.ID)
					return
				}
				fx.Expect = got
				fx.Judge = goldenComputeSearchJudge(fx, got)
				if err := writeSearchGoldenFixture(fx); err != nil {
					t.Fatal(err)
				}
				t.Logf("已更新 %s.json", fx.ID)
				return
			}
			t.Errorf("%s(%s)与金标不一致 —— %s《%s》\n  %s", fx.ID, fx.Source, fx.Track.Artist, fx.Track.Title, strings.Join(diffs, "\n  "))
		})
	}
}

func searchGoldenDescribe(fx *searchGoldenFixture, id string) string {
	if id == "" {
		return "<空>"
	}
	if it := searchGoldenItemByID(fx, id); it != nil {
		return fmt.Sprintf("%s(%q / %q / %.0fs)", id, it.Title, it.Album, it.DurationSecs)
	}
	return id
}

// TestLyricsSearchGoldenPicksAreJustified:每个样本的挑选结果都要用样本自己的数据过一遍独立判据。
func TestLyricsSearchGoldenPicksAreJustified(t *testing.T) {
	for _, fx := range loadSearchGoldenFixtures(t) {
		j := goldenComputeSearchJudge(fx, fx.Expect)
		if err := goldenJudgeSearchPick(fx.Expect, j); err != nil {
			t.Errorf("%s: 挑选结果的独立判据不成立: %v\n  %+v", fx.ID, err, j)
		}
		if j != fx.Judge {
			t.Errorf("%s: 样本里记的判据跟重算的不一致(有人手改过样本?):\n  记录 %+v\n  重算 %+v", fx.ID, fx.Judge, j)
		}
	}
}

// TestLyricsSearchGoldenSourceCoverage:四个源各至少 3 个样本,全部样本里至少 2 个"选空"的负样本——
// 身份闸的价值一半在"拒绝"。
func TestLyricsSearchGoldenSourceCoverage(t *testing.T) {
	fixtures := loadSearchGoldenFixtures(t)
	if len(fixtures) == 0 {
		t.Skip("testdata/lyricsgolden/search 还没有样本")
	}
	count, negatives := map[string]int{}, map[string]int{}
	for _, fx := range fixtures {
		count[fx.Source]++
		if fx.Expect.PickedID == "" {
			negatives[fx.Source]++
		}
	}
	total := 0
	for _, src := range lyricsSearchGoldenSources {
		if count[src] < 3 {
			t.Errorf("%s 只有 %d 个检索层样本(要 ≥3)", src, count[src])
		}
		total += negatives[src]
	}
	if total < 2 {
		t.Errorf("'选空'的负样本只有 %d 个(要 ≥2)——身份闸的价值一半在拒绝", total)
	}
}

func writeSearchGoldenFixture(fx *searchGoldenFixture) error {
	raw, err := json.MarshalIndent(fx, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(lyricsSearchGoldenDir, fx.ID+".json"), append(raw, '\n'), 0o644)
}

// ---------- 采集 ----------

// TestLyricsSearchGoldenCapture 联网跑一次完整检索,把四个源各自**第一次拿到非空搜索结果**的那一批
// (网易云/酷狗会按标题变体查多次,取第一次选出结果的那批,都选不出就取第一批非空的)写成样本:
//
//	LYRICS_SEARCH_GOLDEN_CAPTURE=1 LYRICS_GOLDEN_KEY='歌手|歌名|专辑' LYRICS_GOLDEN_ID=<前缀> \
//	[LYRICS_GOLDEN_NOTE='…'] GOTOOLCHAIN=go1.24.4 go test -run 'TestLyricsSearchGoldenCapture$' -v .
//
// 文件名 <前缀>-<源>.json。每个源写入前都要过 goldenJudgeSearchPick;lrclib 的正文置乱后要过
// "置乱前后挑选结果相同"的闸。缓存只读(同第一层采集器)。
func TestLyricsSearchGoldenCapture(t *testing.T) {
	if os.Getenv("LYRICS_SEARCH_GOLDEN_CAPTURE") == "" {
		t.Skip("LYRICS_SEARCH_GOLDEN_CAPTURE 未设置,跳过联网采集")
	}
	key, prefix, note := os.Getenv("LYRICS_GOLDEN_KEY"), os.Getenv("LYRICS_GOLDEN_ID"), os.Getenv("LYRICS_GOLDEN_NOTE")
	parts := strings.SplitN(key, "|", 3)
	if len(parts) != 3 || prefix == "" {
		t.Fatal("LYRICS_GOLDEN_KEY(歌手|歌名|专辑)与 LYRICS_GOLDEN_ID 都必须给")
	}
	home, _ := os.UserHomeDir()
	cfgDir := filepath.Join(home, ".config", clientName)
	rawCache, err := os.ReadFile(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cache map[string]goldenCacheEntry
	if err := json.Unmarshal(rawCache, &cache); err != nil {
		t.Fatal(err)
	}
	entry, ok := cache[key]
	if !ok {
		t.Fatalf("缓存里没有 key=%q", key)
	}
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))
	loadArtistAliasCache(filepath.Join(cfgDir, clientName+"-artist-alias-cache.json"))
	loadMBPrimaryNameCache(filepath.Join(cfgDir, clientName+"-artist-primary-cache.json"))
	loadAppleCatalogCache(filepath.Join(cfgDir, clientName+"-apple-catalog-cache.json"))
	loadAppleStorefrontArtistCache(filepath.Join(cfgDir, clientName+"-apple-storefront-artist-cache.json"))
	loadQQArtistNameCache(filepath.Join(cfgDir, clientName+"-qq-artist-name-cache.json"))
	artistAliasPath, mbPrimaryNamePath, qqArtistNamePath, appleStorefrontArtistPath, appleCatalogPath = "", "", "", "", ""

	qArtist, qTitle, qAlbum := toSimplified(parts[0]), toSimplified(parts[1]), toSimplified(parts[2])
	dur := entry.ResolvedDurationSecs
	if dur <= 0 {
		dur = entry.DurationSecs
	}
	if d := entry.Decision; d != nil {
		if d.QueryTitle != "" {
			qArtist, qTitle, qAlbum = toSimplified(d.QueryArtist), toSimplified(d.QueryTitle), toSimplified(d.QueryAlbum)
		}
		if d.DurationSecs > 0 {
			dur = d.DurationSecs
		}
	}
	if dur <= 0 {
		t.Fatal("这条缓存没有时长,检索层的时长判据失效,不适合当金标")
	}

	type call struct {
		q     goldenQuery
		items []searchGoldenItem
	}
	calls := map[string][]call{}
	lyricSearchItemsTap = func(source, artist, title, album string, durationSecs float64, items any) {
		var conv []searchGoldenItem
		switch v := items.(type) {
		case []neSearchSong:
			conv = searchItemsFromNetease(v)
		case []qqSearchItem:
			conv = searchItemsFromQQ(v)
		case []kugouSong:
			conv = searchItemsFromKugou(v)
		case []lrclibSearchItem:
			conv = searchItemsFromLRCLIB(v)
		default:
			t.Errorf("tap 收到未知类型 %T(source=%s)", items, source)
			return
		}
		if len(conv) == 0 {
			return
		}
		calls[source] = append(calls[source], call{q: goldenQuery{Artist: artist, Title: title, Album: album, DurationSecs: durationSecs}, items: conv})
	}
	t.Cleanup(func() { lyricSearchItemsTap = nil })
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	scoredLyricCandidatesStreaming(ctx, qArtist, qTitle, qAlbum, dur, func(neteaseInfo, []scoredLyricCandidateResult, int, int) {})

	if err := os.MkdirAll(lyricsSearchGoldenDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, src := range lyricsSearchGoldenSources {
		cs := calls[src]
		if len(cs) == 0 {
			t.Logf("%s: 没有非空搜索结果,跳过", src)
			continue
		}
		// 网易云/酷狗按标题变体查多次:优先取"选出了结果"的那些批次里**条目最多**的一批(干扰项越多
		// 样本越有价值),都选不出就取条目最多的一批。
		chosen, chosenPicked := cs[0], false
		for _, c := range cs {
			picked := runSearchGolden(&searchGoldenFixture{Source: src, Query: c.q, Items: c.items, LocalDurationSecs: dur}).PickedID != ""
			switch {
			case picked && !chosenPicked, picked == chosenPicked && len(c.items) > len(chosen.items):
				chosen, chosenPicked = c, picked
			}
		}
		fx := &searchGoldenFixture{
			ID: prefix + "-" + src, Source: src, Note: note,
			Track:      goldenTrack{Artist: parts[0], Title: parts[1], Album: parts[2]},
			CapturedAt: time.Now().Format("2006-01-02"),
			Query:      chosen.q, Items: chosen.items, LocalDurationSecs: dur,
		}
		if src == "qq" && chosen.q.Album != "" {
			// 按生产同一份预算逻辑真的查一遍专辑名并记下来(qqSongAlbum 自带缓存,这一轮检索里多半已经热了)。
			items := qqItemsFromSearch(fx.Items)
			cands := qqCollectCandidates(items, chosen.q.Artist, chosen.q.Title, true)
			if len(cands) == 0 {
				cands = qqCollectCandidates(items, chosen.q.Artist, chosen.q.Title, false)
			}
			rec := map[string]string{}
			qqPickCandidateWithAlbum(cands, chosen.q.Artist, chosen.q.Album, func(mid string) string {
				a := qqSongAlbum(ctx, mid)
				rec[mid] = a
				return a
			})
			if len(rec) > 0 {
				fx.AlbumLookup = rec
			}
		}
		if src == "lrclib" {
			// 正文置乱 + 保形校验(同第一层)。
			before := runSearchGolden(fx)
			var texts []goldenText
			for _, it := range fx.Items {
				texts = append(texts, goldenText{it.SyncedLyrics, false}, goldenText{it.PlainLyrics, false})
			}
			scr := newGoldenScrambler(fx.ID, texts)
			for i := range fx.Items {
				fx.Items[i].SyncedLyrics = scr.scrambleText(fx.Items[i].SyncedLyrics, false)
				fx.Items[i].PlainLyrics = scr.scrambleText(fx.Items[i].PlainLyrics, false)
			}
			after := runSearchGolden(fx)
			if fmt.Sprintf("%+v", before) != fmt.Sprintf("%+v", after) {
				t.Errorf("%s: 置乱改变了挑选结果(%+v → %+v),不写入", fx.ID, before, after)
				continue
			}
		}
		fx.Expect = runSearchGolden(fx)
		fx.Judge = goldenComputeSearchJudge(fx, fx.Expect)
		t.Logf("%s: %d 条结果,选中 %s", fx.ID, len(fx.Items), searchGoldenDescribe(fx, fx.Expect.PickedID))
		for _, it := range fx.Items {
			mark := "  "
			if it.ID == fx.Expect.PickedID {
				mark = "→ "
			}
			t.Logf("  %s%-14s %-30q %-24q %-30q %.0fs", mark, it.ID, it.Title, searchGoldenItemArtist(it), it.Album, it.DurationSecs)
		}
		if err := goldenJudgeSearchPick(fx.Expect, fx.Judge); err != nil {
			t.Errorf("%s: 挑选结果证明不了,不写入: %v", fx.ID, err)
			continue
		}
		if err := writeSearchGoldenFixture(fx); err != nil {
			t.Fatal(err)
		}
		t.Logf("  已写入 %s/%s.json  判据 %+v", lyricsSearchGoldenDir, fx.ID, fx.Judge)
	}
}
