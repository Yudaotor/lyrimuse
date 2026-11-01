package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// 批量导入一个文件夹里的歌词文件(11 章决策 150)。App 读文件(文件夹可能在受保护的目录里,引擎读不到),写一份暂存请求到
// importStagingDir;引擎两步:
//   - plan-lyrics-import <暂存文件>:只读子命令,按文件名把文件分组(同名的正文 / .tr.lrc / .roma.lrc 一组)、逐组解析
//     (parseImportedLyrics)、认这一组是哪首歌,对照缓存里已有的条目出一张预览清单。不碰缓存。
//   - 改动请求 import_lyrics_batch:按用户在预览表里定下的「哪组 → 哪个 key」和导入方式写进缓存。
// 两步按同一份暂存文件、同一套分组(groupImportFiles)认组号。

// 导入方式(App 侧 LyricsBatchImport.Mode 同名)。
const (
	importModeManual = "manual" // 锁定为手动修改,自动匹配不再换
	importModePrefer = "prefer" // 优先使用,进导入库(importstore.go),别的源给出明显更好的还能换
	importModeFill   = "fill"   // 只补没有歌词的歌,补上的同 prefer
	// 监视文件夹自动导入用(App 侧 LyricsImportWatcher):对得上的歌进导入库,条目里没有歌词的才写进去,已有的不动、
	// 等下一轮选词跟各源比;不用打快照。
	importModeLibrary = "library"
)

func importStagingDir() string {
	dir := configDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, clientName+"-import-staging")
}

type importFileGroup struct {
	ID    int
	Dir   string
	Stem  string
	Files []importLyricsFile
}

var importStemSuffixes = []string{".tr.lrc", ".roma.lrc", ".enhanced.lrc", ".lrcx", ".lrc", ".yrc", ".ttml", ".xml", ".qrc", ".krc", ".txt"}

// importStem:文件名去掉认得的后缀,同名的正文、译文、读音文件得到同一个 stem。
func importStem(name string) string {
	lower := strings.ToLower(name)
	for _, s := range importStemSuffixes {
		if strings.HasSuffix(lower, s) {
			return name[:len(name)-len(s)]
		}
	}
	if ext := filepath.Ext(name); ext != "" {
		return strings.TrimSuffix(name, ext)
	}
	return name
}

// groupImportFiles 按「所在子目录 + stem」(不分大小写)分组,按目录、stem 排序后编号:plan 和 apply 拿同一份暂存文件
// 得到同样的组号。
func groupImportFiles(files []importLyricsFile) []importFileGroup {
	byKey := map[string]*importFileGroup{}
	var order []string
	for _, f := range files {
		rel := f.Path
		if rel == "" {
			rel = f.Name
		}
		dir := path.Dir(filepath.ToSlash(rel))
		stem := importStem(f.Name)
		k := strings.ToLower(dir + "\x00" + stem)
		g, ok := byKey[k]
		if !ok {
			g = &importFileGroup{Dir: dir, Stem: stem}
			byKey[k] = g
			order = append(order, k)
		}
		g.Files = append(g.Files, f)
	}
	sort.Strings(order)
	out := make([]importFileGroup, 0, len(order))
	for i, k := range order {
		g := byKey[k]
		g.ID = i
		sort.Slice(g.Files, func(a, b int) bool { return g.Files[a].Name < g.Files[b].Name })
		out = append(out, *g)
	}
	return out
}

type importIdentity struct {
	artist, title, album string
	// loose:文件名里没有带空格的分隔符、按无空格的连字符硬拆出来的(「周杰伦-晴天」,也可能是「Ob-La-Di」),只拿来对歌词库,
	// 不当身份存进导入库。
	loose bool
}

var (
	importStemHashRe   = regexp.MustCompile(`~[0-9a-f]{6,8}$`)
	importTrackNumRe   = regexp.MustCompile(`^\d{1,3}$`)
	importTrackPrefRe  = regexp.MustCompile(`^\d{1,3}\s*[.)_]\s*`)
	importStemSplitter = regexp.MustCompile(`\s+[-–—－]\s+`)
	importStemTightRe  = regexp.MustCompile(`[-–—－]`)
)

