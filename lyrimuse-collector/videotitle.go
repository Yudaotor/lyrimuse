package main

import (
	"regexp"
	"strings"
)

// 视频标题解析:播放器放的是视频(YouTube / 网页播放器的 MV、翻唱、节目特辑)时,曲名位是视频标题、
// 歌手位常常是频道名或本地化的名字。这里把标题归成几类,只有 MV 类拆出「演唱者 / 歌名」:
//
//   - MV:标题带 Official Video / Official MV / M/V / Official Audio / Lyric Video / Visualizer 这类标记。
//     拆法依次试:引号包着的歌名(「BTS (방탄소년단) ‘Merry Go Round’ Official MV」)、第一个破折号
//     (「Musiq Soulchild - Buddy (Official Video)」)、冒号前是播放器报的歌手(「A x B: 歌名」),
//     都不是就把标记剥掉、歌手照用播放器报的(「Stay (Official Video)」)。
//   - 翻唱:「(Cover by X)」「Covered by X」「[COVER]」。拆出来是原唱,不该拿去当这首歌的身份。
//   - 节目特辑:「[Special]」「[SPECIAL VIDEO]」「Live Clip」、结尾全大写的「LIVE」。没有正式发行。
//
// 所有播放器通用,不看 bundle(同样的标题形状别的网页播放器也会报)。拆出来的写法只是**候选**:
// 打卡要 Last.fm 编目确认存在才用,查歌词 / 封面各自还有打分和核对。决策见 12 章 §4、09 章。

type videoTitleKind int

const (
	videoTitleNone videoTitleKind = iota
	videoTitleMusicVideo
	videoTitleCover
	videoTitleSpecial
)

// videoTitleIdentity 是解析结果。Artist / Song 只在 MusicVideo 时有值。
type videoTitleIdentity struct {
	Kind         videoTitleKind
	Artist, Song string
}

var (
	// videoTitleMarker:MV 类的标记。单独的「MV」「M/V」按整词认,「MVP」这种不算。
	videoTitleMarker = regexp.MustCompile(`(?i)\bofficial\s+(?:music\s+)?(?:video|mv|m/v|audio|lyric\s+video|visuali[sz]er)\b|\b(?:music|lyrics?)\s+video\b|\bm/v\b|\bmv\b|\bvisuali[sz]er\b|^\s*audio\s*$`)
	// videoTitleSpecial:节目特辑 / 现场片段。开头的方括号标签 [Special] / [SPECIAL VIDEO] 最常见。
	videoTitleSpecialTag = regexp.MustCompile(`(?i)^\s*[\[【(（]\s*special(?:\s+video|\s+clip|\s+stage)?\s*[\]】)）]|\blive\s+clip\b|\bkilling\s+voice\b`)
	// 结尾全大写的 LIVE(节目现场);「xxx - Live」这种正式发行的现场专辑曲目是首字母大写,不算。
	videoTitleTrailingLIVE = regexp.MustCompile(`\sLIVE\s*$`)
	// videoTitleCoverTag:没写翻唱者、只打了标签的翻唱(「[COVER] …」「(Cover)」)。
	videoTitleCoverTag = regexp.MustCompile(`(?i)[\[【(（]\s*cover\s*[\]】)）]`)
	// 引号包着的歌名。ASCII 单引号要求两侧是空白或首尾,免得把 I'm / don't 里的撇号当成引号。
	videoTitleQuoted = []*regexp.Regexp{
		regexp.MustCompile(`‘([^’]+)’`),
		regexp.MustCompile(`“([^”]+)”`),
		regexp.MustCompile(`「([^」]+)」`),
		regexp.MustCompile(`『([^』]+)』`),
		regexp.MustCompile(`"([^"]+)"`),
		regexp.MustCompile(`(?:^|\s)'([^']+)'(?:\s|$)`),
	}
	// 演唱者段结尾的括号别名:「BTS (방탄소년단)」「The Rose (더로즈)」。
	videoTitlePerformerAlias = regexp.MustCompile(`\s*[(（][^()（）]*[)）]\s*$`)
)

// parseVideoTitle 解析播放器报的「歌手 / 曲名」。认不出是视频标题时 Kind == videoTitleNone。
func parseVideoTitle(artist, title string) videoTitleIdentity {
	t := cleanMediaTag(title)
	if t == "" {
		return videoTitleIdentity{}
	}
	if _, _, ok := coverPerformerIdentity(t); ok || videoTitleCoverTag.MatchString(t) {
		return videoTitleIdentity{Kind: videoTitleCover}
	}
	if videoTitleSpecialTag.MatchString(t) || videoTitleTrailingLIVE.MatchString(t) {
		return videoTitleIdentity{Kind: videoTitleSpecial}
	}
	cleaned, ok := stripVideoTitleMarkers(t)
	if !ok {
		return videoTitleIdentity{}
	}
	performer, song := splitVideoTitle(cleanMediaTag(artist), cleaned)
	if normLoose(performer) == "" || normLoose(song) == "" {
		return videoTitleIdentity{}
	}
	return videoTitleIdentity{Kind: videoTitleMusicVideo, Artist: performer, Song: song}
}

