package main

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"sync"
	"syscall"
	"time"
)

// App → collector 的播放状态文件:App(Swift 侧 PlaybackStateFile.swift)整份写出「此刻在放什么、放到哪」,
// 这里只读、从不删改。
//
// 契约(字段含义、序号语义、新鲜度)与 Swift 侧一致,样例在 shared/testdata/playback-state/,两侧测试各跑一遍;
// 改字段两边一起改。
//
//   - 位置是播放器的真实播放时间(已含各播放器的修正),不含任何歌词偏移;读方按 secs + (now − at_ms) × rate 外推。
//   - play_seq:每开始播一首加一,同一首重新起播也加一;从停播回到同一首不加。只在同一个 app_pid 内比较。
//   - anchor_seq:位置每出现一次不连续(拖动、恢复、校准跳变)加一。
//   - holding:App 读不到播放器、还在宽限期里按住上一份状态,内容是旧的。
//   - App 平时每 5 秒重写一次;超过 appStateFreshness 没更新、进程不在、写着 exiting、契约版本不认识,都算不可用。
//
// 两份 App 短暂并存(新实例请走旧实例的那几秒)时两边都会写,认启动时刻更晚、进程还在的那一份。
type appStateTags struct {
	Title  string `json:"title"`
	Artist string `json:"artist"`
	Album  string `json:"album"`
}

type appStateRadio struct {
	StationHash string `json:"station_hash"`
	StationName string `json:"station_name,omitempty"`
	TalkBreak   bool   `json:"talk_break"`
	StationCard bool   `json:"station_card"`
}

type appStateTrack struct {
	PlaySeq        int64          `json:"play_seq"`
	Title          string         `json:"title"`
	Artist         string         `json:"artist"`
	Album          string         `json:"album"`
	Raw            appStateTags   `json:"raw"`
	AppliedFixRev  int64          `json:"applied_fix_rev"`
	DurationSecs   *float64       `json:"duration_secs,omitempty"`
	CatalogTrackID *int64         `json:"catalog_track_id,omitempty"`
	TrackNumber    *int           `json:"track_number,omitempty"`
	MediaType      string         `json:"media_type,omitempty"`
	MusicVideo     bool           `json:"music_video"`
	Radio          *appStateRadio `json:"radio,omitempty"`
	Ad             bool           `json:"ad"`
	// SpotifyTrackID:Spotify 原生播放时 `spotify:track:` 之后那段,App 按歌名歌手核对过;没有为空。
	SpotifyTrackID string `json:"spotify_track_id,omitempty"`
}

func (t *appStateTrack) key() string { return t.Title + "|" + t.Artist + "|" + t.Album }

type appStatePosition struct {
	Secs      float64 `json:"secs"`
	AtMs      int64   `json:"at_ms"`
	Rate      float64 `json:"rate"`
	AnchorSeq int64   `json:"anchor_seq"`
}

// at:在 t 时刻的位置(按写出时的速率外推,不早于写出时刻)。
func (p *appStatePosition) at(t time.Time) float64 {
	return p.Secs + max(t.Sub(time.UnixMilli(p.AtMs)).Seconds(), 0)*p.Rate
}

type appStateArtwork struct {
	SHA256  string `json:"sha256"`
	Mime    string `json:"mime"`
	Bytes   int    `json:"bytes"`
	PlaySeq int64  `json:"play_seq"`
}

type appStateRecord struct {
	Schema         int               `json:"schema"`
	AppPID         int               `json:"app_pid"`
	AppStartedAtMs int64             `json:"app_started_at_ms"`
	Seq            int64             `json:"seq"`
	WrittenAtMs    int64             `json:"written_at_ms"`
	State          string            `json:"state"`
	Player         string            `json:"player"`
	Track          *appStateTrack    `json:"track,omitempty"`
	Position       *appStatePosition `json:"position,omitempty"`
	Artwork        *appStateArtwork  `json:"artwork,omitempty"`
	Holding        bool              `json:"holding,omitempty"`
}

