package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// iPad 版网易云(iOS 应用跑在 Apple 芯片 Mac 上,bundle id com.netease.cloudmusic;App 按网易云 Mac 版认)的本地数据跟 Mac 版
// 不是一套:没有 playingList。此刻放的这一项记在容器里 music_storage_keyValue.sqlite3 的 miniBarLastPlay 表,每开播一首、一集
// (含单曲循环重开)改写这一行,比系统报这一项早 0.3～0.5 秒。这一行是 JSON 数组,第一个元素的 rawJsonString 是整条曲目 JSON
// (id、name、ar、al、duration;节目多一个非空的 clientDjProgram,ar 是主播)。
//
// 引擎拿它做两件事:放的是节目时写一份单集名单 lyrimuse-netease-ipad-episodes.json(约定同 neteasepodcast.go 的名单,
// App 两份一起认);Mac 版队列里认不出这首时,按它给出歌曲 id(neteasePlayingSong / neteasePlayingTrack)。见 02 章决策 199。

// neteaseIPadKVOverride 让单测把库指到临时路径。空 = 用真实路径。
var neteaseIPadKVOverride string

func neteaseIPadKVPath() string {
	if neteaseIPadKVOverride != "" {
		return neteaseIPadKVOverride
	}
	return homeSubdir("Library/Containers/com.netease.cloudmusic/Data/Documents/UserData/music_storage_keyValue.sqlite3")
}

const neteaseIPadNowPlayingSQL = "SELECT json FROM miniBarLastPlay LIMIT 1"

// neteaseIPadItem 是 miniBarLastPlay 记的那一项里用得上的字段。
type neteaseIPadItem struct {
	ID   string
	Name string
	// Aliases:别名;系统那份 title 报成「歌名 (别名)」。
	Aliases    []string
	Artists    []string
	AlbumID    string
	AlbumName  string
	AlbumPic   string
	DurationMs float64
	Mark       int64
	// Program:是播客 / 有声书的一集(clientDjProgram 非空)。
	Program bool
}

// neteaseIPadItemFromRow 解 miniBarLastPlay 的 json 列;不是这种形状返回 false。
func neteaseIPadItemFromRow(raw string) (neteaseIPadItem, bool) {
	var outer []string
	if err := json.Unmarshal([]byte(raw), &outer); err != nil || len(outer) == 0 {
		return neteaseIPadItem{}, false
	}
	var wrap struct {
		RawJSONString string `json:"rawJsonString"`
	}
	if err := json.Unmarshal([]byte(outer[0]), &wrap); err != nil || wrap.RawJSONString == "" {
		return neteaseIPadItem{}, false
	}
	var song struct {
		ID   json.RawMessage `json:"id"`
		Name string          `json:"name"`
		Ar   []struct {
			Name string `json:"name"`
		} `json:"ar"`
		Al struct {
			ID     json.RawMessage `json:"id"`
			Name   string          `json:"name"`
			PicURL string          `json:"picUrl"`
		} `json:"al"`
		Alias           []string                   `json:"alias"`
		Duration        float64                    `json:"duration"`
		Mark            int64                      `json:"mark"`
		ClientDjProgram map[string]json.RawMessage `json:"clientDjProgram"`
	}
	if err := json.Unmarshal([]byte(wrap.RawJSONString), &song); err != nil || song.Name == "" {
		return neteaseIPadItem{}, false
	}
	it := neteaseIPadItem{
		ID: rawDigitsID(song.ID), Name: song.Name, AlbumID: rawDigitsID(song.Al.ID),
		AlbumName: song.Al.Name, AlbumPic: song.Al.PicURL, DurationMs: song.Duration, Mark: song.Mark,
		Program: len(song.ClientDjProgram) > 0,
	}
	for _, a := range song.Alias {
		if a = strings.TrimSpace(a); a != "" {
			it.Aliases = append(it.Aliases, a)
		}
	}
	for _, a := range song.Ar {
		if a.Name != "" {
			it.Artists = append(it.Artists, a.Name)
		}
	}
	return it, true
}

