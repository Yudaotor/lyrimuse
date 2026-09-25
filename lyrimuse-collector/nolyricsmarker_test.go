package main

import "testing"

// "曲库里有这首歌、但平台上没有歌词文本"这条信号的守卫。
//
// 起因是现象是「为什么这首歌搜不到歌词」(Iris / OLORUNNS):网易云和 QQ 都精准命中了
// 曲目(歌名/歌手/专辑/时长四项全中),但两家都没有歌词文本,而弹窗显示的是跟"十个源
// 都没搜到这首歌"一模一样的那句话。完整设计见 scoredLyricCandidateResult.TrackFoundNoLyrics。
//
// 这里钉死的是**判据的边界**——判据写成 `lrc == ""` 是不够的:网易云对这类曲目回的是
// 两行署名占位,一条都认不出来。下面第一个用例就是那次实测的原文。

// 判据本身:哪些正文算"平台没有歌词"。两个源共用这一把尺子(netease.go / qq.go 各自的
// 判据都调 isCreditOnlyLRC),所以这里连着一起钉。
func TestNoLyricsVerdictOnRealWorldBodies(t *testing.T) {
	cases := []struct {
		name string
		lrc  string
		want bool
	}{
		{
			// 实测原文(网易云 id=3406605267,Iris / OLORUNNS)。**没有词的歌
			// 最典型的形态不是空串**,是几行带时间戳的署名占位 —— 判据按空串写就全漏。
			name: "网易云的署名占位(实测原文)",
			lrc:  "[00:00.00-1] 作曲 : John Rzeznik\n[00:00.00-1] 制作人 : OLORUNNS\n",
			want: true,
		},
		{
			// QQ 实测形态:retcode -1901,响应里压根没有 lyric 字段 到 空串。
			name: "空正文",
			lrc:  "",
			want: true,
		},
		{
			// 有真词就绝不能报"平台没有歌词"——这是这条信号最不能犯的错:它会让用户以为
			// 平台没收录,而其实是我们这边没选中。
			name: "正常的带时间戳歌词",
			lrc:  "[00:12.00]第一句\n[00:15.30]第二句\n[00:18.90]第三句\n[00:22.10]第四句\n",
			want: false,
		},
		{
			// 署名行 + 真正的歌词正文:平台**是有词的**,只是前面几行是职员表。
			name: "署名行后面跟着真歌词",
			lrc:  "[00:00.00]作词 : 甲\n[00:01.00]作曲 : 乙\n[00:12.00]第一句\n[00:15.30]第二句\n[00:18.90]第三句\n",
			want: false,
		},
		{
			// 没有时间戳的纯文本歌词:平台有词(自动兜底那路会按 plainTextFallback 采纳),
			// 报成"平台没有歌词"是错的。
			name: "无时间戳的纯文本歌词",
			lrc:  "第一句\n第二句\n第三句\n第四句\n",
			want: false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := isCreditOnlyLRC(c.lrc); got != c.want {
				t.Errorf("isCreditOnlyLRC(%q) = %v, want %v", c.lrc, got, c.want)
			}
		})
	}
}

// noLyricsMarkers:从各源应答里摘出标记。钉三件事——带上曲目元数据、可以同时多条、
// 与纯音乐互斥。
func TestNoLyricsMarkers(t *testing.T) {
	raw := map[string]lyricSourceResult{
		"netease": {source: "netease", ne: neteaseInfo{
			TrackFoundNoLyrics: true,
			Title:              "Iris", Artist: "OLORUNNS", Album: "Iris", DurationSecs: 167.221,
		}},
		"qq": {source: "qq", trackFoundNoLyrics: true,
			matchTitle: "Iris", matchArtist: "OLORUNNS", matchAlbum: "Iris", srcDur: 167},
		"kugou": {source: "kugou", lyr: "[00:12.00]有词\n"},
	}

	got := noLyricsMarkers(raw, nil)
	// ① 两个源都命中就出两条 —— 界面要说"网易云音乐、QQ音乐 都找到了这首歌",不是只说一个。
	if len(got) != 2 {
		t.Fatalf("想要 2 条标记(netease+qq),拿到 %d 条: %+v", len(got), got)
	}
	// 源序按 lyricSourceNames 固定,不跟到达序走。
	if got[0].Source != "netease" || got[1].Source != "qq" {
		t.Errorf("源序不对,想要 netease,qq,拿到 %s,%s", got[0].Source, got[1].Source)
	}
	for _, m := range got {
		if !m.TrackFoundNoLyrics || m.Score != -1 {
			t.Errorf("%s: 标记必须是 TrackFoundNoLyrics + Score:-1(搭车语义,不参与打分/排序), 拿到 %+v", m.Source, m)
		}
		// ② 元数据必须带上 —— 用户的原始疑问是"是不是搜错歌了",答这个问题全靠它。
		if m.Title != "Iris" || m.Artist != "OLORUNNS" || m.Album != "Iris" || m.SourceReportedDurationSecs <= 0 {
			t.Errorf("%s: 曲目元数据没带全: %+v", m.Source, m)
		}
	}

	// ③ 与纯音乐互斥:同一个源既被判纯音乐又说没词是自相矛盾,以纯音乐为准(更强的结论)。
	withInstrumental := noLyricsMarkers(raw, &scoredLyricCandidateResult{Source: "netease", Score: -1, Instrumental: true})
	if len(withInstrumental) != 1 || withInstrumental[0].Source != "qq" {
		t.Errorf("网易云已被判纯音乐时,它那条标记该让位,只剩 qq;拿到 %+v", withInstrumental)
	}

	// 没有任何源命中时返回空,别让弹窗拿到一个空壳分支。
	if m := noLyricsMarkers(map[string]lyricSourceResult{"kugou": raw["kugou"]}, nil); len(m) != 0 {
		t.Errorf("没有源命中时该返回空,拿到 %+v", m)
	}
}

