// simeval_test.go — 反事实(counterfactual)评测:对 201 首真实库内曲目的检索模拟样本,
// 逐维度消融**尚未入引擎**的候选打分维度,量化「若加上该维度,冠军会怎么翻盘」。离线
// 运行,不发任何网络请求;用 SIMEVAL_DATA 环境变量门控,不设置时整个测试跳过。
//
// v3(2026-08-12)已把四个维度+overshoot 收进引擎(见 lyricsScoringVersion 注释),它们的
// delta 函数已从这里移除;基线即 v3 引擎本身,并与 golden_shipped.json(v2 时代按"发货
// 集合"算出的每首冠军黄金参照)逐首比对——引擎实现若与被评测背书的口径漂移,测试直接红。
//
// 量尺纪律(与 2026-08-09 消融实验同款方法学,量尺独立于被测维度):
//   - contentMajority: 候选间归一化正文的字符 3-gram Jaccard,sim>=0.5 建边聚类,
//     最大且成员>=2 的簇为多数派;
//   - durationVerdict: 真实 duration vs 候选末句时间戳,按 durationFits 同款规则;
//   - manualVerdict: 用户手选金标签(enrich 缓存 manual_lyrics=true)正文比对;
//   - 评测 contentConsensus 维度自己时主量尺只用 durationVerdict+manualVerdict
//     (content 量尺与维度同源,禁用,防循环)。
//
// 打分复用包内真实 helper(albumScore/versionTagsIn/versionTagsMismatch/normLoose/
// toSimplified/artistCreditParts/firstCreditedArtist/isCreditLine/lastLRCTimestampSecs/
// durationFits/lrcTimestampRe/scoreLyricCandidateDetailed 等),不重抄实现。
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
	"unicode"
)

// ---------- 样本数据结构 ----------

type simCandJSON struct {
	Source        string          `json:"source"`
	Lyrics        string          `json:"lyrics"`
	LyricsTr      string          `json:"lyrics_tr"`
	LyricsTrLang  string          `json:"lyrics_tr_lang"`
	LyricsRoma    string          `json:"lyrics_roma"`
	LyricsYRC     string          `json:"lyrics_yrc"`
	HasWordTiming bool            `json:"has_word_timing"`
	Score         int             `json:"score"`
	ScoreTerms    json.RawMessage `json:"score_terms"`
	Title         string          `json:"title"`
	Artist        string          `json:"artist"`
	Album         string          `json:"album"`
	CoverURL      string          `json:"cover_url"`
}

type simTrackJSON struct {
	Artist       string  `json:"artist"`
	Title        string  `json:"title"`
	Album        string  `json:"album"`
	Duration     float64 `json:"duration"`
	ChosenSource string  `json:"chosen_source"`
	Key          string  `json:"key"`
}

type simRunJSON struct {
	Track  simTrackJSON `json:"track"`
	Result struct {
		Candidates []simCandJSON `json:"candidates"`
	} `json:"result"`
}

// ---------- 评测中间态 ----------

type evalCand struct {
	raw     simCandJSON
	c       lyricCandidate
	corro   bool
	v2Score int
	// rawSum = Σ v2Terms 分值(夹底前)。反事实的正确口径:delta 加在 rawSum 上再
	// 统一 max(1,·) 夹底——直接加在已夹底的 v2Score 上会把引擎已吸收的负分退还,
	// 系统性高估正向维度(复核抓出的高危项)。
	rawSum  int
	v2Terms []scoreTerm
	// 量尺
	body     string
	grams    map[string]struct{}
	last     float64
	hasLast  bool
	contentV string // right | wrong | unknown
	durV     string // fit | overshoot | mismatch | unknown
	manualV  string // right | wrong | unknown | ""(该曲无金标签)
}

type evalTrack struct {
	key, artist, title  string
	la, lt, lal         string // toSimplified 后的本地三元组(打分入参)
	dur                 float64
	cands               []*evalCand
	valid               []int // v2Score>=0 的下标(参与冠军竞争)
	champIdx            int   // v2 冠军(valid 里最高分,平手取先到);无有效候选=-1
	manualGrams         map[string]struct{}
	hasManual           bool
	canonicalArtist     string
	anyCandDurationFits bool
}

// ---------- 缓存(金标签 + canonical_artist)加载 ----------

type enrichCacheEntry struct {
	Lyrics          string `json:"lyrics"`
	ManualLyrics    bool   `json:"manual_lyrics"`
	CanonicalArtist string `json:"canonical_artist"`
}

// ---------- 文本/结构小工具(维度定义与量尺自身的口径,非包内已有 helper 的重抄) ----------

// effLineTexts: rank9 口径的有效行——带戳、去戳后非空、非署名行、且含至少一个字母/汉字/假名
// (unicode.IsLetter 同时覆盖拉丁/汉字/假名,剔除纯标点/占位行)。
func effLineTexts(lyrics string) []string {
	var out []string
	for _, line := range strings.Split(lyrics, "\n") {
		if !lrcTimestampRe.MatchString(line) {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" || isCreditLine(text) {
			continue
		}
		hasLetter := false
		for _, r := range text {
			if unicode.IsLetter(r) {
				hasLetter = true
				break
			}
		}
		if !hasLetter {
			continue
		}
		out = append(out, text)
	}
	return out
}

