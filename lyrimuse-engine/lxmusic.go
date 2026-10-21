package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 洛雪音乐(lx-music-desktop,开源的 Electron 播放器)自己的本地数据,只读,读不动当没有:
//
//   - LxDatas/data.json 的 playInfo:在放哪个列表(listId)的第几首(index)。洛雪换歌时写、节流 2 秒,只当提示,
//     认这一首还要比歌名和歌手(lxMusicCurrentTrack)。
//   - LxDatas/lx.data.db(SQLite,WAL):my_list_music_info + my_list_music_info_order 是各列表的曲目和顺序,id 是
//     「平台缩写_平台曲目 id」(kw_228908;kw 酷我、kg 酷狗、tx QQ、wy 网易云、mg 咪咕)。lyric 表是放过的歌的原版歌词,
//     按 id 存,正文 base64,type 分 lyric(LRC)/ tlyric(译文)/ rlyric(音译)/ lxlyric(逐字),source 是 raw
//     (从平台拉下来的)或 edited(用户在洛雪里改过的,优先用)。music_url 表是取到的播放地址,id 是「曲目 id_音质」,
//     写的时候先删再插(rowid 变大),见 lxMusicPreloadedNext。
//   - LxDatas/config_v2.json 的 setting["player.togglePlayMethod"]:listLoop / list / random / singleLoop / none;
//     openAPI.enable / openAPI.port:用户打开的开放 API(见 lxMusicOpenAPILyrics)。
//   - lx.data.db 的 dislike_list:「不喜欢」规则,每行一条(歌名@歌手 / 歌名 / @歌手),洛雪挑下一首时跳过(lxMusicDislike)。
//
// 另读 App 记下的「从 Lyrimuse 加进洛雪『稍后播放』的那几首」(lxMusicPlayLaterQueued)。本地库里没有这首的词时退到开放 API
// (lxMusicOpenAPILyrics)。这三项见 09 章决策 265。
//
// 系统会话里报的歌名、歌手、专辑就是列表里这一条的 name、singer、meta.albumName。SQLite 走 /usr/bin/sqlite3(理由见
// qqlocal.go)。见 09 章决策 258。

// lxMusicLocalLyricsSource:洛雪本地歌词那份候选的来源名。它不是歌词源(同 kkboxLocalLyricsSource):不能按歌名搜,
// 只有洛雪放过的歌才有,不进源清单;players.json 里洛雪的 nativeLyricSource 填它,用洛雪放歌时享受同源加权。
const lxMusicLocalLyricsSource = "lxmusic"

// lxMusicDataDirOverride 让单测把 LxDatas 指到临时目录。空 = 用真实路径。
var lxMusicDataDirOverride string

func lxMusicDataDir() string {
	if lxMusicDataDirOverride != "" {
		return lxMusicDataDirOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "lx-music-desktop", "LxDatas")
}

func lxMusicDataFile(name string) string {
	dir := lxMusicDataDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, name)
}

func lxMusicDBPath() string     { return lxMusicDataFile("lx.data.db") }
func lxMusicStatePath() string  { return lxMusicDataFile("data.json") }
func lxMusicConfigPath() string { return lxMusicDataFile("config_v2.json") }

// lxMusicTrack 是列表里的一条。
type lxMusicTrack struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Singer   string `json:"singer"`
	Source   string `json:"source"`
	Interval string `json:"interval"`
	Meta     string `json:"meta"`
}

func (t lxMusicTrack) album() string {
	var m struct {
		AlbumName string `json:"albumName"`
	}
	if json.Unmarshal([]byte(t.Meta), &m) != nil {
		return ""
	}
	return strings.TrimSpace(m.AlbumName)
}

// durationSecs:列表里登记的时长(`mm:ss` 或 `hh:mm:ss`,整秒),认不出返回 0。
func (t lxMusicTrack) durationSecs() float64 {
	total := 0
	for _, part := range strings.Split(strings.TrimSpace(t.Interval), ":") {
		v, err := strconv.Atoi(part)
		if err != nil || v < 0 {
			return 0
		}
		total = total*60 + v
	}
	return float64(total)
}

// songPages:这一条在它所属平台的歌曲页。只给 QQ(tx,songId 是 songmid)和网易云(wy,数字 id):别的平台在条目里没有
// 歌曲页字段。id 先过跟那两个播放器同一道形状闸(playerSongIDOK)。
func (t lxMusicTrack) songPages() (qq, netease string) {
	var m struct {
		SongID json.RawMessage `json:"songId"`
	}
	if json.Unmarshal([]byte(t.Meta), &m) != nil {
		return "", ""
	}
	switch t.Source {
	case "tx":
		if mid := strings.Trim(strings.TrimSpace(string(m.SongID)), `"`); playerSongIDOK(qqMusicBundleID, mid) {
			qq = qqSongURL(mid)
		}
	case "wy":
		if id := rawDigitsID(m.SongID); playerSongIDOK(neteaseMusicBundleID, id) {
			netease = "https://music.163.com/song?id=" + id
		}
	}
	return qq, netease
}

