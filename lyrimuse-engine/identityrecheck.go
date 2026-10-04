package main

import (
	"context"
	"fmt"
	"log/slog"
	neturl "net/url"
	"sort"
	"strings"
	"time"
)

// 身份缓存查一次永久生效。没有 Checked 的条目是按「搜索首条分数够高就认」写下的,可能认错了人(歌手地区、
// 歌手页跳转、按 mbid 的合并都读它),这里按现行判据(resolveArtistIdentityMB)补核。见 12 章决策 25。

const (
	// artistIdentityRecheckBatch:每轮至多核几条(每条 1~4 个请求,MusicBrainz 全局 1.1 s 限速)。
	artistIdentityRecheckBatch = 20
	// artistIdentityRecheckInterval:两轮之间隔多久。都核完之后每轮只扫一遍内存里的缓存。
	artistIdentityRecheckInterval = 5 * time.Minute
	// artistIdentityRecheckMaxFailures:连着这么多条没问成就停下这一轮。
	artistIdentityRecheckMaxFailures = 3
)

// lastfmMbidFn 问 Last.fm 某个写法的歌手页挂的 mbid:没挂返回空串,没问成返回 error。
type lastfmMbidFn func(ctx context.Context, name string) (string, error)

// artistIdentityRecheckDigest 由后台任务(runDigests)调用,每 artistIdentityRecheckInterval 补核一批。
func (p *poller) artistIdentityRecheckDigest(now time.Time, env digestEnv) {
	if !p.identityRecheckAt.IsZero() && now.Before(p.identityRecheckAt) {
		return
	}
	p.identityRecheckAt = now.Add(artistIdentityRecheckInterval)
	var lastfm lastfmMbidFn
	if key := env.cfg.lastfmBridgeAPIKey(); key != "" {
		lastfm = func(ctx context.Context, name string) (string, error) { return lastfmArtistMbid(ctx, key, name) }
	}
	recheckArtistIdentities(env.ctx, artistIdentityRecheckBatch, lastfm)
}

// recheckArtistIdentities 按名字顺序试核至多 limit 条没有 Checked 的条目,有改动就存盘,返回还剩几条没核。
// lastfm 为 nil 时不问 Last.fm。
func recheckArtistIdentities(ctx context.Context, limit int, lastfm lastfmMbidFn) int {
	pending := uncheckedArtistIdentities()
	if len(pending) == 0 {
		return 0
	}
	done, tried, failures := 0, 0, 0
	for _, name := range pending {
		if tried >= limit || failures >= artistIdentityRecheckMaxFailures || ctx.Err() != nil {
			break
		}
		tried++
		if recheckArtistIdentity(ctx, name, lastfm) {
			done, failures = done+1, 0
		} else {
			failures++
		}
	}
	saveArtistIdentityCache()
	slog.Info("artist identity recheck", "checked", done, "remaining", len(pending)-done)
	return len(pending) - done
}

// uncheckedArtistIdentities:还没按现行判据核过的名字,按名字排序。
func uncheckedArtistIdentities() []string {
	artistIdentityMu.Lock()
	defer artistIdentityMu.Unlock()
	var out []string
	for name, id := range artistIdentityCache {
		if !id.Checked {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

// recheckArtistIdentity 核一条,返回 false = 没问成、缓存没动。
//
// 缓存里那个 mbid 的主名或登记别名就是这个写法:留下,中文名按现行规则重挑。否则(对不上、名字在手工表里、
// 原来就没有 mbid)问 Last.fm 这个写法挂的 mbid,交给 resolveArtistIdentityMB 重新解析:Last.fm 给了就用它,
// 没给就按名字搜,首条也得对得上名字。
func recheckArtistIdentity(ctx context.Context, name string, lastfm lastfmMbidFn) bool {
	id, ok := cachedArtistIdentity(name)
	if !ok || id.Checked {
		return true
	}
	if id.Mbid != "" && knownArtistAlias(name) == "" {
		var a mbArtistWithAliases
		err := mbGetJSONShared(ctx, mbArtistAliasesURL(id.Mbid), &a)
		if err == nil && mbNameBelongsToArtist(a.Name, a.Aliases, name) {
			id.Zh = ""
			if !containsHan(name) {
				id.Zh = pickChineseAlias(a.Aliases, a.Country)
			}
			id.Checked = true
			storeArtistIdentity(name, id)
			return true
		}
		if err != nil && !mbDefinitiveMiss(err) {
			return false
		}
	}
	known := ""
	if lastfm != nil {
		m, err := lastfm(ctx, name)
		if err != nil {
			return false
		}
		known = m
	}
	resolveArtistIdentityMB(name, known)
	got, _ := cachedArtistIdentity(name)
	return got.Checked
}

// lastfmArtistMbid 问 Last.fm 这个写法的歌手页挂的 mbid(artist.getInfo,不让它自动纠正写法)。
// 查无此人(error 6)和没挂 mbid 都返回空串。
func lastfmArtistMbid(ctx context.Context, apiKey, name string) (string, error) {
	var out struct {
		Error  int `json:"error"`
		Artist struct {
			Mbid string `json:"mbid"`
		} `json:"artist"`
	}
	params := neturl.Values{"method": {"artist.getInfo"}, "artist": {name}, "autocorrect": {"0"}, "api_key": {apiKey}}
	if err := lastfmAPIGet(ctx, params, &out); err != nil {
		return "", err
	}
	switch out.Error {
	case 0:
		return strings.TrimSpace(out.Artist.Mbid), nil
	case 6:
		return "", nil
	}
	return "", fmt.Errorf("lastfm artist.getInfo error %d", out.Error)
}