// lrcEvent / lrcEventsOf: rank5 结构体检的 (t,text) 事件展开(每行全部时间戳标签,
// 丢弃去戳后空文本行),按 t 排序。t 用毫秒整数,方便 h4 判"同一时间戳"。
type lrcEvent struct {
	ms   int
	text string
}

func lrcEventsOf(lyrics string) []lrcEvent {
	var evs []lrcEvent
	for _, line := range strings.Split(lyrics, "\n") {
		ms := lrcTimestampCaptureRe.FindAllStringSubmatch(line, -1)
		if len(ms) == 0 {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" {
			continue
		}
		for _, m := range ms {
			mm, _ := strconv.Atoi(m[1])
			ss, _ := strconv.Atoi(m[2])
			frac, _ := strconv.Atoi(m[3])
			secs := float64(mm*60+ss) + float64(frac)/math.Pow(10, float64(len(m[3])))
			evs = append(evs, lrcEvent{ms: int(secs*1000 + 0.5), text: text})
		}
	}
	sort.Slice(evs, func(i, j int) bool { return evs[i].ms < evs[j].ms })
	return evs
}

// YRC 解析(rank4):归一化语法 "[行始ms,行长ms](词始ms,词长ms,flag)词"。
// netease 元数据行是 JSON({"t":..}),不匹配行首 [n,n],天然跳过。
var simevalYRCLineRe = regexp.MustCompile(`^\[(\d+),(\d+)\]`)
var simevalYRCWordRe = regexp.MustCompile(`\((\d+),(\d+),(\d+)\)`)

type yrcStats struct {
	realLines       int   // 含>=2词段的行数
	starts          []int // 全部词段 start,文档序
	endMs           int   // 末刻 = max(start+dur)
	lastLineStartMs int   // 最后一个带戳行的行首 start(自洽闸(b)用,与 LRC 末句 start 同类量)
}

func parseYRCStats(yrc string) yrcStats {
	var st yrcStats
	for _, line := range strings.Split(yrc, "\n") {
		m := simevalYRCLineRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		if ls, err := strconv.Atoi(m[1]); err == nil && ls > st.lastLineStartMs {
			st.lastLineStartMs = ls
		}
		words := simevalYRCWordRe.FindAllStringSubmatch(line, -1)
		if len(words) >= 2 {
			st.realLines++
		}
		for _, w := range words {
			s, _ := strconv.Atoi(w[1])
			d, _ := strconv.Atoi(w[2])
			st.starts = append(st.starts, s)
			if s+d > st.endMs {
				st.endMs = s + d
			}
		}
	}
	return st
}

func monotonicRatio(starts []int) float64 {
	if len(starts) < 2 {
		return 1
	}
	ok := 0
	for i := 1; i < len(starts); i++ {
		if starts[i] >= starts[i-1] {
			ok++
		}
	}
	return float64(ok) / float64(len(starts)-1)
}

func durationTermPoints(terms []scoreTerm) int {
	for _, t := range terms {
		switch t.Kind {
		case scoreTermDuration, scoreTermCorroborated, scoreTermDurationOff, scoreTermDurationOvershoot:
			return t.Points
		}
	}
	return 0
}

func linesTermPoints(terms []scoreTerm) int {
	for _, t := range terms {
		if t.Kind == scoreTermLines {
			return t.Points
		}
	}
	return 0
}

// ---------- 报告结构 ----------

type champSide struct {
	Source         string `json:"source"`
	Score          int    `json:"score"`
	ContentVerdict string `json:"contentVerdict"`
	DurVerdict     string `json:"durVerdict"`
	ManualVerdict  string `json:"manualVerdict,omitempty"`
}

type flipRec struct {
	Track   string    `json:"track"`
	Artist  string    `json:"artist"`
	Title   string    `json:"title"`
	Old     champSide `json:"old"`
	New     champSide `json:"new"`
	Verdict string    `json:"verdict"` // improvement | regression | neutral
}

type dimReport struct {
	Flips    []flipRec `json:"flips"`
	NFlips   int       `json:"n_flips"`
	NImprove int       `json:"n_improve"`
	NRegress int       `json:"n_regress"`
	NNeutral int       `json:"n_neutral"`
	Examples []string  `json:"examples"`
	Notes    string    `json:"notes,omitempty"`
}

type simevalReport struct {
	BaselineMismatches       int                   `json:"baseline_mismatches"`
	BaselineMismatchExamples []string              `json:"baseline_mismatch_examples"`
	PerDimension             map[string]*dimReport `json:"per_dimension"`
	JointAblation            map[string]*dimReport `json:"joint_ablation"`
	ManualTracksInSample     []string              `json:"manual_tracks_in_sample"`
	Assumptions              []string              `json:"assumptions"`
	NTracks                  int                   `json:"n_tracks"`
	NCandidates              int                   `json:"n_candidates"`
}

// ---------- 主测试 ----------

