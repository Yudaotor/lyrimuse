package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// `collector artist-avatars <歌手名>...`:给一批歌手名解析头像图 URL,stdout 输出一个
// JSON 对象 {"歌手名": "url", ...}(查不到的名字值为空串)。
//
// 给 Lyrimuse 的 Last.fm 信息页(LastfmStatsSection)用 —— Last.fm API 的歌手图 2019 年
// 起全是同一张白星占位图,真头像走这里:复用网页版"历史播放 Top 歌手"已经在用的
// resolveArtistAvatar(QQ 音乐优先、Deezer 兜底,见 topartists.go),不在 Swift 里把
// 两个服务的搜索逻辑重抄一遍。
//
// ## 磁盘缓存
//
// 结果按歌手名落盘(lyrimuse-artist-avatar-cache.json),命中直接返回,不再打网络请求。
// 头像不是会频繁变的东西,TTL 给 14 天;**查不到也缓存**(空串)——查不到的歌手(小众/
// 纯本地标签)每次打开页面都重查一遍,是对 QQ/Deezer 无意义的连打。
type avatarCacheEntry struct {
	URL string `json:"url"`
	TS  int64  `json:"ts"`
	// Transient:这是一次"暂时故障"下的空结果(网络挂了/服务抽风),不是确定性的
	// 查无此人 —— 只配 30 分钟的短负缓存(防抖动期连打),不配 14 天。老缓存文件没有
	// 这个字段,读出来是 false = 按确定性结论处理,正确。
	Transient bool `json:"transient,omitempty"`
}

const avatarCacheTTL = 14 * 24 * time.Hour
const avatarTransientTTL = 30 * time.Minute

func runArtistAvatarsCLI(args []string) {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "artist-avatars: at least one artist name is required")
		os.Exit(2)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("artist-avatars: resolve home dir: %v", err)
	}
	cachePath := filepath.Join(home, ".config", clientName, clientName+"-artist-avatar-cache.json")

	cache := map[string]avatarCacheEntry{}
	if data, err := os.ReadFile(cachePath); err == nil {
		// 解析失败就当没有缓存,重查一遍然后覆盖写 —— 缓存文件坏了不该让功能失效
		_ = json.Unmarshal(data, &cache)
	}

	out := map[string]string{}
	dirty := false
	now := time.Now()
	// 先把缓存命中的收掉,剩下的才要打网络
	var misses []string
	for _, name := range args {
		if name == "" {
			continue
		}
		if old, ok := cache[name]; ok {
			ttl := avatarCacheTTL
			if old.Transient {
				ttl = avatarTransientTTL
			}
			if now.Sub(time.Unix(old.TS, 0)) < ttl {
				out[name] = old.URL
				continue
			}
		}
		misses = append(misses, name)
	}
	// 冷缓存并发解析:串行时每名最坏 6 秒,一次冷打开(10 个新歌手)能卡到一分钟 ——
	// daemon 侧 topArtistsDigest 早为同样的理由用了 4 路并发(见那边注释),这里对齐。
	// 顺序无关(输出是 map),cache/out 的写入用锁护住。
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 4)
	for _, name := range misses {
		wg.Add(1)
		go func(name string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
			url, definitive := resolveArtistAvatar(ctx, name)
			cancel()
			mu.Lock()
			defer mu.Unlock()
			old, hasOld := cache[name]
			switch {
			case url != "" || definitive:
				// 拿到了图,或者两条腿都正常应答说"确实没有" —— 都可以放心存 14 天
				out[name] = url
				cache[name] = avatarCacheEntry{URL: url, TS: now.Unix()}
				dirty = true
			case hasOld && old.URL != "":
				// 暂时故障 + 手上有过期的旧头像:继续用旧的,**不覆盖**(serve-stale,
				// 过期的真图永远好过一个空位;2026-08-11 审阅确认原先会抹掉好头像)。
				out[name] = old.URL
			default:
				// 暂时故障且没有旧值:输出空,落 30 分钟短负缓存防抖动期连打。
				out[name] = ""
				cache[name] = avatarCacheEntry{URL: "", TS: now.Unix(), Transient: true}
				dirty = true
			}
		}(name)
	}
	wg.Wait()

	if dirty {
		if data, err := json.MarshalIndent(cache, "", "  "); err == nil {
			// 临时文件 + rename 原子落盘:App 可能同时起两个 artist-avatars 进程(切时段
			// 触发两批解析),半写状态被另一个进程读到会整份解析失败、缓存全丢。
			tmp := cachePath + ".tmp"
			if err := os.WriteFile(tmp, data, 0o644); err != nil {
				log.Printf("artist-avatars: write cache failed: %v", err)
			} else if err := os.Rename(tmp, cachePath); err != nil {
				log.Printf("artist-avatars: rename cache failed: %v", err)
			}
		}
	}

	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(out); err != nil {
		log.Fatalf("artist-avatars: encode: %v", err)
	}
}