// neteaseIPadQueryNowPlaying 读 miniBarLastPlay 那一行。库是 WAL 模式,先按 mode=ro 打开(读得到还没并回主库的新内容);
// 客户端退出时删掉了 -wal / -shm 的话只读连接打不开,这时 WAL 里没有东西,改用 immutable=1。别退回读写连接:那会在它的容器里建文件。
func neteaseIPadQueryNowPlaying(path string) (neteaseIPadItem, error) {
	out, err := neteaseIPadQuery(path, "mode=ro")
	if err != nil {
		if _, walErr := os.Stat(path + "-wal"); walErr == nil {
			return neteaseIPadItem{}, err
		}
		if out, err = neteaseIPadQuery(path, "immutable=1"); err != nil {
			return neteaseIPadItem{}, err
		}
	}
	var rows []struct {
		JSON string `json:"json"`
	}
	trimmed := bytes.TrimSpace(out)
	// sqlite3 -json 对零行输出空串,不是 "[]"。
	if len(trimmed) == 0 {
		return neteaseIPadItem{}, errNeteaseIPadNoItem
	}
	if err := json.Unmarshal(trimmed, &rows); err != nil || len(rows) == 0 {
		return neteaseIPadItem{}, errNeteaseIPadNoItem
	}
	it, ok := neteaseIPadItemFromRow(rows[0].JSON)
	if !ok {
		noteParserUnrecognized("netease-ipad-now-playing", "miniBarLastPlay row")
		return neteaseIPadItem{}, errNeteaseIPadNoItem
	}
	noteParserRecognized("netease-ipad-now-playing")
	return it, nil
}

var errNeteaseIPadNoItem = errors.New("no recognisable miniBarLastPlay row")

func neteaseIPadQuery(path, query string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), neteaseLocalQueryTimeout)
	defer cancel()
	// 路径里可能带空格,用 net/url 组 URI 才会转义。
	uri := (&neturl.URL{Scheme: "file", Path: path, RawQuery: query}).String()
	return exec.CommandContext(ctx, "/usr/bin/sqlite3", "-json", uri, neteaseIPadNowPlayingSQL).Output()
}

// neteaseIPadStamp:库和 -wal 的修改时间、大小,两份都没变就是那一行没变。
type neteaseIPadStamp struct {
	dbMod, walMod   time.Time
	dbSize, walSize int64
}

func neteaseIPadStampOf(path string) (neteaseIPadStamp, error) {
	st, err := os.Stat(path)
	if err != nil {
		return neteaseIPadStamp{}, err
	}
	s := neteaseIPadStamp{dbMod: st.ModTime(), dbSize: st.Size()}
	if wal, err := os.Stat(path + "-wal"); err == nil {
		s.walMod, s.walSize = wal.ModTime(), wal.Size()
	}
	return s, nil
}

var (
	neteaseIPadMu        sync.Mutex
	neteaseIPadSeenPath  string
	neteaseIPadSeenStamp neteaseIPadStamp
	neteaseIPadSeenItem  neteaseIPadItem
	neteaseIPadSeenOK    bool
)

// neteaseIPadNowPlaying 是 iPad 版此刻记的那一项;库和 -wal 都没变时用上一次读到的。没装、没授权、读不出时 ok=false。
func neteaseIPadNowPlaying() (neteaseIPadItem, bool) {
	path := neteaseIPadKVPath()
	if path == "" {
		return neteaseIPadItem{}, false
	}
	stamp, err := neteaseIPadStampOf(path)
	if err != nil {
		noteLocalCacheDenied("netease", path, err)
		return neteaseIPadItem{}, false
	}
	neteaseIPadMu.Lock()
	defer neteaseIPadMu.Unlock()
	if neteaseIPadSeenPath == path && neteaseIPadSeenStamp == stamp {
		return neteaseIPadSeenItem, neteaseIPadSeenOK
	}
	it, err := neteaseIPadQueryNowPlaying(path)
	neteaseIPadSeenPath, neteaseIPadSeenStamp, neteaseIPadSeenItem, neteaseIPadSeenOK = path, stamp, it, err == nil
	if err == nil {
		noteLocalCacheReadable("netease")
	}
	return it, err == nil
}