// hasTrack:App 此刻认下了一首在放 / 暂停着的歌。
func (r appStateRecord) hasTrack() bool {
	return r.Track != nil && (r.State == "playing" || r.State == "paused")
}

const (
	appStateSchema    = 1
	appStateFreshness = 15 * time.Second
)

type appStateAvailability string

const (
	appStateAvailable   appStateAvailability = "available"
	appStateMissing     appStateAvailability = "missing"
	appStateUnreadable  appStateAvailability = "unreadable"
	appStateUnsupported appStateAvailability = "unsupported_schema"
	appStateStale       appStateAvailability = "stale"
	appStateExiting     appStateAvailability = "exiting"
	appStateProcessGone appStateAvailability = "process_gone"
)

// appStateUsable 判一份已解出的记录此刻能不能用。纯函数,测试覆盖;alive 由调用方注入。
func appStateUsable(rec appStateRecord, now time.Time, alive func(pid int) bool) appStateAvailability {
	switch {
	case rec.Schema != appStateSchema:
		return appStateUnsupported
	case rec.State == "exiting":
		return appStateExiting
	case rec.AppPID <= 0 || !alive(rec.AppPID):
		return appStateProcessGone
	case now.Sub(time.UnixMilli(rec.WrittenAtMs)) > appStateFreshness:
		return appStateStale
	}
	return appStateAvailable
}

func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// appStateReader 按修改时间读播放状态文件,变了才解码。并发安全。
type appStateReader struct {
	path  string
	alive func(pid int) bool

	mu      sync.Mutex
	modTime time.Time
	size    int64
	rec     appStateRecord
	decoded bool
	broken  bool
}

func newAppStateReader(path string) *appStateReader {
	return &appStateReader{path: path, alive: processAlive}
}

// read 返回此刻的记录与它能不能用。文件没变就不重读;两份 App 并存时认启动更晚、进程还在的那一份。
func (r *appStateReader) read(now time.Time) (appStateRecord, appStateAvailability) {
	r.mu.Lock()
	defer r.mu.Unlock()
	info, err := os.Stat(r.path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return appStateRecord{}, appStateMissing
		}
		return appStateRecord{}, appStateUnreadable
	}
	if !r.decoded || !info.ModTime().Equal(r.modTime) || info.Size() != r.size {
		r.modTime, r.size = info.ModTime(), info.Size()
		raw, readErr := os.ReadFile(r.path)
		var next appStateRecord
		if readErr != nil || json.Unmarshal(raw, &next) != nil {
			r.broken = true
		} else {
			r.broken = false
			if !r.decoded || !appStateSuperseded(r.rec, next, r.alive) {
				r.rec, r.decoded = next, true
			}
		}
	}
	if r.broken {
		return appStateRecord{}, appStateUnreadable
	}
	return r.rec, appStateUsable(r.rec, now, r.alive)
}

// appStateSuperseded:next 是另一个更早启动、而更晚启动的那份还活着的 App 写的 —— 不采纳。纯函数,测试覆盖。
func appStateSuperseded(held, next appStateRecord, alive func(pid int) bool) bool {
	return next.AppPID != held.AppPID && next.AppStartedAtMs < held.AppStartedAtMs && held.AppPID > 0 && alive(held.AppPID)
}

// appStateSnapshot 把一份记录换成 collector 的快照结构,位置外推到 now。没有曲目时是零值(= 没在放)。
func appStateSnapshot(rec appStateRecord, now time.Time) snapshot {
	if !rec.hasTrack() {
		return snapshot{}
	}
	t := rec.Track
	s := snapshot{
		Title: t.Title, Artist: t.Artist, Album: t.Album, Bundle: rec.Player,
		Playing: rec.State == "playing", Radio: t.Radio != nil, NotAudio: t.MusicVideo,
	}
	if t.DurationSecs != nil {
		s.Duration, s.ReportedDuration = *t.DurationSecs, *t.DurationSecs
	}
	if p := rec.Position; p != nil {
		pos := p.at(now)
		if s.Duration > 0 && pos > s.Duration {
			pos = s.Duration
		}
		s.Position, s.AnchorTS, s.Rate = pos, now, p.Rate
	}
	return s
}
