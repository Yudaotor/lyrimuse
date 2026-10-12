package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	neturl "net/url"
	"os"
	"sort"
	"sync"
	"time"
)

// MusicBrainz 按 ISRC 补录音(歌曲实体阶段 2,18 章决策 14):缓存里能当证据的号逐个问 MusicBrainz,唯一命中的录音 id 按号
// 存进 `lyrimuse-mb-recordings.json`(派生数据,丢了重取)。建实体表时同一个录音 id 的写法连强证据边:再版换号、两家发行商
// 各登记一套的同一份录音靠它连上。

const (
	mbRecordingsFileVersion = 1
	mbRecordingsDelay       = 8 * time.Minute
	mbRecordingsInterval    = 24 * time.Hour
	// mbRecordingsRetry:这一轮没问完(连续被限速)时,隔这么久再接着问,不等到第二天。
	mbRecordingsRetry   = time.Hour
	mbRecordingsRecheck = 365 * 24 * time.Hour
	// mbRecordingsSaveEvery:每问成这么多个号落一次盘,被重启时最多丢这么多。退出那一刻的落盘常赶不上进程结束,不能指望它;
	// 见 18 章决策 14。
	mbRecordingsSaveEvery = 20
	// 被限速(503)或请求失败时退避这么久再问同一个号,连续失败 mbRecordingsMaxFailures 次才停:按 IP 的限速在几十个请求
	// 之后就会碰上,碰一次就停的话第一轮要拖好多天。
	mbRecordingsBackoff     = 30 * time.Second
	mbRecordingsMaxFailures = 5
	songIDMBRecording       = "mb_recording"
)

// mbISRCRecord:一个号在 MusicBrainz 上对应的录音。Recordings 是命中几条(0 = 没有这个号);只有唯一命中时才有 Recording。
type mbISRCRecord struct {
	Recording  string `json:"recording,omitempty"`
	Recordings int    `json:"recordings"`
	Checked    int64  `json:"checked"`
}

type mbRecordingsFile struct {
	Version int                     `json:"version"`
	ISRCs   map[string]mbISRCRecord `json:"isrcs"`
}

func mbRecordingsPath() string { return configFilePath(clientName + "-mb-recordings.json") }

// readMBRecordings 读补扫结果;缺失、坏掉、版本对不上都返回空表。
func readMBRecordings(path string) map[string]mbISRCRecord {
	out := map[string]mbISRCRecord{}
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return out
	}
	var f mbRecordingsFile
	if err := json.Unmarshal(data, &f); err != nil {
		noteFileErr("decode", path, err)
		return out
	}
	if f.Version != mbRecordingsFileVersion || f.ISRCs == nil {
		return out
	}
	return f.ISRCs
}

func writeMBRecordings(path string, isrcs map[string]mbISRCRecord) error {
	data, err := json.Marshal(mbRecordingsFile{Version: mbRecordingsFileVersion, ISRCs: isrcs})
	if err != nil {
		return err
	}
	return writeFileAtomic(path, data)
}

// mbRecordingsDue:缓存里能当证据的号(写法上级别 verified 以上的)里没问过、或问过超过 mbRecordingsRecheck 的,排好序。
func mbRecordingsDue(entries map[string]enrichEntry, have map[string]mbISRCRecord, now time.Time) []string {
	seen := map[string]bool{}
	var out []string
	for k, e := range entries {
		if len(e.ISRCs) == 0 {
			continue
		}
		for _, g := range songVariantOf(k, e, false).ids {
			if g.ns != songIDISRC || g.level < songIDVerified || seen[g.id] {
				continue
			}
			seen[g.id] = true
			if rec, ok := have[g.id]; ok && now.Sub(time.Unix(rec.Checked, 0)) < mbRecordingsRecheck {
				continue
			}
			out = append(out, g.id)
		}
	}
	sort.Strings(out)
	return out
}

// lookupMBRecording 问一个号,排 musicbrainzThrottle。MusicBrainz 没有这个号(404)也算问成;被限速、网络不通、ctx 取消
// 时 ok 为 false。
func lookupMBRecording(ctx context.Context, code string) (mbISRCRecord, bool) {
	if err := musicbrainzThrottle(ctx); err != nil {
		return mbISRCRecord{}, false
	}
	var resp struct {
		Recordings []struct {
			ID string `json:"id"`
		} `json:"recordings"`
	}
	url := "https://musicbrainz.org/ws/2/isrc/" + neturl.PathEscape(code) + "?inc=isrcs&fmt=json"
	if err := mbGetJSON(ctx, url, &resp); err != nil {
		var st *mbStatusError
		if errors.As(err, &st) && st.status == http.StatusNotFound {
			return mbISRCRecord{}, true
		}
		return mbISRCRecord{}, false
	}
	rec := mbISRCRecord{Recordings: len(resp.Recordings)}
	if len(resp.Recordings) == 1 {
		rec.Recording = resp.Recordings[0].ID
	}
	return rec, true
}