// 标记绝不能被当成候选:它会污染"这个源给出了候选"的判定,让弹窗把"有歌没词"显示成
// "已给出候选",也会让 LyricsSourcesSeen 误以为这个源已经交过货、不再重搜。
func TestNoLyricsMarkerIsNotACandidate(t *testing.T) {
	marker := scoredLyricCandidateResult{Source: "netease", Score: -1, TrackFoundNoLyrics: true}
	real := scoredLyricCandidateResult{Source: "kugou", Score: 100, Lyrics: "[00:12.00]有词\n"}
	scored := []scoredLyricCandidateResult{marker, real}

	// LyricsSourcesSeen 的口径(onlyValid=true):标记是负分,不算"给出了可用候选"。
	if seen := lyricSourcesWithCandidates(scored); len(seen) != 1 || seen[0] != "kugou" {
		t.Errorf("标记不该算进 lyricSourcesWithCandidates(会挡掉后续重搜),拿到 %v", seen)
	}
	// responded 的口径(不看分数):算应答了——它确实回答了"我这儿有这首歌、只是没词",
	// 不该再被报一个"未给出候选"的失败原因。跟 Instrumental 标记同一套语义。
	if resp := lyricSourcesResponded(scored); !containsString(resp, "netease") {
		t.Errorf("标记该算进 lyricSourcesResponded(它确实答了),拿到 %v", resp)
	}
}

// 变体轮合并:标记不能占住源位置,把另一轮真搜到的候选顶掉;而某个源在别的轮真搜到了词,
// 它那条标记就该消失(结论已经不成立),别的源的标记不受影响。
func TestMergeRoundsKeepsNoLyricsMarkersSeparateFromCandidates(t *testing.T) {
	neMarker := scoredLyricCandidateResult{Source: "netease", Score: -1, TrackFoundNoLyrics: true, Title: "Iris"}
	qqMarker := scoredLyricCandidateResult{Source: "qq", Score: -1, TrackFoundNoLyrics: true, Title: "Iris"}
	// 变体轮网易云真搜到了词。
	neReal := scoredLyricCandidateResult{
		Source: "netease", Score: 0,
		Lyrics: "[00:12.00]第一句\n[00:15.30]第二句\n[00:18.90]第三句\n",
		Title:  "Iris", Artist: "OLORUNNS",
	}

	out := mergeLyricCandidateRounds("OLORUNNS", "Iris", "Iris", 167,
		[]scoredLyricCandidateResult{neMarker, qqMarker}, []scoredLyricCandidateResult{neReal})

	var gotReal, gotMarkers int
	var markerSources []string
	for _, r := range out {
		if r.TrackFoundNoLyrics {
			gotMarkers++
			markerSources = append(markerSources, r.Source)
			continue
		}
		gotReal++
	}
	// 网易云那条真候选必须活下来(标记没有占住它的位置)。
	if gotReal != 1 {
		t.Errorf("变体轮的网易云真候选该留下,真候选数=%d: %+v", gotReal, out)
	}
	// 网易云的标记该消失(它已经有词了),QQ 的该留着。
	if gotMarkers != 1 || (len(markerSources) > 0 && markerSources[0] != "qq") {
		t.Errorf("合并后该只剩 qq 一条标记,拿到 %v", markerSources)
	}
}