// stripVideoTitleMarkers 剥掉 MV 标记:带标记的括号段、「| 带标记的那一段」、结尾裸露的标记。
// 第二个返回值 = 标题里确实有 MV 标记(没有标记就不是 MV,原样返回 false)。
func stripVideoTitleMarkers(t string) (string, bool) {
	found := false
	// 竖线分段:带标记的那一段整段去掉(「Utopia | Official Audio」)。
	if strings.Contains(t, "|") {
		var keep []string
		for _, part := range strings.Split(t, "|") {
			if videoTitleMarker.MatchString(part) {
				found = true
				continue
			}
			keep = append(keep, part)
		}
		t = strings.Join(keep, "|")
	}
	// 括号段:内容带标记的整段去掉,不限位置(「(Official Video)」「[MV]」「【Official MV】」)。
	var b strings.Builder
	last := 0
	for _, seg := range coverBracketSegments(t) {
		if videoTitleMarker.MatchString(seg.inner) {
			found = true
			b.WriteString(t[last:seg.start])
			b.WriteString(" ")
			last = seg.end
		}
	}
	b.WriteString(t[last:])
	t = b.String()
	// 结尾裸露的标记(「… Official MV」「… M/V」)。
	for {
		loc := videoTitleMarker.FindStringIndex(t)
		if loc == nil {
			break
		}
		found = true
		t = t[:loc[0]] + " " + t[loc[1]:]
	}
	if !found {
		return "", false
	}
	t = strings.Join(strings.Fields(t), " ")
	t = strings.Trim(t, " -–—|:：")
	return normEnrichTitle(t), true
}

// splitVideoTitle 从剥掉标记的标题里拆出演唱者和歌名,拆不出就是「播放器报的歌手 / 整个标题」。
func splitVideoTitle(artist, t string) (performer, song string) {
	for _, re := range videoTitleQuoted {
		loc := re.FindStringSubmatchIndex(t)
		if loc == nil {
			continue
		}
		song = strings.TrimSpace(t[loc[2]:loc[3]])
		performer = videoTitlePerformer(t[:loc[0]])
		if performer == "" {
			performer = artist
		}
		return performer, song
	}
	for _, sep := range []string{" - ", " – ", " — "} {
		if i := strings.Index(t, sep); i >= 0 {
			if p := videoTitlePerformer(t[:i]); p != "" {
				return p, strings.TrimSpace(t[i+len(sep):])
			}
		}
	}
	// 冒号:只有冒号前面包含播放器报的歌手时才当「演唱者: 歌名」,免得把「Interlude: Shadow」拆开。
	if i := strings.Index(t, ": "); i > 0 && artist != "" && strings.Contains(strings.ToLower(t[:i]), strings.ToLower(artist)) {
		return videoTitlePerformer(t[:i]), strings.TrimSpace(t[i+2:])
	}
	return artist, t
}

// videoTitlePerformer 清理演唱者段:去掉首尾的分隔符(含「IU(아이유) _ 'Blueming'」里的下划线)和结尾的括号别名。
func videoTitlePerformer(s string) string {
	const seps = " -–—|:：_"
	s = strings.Trim(s, seps)
	s = videoTitlePerformerAlias.ReplaceAllString(s, "")
	return strings.Trim(s, seps)
}

// titleSplitIdentity 是查歌词、补专辑两处「从标题里拆身份」的共用入口:认得出 MV 就用 parseVideoTitle 拆出来的
// 写法(isMusicVideo = true,调用方把时长当未知:MV 比录音室版长,片头片尾常多出几秒到几十秒);认不出(含翻唱、
// 特辑)就按第一个破折号拆(albumHintTitleSplit),跟接入 MV 解析之前逐字相同。
func titleSplitIdentity(artist, title string) (splitArtist, song string, isMusicVideo, ok bool) {
	if v := parseVideoTitle(artist, title); v.Kind == videoTitleMusicVideo {
		if v.Artist == cleanMediaTag(artist) && v.Song == cleanMediaTag(title) {
			return "", "", false, false
		}
		return v.Artist, v.Song, true, true
	}
	a, s, ok := albumHintTitleSplit(title)
	return a, s, false, ok
}