func TestSimEval(t *testing.T) {
	dataDir := os.Getenv("SIMEVAL_DATA")
	if dataDir == "" {
		t.Skip("SIMEVAL_DATA 未设置,跳过离线反事实评测")
	}

	// 1. 加载 simruns
	files, err := filepath.Glob(filepath.Join(dataDir, "simruns", "*.json"))
	if err != nil || len(files) == 0 {
		t.Fatalf("simruns 加载失败: %v (files=%d)", err, len(files))
	}
	sort.Strings(files)

	// v3 的增值内容维度读目标语言;评测样本采集时(2026-08-12)用户设置即 zh,黄金参照
	// 也按 zh 生成——这里显式钉住,不依赖测试进程恰好没加载 features 的零值。
	features.LyricsTranslationLanguage = "zh"

	// 黄金参照:发货集合算出的每首冠军(见文件头注释)。
	//
	// ⚠️ 参照与**这一份样本快照**绑定:fingerprint 记着样本的曲目/候选构成,重采数据后
	// 各源返回的候选文本必然漂移,拿旧参照比对会成批报"引擎漂移"的假阳性。指纹对不上
	// 就只提示、不断言;确认引擎正确后用 SIMEVAL_WRITE_GOLDEN=1 重生成一份新参照。
	type goldenChamp struct {
		Source string `json:"source"`
		Score  int    `json:"score"`
	}
	type goldenFile struct {
		Fingerprint string                 `json:"fingerprint"`
		Note        string                 `json:"note"`
		Champs      map[string]goldenChamp `json:"champs"`
	}
	goldenPath := filepath.Join(dataDir, "golden_shipped.json")
	writeGolden := os.Getenv("SIMEVAL_WRITE_GOLDEN") != ""
	var goldenIn goldenFile
	if raw, err := os.ReadFile(goldenPath); err == nil {
		if err := json.Unmarshal(raw, &goldenIn); err != nil {
			t.Fatalf("golden_shipped.json 解析失败: %v", err)
		}
	} else if !writeGolden {
		t.Logf("警告: golden_shipped.json 不可读(%v),跳过黄金参照比对", err)
	}
	golden := goldenIn.Champs

	// 2. 加载 enrich 缓存(金标签 + canonical_artist),纯本地文件,无网络
	manualByAT := map[string]string{} // normLoose(artist)|normLoose(title) -> 手选歌词
	canonByAT := map[string]string{}  // 同键 -> canonical_artist
	home, _ := os.UserHomeDir()
	cachePath := filepath.Join(home, ".config", "lyrimuse", "lyrimuse-enrich-cache.json")
	if raw, err := os.ReadFile(cachePath); err == nil {
		var cache map[string]enrichCacheEntry
		if err := json.Unmarshal(raw, &cache); err != nil {
			t.Fatalf("enrich 缓存解析失败: %v", err)
		}
		for key, e := range cache {
			parts := strings.SplitN(key, "|", 3)
			if len(parts) < 2 {
				continue
			}
			at := normLoose(parts[0]) + "|" + normLoose(parts[1])
			if e.ManualLyrics && e.Lyrics != "" {
				manualByAT[at] = e.Lyrics
			}
			if e.CanonicalArtist != "" {
				if _, seen := canonByAT[at]; !seen {
					canonByAT[at] = e.CanonicalArtist
				}
			}
		}
	} else {
		t.Logf("警告: enrich 缓存不可读(%v),manualVerdict/canonicalArtist 均缺席", err)
	}

	// 3. baseline 重算 + 量尺预计算
	var tracks []*evalTrack
	baselineMismatch := 0
	var mismatchExamples []string
	nCands := 0
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("读 %s: %v", f, err)
		}
		var run simRunJSON
		if err := json.Unmarshal(raw, &run); err != nil {
			t.Fatalf("解析 %s: %v", f, err)
		}
		tr := &evalTrack{
			key:      run.Track.Key,
			artist:   run.Track.Artist,
			title:    run.Track.Title,
			la:       toSimplified(run.Track.Artist),
			lt:       toSimplified(run.Track.Title),
			lal:      toSimplified(run.Track.Album),
			dur:      run.Track.Duration,
			champIdx: -1,
		}
		at := normLoose(run.Track.Artist) + "|" + normLoose(run.Track.Title)
		if ml, ok := manualByAT[at]; ok {
			tr.hasManual = true
			tr.manualGrams = lyricGram3Set(lyricConsensusBody(ml))
		}
		tr.canonicalArtist = canonByAT[at]

		// 候选 → lyricCandidate(与 enrich.go 构造方式一致:hasWordTiming = yrc 非空,
		// usable 标志同 enrich.go 用生产 usableValueAdd 算——netease 的社区译文固定 zh,
		// 样本里 lyrics_tr_lang 字段就是采集时记下的语言)
		var batch []lyricCandidate
		for _, rc := range run.Result.Candidates {
			uTr, uRoma := usableValueAdd(rc.Lyrics, rc.LyricsTr, rc.LyricsTrLang, rc.LyricsRoma, features.LyricsTranslationLanguage)
			batch = append(batch, lyricCandidate{
				source:                rc.Source,
				lyrics:                rc.Lyrics,
				wordTimingYRC:         rc.LyricsYRC,
				hasWordTiming:         rc.LyricsYRC != "",
				hasUsableTranslation:  uTr,
				hasUsableRomanization: uRoma,
				title:                 rc.Title,
				artist:                rc.Artist,
				album:                 rc.Album,
			})
		}
		corro := corroboratedEndings(batch, tr.dur)
		peers := contentConsensusPeers(tr.la, tr.lt, batch, tr.dur)
		for i, rc := range run.Result.Candidates {
			nCands++
			ec := &evalCand{raw: rc, c: batch[i], corro: corro[rc.Source]}
			ec.v2Score, ec.v2Terms = scoreLyricCandidateDetailed(tr.la, tr.lt, tr.lal, tr.dur, batch[i], ec.corro, peers[rc.Source])
			for _, tm := range ec.v2Terms {
				ec.rawSum += tm.Points
			}
			ec.last, ec.hasLast = lastLRCTimestampSecs(rc.Lyrics)
			ec.body = lyricConsensusBody(rc.Lyrics)
			if len([]rune(ec.body)) >= 30 {
				ec.grams = lyricGram3Set(ec.body)
			}
			tr.cands = append(tr.cands, ec)
			if ec.v2Score >= 0 {
				tr.valid = append(tr.valid, i)
				if tr.dur > 0 && ec.hasLast && durationFits(ec.last, tr.dur) {
					tr.anyCandDurationFits = true
				}
			}
		}
		// v3 冠军:有效候选里最高分,平手取样本序(=分数排序,平手保构造序)
		best := -1
		for _, i := range tr.valid {
			if best < 0 || tr.cands[i].v2Score > tr.cands[best].v2Score {
				best = i
			}
		}
		tr.champIdx = best
		// 黄金参照断言:v3 引擎冠军必须逐首等于 v2+发货集合 delta 的预计算结果——
		// 不一致说明引擎实现与消融评测背书的口径发生了漂移,这是要红的错误,不是统计。
		if g, ok := golden[tr.key]; ok && best >= 0 {
			if tr.cands[best].c.source != g.Source || tr.cands[best].v2Score != g.Score {
				baselineMismatch++
				if len(mismatchExamples) < 10 {
					mismatchExamples = append(mismatchExamples, fmt.Sprintf(
						"《%s》: 引擎冠军 %s(%d) ≠ 黄金参照 %s(%d)",
						run.Track.Title, tr.cands[best].c.source, tr.cands[best].v2Score, g.Source, g.Score))
				}
			}
		}

		// 量尺: durationVerdict
		for _, ec := range tr.cands {
			switch {
			case tr.dur <= 0 || !ec.hasLast:
				ec.durV = "unknown"
			case durationFits(ec.last, tr.dur):
				ec.durV = "fit"
			case ec.last > tr.dur+lyricOvershootToleranceSecs:
				ec.durV = "overshoot"
			default:
				ec.durV = "mismatch"
			}
		}
		// 量尺: contentMajority(只在有效候选间聚类;正文<30 字符的候选记 unknown)
		computeContentMajority(tr)
		// 量尺: manualVerdict
		for _, ec := range tr.cands {
			if !tr.hasManual {
				continue
			}
			if ec.grams == nil {
				ec.manualV = "unknown"
				continue
			}
			sim := gramJaccard(ec.grams, tr.manualGrams)
			switch {
			case sim >= 0.6:
				ec.manualV = "right"
			case sim < 0.35:
				ec.manualV = "wrong"
			default:
				ec.manualV = "unknown"
			}
		}
		tracks = append(tracks, tr)
	}
	// 样本指纹:曲目 key + 每条候选的源与正文长度。重采后必变。
	h := sha256.New()
	for _, tr := range tracks {
		fmt.Fprintf(h, "%s|%.1f|", tr.key, tr.dur)
		for _, ec := range tr.cands {
			fmt.Fprintf(h, "%s:%d,", ec.c.source, len(ec.c.lyrics))
		}
		fmt.Fprint(h, ";")
	}
	fingerprint := fmt.Sprintf("%d/%d/%x", len(tracks), nCands, h.Sum(nil)[:8])

	switch {
	case writeGolden:
		out := goldenFile{
			Fingerprint: fingerprint,
			Note:        "v3 引擎(专辑亲和/正文共识/标题梯度/增值决胜/overshoot)在本样本快照上的逐首冠军。重采样本后需重新生成。",
			Champs:      map[string]goldenChamp{},
		}
		for _, tr := range tracks {
			if tr.champIdx >= 0 {
				out.Champs[tr.key] = goldenChamp{Source: tr.cands[tr.champIdx].c.source, Score: tr.cands[tr.champIdx].v2Score}
			}
		}
		b, err := json.MarshalIndent(out, "", " ")
		if err != nil {
			t.Fatalf("序列化黄金参照: %v", err)
		}
		if err := os.WriteFile(goldenPath, b, 0o644); err != nil {
			t.Fatalf("写黄金参照: %v", err)
		}
		t.Logf("已重生成黄金参照 %s(%d 首,指纹 %s)", goldenPath, len(out.Champs), fingerprint)
	case len(golden) == 0:
		// 已在上面提示过
	case goldenIn.Fingerprint != "" && goldenIn.Fingerprint != fingerprint:
		t.Logf("样本已重采(指纹 %s ≠ 参照 %s),跳过黄金参照断言;确认引擎无误后用 SIMEVAL_WRITE_GOLDEN=1 重生成",
			fingerprint, goldenIn.Fingerprint)
	case baselineMismatch > 0:
		t.Errorf("v3 引擎冠军与黄金参照不一致 %d 首(引擎与评测口径漂移!): %v", baselineMismatch, mismatchExamples)
	}
	t.Logf("样本: %d 首 / %d 条候选;黄金参照不一致: %d 首;指纹 %s", len(tracks), nCands, baselineMismatch, fingerprint)

	// 4. 尚未入引擎的候选维度(v3 已收编的四个+overshoot 已从这里移除,基线即含它们)
	dims := []struct {
		name string
		fn   func(tr *evalTrack, i int) int
	}{
		{"durationAsymmetry", deltaDurationAsymmetry},
		{"wordTimingCoverage", deltaWordTimingCoverage},
		{"lrcStructureHealth", deltaLRCStructureHealth},
		{"artistIdentityAlignment", deltaArtistIdentityAlignment},
		{"unverifiableVersionPenalty", deltaUnverifiableVersionPenalty},
		{"effLineDensity", deltaEffLineDensity},
		{"creditRatioPenalty", deltaCreditRatioPenalty},
		{"independentAlbumCorroboration", deltaIndependentAlbumCorroboration},
	}

	report := &simevalReport{
		BaselineMismatches:       baselineMismatch,
		BaselineMismatchExamples: mismatchExamples,
		PerDimension:             map[string]*dimReport{},
		JointAblation:            map[string]*dimReport{},
		NTracks:                  len(tracks),
		NCandidates:              nCands,
		Assumptions: []string{
			"基线=v3 引擎(含专辑亲和/正文共识/标题梯度/增值决胜/overshoot),targetLang 钉 zh 与黄金参照一致",
			"新分=max(1, raw项和+delta)——delta 加在夹底前的原始项和上再按引擎口径统一夹底(修正版;旧版加在已夹底分上会退还引擎已吸收的负分)",
			"wordTimingCoverage 自洽闸(b)修正版:比较 YRC 最后一行 start 与 LRC 末句 start(同类量);旧版拿 YRC 末词 start+dur(唱完时刻)比 LRC 末行起点,天然带一行歌词长度的正偏差,误杀真逐字",
			"titleMatchTier 噪音括号升档修正版:只看括号段内的版本词(旧版对整标题调 titleVersionTags 会把 dash 尾段版本词也算进去,压低本该 EXACT 的候选)",
			"contentMajority 最大簇平手时取含最小候选下标的簇(修正版;旧版依赖 Go map 迭代序,跨运行不可复现)",
			"翻盘量尺: contentMajority→durationVerdict→neutral;contentConsensus 维度按方法学换用 manualVerdict→durationVerdict(防量尺与维度同源循环)",
			"independentAlbumCorroboration 只测『候选互证』半边,apple 第六方半边样本缺字段不可测(catalog eval_plan 已声明)",
			"本轮样本各源候选数: netease/qq/kugou/lrclib(无 musixmatch 候选)",
		},
	}
	for _, tr := range tracks {
		if tr.hasManual {
			report.ManualTracksInSample = append(report.ManualTracksInSample, tr.key)
		}
	}
	sort.Strings(report.ManualTracksInSample)

	for _, d := range dims {
		rep := runAblation(tracks, d.name, d.fn)
		report.PerDimension[d.name] = rep
	}

	// 5. rank1+rank5 联合消融(catalog methodology 要求:③档放宽由 h2 补枪,须联合验证)
	joint := func(tr *evalTrack, i int) int {
		return deltaDurationAsymmetry(tr, i) + deltaLRCStructureHealth(tr, i)
	}
	report.JointAblation["durationAsymmetry+lrcStructureHealth"] = runAblation(tracks, "durationAsymmetry+lrcStructureHealth", joint)

	// 6. 写报告
	out, err := json.MarshalIndent(report, "", " ")
	if err != nil {
		t.Fatalf("序列化报告: %v", err)
	}
	outPath := filepath.Join(dataDir, "counterfactual_report.json")
	if err := os.WriteFile(outPath, out, 0o644); err != nil {
		t.Fatalf("写报告 %s: %v", outPath, err)
	}
	t.Logf("报告已写入 %s", outPath)
	for _, d := range dims {
		r := report.PerDimension[d.name]
		t.Logf("%-32s flips=%d improve=%d regress=%d neutral=%d", d.name, r.NFlips, r.NImprove, r.NRegress, r.NNeutral)
	}
	jr := report.JointAblation["durationAsymmetry+lrcStructureHealth"]
	t.Logf("%-32s flips=%d improve=%d regress=%d neutral=%d", "joint(rank1+rank5)", jr.NFlips, jr.NImprove, jr.NRegress, jr.NNeutral)
}

