package main

import (
	"fmt"
	"maps"
	"math/rand"
	"os"
	"reflect"
	"regexp"
	"runtime"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// 排序层的新旧对拍:同一份各源原始应答,生产的 rankLyricSourceResults 和参照 handwrittenRankLyricSourceResults
// (lyricrankreference_test.go,迁移前的函数体原样)各排一遍,全部输出逐字段相等(候选及顺序、每个候选的全部字段、
// 分数与分项、搭车的纯音乐 / 有歌没词标记)。
//
// 输入语料三部分,全部离线、固定随机种子:
//   - 金标样本(testdata/lyricsgolden)各自的原始应答原样一组;
//   - 每个来源一组「每一栏都交了」的整形输入(rankParityShapeCases),逐栏核对参照读不读它(lyricSourceCandidateShapes);
//   - 金标样本的组合扰动(rankParityMutators):去掉源、互换与移植内容、只留逐行 / 纯文本、加减译文 / 读音 / 背景人声 /
//     作者、烘入译文、括号背景人声、纯音乐与无人声信号、本机身份、设置(译文语言、在放的播放器)。
//
// 排序层改一处就跑 `go test -tags devtools -run 'TestRank'`;大语料(四千多组,机器空闲时约一分钟)要设环境变量才跑:
// `LYRIC_RANK_PARITY_LARGE=1 go test -tags devtools -timeout 60m -run TestRankParityLargeCorpus -v`。

// rankParityCase 是一组输入:查询、各源原始应答、排序会读的包级设置。
type rankParityCase struct {
	name                 string
	artist, title, album string
	dur                  float64
	raw                  map[string]lyricSourceResult
	lang                 string // 译文语言
	player               string // 在放的播放器的 bundle id
	sources              map[string]bool
	hint                 string // 查询歌手的中文别名提示
	// focus:这组扰动多半落在它头上的那个来源,几种扰动叠在同一个源上才走得到组合分支。
	focus string
}

func applyRankParitySettings(c rankParityCase) {
	featuresRef().LyricsTranslationLanguage = c.lang
	featuresRef().LyricsSources = c.sources
	setNativeLyricSourcesForPlayer(c.player)
}

// saveRankParityState 登记还原:对拍会改译文语言、来源开关、在放的播放器、歌手别名缓存。
func saveRankParityState(t *testing.T) {
	t.Helper()
	savedFeatures := features()
	nativeLyricSourcesMu.Lock()
	savedNative, savedPlayer := nativeLyricSources, playingPlayerID
	nativeLyricSourcesMu.Unlock()
	artistAliasMu.Lock()
	savedAlias := maps.Clone(artistAliasCache)
	artistAliasMu.Unlock()
	t.Cleanup(func() {
		setFeatures(savedFeatures)
		nativeLyricSourcesMu.Lock()
		nativeLyricSources, playingPlayerID = savedNative, savedPlayer
		nativeLyricSourcesMu.Unlock()
		artistAliasMu.Lock()
		artistAliasCache = savedAlias
		artistAliasMu.Unlock()
	})
}

func cloneRankParityRaw(raw map[string]lyricSourceResult) map[string]lyricSourceResult {
	out := make(map[string]lyricSourceResult, len(raw))
	for k, r := range raw {
		r.trackIDs = slices.Clone(r.trackIDs)
		r.songwriters = slices.Clone(r.songwriters)
		r.amll.ncmIDs = slices.Clone(r.amll.ncmIDs)
		r.amll.qqIDs = slices.Clone(r.amll.qqIDs)
		r.amll.isrcs = slices.Clone(r.amll.isrcs)
		r.amll.songwriters = slices.Clone(r.amll.songwriters)
		out[k] = r
	}
	return out
}

// rankParityDiff:两份排序结果第一处不同在哪,相同返回空串。
func rankParityDiff(want, got []scoredLyricCandidateResult) string {
	if reflect.DeepEqual(want, got) {
		return ""
	}
	names := func(rs []scoredLyricCandidateResult) []string {
		out := make([]string, len(rs))
		for i, r := range rs {
			out[i] = fmt.Sprintf("%s(%d)", r.Source, r.Score)
		}
		return out
	}
	if len(want) != len(got) {
		return fmt.Sprintf("条数 参照 %v\n         生产 %v", names(want), names(got))
	}
	for i := range want {
		if reflect.DeepEqual(want[i], got[i]) {
			continue
		}
		w, g := reflect.ValueOf(want[i]), reflect.ValueOf(got[i])
		for f := 0; f < w.NumField(); f++ {
			name := w.Type().Field(f).Name
			if !w.Type().Field(f).IsExported() {
				if !reflect.DeepEqual(want[i].unmasked, got[i].unmasked) {
					return fmt.Sprintf("第 %d 条(%s)的 %s 不同", i, want[i].Source, name)
				}
				continue
			}
			if !reflect.DeepEqual(w.Field(f).Interface(), g.Field(f).Interface()) {
				return fmt.Sprintf("第 %d 条(参照 %s / 生产 %s)的 %s\n  参照 %.300q\n  生产 %.300q\n  顺序 参照 %v\n       生产 %v",
					i, want[i].Source, got[i].Source, name, fmt.Sprint(w.Field(f).Interface()), fmt.Sprint(g.Field(f).Interface()), names(want), names(got))
			}
		}
	}
	return "DeepEqual 不等,逐栏却找不到差别(nil 与空切片?)"
}

// rankParityTally 按来源数参照输出里各种装配结果出现了几次,证明语料走到了每个源那段装配的每个分支。
type rankParityTally struct {
	mu     sync.Mutex
	counts map[string]int
}

func (ta *rankParityTally) add(source, what string) {
	ta.mu.Lock()
	ta.counts[source+"/"+what]++
	ta.mu.Unlock()
}

func (ta *rankParityTally) note(c rankParityCase, out []scoredLyricCandidateResult) {
	for i, r := range out {
		src := r.Source
		switch {
		case r.Instrumental && r.PlayerInstrumental:
			ta.add(src, "播放器纯音乐标记")
			continue
		case r.Instrumental:
			ta.add(src, "纯音乐标记")
			continue
		case r.TrackFoundNoLyrics:
			ta.add(src, "有歌没词标记")
			continue
		}
		in := rankParityContentOf(src, c.raw[src])
		ta.add(src, "候选")
		if r.Score >= 0 {
			ta.add(src, "过闸")
			if i+1 < len(out) && out[i+1].Score == r.Score {
				ta.add(src, "同分领先")
			}
			if i > 0 && out[i-1].Score == r.Score {
				ta.add(src, "同分落后")
			}
		}
		mark := func(has, offered bool, yes, no string) {
			if has {
				ta.add(src, yes)
			} else if offered {
				ta.add(src, no)
			}
		}
		mark(r.HasWordTiming, in.yrc != "", "逐字", "逐字没进候选")
		mark(r.LyricsTr != "" && r.LyricsTrFrom == "", in.tr != "", "译文", "译文没进结果")
		if r.LyricsTr != "" && r.LyricsTrFrom == "" {
			ta.add(src, "译文语言="+r.LyricsTrLang)
		}
		mark(r.LyricsRoma != "", in.roma != "", "读音", "读音没进结果")
		mark(r.PlainTextOnly, c.raw[src].plainOnly, "纯文本", "纯文本标记没进候选")
		mark(r.BakedTranslationLines > 0, false, "烘入译文", "")
		offeredBG := c.raw[src].bg
		if src == lyricSourceAMLL {
			offeredBG = c.raw[src].amll.bg
		}
		mark(offeredBG != "" && r.LyricsBG == offeredBG, offeredBG != "", "背景人声", "背景人声没进结果")
		mark(r.LyricsBG != "" && r.LyricsBG != offeredBG, false, "括号背景人声", "")
		mark(len(r.Songwriters) > 0, len(c.raw[src].songwriters) > 0 || len(c.raw[src].amll.songwriters) > 0, "作者", "作者没进结果")
		mark(r.ISRC != "", c.raw[src].isrc != "", "ISRC", "ISRC没进候选")
		mark(r.SourceURL != "", c.raw[src].sourceURL != "" || c.raw[src].amll.pageURL != "", "来源链接", "来源链接没进候选")
		mark(r.Language != "", c.raw[src].language != "", "语种", "语种没进候选")
		mark(r.IdentityFromLocalClient, c.raw[src].identityFromLocalClient || c.raw[src].ne.FromLocalClient, "本机身份", "本机身份没进候选")
		mark(r.Album != "", in.album != "", "专辑", "专辑没进候选")
		mark(r.CoverURL != "", in.cover != "", "封面", "封面没进候选")
		mark(r.SourceReportedDurationSecs != 0, in.dur != 0, "自报曲长", "自报曲长没进候选")
		mark(r.BorrowedDurationFrom != "", false, "借曲长", "")
	}
}

func (ta *rankParityTally) report() string {
	keys := make([]string, 0, len(ta.counts))
	for k := range ta.counts {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		fmt.Fprintf(&b, "%s=%d\n", k, ta.counts[k])
	}
	return b.String()
}

// runRankParity 把用例按设置(译文语言、在放的播放器、来源开关)分批,同一批并发排;每个用例参照、生产各排一遍,比全部输出。
// twice 为真时参照多排一遍,核对它自己前后一致(排序里要是有依赖 map 遍历顺序的地方,对拍没法逐字段比)。
func runRankParity(t *testing.T, cases []rankParityCase, twice bool) *rankParityTally {
	t.Helper()
	saveRankParityState(t)
	tally := &rankParityTally{counts: map[string]int{}}
	type batchKey struct{ lang, player, sources string }
	batches := map[batchKey][]rankParityCase{}
	var order []batchKey
	artistAliasMu.Lock()
	if artistAliasCache == nil {
		artistAliasCache = map[string]string{}
	}
	for _, c := range cases {
		if c.hint != "" {
			artistAliasCache[c.artist] = c.hint
		}
	}
	artistAliasMu.Unlock()
	for _, c := range cases {
		k := batchKey{c.lang, c.player, fmt.Sprint(c.sources)}
		if _, ok := batches[k]; !ok {
			order = append(order, k)
		}
		batches[k] = append(batches[k], c)
	}
	var failures []string
	var mu sync.Mutex
	fail := func(format string, args ...any) {
		mu.Lock()
		failures = append(failures, fmt.Sprintf(format, args...))
		mu.Unlock()
	}
	for _, k := range order {
		batch := batches[k]
		applyRankParitySettings(batch[0])
		work := make(chan rankParityCase)
		var wg sync.WaitGroup
		for w := 0; w < runtime.GOMAXPROCS(0); w++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for c := range work {
					input := cloneRankParityRaw(c.raw)
					want := handwrittenRankLyricSourceResults(c.artist, c.title, c.album, c.dur, cloneRankParityRaw(c.raw))
					if twice {
						again := handwrittenRankLyricSourceResults(c.artist, c.title, c.album, c.dur, cloneRankParityRaw(c.raw))
						if d := rankParityDiff(want, again); d != "" {
							fail("%s:参照自己两遍不一致(排序依赖了不确定的顺序?)\n%s", c.name, d)
							continue
						}
					}
					got := rankLyricSourceResults(c.artist, c.title, c.album, c.dur, c.raw)
					if d := rankParityDiff(want, got); d != "" {
						fail("%s\n%s", c.name, d)
					}
					if !reflect.DeepEqual(input, c.raw) {
						fail("%s:排序改了调用方的原始应答", c.name)
					}
					tally.note(c, want)
				}
			}()
		}
		for _, c := range batch {
			work <- c
		}
		close(work)
		wg.Wait()
	}
	sort.Strings(failures)
	for i, f := range failures {
		if i == 8 {
			t.Errorf("……另有 %d 组不一致", len(failures)-i)
			break
		}
		t.Errorf("%s", f)
	}
	return tally
}