// importIdentityGuesses:这一组可能是哪首歌,按可信程度排:文件里写的(标签、TTML / QRC 的头部、Lyrimuse 自己的文件头),
// 再是文件名里的「歌手 - 歌名」「歌名 - 歌手」「歌手 - 歌名 - 专辑」(Lyrimuse 导出的命名)、「歌手 - 专辑 - 歌名」、
// 「歌手 - 歌名里带 - 的」、只有歌名;文件名开头的音轨号去掉,全角空格这类先折成普通空格。
func importIdentityGuesses(stem string, c *scoredLyricCandidateResult) []importIdentity {
	var out []importIdentity
	if c != nil && strings.TrimSpace(c.Title) != "" {
		out = append(out, importIdentity{artist: c.Artist, title: c.Title, album: c.Album})
	}
	s := strings.TrimSpace(importStemHashRe.ReplaceAllString(cleanMediaTag(stem), ""))
	s = strings.TrimSpace(importTrackPrefRe.ReplaceAllString(s, ""))
	var parts []string
	for _, p := range importStemSplitter.Split(s, -1) {
		if p = strings.TrimSpace(p); p != "" {
			parts = append(parts, p)
		}
	}
	// 「01 - 歌手 - 歌名」的开头是音轨号;只有两段时分不清是音轨号还是数字歌手名(「311 - Amber」),两种都猜。
	if len(parts) > 2 && importTrackNumRe.MatchString(parts[0]) {
		parts = parts[1:]
	}
	if len(parts) == 2 && importTrackNumRe.MatchString(parts[0]) {
		return append(out, importIdentity{artist: parts[0], title: parts[1]}, importIdentity{title: parts[1]})
	}
	switch len(parts) {
	case 0:
	case 1:
		out = append(out, importIdentity{title: parts[0]})
		if loc := importStemTightRe.FindStringIndex(parts[0]); loc != nil {
			a, b := strings.TrimSpace(parts[0][:loc[0]]), strings.TrimSpace(parts[0][loc[1]:])
			if a != "" && b != "" {
				out = append(out, importIdentity{artist: a, title: b, loose: true}, importIdentity{artist: b, title: a, loose: true})
			}
		}
	case 2:
		out = append(out, importIdentity{artist: parts[0], title: parts[1]}, importIdentity{artist: parts[1], title: parts[0]})
	default:
		out = append(out,
			importIdentity{artist: parts[0], title: parts[1], album: strings.Join(parts[2:], " - ")},
			importIdentity{artist: parts[0], title: parts[len(parts)-1], album: strings.Join(parts[1:len(parts)-1], " - ")},
			importIdentity{artist: parts[0], title: strings.Join(parts[1:], " - ")})
	}
	return out
}

type importLibEntry struct {
	key, artist, title, album string
	dur                       float64
	hasLyrics, manual, plain  bool
	source                    string
}

type importLibrary struct {
	entries []importLibEntry
	byTitle map[string][]int
	// byBareTitle:歌名带合作署名(「(feat. X)」「ft. X」)的条目,按去掉署名后的歌名再记一份,文件名没写署名时用。
	byBareTitle map[string][]int
}

func importNormTitle(t string) string {
	return loosenEnrichKey(normEnrichTitle(cleanMediaTag(t)))
}

func importNormName(s string) string {
	return loosenEnrichKey(cleanMediaTag(s))
}

