// lyricsgolden_test.go — 歌词搜索的**回归金标集**(golden corpus)。
//
// 这里守的不是"某条规则对某个输入怎么判",而是"**这首真实的歌,拿到这组真实的候选,最后选对了**"——
// 从各源原始应答一路到冠军的整条离线链路(候选构建 → 时间轴自洽修复 → 跨源末尾印证 →
// 跨源正文共识 → 逐条打分 → 纯音乐标记 → 逐字加分撤销 → 稳定排序 → 挑选),跑的是生产同一份
// 代码 rankLyricSourceResults / pickLyricCandidate,不在测试里另抄一份骨架。
//
// 为什么需要它(2026-09-04):116 个测试文件里全是按函数钉的规则,历次"全库回放"都是一次性脚本、
// 跑完就丢,simeval 又依赖本机数据默认跳过——改一档权重之后"哪几类歌会换冠军"在仓库里没有任何
// 常驻证据。金标集把每一类已确认正确的真实决策固化成样本,以后任何打分/守卫改动都必须先过它。
//
// 样本在 testdata/lyricsgolden/*.json,一首歌一个文件。结构见 goldenFixture;每个样本记着:
//   - query:发给各源的查询词(已 toSimplified,跟生产传给 rankLyricSourceResults 的完全一样)与时长;
//   - settings:当时的译文语言 / 来源开关 / 挑选模式 / 播放器 / 歌手中文别名提示——打分会偷读的
//     全部包级状态,测试跑前照样设上、跑完还原;
//   - sources:各源的**原始应答**(lyricSourceResult 逐字段);
//   - expect:冠军、每条候选的判决(accepted / 哪条 reject)、纯音乐标记、以及完整分项快照。
//
// ⚠️ 正文不入库明文:01 章版权立场写的是"不托管、不转发、不再分发",真实歌词进 git 就违背这一条。
// 样本里的歌词/逐字/译文/罗马音都经过 scrambleLyricRound 的**保形置乱**(同一首内一致的字符双射,
// 汉字→汉字、拉丁→拉丁保大小写、假名/谚文各自块内;时间戳、标点、数字、署名行、演唱者标签、
// 元数据标签、纯音乐占位原样不动)。打分读到的每一个特征——时间戳密度、末句时刻、行数、汉字/假名
// 占比、3-gram 共识、署名结构——置乱前后逐位相同,采集器(lyricsgolden_capture_test.go)会把
// "置乱前后 rank 结果逐项一致"当作写入前的硬闸,不一致就拒绝入库。所以样本文本看起来是乱码是**预期**,
// 别试图"修好"它。
//
// 两层断言:
//   - 语义硬断言:冠军、每条候选的判决、纯音乐标记。这三样变了就是"这首歌选错了 / 该拒的没拒",
//     即使设了 LYRICS_GOLDEN_UPDATE 也不会静默改写——必须再显式给 LYRICS_GOLDEN_ACCEPT_SEMANTIC
//     (样本 id 逗号分隔,或 all),让"我知道这首歌的冠军换了"成为一个刻意的动作,留在命令行里、
//     也留在 git diff 里;
//   - 分项快照:每条候选的分数与全部 scoreTerm(kind+points)、逐字/译文/罗马音有无。改权重时
//     大面积变化是正常的,LYRICS_GOLDEN_UPDATE=1 重生成 expect,靠 git diff 审"哪些歌的哪一项动了"。
//
// 另有一道类别覆盖契约(TestLyricsGoldenCategoryCoverage):goldenRequiredCategories 里每一类至少
// 一个样本;删样本或漏类别直接红。新增一类判据/新踩一个坑,就在那张表加一行、采一个样本。
//
// 采样方法见 testdata/lyricsgolden/README.md。
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

const lyricsGoldenDir = "testdata/lyricsgolden"

// ---------- 样本结构 ----------

type goldenFixture struct {
	// ID 是文件名(不含 .json),也是 LYRICS_GOLDEN_ACCEPT_SEMANTIC 里引用它的名字。
	ID string `json:"id"`
	// Category 必须是 goldenRequiredCategories 里的一个键。
	Category string `json:"category"`
	// Note:为什么挑这首、这一类在守什么(人写)。
	Note string `json:"note"`
	// LabelEvidence:这首歌的冠军**为什么算对**——一组不依赖缓存的独立判据(见 goldenLabelEvidence),
	// 采集时算、写样本前逐条过闸(goldenJudgeEvidence),TestLyricsGoldenWinnersAreIndependentlyJustified
	// 每次都拿样本数据重算一遍。"缓存里就是这份"只是其中一项旁证,不是依据。
	LabelEvidence goldenLabelEvidence `json:"label_evidence"`
	// Track:未置乱的本地标签原文,只给人看。打分入参是下面的 Query。
	Track      goldenTrack `json:"track"`
	CapturedAt string      `json:"captured_at"`
	CapturedBy string      `json:"captured_by,omitempty"`
	// ScoringVersionAtCapture:采集时的 lyricsScoringVersion。只是信息,不参与断言——
	// 快照跟着 UPDATE 走,版本号跟着 match.go 走。
	ScoringVersionAtCapture int                        `json:"scoring_version_at_capture"`
	Query                   goldenQuery                `json:"query"`
	Settings                goldenSettings             `json:"settings"`
	Sources                 map[string]goldenSourceRaw `json:"sources"`
	Expect                  goldenExpect               `json:"expect"`
}

type goldenTrack struct {
	Artist string `json:"artist"`
	Title  string `json:"title"`
	Album  string `json:"album"`
}

type goldenQuery struct {
	Artist       string  `json:"artist"`
	Title        string  `json:"title"`
	Album        string  `json:"album"`
	DurationSecs float64 `json:"duration_secs"`
}