// ---------- 语料 ----------

// rankParityContent 是一个源交的正文那一组,三种摆法(公共字段、网易云的 ne、AMLL 的 amll)收成一种。
type rankParityContent struct {
	lyr, yrc, tr, roma          string
	title, artist, album, cover string
	dur                         float64
}

func rankParityContentOf(source string, r lyricSourceResult) rankParityContent {
	switch source {
	case lyricSourceNetease:
		lyr := r.ne.Lyrics
		if lyr == "" {
			lyr = r.ne.PlainLyrics
		}
		return rankParityContent{lyr, r.ne.YRC, r.ne.Trans, r.ne.Roma, r.ne.Title, r.ne.Artist, r.ne.Album, r.ne.Cover, r.ne.DurationSecs}
	case lyricSourceAMLL:
		return rankParityContent{r.amll.lrc, r.amll.yrc, r.amll.tr, r.amll.roma, r.amll.matchTitle, r.amll.matchArtist, r.amll.matchAlbum, "", 0}
	}
	return rankParityContent{r.lyr, r.yrc, r.tr, r.roma, r.matchTitle, r.matchArtist, r.matchAlbum, r.matchCover, r.srcDur}
}

func setRankParityContent(source string, r *lyricSourceResult, c rankParityContent) {
	switch source {
	case lyricSourceNetease:
		r.ne.Lyrics, r.ne.YRC, r.ne.Trans, r.ne.Roma = c.lyr, c.yrc, c.tr, c.roma
		r.ne.Title, r.ne.Artist, r.ne.Album, r.ne.Cover, r.ne.DurationSecs = c.title, c.artist, c.album, c.cover, c.dur
		r.ne.PlainLyrics = ""
	case lyricSourceAMLL:
		r.amll.lrc, r.amll.yrc, r.amll.tr, r.amll.roma = c.lyr, c.yrc, c.tr, c.roma
		r.amll.matchTitle, r.amll.matchArtist, r.amll.matchAlbum = c.title, c.artist, c.album
	default:
		r.lyr, r.yrc, r.tr, r.roma = c.lyr, c.yrc, c.tr, c.roma
		r.matchTitle, r.matchArtist, r.matchAlbum, r.matchCover, r.srcDur = c.title, c.artist, c.album, c.cover, c.dur
	}
}