// lxMusicPlayingCatalogIDs:洛雪正在放的这首的曲目 id(列表里那一条的 id,记进 PlayerSongIDs)和它所属平台的歌曲页
// (见 playercatalog.go)。认不出这一首返回空。
func lxMusicPlayingCatalogIDs(artist, title string, durationSecs float64) playerCatalogIDs {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	t, _, _, ok := lxMusicCurrentTrack(ctx, artist, title, durationSecs)
	if !ok {
		return playerCatalogIDs{}
	}
	qq, netease := t.songPages()
	return playerCatalogIDs{songID: t.ID, qqSong: qq, neteaseSong: netease}
}

func (t lxMusicTrack) upcoming() upcomingTrack {
	return upcomingTrack{artist: t.Singer, title: t.Name, album: t.album(), duration: t.durationSecs()}
}

// lxMusicSameSong:列表里这一条是不是播放器报的这一首(歌名、歌手按缓存键那一套归一后相同)。
func lxMusicSameSong(t lxMusicTrack, artist, title string) bool {
	if strings.TrimSpace(t.Name) == "" {
		return false
	}
	return loosenEnrichKey(legacyEnrichKey(t.Singer, t.Name, "")) == loosenEnrichKey(legacyEnrichKey(artist, title, ""))
}

// lxMusicSQL 只读执行一句查询,-json 输出解进 out;没有行时 out 不动。
func lxMusicSQL(ctx context.Context, query string, out any) error {
	db := lxMusicDBPath()
	if db == "" {
		return os.ErrNotExist
	}
	if _, err := os.Stat(db); err != nil {
		return err
	}
	// net/url 组 URI:路径里的 #、?、%、空格要转义,不然 sqlite 按 URI 拆开,打开的是别的文件(同 queryQQLocalSongs)。
	uri := (&neturl.URL{Scheme: "file", Path: db, RawQuery: "mode=ro"}).String()
	raw, err := exec.CommandContext(ctx, "/usr/bin/sqlite3", "-json", uri, query).Output()
	if err != nil {
		if sqliteSchemaMismatch(err) {
			noteParserUnrecognized("lx-music-library", sqliteErrorDetail(err))
		}
		return err
	}
	if strings.TrimSpace(string(raw)) == "" {
		return nil
	}
	return json.Unmarshal(raw, out)
}

func lxMusicSQLString(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// lxMusicList 按播放顺序取一个列表的曲目。
func lxMusicList(ctx context.Context, listID string) ([]lxMusicTrack, error) {
	var tracks []lxMusicTrack
	err := lxMusicSQL(ctx, `SELECT m.id AS id, m.name AS name, m.singer AS singer, m.source AS source, `+
		`m.interval AS interval, m.meta AS meta FROM my_list_music_info_order o JOIN my_list_music_info m `+
		`ON m.id = o.musicInfoId AND m.listId = o.listId WHERE o.listId = `+lxMusicSQLString(listID)+
		` ORDER BY o."order"`, &tracks)
	return tracks, err
}

// lxMusicTracksNamed 在所有列表里按歌名找(歌手由调用方比)。
func lxMusicTracksNamed(ctx context.Context, title string) ([]lxMusicTrack, error) {
	var tracks []lxMusicTrack
	err := lxMusicSQL(ctx, `SELECT id, name, singer, source, interval, meta FROM my_list_music_info WHERE name = `+
		lxMusicSQLString(title), &tracks)
	return tracks, err
}

type lxMusicPlayInfo struct {
	ListID string `json:"listId"`
	Index  int    `json:"index"`
}

func lxMusicReadPlayInfo() (lxMusicPlayInfo, bool) {
	path := lxMusicStatePath()
	raw, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return lxMusicPlayInfo{}, false
	}
	var s struct {
		PlayInfo *lxMusicPlayInfo `json:"playInfo"`
	}
	if json.Unmarshal(raw, &s) != nil || s.PlayInfo == nil || s.PlayInfo.ListID == "" {
		return lxMusicPlayInfo{}, false
	}
	return *s.PlayInfo, true
}

// lxMusicPlayMethod:播放顺序设置,读不到当列表循环(洛雪的默认值)。
func lxMusicPlayMethod() string {
	path := lxMusicConfigPath()
	raw, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return "listLoop"
	}
	var c struct {
		Setting map[string]any `json:"setting"`
	}
	if json.Unmarshal(raw, &c) == nil {
		if m, ok := c.Setting["player.togglePlayMethod"].(string); ok && m != "" {
			return m
		}
	}
	return "listLoop"
}

// lxMusicDislike 是洛雪的「不喜欢」规则(dislike_list 表):按歌名、按歌手、按歌名加歌手三种。名字照洛雪的写法归一
// (lxMusicDislikeName),比较时两边都归一。
type lxMusicDislike struct {
	musicNames, singerNames, names map[string]bool
}

// lxMusicDislikeName:名字里的 @ 换成 #、转小写、去首尾空白,同洛雪 `filterRules` / `filterMusicList`。
func lxMusicDislikeName(s string) string {
	return strings.TrimSpace(strings.ToLower(strings.ReplaceAll(s, "@", "#")))
}

