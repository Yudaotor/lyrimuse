package main

import (
	"regexp"
	"strconv"
	"strings"
	"time"
)

// 听歌报告用哪种语言写:App 把自己的界面语言写进 features.json 的 report_language(zh-hans / zh-hant / en),报告里的
// 固定用语(标题、第一行、小节名、三套预设模板、各平台排版的标签)按它从 digestWordTable 取;歌名、歌手名原样。
// 缺这个键、认不得的值按简体。每一句里的 {名字} 由调用处换成值(digestWords.f),Core `ReportWords` 用同一张表、
// 同一种换法,两边对得上靠共用样例 shared/testdata/notify/words.json。
// 判「这个渠道收到过这一期没有」的键照旧用简体标题(digestHansTitle,再经 digestTitleKey 去掉今日 / 昨日),切换语言不会把同一期当成新的一期。见 15 章决策 98。

type digestLang string

const (
	digestLangHans digestLang = "zh-hans"
	digestLangHant digestLang = "zh-hant"
	digestLangEn   digestLang = "en"
	digestLangJa   digestLang = "ja"
	digestLangKo   digestLang = "ko"
	digestLangEs   digestLang = "es"
	digestLangFr   digestLang = "fr"
	digestLangDe   digestLang = "de"
	digestLangIt   digestLang = "it"
	digestLangPtBR digestLang = "pt-br"
	digestLangVi   digestLang = "vi"
	digestLangRu   digestLang = "ru"
)

func parseDigestLang(s string) digestLang {
	switch l := digestLang(strings.ToLower(strings.TrimSpace(s))); l {
	case digestLangHant, digestLangEn, digestLangJa, digestLangKo, digestLangEs, digestLangFr, digestLangDe, digestLangIt, digestLangPtBR, digestLangVi, digestLangRu:
		return l
	}
	return digestLangHans
}

// digestWords 是一种语言的那张表。
type digestWords map[string]string

func digestWordsFor(lang digestLang) digestWords {
	if w, ok := digestWordTable[lang]; ok {
		return w
	}
	return digestWordTable[digestLangHans]
}

// reportLang:当前报告语言;还没读过 features.json(零值)时按简体。
func reportLang() digestLang { return parseDigestLang(string(features().ReportLanguage)) }

// dw:当前报告语言的那张表。
func dw() digestWords { return digestWordsFor(reportLang()) }

// f 取 key 那一句,把 {名字} 换成 kv 里的值(名字、值交替给)。只扫那一句本身一遍:换进去的歌名里带 {n} 这类字样时
// 原样留着,不会再被后面的名字换掉。
func (w digestWords) f(key string, kv ...string) string {
	vals := make(map[string]string, len(kv)/2)
	for i := 0; i+1 < len(kv); i += 2 {
		vals[kv[i]] = kv[i+1]
	}
	return digestWordSlotRe.ReplaceAllStringFunc(w[key], func(m string) string {
		if v, ok := vals[m[1:len(m)-1]]; ok {
			return v
		}
		return m
	})
}

var digestWordSlotRe = regexp.MustCompile(`\{[a-z_]+\}`)

// count:带数量 {n} 的那一句;数量属于 one / few / many(pluralForm)且表里有 key_one / key_few / key_many 时用那一句,
// 否则用 key 本身(other)。
func (w digestWords) count(key string, n int, kv ...string) string {
	if form := w.pluralForm(n); form != "other" {
		if _, ok := w[key+"_"+form]; ok {
			key += "_" + form
		}
	}
	return w.f(key, append([]string{"n", strconv.Itoa(n)}, kv...)...)
}

// pluralForm:数量 n 在这张表的语言里属于哪一类(CLDR 整数规则),同 Core UILanguage.pluralCategory。
// 表里 plural_rule 是 ru 的按俄语:个位 1 且末两位不是 11 → one,个位 2～4 且末两位不是 12～14 → few,其余 many;
// 别的语言 1 是 one,表里有 zero_is_one 的(法语、葡萄牙语)0 也是 one,其余 other。
func (w digestWords) pluralForm(n int) string {
	if w["plural_rule"] == "ru" {
		if n < 0 {
			n = -n
		}
		mod10, mod100 := n%10, n%100
		switch {
		case mod10 == 1 && mod100 != 11:
			return "one"
		case mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14):
			return "few"
		}
		return "many"
	}
	if n == 1 || n == 0 && w["zero_is_one"] != "" {
		return "one"
	}
	return "other"
}

// date:标题里的日期(本地)。
func (w digestWords) date(t time.Time) string {
	return w.f("date", "mm", t.Format("01"), "dd", t.Format("02"), "m", strconv.Itoa(int(t.Month())), "mon", t.Format("Jan"),
		"d", strconv.Itoa(t.Day()))
}

// month:带年、月的那一句,月份既有数字 {month} 也有月名 {month_name}(monthName)。
func (w digestWords) month(key string, year int, month time.Month) string {
	return w.f(key, "year", strconv.Itoa(year), "month", strconv.Itoa(int(month)), "month_name", w.monthName(month))
}