var rankParityStampRe = regexp.MustCompile(`^((?:\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\])+)(.*)$`)

// rankParityLines:LRC 里带时间戳、有字的行,拆成(时间戳原文,文字)。
func rankParityLines(lrc string) (stamps, texts []string) {
	for _, line := range strings.Split(lrc, "\n") {
		m := rankParityStampRe.FindStringSubmatch(strings.TrimRight(line, "\r"))
		if m == nil || strings.TrimSpace(m[2]) == "" {
			continue
		}
		stamps, texts = append(stamps, m[1]), append(texts, strings.TrimSpace(m[2]))
	}
	return
}

const rankParityHan = "风花雪月山川湖海晨昏昼夜星云雨露春夏秋冬远近高低来去聚散悲欢离合光影声色梦醒心念"

// rankParityHanLine:第 i 行的一句纯汉字,各行不同。
func rankParityHanLine(i int) string {
	pool := []rune(rankParityHan)
	var b strings.Builder
	for k := 0; k < 5+i%4; k++ {
		b.WriteRune(pool[(i*7+k*3)%len(pool)])
	}
	return b.String()
}

// rankParityAux 照正文的时间戳造一份附属歌词:kind 是 zh(汉字)、ko(谚文)、latin(拉丁字母)。keep 是留下的行的比例。
func rankParityAux(lrc, kind string, keep float64) string {
	stamps, _ := rankParityLines(lrc)
	n := int(float64(len(stamps)) * keep)
	var out []string
	for i, s := range stamps[:n] {
		switch kind {
		case "zh":
			out = append(out, s+rankParityHanLine(i))
		case "ko":
			out = append(out, s+"번역된 가사 "+strings.Repeat("줄", 1+i%3))
		default:
			out = append(out, s+"ro ma ji "+strconv.Itoa(i)+" yomi kata")
		}
	}
	return strings.Join(out, "\n")
}

func rankParityShiftStamp(stamp string, deltaMs int) string {
	m := lrcTimestampCaptureRe.FindStringSubmatch(stamp)
	if m == nil {
		return stamp
	}
	mm, _ := strconv.Atoi(m[1])
	ss, _ := strconv.Atoi(m[2])
	frac, _ := strconv.Atoi(m[3])
	switch len(m[3]) {
	case 1:
		frac *= 100
	case 2:
		frac *= 10
	}
	return lrcTimestamp(mm*60000 + ss*1000 + frac + deltaMs)
}

// rankParityBake 把逐句的中文译文烘进正文。style:same = 译文行跟原文同一个时间戳;later = 晚 1.5 秒的独立时间戳;
// next = 挂在下一句原文的时间戳上(酷我的烘法)。
func rankParityBake(lrc, style string) string {
	stamps, texts := rankParityLines(lrc)
	var out []string
	for i := range stamps {
		out = append(out, stamps[i]+texts[i])
		switch style {
		case "same":
			out = append(out, stamps[i]+rankParityHanLine(i))
		case "later":
			out = append(out, rankParityShiftStamp(stamps[i], 1500)+rankParityHanLine(i))
		case "next":
			if i+1 < len(stamps) {
				out = append(out, stamps[i+1]+rankParityHanLine(i))
			}
		}
	}
	return strings.Join(out, "\n")
}

func rankParityPlain(lrc string) string {
	_, texts := rankParityLines(lrc)
	return strings.Join(texts, "\n")
}

func rankParityShift(lrc string, deltaMs int) string {
	stamps, texts := rankParityLines(lrc)
	out := make([]string, len(stamps))
	for i := range stamps {
		out[i] = rankParityShiftStamp(stamps[i], deltaMs) + texts[i]
	}
	return strings.Join(out, "\n")
}

// rankParitySong 造一首整行与逐字对得上的歌:每行 4 秒。
func rankParitySong(lines []string) (lrc, yrc string) {
	var l, y []string
	for i, text := range lines {
		ms := 2000 + 4000*i
		l = append(l, lrcTimestamp(ms)+text)
		y = append(y, yrcLine(ms, text))
	}
	return strings.Join(l, "\n"), strings.Join(y, "\n")
}

var (
	rankParityJapanese = []string{
		"きみのこえが きこえる", "よるのまちを あるいて", "ほしをかぞえて ねむる", "あさがくれば わらう", "かぜにのって とんで",
		"うみのむこう までも", "ゆめをみてた ずっと", "なみだのあと かわく", "はなびらが まいおちる", "ひかりのなか はしる",
		"とおいそらを みあげて", "こころのおく ひびく",
	}
	rankParityEnglish = []string{
		"Kills me slowly (slowly)", "No parens in this one", "Pray it away (away)", "Walking down the empty road", "Counting every single star",
		"Morning comes and I am gone (gone)", "Dreaming of another day", "Tears are drying on my face", "Petals falling to the ground",
		"Running through the light (the light)", "Looking at the distant sky", "Echoes deep inside my heart",
	}
	rankParityKorean = []string{
		"너의 목소리가 들려", "밤거리를 걸어가", "별을 세며 잠들어", "아침이 오면 웃어", "바람을 타고 날아",
		"바다 건너 저편까지", "꿈을 꾸고 있었어", "눈물 자국이 말라", "꽃잎이 흩날려", "빛 속을 달려가",
	}
)

const (
	rankParityBG       = "[2000,800](2100,300,0)ooh (2400,300,0)yeah\n[10000,800](10100,300,0)la (10400,300,0)la"
	rankParityCredit   = "[00:00.00]作词 : 某人\n[00:01.00]作曲 : 某人\n[00:02.00]编曲 : 某人"
	rankParityNoLyrics = "[00:00.00]此歌曲为没有填词的纯音乐，请您欣赏"
)