// computeContentMajority 在一个 track 的有效候选间做 3-gram Jaccard sim>=0.5 聚类,
// 最大且成员>=2 的簇为多数派;在多数派=right;存在多数派且与簇内最大 sim<0.35=wrong;
// 其余(含正文过短没有 gram 集的)=unknown。
func computeContentMajority(tr *evalTrack) {
	for _, ec := range tr.cands {
		ec.contentV = "unknown"
	}
	var idx []int
	for _, i := range tr.valid {
		if tr.cands[i].grams != nil {
			idx = append(idx, i)
		}
	}
	if len(idx) < 2 {
		return
	}
	parent := map[int]int{}
	var find func(int) int
	find = func(x int) int {
		if parent[x] != x {
			parent[x] = find(parent[x])
		}
		return parent[x]
	}
	for _, i := range idx {
		parent[i] = i
	}
	for a := 0; a < len(idx); a++ {
		for b := a + 1; b < len(idx); b++ {
			if gramJaccard(tr.cands[idx[a]].grams, tr.cands[idx[b]].grams) >= 0.5 {
				parent[find(idx[a])] = find(idx[b])
			}
		}
	}
	clusters := map[int][]int{}
	for _, i := range idx {
		r := find(i)
		clusters[r] = append(clusters[r], i)
	}
	var roots []int
	for r := range clusters {
		roots = append(roots, r)
	}
	sort.Ints(roots)
	var majority []int
	minIdx := func(m []int) int {
		mi := m[0]
		for _, x := range m {
			if x < mi {
				mi = x
			}
		}
		return mi
	}
	for _, r := range roots {
		members := clusters[r]
		if len(members) < 2 {
			continue
		}
		if len(members) > len(majority) ||
			(majority != nil && len(members) == len(majority) && minIdx(members) < minIdx(majority)) {
			majority = members
		}
	}
	if majority == nil {
		return
	}
	inMaj := map[int]bool{}
	for _, i := range majority {
		inMaj[i] = true
	}
	for _, i := range idx {
		if inMaj[i] {
			tr.cands[i].contentV = "right"
			continue
		}
		maxSim := 0.0
		for _, m := range majority {
			if s := gramJaccard(tr.cands[i].grams, tr.cands[m].grams); s > maxSim {
				maxSim = s
			}
		}
		if maxSim < 0.35 {
			tr.cands[i].contentV = "wrong"
		}
	}
}