func buildImportLibrary(cache map[string]enrichEntry) importLibrary {
	lib := importLibrary{byTitle: map[string][]int{}, byBareTitle: map[string][]int{}}
	keys := make([]string, 0, len(cache))
	for k := range cache {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		e := cache[k]
		if strings.Count(k, "|") < 2 {
			continue
		}
		artist, title, album := splitEnrichKey(k)
		title = strings.TrimSuffix(title, enrichKeyDurationVariantRe.FindString(title))
		dur := e.DurationSecs
		if dur <= 0 {
			dur = e.ResolvedDurationSecs
		}
		lib.entries = append(lib.entries, importLibEntry{
			key: k, artist: artist, title: title, album: album, dur: dur,
			hasLyrics: e.Lyrics.Len() > 0 || e.BodyFields&32 != 0 || e.Instrumental, manual: e.ManualLyrics, source: e.LyricsSource,
			plain: e.PlainLyrics.Len() > 0 || e.BodyFields&8 != 0,
		})
		n := importNormTitle(title)
		lib.byTitle[n] = append(lib.byTitle[n], len(lib.entries)-1)
		if bare := titleWithoutFeatCredit(title); bare != "" {
			b := importNormTitle(bare)
			lib.byBareTitle[b] = append(lib.byBareTitle[b], len(lib.entries)-1)
		}
	}
	return lib
}

// titleCandidates:歌名对得上的条目。先按原样;对不上时两边都去掉合作署名再比(文件名、库里只有一边写了「feat. X」)。
func (lib importLibrary) titleCandidates(title string) []int {
	if list := lib.byTitle[importNormTitle(title)]; len(list) > 0 {
		return list
	}
	bare := titleWithoutFeatCredit(title)
	if bare != "" {
		if list := lib.byTitle[importNormTitle(bare)]; len(list) > 0 {
			return list
		}
	} else {
		bare = title
	}
	return lib.byBareTitle[importNormTitle(bare)]
}

// importArtistFits:歌手对不对得上。对不上时去掉合作署名、只看第一位再比一次(「A feat. B」「A & B」)。
func importArtistFits(libArtist, guess string) bool {
	if importNormName(libArtist) == importNormName(guess) || artistMatches(libArtist, guess) {
		return true
	}
	pg, pl := primaryCreditedArtist(guess), primaryCreditedArtist(libArtist)
	if pg == "" || pl == "" {
		return false
	}
	return importNormName(pl) == importNormName(pg) || artistMatches(libArtist, pg) || artistMatches(pl, guess)
}

// match:按猜测的先后找第一组歌手、歌名都对得上的条目;有专辑、又有专辑也对得上的,只留那几条。没写歌手的猜测(文件里只有
// [ti:]、文件名只有歌名)对上了先记着,后面带歌手的猜测都对不上才用它。
// byTitleOnly:是只凭歌名对上的(猜测里没有歌手),调用方别自动认定。
func (lib importLibrary) match(guesses []importIdentity) (hits []int, byTitleOnly bool) {
	var titleOnly []int
	for _, g := range guesses {
		list := lib.titleCandidates(g.title)
		if len(list) == 0 {
			continue
		}
		if g.artist != "" {
			var kept []int
			for _, i := range list {
				if importArtistFits(lib.entries[i].artist, g.artist) {
					kept = append(kept, i)
				}
			}
			list = kept
		}
		if len(list) == 0 {
			continue
		}
		if g.album != "" {
			var sameAlbum []int
			nal := importNormName(g.album)
			for _, i := range list {
				if importNormName(lib.entries[i].album) == nal {
					sameAlbum = append(sameAlbum, i)
				}
			}
			if len(sameAlbum) > 0 {
				list = sameAlbum
			}
		}
		if g.artist == "" {
			if titleOnly == nil {
				titleOnly = list
			}
			continue
		}
		return list, false
	}
	return titleOnly, titleOnly != nil
}

type importPlanOption struct {
	Key          string  `json:"key"`
	Artist       string  `json:"artist"`
	Title        string  `json:"title"`
	Album        string  `json:"album"`
	DurationSecs float64 `json:"duration_secs,omitempty"`
	HasLyrics    bool    `json:"has_lyrics"`
	// HasPlain:有纯文本歌词(「只补」时导入纯文本不换掉它)。
	HasPlain bool   `json:"has_plain,omitempty"`
	Manual   bool   `json:"manual"`
	Source   string `json:"source,omitempty"`
}

// 预览清单一行的状态。
const (
	importStatusMatched      = "matched"      // 认出是哪一首
	importStatusAmbiguous    = "ambiguous"    // 对得上好几首,时长也分不开,等用户挑
	importStatusUnmatched    = "unmatched"    // 库里没有对得上的
	importStatusUnrecognized = "unrecognized" // 文件认不出歌词
	importStatusDuplicate    = "duplicate"    // 跟别的组对到同一首,那一组更好
)