// rankParityLangs / rankParityPlayers:扰动设置时抽的译文语言、在放的播放器。
var (
	rankParityLangs   = []string{"zh", "zh-Hans", "zh-Hant", "en", "ja", "ko", ""}
	rankParityPlayers = []string{"", playerNetease, playerQQMusic, playerKugou, playerKuwo, playerAppleMusic, playerSoda,
		playerSpotify, playerKKBOX, playerAmazonMusic, playerLXMusic, playerReamp, playerKaset}
)

// rankParityMutator 是一种扰动:改一组输入,返回一句说明(进用例名)。
type rankParityMutator struct {
	name string
	// weight:抽中的相对机会。
	weight int
	apply  func(rng *rand.Rand, c *rankParityCase) string
}

func rankParityPick(rng *rand.Rand, names []string) string { return names[rng.Intn(len(names))] }

// rankParityTarget:这一下扰动落在哪个来源上,六成是这组的 focus。
func rankParityTarget(rng *rand.Rand, c *rankParityCase) string {
	if c.focus != "" && rng.Intn(10) < 6 {
		return c.focus
	}
	return rankParityPick(rng, lyricCandidateTieOrder)
}

// rankParityPresent:这组输入里交了正文的来源,按决胜序。
func rankParityPresent(c *rankParityCase) []string {
	var out []string
	for _, s := range lyricCandidateTieOrder {
		if r, ok := c.raw[s]; ok && rankParityContentOf(s, r).lyr != "" {
			out = append(out, s)
		}
	}
	return out
}

func rankParityEdit(c *rankParityCase, source string, edit func(r *lyricSourceResult)) {
	r := c.raw[source]
	r.source = source
	edit(&r)
	c.raw[source] = r
}

// rankParityEditContent 改一个源的正文那一组;这个源没交正文时什么都不做,返回 false。
func rankParityEditContent(c *rankParityCase, source string, edit func(ct *rankParityContent)) bool {
	ct := rankParityContentOf(source, c.raw[source])
	if ct.lyr == "" {
		return false
	}
	edit(&ct)
	rankParityEdit(c, source, func(r *lyricSourceResult) {
		plain := source == lyricSourceNetease && r.ne.Lyrics == ""
		setRankParityContent(source, r, ct)
		if plain {
			r.ne.Lyrics, r.ne.PlainLyrics = "", ct.lyr
		}
	})
	return true
}

// rankParityFlags 把一种「这个源说了什么」的信号按来源放到它该在的栏上(网易云的在 ne 上)。
func rankParitySetLocal(r *lyricSourceResult, source string) {
	if source == lyricSourceNetease {
		r.ne.FromLocalClient = true
		return
	}
	r.identityFromLocalClient = true
}

func rankParitySetNoVocals(r *lyricSourceResult, source string) {
	if source == lyricSourceNetease {
		r.ne.NoVocals = true
		return
	}
	r.noVocals = true
}

func rankParitySetInstrumental(r *lyricSourceResult, source string) {
	if source == lyricSourceNetease {
		r.ne.PureMusic = true
		return
	}
	r.instrumental = true
}