type goldenSettings struct {
	TranslationLanguage string `json:"translation_language"`
	// Sources:nil/空 = 全部启用(跟 lyricSourceEnabled 的口径一致)。
	Sources     map[string]bool `json:"sources,omitempty"`
	SourceMode  string          `json:"source_mode,omitempty"`
	SourceOrder []string        `json:"source_order,omitempty"`
	// PlayerBundleID:这一刻在放的播放器(同源 +250 的判据),空 = 不加分。
	PlayerBundleID string `json:"player_bundle_id,omitempty"`
	// ArtistCJKHint:采集时 resolvedArtistCJKHint(query.artist) 的值——isProbablyWrongLanguageLyrics
	// 在打分热路径上偷读的那份歌手别名缓存。空 = 当时也是空。
	ArtistCJKHint string `json:"artist_cjk_hint,omitempty"`
}

// goldenSourceRaw 是 lyricSourceResult 的 JSON 形态,字段一一对应(netease/amll 各自的子结构
// 也原样带上)。文本字段全部已置乱。
type goldenSourceRaw struct {
	Lyrics       string  `json:"lyrics,omitempty"`
	YRC          string  `json:"yrc,omitempty"`
	Tr           string  `json:"tr,omitempty"`
	Roma         string  `json:"roma,omitempty"`
	Title        string  `json:"title,omitempty"`
	Artist       string  `json:"artist,omitempty"`
	Album        string  `json:"album,omitempty"`
	Cover        string  `json:"cover,omitempty"`
	DurationSecs float64 `json:"duration_secs,omitempty"`
	Language     string  `json:"language,omitempty"`
	Instrumental bool    `json:"instrumental,omitempty"`
	PlainOnly    bool    `json:"plain_only,omitempty"`
	// Netease:只有 source=netease 有。lyricSourceResult 对网易云走的是 ne neteaseInfo 这个
	// 独立子结构,不复用上面的 lyr/yrc/tr。
	Netease *goldenNetease `json:"netease,omitempty"`
	// AMLL:只有 source=amll 有。
	AMLL *goldenAMLL `json:"amll,omitempty"`
}

type goldenNetease struct {
	Cover        string  `json:"cover,omitempty"`
	SongURL      string  `json:"song_url,omitempty"`
	Lyrics       string  `json:"lyrics,omitempty"`
	Trans        string  `json:"trans,omitempty"`
	Roma         string  `json:"roma,omitempty"`
	YRC          string  `json:"yrc,omitempty"`
	DurationSecs float64 `json:"duration_secs,omitempty"`
	Artist       string  `json:"artist,omitempty"`
	Title        string  `json:"title,omitempty"`
	Album        string  `json:"album,omitempty"`
	SongID       int64   `json:"song_id,omitempty"`
	AlbumID      int64   `json:"album_id,omitempty"`
	PureMusic    bool    `json:"pure_music,omitempty"`
}

type goldenAMLL struct {
	LRC     string `json:"lrc,omitempty"`
	YRC     string `json:"yrc,omitempty"`
	Tr      string `json:"tr,omitempty"`
	HasDuet bool   `json:"has_duet,omitempty"`
}

type goldenExpect struct {
	// ---- 语义硬断言 ----
	Winner string `json:"winner"`
	// InstrumentalMarker:搭车的纯音乐标记来自哪个源,空 = 没有。
	InstrumentalMarker string `json:"instrumental_marker,omitempty"`
	// Verdicts:源 → "accepted" 或 reject 的 kind(scoreRejectNotTimed 等)。
	Verdicts map[string]string `json:"verdicts"`
	// ---- 分项快照 ----
	// Ranked:排序后的候选列表(纯音乐标记那条不在里面)。
	Ranked []goldenRankedCandidate `json:"ranked"`
	// WinnerFingerprint:冠军 Lyrics(置乱后、经 rankLyricSourceResults 输出)的 sha256 前 16 位。
	// 时间轴自洽修复改了冠军正文的时间戳会在这里体现。
	WinnerFingerprint string `json:"winner_fingerprint,omitempty"`
}

type goldenRankedCandidate struct {
	Source          string      `json:"source"`
	Score           int         `json:"score"`
	Terms           []scoreTerm `json:"terms,omitempty"`
	HasWordTiming   bool        `json:"has_word_timing,omitempty"`
	HasTranslation  bool        `json:"has_translation,omitempty"`
	TranslationLang string      `json:"translation_lang,omitempty"`
	HasRomanization bool        `json:"has_romanization,omitempty"`
}

// goldenLabelEvidence 是"这个冠军确实是这首歌、而且是这个版本"的独立判据。每一项都能从样本自己
// 的数据重算出来(标题/专辑/时长是原样元数据,正文置乱不改时间戳与 3-gram 关系),不依赖采集时
// 的缓存内容。
//
// 为什么不能只信缓存(用户 2026-09-04 的要求「不能纯信目前的缓存」):缓存里那份是**上一版规则**
// 选出来的,采集时就撞到两条错的——《低潮期》缓存是 30 秒 5 行的残片(那轮拿 0 时长打分),
// 《公园 (Live版)》缓存是另一场演唱会的版本(用户当初报过的错配)。拿它当金标等于把旧错误钉成
// 新标准。
type goldenLabelEvidence struct {
	// ConsensusPeers:有多少个**别的**源的正文与冠军 3-gram 相似度 ≥ lyricConsensusSimThreshold。
	// ≥1 就说明"至少两个互不相干的平台给出了同一份内容"——冠军不是串了别的歌。
	ConsensusPeers int `json:"consensus_peers"`
	// TitleAccepted:冠军自报的歌名过 lyricTitleAccepted(归一相等/剥括号/双语,不认子串)。
	TitleAccepted bool `json:"title_accepted"`
	// VersionTagsOK:冠军与本地的版本限定词集合一致(live/remix/acoustic…,含专辑级 live 声明),
	// 且不是另一场演出(liveAlbumIdentityConflict 为假)。这是"是这个版本"的判据。
	VersionTagsOK bool `json:"version_tags_ok"`
	// SourceDurationDeltaPct:冠军自报曲长与本地曲长的偏差百分比;-1 = 该源没自报(amll)。
	// 同一次录音跨平台只差在取整,≤ 3% 视为同一录音。
	SourceDurationDeltaPct float64 `json:"source_duration_delta_pct"`
	// LyricsEndSecs / CoveragePct:歌词末句时刻,以及它占本地曲长的比例。末句不能晚于曲长 5s
	// (物理矛盾),也得覆盖过半(不是残片)。
	LyricsEndSecs float64 `json:"lyrics_end_secs"`
	CoveragePct   float64 `json:"coverage_pct"`
	// AlbumScore:冠军自报专辑与本地专辑的亲和(albumScore)。本地是现场专辑时要求 >0(同一场)。
	AlbumScore int `json:"album_score"`
	// LiveMismatch:一边是现场录音、另一边不是——按 albumHasLiveMarker(拉丁 live/concert 词元
	// **也算**,比打分层的 recordingVersionTags 宽)看两边专辑,再看两边歌名的 live 声明。打分层刻意
	// 不认拉丁词元(把握不够),但金标要的是"没有争议",宁可多拒。《爱是怀疑》采集时抓到的形态:
	// 本地是国语精选,酷狗冠军挂在《Eason Third Encounter Concert Live 2003》——词是对的、时间轴是
	// 另一场演出的,不能当金标。
	LiveMismatch bool `json:"live_mismatch"`
	// CacheAgreement:采集那一刻缓存里生效的那份跟冠军的关系——exact / similar=0.93 / differs=0.12 /
	// no-cache / manual。**只作旁证**;differs 且不是手选时采集会拒绝,因为那意味着有争议。
	CacheAgreement string `json:"cache_agreement"`
	// Instrumental:纯音乐类样本——没有歌词冠军,标记来自哪个源的**明文断言**(lrclib 结构化字段 /
	// 网易云 pureMusic / QQ 占位正文),与缓存无关。
	Instrumental string `json:"instrumental,omitempty"`
}