// neteaseIPadPlaying:iPad 版此刻记的那一项是不是这首歌(歌名歌手对得上,歌名按「歌名」或「歌名 (别名)」比;两边时长都知道时
// 也要对得上);节目不算。
func neteaseIPadPlaying(artist, title string, durationSecs float64) (neteaseIPadItem, bool) {
	it, ok := neteaseIPadNowPlaying()
	if !ok || it.Program || it.ID == "" {
		return neteaseIPadItem{}, false
	}
	m, artists := newQueueCurrentMatcher(artist, title), strings.Join(it.Artists, "/")
	matched := m.match(artists, it.Name) != queueNoMatch
	for _, a := range it.Aliases {
		matched = matched || m.match(artists, it.Name+" ("+a+")") != queueNoMatch
	}
	if !matched {
		return neteaseIPadItem{}, false
	}
	if dur := it.DurationMs / 1000; dur > 0 && durationSecs > 0 && !sourceDurationFits(durationSecs, dur) {
		log.Printf("netease ipad: %q - %q matches the iPad app's now playing by name but not by duration (%.0fs vs %.0fs)",
			artist, title, durationSecs, dur)
		return neteaseIPadItem{}, false
	}
	log.Printf("netease ipad: %q - %q is the iPad app's now playing → %s", artist, title, it.ID)
	return it, true
}

// neteaseIPadPlayingTrack:同 neteaseIPadPlaying,换成本机曲库那种形状;两边专辑都知道又对不上时不认,id 不是数字时 ok=false。
func neteaseIPadPlayingTrack(artist, title, album string, durationSecs float64) (neteaseLocalTrack, bool) {
	it, ok := neteaseIPadPlaying(artist, title, durationSecs)
	if !ok || !neteaseLocalAlbumAgrees(album, it.AlbumName) {
		return neteaseLocalTrack{}, false
	}
	id, err := strconv.ParseInt(it.ID, 10, 64)
	if err != nil || id <= 0 {
		return neteaseLocalTrack{}, false
	}
	t := neteaseLocalTrack{ID: flexID(id), Name: it.Name, Duration: it.DurationMs, Mark: it.Mark}
	if albumID, err := strconv.ParseInt(it.AlbumID, 10, 64); err == nil {
		t.Album.ID = flexID(albumID)
	}
	t.Album.Name, t.Album.PicURL = it.AlbumName, it.AlbumPic
	for _, a := range it.Artists {
		t.Artists = append(t.Artists, struct {
			Name string `json:"name"`
		}{Name: a})
	}
	return t, true
}

// neteaseIPadEpisodesPublisher 照 neteaseEpisodesPublisher 的约定写 iPad 版的单集名单:读得到那一行就有这份文件,
// 是节目时里面是这一集(单集名 + 主播),是歌时是空数组;读不到时删掉。库没变、内容没变都不重写。
type neteaseIPadEpisodesPublisher struct {
	statePath string
	dbPath    string
	seen      bool
	stamp     neteaseIPadStamp
	written   []byte
}