var rankParityMutators = []rankParityMutator{
	{"去掉", 3, func(rng *rand.Rand, c *rankParityCase) string {
		present := rankParityPresent(c)
		if len(present) == 0 {
			return ""
		}
		s := rankParityPick(rng, present)
		delete(c.raw, s)
		return "去掉 " + s
	}},
	{"移植", 10, func(rng *rand.Rand, c *rankParityCase) string {
		present := rankParityPresent(c)
		if len(present) == 0 {
			return ""
		}
		from, to := rankParityPick(rng, present), rankParityTarget(rng, c)
		ct := rankParityContentOf(from, c.raw[from])
		rankParityEdit(c, to, func(r *lyricSourceResult) { setRankParityContent(to, r, ct) })
		return from + " 的内容给 " + to
	}},
	{"互换", 4, func(rng *rand.Rand, c *rankParityCase) string {
		present := rankParityPresent(c)
		if len(present) < 2 {
			return ""
		}
		a, b := rankParityPick(rng, present), rankParityPick(rng, present)
		ca, cb := rankParityContentOf(a, c.raw[a]), rankParityContentOf(b, c.raw[b])
		rankParityEdit(c, a, func(r *lyricSourceResult) { setRankParityContent(a, r, cb) })
		rankParityEdit(c, b, func(r *lyricSourceResult) { setRankParityContent(b, r, ca) })
		return a + " 与 " + b + " 互换"
	}},
	{"整份搬到别的源名下", 4, func(rng *rand.Rand, c *rankParityCase) string {
		// 公共字段、ne、amll 三块连同各种标记一起搬:目的地不读的栏也带着,核对它确实不读。
		present := rankParityPresent(c)
		if len(present) == 0 {
			return ""
		}
		from, to := rankParityPick(rng, present), rankParityTarget(rng, c)
		r := c.raw[from]
		ct := rankParityContentOf(from, r)
		r.source = to
		setRankParityContent(to, &r, ct)
		c.raw[to] = r
		return from + " 整份搬给 " + to
	}},
	{"只留逐行", 3, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		if !rankParityEditContent(c, s, func(ct *rankParityContent) { ct.yrc = "" }) {
			return ""
		}
		return s + " 只留逐行"
	}},
	{"逐字残缺", 2, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		if !rankParityEditContent(c, s, func(ct *rankParityContent) {
			lines := strings.Split(ct.yrc, "\n")
			ct.yrc = strings.Join(lines[:len(lines)/4], "\n")
		}) {
			return ""
		}
		return s + " 逐字只剩前四分之一"
	}},
	{"只留纯文本", 3, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		ct := rankParityContentOf(s, c.raw[s])
		if ct.lyr == "" {
			return ""
		}
		rankParityEdit(c, s, func(r *lyricSourceResult) {
			switch s {
			case lyricSourceNetease:
				r.ne.Lyrics, r.ne.YRC, r.ne.PlainLyrics = "", "", rankParityPlain(ct.lyr)
			case lyricSourceAMLL:
				r.amll.lrc, r.amll.yrc = rankParityPlain(ct.lyr), ""
			default:
				r.lyr, r.yrc, r.plainOnly = rankParityPlain(ct.lyr), "", true
			}
		})
		return s + " 只留纯文本"
	}},
	{"纯文本标记", 2, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		rankParityEdit(c, s, func(r *lyricSourceResult) { r.plainOnly = !r.plainOnly })
		return s + " 翻转纯文本标记"
	}},
	{"加译文", 8, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		kind := rankParityPick(rng, []string{"zh", "zh", "zh", "ko", "latin"})
		keep := []float64{1, 1, 1, 0.3}[rng.Intn(4)]
		lang := rankParityPick(rng, []string{"", "", "zh", "zh-Hans", "zh-Hant", "ja", "en", "ko"})
		if !rankParityEditContent(c, s, func(ct *rankParityContent) { ct.tr = rankParityAux(ct.lyr, kind, keep) }) {
			return ""
		}
		rankParityEdit(c, s, func(r *lyricSourceResult) { r.trLang, r.amll.trLang = lang, lang })
		return fmt.Sprintf("%s 加 %s 译文(留 %.1f,标 %q)", s, kind, keep, lang)
	}},
	{"去译文", 2, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		if !rankParityEditContent(c, s, func(ct *rankParityContent) { ct.tr = "" }) {
			return ""
		}
		return s + " 去译文"
	}},
	{"译文不带时间戳", 1, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		if !rankParityEditContent(c, s, func(ct *rankParityContent) { ct.tr = rankParityPlain(rankParityAux(ct.lyr, "zh", 1)) }) {
			return ""
		}
		return s + " 译文不带时间戳"
	}},
	{"加读音", 6, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		kind := rankParityPick(rng, []string{"latin", "latin", "latin", "zh"})
		if !rankParityEditContent(c, s, func(ct *rankParityContent) { ct.roma = rankParityAux(ct.lyr, kind, 1) }) {
			return ""
		}
		return s + " 加 " + kind + " 读音"
	}},
	{"去读音", 1, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		if !rankParityEditContent(c, s, func(ct *rankParityContent) { ct.roma = "" }) {
			return ""
		}
		return s + " 去读音"
	}},
	{"烘入译文", 6, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		style := rankParityPick(rng, []string{"same", "later", "next"})
		dropYRC := rng.Intn(2) == 0
		if !rankParityEditContent(c, s, func(ct *rankParityContent) {
			ct.lyr = rankParityBake(ct.lyr, style)
			if dropYRC {
				ct.yrc = ""
			}
		}) {
			return ""
		}
		return fmt.Sprintf("%s 烘入译文(%s,去逐字=%v)", s, style, dropYRC)
	}},
	{"中文歌夹一段带译文的外文", 3, func(rng *rand.Rand, c *rankParityCase) string {
		// 中文歌中间五句外文,每句的中文译文挂在下一句的时间戳上(酷我的烘法)。整首不算外文歌,打分那道「译文可用」不认。
		s := lyricSourceKuwo
		if rng.Intn(3) == 0 {
			s = rankParityTarget(rng, c)
		}
		var lines []string
		ms := 2000
		add := func(text string, step int) {
			lines = append(lines, lrcTimestamp(ms)+text)
			ms += step
		}
		for i := 0; i < 3; i++ {
			add(rankParityHanLine(i), 4000)
		}
		for i := 0; i < 5; i++ {
			add("placeholder foreign line number "+strconv.Itoa(i), 4000)
			add(rankParityHanLine(10+i), 0)
		}
		for i := 3; i < 6; i++ {
			add(rankParityHanLine(i), 4000)
		}
		ct := rankParityContent{lyr: strings.Join(lines, "\n"), title: c.title, artist: c.artist, album: c.album, dur: c.dur}
		rankParityEdit(c, s, func(r *lyricSourceResult) { setRankParityContent(s, r, ct) })
		return s + " 中文歌夹一段带译文的外文"
	}},
	{"换成造的歌", 8, func(rng *rand.Rand, c *rankParityCase) string {
		// 整首换成整行与逐字对得上的造的歌:日文(读音可用)、带括号背景人声的英文、韩文。歌名歌手照查询填,过得了身份闸。
		s := rankParityTarget(rng, c)
		which := rng.Intn(3)
		lines := [][]string{rankParityJapanese, rankParityEnglish, rankParityKorean}[which]
		lrc, yrc := rankParitySong(lines)
		ct := rankParityContent{lyr: lrc, yrc: yrc, title: c.title, artist: c.artist, album: c.album, cover: "https://example.com/" + s + ".jpg", dur: c.dur}
		rankParityEdit(c, s, func(r *lyricSourceResult) { setRankParityContent(s, r, ct) })
		return s + " 换成造的歌 " + []string{"日文", "英文带括号", "韩文"}[which]
	}},
	{"时间轴平移", 3, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		delta := []int{-3000, 2500, 6000}[rng.Intn(3)]
		if !rankParityEditContent(c, s, func(ct *rankParityContent) { ct.lyr, ct.yrc = rankParityShift(ct.lyr, delta), "" }) {
			return ""
		}
		return fmt.Sprintf("%s 时间轴平移 %d 毫秒", s, delta)
	}},
	{"整行轴偏离逐字", 4, func(rng *rand.Rand, c *rankParityCase) string {
		// 日文歌,整行、译文、读音的时间戳一起比逐字晚 0.3 秒:整行会按逐字重挂,译文、读音跟着搬。
		s := rankParityTarget(rng, c)
		lrc, yrc := rankParitySong(rankParityJapanese)
		late := rankParityShift(lrc, 300)
		ct := rankParityContent{lyr: late, yrc: yrc, tr: rankParityAux(late, "zh", 1), roma: rankParityAux(late, "latin", 1),
			title: c.title, artist: c.artist, album: c.album, dur: c.dur}
		rankParityEdit(c, s, func(r *lyricSourceResult) { setRankParityContent(s, r, ct) })
		return s + " 日文歌整行晚于逐字"
	}},
	{"手打时间轴整体晚", 3, func(rng *rand.Rand, c *rankParityCase) string {
		// 一个源拿别家的整行正文、时间轴整体晚 8 秒(Megalobiz 的手打时间轴会这样)。
		present := rankParityPresent(c)
		if len(present) == 0 {
			return ""
		}
		from, to := rankParityPick(rng, present), lyricSourceMegalobiz
		if rng.Intn(3) == 0 {
			to = rankParityTarget(rng, c)
		}
		ct := rankParityContentOf(from, c.raw[from])
		ct.lyr, ct.yrc, ct.tr, ct.roma = rankParityShift(ct.lyr, 8000), "", "", ""
		ct.title, ct.artist, ct.dur = c.title, c.artist, c.dur+2
		rankParityEdit(c, to, func(r *lyricSourceResult) { setRankParityContent(to, r, ct) })
		return to + " 拿 " + from + " 的正文、整体晚 8 秒"
	}},
	{"背景人声轨", 5, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		rankParityEdit(c, s, func(r *lyricSourceResult) { r.bg, r.amll.bg = rankParityBG, rankParityBG })
		return s + " 带背景人声轨"
	}},
	{"作者", 5, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		rankParityEdit(c, s, func(r *lyricSourceResult) {
			r.songwriters, r.amll.songwriters = []string{"Writer A", "作者乙"}, []string{"Writer A", "作者乙"}
		})
		return s + " 带作者"
	}},
	{"ISRC 与链接与语种", 5, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		rankParityEdit(c, s, func(r *lyricSourceResult) {
			r.isrc, r.sourceURL = "USUM71703861", "https://www.megalobiz.com/lrc/maker/x.1"
			r.language = rankParityPick(rng, []string{songLanguageMandarin, songLanguageCantonese})
			r.trackIDs = []string{"0039MnYb0qxYhV", "97773"}
			r.amll.pageURL = "https://github.com/amll-dev/amll-ttml-db/blob/main/raw-lyrics/1.ttml"
			r.amll.isrcs, r.amll.qqIDs = []string{"USUM71703861"}, []string{"97773"}
			if ne := c.raw[lyricSourceNetease].ne; ne.SongID > 0 {
				r.amll.ncmIDs = []string{strconv.FormatInt(ne.SongID, 10)}
			}
			r.amll.platform = rankParityPick(rng, []string{"", "ncm-lyrics", "qq-lyrics", "am-lyrics", "spotify-lyrics"})
		})
		return s + " 带 ISRC、链接、语种、曲目编号"
	}},
	{"各栏都交", 6, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		rankParityEdit(c, s, func(r *lyricSourceResult) {
			r.bg, r.songwriters, r.isrc, r.sourceURL = rankParityBG, []string{"Writer A"}, "USUM71703861", "https://www.megalobiz.com/lrc/maker/x.1"
			r.language, r.trackIDs = songLanguageMandarin, []string{"97773"}
			r.amll.bg, r.amll.songwriters, r.amll.pageURL = rankParityBG, []string{"Writer A"}, "https://github.com/amll-dev/amll-ttml-db/blob/main/raw-lyrics/1.ttml"
			rankParitySetLocal(r, s)
		})
		return s + " 各栏都交"
	}},
	{"播放器说没有人声", 4, func(rng *rand.Rand, c *rankParityCase) string {
		// 在放的播放器自家的源说这一条没有人声:身份来自本机、解析的是在放的这首,自己交没交词各半。
		owners := map[string]string{
			lyricSourceNetease: playerNetease, lyricSourceQQ: playerQQMusic, lyricSourceSoda: playerSoda,
			lyricSourceAppleMusic: playerAppleMusic, spotifyLocalLyricsSource: playerSpotify,
		}
		s := rankParityPick(rng, []string{lyricSourceNetease, lyricSourceQQ, lyricSourceSoda, lyricSourceAppleMusic, spotifyLocalLyricsSource})
		c.player = playerBundleIDs[owners[s]]
		empty := rng.Intn(2) == 0
		for name, r := range c.raw {
			r.forPlayingTrack = true
			c.raw[name] = r
		}
		rankParityEdit(c, s, func(r *lyricSourceResult) {
			r.forPlayingTrack = true
			rankParitySetNoVocals(r, s)
			rankParitySetLocal(r, s)
			if empty {
				setRankParityContent(s, r, rankParityContent{title: c.title, artist: c.artist, album: c.album, dur: c.dur})
			}
		})
		return fmt.Sprintf("%s 在放、它说这一条没有人声(清空正文=%v)", owners[s], empty)
	}},
	{"本机身份", 6, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		rankParityEdit(c, s, func(r *lyricSourceResult) { rankParitySetLocal(r, s) })
		return s + " 本机身份"
	}},
	{"无人声", 5, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		local := rng.Intn(2) == 0
		rankParityEdit(c, s, func(r *lyricSourceResult) {
			rankParitySetNoVocals(r, s)
			if local {
				rankParitySetLocal(r, s)
			}
		})
		return fmt.Sprintf("%s 说没有人声(本机身份=%v)", s, local)
	}},
	{"纯音乐", 5, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		empty := rng.Intn(3) > 0
		rankParityEdit(c, s, func(r *lyricSourceResult) {
			rankParitySetInstrumental(r, s)
			if empty {
				setRankParityContent(s, r, rankParityContent{title: c.title, artist: c.artist, album: c.album, dur: c.dur})
			}
		})
		return fmt.Sprintf("%s 说是纯音乐(清空正文=%v)", s, empty)
	}},
	{"只有署名行", 4, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		rankParityEdit(c, s, func(r *lyricSourceResult) {
			setRankParityContent(s, r, rankParityContent{lyr: rankParityCredit, title: c.title, artist: c.artist, album: c.album, dur: c.dur})
			if rng.Intn(3) > 0 {
				rankParitySetNoVocals(r, s)
			}
		})
		return s + " 正文只有署名行"
	}},
	{"纯音乐占位句", 4, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		rankParityEdit(c, s, func(r *lyricSourceResult) {
			setRankParityContent(s, r, rankParityContent{lyr: rankParityNoLyrics, title: c.title, artist: c.artist, album: c.album, dur: c.dur})
		})
		return s + " 正文是纯音乐占位句"
	}},
	{"有歌没词", 3, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		rankParityEdit(c, s, func(r *lyricSourceResult) {
			setRankParityContent(s, r, rankParityContent{title: c.title, artist: c.artist, album: c.album, dur: c.dur})
			r.trackFoundNoLyrics, r.ne.TrackFoundNoLyrics = true, s == lyricSourceNetease
		})
		return s + " 有歌没词"
	}},
	{"在放的这首", 6, func(rng *rand.Rand, c *rankParityCase) string {
		for s, r := range c.raw {
			r.forPlayingTrack = true
			c.raw[s] = r
		}
		return "解析的是在放的这首"
	}},
	{"改歌名歌手专辑时长", 4, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		what := rng.Intn(5)
		if !rankParityEditContent(c, s, func(ct *rankParityContent) {
			switch what {
			case 0:
				ct.title += " (Live)"
			case 1:
				ct.artist = "Somebody Else"
			case 2:
				ct.album, ct.cover = "", ""
			case 3:
				ct.dur = 0
			case 4:
				ct.dur += 9
			}
		}) {
			return ""
		}
		return s + " 改" + []string{"歌名", "歌手", "专辑封面", "去时长", "时长"}[what]
	}},
	{"字符实体", 1, func(rng *rand.Rand, c *rankParityCase) string {
		s := rankParityTarget(rng, c)
		if !rankParityEditContent(c, s, func(ct *rankParityContent) { ct.lyr = strings.ReplaceAll(ct.lyr, "'", "&apos;") }) {
			return ""
		}
		return s + " 正文带字符实体"
	}},
	{"无关的栏", 3, func(rng *rand.Rand, c *rankParityCase) string {
		// 往一个源不读的那几块里塞正文:公共字段的源塞 ne 与 amll,网易云、AMLL 塞公共字段。排序不该读到。
		present := rankParityPresent(c)
		if len(present) == 0 {
			return ""
		}
		from, to := rankParityPick(rng, present), rankParityTarget(rng, c)
		ct := rankParityContentOf(from, c.raw[from])
		rankParityEdit(c, to, func(r *lyricSourceResult) {
			if to != lyricSourceNetease {
				r.ne.Lyrics, r.ne.YRC, r.ne.Trans, r.ne.Roma, r.ne.PlainLyrics = ct.lyr, ct.yrc, ct.tr, ct.roma, ct.lyr
			}
			if to != lyricSourceAMLL {
				r.amll.lrc, r.amll.yrc, r.amll.tr, r.amll.roma = ct.lyr, ct.yrc, ct.tr, ct.roma
			}
			if to == lyricSourceNetease || to == lyricSourceAMLL {
				r.lyr, r.yrc, r.tr, r.roma, r.matchTitle, r.matchArtist = ct.lyr, ct.yrc, ct.tr, ct.roma, ct.title, ct.artist
			}
		})
		return to + " 不读的栏里塞了 " + from + " 的正文"
	}},
	{"外文查询", 3, func(rng *rand.Rand, c *rankParityCase) string {
		// 查询换成不含汉字的写法(烘入译文认「外文歌」的前提),各源报的歌名歌手跟着换,过得了身份闸。
		old := *c
		c.artist, c.title = "Some Artist", "Some Title"
		for _, s := range lyricCandidateTieOrder {
			if _, ok := c.raw[s]; !ok {
				continue
			}
			rankParityEdit(c, s, func(r *lyricSourceResult) {
				ct := rankParityContentOf(s, *r)
				if ct.title == old.title || ct.title == "" {
					ct.title = c.title
				}
				if ct.artist == old.artist || ct.artist == "" {
					ct.artist = c.artist
				}
				plain := s == lyricSourceNetease && r.ne.Lyrics == ""
				setRankParityContent(s, r, ct)
				if plain {
					r.ne.Lyrics, r.ne.PlainLyrics = "", ct.lyr
				}
			})
		}
		return "查询换成外文写法"
	}},
}

