package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// ---- App 与 collector 共享的限流窗口 ----
//
// 两个进程共用一个出口 IP,都会打 iTunes 和 Last.fm 的读接口。一边撞到限流(429 / 403 / Last.fm
// error 29 / 连不上),另一边接着打只会被一起限。所以这几个接口的停手窗口写进一个共享文件,
// 两边发请求前都看一眼。App 侧同一份逻辑在 LyrimuseCore/Local/OutboundCooldowns.swift,
// 文件名、键的写法、JSON 形状三处必须两边一起改(selftest contracts 组守着)。
//
// 文件形状:{"endpoints":{"itunes.apple.com/search":1790253000.5,...}},值是窗口截止的 Unix 秒。
// 键跟出站闸的端点键(guardEndpointKey)同一个写法。写入是读 - 合并 - 原子替换:两个进程
// 同时写可能丢掉对方刚写的一条,丢了只是那一边少停一个窗口,不值得为它加跨进程锁。
// 过期的条目在每次写入时清掉。

const (
	sharedCooldownITunesSearch = "itunes.apple.com/search"
	sharedCooldownLastfm       = "ws.audioscrobbler.com/2.0/"
	// sharedCooldownRereadEvery:读缓存的有效期,出站闸每个请求都会问一次,别每次都 stat。
	sharedCooldownRereadEvery = time.Second
)

// sharedCooldownHosts:共享窗口只覆盖这几个主机上的端点。
var sharedCooldownHosts = map[string]bool{
	"itunes.apple.com":      true,
	"ws.audioscrobbler.com": true,
}

type sharedCooldownFile struct {
	Endpoints map[string]float64 `json:"endpoints"`
}

var (
	sharedCooldownMu     sync.Mutex
	sharedCooldownPath   string
	sharedCooldownCache  map[string]float64
	sharedCooldownReadAt time.Time
	sharedCooldownMtime  time.Time
)

// setSharedCooldownPath 在启动时调一次;空串关掉共享(单测默认就是关的)。
func setSharedCooldownPath(path string) {
	sharedCooldownMu.Lock()
	sharedCooldownPath = path
	sharedCooldownCache = nil
	sharedCooldownReadAt = time.Time{}
	sharedCooldownMtime = time.Time{}
	sharedCooldownMu.Unlock()
}

func readSharedCooldownFile(path string) map[string]float64 {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var f sharedCooldownFile
	if json.Unmarshal(data, &f) != nil {
		return nil
	}
	return f.Endpoints
}

// sharedCooldownUntil 返回共享文件里这个端点的窗口截止时刻;没有或已过期返回零值。
func sharedCooldownUntil(key string, now time.Time) time.Time {
	sharedCooldownMu.Lock()
	defer sharedCooldownMu.Unlock()
	if sharedCooldownPath == "" {
		return time.Time{}
	}
	if now.Sub(sharedCooldownReadAt) >= sharedCooldownRereadEvery {
		sharedCooldownReadAt = now
		if st, err := os.Stat(sharedCooldownPath); err != nil {
			sharedCooldownCache = nil
		} else if !st.ModTime().Equal(sharedCooldownMtime) {
			sharedCooldownMtime = st.ModTime()
			sharedCooldownCache = readSharedCooldownFile(sharedCooldownPath)
		}
	}
	secs, ok := sharedCooldownCache[key]
	if !ok {
		return time.Time{}
	}
	until := time.Unix(0, int64(secs*float64(time.Second)))
	if !now.Before(until) {
		return time.Time{}
	}
	return until
}

// mergeSharedCooldown:去掉过期的,key 取两者较晚的截止时刻。纯函数。
func mergeSharedCooldown(existing map[string]float64, key string, until, now time.Time) map[string]float64 {
	out := make(map[string]float64, len(existing)+1)
	nowSecs := float64(now.UnixNano()) / float64(time.Second)
	for k, v := range existing {
		if v > nowSecs {
			out[k] = v
		}
	}
	u := float64(until.UnixNano()) / float64(time.Second)
	if u > out[key] {
		out[key] = u
	}
	return out
}

// publishSharedCooldown 把一个端点的停手窗口写进共享文件。不在共享名单里的主机、或共享没开时什么都不做。
func publishSharedCooldown(host, key string, until time.Time) {
	if !sharedCooldownHosts[host] {
		return
	}
	sharedCooldownMu.Lock()
	defer sharedCooldownMu.Unlock()
	path := sharedCooldownPath
	if path == "" {
		return
	}
	now := time.Now()
	merged := mergeSharedCooldown(readSharedCooldownFile(path), key, until, now)
	data, err := json.Marshal(sharedCooldownFile{Endpoints: merged})
	if err != nil {
		return
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp*")
	if err != nil {
		return
	}
	tmpName := tmp.Name()
	_, werr := tmp.Write(data)
	cerr := tmp.Close()
	if werr != nil || cerr != nil || os.Rename(tmpName, path) != nil {
		os.Remove(tmpName)
		return
	}
	sharedCooldownCache = merged
	sharedCooldownReadAt = now
	if st, err := os.Stat(path); err == nil {
		sharedCooldownMtime = st.ModTime()
	}
}
