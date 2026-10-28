package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// 网易云在放播客单集时,App 要认出来、不当成歌报(02 章决策 114)。依据是网易云容器里的当前播放列表 `playingList`:
// 放单集时客户端把这档节目的单集整份写进去。这份文件只由引擎读,App 只读引擎摘出来的单集名单
// (`lyrimuse-netease-episodes.json`)。别让 App 自己去读网易云的容器:App 是前台进程,没授权时系统会弹
// 「想访问其他 App 的数据」,用户点了「不允许」连引擎这边的授权也一起收回;引擎被拒时系统不弹框。见 02 章决策 151。
//
// 名单文件的约定:有这份文件 = 引擎此刻读得到网易云的播放列表,里面是列表里的全部单集(没有单集时是空数组);
// 没有这份文件 = 不知道(没装网易云、没授权、引擎没在跑),App 一律不当单集。引擎启动时先删掉旧的,
// 读不到列表(被拒、文件不在)时也删掉。

// neteaseEpisodesRetryInterval:网易云的列表目录还不在(没装、没打开过)或者盯不了时,隔这么久再试。
// neteaseEpisodesPathCheckInterval:盯着的时候隔这么久重新挑一次列表在哪个根(沙盒版、非沙盒版换着用时会换根)。
const (
	neteaseEpisodesRetryInterval     = 5 * time.Minute
	neteaseEpisodesPathCheckInterval = 30 * time.Second
)

type neteaseEpisode struct {
	Title string `json:"title"`
	// Host 是主播昵称;条目没记主播时是空串,App 那边只看歌名。
	Host string `json:"host"`
}

type neteaseEpisodesState struct {
	UpdatedAt int64            `json:"updatedAt"`
	Episodes  []neteaseEpisode `json:"episodes"`
}

// neteaseEpisodesFromQueue 摘出队列文件里的单集条目;不是这份文件的形状返回 false。单集的 `track` 没有 `artists`,
// 单集名在 `track.name`、主播在 `track.creator.nickname`。
func neteaseEpisodesFromQueue(raw []byte) ([]neteaseEpisode, bool) {
	var f struct {
		List []struct {
			ResourceType string `json:"resourceType"`
			Track        struct {
				Name    string `json:"name"`
				Creator struct {
					Nickname string `json:"nickname"`
				} `json:"creator"`
			} `json:"track"`
		} `json:"list"`
	}
	if err := json.Unmarshal(raw, &f); err != nil || f.List == nil {
		return nil, false
	}
	out := []neteaseEpisode{}
	for _, it := range f.List {
		if !neteaseVoiceTypes[it.ResourceType] || it.Track.Name == "" {
			continue
		}
		out = append(out, neteaseEpisode{Title: it.Track.Name, Host: it.Track.Creator.Nickname})
	}
	return out, true
}

// neteaseEpisodesPublisher 记上一次读到的列表文件和写出去的内容,文件没变、内容没变都不重写。
type neteaseEpisodesPublisher struct {
	statePath string
	queuePath string
	seenMod   time.Time
	seenSize  int64
	seen      bool
	// written 是写出去的那份单集(不含 updatedAt);nil = 名单此刻不在。
	written []byte
}

// refresh 按此刻的列表文件更新名单,返回读不读得到这份列表(false = 名单已删,不知道)。
func (p *neteaseEpisodesPublisher) refresh() bool {
	st, err := os.Stat(p.queuePath)
	if err == nil && p.seen && st.ModTime().Equal(p.seenMod) && st.Size() == p.seenSize {
		return p.written != nil
	}
	var raw []byte
	if err == nil && st.Size() <= neteaseUpcomingMaxBytes {
		raw, err = os.ReadFile(p.queuePath)
	}
	if err != nil {
		noteLocalCacheDenied("netease", p.queuePath, err)
		p.forget()
		return false
	}
	p.seen, p.seenMod, p.seenSize = true, st.ModTime(), st.Size()
	if raw == nil {
		p.withdraw()
		return false
	}
	noteLocalCacheReadable("netease")
	episodes, ok := neteaseEpisodesFromQueue(raw)
	if !ok {
		p.withdraw()
		return false
	}
	// 列表重写了但单集没变(换歌、加歌)就不重写名单。
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

// withdraw 删掉名单(App 当成不知道);下一次文件变了再重读。
func (p *neteaseEpisodesPublisher) withdraw() {
	if err := os.Remove(p.statePath); err != nil && !errors.Is(err, fs.ErrNotExist) {
		warnf("netease episodes: cannot remove %s: %v", p.statePath, err)
	}
	p.written = nil
}

// forget 删掉名单并忘掉上一次看到的文件,下一次一定重读。
func (p *neteaseEpisodesPublisher) forget() {
	p.withdraw()
	p.seen = false
}

// startNeteaseEpisodesWatcher 由 run() 单开 goroutine:盯网易云播放列表所在的目录(客户端写临时文件再改名,
// 盯目录收得到),一有改动就更新名单。网易云在单集开播前约 1 秒写这份列表,App 收到这一集时名单已经在了。
func startNeteaseEpisodesWatcher(ctx context.Context) {
	p := &neteaseEpisodesPublisher{statePath: configFilePath(clientName + "-netease-episodes.json")}
	p.forget()
	runNeteaseEpisodesWatcher(ctx, p, neteaseEpisodesRetryInterval, neteaseEpisodesPathCheckInterval, neteaseUpcomingPath)
}

// runNeteaseEpisodesWatcher:每轮按 pathFor 重新取列表路径再盯它的目录;盯着时每 recheck 重取一次,路径变了当场换目录。
func runNeteaseEpisodesWatcher(ctx context.Context, p *neteaseEpisodesPublisher, retry, recheck time.Duration, pathFor func() string) {
	for {
		p.queuePath = pathFor()
		moved, ok := false, false
		var stopped <-chan struct{}
		watchCtx, cancel := context.WithCancel(ctx)
		if p.queuePath != "" {
			writes := make(chan struct{}, 1)
			stopped, ok = startDirWatch(watchCtx, filepath.Dir(p.queuePath), writes)
			if ok {
				p.refresh()
				moved = neteaseEpisodesFollow(watchCtx, p, writes, stopped, recheck, pathFor)
			}
		}
		cancel()
		if ok && stopped != nil {
			<-stopped
		}
		p.forget()
		if moved {
			continue
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(retry):
		}
	}
}

// neteaseEpisodesFollow 跟着目录的改动刷新名单,直到 ctx 结束、监听停了,或 pathFor 给的路径不再是 p.queuePath
// (返回 true,调用方换目录重盯)。
func neteaseEpisodesFollow(ctx context.Context, p *neteaseEpisodesPublisher, writes <-chan struct{}, stopped <-chan struct{},
	recheck time.Duration, pathFor func() string) bool {
	ticker := time.NewTicker(recheck)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return false
		case <-stopped:
			return false
		case <-writes:
			p.refresh()
		case <-ticker.C:
			if pathFor() != p.queuePath {
				return true
			}
		}
	}
}