func rankParityCaseFromFixture(fx *goldenFixture) rankParityCase {
	return rankParityCase{
		name: fx.ID, artist: fx.Query.Artist, title: fx.Query.Title, album: fx.Query.Album, dur: fx.Query.DurationSecs,
		raw: goldenRawRound(fx), lang: fx.Settings.TranslationLanguage, player: fx.Settings.PlayerBundleID,
		sources: fx.Settings.Sources, hint: fx.Settings.ArtistCJKHint,
	}
}

// rankParityMutated:从 base 出发按种子叠 1~5 种扰动。
func rankParityMutated(base rankParityCase, seed int64) rankParityCase {
	rng := rand.New(rand.NewSource(seed))
	c := base
	c.raw = cloneRankParityRaw(base.raw)
	c.focus = rankParityPick(rng, lyricCandidateTieOrder)
	total := 0
	for _, m := range rankParityMutators {
		total += m.weight
	}
	var notes []string
	for n := 1 + rng.Intn(5); n > 0; n-- {
		pick := rng.Intn(total)
		for _, m := range rankParityMutators {
			if pick -= m.weight; pick < 0 {
				if note := m.apply(rng, &c); note != "" {
					notes = append(notes, note)
				}
				break
			}
		}
	}
	c.name = fmt.Sprintf("%s#%d(译文语言 %q,在放 %q)[%s]", base.name, seed, c.lang, c.player, strings.Join(notes, ";"))
	return c
}