// goldenComputeEvidence 从一轮排好序的候选与本地查询算出独立判据。cacheAgreement 由调用方填
// (测试里重算时没有缓存,留原值)。
func goldenComputeEvidence(q goldenQuery, ranked []scoredLyricCandidateResult) goldenLabelEvidence {
	ev := goldenLabelEvidence{SourceDurationDeltaPct: -1}
	var winner *scoredLyricCandidateResult
	for i := range ranked {
		if ranked[i].Instrumental {
			ev.Instrumental = ranked[i].Source
		}
	}
	winner = pickLyricCandidate(ranked)
	if winner == nil {
		return ev
	}
	wgrams := lyricGram3Set(lyricConsensusBody(winner.Lyrics))
	for i := range ranked {
		c := &ranked[i]
		if c.Source == winner.Source || c.Lyrics == "" || c.Instrumental {
			continue
		}
		body := lyricConsensusBody(c.Lyrics)
		if len([]rune(body)) < 30 {
			continue
		}
		if gramJaccard(wgrams, lyricGram3Set(body)) >= lyricConsensusSimThreshold {
			ev.ConsensusPeers++
		}
	}
	ev.TitleAccepted = lyricTitleAccepted(winner.Title, q.Title)
	ev.VersionTagsOK = !versionTagsMismatch(q.Title, q.Album, winner.Title, winner.Album) &&
		!liveAlbumIdentityConflict(q.Artist, q.Album, winner.Title, winner.Album)
	if winner.SourceReportedDurationSecs > 0 && q.DurationSecs > 0 {
		ev.SourceDurationDeltaPct = 100 * abs(winner.SourceReportedDurationSecs-q.DurationSecs) / q.DurationSecs
	}
	if end, ok := lastLRCTimestampSecs(winner.Lyrics); ok {
		ev.LyricsEndSecs = end
		if q.DurationSecs > 0 {
			ev.CoveragePct = 100 * end / q.DurationSecs
		}
	}
	ev.AlbumScore = albumScore(winner.Album, q.Album)
	localLive := recordingVersionTags(q.Title, q.Album)["live"] || albumHasLiveMarker(q.Album)
	winnerLive := recordingVersionTags(winner.Title, winner.Album)["live"] || albumHasLiveMarker(winner.Album)
	ev.LiveMismatch = localLive != winnerLive
	return ev
}

func abs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}

// goldenJudgeEvidence 是"够不够格当金标"的闸。全部要过:
//   - 有冠军:歌名过闸、版本一致;自报曲长偏差 ≤3%(没自报的放行);末句 ≤ 曲长+5s 且覆盖 ≥50%;
//     并且**要么**有别的源印证正文(ConsensusPeers ≥1),**要么**(单候选)自报曲长偏差 ≤1% 且覆盖 ≥70%;
//     本地是现场专辑时专辑亲和 >0;
//   - 没冠军:必须是纯音乐类(标记来自源的明文断言),不接受"搜不到"当样本;
//   - 缓存那份跟冠军不是同一份(differs)且不是用户手选 → 有争议,拒绝。
func goldenJudgeEvidence(q goldenQuery, winner string, ev goldenLabelEvidence) error {
	if winner == "" {
		if ev.Instrumental == "" {
			return fmt.Errorf("没有冠军也没有纯音乐标记——'搜不到'不能当金标")
		}
		return nil
	}
	var problems []string
	if !ev.TitleAccepted {
		problems = append(problems, "冠军歌名没过 lyricTitleAccepted")
	}
	if !ev.VersionTagsOK {
		problems = append(problems, "冠军与本地的版本限定词不一致或是另一场演出")
	}
	if ev.SourceDurationDeltaPct > 3 {
		problems = append(problems, fmt.Sprintf("冠军自报曲长偏差 %.1f%% > 3%%", ev.SourceDurationDeltaPct))
	}
	if q.DurationSecs > 0 {
		if ev.LyricsEndSecs > q.DurationSecs+lyricOvershootToleranceSecs {
			problems = append(problems, fmt.Sprintf("末句 %.1fs 晚于曲长 %.1fs", ev.LyricsEndSecs, q.DurationSecs))
		}
		if ev.CoveragePct < 50 {
			problems = append(problems, fmt.Sprintf("歌词只覆盖曲长的 %.0f%%", ev.CoveragePct))
		}
	}
	if ev.ConsensusPeers < 1 {
		if !(ev.SourceDurationDeltaPct >= 0 && ev.SourceDurationDeltaPct <= 1 && ev.CoveragePct >= 70) {
			problems = append(problems, "没有别的源印证正文,自报曲长/覆盖率也不足以单独证明")
		}
	}
	if recordingVersionTags(q.Title, q.Album)["live"] && ev.AlbumScore <= 0 {
		problems = append(problems, "本地是现场专辑,冠军专辑却对不上(可能是另一场)")
	}
	if ev.LiveMismatch {
		problems = append(problems, "一边是现场录音一边不是(专辑名带 live/concert/演唱会),时间轴是另一次演出的")
	}
	if strings.HasPrefix(ev.CacheAgreement, "differs") {
		problems = append(problems, "缓存里生效的那份跟冠军不是同一份内容("+ev.CacheAgreement+"),有争议")
	}
	if len(problems) > 0 {
		return fmt.Errorf("%s", strings.Join(problems, ";"))
	}
	return nil
}