// lxMusicParseDislike 解 dislike_list 的 content:「歌名@歌手」「歌名」「@歌手」各一行一条,按 @ 拆成前两段。
func lxMusicParseDislike(contents []string) lxMusicDislike {
	d := lxMusicDislike{musicNames: map[string]bool{}, singerNames: map[string]bool{}, names: map[string]bool{}}
	for _, c := range contents {
		parts := strings.Split(c, "@")
		name, singer := parts[0], ""
		if len(parts) > 1 {
			singer = parts[1]
		}
		switch {
		case name != "" && singer != "":
			d.names[lxMusicDislikeName(name)+"@"+lxMusicDislikeName(singer)] = true
		case name != "":
			d.musicNames[lxMusicDislikeName(name)] = true
		case singer != "":
			d.singerNames[lxMusicDislikeName(singer)] = true
		}
	}
	return d
}

// lxMusicReadDislike 读「不喜欢」规则;没有这张表、读不动当没有。
func lxMusicReadDislike(ctx context.Context) lxMusicDislike {
	var rows []struct {
		Content string `json:"content"`
	}
	if err := lxMusicSQL(ctx, `SELECT content FROM dislike_list`, &rows); err != nil {
		return lxMusicParseDislike(nil)
	}
	contents := make([]string, 0, len(rows))
	for _, r := range rows {
		contents = append(contents, r.Content)
	}
	return lxMusicParseDislike(contents)
}

func (d lxMusicDislike) matches(t lxMusicTrack) bool {
	name, singer := lxMusicDislikeName(t.Name), lxMusicDislikeName(t.Singer)
	return d.musicNames[name] || d.singerNames[singer] || d.names[name+"@"+singer]
}

// filter 去掉列表里洛雪不会放的(命中规则的),pos 那一首(在放的)留着,返回新列表和它在新列表里的下标。除了在放的
// 一首都不剩时照旧用整个列表:洛雪那时也不滤。
func (d lxMusicDislike) filter(list []lxMusicTrack, pos int) ([]lxMusicTrack, int) {
	if len(d.musicNames)+len(d.singerNames)+len(d.names) == 0 {
		return list, pos
	}
	out := make([]lxMusicTrack, 0, len(list))
	newPos := -1
	for i, t := range list {
		if i == pos {
			newPos = len(out)
			out = append(out, t)
		} else if !d.matches(t) {
			out = append(out, t)
		}
	}
	if len(out) <= 1 {
		return list, pos
	}
	return out, newPos
}

// lxMusicCurrentTrack:洛雪此刻在放的这一首,连同它所在的列表和下标(不在 playInfo 那个列表里时 list 为空、pos 为 -1)。
// playInfo 指的那一条名字对得上就是它;对不上(换歌后 playInfo 还没写盘)就在 playInfo 那个列表里按名字找;再找不到在所有
// 列表里找,不止一条时取登记时长最接近 durationSecs 的。
func lxMusicCurrentTrack(ctx context.Context, artist, title string, durationSecs float64) (track lxMusicTrack, list []lxMusicTrack, pos int, ok bool) {
	if info, found := lxMusicReadPlayInfo(); found {
		if tracks, err := lxMusicList(ctx, info.ListID); err == nil {
			if info.Index >= 0 && info.Index < len(tracks) && lxMusicSameSong(tracks[info.Index], artist, title) {
				return tracks[info.Index], tracks, info.Index, true
			}
			for i, t := range tracks {
				if lxMusicSameSong(t, artist, title) {
					return t, tracks, i, true
				}
			}
		}
	}
	named, err := lxMusicTracksNamed(ctx, title)
	if err != nil {
		return lxMusicTrack{}, nil, -1, false
	}
	best, bestDiff := -1, 0.0
	for i, t := range named {
		if !lxMusicSameSong(t, artist, title) {
			continue
		}
		diff := 0.0
		if durationSecs > 0 && t.durationSecs() > 0 {
			diff = max(durationSecs-t.durationSecs(), t.durationSecs()-durationSecs)
		}
		if best < 0 || diff < bestDiff {
			best, bestDiff = i, diff
		}
	}
	if best < 0 {
		return lxMusicTrack{}, nil, -1, false
	}
	return named[best], nil, -1, true
}

// lxMusicResumePoint 是 data.json 记的那一首和它所在的列表。放「稍后播放」里的歌时洛雪不改这份记录。
func lxMusicResumePoint(ctx context.Context) ([]lxMusicTrack, int, bool) {
	info, found := lxMusicReadPlayInfo()
	if !found {
		return nil, -1, false
	}
	tracks, err := lxMusicList(ctx, info.ListID)
	if err != nil || info.Index < 0 || info.Index >= len(tracks) {
		return nil, -1, false
	}
	return tracks, info.Index, true
}

// lxMusicAwaitsDuration:洛雪换歌先报新歌名、时长 0,约 0.6 秒后才补上时长。拿 0 去首次解析,打分里时长那几项都用不上,
// 自报时长对不上的也罚不到;这一拍先不起,下一拍有了时长再起。
func lxMusicAwaitsDuration(bundleID string, durationSecs float64) bool {
	return bundleID == lxMusicBundleID && durationSecs <= 0
}

// lxMusicLyricSet 是 lyric 表里一首的几份歌词(已解开 base64)。
type lxMusicLyricSet struct {
	lrc, tr, roma, word string
}