func (p *neteaseIPadEpisodesPublisher) refresh() bool {
	stamp, err := neteaseIPadStampOf(p.dbPath)
	if err == nil && p.seen && stamp == p.stamp {
		return p.written != nil
	}
	if err != nil {
		noteLocalCacheDenied("netease", p.dbPath, err)
		p.forget()
		return false
	}
	p.seen, p.stamp = true, stamp
	it, err := neteaseIPadQueryNowPlaying(p.dbPath)
	if err != nil {
		p.withdraw()
		return false
	}
	noteLocalCacheReadable("netease")
	episodes := []neteaseEpisode{}
	if it.Program {
		episodes = append(episodes, neteaseEpisode{Title: it.Name, Host: strings.Join(it.Artists, "/")})
	}
	key, _ := json.Marshal(episodes)
	if p.written != nil && bytes.Equal(p.written, key) {
		return true
	}
	body, _ := json.Marshal(neteaseEpisodesState{UpdatedAt: time.Now().Unix(), Episodes: episodes})
	if writeFileAtomic(p.statePath, body) != nil {
		p.forget()
		return false
	}
	p.written = key
	return true
}

func (p *neteaseIPadEpisodesPublisher) withdraw() {
	if err := os.Remove(p.statePath); err != nil && !errors.Is(err, fs.ErrNotExist) {
		warnf("netease ipad episodes: cannot remove %s: %v", p.statePath, err)
	}
	p.written = nil
}

func (p *neteaseIPadEpisodesPublisher) forget() {
	p.withdraw()
	p.seen = false
}

// startNeteaseIPadEpisodesWatcher 由 run() 单开 goroutine。库是原地写的 WAL,盯目录收不到写入:同时盯库所在的目录
// (-wal 建出来、删掉)和 -wal 本身(每次写入)。
func startNeteaseIPadEpisodesWatcher(ctx context.Context) {
	p := &neteaseIPadEpisodesPublisher{statePath: configFilePath(clientName + "-netease-ipad-episodes.json"), dbPath: neteaseIPadKVPath()}
	p.forget()
	if p.dbPath == "" {
		return
	}
	runNeteaseIPadEpisodesWatcher(ctx, p, neteaseEpisodesRetryInterval)
}

func runNeteaseIPadEpisodesWatcher(ctx context.Context, p *neteaseIPadEpisodesPublisher, retry time.Duration) {
	dir := filepath.Dir(p.dbPath)
	for {
		dirWrites := make(chan struct{}, 1)
		watchCtx, cancel := context.WithCancel(ctx)
		stopped, ok := startDirWatch(watchCtx, dir, dirWrites)
		if ok {
			p.refresh()
			neteaseIPadEpisodesFollow(watchCtx, p, dirWrites, stopped)
		}
		cancel()
		if ok && stopped != nil {
			<-stopped
		}
		p.forget()
		select {
		case <-ctx.Done():
			return
		case <-time.After(retry):
		}
	}
}

// neteaseIPadEpisodesFollow 跟着目录和 -wal 的改动刷新名单,直到 ctx 结束或目录监听停了。-wal 被删、换掉时监听会停,
// 目录一变就重新盯。
func neteaseIPadEpisodesFollow(ctx context.Context, p *neteaseIPadEpisodesPublisher, dirWrites <-chan struct{}, dirStopped <-chan struct{}) {
	walWrites := make(chan struct{}, 1)
	var walCancel context.CancelFunc
	var walStopped <-chan struct{}
	unwatch := func() {
		if walCancel != nil {
			walCancel()
			<-walStopped
			walCancel, walStopped = nil, nil
		}
	}
	rewatch := func() {
		unwatch()
		wctx, cancel := context.WithCancel(ctx)
		if stopped, ok := startDirWatch(wctx, p.dbPath+"-wal", walWrites); ok {
			walCancel, walStopped = cancel, stopped
		} else {
			cancel()
		}
	}
	rewatch()
	defer unwatch()
	for {
		select {
		case <-ctx.Done():
			return
		case <-dirStopped:
			return
		case <-dirWrites:
			rewatch()
			p.refresh()
		case <-walStopped:
			walCancel()
			walCancel, walStopped = nil, nil
			p.refresh()
		case <-walWrites:
			p.refresh()
		}
	}
}