// ---------- 类别覆盖契约 ----------

// goldenRequiredCategories:每一类至少一个样本。键是 fixture.category 的取值,值是一句"这一类在
// 守什么"。新增一条打分判据 / 新修一个真实错配,就在这里加一行并采一个样本——没有样本的判据
// 等于没有回归保护。
var goldenRequiredCategories = map[string]string{
	"zh-studio-multisource": "华语录音室版,多源应答,逐字时间轴——最普通的一类,守基线",
	"latin-title":           "英文歌(歌手/歌名均无汉字),语言闸不许误杀,Musixmatch/LRCLIB 参与",
	"ja-romanization":       "日文歌,罗马音可用(+30),假名标注行不破坏共识",
	"ko-hangul-lyrics":      "韩文歌(谚文正文、拉丁标签),语言闸不误杀、中文译文可用、没有罗马音加分",
	"cantonese":             "粤语歌",
	"live-same-concert":     "现场版,候选与本地是同一场演出(live 标记双向对称,不吃 versionTags)",
	"live-other-concert":    "现场版,另一场演出的候选吃 liveAlbumConflict",
	"version-tag-mismatch":  "版本限定词错配的候选吃 versionTags -600",
	"multi-artist-credit":   "多歌手合 credit 的署名",
	"reject-credit-only":    "整份只有署名行的候选被否决",
	"reject-plain-text":     "无时间戳纯文本候选被否决",
	"reject-wrong-language": "语言跟这首歌对不上的候选被否决",
	// ⚠️ 没有 "word-timing-override"(applyWordTimingTitleOverride)这一类:2026-09-04 采集时把库里
	// 全部 20 条真实触发案例过了一遍,没有一条站得住——原始案例(方大同《公园/南音 (Live版)》,酷狗是
	// 另一场演唱会)如今被 v7 的 liveAlbumConflict 先行接住、逐字加分不再是决胜项,这条规则根本不触发;
	// 仍会触发的 11 条(林家谦 White Summer Live 系列、《Catch a Dream (Live版)》《爱不来 (Live版)》
	// 《大风吹 (和声伴奏)》)里被撤销的酷狗候选跟冠军**是同一张专辑、同一自报时长的同一次录音**,只是
	// 括号写法不同(「(with 宣萱)(White Summer Live)」vs「(White Summer Live) [with 宣萱]」),撤销之后
	// 用户丢的是逐字、换来的不是版本正确——这更像规则误伤而不是"已确认正确"。有争议的不进金标
	// (用户 2026-09-04 定),这条规则由 match_test.go 的 TestApplyWordTimingTitleOverride_* 钉住。
	"duration-overshoot":        "末句超曲长 5s 的候选吃 -700",
	"duration-corroborated":     "时长不吻合但跨源末尾印证救回",
	"line-only-winner":          "没有逐字的冠军赢过带逐字的候选",
	"amll-embedded-translation": "amll 按 ID 直取命中,内嵌译文可用",
	"native-player-source":      "与当前播放器同源 +250",
	"single-candidate":          "只有一个源应答",
	"instrumental-marker":       "纯音乐标记搭车透传,没有歌词冠军",
}

// ---------- 加载 / 转换 ----------

func loadGoldenFixtures(t *testing.T) []*goldenFixture {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(lyricsGoldenDir, "*.json"))
	if err != nil {
		t.Fatalf("列举金标样本失败: %v", err)
	}
	sort.Strings(files)
	var out []*goldenFixture
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("读 %s: %v", f, err)
		}
		var fx goldenFixture
		if err := json.Unmarshal(raw, &fx); err != nil {
			t.Fatalf("解析 %s: %v", f, err)
		}
		want := strings.TrimSuffix(filepath.Base(f), ".json")
		if fx.ID != want {
			t.Fatalf("%s: id=%q 与文件名不一致", f, fx.ID)
		}
		out = append(out, &fx)
	}
	return out
}

func goldenRawFromSource(g goldenSourceRaw) lyricSourceResult {
	r := lyricSourceResult{
		lyr: g.Lyrics, yrc: g.YRC, tr: g.Tr, roma: g.Roma,
		matchTitle: g.Title, matchArtist: g.Artist, matchAlbum: g.Album, matchCover: g.Cover,
		srcDur: g.DurationSecs, language: g.Language, instrumental: g.Instrumental, plainOnly: g.PlainOnly,
	}
	if g.Netease != nil {
		n := g.Netease
		r.ne = neteaseInfo{
			Cover: n.Cover, SongURL: n.SongURL, Lyrics: n.Lyrics, Trans: n.Trans, Roma: n.Roma, YRC: n.YRC,
			DurationSecs: n.DurationSecs, Artist: n.Artist, Title: n.Title, Album: n.Album,
			SongID: n.SongID, AlbumID: n.AlbumID, PureMusic: n.PureMusic,
		}
	}
	if g.AMLL != nil {
		r.amll = amllResult{lrc: g.AMLL.LRC, yrc: g.AMLL.YRC, tr: g.AMLL.Tr, hasDuet: g.AMLL.HasDuet}
	}
	return r
}