// runAblation: 对单一维度做反事实重选冠军,记录翻盘与三态判定。
func runAblation(tracks []*evalTrack, name string, fn func(tr *evalTrack, i int) int) *dimReport {
	rep := &dimReport{Flips: []flipRec{}, Examples: []string{}}
	contentRank := map[string]int{"right": 2, "unknown": 1, "wrong": 0}
	durRank := map[string]int{"fit": 3, "unknown": 2, "mismatch": 1, "overshoot": 0}
	for _, tr := range tracks {
		if tr.champIdx < 0 {
			continue
		}
		newBest, newBestScore := -1, 0
		newScores := map[int]int{}
		for _, i := range tr.valid {
			s := tr.cands[i].rawSum + fn(tr, i)
			if s < 1 {
				s = 1 // 引擎同款夹底(match.go:409-411):重扣表达"差"而非"不能用"
			}
			newScores[i] = s
			if newBest < 0 || s > newBestScore {
				newBest, newBestScore = i, s
			}
		}
		if newBest == tr.champIdx {
			continue
		}
		oldC, newC := tr.cands[tr.champIdx], tr.cands[newBest]
		verdict := "neutral"
		if name == "contentConsensus" {
			// 方法学专门条款:主量尺只用 manualVerdict+durationVerdict
			switch {
			case tr.hasManual && contentRank[newC.manualV] != contentRank[oldC.manualV]:
				if contentRank[newC.manualV] > contentRank[oldC.manualV] {
					verdict = "improvement"
				} else {
					verdict = "regression"
				}
			case durRank[newC.durV] != durRank[oldC.durV]:
				if durRank[newC.durV] > durRank[oldC.durV] {
					verdict = "improvement"
				} else {
					verdict = "regression"
				}
			}
		} else {
			switch {
			case contentRank[newC.contentV] != contentRank[oldC.contentV]:
				if contentRank[newC.contentV] > contentRank[oldC.contentV] {
					verdict = "improvement"
				} else {
					verdict = "regression"
				}
			case durRank[newC.durV] != durRank[oldC.durV]:
				if durRank[newC.durV] > durRank[oldC.durV] {
					verdict = "improvement"
				} else {
					verdict = "regression"
				}
			}
		}
		rec := flipRec{
			Track:  tr.key,
			Artist: tr.artist,
			Title:  tr.title,
			Old: champSide{Source: oldC.c.source, Score: oldC.v2Score,
				ContentVerdict: oldC.contentV, DurVerdict: oldC.durV, ManualVerdict: oldC.manualV},
			New: champSide{Source: newC.c.source, Score: newScores[newBest],
				ContentVerdict: newC.contentV, DurVerdict: newC.durV, ManualVerdict: newC.manualV},
			Verdict: verdict,
		}
		rep.Flips = append(rep.Flips, rec)
		switch verdict {
		case "improvement":
			rep.NImprove++
		case "regression":
			rep.NRegress++
		default:
			rep.NNeutral++
		}
	}
	rep.NFlips = len(rep.Flips)
	for _, f := range rep.Flips {
		if len(rep.Examples) >= 5 {
			break
		}
		manualNote := ""
		if f.Old.ManualVerdict != "" || f.New.ManualVerdict != "" {
			manualNote = fmt.Sprintf(",手选金标签判定 %s→%s", f.Old.ManualVerdict, f.New.ManualVerdict)
		}
		rep.Examples = append(rep.Examples, fmt.Sprintf(
			"《%s》(%s): 冠军由 %s(%d分) 换成 %s(%d分);内容多数派 %s→%s,时长判定 %s→%s%s ⇒ %s",
			f.Title, f.Artist, f.Old.Source, f.Old.Score, f.New.Source, f.New.Score,
			f.Old.ContentVerdict, f.New.ContentVerdict, f.Old.DurVerdict, f.New.DurVerdict,
			manualNote, f.Verdict))
	}
	return rep
}