// fetchMBRecordings 逐个问,结果并进 have,返回问成了几个。问不成就等 backoff 再问同一个号,连续 mbRecordingsMaxFailures
// 次问不成就停(断网、一直被限速),下次再来;每问成 mbRecordingsSaveEvery 个调一次 save。
func fetchMBRecordings(ctx context.Context, codes []string, have map[string]mbISRCRecord, now time.Time, backoff time.Duration,
	lookup func(ctx context.Context, code string) (mbISRCRecord, bool), save func()) int {
	settled, failures := 0, 0
	for i := 0; i < len(codes); {
		if ctx.Err() != nil {
			break
		}
		code := codes[i]
		rec, ok := lookup(ctx, code)
		if !ok {
			if failures++; failures >= mbRecordingsMaxFailures {
				break
			}
			select {
			case <-ctx.Done():
				return settled
			case <-time.After(backoff):
			}
			continue
		}
		failures = 0
		i++
		rec.Checked = now.Unix()
		have[code] = rec
		settled++
		if settled%mbRecordingsSaveEvery == 0 {
			save()
		}
	}
	return settled
}

// startMBRecordingsSweep 由 poller 单开一个 goroutine:启动后 mbRecordingsDelay 补一次,之后每 mbRecordingsInterval 一次,
// 没问完就隔 mbRecordingsRetry 接着问;补到了新结果、实体表开着,就重建一次实体表。
func startMBRecordingsSweep(ctx context.Context) {
	timer := time.NewTimer(mbRecordingsDelay)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		next := mbRecordingsInterval
		if features().SongEntityPhase2 {
			settled, done := sweepMBRecordings(ctx, mbRecordingsPath(), time.Now())
			if settled > 0 && features().SongEntityShadow {
				rebuildSongEntityTable(time.Now())
			}
			if !done {
				next = mbRecordingsRetry
			}
		}
		timer.Reset(next)
	}
}

// sweepMBRecordings 补一轮,返回这一轮问成了几个号、到期的是不是都问完了。
func sweepMBRecordings(ctx context.Context, path string, now time.Time) (int, bool) {
	enrichMu.Lock()
	entries := make(map[string]enrichEntry, len(enrichCache))
	for k, v := range enrichCache {
		entries[k] = v
	}
	enrichMu.Unlock()
	have := readMBRecordings(path)
	due := mbRecordingsDue(entries, have, now)
	if len(due) == 0 {
		return 0, true
	}
	save := func() {
		if err := writeMBRecordings(path, have); err != nil {
			slog.Error("song entities: write mb recordings", "err", err)
		}
	}
	settled := fetchMBRecordings(withBackgroundOutbound(ctx), due, have, now, mbRecordingsBackoff, lookupMBRecording, save)
	save()
	slog.Info("song entities: mb recordings swept", "due", len(due), "settled", settled, "known", len(have))
	return settled, settled == len(due)
}

var (
	mbRecordingsMemoMu    sync.Mutex
	mbRecordingsMemo      map[string]mbISRCRecord
	mbRecordingsMemoMTime time.Time
)

// mbRecordingForISRC:MusicBrainz 补扫对这个号唯一命中的录音 id,没有返回空串。补扫文件改了才重读。ListenBrainz 上报用(lb.go)。
func mbRecordingForISRC(code string) string {
	if code == "" {
		return ""
	}
	path := mbRecordingsPath()
	info, err := os.Stat(path)
	if err != nil {
		return ""
	}
	mbRecordingsMemoMu.Lock()
	defer mbRecordingsMemoMu.Unlock()
	if mbRecordingsMemo == nil || !info.ModTime().Equal(mbRecordingsMemoMTime) {
		mbRecordingsMemo, mbRecordingsMemoMTime = readMBRecordings(path), info.ModTime()
	}
	return mbRecordingsMemo[code].Recording
}

// attachMBRecordings:写法上级别够格的号唯一命中的录音 id,记成一种强 id(级别跟号一样),同一个录音 id 的写法连证据边。
func attachMBRecordings(vs []songVariant, recs map[string]mbISRCRecord) {
	for i := range vs {
		v := &vs[i]
		var add []songGradedID
		for _, g := range v.ids {
			if g.ns != songIDISRC || g.level < songIDVerified {
				continue
			}
			rec, ok := recs[g.id]
			if !ok || rec.Recording == "" {
				continue
			}
			dup := false
			for j := range add {
				if add[j].id == rec.Recording {
					add[j].level = max(add[j].level, g.level)
					dup = true
				}
			}
			if !dup {
				add = append(add, songGradedID{ns: songIDMBRecording, id: rec.Recording, level: g.level})
			}
		}
		v.ids = append(v.ids, add...)
	}
}