// lxMusicLyrics 取一首放过的歌的歌词;用户改过的(edited)整套优先。
func lxMusicLyrics(ctx context.Context, id string) (lxMusicLyricSet, bool) {
	var rows []struct {
		Type   string `json:"type"`
		Source string `json:"source"`
		Text   string `json:"text"`
	}
	if err := lxMusicSQL(ctx, `SELECT type, source, text FROM lyric WHERE id = `+lxMusicSQLString(id), &rows); err != nil {
		return lxMusicLyricSet{}, false
	}
	pick := func(source string) (lxMusicLyricSet, bool) {
		var s lxMusicLyricSet
		for _, r := range rows {
			if r.Source != source {
				continue
			}
			text, err := base64.StdEncoding.DecodeString(strings.TrimSpace(r.Text))
			if err != nil {
				continue
			}
			switch r.Type {
			case "lyric":
				s.lrc = string(text)
			case "tlyric":
				s.tr = string(text)
			case "rlyric":
				s.roma = string(text)
			case "lxlyric":
				s.word = string(text)
			}
		}
		return s, strings.TrimSpace(s.lrc) != ""
	}
	s, ok := pick("edited")
	if !ok {
		s, ok = pick("raw")
	}
	s.lrc, s.word = lxMusicStripMetaLines(s.lrc), lxMusicStripMetaLines(s.word)
	return s, ok
}