// monthName:表里有 month_names(逗号隔开的十二个月名)时取它,没有用英文月名。
func (w digestWords) monthName(month time.Month) string {
	if names := strings.Split(w["month_names"], ","); len(names) == 12 {
		return names[month-1]
	}
	return month.String()
}

// digestHansTitle:简体的标题,推送记录里认「同一期」用(notifyMessage.Key)。title 是按某种语言算标题的函数。
func digestHansTitle(title func(digestWords) string) string {
	return title(digestWordsFor(digestLangHans))
}

// digestWordTable:各种语言的用语。简体那份就是引擎一直推出去的原文,改它等于改所有简体用户收到的报告。
var digestWordTable = map[digestLang]digestWords{
	digestLangHans: {
		"date":            "{mm}-{dd}",
		"title_today":     "🎧 今日听歌报告（{date}）",
		"title_yesterday": "🎧 昨日听歌报告（{date}）",
		"title_day":       "🎧 听歌报告（{date}）",
		"title_week":      "🎵 上周听歌小结（{from}~{to}）",
		"title_month":     "📅 {year} 年 {month} 月听歌小结",
		"title_year":      "🏆 {year} 年度听歌小结",
		"title_sample":    "🎧 听歌报告示例",
		"plays":           "共播放 {n} 次",
		"plays_truncated": "共播放 {n} 次以上（记录太多，只统计了最近这些）",
		"compare":         "（{label} {prev}，{change}）",
		"flat":            "持平",
		"duration_hm":     " · 约 {h} 小时 {m} 分",
		"duration_m":      " · 约 {m} 分",
		"value_hm":        "{h} 小时 {m} 分",
		"value_m":         "{m} 分",
		"prev_week":       "前一周",
		"prev_month":      "{month} 月",
		"prev_month_year": "{year} 年 {month} 月",
		"prev_year":       "{year} 年",
		"new_artists":     "新听了 {n} 位歌手",
		"names_lead":      "：",
		"name_sep":        "、",
		"more":            " 等",
		"colon":           "：",
		"head_artists":    "Top 歌手",
		"head_albums":     "Top 专辑",
		"head_tracks":     "Top 歌曲",
		"col_artists":     "歌手",
		"col_albums":      "专辑",
		"col_tracks":      "歌曲",
		"item":            "{i}. {name}（{n}）",
		"pair":            "{artist} - {name}",
		"most_played":     "最常听",
		"brief_line":      "{label}：{name} · {n}",
		"label_artist":    "歌手",
		"label_album":     "专辑",
		"label_track":     "歌曲",
		"link":            "在 {source} 上看完整榜单",
		"footer":          "Lyrimuse · 数据来自 {source}",
		"cover":           "封面",
		"keyword":         "听歌",
		"preset_full": "{summary}\n\nTop 歌手：\n{top_artists}\n\nTop 专辑：\n{top_albums}\n\nTop 歌曲：\n{top_tracks}\n\n" +
			"新听了 {new_artists} 位歌手：{new_artist_names}",
		"preset_brief": "{summary}\n最常听的歌手：{top_artist}\n最常听的专辑：{top_album}\n最常听的歌曲：{top_track}\n" +
			"新听了 {new_artists} 位歌手：{new_artist_names}",
		"preset_overview": "{summary}\n新听了 {new_artists} 位歌手",
	},
	digestLangHant: {
		"date":            "{mm}-{dd}",
		"title_today":     "🎧 今日聽歌報告（{date}）",
		"title_yesterday": "🎧 昨日聽歌報告（{date}）",
		"title_day":       "🎧 聽歌報告（{date}）",
		"title_week":      "🎵 上週聽歌小結（{from}~{to}）",
		"title_month":     "📅 {year} 年 {month} 月聽歌小結",
		"title_year":      "🏆 {year} 年度聽歌小結",
		"title_sample":    "🎧 聽歌報告範例",
		"plays":           "共播放 {n} 次",
		"plays_truncated": "共播放 {n} 次以上（記錄太多，只統計了最近這些）",
		"compare":         "（{label} {prev}，{change}）",
		"flat":            "持平",
		"duration_hm":     " · 約 {h} 小時 {m} 分",
		"duration_m":      " · 約 {m} 分",
		"value_hm":        "{h} 小時 {m} 分",
		"value_m":         "{m} 分",
		"prev_week":       "前一週",
		"prev_month":      "{month} 月",
		"prev_month_year": "{year} 年 {month} 月",
		"prev_year":       "{year} 年",
		"new_artists":     "新聽了 {n} 位歌手",
		"names_lead":      "：",
		"name_sep":        "、",
		"more":            " 等",
		"colon":           "：",
		"head_artists":    "Top 歌手",
		"head_albums":     "Top 專輯",
		"head_tracks":     "Top 歌曲",
		"col_artists":     "歌手",
		"col_albums":      "專輯",
		"col_tracks":      "歌曲",
		"item":            "{i}. {name}（{n}）",
		"pair":            "{artist} - {name}",
		"most_played":     "最常聽",
		"brief_line":      "{label}：{name} · {n}",
		"label_artist":    "歌手",
		"label_album":     "專輯",
		"label_track":     "歌曲",
		"link":            "在 {source} 上看完整排行",
		"footer":          "Lyrimuse · 資料來自 {source}",
		"cover":           "封面",
		"keyword":         "聽歌",
		"preset_full": "{summary}\n\nTop 歌手：\n{top_artists}\n\nTop 專輯：\n{top_albums}\n\nTop 歌曲：\n{top_tracks}\n\n" +
			"新聽了 {new_artists} 位歌手：{new_artist_names}",
		"preset_brief": "{summary}\n最常聽的歌手：{top_artist}\n最常聽的專輯：{top_album}\n最常聽的歌曲：{top_track}\n" +
			"新聽了 {new_artists} 位歌手：{new_artist_names}",
		"preset_overview": "{summary}\n新聽了 {new_artists} 位歌手",
	},
	digestLangEn: {
		"date":            "{mon} {d}",
		"title_today":     "🎧 Today's Listening Report ({date})",
		"title_yesterday": "🎧 Yesterday's Listening Report ({date})",
		"title_day":       "🎧 Listening Report ({date})",
		"title_week":      "🎵 Last Week's Listening Digest ({from} – {to})",
		"title_month":     "📅 {month_name} {year} Listening Digest",
		"title_year":      "🏆 {year} Listening Digest",
		"title_sample":    "🎧 Sample Listening Report",
		"plays":           "{n} plays",
		"plays_one":       "{n} play",
		"plays_truncated": "{n}+ plays (too many listens, only the most recent were counted)",
		"compare":         " (vs. {prev} {label}, {change})",
		"flat":            "no change",
		"duration_hm":     " · about {h} h {m} min",
		"duration_m":      " · about {m} min",
		"value_hm":        "{h} h {m} min",
		"value_m":         "{m} min",
		"prev_week":       "the week before",
		"prev_month":      "in {month_name}",
		"prev_month_year": "in {month_name} {year}",
		"prev_year":       "in {year}",
		"new_artists":     "{n} new artists",
		"new_artists_one": "{n} new artist",
		"names_lead":      ": ",
		"name_sep":        ", ",
		"more":            " and more",
		"colon":           ":",
		"head_artists":    "Top artists",
		"head_albums":     "Top albums",
		"head_tracks":     "Top tracks",
		"col_artists":     "Artists",
		"col_albums":      "Albums",
		"col_tracks":      "Tracks",
		"item":            "{i}. {name} ({n})",
		"pair":            "{artist} - {name}",
		"most_played":     "Most played",
		"brief_line":      "{label}: {name} · {n}",
		"label_artist":    "Artist",
		"label_album":     "Album",
		"label_track":     "Track",
		"link":            "See the full chart on {source}",
		"footer":          "Lyrimuse · Data from {source}",
		"cover":           "Cover",
		"keyword":         "Listening",
		"preset_full": "{summary}\n\nTop artists:\n{top_artists}\n\nTop albums:\n{top_albums}\n\nTop tracks:\n{top_tracks}\n\n" +
			"New artists ({new_artists}): {new_artist_names}",
		"preset_brief":    "{summary}\nTop artist: {top_artist}\nTop album: {top_album}\nTop track: {top_track}\nNew artists ({new_artists}): {new_artist_names}",
		"preset_overview": "{summary}\nNew artists: {new_artists}",
	},
	digestLangJa: {
		"brief_line":      "{label}：{name} · {n}",
		"col_albums":      "アルバム",
		"col_artists":     "アーティスト",
		"col_tracks":      "曲",
		"colon":           "：",
		"compare":         "（{label}：{prev}、{change}）",
		"cover":           "アートワーク",
		"date":            "{m}月{d}日",
		"duration_hm":     " · 約{h}時間{m}分",
		"duration_m":      " · 約{m}分",
		"flat":            "変化なし",
		"footer":          "Lyrimuse · データ提供：{source}",
		"head_albums":     "トップアルバム",
		"head_artists":    "トップアーティスト",
		"head_tracks":     "トップ曲",
		"item":            "{i}. {name}（{n}）",
		"keyword":         "リスニング",
		"label_album":     "アルバム",
		"label_artist":    "アーティスト",
		"label_track":     "曲",
		"link":            "{source}でランキング全体を見る",
		"more":            " など",
		"most_played":     "最も多く再生",
		"name_sep":        "、",
		"names_lead":      "：",
		"new_artists":     "新しく聴いたアーティスト{n}組",
		"pair":            "{artist} - {name}",
		"plays":           "合計{n}回再生",
		"plays_truncated": "{n}回以上再生（記録が多いため、直近の分のみ集計）",
		"preset_brief":    "{summary}\n最も多く再生したアーティスト：{top_artist}\n最も多く再生したアルバム：{top_album}\n最も多く再生した曲：{top_track}\n新しく聴いたアーティスト（{new_artists}）：{new_artist_names}",
		"preset_full":     "{summary}\n\nトップアーティスト：\n{top_artists}\n\nトップアルバム：\n{top_albums}\n\nトップ曲：\n{top_tracks}\n\n新しく聴いたアーティスト（{new_artists}）：{new_artist_names}",
		"preset_overview": "{summary}\n新しく聴いたアーティスト：{new_artists}",
		"prev_month":      "{month}月",
		"prev_month_year": "{year}年{month}月",
		"prev_week":       "前週",
		"prev_year":       "{year}年",
		"title_day":       "🎧 リスニングレポート（{date}）",
		"title_month":     "📅 {year}年{month}月のリスニングまとめ",
		"title_sample":    "🎧 リスニングレポートのサンプル",
		"title_today":     "🎧 今日のリスニングレポート（{date}）",
		"title_week":      "🎵 先週のリスニングまとめ（{from}〜{to}）",
		"title_year":      "🏆 {year}年のリスニングまとめ",
		"title_yesterday": "🎧 昨日のリスニングレポート（{date}）",
		"value_hm":        "{h}時間{m}分",
		"value_m":         "{m}分",
	},
	digestLangKo: {
		"brief_line":      "{label}: {name} · {n}",
		"col_albums":      "앨범",
		"col_artists":     "아티스트",
		"col_tracks":      "노래",
		"colon":           ":",
		"compare":         " ({label} {prev}, {change})",
		"cover":           "아트워크",
		"date":            "{m}월 {d}일",
		"duration_hm":     " · 약 {h}시간 {m}분",
		"duration_m":      " · 약 {m}분",
		"flat":            "변동 없음",
		"footer":          "Lyrimuse · 데이터 출처: {source}",
		"head_albums":     "Top 앨범",
		"head_artists":    "Top 아티스트",
		"head_tracks":     "Top 노래",
		"item":            "{i}. {name} ({n})",
		"keyword":         "청취",
		"label_album":     "앨범",
		"label_artist":    "아티스트",
		"label_track":     "노래",
		"link":            "{source}에서 전체 차트 보기",
		"more":            " 등",
		"most_played":     "가장 많이 들음",
		"name_sep":        ", ",
		"names_lead":      ": ",
		"new_artists":     "새로 들은 아티스트 {n}명",
		"pair":            "{artist} - {name}",
		"plays":           "총 {n}회 재생",
		"plays_truncated": "{n}회 이상 재생 (기록이 많아 최근 기록만 집계)",
		"preset_brief":    "{summary}\n가장 많이 들은 아티스트: {top_artist}\n가장 많이 들은 앨범: {top_album}\n가장 많이 들은 노래: {top_track}\n새로 들은 아티스트 ({new_artists}): {new_artist_names}",
		"preset_full":     "{summary}\n\nTop 아티스트:\n{top_artists}\n\nTop 앨범:\n{top_albums}\n\nTop 노래:\n{top_tracks}\n\n새로 들은 아티스트 ({new_artists}): {new_artist_names}",
		"preset_overview": "{summary}\n새로 들은 아티스트: {new_artists}",
		"prev_month":      "{month}월",
		"prev_month_year": "{year}년 {month}월",
		"prev_week":       "지난주",
		"prev_year":       "{year}년",
		"title_day":       "🎧 청취 리포트 ({date})",
		"title_month":     "📅 {year}년 {month}월 청취 요약",
		"title_sample":    "🎧 청취 리포트 샘플",
		"title_today":     "🎧 오늘의 청취 리포트 ({date})",
		"title_week":      "🎵 지난주 청취 요약 ({from}~{to})",
		"title_year":      "🏆 {year}년 청취 요약",
		"title_yesterday": "🎧 어제의 청취 리포트 ({date})",
		"value_hm":        "{h}시간 {m}분",
		"value_m":         "{m}분",
	},
	digestLangEs: {
		"brief_line":      "{label}: {name} · {n}",
		"col_albums":      "Álbumes",
		"col_artists":     "Artistas",
		"col_tracks":      "Canciones",
		"colon":           ":",
		"compare":         " (frente a {prev} {label}, {change})",
		"cover":           "Portada",
		"date":            "{d}/{m}",
		"duration_hm":     " · unas {h} h {m} min",
		"duration_m":      " · unos {m} min",
		"flat":            "sin cambios",
		"footer":          "Lyrimuse · Datos de {source}",
		"head_albums":     "Álbumes más escuchados",
		"head_artists":    "Artistas más escuchados",
		"head_tracks":     "Canciones más escuchadas",
		"item":            "{i}. {name} ({n})",
		"keyword":         "escucha",
		"label_album":     "Álbum",
		"label_artist":    "Artista",
		"label_track":     "Canción",
		"link":            "Ver la clasificación completa en {source}",
		"month_names":     "enero,febrero,marzo,abril,mayo,junio,julio,agosto,septiembre,octubre,noviembre,diciembre",
		"more":            " y más",
		"most_played":     "Lo más escuchado",
		"name_sep":        ", ",
		"names_lead":      ": ",
		"new_artists":     "{n} artistas nuevos",
		"new_artists_one": "{n} artista nuevo",
		"pair":            "{artist} - {name}",
		"plays":           "{n} reproducciones",
		"plays_one":       "{n} reproducción",
		"plays_truncated": "Más de {n} reproducciones (demasiadas escuchas; solo se contaron las más recientes)",
		"preset_brief":    "{summary}\nArtista principal: {top_artist}\nÁlbum principal: {top_album}\nCanción principal: {top_track}\nArtistas nuevos ({new_artists}): {new_artist_names}",
		"preset_full":     "{summary}\n\nArtistas más escuchados:\n{top_artists}\n\nÁlbumes más escuchados:\n{top_albums}\n\nCanciones más escuchadas:\n{top_tracks}\n\nArtistas nuevos ({new_artists}): {new_artist_names}",
		"preset_overview": "{summary}\nArtistas nuevos: {new_artists}",
		"prev_month":      "en {month_name}",
		"prev_month_year": "en {month_name} de {year}",
		"prev_week":       "la semana anterior",
		"prev_year":       "en {year}",
		"title_day":       "🎧 Informe de escucha ({date})",
		"title_month":     "📅 Resumen de escucha de {month_name} de {year}",
		"title_sample":    "🎧 Ejemplo de informe de escucha",
		"title_today":     "🎧 Informe de escucha de hoy ({date})",
		"title_week":      "🎵 Resumen de escucha de la semana pasada ({from} – {to})",
		"title_year":      "🏆 Resumen de escucha de {year}",
		"title_yesterday": "🎧 Informe de escucha de ayer ({date})",
		"value_hm":        "{h} h {m} min",
		"value_m":         "{m} min",
	},
	digestLangFr: {
		"brief_line":      "{label}\u00a0: {name} · {n}",
		"col_albums":      "Albums",
		"col_artists":     "Artistes",
		"col_tracks":      "Morceaux",
		"colon":           "\u00a0:",
		"compare":         " (contre {prev} {label}, {change})",
		"cover":           "Pochette",
		"date":            "{d}/{m}",
		"duration_hm":     " · environ {h} h {m} min",
		"duration_m":      " · environ {m} min",
		"flat":            "stable",
		"footer":          "Lyrimuse · Données de {source}",
		"head_albums":     "Top albums",
		"head_artists":    "Top artistes",
		"head_tracks":     "Top morceaux",
		"item":            "{i}. {name} ({n})",
		"keyword":         "écoute",
		"label_album":     "Album",
		"label_artist":    "Artiste",
		"label_track":     "Morceau",
		"link":            "Voir le classement complet sur {source}",
		"month_names":     "janvier,février,mars,avril,mai,juin,juillet,août,septembre,octobre,novembre,décembre",
		"more":            " et plus",
		"most_played":     "Les plus écoutés",
		"name_sep":        ", ",
		"names_lead":      "\u00a0: ",
		"new_artists":     "{n} nouveaux artistes",
		"new_artists_one": "{n} nouvel artiste",
		"pair":            "{artist} - {name}",
		"plays":           "{n} écoutes",
		"plays_one":       "{n} écoute",
		"plays_truncated": "Plus de {n} écoutes (trop d’écoutes, seules les plus récentes ont été comptées)",
		"preset_brief":    "{summary}\nArtiste principal\u00a0: {top_artist}\nAlbum principal\u00a0: {top_album}\nMorceau principal\u00a0: {top_track}\nNouveaux artistes ({new_artists})\u00a0: {new_artist_names}",
		"preset_full":     "{summary}\n\nTop artistes\u00a0:\n{top_artists}\n\nTop albums\u00a0:\n{top_albums}\n\nTop morceaux\u00a0:\n{top_tracks}\n\nNouveaux artistes ({new_artists})\u00a0: {new_artist_names}",
		"preset_overview": "{summary}\nNouveaux artistes\u00a0: {new_artists}",
		"prev_month":      "en {month_name}",
		"prev_month_year": "en {month_name} {year}",
		"prev_week":       "la semaine précédente",
		"prev_year":       "en {year}",
		"title_day":       "🎧 Bilan d’écoute ({date})",
		"title_month":     "📅 Récap d’écoute\u00a0: {month_name} {year}",
		"title_sample":    "🎧 Exemple de bilan d’écoute",
		"title_today":     "🎧 Bilan d’écoute du jour ({date})",
		"title_week":      "🎵 Récap d’écoute de la semaine dernière ({from} – {to})",
		"title_year":      "🏆 Récap d’écoute {year}",
		"title_yesterday": "🎧 Bilan d’écoute d’hier ({date})",
		"value_hm":        "{h} h {m} min",
		"value_m":         "{m} min",
		"zero_is_one":     "1",
	},
	digestLangDe: {
		"brief_line":      "{label}: {name} · {n}",
		"col_albums":      "Alben",
		"col_artists":     "Künstler",
		"col_tracks":      "Titel",
		"colon":           ":",
		"compare":         " (gegenüber {prev} {label}, {change})",
		"cover":           "Cover",
		"date":            "{d}.{m}.",
		"duration_hm":     " · etwa {h} Std. {m} Min.",
		"duration_m":      " · etwa {m} Min.",
		"flat":            "unverändert",
		"footer":          "Lyrimuse · Daten von {source}",
		"head_albums":     "Top-Alben",
		"head_artists":    "Top-Künstler",
		"head_tracks":     "Top-Titel",
		"item":            "{i}. {name} ({n})",
		"keyword":         "Hör",
		"label_album":     "Album",
		"label_artist":    "Künstler",
		"label_track":     "Titel",
		"link":            "Gesamte Rangliste auf {source}",
		"month_names":     "Januar,Februar,März,April,Mai,Juni,Juli,August,September,Oktober,November,Dezember",
		"more":            " und mehr",
		"most_played":     "Am meisten gehört",
		"name_sep":        ", ",
		"names_lead":      ": ",
		"new_artists":     "{n} neue Künstler",
		"new_artists_one": "{n} neuer Künstler",
		"pair":            "{artist} - {name}",
		"plays":           "{n} Wiedergaben",
		"plays_one":       "{n} Wiedergabe",
		"plays_truncated": "Über {n} Wiedergaben (zu viele, nur die neuesten wurden gezählt)",
		"preset_brief":    "{summary}\nTop-Künstler: {top_artist}\nTop-Album: {top_album}\nTop-Titel: {top_track}\nNeue Künstler ({new_artists}): {new_artist_names}",
		"preset_full":     "{summary}\n\nTop-Künstler:\n{top_artists}\n\nTop-Alben:\n{top_albums}\n\nTop-Titel:\n{top_tracks}\n\nNeue Künstler ({new_artists}): {new_artist_names}",
		"preset_overview": "{summary}\nNeue Künstler: {new_artists}",
		"prev_month":      "im {month_name}",
		"prev_month_year": "im {month_name} {year}",
		"prev_week":       "in der Vorwoche",
		"prev_year":       "im Jahr {year}",
		"title_day":       "🎧 Hörbericht ({date})",
		"title_month":     "📅 Hörrückblick {month_name} {year}",
		"title_sample":    "🎧 Beispiel-Hörbericht",
		"title_today":     "🎧 Hörbericht von heute ({date})",
		"title_week":      "🎵 Hörrückblick der letzten Woche ({from} – {to})",
		"title_year":      "🏆 Hörrückblick {year}",
		"title_yesterday": "🎧 Hörbericht von gestern ({date})",
		"value_hm":        "{h} Std. {m} Min.",
		"value_m":         "{m} Min.",
	},
	digestLangIt: {
		"brief_line":      "{label}: {name} · {n}",
		"col_albums":      "Album",
		"col_artists":     "Artisti",
		"col_tracks":      "Brani",
		"colon":           ":",
		"compare":         " ({label}: {prev}, {change})",
		"cover":           "Copertina",
		"date":            "{d}/{m}",
		"duration_hm":     " · circa {h} h {m} min",
		"duration_m":      " · circa {m} min",
		"flat":            "invariato",
		"footer":          "Lyrimuse · Dati da {source}",
		"head_albums":     "Album più ascoltati",
		"head_artists":    "Artisti più ascoltati",
		"head_tracks":     "Brani più ascoltati",
		"item":            "{i}. {name} ({n})",
		"keyword":         "ascolto",
		"label_album":     "Album",
		"label_artist":    "Artista",
		"label_track":     "Brano",
		"link":            "Classifica completa su {source}",
		"month_names":     "gennaio,febbraio,marzo,aprile,maggio,giugno,luglio,agosto,settembre,ottobre,novembre,dicembre",
		"more":            " e altri",
		"most_played":     "I più ascoltati",
		"name_sep":        ", ",
		"names_lead":      ": ",
		"new_artists":     "{n} nuovi artisti",
		"new_artists_one": "{n} nuovo artista",
		"pair":            "{artist} - {name}",
		"plays":           "{n} ascolti",
		"plays_one":       "{n} ascolto",
		"plays_truncated": "Oltre {n} ascolti (troppi, sono stati contati solo i più recenti)",
		"preset_brief":    "{summary}\nArtista principale: {top_artist}\nAlbum principale: {top_album}\nBrano principale: {top_track}\nNuovi artisti ({new_artists}): {new_artist_names}",
		"preset_full":     "{summary}\n\nArtisti più ascoltati:\n{top_artists}\n\nAlbum più ascoltati:\n{top_albums}\n\nBrani più ascoltati:\n{top_tracks}\n\nNuovi artisti ({new_artists}): {new_artist_names}",
		"preset_overview": "{summary}\nNuovi artisti: {new_artists}",
		"prev_month":      "a {month_name}",
		"prev_month_year": "a {month_name} {year}",
		"prev_week":       "settimana precedente",
		"prev_year":       "nel {year}",
		"title_day":       "🎧 Report di ascolto ({date})",
		"title_month":     "📅 Riepilogo di ascolto di {month_name} {year}",
		"title_sample":    "🎧 Report di ascolto di esempio",
		"title_today":     "🎧 Report di ascolto di oggi ({date})",
		"title_week":      "🎵 Riepilogo di ascolto della settimana scorsa ({from} – {to})",
		"title_year":      "🏆 Riepilogo di ascolto del {year}",
		"title_yesterday": "🎧 Report di ascolto di ieri ({date})",
		"value_hm":        "{h} h {m} min",
		"value_m":         "{m} min",
	},
	digestLangPtBR: {
		"brief_line":      "{label}: {name} · {n}",
		"col_albums":      "Álbuns",
		"col_artists":     "Artistas",
		"col_tracks":      "Músicas",
		"colon":           ":",
		"compare":         " ({label}: {prev}, {change})",
		"cover":           "Capa",
		"date":            "{d}/{m}",
		"duration_hm":     " · cerca de {h} h {m} min",
		"duration_m":      " · cerca de {m} min",
		"flat":            "sem variação",
		"footer":          "Lyrimuse · Dados de {source}",
		"head_albums":     "Álbuns mais ouvidos",
		"head_artists":    "Artistas mais ouvidos",
		"head_tracks":     "Músicas mais ouvidas",
		"item":            "{i}. {name} ({n})",
		"keyword":         "audição",
		"label_album":     "Álbum",
		"label_artist":    "Artista",
		"label_track":     "Música",
		"link":            "Ranking completo em {source}",
		"month_names":     "janeiro,fevereiro,março,abril,maio,junho,julho,agosto,setembro,outubro,novembro,dezembro",
		"more":            " e mais",
		"most_played":     "Mais ouvidos",
		"name_sep":        ", ",
		"names_lead":      ": ",
		"new_artists":     "{n} artistas novos",
		"new_artists_one": "{n} artista novo",
		"pair":            "{artist} - {name}",
		"plays":           "{n} reproduções",
		"plays_one":       "{n} reprodução",
		"plays_truncated": "Mais de {n} reproduções (são muitas; só as mais recentes foram contadas)",
		"preset_brief":    "{summary}\nArtista principal: {top_artist}\nÁlbum principal: {top_album}\nMúsica principal: {top_track}\nArtistas novos ({new_artists}): {new_artist_names}",
		"preset_full":     "{summary}\n\nArtistas mais ouvidos:\n{top_artists}\n\nÁlbuns mais ouvidos:\n{top_albums}\n\nMúsicas mais ouvidas:\n{top_tracks}\n\nArtistas novos ({new_artists}): {new_artist_names}",
		"preset_overview": "{summary}\nArtistas novos: {new_artists}",
		"prev_month":      "em {month_name}",
		"prev_month_year": "em {month_name} de {year}",
		"prev_week":       "semana anterior",
		"prev_year":       "em {year}",
		"title_day":       "🎧 Relatório de audição ({date})",
		"title_month":     "📅 Resumo de audição de {month_name} de {year}",
		"title_sample":    "🎧 Exemplo de relatório de audição",
		"title_today":     "🎧 Relatório de audição de hoje ({date})",
		"title_week":      "🎵 Resumo de audição da semana passada ({from} – {to})",
		"title_year":      "🏆 Resumo de audição de {year}",
		"title_yesterday": "🎧 Relatório de audição de ontem ({date})",
		"value_hm":        "{h} h {m} min",
		"value_m":         "{m} min",
		"zero_is_one":     "1",
	},
	digestLangVi: {
		"brief_line":      "{label}: {name} · {n}",
		"col_albums":      "Album",
		"col_artists":     "Nghệ sĩ",
		"col_tracks":      "Bài hát",
		"colon":           ":",
		"compare":         " ({label}: {prev}, {change})",
		"cover":           "Ảnh bìa",
		"date":            "{d}/{m}",
		"duration_hm":     " · khoảng {h} giờ {m} phút",
		"duration_m":      " · khoảng {m} phút",
		"flat":            "không đổi",
		"footer":          "Lyrimuse · Dữ liệu từ {source}",
		"head_albums":     "Album nghe nhiều nhất",
		"head_artists":    "Nghệ sĩ nghe nhiều nhất",
		"head_tracks":     "Bài hát nghe nhiều nhất",
		"item":            "{i}. {name} ({n})",
		"keyword":         "nghe nhạc",
		"label_album":     "Album",
		"label_artist":    "Nghệ sĩ",
		"label_track":     "Bài hát",
		"link":            "Xem bảng xếp hạng đầy đủ trên {source}",
		"more":            ", v.v.",
		"most_played":     "Nghe nhiều nhất",
		"name_sep":        ", ",
		"names_lead":      ": ",
		"new_artists":     "{n} nghệ sĩ mới",
		"pair":            "{artist} - {name}",
		"plays":           "{n} lượt phát",
		"plays_truncated": "Hơn {n} lượt phát (quá nhiều, chỉ tính những lượt gần nhất)",
		"preset_brief":    "{summary}\nNghệ sĩ hàng đầu: {top_artist}\nAlbum hàng đầu: {top_album}\nBài hát hàng đầu: {top_track}\nNghệ sĩ mới ({new_artists}): {new_artist_names}",
		"preset_full":     "{summary}\n\nNghệ sĩ nghe nhiều nhất:\n{top_artists}\n\nAlbum nghe nhiều nhất:\n{top_albums}\n\nBài hát nghe nhiều nhất:\n{top_tracks}\n\nNghệ sĩ mới ({new_artists}): {new_artist_names}",
		"preset_overview": "{summary}\nNghệ sĩ mới: {new_artists}",
		"prev_month":      "tháng {month}",
		"prev_month_year": "tháng {month}/{year}",
		"prev_week":       "tuần trước đó",
		"prev_year":       "năm {year}",
		"title_day":       "🎧 Báo cáo nghe nhạc ({date})",
		"title_month":     "📅 Tổng kết nghe nhạc tháng {month}/{year}",
		"title_sample":    "🎧 Báo cáo nghe nhạc mẫu",
		"title_today":     "🎧 Báo cáo nghe nhạc hôm nay ({date})",
		"title_week":      "🎵 Tổng kết nghe nhạc tuần trước ({from} – {to})",
		"title_year":      "🏆 Tổng kết nghe nhạc năm {year}",
		"title_yesterday": "🎧 Báo cáo nghe nhạc hôm qua ({date})",
		"value_hm":        "{h} giờ {m} phút",
		"value_m":         "{m} phút",
	},
	digestLangRu: {
		"brief_line":       "{label}: {name} · {n}",
		"col_albums":       "Альбомы",
		"col_artists":      "Артисты",
		"col_tracks":       "Треки",
		"colon":            ":",
		"compare":          " ({label}: {prev}, {change})",
		"cover":            "Обложка",
		"date":             "{dd}.{mm}",
		"duration_hm":      " · около {h} ч {m} мин",
		"duration_m":       " · около {m} мин",
		"flat":             "без изменений",
		"footer":           "Lyrimuse · Данные: {source}",
		"head_albums":      "Топ альбомов",
		"head_artists":     "Топ артистов",
		"head_tracks":      "Топ треков",
		"item":             "{i}. {name} ({n})",
		"keyword":          "прослушиваний",
		"label_album":      "Альбом",
		"label_artist":     "Артист",
		"label_track":      "Трек",
		"link":             "Полный рейтинг на {source}",
		"month_names":      "январь,февраль,март,апрель,май,июнь,июль,август,сентябрь,октябрь,ноябрь,декабрь",
		"more":             " и др.",
		"most_played":      "Чаще всего",
		"name_sep":         ", ",
		"names_lead":       ": ",
		"new_artists":      "{n} новых артиста",
		"new_artists_few":  "{n} новых артиста",
		"new_artists_many": "{n} новых артистов",
		"new_artists_one":  "{n} новый артист",
		"pair":             "{artist} — {name}",
		"plays":            "{n} прослушивания",
		"plays_few":        "{n} прослушивания",
		"plays_many":       "{n} прослушиваний",
		"plays_one":        "{n} прослушивание",
		"plays_truncated":  "Прослушиваний: более {n} (слишком много, учтены только последние)",
		"plural_rule":      "ru",
		"preset_brief":     "{summary}\nТоп-артист: {top_artist}\nТоп-альбом: {top_album}\nТоп-трек: {top_track}\nНовые артисты ({new_artists}): {new_artist_names}",
		"preset_full":      "{summary}\n\nТоп артистов:\n{top_artists}\n\nТоп альбомов:\n{top_albums}\n\nТоп треков:\n{top_tracks}\n\nНовые артисты ({new_artists}): {new_artist_names}",
		"preset_overview":  "{summary}\nНовые артисты: {new_artists}",
		"prev_month":       "{month_name}",
		"prev_month_year":  "{month_name} {year}",
		"prev_week":        "предыдущая неделя",
		"prev_year":        "{year} год",
		"title_day":        "🎧 Сводка прослушиваний ({date})",
		"title_month":      "📅 Итоги прослушиваний за {month_name} {year}",
		"title_sample":     "🎧 Пример сводки прослушиваний",
		"title_today":      "🎧 Сводка прослушиваний за сегодня ({date})",
		"title_week":       "🎵 Итоги прослушиваний за прошлую неделю ({from} – {to})",
		"title_year":       "🏆 Итоги прослушиваний за {year} год",
		"title_yesterday":  "🎧 Сводка прослушиваний за вчера ({date})",
		"value_hm":         "{h} ч {m} мин",
		"value_m":          "{m} мин",
	},
}