type importPlanItem struct {
	ID              int                `json:"id"`
	Files           []string           `json:"files"`
	Format          string             `json:"format,omitempty"`
	Lines           int                `json:"lines,omitempty"`
	HasWordTiming   bool               `json:"has_word_timing,omitempty"`
	HasTranslation  bool               `json:"has_translation,omitempty"`
	HasRomanization bool               `json:"has_romanization,omitempty"`
	PlainText       bool               `json:"plain_text,omitempty"`
	Artist          string             `json:"artist,omitempty"`
	Title           string             `json:"title,omitempty"`
	Album           string             `json:"album,omitempty"`
	Status          string             `json:"status"`
	Error           string             `json:"error,omitempty"`
	Key             string             `json:"key,omitempty"`
	Options         []importPlanOption `json:"options,omitempty"`
	DuplicateOf     int                `json:"duplicate_of,omitempty"`
	// CanStore:库里没有对应的歌曲时,认得出歌手和歌名、可以按身份存进导入库(importStoreIdentities)。
	CanStore bool `json:"can_store,omitempty"`
}

type importPlan struct {
	Items []importPlanItem `json:"items"`
}

// importTimedLines:有时间戳的行数;纯文本数非空行。
func importTimedLines(c *scoredLyricCandidateResult) int {
	if c.PlainTextOnly {
		n := 0
		for _, l := range strings.Split(c.Lyrics, "\n") {
			if strings.TrimSpace(l) != "" {
				n++
			}
		}
		return n
	}
	return len(importLRCLineRe.FindAllStringIndex(c.Lyrics, -1))
}

// importBetter:同一首对到两组时留哪组:带逐字的,再是不是纯文本,再是行数多的,最后组号小的。
func importBetter(a, b importPlanItem) bool {
	if a.HasWordTiming != b.HasWordTiming {
		return a.HasWordTiming
	}
	if a.PlainText != b.PlainText {
		return !a.PlainText
	}
	if a.Lines != b.Lines {
		return a.Lines > b.Lines
	}
	return a.ID < b.ID
}

func planLyricsImport(files []importLyricsFile, trTarget string, cache map[string]enrichEntry) importPlan {
	lib := buildImportLibrary(cache)
	groups := groupImportFiles(files)
	plan := importPlan{Items: make([]importPlanItem, 0, len(groups))}
	for _, g := range groups {
		item := importPlanItem{ID: g.ID}
		for _, f := range g.Files {
			p := f.Path
			if p == "" {
				p = f.Name
			}
			item.Files = append(item.Files, p)
		}
		res := parseImportedLyrics(g.Files, trTarget)
		c := res.Candidate
		guesses := importIdentityGuesses(g.Stem, c)
		if len(guesses) > 0 {
			item.Artist, item.Title, item.Album = guesses[0].artist, guesses[0].title, guesses[0].album
		}
		if c == nil {
			item.Status, item.Error = importStatusUnrecognized, res.Error
			plan.Items = append(plan.Items, item)
			continue
		}
		item.Format, item.Lines = res.Format, importTimedLines(c)
		item.HasWordTiming, item.PlainText = c.HasWordTiming, c.PlainTextOnly
		item.HasTranslation, item.HasRomanization = c.LyricsTr != "", c.LyricsRoma != ""
		hits, byTitleOnly := lib.match(guesses)
		for _, i := range hits {
			e := lib.entries[i]
			item.Options = append(item.Options, importPlanOption{
				Key: e.key, Artist: e.artist, Title: e.title, Album: e.album, DurationSecs: e.dur,
				HasLyrics: e.hasLyrics, HasPlain: e.plain, Manual: e.manual, Source: e.source,
			})
		}
		switch {
		case len(hits) == 0:
			item.Status = importStatusUnmatched
			item.CanStore = !c.PlainTextOnly && len(importStoreIdentities(g.Stem, c)) > 0
		case byTitleOnly:
			// 只凭歌名对上的(文件里、文件名里都没有歌手):交给用户挑,监视文件夹也不自动导。
			item.Status = importStatusAmbiguous
		case len(hits) == 1:
			item.Status, item.Key = importStatusMatched, item.Options[0].Key
		default:
			item.Status = importStatusAmbiguous
			last, ok := lastLRCTimestampSecs(c.Lyrics)
			if ok {
				var fits []int
				for j, o := range item.Options {
					if o.DurationSecs > 0 && durationFits(last, o.DurationSecs) {
						fits = append(fits, j)
					}
				}
				if len(fits) == 1 {
					item.Status, item.Key = importStatusMatched, item.Options[fits[0]].Key
				}
				sort.SliceStable(item.Options, func(a, b int) bool {
					return importDurationGap(item.Options[a].DurationSecs, last) < importDurationGap(item.Options[b].DurationSecs, last)
				})
			}
		}
		plan.Items = append(plan.Items, item)
	}
	best := map[string]int{}
	for i, it := range plan.Items {
		if it.Status != importStatusMatched {
			continue
		}
		if j, ok := best[it.Key]; !ok || importBetter(it, plan.Items[j]) {
			best[it.Key] = i
		}
	}
	for i, it := range plan.Items {
		if it.Status == importStatusMatched && best[it.Key] != i {
			plan.Items[i].Status = importStatusDuplicate
			plan.Items[i].DuplicateOf = plan.Items[best[it.Key]].ID
		}
	}
	return plan
}