// lxMusicStripMetaLines 剥掉洛雪歌词开头那两行没有冒号的元数据(「歌曲名 天天」「歌手名 陶喆」,跟咪咕同一个形状,
// 认法同 miguMetaLineRe);逐字那份去掉 `<毫秒,时长>` 标记再认。别的行原样留着。见 08 章决策 56。
func lxMusicStripMetaLines(text string) string {
	if text == "" {
		return text
	}
	lines := strings.Split(text, "\n")
	kept := lines[:0]
	for _, line := range lines {
		bare := strings.TrimSpace(metaLineTimestampRe.ReplaceAllString(lxMusicWordRe.ReplaceAllString(line, ""), ""))
		if bare != "" && miguMetaLineRe.MatchString(bare) {
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}

var (
	lxMusicWordLineRe = regexp.MustCompile(`^\[(\d+):(\d+)(?:\.(\d{1,3}))?\](.*)$`)
	lxMusicWordRe     = regexp.MustCompile(`<(\d+),(\d+)>`)
)

// lxMusicWordsToYRC 把洛雪的逐字格式(`[mm:ss.xxx]<相对行首的毫秒,时长>字…`)转成 YRC:`[行始,行长](词始,词长,0)词…`,
// 词始为绝对毫秒。后一个字的起点早于前一个字的终点时把前一个截到后一个的起点;一行没有逐字标记或没有文字的丢掉。
func lxMusicWordsToYRC(text string) string {
	text = strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n")
	type word struct {
		start, end int
		text       string
	}
	var out []string
	for _, line := range strings.Split(text, "\n") {
		m := lxMusicWordLineRe.FindStringSubmatch(strings.TrimSpace(line))
		if m == nil {
			continue
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
		lineStart := (mm*60+ss)*1000 + frac
		body := m[4]
		locs := lxMusicWordRe.FindAllStringSubmatchIndex(body, -1)
		if len(locs) == 0 {
			continue
		}
		var words []word
		for i, loc := range locs {
			off, _ := strconv.Atoi(body[loc[2]:loc[3]])
			dur, _ := strconv.Atoi(body[loc[4]:loc[5]])
			end := len(body)
			if i+1 < len(locs) {
				end = locs[i+1][0]
			}
			start := lineStart + off
			if n := len(words); n > 0 && start < words[n-1].end {
				words[n-1].end = max(start, words[n-1].start)
			}
			words = append(words, word{start: start, end: start + dur, text: body[loc[1]:end]})
		}
		hasText, lineEnd := false, lineStart
		for _, w := range words {
			hasText = hasText || strings.TrimSpace(w.text) != ""
			lineEnd = max(lineEnd, w.end)
		}
		if !hasText {
			continue
		}
		var b strings.Builder
		fmt.Fprintf(&b, "[%d,%d]", lineStart, lineEnd-lineStart)
		for _, w := range words {
			fmt.Fprintf(&b, "(%d,%d,0)%s", w.start, w.end-w.start, w.text)
		}
		out = append(out, b.String())
	}
	if len(out) == 0 {
		return ""
	}
	merged, _ := yrcMergeWhitespaceTokens(strings.Join(out, "\n"))
	return merged
}

// lxMusicLocalLyricsFor 给歌词检索用:正在用洛雪放歌时才读,换成一份跟各歌词源同形的原始应答。身份是洛雪列表里这一条
// 的平台曲目 id,歌词是它从那个平台拉下来的原版,置 identityFromLocalClient。
func lxMusicLocalLyricsFor(ctx context.Context, artist, title string, durationSecs float64) (lyricSourceResult, bool) {
	if !isNativeLyricSource(lxMusicLocalLyricsSource) {
		return lyricSourceResult{}, false
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	if t, _, _, ok := lxMusicCurrentTrack(ctx, artist, title, durationSecs); ok {
		if set, found := lxMusicLyrics(ctx, t.ID); found {
			return lyricSourceResult{
				source: lxMusicLocalLyricsSource, lyr: set.lrc, yrc: lxMusicWordsToYRC(set.word), tr: set.tr, roma: set.roma,
				matchTitle: t.Name, matchArtist: t.Singer, matchAlbum: t.album(), srcDur: t.durationSecs(),
				identityFromLocalClient: true,
			}, true
		}
	}
	set, st, ok := lxMusicOpenAPILyrics(ctx, artist, title)
	if !ok {
		return lyricSourceResult{}, false
	}
	log.Printf("lxmusic: lyrics for %s - %s from the open API (not in the local library)", st.Singer, st.Name)
	return lyricSourceResult{
		source: lxMusicLocalLyricsSource, lyr: set.lrc, yrc: lxMusicWordsToYRC(set.word), tr: set.tr, roma: set.roma,
		matchTitle: st.Name, matchArtist: st.Singer, matchAlbum: strings.TrimSpace(st.AlbumName), srcDur: st.Duration,
		identityFromLocalClient: true,
	}, true
}

// lxMusicOpenAPIStatus 是开放 API `/status` 回的那几项。
type lxMusicOpenAPIStatus struct {
	Name      string  `json:"name"`
	Singer    string  `json:"singer"`
	AlbumName string  `json:"albumName"`
	Duration  float64 `json:"duration"`
}

// lxMusicOpenAPIBaseOverride 让单测把开放 API 指到测试服务器。空 = 按洛雪配置里的端口连本机。
var lxMusicOpenAPIBaseOverride string

// lxMusicOpenAPIClient 只连本机,不走代理。
var lxMusicOpenAPIClient = &http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{Proxy: nil}}

// lxMusicOpenAPIPort:洛雪设置里开了开放 API 时它听的端口(端口认不出按默认 23330,同 App 的 LXMusicOpenAPI.config);
// 没开、读不到为 0。
func lxMusicOpenAPIPort() int {
	path := lxMusicConfigPath()
	raw, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return 0
	}
	var c struct {
		Setting map[string]any `json:"setting"`
	}
	if json.Unmarshal(raw, &c) != nil {
		return 0
	}
	if on, _ := c.Setting["openAPI.enable"].(bool); !on {
		return 0
	}
	port := 0
	switch v := c.Setting["openAPI.port"].(type) {
	case float64:
		port = int(v)
	case string:
		port, _ = strconv.Atoi(strings.TrimSpace(v))
	}
	if port < 1 || port > 65535 {
		return 23330
	}
	return port
}

func lxMusicOpenAPIGet(ctx context.Context, path string, out any) error {
	base := lxMusicOpenAPIBaseOverride
	if base == "" {
		port := lxMusicOpenAPIPort()
		if port == 0 {
			return os.ErrNotExist
		}
		base = fmt.Sprintf("http://127.0.0.1:%d", port)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+path, nil)
	if err != nil {
		return err
	}
	resp, err := lxMusicOpenAPIClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("lx open api %s: status %d", path, resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(out)
}

// lxMusicOpenAPILyrics:用户打开了洛雪的开放 API 时,它此刻在放的这首的歌词(`/lyric-all`,明文,跟本地库 lyric 表同一套)。
// 本地库里找不到这首(从搜索结果点播、不在任何列表里)或还没写进去时用。问歌词前后各问一次 `/status`,两次都是这一首才算,
// 免得中间换了歌拿到别的歌词。没开、连不上、没词时 ok 为假。
func lxMusicOpenAPILyrics(ctx context.Context, artist, title string) (lxMusicLyricSet, lxMusicOpenAPIStatus, bool) {
	const statusPath = "/status?filter=name,singer,albumName,duration"
	same := func(s lxMusicOpenAPIStatus) bool {
		return strings.TrimSpace(s.Name) != "" && lxMusicSameSong(lxMusicTrack{Name: s.Name, Singer: s.Singer}, artist, title)
	}
	var before lxMusicOpenAPIStatus
	if lxMusicOpenAPIGet(ctx, statusPath, &before) != nil || !same(before) {
		return lxMusicLyricSet{}, lxMusicOpenAPIStatus{}, false
	}
	var all struct {
		Lyric   string `json:"lyric"`
		Tlyric  string `json:"tlyric"`
		Rlyric  string `json:"rlyric"`
		Lxlyric string `json:"lxlyric"`
	}
	if lxMusicOpenAPIGet(ctx, "/lyric-all", &all) != nil || strings.TrimSpace(all.Lyric) == "" {
		return lxMusicLyricSet{}, lxMusicOpenAPIStatus{}, false
	}
	var after lxMusicOpenAPIStatus
	if lxMusicOpenAPIGet(ctx, statusPath, &after) != nil || after.Name != before.Name || after.Singer != before.Singer {
		return lxMusicLyricSet{}, lxMusicOpenAPIStatus{}, false
	}
	return lxMusicLyricSet{lrc: lxMusicStripMetaLines(all.Lyric), tr: all.Tlyric, roma: all.Rlyric, word: lxMusicStripMetaLines(all.Lxlyric)}, before, true
}

const (
	lxMusicLyricsFoundTTL      = 30 * time.Second
	lxMusicLyricsMissingTTL    = 5 * time.Second
	lxMusicLyricsMissingMaxTTL = time.Minute
)

// lxMusicLyricsAvail:一首的结论记到什么时候;misses 是同一首接连几次查到没有。
type lxMusicLyricsAvail struct {
	until  time.Time
	ok     bool
	misses int
}

// lxMusicLyricsMissingTTLFor:接连第 misses 次查到没有,这次的结论记多久。从几秒起步(洛雪开播后才去拉词,刚开播时
// 要尽快发现),每多落空一次翻一倍,封顶一分钟 —— 这首洛雪一直没词时,每一拍都要起几个 sqlite3 子进程、
// 开了开放 API 还要再问三次,不能每几秒就来一遍。
func lxMusicLyricsMissingTTLFor(misses int) time.Duration {
	ttl := lxMusicLyricsMissingTTL
	for i := 1; i < misses && ttl < lxMusicLyricsMissingMaxTTL; i++ {
		ttl *= 2
	}
	return min(ttl, lxMusicLyricsMissingMaxTTL)
}

var (
	lxMusicLyricsAvailMu   sync.Mutex
	lxMusicLyricsAvailMemo = map[string]lxMusicLyricsAvail{}
)

// lxMusicLyricsAvailable:正用洛雪放的这首,它本地现在有没有词(见 lxMusicLyricsWorthRecheck)。洛雪开播时才去拉词,
// 首次解析常常先跑完,所以没有的结论先只记几秒、接连落空就越记越久(lxMusicLyricsMissingTTLFor),有的记半分钟。
func lxMusicLyricsAvailable(bundleID, artist, title string, durationSecs float64) bool {
	if bundleID != lxMusicBundleID {
		return false
	}
	key := artist + "\x00" + title
	now := time.Now()
	lxMusicLyricsAvailMu.Lock()
	prev, seen := lxMusicLyricsAvailMemo[key]
	if seen && now.Before(prev.until) {
		lxMusicLyricsAvailMu.Unlock()
		return prev.ok
	}
	lxMusicLyricsAvailMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	ok := false
	if t, _, _, found := lxMusicCurrentTrack(ctx, artist, title, durationSecs); found {
		_, ok = lxMusicLyrics(ctx, t.ID)
	}
	if !ok {
		_, _, ok = lxMusicOpenAPILyrics(ctx, artist, title)
	}
	ttl, misses := lxMusicLyricsFoundTTL, 0
	if !ok {
		misses = 1
		if seen && !prev.ok {
			misses = prev.misses + 1
		}
		ttl = lxMusicLyricsMissingTTLFor(misses)
	}
	lxMusicLyricsAvailMu.Lock()
	for k, m := range lxMusicLyricsAvailMemo {
		if now.After(m.until) {
			delete(lxMusicLyricsAvailMemo, k)
		}
	}
	lxMusicLyricsAvailMemo[key] = lxMusicLyricsAvail{until: now.Add(ttl), ok: ok, misses: misses}
	lxMusicLyricsAvailMu.Unlock()
	return ok
}

// lxMusicLyricsRechecked:这次进程里已经为洛雪本地歌词重来过的条目。只在 enrichMu 里读写。
var lxMusicLyricsRechecked = map[string]bool{}

// lxMusicLyricsRecheckOnce:同 kkboxLyricsRecheckOnce。调用方持有 enrichMu。
func lxMusicLyricsRecheckOnce(key string) bool {
	if lxMusicLyricsRechecked[key] {
		return false
	}
	lxMusicLyricsRechecked[key] = true
	return true
}

// lxMusicLyricsWorthRecheck:同 amazonLyricsWorthRecheck。条目当初没见过洛雪本地歌词那份候选(预解析过、首次解析比洛雪
// 拉词先跑完、当初不是用洛雪放的),现在正用它放、本地有词 → 值得重来一次(retryLyricsUpgrade,分数严格更高才替换)。
func lxMusicLyricsWorthRecheck(e enrichEntry, bundleID string, pinned, autoUpgrade, available bool) bool {
	if bundleID != lxMusicBundleID || !autoUpgrade || pinned || e.ManualLyrics || e.Instrumental || !available {
		return false
	}
	if slices.Contains(e.LyricsSourcesSeen, lxMusicLocalLyricsSource) || slices.Contains(e.LyricsSourcesResponded, lxMusicLocalLyricsSource) {
		return false
	}
	if e.LyricsDecision != nil && slices.Contains(e.LyricsDecision.SourcesResponded, lxMusicLocalLyricsSource) {
		return false
	}
	return e.LyricsRetryCount < lyricsRetryMaxAttempts
}

// lxMusicUpcoming 是洛雪接下来会放的几首:当前这首所在列表,按播放顺序设置往后取。随机时按 shuffleCandidates 交一批;
// 单曲循环、播完停止时没有下一首。「稍后播放」那份只在洛雪内存里,读不到;当前这首哪个列表里都没有时多半就是它,
// 洛雪放完那几首回到 data.json 记的那一首往后接着放,从那里往后取。排在列表前面的依次是:这一首快放完时洛雪预加载的
// 下一首(lxMusicPreloadedNext,随机、「稍后播放」时它才是真正的下一首),从 Lyrimuse 加进「稍后播放」还没放到的那几首
// (lxMusicPlayLaterQueued)。列表那部分跳过洛雪不会放的「不喜欢」(lxMusicDislike)。
func lxMusicUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cur, list, pos, ok := lxMusicCurrentTrack(ctx, artist, title, 0)
	next, preloaded := lxMusicPreloadedNext(ctx, artist, title, cur.ID)
	if !ok {
		list, pos, ok = lxMusicResumePoint(ctx)
	}
	var res []upcomingTrack
	if ok && pos >= 0 {
		res = lxMusicListUpcoming(list, pos, n, lxMusicReadDislike(ctx))
	}
	var head []upcomingTrack
	if preloaded {
		head = append(head, next.upcoming())
	}
	for _, t := range lxMusicPlayLaterQueued(artist, title, time.Now()) {
		if !slices.ContainsFunc(head, func(h upcomingTrack) bool { return h.title == t.title && h.artist == t.artist }) {
			head = append(head, t)
		}
	}
	if len(head) > 0 {
		out := slices.Clone(head[:min(len(head), n)])
		for _, t := range res {
			if len(out) < n && !slices.ContainsFunc(head, func(h upcomingTrack) bool { return h.title == t.title && h.artist == t.artist }) {
				out = append(out, t)
			}
		}
		return out, true
	}
	if !ok || pos < 0 {
		return nil, false
	}
	return res, true
}

// lxMusicListUpcoming 是列表里 pos 那一首之后按播放顺序设置会放的几首,命中「不喜欢」的不算。
func lxMusicListUpcoming(list []lxMusicTrack, pos, n int, dislike lxMusicDislike) []upcomingTrack {
	list, pos = dislike.filter(list, pos)
	at := func(i int) (upcomingTrack, bool) {
		t := list[i]
		return t.upcoming(), strings.TrimSpace(t.Name) != "" && strings.TrimSpace(t.Singer) != ""
	}
	method := lxMusicPlayMethod()
	switch method {
	case "singleLoop", "none":
		return nil
	case "random":
		return shuffleCandidates(len(list), pos, at)
	}
	var res []upcomingTrack
	for k := 1; k < len(list) && len(res) < n; k++ {
		i := pos + k
		if i >= len(list) {
			if method == "list" {
				break
			}
			i %= len(list)
		}
		if t, ok := at(i); ok {
			res = append(res, t)
		}
	}
	return res
}

var (
	lxMusicPreloadMu sync.Mutex
	// lxMusicPreloadKey 是记下基线时在放的那一首(歌手|歌名),lxMusicPreloadBaseline 是那时 music_url 表最大的 rowid。
	lxMusicPreloadKey      string
	lxMusicPreloadBaseline int64
	// lxMusicPreloadLogged 是最近记过日志的那一行的 rowid,同一行不重复记。
	lxMusicPreloadLogged int64
)

// lxMusicPreloadedNext 是这一首快放完时洛雪预加载的下一首。洛雪在每首最后 10 秒取下一首的播放地址
// (`usePreloadNextMusic.ts`),地址没缓存、或缓存的地址失效了,就往 music_url 表写一行。这一首第一次问的时候记下
// 表里最大的 rowid 当基线,之后新写的、不是这一首的那行就是下一首,按 id 回列表里找歌名(实测开播前 9.7 秒写下)。
// 地址缓存还有效时不写,看不到;id 不在任何列表里(从搜索结果加进「稍后播放」的)时没有歌名,也不给。见 09 章决策 262。
func lxMusicPreloadedNext(ctx context.Context, artist, title, currentID string) (lxMusicTrack, bool) {
	var rows []lxMusicURLRow
	if err := lxMusicSQL(ctx, `SELECT rowid AS rowid, id FROM music_url ORDER BY rowid DESC LIMIT 1`, &rows); err != nil {
		return lxMusicTrack{}, false
	}
	var row lxMusicURLRow
	if len(rows) > 0 {
		row = rows[0]
	}
	key := legacyEnrichKey(artist, title, "")
	lxMusicPreloadMu.Lock()
	if lxMusicPreloadKey != key {
		lxMusicPreloadKey, lxMusicPreloadBaseline = key, row.RowID
		lxMusicPreloadMu.Unlock()
		return lxMusicTrack{}, false
	}
	fresh := row.RowID > lxMusicPreloadBaseline
	firstLook := row.RowID != lxMusicPreloadLogged
	lxMusicPreloadLogged = row.RowID
	lxMusicPreloadMu.Unlock()
	id := lxMusicURLSongID(row.ID)
	if !fresh || id == "" || id == currentID {
		return lxMusicTrack{}, false
	}
	var tracks []lxMusicTrack
	err := lxMusicSQL(ctx, `SELECT id, name, singer, source, interval, meta FROM my_list_music_info WHERE id = `+
		lxMusicSQLString(id)+` LIMIT 1`, &tracks)
	if err != nil || len(tracks) == 0 || strings.TrimSpace(tracks[0].Name) == "" {
		if firstLook {
			log.Printf("lxmusic: preloaded next %s is in no list, no title to prefetch", id)
		}
		return lxMusicTrack{}, false
	}
	if firstLook {
		log.Printf("lxmusic: preloaded next %s = %s - %s", id, tracks[0].Singer, tracks[0].Name)
	}
	return tracks[0], true
}

// lxMusicCoverURL 是洛雪列表里这一首记着的封面(meta.picUrl,洛雪放的时候取到才写进去),换成 Discord 认的 https。
// 见 09 章决策 263。
func lxMusicCoverURL(artist, title string, durationSecs float64) string {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	t, _, _, ok := lxMusicCurrentTrack(ctx, artist, title, durationSecs)
	if !ok {
		return ""
	}
	var meta struct {
		PicURL string `json:"picUrl"`
	}
	if json.Unmarshal([]byte(t.Meta), &meta) != nil {
		return ""
	}
	return lxMusicHTTPSCover(meta.PicURL)
}

// lxMusicKuwoImageHost 是酷我那几个同时认 https 的图床(img1~img4.kuwo.cn)。
var lxMusicKuwoImageHost = regexp.MustCompile(`^img\d\.kuwo\.cn$`)

// lxMusicHTTPSCover 把洛雪记的封面地址换成 https:各家图床逐个核过 https 下同一路径给的是同一张图;img1.kwcdn.kuwo.cn
// 不认 https,同一路径在 img1.kuwo.cn 上是同一张(字节一致)。咪咕记的多是不带主机的「/data/oss/…」,补成 d.musicapp.migu.cn。
// 没核过的图床不给。
func lxMusicHTTPSCover(raw string) string {
	raw = strings.TrimSpace(raw)
	if strings.HasPrefix(raw, "/data/oss/") {
		raw = "https://d.musicapp.migu.cn" + raw
	}
	u, err := neturl.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return ""
	}
	switch host := strings.ToLower(u.Hostname()); {
	case host == "img1.kwcdn.kuwo.cn":
		u.Host = "img1.kuwo.cn"
	case lxMusicKuwoImageHost.MatchString(host), host == "imge.kugou.com", host == "y.gtimg.cn",
		host == "d.musicapp.migu.cn", strings.HasSuffix(host, ".music.126.net"):
	default:
		return ""
	}
	u.Scheme = "https"
	return u.String()
}

// lxMusicURLRow 是 music_url 表的一行(播放地址本身不读)。
type lxMusicURLRow struct {
	RowID int64  `json:"rowid"`
	ID    string `json:"id"`
}

// lxMusicURLSongID 把 music_url 的 id(「曲目 id_音质」,kw_168143592_128k)还原成曲目 id。
func lxMusicURLSongID(urlID string) string {
	i := strings.LastIndex(urlID, "_")
	if i <= 0 || !strings.Contains(urlID[:i], "_") {
		return ""
	}
	return urlID[:i]
}

// lxMusicQueueStamp 是洛雪本地库此刻的改写标记(WAL 和主文件的修改时间)加上 App 记的「稍后播放」文件的修改时间:
// 预加载往 music_url 写了一行、用户从 Lyrimuse 加了一首,它就变,upcoming.go 据此重读一次接下来那几首。
func lxMusicQueueStamp() string {
	db := lxMusicDBPath()
	if db == "" {
		return ""
	}
	return fmt.Sprintf("%d/%d/%d", fileModTime(db+"-wal").UnixNano(), fileModTime(db).UnixNano(),
		fileModTime(lxMusicPlayLaterPath()).UnixNano())
}

// lxMusicPlayLaterTTL:App 记下的「稍后播放」超过这么久还没放到就不算(多半被洛雪清掉了,或洛雪重开过,那个队列只在它内存里)。
const lxMusicPlayLaterTTL = 6 * time.Hour

// lxMusicPlayLaterPathOverride 让单测把「稍后播放」文件指到临时目录。空 = 配置目录里那份。
var lxMusicPlayLaterPathOverride string

// lxMusicPlayLaterPath 是 App 写的「从 Lyrimuse 加进洛雪『稍后播放』的那几首」(LXMusicPlayLater.swift;形状两边一起改,
// 样例 shared/testdata/lx-play-later.json 两边测试各读一遍)。
func lxMusicPlayLaterPath() string {
	if lxMusicPlayLaterPathOverride != "" {
		return lxMusicPlayLaterPathOverride
	}
	return configFilePath(clientName + "-lx-play-later.json")
}

type lxMusicPlayLaterFile struct {
	Schema int `json:"schema"`
	Tracks []struct {
		Title     string `json:"title"`
		Artist    string `json:"artist"`
		Album     string `json:"album"`
		AddedAtMs int64  `json:"added_at_ms"`
	} `json:"tracks"`
}

// lxMusicPlayLaterQueued 是从 Lyrimuse 加进洛雪「稍后播放」、还没放到的那几首,按加的先后(洛雪按这个顺序放)。
// 正在放的这首、超过 lxMusicPlayLaterTTL 的不算;放到的由 App 从文件里删掉。没有文件、解不开当没有。
func lxMusicPlayLaterQueued(artist, title string, now time.Time) []upcomingTrack {
	path := lxMusicPlayLaterPath()
	raw, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return nil
	}
	var f lxMusicPlayLaterFile
	if json.Unmarshal(raw, &f) != nil || f.Schema != 1 {
		return nil
	}
	var out []upcomingTrack
	for _, t := range f.Tracks {
		if strings.TrimSpace(t.Title) == "" || strings.TrimSpace(t.Artist) == "" ||
			now.Sub(time.UnixMilli(t.AddedAtMs)) > lxMusicPlayLaterTTL ||
			lxMusicSameSong(lxMusicTrack{Name: t.Title, Singer: t.Artist}, artist, title) {
			continue
		}
		out = append(out, upcomingTrack{artist: t.Artist, title: t.Title, album: strings.TrimSpace(t.Album)})
	}
	return out
}
