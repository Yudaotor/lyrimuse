package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io/fs"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// iPad 版酷狗自然连播时偶尔只报下一首的第一份锚点(旧歌名下、新时长、进度归零),新歌名到下一次暂停才报。App 认出这种情形时
// 按时长在它的播放队列里找这一首(KugouIPadTitleRepair);队列在它的容器里,App 不读别的 App 的容器(会弹「想访问其他 App
// 的数据」),由引擎读出来写一份 lyrimuse-kugou-ipad-queue.json:队列里每首的歌名(showName)、署名、专辑、整秒时长,外加随机
// 模式抽取记录指的当前这首(userCurrentPlayList.plist 里 currentPlayListRandomState 的 historySongIndexes[historyIndex],
// 换歌那一刻改写;顺序模式下这份记录停在上一次随机放的时候,所以只拿它在时长对得上的几首里挑)。没有完全磁盘访问、没装
// iPad 版、读不到队列时没有这份文件。见 02 章决策 293。

// kugouIPadCurrentListOverride 让单测把那份 plist 指到临时路径。空 = 用真实路径。
var kugouIPadCurrentListOverride string

func kugouIPadCurrentListPath() string {
	if kugouIPadCurrentListOverride != "" {
		return kugouIPadCurrentListOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return otherAppContainer(filepath.Join(home, "Library/Containers/com.kugou.kugou1002/Data/Library/Preferences",
		"userCurrentPlayList.plist"))
}

// kugouIPadQueueEntry 是名单里的一首。Seconds 是队列记的 musicTime(整秒,系统报的时长比它多不到 1 秒)。
type kugouIPadQueueEntry struct {
	Title   string  `json:"title"`
	Artist  string  `json:"artist"`
	Album   string  `json:"album"`
	Seconds float64 `json:"seconds"`
}

// kugouIPadQueueState 是 lyrimuse-kugou-ipad-queue.json 的内容,App 侧 KugouIPadTitleRepair.Queue 读同一套字段。
// ShuffleCurrent 是 Songs 里的下标,-1 = 没有随机抽取记录或对不上这份队列;ShuffleAt 是那份 plist 的修改时刻(Unix 秒)。
type kugouIPadQueueState struct {
	UpdatedAt      int64                 `json:"updatedAt"`
	Songs          []kugouIPadQueueEntry `json:"songs"`
	ShuffleCurrent int                   `json:"shuffleCurrent"`
	ShuffleAt      float64               `json:"shuffleAt"`
}

// kugouIPadQueueEntries 按队列次序读出每一首;读不了、没有为 false。
func kugouIPadQueueEntries(path string) ([]kugouIPadQueueEntry, bool) {
	if path == "" {
		return nil, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), kugouUpcomingQueryTimeout)
	defer cancel()
	uri := (&neturl.URL{Scheme: "file", Path: path, RawQuery: "mode=ro"}).String()
	out, err := exec.CommandContext(ctx, "/usr/bin/sqlite3", "-json", uri, kugouIPadQueueSQL(kugouUpcomingSQL)).Output()
	if err != nil {
		return nil, false
	}
	var rows []kugouUpcomingRow
	if trimmed := bytes.TrimSpace(out); len(trimmed) == 0 || json.Unmarshal(trimmed, &rows) != nil {
		return nil, false
	}
	entries := make([]kugouIPadQueueEntry, 0, len(rows))
	for _, r := range rows {
		a, ti := kugouUpcomingSplit(r.Name)
		if s := kugouIPadSingers(r.Singer); s != "" {
			a = s
		}
		if r.ShowName != "" {
			ti = r.ShowName
		}
		entries = append(entries, kugouIPadQueueEntry{Title: ti, Artist: a, Album: r.Album, Seconds: r.Dur})
	}
	return entries, true
}

// kugouIPadSingers:singerInfo 里的全部署名,按它报给系统的写法用「、」连(跟 Mac 版同一个酷狗目录);解不开为空。
func kugouIPadSingers(raw string) string {
	var singers []struct {
		Name string `json:"name"`
	}
	if raw == "" || json.Unmarshal([]byte(raw), &singers) != nil {
		return ""
	}
	names := make([]string, 0, len(singers))
	for _, s := range singers {
		if s.Name != "" {
			names = append(names, s.Name)
		}
	}
	return strings.Join(names, "、")
}

// kugouIPadRandomState 是 currentPlayListRandomState 那块 JSON 里用得上的字段。
type kugouIPadRandomState struct {
	History []int `json:"historySongIndexes"`
	Index   int   `json:"historyIndex"`
	Count   int   `json:"songCount"`
}

