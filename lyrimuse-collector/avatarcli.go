package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
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
}

const avatarCacheTTL = 14 * 24 * time.Hour

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
	for _, name := range args {
		if name == "" {
			continue
		}
		if e, ok := cache[name]; ok && now.Sub(time.Unix(e.TS, 0)) < avatarCacheTTL {
			out[name] = e.URL
			continue
		}
		// 每个名字各自限 6 秒 —— 一批 10 个名字全部超时也只有一分钟,而且缓存写进去后
		// 下次就不会再打网络。
		ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
		url := resolveArtistAvatar(ctx, name)
		cancel()
		out[name] = url
		cache[name] = avatarCacheEntry{URL: url, TS: now.Unix()}
		dirty = true
	}

	if dirty {
		if data, err := json.MarshalIndent(cache, "", "  "); err == nil {
			if err := os.WriteFile(cachePath, data, 0o644); err != nil {
				log.Printf("artist-avatars: write cache failed: %v", err)
			}
		}
	}

	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(out); err != nil {
		log.Fatalf("artist-avatars: encode: %v", err)
	}
}