func goldenSourceFromRaw(source string, r lyricSourceResult) goldenSourceRaw {
	g := goldenSourceRaw{
		Lyrics: r.lyr, YRC: r.yrc, Tr: r.tr, Roma: r.roma,
		Title: r.matchTitle, Artist: r.matchArtist, Album: r.matchAlbum, Cover: r.matchCover,
		DurationSecs: r.srcDur, Language: r.language, Instrumental: r.instrumental, PlainOnly: r.plainOnly,
	}
	if source == "netease" {
		n := r.ne
		g.Netease = &goldenNetease{
			Cover: n.Cover, SongURL: n.SongURL, Lyrics: n.Lyrics, Trans: n.Trans, Roma: n.Roma, YRC: n.YRC,
			DurationSecs: n.DurationSecs, Artist: n.Artist, Title: n.Title, Album: n.Album,
			SongID: n.SongID, AlbumID: n.AlbumID, PureMusic: n.PureMusic,
		}
	}
	if source == "amll" {
		g.AMLL = &goldenAMLL{LRC: r.amll.lrc, YRC: r.amll.yrc, Tr: r.amll.tr, HasDuet: r.amll.hasDuet}
	}
	return g
}

func goldenRawRound(fx *goldenFixture) map[string]lyricSourceResult {
	raw := map[string]lyricSourceResult{}
	for src, g := range fx.Sources {
		r := goldenRawFromSource(g)
		r.source = src
		raw[src] = r
	}
	return raw
}

// applyGoldenSettings 把样本里记录的包级状态设上,并登记还原。
func applyGoldenSettings(t *testing.T, fx *goldenFixture) {
	t.Helper()
	savedFeatures := features
	nativeLyricSourcesMu.Lock()
	savedNative := nativeLyricSources
	nativeLyricSourcesMu.Unlock()
	artistAliasMu.Lock()
	savedAlias, hadAlias := artistAliasCache[fx.Query.Artist]
	artistAliasMu.Unlock()
	t.Cleanup(func() {
		features = savedFeatures
		nativeLyricSourcesMu.Lock()
		nativeLyricSources = savedNative
		nativeLyricSourcesMu.Unlock()
		artistAliasMu.Lock()
		if hadAlias {
			artistAliasCache[fx.Query.Artist] = savedAlias
		} else {
			delete(artistAliasCache, fx.Query.Artist)
		}
		artistAliasMu.Unlock()
	})

	s := fx.Settings
	features.LyricsTranslationLanguage = s.TranslationLanguage
	features.LyricsSources = s.Sources
	features.LyricsSourceMode = resolveLyricsSourceMode(s.SourceMode)
	features.LyricsSourceOrder = resolveLyricsSourceOrder(s.SourceOrder)
	setNativeLyricSourcesForPlayer(s.PlayerBundleID)
	artistAliasMu.Lock()
	if artistAliasCache == nil {
		artistAliasCache = map[string]string{}
	}
	if s.ArtistCJKHint != "" {
		artistAliasCache[fx.Query.Artist] = s.ArtistCJKHint
	} else {
		delete(artistAliasCache, fx.Query.Artist)
	}
	artistAliasMu.Unlock()
}

// runGoldenFixture 跑生产链路,产出可比对的 expect。
func runGoldenFixture(fx *goldenFixture) goldenExpect {
	raw := goldenRawRound(fx)
	ranked := rankLyricSourceResults(fx.Query.Artist, fx.Query.Title, fx.Query.Album, fx.Query.DurationSecs, raw)
	return goldenExpectFromRanked(ranked)
}

func goldenExpectFromRanked(ranked []scoredLyricCandidateResult) goldenExpect {
	e := goldenExpect{Verdicts: map[string]string{}}
	for _, c := range ranked {
		if c.Instrumental {
			e.InstrumentalMarker = c.Source
			continue
		}
		verdict := "accepted"
		if c.Score < 0 {
			verdict = "rejected"
			if len(c.ScoreTerms) > 0 {
				verdict = c.ScoreTerms[0].Kind
			}
		}
		e.Verdicts[c.Source] = verdict
		e.Ranked = append(e.Ranked, goldenRankedCandidate{
			Source: c.Source, Score: c.Score, Terms: c.ScoreTerms,
			HasWordTiming: c.HasWordTiming, HasTranslation: c.LyricsTr != "", TranslationLang: c.LyricsTrLang,
			HasRomanization: c.LyricsRoma != "",
		})
	}
	if picked := pickLyricCandidate(ranked); picked != nil {
		e.Winner = picked.Source
		e.WinnerFingerprint = goldenFingerprint(picked.Lyrics)
	}
	return e
}

func goldenFingerprint(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:8])
}

// ---------- 比对 ----------

type goldenDiff struct {
	semantic []string // 冠军 / 判决 / 纯音乐标记
	snapshot []string // 分项快照
}