// ---------- 12 维度 delta 实现(catalog definition 逐条对应) ----------

// rank1 durationAsymmetry 的**剩余**部分(欠覆盖档细分)。overshoot −700 已随 v3 入引擎,
// 这里只评还没上的③/④档:0.25<r<=0.45 → corroborated?+50:−200;r>0.45 → corroborated?−100:−500。
// ⚠️ 2026-08-12 轮结论:③档减罚对温和截断货过仁慈(In My Room 案),等收窄参数后再评。
// delta = 新时长项 − v3 时长项。
func deltaDurationAsymmetry(tr *evalTrack, i int) int {
	ec := tr.cands[i]
	if tr.dur <= 0 || !ec.hasLast {
		return 0
	}
	if durationFits(ec.last, tr.dur) {
		return 0 // ①档维持现状
	}
	old := durationTermPoints(ec.v2Terms)
	r := (tr.dur - ec.last) / tr.dur
	var newPts int
	switch {
	case ec.last > tr.dur+lyricOvershootToleranceSecs:
		return 0 // ② overshoot −700 已在 v3 引擎里,无差分
	case r > durationFitTolerance && r <= 0.45:
		if ec.corro {
			newPts = 50
		} else {
			newPts = -200
		} // ③ 温和欠覆盖
	case r > 0.45:
		if ec.corro {
			newPts = -100
		} else {
			newPts = -500
		} // ④ 重度欠覆盖
	default:
		return 0 // 负 r 但未 overshoot 的缝隙形态(短曲),维持现状
	}
	return newPts - old
}