// rankParityBlock:多少组扰动共用一份设置。同一份设置的用例才能并发排,块太小就退化成串行。
const rankParityBlock = 8

// rankParityCorpus:金标样本原样各一组,加每个样本 perFixture 组扰动。种子只由样本序号和组号定;头一块用样本自己的设置,
// 之后每块按种子另抽译文语言和在放的播放器。
func rankParityCorpus(t *testing.T, perFixture int) []rankParityCase {
	t.Helper()
	var cases []rankParityCase
	for i, fx := range loadGoldenFixtures(t) {
		base := rankParityCaseFromFixture(fx)
		cases = append(cases, base)
		blockBase := base
		for k := 0; k < perFixture; k++ {
			if block := k / rankParityBlock; block > 0 && k%rankParityBlock == 0 {
				rng := rand.New(rand.NewSource(int64(i)*7919 + int64(block)))
				blockBase = base
				blockBase.lang = rankParityPick(rng, rankParityLangs)
				blockBase.player = playerBundleIDs[rankParityPick(rng, rankParityPlayers)]
			}
			cases = append(cases, rankParityMutated(blockBase, int64(i)*100003+int64(k)))
		}
	}
	return append(cases, rankParityFullFieldCases(t)...)
}

// rankParityBakedSong:英文歌每句后面烘一行晚 1.5 秒的中文译文,整行和逐字轨里都有。
func rankParityBakedSong(lines []string) (lrc, yrc string) {
	var l, y []string
	for i, text := range lines {
		ms := 2000 + 4000*i
		l = append(l, lrcTimestamp(ms)+text, lrcTimestamp(ms+1500)+rankParityHanLine(i))
		y = append(y, yrcLine(ms, text), yrcLine(ms+1500, rankParityHanLine(i)))
	}
	return strings.Join(l, "\n"), strings.Join(y, "\n")
}