// importStoreIdentities:按身份存进导入库时认哪几种「歌手 + 歌名」。文件里写了歌手和歌名就只认它;否则用文件名里歌手、歌名
// 都有的猜测(两种顺序都记)。只有歌名的不存:放到同名的别的歌时会借错。
func importStoreIdentities(stem string, c *scoredLyricCandidateResult) []importedIdentity {
	if c != nil && strings.TrimSpace(c.Title) != "" && strings.TrimSpace(c.Artist) != "" {
		return []importedIdentity{{Artist: c.Artist, Title: c.Title}}
	}
	// 纯数字的「歌手」多半是音轨号(「01 - 歌名」),存进去永远对不上;只留给 match 在歌词库里比对。
	var out []importedIdentity
	for _, g := range importIdentityGuesses(stem, nil) {
		if g.artist != "" && g.title != "" && !g.loose && !importTrackNumRe.MatchString(g.artist) {
			out = append(out, importedIdentity{Artist: g.artist, Title: g.title})
		}
	}
	return out
}

func importDurationGap(dur, last float64) float64 {
	if dur <= 0 {
		return 1e9
	}
	if dur > last {
		return dur - last
	}
	return last - dur
}

type importStagingRequest struct {
	Files []importLyricsFile `json:"files"`
}

// readImportStaging 读 App 写的暂存请求。只认 importStagingDir 下的文件:改动请求里的路径是 App 给的,别让它去读别处。
func readImportStaging(p string) ([]importLyricsFile, error) {
	dir := importStagingDir()
	if dir == "" || filepath.Dir(filepath.Clean(p)) != filepath.Clean(dir) {
		return nil, fmt.Errorf("staging file outside %s", dir)
	}
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, 512<<20))
	if err != nil {
		return nil, err
	}
	var req importStagingRequest
	if err := json.Unmarshal(raw, &req); err != nil {
		return nil, err
	}
	return req.Files, nil
}

// runPlanLyricsImportCLI:plan-lyrics-import <暂存文件>,只读,结果(importPlan)打到 stdout。
func runPlanLyricsImportCLI(args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "usage: plan-lyrics-import <staging file>")
		os.Exit(2)
	}
	cfgDir := configDir()
	if cfgDir == "" {
		fmt.Fprintln(os.Stderr, "plan-lyrics-import: cannot resolve the config directory")
		os.Exit(2)
	}
	setFeatures(loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json")))
	files, err := readImportStaging(args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, "plan-lyrics-import:", err)
		os.Exit(2)
	}
	loadEnrichCacheMetaReadOnly(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	out, _ := json.Marshal(planLyricsImport(files, features().LyricsTranslationLanguage, enrichCache))
	fmt.Println(string(out))
}