// rank4 wordTimingCoverage: 逐字 +400 布尔改覆盖率阶梯+自洽资格闸。
// delta = 新逐字项 − (hasWordTiming?400:0)。
func deltaWordTimingCoverage(tr *evalTrack, i int) int {
	ec := tr.cands[i]
	old := 0
	if ec.c.hasWordTiming {
		old = 400
	}
	newPts := 0
	if ec.c.wordTimingYRC != "" {
		st := parseYRCStats(ec.c.wordTimingYRC)
		lrcContent := 0
		for _, line := range strings.Split(ec.c.lyrics, "\n") {
			if !lrcTimestampRe.MatchString(line) {
				continue
			}
			text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
			if text == "" || isCreditLine(text) {
				continue
			}
			lrcContent++
		}
		den := lrcContent
		if den < 1 {
			den = 1
		}
		coverage := float64(st.realLines) / float64(den)
		if coverage > 1 {
			coverage = 1
		}
		// 自洽闸 (a): 全部词段 start 序列单调率<0.95 → 作废逐字加分资格
		if monotonicRatio(st.starts) < 0.95 {
			coverage = 0
		}
		// 自洽闸 (b) 修正版: 比较 YRC 最后一行 start 与 LRC 末句 start——同类量,
		// 无"唱完时刻 vs 行起点"的系统性正偏差(045 案:偏差=末行时长 15.18s 被误杀)。
		if coverage >= 0.7 && ec.hasLast {
			if math.Abs(float64(st.lastLineStartMs)/1000-ec.last) > 15 {
				coverage = 0
			}
		}
		switch {
		case coverage >= 0.7:
			newPts = 400
		case coverage >= 0.3:
			newPts = 250
		case coverage > 0:
			newPts = 100
		}
	}
	return newPts - old
}

// rank5 lrcStructureHealth: h1..h5 组合负项,封顶 −400。
func deltaLRCStructureHealth(tr *evalTrack, i int) int {
	ec := tr.cands[i]
	evs := lrcEventsOf(ec.c.lyrics)
	total := 0
	durMs := int(tr.dur * 1000)
	if tr.dur > 0 && len(evs) > 0 {
		// h1 首句异常
		if float64(evs[0].ms) > 0.40*float64(durMs) {
			total -= 200
		}
		// h2 覆盖跨度不足
		if len(evs) >= 2 && float64(evs[len(evs)-1].ms-evs[0].ms)/float64(durMs) < 0.40 {
			total -= 250
		}
		// h3 中段大空洞(排除首尾事件后的相邻最大间隔)
		if len(evs) >= 4 {
			interior := evs[1 : len(evs)-1]
			maxGap := 0
			for k := 1; k < len(interior); k++ {
				if g := interior[k].ms - interior[k-1].ms; g > maxGap {
					maxGap = g
				}
			}
			threshold := int(math.Max(60, 0.35*tr.dur) * 1000)
			if maxGap > threshold {
				total -= 150
			}
		}
	}
	// h4 垃圾轴(任意时长可判)
	if len(evs) > 0 {
		uniq := map[int]bool{}
		run, maxRun := 1, 1
		for k, e := range evs {
			uniq[e.ms] = true
			if k > 0 {
				if e.ms == evs[k-1].ms {
					run++
					if run > maxRun {
						maxRun = run
					}
				} else {
					run = 1
				}
			}
		}
		dupRatio := float64(len(evs)-len(uniq)) / float64(len(evs))
		if dupRatio > 0.30 || maxRun >= 4 {
			total -= 150
		}
	}
	// h5 重复退化(effLines>=12,rank9 口径)
	eff := effLineTexts(ec.c.lyrics)
	if len(eff) >= 12 {
		freq := map[string]int{}
		for _, l := range eff {
			freq[normLoose(l)]++
		}
		maxFreq := 0
		for _, n := range freq {
			if n > maxFreq {
				maxFreq = n
			}
		}
		uniqueRatio := float64(len(freq)) / float64(len(eff))
		if uniqueRatio < 0.25 || float64(maxFreq)/float64(len(eff)) > 0.5 {
			total -= 250
		}
	}
	if total < -400 {
		total = -400
	}
	return total
}