// kugouIPadShuffleCurrent 从随机抽取记录取当前这首在队列里的下标;记录的歌数跟队列对不上、下标越界、读不了为 -1。纯函数(raw 是
// plutil 取出的 base64),单测覆盖。
func kugouIPadShuffleCurrent(raw []byte, songs int) int {
	body, err := base64.StdEncoding.DecodeString(string(bytes.TrimSpace(raw)))
	if err != nil {
		return -1
	}
	var st kugouIPadRandomState
	if json.Unmarshal(body, &st) != nil || st.Count != songs || st.Index < 0 || st.Index >= len(st.History) {
		return -1
	}
	if i := st.History[st.Index]; i >= 0 && i < songs {
		return i
	}
	return -1
}

func kugouIPadReadShuffle(path string, songs int) (int, float64) {
	st, err := os.Stat(path)
	if err != nil {
		return -1, 0
	}
	ctx, cancel := context.WithTimeout(context.Background(), kugouUpcomingQueryTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/plutil", "-extract", "currentPlayListRandomState", "raw", "-o", "-", path).Output()
	if err != nil {
		return -1, 0
	}
	i := kugouIPadShuffleCurrent(out, songs)
	if i < 0 {
		return -1, 0
	}
	return i, float64(st.ModTime().UnixNano()) / 1e9
}

type kugouIPadQueueStamp struct {
	dbMod, listMod   time.Time
	dbSize, listSize int64
}

// kugouIPadQueuePublisher:读得到队列就有这份文件,读不到时删掉。两份文件都没变、内容没变都不重写。
type kugouIPadQueuePublisher struct {
	statePath, dbPath, listPath string
	seen                        bool
	stamp                       kugouIPadQueueStamp
	written                     []byte
}

func (p *kugouIPadQueuePublisher) refresh() bool {
	db, err := os.Stat(p.dbPath)
	if err != nil {
		p.forget()
		return false
	}
	stamp := kugouIPadQueueStamp{dbMod: db.ModTime(), dbSize: db.Size()}
	if list, err := os.Stat(p.listPath); err == nil {
		stamp.listMod, stamp.listSize = list.ModTime(), list.Size()
	}
	if p.seen && stamp == p.stamp {
		return p.written != nil
	}
	p.seen, p.stamp = true, stamp
	songs, ok := kugouIPadQueueEntries(p.dbPath)
	if !ok {
		p.withdraw()
		return false
	}
	state := kugouIPadQueueState{Songs: songs, ShuffleCurrent: -1}
	if p.listPath != "" {
		state.ShuffleCurrent, state.ShuffleAt = kugouIPadReadShuffle(p.listPath, len(songs))
	}
	key, _ := json.Marshal(state)
	if p.written != nil && bytes.Equal(p.written, key) {
		return true
	}
	state.UpdatedAt = time.Now().Unix()
	body, _ := json.Marshal(state)
	if writeFileAtomic(p.statePath, body) != nil {
		p.forget()
		return false
	}
	p.written = key
	return true
}

func (p *kugouIPadQueuePublisher) withdraw() {
	if err := os.Remove(p.statePath); err != nil && !errors.Is(err, fs.ErrNotExist) {
		warnf("kugou ipad queue: cannot remove %s: %v", p.statePath, err)
	}
	p.written = nil
}

func (p *kugouIPadQueuePublisher) forget() {
	p.withdraw()
	p.seen = false
}

// kugouIPadQueueRetryInterval:目录还没有(没装、没开过)或监听停了之后多久再试。
const kugouIPadQueueRetryInterval = 5 * time.Minute

// startKugouIPadQueueWatcher 由 run() 单开 goroutine。队列库是 rollback journal(写时建、删 -journal)、plist 是整份换掉,
// 都会改动它们所在的目录,盯目录就够。
func startKugouIPadQueueWatcher(ctx context.Context) {
	p := &kugouIPadQueuePublisher{statePath: configFilePath(clientName + "-kugou-ipad-queue.json"),
		dbPath: kugouIPadQueuePath(), listPath: kugouIPadCurrentListPath()}
	p.forget()
	if p.dbPath == "" {
		return
	}
	runKugouIPadQueueWatcher(ctx, p, kugouIPadQueueRetryInterval)
}

func runKugouIPadQueueWatcher(ctx context.Context, p *kugouIPadQueuePublisher, retry time.Duration) {
	dir := filepath.Dir(p.dbPath)
	for {
		writes := make(chan struct{}, 1)
		watchCtx, cancel := context.WithCancel(ctx)
		stopped, ok := startDirWatch(watchCtx, dir, writes)
		if ok {
			p.refresh()
		follow:
			for {
				select {
				case <-ctx.Done():
					break follow
				case <-stopped:
					break follow
				case <-writes:
					p.refresh()
				}
			}
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