// importBatchItem:预览表里定下的一组 → 哪个 key。Force:这首是手改过的也换(预览表里默认不勾)。Store:库里没有对应的歌曲,
// 按身份存进导入库(Key 为空)。
type importBatchItem struct {
	ID    int    `json:"id"`
	Key   string `json:"key"`
	Force bool   `json:"force,omitempty"`
	Store bool   `json:"store,omitempty"`
}

// importBatchPrepared:import_lyrics_batch 在拿 enrichMu 之前读好、解析好的那几组(prepareImportBatch),锁里只写缓存。
type importBatchPrepared struct {
	groups map[int]importPreparedGroup
	err    error
}

type importPreparedGroup struct {
	stem  string
	names []string
	// paths:各文件在所选文件夹里的相对路径(监视文件夹的记录据此记下来源)。
	paths []string
	c     *scoredLyricCandidateResult
}

// prepareImportBatch:读暂存、分组,只解析预览表里选中的那几组。不碰缓存,在锁外跑。
func prepareImportBatch(req enrichEditRequest) *importBatchPrepared {
	files, err := readImportStaging(req.Staging)
	if err != nil {
		return &importBatchPrepared{err: err}
	}
	groups := groupImportFiles(files)
	trTarget := features().LyricsTranslationLanguage
	out := &importBatchPrepared{groups: map[int]importPreparedGroup{}}
	for _, it := range req.ImportItems {
		if it.ID < 0 || it.ID >= len(groups) {
			continue
		}
		if _, done := out.groups[it.ID]; done {
			continue
		}
		g := groups[it.ID]
		names := make([]string, 0, len(g.Files))
		paths := make([]string, 0, len(g.Files))
		for _, f := range g.Files {
			names = append(names, f.Name)
			rel := f.Path
			if rel == "" {
				rel = f.Name
			}
			paths = append(paths, rel)
		}
		out.groups[it.ID] = importPreparedGroup{stem: g.Stem, names: names, paths: paths,
			c: parseImportedLyrics(g.Files, trTarget).Candidate}
	}
	return out
}