// rankParityFullFieldVariants:每个来源各来一组的整形输入。build 给出这个来源交的正文那一组,可以顺手改查询。
var rankParityFullFieldVariants = []struct {
	name      string
	plainOnly bool
	build     func(c *rankParityCase) rankParityContent
}{
	{"各栏都交", false, func(c *rankParityCase) rankParityContent {
		lrc, yrc := rankParitySong(rankParityJapanese)
		return rankParityContent{lyr: lrc, yrc: yrc, tr: rankParityAux(lrc, "zh", 1), roma: rankParityAux(lrc, "latin", 1)}
	}},
	{"各栏都交加纯文本标记", true, func(c *rankParityCase) rankParityContent {
		lrc, yrc := rankParitySong(rankParityJapanese)
		return rankParityContent{lyr: lrc, yrc: yrc, tr: rankParityAux(lrc, "zh", 1), roma: rankParityAux(lrc, "latin", 1)}
	}},
	// 英文歌不配读音:交了读音也不该进结果。
	{"括号背景人声", false, func(c *rankParityCase) rankParityContent {
		lrc, yrc := rankParitySong(rankParityEnglish)
		return rankParityContent{lyr: lrc, yrc: yrc, roma: rankParityAux(lrc, "latin", 1)}
	}},
	{"烘入译文", false, func(c *rankParityCase) rankParityContent {
		c.artist, c.title = "Some Artist", "Some Title"
		lrc, _ := rankParitySong(rankParityEnglish)
		return rankParityContent{lyr: rankParityBake(lrc, "later")}
	}},
	{"烘入译文连逐字轨", false, func(c *rankParityCase) rankParityContent {
		c.artist, c.title = "Some Artist", "Some Title"
		lrc, yrc := rankParityBakedSong(rankParityEnglish)
		return rankParityContent{lyr: lrc, yrc: yrc}
	}},
	// 标签带汉字的歌不算外文歌:同一份烘了译文的英文正文不摘。
	{"中文标签下的烘入译文", false, func(c *rankParityCase) rankParityContent {
		c.artist, c.title = "某位歌手", "某首歌名"
		lrc, yrc := rankParityBakedSong(rankParityEnglish)
		return rankParityContent{lyr: lrc, yrc: yrc}
	}},
	{"逐字残缺", false, func(c *rankParityCase) rankParityContent {
		lrc, yrc := rankParitySong(rankParityJapanese)
		rows := strings.Split(yrc, "\n")
		return rankParityContent{lyr: lrc, yrc: strings.Join(rows[:len(rows)/4], "\n")}
	}},
	// 拿汉字当读音的轨不进结果。
	{"读音是汉字", false, func(c *rankParityCase) rankParityContent {
		lrc, yrc := rankParitySong(rankParityJapanese)
		return rankParityContent{lyr: lrc, yrc: yrc, roma: rankParityAux(lrc, "zh", 1)}
	}},
	// 只有逐字、没有整行:公共字段的源不出候选。
	{"只有逐字没有整行", false, func(c *rankParityCase) rankParityContent {
		_, yrc := rankParitySong(rankParityJapanese)
		return rankParityContent{yrc: yrc, tr: "[00:02.00]只有译文", roma: "[00:02.00]tada yomi"}
	}},
	// 中文歌第一行是「歌名 - 歌手」的抬头,歌手那一段是缩写、只有歌名对得上;中间五句外文各带一行挂在下一句时间戳上的
	// 中文译文(酷我的烘法),另有一句外文没带译文。抬头认出来就不算进要翻的行,六句译了五句,过「译全了」那条判据;
	// 把歌手和歌名对调着认,抬头算成又一句没译的,七句译了五句,不过。
	{"抬头行只有歌名对得上", false, func(c *rankParityCase) rankParityContent {
		c.artist, c.title, c.lang = "Khalil Fong", "Throw It Off", "zh"
		var lines []string
		ms := 500
		add := func(text string, step int) {
			lines = append(lines, lrcTimestamp(ms)+text)
			ms += step
		}
		add("Throw It Off - K. Fong", 3500)
		for i := 0; i < 3; i++ {
			add(rankParityHanLine(i), 4000)
		}
		for i := 0; i < 5; i++ {
			add("placeholder foreign line number "+strconv.Itoa(i), 4000)
			add(rankParityHanLine(10+i), 0)
		}
		add(rankParityHanLine(3), 4000)
		add("one more foreign line left without a pair", 4000)
		for i := 4; i < 7; i++ {
			add(rankParityHanLine(i), 4000)
		}
		return rankParityContent{lyr: strings.Join(lines, "\n")}
	}},
}

// rankParityFullFieldCases:每个来源按 rankParityFullFieldVariants 各来一组,垫在金标样本那一轮别的源旁边;除正文那一组外
// 别的栏(背景人声轨、作者、ISRC、链接、语种、曲目编号、本机身份)都交。随机扰动凑不凑得出这些组合不看运气。
func rankParityFullFieldCases(t *testing.T) []rankParityCase {
	t.Helper()
	fixtures := loadGoldenFixtures(t)
	var cases []rankParityCase
	for i, source := range lyricCandidateTieOrder {
		base := rankParityCaseFromFixture(fixtures[i%len(fixtures)])
		for _, variant := range rankParityFullFieldVariants {
			c := base
			c.raw = cloneRankParityRaw(base.raw)
			c.name = fmt.Sprintf("%s+%s:%s", base.name, source, variant.name)
			ct := variant.build(&c)
			ct.title, ct.artist, ct.album, ct.cover, ct.dur = c.title, c.artist, c.album, "https://example.com/full.jpg", c.dur
			rankParityEdit(&c, source, func(r *lyricSourceResult) {
				setRankParityContent(source, r, ct)
				r.bg, r.songwriters, r.isrc, r.sourceURL = rankParityBG, []string{"Writer A"}, "USUM71703861", "https://www.megalobiz.com/lrc/maker/x.1"
				r.language, r.trackIDs, r.plainOnly = songLanguageMandarin, []string{"97773"}, variant.plainOnly
				r.amll.bg, r.amll.songwriters, r.amll.pageURL = rankParityBG, []string{"Writer A"}, "https://github.com/amll-dev/amll-ttml-db/blob/main/raw-lyrics/1.ttml"
				rankParitySetLocal(r, source)
			})
			cases = append(cases, c)
		}
	}
	return cases
}

// 金标样本原样加每个来源的整形输入;参照另多排一遍,核对它自己前后一致。
func TestRankParityGolden(t *testing.T) {
	runRankParity(t, rankParityCorpus(t, 0), true)
}

// rankParityDefaultPerFixture / rankParityLargePerFixture:每个金标样本叠多少组扰动。
const (
	rankParityDefaultPerFixture = 4
	rankParityLargePerFixture   = 160
)

// rankParityLargeEnv:设了才跑大语料。1 = 每个样本叠 rankParityLargePerFixture 组;别的正整数 = 每个样本叠那么多组。
// 不能靠 -run 点没点名来判:提交校验的分片脚本(scripts/go-test-shards.py)把每个测试的名字都写进 -run。
const rankParityLargeEnv = "LYRIC_RANK_PARITY_LARGE"

func TestRankParityCorpus(t *testing.T) {
	cases := rankParityCorpus(t, rankParityDefaultPerFixture)
	runRankParity(t, cases, false)
	t.Logf("%d 组", len(cases))
}

// 大语料只在设了 rankParityLargeEnv 时跑(整套测试、提交校验里跳过)。除了对拍,还核对语料走到了每个来源那段装配的
// 每个分支(rankParityCoverageGaps)。
func TestRankParityLargeCorpus(t *testing.T) {
	perFixture := rankParityLargePerFixture
	switch v, err := strconv.Atoi(os.Getenv(rankParityLargeEnv)); {
	case err != nil || v <= 0:
		t.Skipf("大语料:设 %s=1 再跑", rankParityLargeEnv)
	case v > 1:
		perFixture = v
	}
	cases := rankParityCorpus(t, perFixture)
	tally := runRankParity(t, cases, false)
	t.Logf("%d 组\n各来源的装配结果计数:\n%s", len(cases), tally.report())
	for _, gap := range rankParityCoverageGaps(tally) {
		t.Errorf("语料没走到:%s", gap)
	}
}