// rank7 artistIdentityAlignment: 歌手 credit 集合对齐,known 三元并集保护。
func deltaArtistIdentityAlignment(tr *evalTrack, i int) int {
	ec := tr.cands[i]
	fold := func(s string) string { return strings.ToLower(toSimplified(strings.TrimSpace(s))) }
	partsOf := func(folded string) map[string]bool {
		p := artistCreditParts(folded)
		if len(p) >= 2 {
			out := map[string]bool{}
			for _, x := range p {
				out[x] = true
			}
			return out
		}
		return map[string]bool{folded: true}
	}
	known := []string{fold(tr.artist)}
	if tr.canonicalArtist != "" {
		known = append(known, fold(tr.canonicalArtist))
	}
	if alias := knownArtistAlias(tr.artist); alias != "" {
		known = append(known, fold(alias))
	}
	L := map[string]bool{}
	for _, k := range known {
		if k == "" {
			continue
		}
		for p := range partsOf(k) {
			L[p] = true
		}
	}
	if strings.TrimSpace(ec.c.artist) == "" {
		return 0 // netease 多人合唱刻意留空,不可罚
	}
	C := partsOf(fold(ec.c.artist))
	// 集合相等
	if len(C) == len(L) {
		equal := true
		for p := range C {
			if !L[p] {
				equal = false
				break
			}
		}
		if equal {
			return 100
		}
	}
	if L[fold(firstCreditedArtist(ec.c.artist))] {
		return 60 // 主唱对上,feat 阵容不同
	}
	for p := range C {
		if L[p] {
			return 40 // 有交集
		}
	}
	for l := range L {
		for cp := range C {
			if looseContains(l, cp) {
				return 0 // 沾边但可疑(含仿冒号后缀形态):不奖不罚
			}
		}
	}
	return -250
}

// rank8 unverifiableVersionPenalty: 本地带版本限定词 × 候选零元数据 → −150。
func deltaUnverifiableVersionPenalty(tr *evalTrack, i int) int {
	ec := tr.cands[i]
	if len(versionTagsIn(tr.lt, tr.lal)) > 0 &&
		strings.TrimSpace(ec.c.title) == "" && strings.TrimSpace(ec.c.album) == "" {
		return -150
	}
	return 0
}

// rank9 effLineDensity: 行数项口径改 effLines(封顶 200 不变),另加每分钟行数区间罚。
// delta = (新行数分 − v2 行数分) + 密度罚。
func deltaEffLineDensity(tr *evalTrack, i int) int {
	ec := tr.cands[i]
	eff := effLineTexts(ec.c.lyrics)
	newLines := len(eff)
	if newLines > 200 {
		newLines = 200
	}
	delta := newLines - linesTermPoints(ec.v2Terms)
	if tr.dur > 0 {
		lpm := float64(len(eff)) / (tr.dur / 60.0)
		if lpm > 30 || (lpm < 2 && len(eff) >= 3) {
			delta -= 200
		}
	}
	return delta
}

// rank10 creditRatioPenalty: 署名行占比>0.15 起连续罚,封顶 −300。
func deltaCreditRatioPenalty(tr *evalTrack, i int) int {
	ec := tr.cands[i]
	timed, credit := 0, 0
	for _, line := range strings.Split(ec.c.lyrics, "\n") {
		if !lrcTimestampRe.MatchString(line) {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" {
			continue
		}
		timed++
		if isCreditLine(text) {
			credit++
		}
	}
	den := timed
	if den < 1 {
		den = 1
	}
	ratio := float64(credit) / float64(den)
	if ratio > 0.15 {
		p := int(1000 * (ratio - 0.15))
		if p > 300 {
			p = 300
		}
		return -p
	}
	return 0
}

// rank11 independentAlbumCorroboration: albumAffinity==0 且候选专辑非空时,池内(其它源
// 非空专辑候选)任一成员 albumScore>=100 → +50(命中即封顶;apple 半边样本无字段不测)。
func deltaIndependentAlbumCorroboration(tr *evalTrack, i int) int {
	ec := tr.cands[i]
	if strings.TrimSpace(ec.c.album) == "" {
		return 0
	}
	affinityZero := strings.TrimSpace(tr.lal) == "" || albumScore(ec.c.album, tr.lal) == 0
	if !affinityZero {
		return 0
	}
	for _, j := range tr.valid {
		p := tr.cands[j]
		if p == ec || p.c.source == ec.c.source || strings.TrimSpace(p.c.album) == "" {
			continue
		}
		if albumScore(ec.c.album, p.c.album) >= 100 {
			return 50
		}
	}
	return 0
}