func diffGoldenExpect(want, got goldenExpect) goldenDiff {
	var d goldenDiff
	if want.Winner != got.Winner {
		d.semantic = append(d.semantic, fmt.Sprintf("冠军: 期望 %q, 实际 %q", want.Winner, got.Winner))
	}
	if want.InstrumentalMarker != got.InstrumentalMarker {
		d.semantic = append(d.semantic, fmt.Sprintf("纯音乐标记: 期望 %q, 实际 %q", want.InstrumentalMarker, got.InstrumentalMarker))
	}
	var sources []string
	seen := map[string]bool{}
	for s := range want.Verdicts {
		if !seen[s] {
			sources = append(sources, s)
			seen[s] = true
		}
	}
	for s := range got.Verdicts {
		if !seen[s] {
			sources = append(sources, s)
			seen[s] = true
		}
	}
	sort.Strings(sources)
	for _, s := range sources {
		w, wok := want.Verdicts[s]
		g, gok := got.Verdicts[s]
		switch {
		case !wok:
			d.semantic = append(d.semantic, fmt.Sprintf("候选 %s: 样本里没有这条候选,实际出现了(判决 %s)", s, g))
		case !gok:
			d.semantic = append(d.semantic, fmt.Sprintf("候选 %s: 期望判决 %s,实际这条候选不存在了", s, w))
		case w != g:
			d.semantic = append(d.semantic, fmt.Sprintf("候选 %s: 判决 期望 %s, 实际 %s", s, w, g))
		}
	}
	if want.WinnerFingerprint != got.WinnerFingerprint {
		d.snapshot = append(d.snapshot, fmt.Sprintf("冠军正文指纹: 期望 %s, 实际 %s", want.WinnerFingerprint, got.WinnerFingerprint))
	}
	// 名次按整体顺序比一次,分项按**源名**逐一比——按位置比会在名次变动时把 A 的期望跟 B 的实际
	// 摆在一行里,读起来像 A 的分项被改得面目全非(突变测试里实测就是这个形态)。
	order := func(r []goldenRankedCandidate) string {
		names := make([]string, 0, len(r))
		for _, c := range r {
			names = append(names, fmt.Sprintf("%s:%d", c.Source, c.Score))
		}
		return strings.Join(names, " > ")
	}
	if wo, go_ := order(want.Ranked), order(got.Ranked); wo != go_ {
		d.snapshot = append(d.snapshot, fmt.Sprintf("名次: 期望 [%s], 实际 [%s]", wo, go_))
	}
	bySource := func(r []goldenRankedCandidate) map[string]goldenRankedCandidate {
		m := make(map[string]goldenRankedCandidate, len(r))
		for _, c := range r {
			m[c.Source] = c
		}
		return m
	}
	wm, gm := bySource(want.Ranked), bySource(got.Ranked)
	for _, s := range sources {
		w, wok := wm[s]
		g, gok := gm[s]
		if !wok || !gok {
			continue // 有无候选的差异已在上面的判决里报过
		}
		if wt, gt := goldenTermsString(w.Terms), goldenTermsString(g.Terms); wt != gt {
			d.snapshot = append(d.snapshot, fmt.Sprintf("%s 分项: 期望 [%s], 实际 [%s]", s, wt, gt))
		}
		if w.HasWordTiming != g.HasWordTiming || w.HasTranslation != g.HasTranslation ||
			w.TranslationLang != g.TranslationLang || w.HasRomanization != g.HasRomanization {
			d.snapshot = append(d.snapshot, fmt.Sprintf("%s 附属: 期望 yrc=%v tr=%v(%s) roma=%v, 实际 yrc=%v tr=%v(%s) roma=%v",
				s, w.HasWordTiming, w.HasTranslation, w.TranslationLang, w.HasRomanization,
				g.HasWordTiming, g.HasTranslation, g.TranslationLang, g.HasRomanization))
		}
	}
	return d
}

func goldenTermsString(terms []scoreTerm) string {
	parts := make([]string, 0, len(terms))
	for _, t := range terms {
		parts = append(parts, fmt.Sprintf("%s:%d", t.Kind, t.Points))
	}
	return strings.Join(parts, " ")
}

func goldenUpdateEnabled() bool { return os.Getenv("LYRICS_GOLDEN_UPDATE") != "" }

func goldenSemanticAccepted(id string) bool {
	v := os.Getenv("LYRICS_GOLDEN_ACCEPT_SEMANTIC")
	if v == "" {
		return false
	}
	if v == "all" {
		return true
	}
	for _, s := range strings.Split(v, ",") {
		if strings.TrimSpace(s) == id {
			return true
		}
	}
	return false
}

