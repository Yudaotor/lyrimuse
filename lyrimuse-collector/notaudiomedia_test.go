package main

import "testing"

// notAudioMedia / extract:Apple Music 放 MV 时不能拿视频时长当曲长。
//
// 现象:「MV 有一些额外的内容,导致和实际歌词对不上」。视频时长 = 歌 +
// 前导对白 + 尾字幕,当曲长用会同时打坏三处(见 notAudioMedia 头注)。实测陶喆
// 《In the Morning》歌曲 212.1s(iTunes entity=song),MV 只要多 30s 就跨过
// durationMismatch 那道 12% 线。
func TestNotAudioMedia(t *testing.T) {
	cases := []struct {
		name  string
		state map[string]any
		want  bool
	}{
		// —— mediaType 一律不参与判据(实测:MV 也报 Music,这个字段认不出 MV)——
		{"mediaType=Music:不参与判据", map[string]any{"mediaType": mediaTypeMusic}, false},
		// 这一条钉的是**负面结论**:哪怕真有播放器报 Video,也不能据此关掉时长打分。
		// Safari 放 YouTube Music 本来就是视频站,反判会把一整个播放器的时长证据静默关掉,
		// 而对 Apple Music 的 MV(唯一确认的现场)收益为零。
		{"mediaType=Video:仍不参与判据", map[string]any{"mediaType": "MRMediaRemoteMediaTypeVideo"}, false},
		{"字段缺失:按音频处理(行为跟改动前一样)", map[string]any{"title": "x"}, false},

		// —— mediaKind(Music.app / JXA):唯一的判据。白名单,取值域从 sdef 的 eMdK 枚举读全 ——
		{"mediaKind=song:是音频", map[string]any{"mediaKind": "song"}, false},
		{"mediaKind=music video:不是音频", map[string]any{"mediaKind": "music video"}, true},
		{"mediaKind=movie:不是音频", map[string]any{"mediaKind": "movie"}, true},
		{"mediaKind=TV show:不是音频", map[string]any{"mediaKind": "TV show"}, true},
		// unknown 刻意**不**算视频:本地导入的文件在这个字段上报什么还没实测,
		// 宁可保持现状也不要误伤一整类曲目。这是白名单而不是反判的全部理由。
		{"mediaKind=unknown:按音频处理,不误伤本地文件", map[string]any{"mediaKind": "unknown"}, false},

		// —— 真实现场逐字复刻(用户放陶喆《In the Morning》的 MV)——
		// media-control 报 Music、Music.app 报 music video:**只有后者说了实话**。
		{"真实 MV 现场:mediaType 说 Music 也拦得住", map[string]any{"mediaType": mediaTypeMusic, "mediaKind": "music video"}, true},
		{"真实音频现场(PRINCE):两个都说是歌", map[string]any{"mediaType": mediaTypeMusic, "mediaKind": "song"}, false},
	}
	for _, c := range cases {
		if got := notAudioMedia(c.state); got != c.want {
			t.Errorf("%s: notAudioMedia = %v, want %v", c.name, got, c.want)
		}
	}
}

// extract:认出 MV 之后,交给歌词解析的时长必须是"未知"(0),而 Duration 本身原样保留。
//
// 0 之所以是对的,是因为歌词解析那边全都按"未知"处理:match.go 的时长打分整段挂在
// `durationSecs > 0` 下,enrich.go 的 durationMismatch 任一方为 0 也不触发。
// Duration 不能跟着置 0:打卡门槛读它,置 0 就退成 240 秒 —— 真机坐实过,方大同《黑洞里》
// MV 214.6 秒完整看完,Last.fm 和 ListenBrainz 都没记上(02 章决策 49)。
func TestExtractMusicVideoDurationIsUnknown(t *testing.T) {
	// 载荷逐字来自的真实现场(用户当场放的 MV)。注意 mediaType 是 Music ——
	// 拦住它的是 mediaKind。
	mv := map[string]any{
		"title": "In the Morning", "artist": "陶喆", "album": "",
		"bundleIdentifier": "com.apple.Music",
		"duration":         232.857, "elapsedTime": 12.0, "playing": true,
		"mediaType": mediaTypeMusic, "mediaKind": "music video",
	}
	s := extract(mv)
	if !s.NotAudio {
		t.Fatal("mediaKind=music video → NotAudio 必须为真")
	}
	if s.lyricsDurationSecs() != 0 {
		t.Fatalf("MV 交给歌词解析的时长必须按未知(0)处理,得到 %.3f", s.lyricsDurationSecs())
	}
	if s.Duration != 232.857 {
		t.Fatalf("MV 的 Duration 本身必须原样保留(打卡门槛读它),得到 %.3f", s.Duration)
	}
	if listenThreshold(s.Duration) != 232.857/2 {
		t.Fatalf("MV 的打卡门槛不该退成缺时长的 %v 秒", listenCapSecs)
	}
	// 其余字段一个都不受影响。
	if s.Title != "In the Morning" || s.Artist != "陶喆" || !s.Playing || s.Elapsed != 12.0 {
		t.Fatalf("其余字段不该动,得到 %+v", s)
	}

	// 真实曲目载荷(同一天同一台机器,PRINCE《Annie Christian》):时长原样,一个字都不动。
	song := map[string]any{
		"title": "Annie Christian", "artist": "PRINCE", "bundleIdentifier": "com.apple.Music",
		"duration": 262.799, "playing": true,
		"mediaType": mediaTypeMusic, "mediaKind": "song",
	}
	n := extract(song)
	if n.NotAudio || n.Duration != 262.799 {
		t.Fatalf("普通曲目必须保留时长,得到 notAudio=%v duration=%.3f", n.NotAudio, n.Duration)
	}

	// 电台那条路不受影响:它有自己的换算(整档节目 → 目录单曲时长),而且电台的
	// mediaType 报什么都不该改变这个行为 —— 两条闸是 switch 的两个分支,不会互相吃掉。
	radio := map[string]any{
		"title": "Juna", "artist": "Clairo", "bundleIdentifier": "com.apple.Music",
		"duration": 3390.122, "playing": true,
		"radioStationHash": "CgkIBRoFwOSKqxkQBA", "catalogDurationSecs": 226.283,
	}
	if got := extract(radio); !got.Radio || got.Duration != 226.283 {
		t.Fatalf("电台仍走目录曲长,得到 radio=%v duration=%.3f", got.Radio, got.Duration)
	}
}