// applyImportBatchLocked:import_lyrics_batch 改动请求。只写缓存里已有的条目;手改过的不 Force 不动;纯文本盖不住已有的逐行
// 歌词(显示层先用逐行的),不写;「只补没有歌词的歌」跳过已有逐行歌词、标了纯音乐的;监视文件夹(library)再加上只有纯文本的,
// 这些只进导入库。调用方持 enrichMu;暂存的读取和解析在锁外做好(req.importPrepared),没做时这里补做。
func applyImportBatchLocked(req enrichEditRequest) enrichEditOutcome {
	switch req.Mode {
	case importModeManual, importModePrefer, importModeFill, importModeLibrary:
	default:
		return enrichEditOutcome{err: fmt.Errorf("import_lyrics_batch: unknown mode %q", req.Mode)}
	}
	prep := req.importPrepared
	if prep == nil {
		prep = prepareImportBatch(req)
	}
	if prep.err != nil {
		return enrichEditOutcome{err: fmt.Errorf("import_lyrics_batch: %w", prep.err)}
	}
	now := time.Now()
	var exports, dropped []string
	var recs []importedLyricsRecord
	stored, written := 0, 0
	// 监视文件夹存进来的记录记下来源文件,文件删了、挪走了跟着作废(dropImportedLyricsFromWatchFiles)。
	watchFiles := func(g importPreparedGroup) []string {
		if req.Mode != importModeLibrary || req.WatchFolder == "" {
			return nil
		}
		out := make([]string, 0, len(g.paths))
		for _, p := range g.paths {
			out = append(out, filepath.Join(req.WatchFolder, filepath.FromSlash(p)))
		}
		return out
	}
	keyedRecord := func(key string, g importPreparedGroup) importedLyricsRecord {
		c := g.c
		return importedLyricsRecord{
			Key: key, Lyrics: c.Lyrics, Tr: c.LyricsTr, TrLang: c.LyricsTrLang, Roma: c.LyricsRoma, YRC: c.LyricsYRC,
			BG: c.LyricsBG, Title: c.Title, Artist: c.Artist, Album: c.Album, Files: g.names, ImportedAt: now.Unix(),
			WatchFiles: watchFiles(g),
		}
	}
	for _, it := range req.ImportItems {
		g, ok := prep.groups[it.ID]
		if !ok || g.c == nil {
			continue
		}
		c := g.c
		if it.Key == "" {
			if it.Store {
				if rec, ok := importStoreRecord(g, now); ok {
					rec.WatchFiles = watchFiles(g)
					recs = append(recs, rec)
					stored++
				}
			}
			continue
		}
		e, ok := enrichCache[it.Key]
		if !ok || (e.ManualLyrics && !it.Force) {
			continue
		}
		hasLyrics := e.Lyrics.Len() > 0
		if c.PlainTextOnly && hasLyrics {
			continue
		}
		// 「只补」:已有逐行歌词、标了纯音乐的不动;导入的是纯文本时,已有纯文本也算有(别拿一份纯文本换掉另一份)。
		if req.Mode == importModeFill && (hasLyrics || e.Instrumental || (c.PlainTextOnly && e.PlainLyrics.Len() > 0)) {
			continue
		}
		if req.Mode == importModeLibrary && (hasLyrics || e.Instrumental || e.PlainLyrics.Len() > 0) {
			if !c.PlainTextOnly {
				recs = append(recs, keyedRecord(it.Key, g))
				stored++
			}
			continue
		}
		if c.PlainTextOnly {
			e.PlainLyrics, e.PlainLyricsSource = bt(c.Lyrics), importLyricsSource
			e.Instrumental = false
			e.ManualLyrics = e.ManualLyrics || req.Mode == importModeManual
		} else {
			yrc, bg, trLang := c.LyricsYRC, c.LyricsBG, c.LyricsTrLang
			edit := enrichEditRequest{
				Lyrics: c.Lyrics, Tr: c.LyricsTr, Roma: c.LyricsRoma, YRC: &yrc, BG: &bg, TrLang: &trLang,
				Source: importLyricsSource, MarkManual: req.Mode == importModeManual,
			}
			if err := applySaveEdit(&e, edit); err != nil {
				continue
			}
			e.LyricsDecisionApplied = nil
		}
		enrichCache[it.Key] = e
		cancelInFlightEnrichLocked(it.Key)
		exports = append(exports, it.Key)
		written++
		if req.Mode == importModeManual {
			dropped = append(dropped, it.Key)
			if songEntitySharing() {
				exports = append(exports, shareManualEditLocked(it.Key, now)...)
			}
			continue
		}
		if !c.PlainTextOnly {
			recs = append(recs, keyedRecord(it.Key, g))
		}
	}
	dropImportedLyrics(dropped...)
	if len(recs) > 0 {
		if err := saveImportedLyrics(recs...); err != nil {
			noteFileErr("write", importedLyricsDir(), err)
		}
	}
	// 改了几首只数请求里的这几首:「锁定」时同一首歌的其他写法跟着改(shareManualEditLocked),不算进去。
	return enrichEditOutcome{changed: written + stored, exports: exports}
}

// importStoreRecord:库里没有对应歌曲的一组,做成按身份存的导入库记录。纯文本、认不出歌手歌名的不存。
func importStoreRecord(g importPreparedGroup, now time.Time) (importedLyricsRecord, bool) {
	c := g.c
	if c == nil || c.PlainTextOnly {
		return importedLyricsRecord{}, false
	}
	ids := importStoreIdentities(g.stem, c)
	if len(ids) == 0 {
		return importedLyricsRecord{}, false
	}
	return importedLyricsRecord{
		Lyrics: c.Lyrics, Tr: c.LyricsTr, TrLang: c.LyricsTrLang, Roma: c.LyricsRoma, YRC: c.LyricsYRC, BG: c.LyricsBG,
		Title: ids[0].Title, Artist: ids[0].Artist, Album: c.Album, Files: g.names, ImportedAt: now.Unix(), Identities: ids,
	}, true
}