func writeGoldenFixture(fx *goldenFixture) error {
	raw, err := json.MarshalIndent(fx, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	return os.WriteFile(filepath.Join(lyricsGoldenDir, fx.ID+".json"), raw, 0o644)
}

// ---------- 测试 ----------

func TestLyricsGolden(t *testing.T) {
	fixtures := loadGoldenFixtures(t)
	if len(fixtures) == 0 {
		t.Skip("testdata/lyricsgolden 还没有样本")
	}
	for _, fx := range fixtures {
		fx := fx
		t.Run(fx.ID, func(t *testing.T) {
			if _, ok := goldenRequiredCategories[fx.Category]; !ok {
				t.Errorf("category=%q 不在 goldenRequiredCategories 里(拼错了,还是忘了登记这一类?)", fx.Category)
			}
			if err := goldenCategoryCheck(fx, fx.Category, fx.Expect); err != nil {
				t.Errorf("样本没有体现它声称的类别 %s: %v", fx.Category, err)
			}
			applyGoldenSettings(t, fx)
			got := runGoldenFixture(fx)
			d := diffGoldenExpect(fx.Expect, got)
			if len(d.semantic) == 0 && len(d.snapshot) == 0 {
				return
			}
			if goldenUpdateEnabled() {
				if len(d.semantic) > 0 && !goldenSemanticAccepted(fx.ID) {
					t.Errorf("语义变化不允许静默改写(冠军/判决/纯音乐标记):\n  %s\n确认这首歌确实该这样之后,加 LYRICS_GOLDEN_ACCEPT_SEMANTIC=%s 再跑一次",
						strings.Join(d.semantic, "\n  "), fx.ID)
					return
				}
				fx.Expect = got
				if err := writeGoldenFixture(fx); err != nil {
					t.Fatalf("写回样本失败: %v", err)
				}
				t.Logf("已更新 %s.json:\n  %s", fx.ID, strings.Join(append(d.semantic, d.snapshot...), "\n  "))
				return
			}
			var msg strings.Builder
			fmt.Fprintf(&msg, "%s(%s)与金标不一致 —— %s《%s》\n", fx.ID, fx.Category, fx.Track.Artist, fx.Track.Title)
			if len(d.semantic) > 0 {
				fmt.Fprintf(&msg, "  [语义] %s\n", strings.Join(d.semantic, "\n  [语义] "))
			}
			if len(d.snapshot) > 0 {
				fmt.Fprintf(&msg, "  [快照] %s\n", strings.Join(d.snapshot, "\n  [快照] "))
			}
			msg.WriteString("  改动是有意的话:LYRICS_GOLDEN_UPDATE=1 go test -run TestLyricsGolden . (语义变化还需 LYRICS_GOLDEN_ACCEPT_SEMANTIC)")
			t.Error(msg.String())
		})
	}
}

// TestLyricsGoldenCategoryCoverage:类别覆盖契约。
func TestLyricsGoldenCategoryCoverage(t *testing.T) {
	fixtures := loadGoldenFixtures(t)
	if len(fixtures) == 0 {
		t.Skip("testdata/lyricsgolden 还没有样本")
	}
	// 一类算"有覆盖",是**有样本真的体现了它**(goldenCategoryCheck 过),不是有样本贴了这个标签——
	// 一个样本常常同时体现好几类(纯音乐那首里网易云的署名行也被否决了),按标签数就漏了。
	var missing []string
	for cat := range goldenRequiredCategories {
		covered := false
		for _, fx := range fixtures {
			if goldenCategoryCheck(fx, cat, fx.Expect) == nil {
				covered = true
				break
			}
		}
		if !covered {
			missing = append(missing, cat)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Errorf("这些类别还没有任何样本体现(按 testdata/lyricsgolden/README.md 采一个):\n  %s", strings.Join(missing, "\n  "))
	}
}

// TestLyricsGoldenFixturesAreScrambled:样本里不许出现明文歌词——置乱后的正文不可能命中任何
// OpenCC 繁→简词典里的字(置乱池刻意避开了它们),也不可能出现 goldenScrambleForbiddenSample
// 里这些高频真实汉字。命中就说明有人手工往样本里塞了明文,或者采集时绕过了 scrambleLyricRound。
func TestLyricsGoldenFixturesAreScrambled(t *testing.T) {
	fixtures := loadGoldenFixtures(t)
	for _, fx := range fixtures {
		for src, g := range fx.Sources {
			texts := []string{g.Lyrics, g.YRC, g.Tr, g.Roma}
			if g.Netease != nil {
				texts = append(texts, g.Netease.Lyrics, g.Netease.Trans, g.Netease.Roma, g.Netease.YRC)
			}
			if g.AMLL != nil {
				texts = append(texts, g.AMLL.LRC, g.AMLL.YRC, g.AMLL.Tr)
			}
			for _, text := range texts {
				if line, ok := goldenFindUnscrambledLine(text); ok {
					t.Errorf("%s/%s 疑似明文歌词行(置乱池不该产出这些字): %q", fx.ID, src, line)
					break
				}
			}
		}
	}
}

// ---------- 类别语义校验:贴了这个标签的样本,必须真的走到了这一类要守的那条判据 ----------

// goldenCategoryCheck 检查样本的 expect 是否**体现**了它声称的类别——"duration-overshoot"的样本里
// 必须真有候选吃到 durationOvershoot,"reject-plain-text"里必须真有候选被 rejectPlainTextOnly。
// 采集时和 TestLyricsGolden 里都跑:防止标签贴错,也防止哪天某条判据被改得永远不触发、而样本仍然
// "全绿"地放行(那时它守的就是空气)。
func goldenCategoryCheck(fx *goldenFixture, category string, e goldenExpect) error {
	hasTerm := func(c goldenRankedCandidate, kind string) bool {
		for _, t := range c.Terms {
			if t.Kind == kind {
				return true
			}
		}
		return false
	}
	var winner *goldenRankedCandidate
	accepted := 0
	for i := range e.Ranked {
		if e.Ranked[i].Score >= 0 {
			accepted++
		}
		if e.Ranked[i].Source == e.Winner {
			winner = &e.Ranked[i]
		}
	}
	anyCand := func(pred func(goldenRankedCandidate) bool) bool {
		for _, c := range e.Ranked {
			if pred(c) {
				return true
			}
		}
		return false
	}
	anyVerdict := func(kind string) bool {
		for _, v := range e.Verdicts {
			if v == kind {
				return true
			}
		}
		return false
	}
	anyRawLanguage := func(lang string) bool {
		for _, g := range fx.Sources {
			if g.Language == lang {
				return true
			}
		}
		return false
	}
	needWinner := func() error {
		if winner == nil {
			return fmt.Errorf("没有冠军")
		}
		return nil
	}
	localHan := containsHan(fx.Query.Artist) || containsHan(fx.Query.Title)

	switch category {
	case "zh-studio-multisource":
		if err := needWinner(); err != nil {
			return err
		}
		if !localHan || accepted < 4 || !hasTerm(*winner, scoreTermWordTiming) || !hasTerm(*winner, scoreTermConsensus) {
			return fmt.Errorf("要求:中文标签、≥4 条可用候选、冠军带逐字与共识(实际 han=%v accepted=%d)", localHan, accepted)
		}
	case "latin-title":
		if err := needWinner(); err != nil {
			return err
		}
		if localHan || accepted < 3 {
			return fmt.Errorf("要求:歌手/歌名均无汉字、≥3 条可用候选(实际 han=%v accepted=%d)", localHan, accepted)
		}
	case "ja-romanization":
		if err := needWinner(); err != nil {
			return err
		}
		if !hasTerm(*winner, scoreTermRoma) {
			return fmt.Errorf("要求:冠军带 romanization 加分")
		}
	case "ko-hangul-lyrics":
		if err := needWinner(); err != nil {
			return err
		}
		hangul := false
		for _, g := range fx.Sources {
			for _, r := range g.Lyrics {
				if r >= goldenHangulLo && r <= goldenHangulHi {
					hangul = true
					break
				}
			}
		}
		if !hangul || !hasTerm(*winner, scoreTermTranslation) {
			return fmt.Errorf("要求:候选正文含谚文、冠军带 translation 加分(实际 hangul=%v)", hangul)
		}
		if anyCand(func(c goldenRankedCandidate) bool { return hasTerm(c, scoreTermRoma) || c.HasRomanization }) {
			return fmt.Errorf("要求:没有任何候选拿到 romanization 加分 / 附带罗马音")
		}
	case "cantonese":
		if err := needWinner(); err != nil {
			return err
		}
		if !anyRawLanguage(songLanguageCantonese) {
			return fmt.Errorf("要求:至少一个源自报语种为 %s", songLanguageCantonese)
		}
	case "live-same-concert":
		if err := needWinner(); err != nil {
			return err
		}
		if !recordingVersionTags(fx.Query.Title, fx.Query.Album)["live"] {
			return fmt.Errorf("要求:本地歌名/专辑声明了 live")
		}
		if hasTerm(*winner, scoreTermLiveAlbumConflict) || hasTerm(*winner, scoreTermVersionTags) {
			return fmt.Errorf("要求:冠军不吃 liveAlbumConflict / versionTags")
		}
	case "live-other-concert":
		if err := needWinner(); err != nil {
			return err
		}
		if !anyCand(func(c goldenRankedCandidate) bool {
			return c.Source != e.Winner && hasTerm(c, scoreTermLiveAlbumConflict)
		}) {
			return fmt.Errorf("要求:有非冠军候选吃到 liveAlbumConflict")
		}
	case "version-tag-mismatch":
		if err := needWinner(); err != nil {
			return err
		}
		if !anyCand(func(c goldenRankedCandidate) bool { return c.Source != e.Winner && hasTerm(c, scoreTermVersionTags) }) {
			return fmt.Errorf("要求:有非冠军候选吃到 versionTags")
		}
	case "multi-artist-credit":
		if err := needWinner(); err != nil {
			return err
		}
		if len(artistCreditParts(fx.Query.Artist)) < 2 {
			return fmt.Errorf("要求:本地歌手是多人合 credit(实际 %q)", fx.Query.Artist)
		}
	case "reject-credit-only":
		if !anyVerdict(scoreRejectCreditOnly) {
			return fmt.Errorf("要求:有候选被 %s", scoreRejectCreditOnly)
		}
	case "reject-plain-text":
		if !anyVerdict(scoreRejectPlainTextOnly) {
			return fmt.Errorf("要求:有候选被 %s", scoreRejectPlainTextOnly)
		}
	case "reject-wrong-language":
		if !anyVerdict(scoreRejectWrongLanguage) {
			return fmt.Errorf("要求:有候选被 %s", scoreRejectWrongLanguage)
		}
	case "duration-overshoot":
		if !anyCand(func(c goldenRankedCandidate) bool { return hasTerm(c, scoreTermDurationOvershoot) }) {
			return fmt.Errorf("要求:有候选吃到 durationOvershoot")
		}
	case "duration-corroborated":
		if err := needWinner(); err != nil {
			return err
		}
		if !hasTerm(*winner, scoreTermCorroborated) {
			return fmt.Errorf("要求:冠军靠 corroborated 拿分")
		}
	case "line-only-winner":
		if err := needWinner(); err != nil {
			return err
		}
		if hasTerm(*winner, scoreTermWordTiming) || !anyCand(func(c goldenRankedCandidate) bool { return c.Score >= 0 && hasTerm(c, scoreTermWordTiming) }) {
			return fmt.Errorf("要求:冠军无逐字,且有别的可用候选带逐字")
		}
	case "amll-embedded-translation":
		if err := needWinner(); err != nil {
			return err
		}
		if e.Winner != "amll" || !hasTerm(*winner, scoreTermTranslation) {
			return fmt.Errorf("要求:冠军是 amll 且带 translation 加分")
		}
	case "native-player-source":
		if err := needWinner(); err != nil {
			return err
		}
		if fx.Settings.PlayerBundleID == "" || !hasTerm(*winner, scoreTermNativeSource) {
			return fmt.Errorf("要求:记录了播放器且冠军带 nativeSource 加分")
		}
	case "single-candidate":
		if err := needWinner(); err != nil {
			return err
		}
		if len(e.Ranked) != 1 {
			return fmt.Errorf("要求:只有 1 条候选(实际 %d)", len(e.Ranked))
		}
	case "instrumental-marker":
		if e.Winner != "" || e.InstrumentalMarker == "" {
			return fmt.Errorf("要求:没有冠军且有纯音乐标记(实际 winner=%q marker=%q)", e.Winner, e.InstrumentalMarker)
		}
	default:
		return fmt.Errorf("未知类别 %q", category)
	}
	return nil
}

// TestLyricsGoldenWinnersAreIndependentlyJustified:每个样本的冠军都必须用样本自己的数据重新
// 通过 goldenJudgeEvidence——防止有人手改 expect.winner 钉一个站不住的冠军,也防止"缓存里就是它"
// 被当成唯一依据。cache_agreement 是采集时的旁证,重算时原样沿用。
func TestLyricsGoldenWinnersAreIndependentlyJustified(t *testing.T) {
	fixtures := loadGoldenFixtures(t)
	for _, fx := range fixtures {
		fx := fx
		t.Run(fx.ID, func(t *testing.T) {
			applyGoldenSettings(t, fx)
			ranked := rankLyricSourceResults(fx.Query.Artist, fx.Query.Title, fx.Query.Album, fx.Query.DurationSecs, goldenRawRound(fx))
			ev := goldenComputeEvidence(fx.Query, ranked)
			ev.CacheAgreement = fx.LabelEvidence.CacheAgreement
			if err := goldenJudgeEvidence(fx.Query, fx.Expect.Winner, ev); err != nil {
				t.Errorf("冠军 %q 的独立判据不成立: %v\n  %+v", fx.Expect.Winner, err, ev)
			}
			stored := fx.LabelEvidence
			if stored.ConsensusPeers != ev.ConsensusPeers || stored.TitleAccepted != ev.TitleAccepted ||
				stored.VersionTagsOK != ev.VersionTagsOK || stored.AlbumScore != ev.AlbumScore ||
				stored.Instrumental != ev.Instrumental || stored.LiveMismatch != ev.LiveMismatch ||
				abs(stored.CoveragePct-ev.CoveragePct) > 0.5 {
				t.Errorf("样本里记的判据跟重算的不一致(有人手改过样本?):\n  记录 %+v\n  重算 %+v", stored, ev)
			}
		})
	}
}
