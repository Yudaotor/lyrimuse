package main

import "sort"

// 排序层新旧对拍的参照:提交 43fa2dff7 里的 rankLyricSourceResults 和它直接调的三个按源名写的辅助函数,函数体原样、
// 只改了名字(加 handwritten 前缀,互相之间的调用指到这一份上)。lyricrankparity_test.go 拿它跟生产的
// rankLyricSourceResults 对同一份输入比全部输出。别改这里的函数体:它是迁移期间「原来怎么排」的唯一依据。

func handwrittenRankLyricSourceResults(artist, title, album string, durationSecs float64, raw map[string]lyricSourceResult) []scoredLyricCandidateResult {
	// 第一步先把各源正文里的 HTML / XML 字符实体还原(酷狗 `they&apos;re`,见 lyricentities.go)。
	// 返回的是新 map,调用方那份原始应答不动——它每来一个源就全量重跑一次这里。
	raw = decodeLyricSourceEntities(raw)
	raw = splitWordTimedSourceLyrics(raw)
	raw = dropOtherVersionInstrumentalClaims(title, album, raw)
	ne := raw["netease"].ne
	qq, kugou, lrclib, lf, kuwo := raw["qq"], raw["kugou"], raw["lrclib"], raw["lyricfind"], raw["kuwo"]
	qqLyr, qqYRC, qqTr, qqRoma, qqTitle, qqArtist, qqAlbum, qqCover, qqDur, qqLang := qq.lyr, qq.yrc, qq.tr, qq.roma, qq.matchTitle, qq.matchArtist, qq.matchAlbum, qq.matchCover, qq.srcDur, qq.language
	qqInstrumental := qq.instrumental
	qqPlainOnly := qq.plainOnly
	kugouLyr, kugouYRC, kugouTr, kugouRoma, kugouTitle, kugouArtist, kugouAlbum, kugouCover, kugouDur, kugouLang := kugou.lyr, kugou.yrc, kugou.tr, kugou.roma, kugou.matchTitle, kugou.matchArtist, kugou.matchAlbum, kugou.matchCover, kugou.srcDur, kugou.language
	lrclibLyr, lrclibTitle, lrclibArtist, lrclibAlbum, lrclibDur := lrclib.lyr, lrclib.matchTitle, lrclib.matchArtist, lrclib.matchAlbum, lrclib.srcDur
	lrclibInstrumental := lrclib.instrumental
	lrclibPlainOnly := lrclib.plainOnly
	lrclibYRC, lrclibRoma := lrclib.yrc, lrclib.roma
	lfLyr, lfTitle, lfArtist, lfAlbum, lfCover, lfDur, lfPlainOnly := lf.lyr, lf.matchTitle, lf.matchArtist, lf.matchAlbum, lf.matchCover, lf.srcDur, lf.plainOnly
	kuwoLyr, kuwoYRC, kuwoTitle, kuwoArtist, kuwoAlbum, kuwoCover, kuwoDur := kuwo.lyr, kuwo.yrc, kuwo.matchTitle, kuwo.matchArtist, kuwo.matchAlbum, kuwo.matchCover, kuwo.srcDur
	migu := raw["migu"]
	miguLyr, miguYRC, miguTr, miguTitle, miguArtist, miguAlbum, miguCover := migu.lyr, migu.yrc, migu.tr, migu.matchTitle, migu.matchArtist, migu.matchAlbum, migu.matchCover
	miguPlainOnly, miguDur := migu.plainOnly, migu.srcDur
	dz := raw["deezer"]
	dzLyr, dzYRC, dzTr, dzTitle, dzArtist, dzAlbum, dzCover, dzDur, dzPlainOnly := dz.lyr, dz.yrc, dz.tr, dz.matchTitle, dz.matchArtist, dz.matchAlbum, dz.matchCover, dz.srcDur, dz.plainOnly
	am := raw["applemusic"]
	amLyr, amYRC, amTr, amRoma, amTitle, amArtist, amAlbum, amCover, amDur, amPlainOnly := am.lyr, am.yrc, am.tr, am.roma, am.matchTitle, am.matchArtist, am.matchAlbum, am.matchCover, am.srcDur, am.plainOnly
	amBG := am.bg
	amTrLang := am.trLang
	if amTrLang == "" {
		amTrLang = features().LyricsTranslationLanguage
	}
	soda := raw["soda"]
	vibe := raw["vibe"]
	genie := raw["genie"]
	petit := raw["petitlyrics"]
	zing := raw["zing"]
	mgz := raw["megalobiz"]
	kk := raw[kkboxLocalLyricsSource]
	spl := raw[spotifyLocalLyricsSource]
	amz := raw[amazonLocalLyricsSource]
	localLRC := raw[localFileLyricsSource]
	lxm := raw[lxMusicLocalLyricsSource]
	imp := raw[importLyricsSource]
	sodaLyr, sodaYRC, sodaTr, sodaTitle, sodaArtist, sodaAlbum, sodaCover, sodaDur := soda.lyr, soda.yrc, soda.tr, soda.matchTitle, soda.matchArtist, soda.matchAlbum, soda.matchCover, soda.srcDur
	amll := raw["amll"].amll
	// 候选的封面只用它自己那个源给的,没有就空着(「搜索候选歌词」弹窗显示占位图,「解析决策」全空时整列不出现);
	// amll 自己没有封面,借能认定是同一条录音的那几家的(amllCandidateCover)。
	// 别拿按本地歌名搜来的 Apple 封面给它兜底:那是"本地这首"的封面、不是这条候选的出处,候选缩略图本来是帮人
	// 分辨"这条是哪个版本"的,套上一张别人的图反而像是对上了;所有没带封面的候选还会套成同一张,毫无区分度。
	// 烘进正文的逐行中文译文(bakedtranslation.go):候选装配**之前**摘出来——共识、行数、
	// 逐字覆盖率全都读正文,晚了就都是按"一半是中文"的正文算的。译文轨本来就是中文语义的源
	// (netease/qq/kugou)接上摘出来的译文;lrclib/lyricfind/amll 只摘不接。
	foreignSong := !containsHan(artist) && !containsHan(title)
	bakedLines := map[string]int{}
	ne.Lyrics, ne.Trans, ne.YRC, bakedLines["netease"] = adoptBakedTranslation(ne.Lyrics, ne.Trans, ne.YRC, foreignSong, true)
	qqLyr, qqTr, qqYRC, bakedLines["qq"] = adoptBakedTranslation(qqLyr, qqTr, qqYRC, foreignSong, true)
	kugouLyr, kugouTr, kugouYRC, bakedLines["kugou"] = adoptBakedTranslation(kugouLyr, kugouTr, kugouYRC, foreignSong, true)
	lrclibLyr, _, lrclibYRC, bakedLines["lrclib"] = adoptBakedTranslation(lrclibLyr, "", lrclibYRC, foreignSong, false)
	lfLyr, _, _, bakedLines["lyricfind"] = adoptBakedTranslation(lfLyr, "", "", foreignSong, false)
	// 酷我对外文歌**系统性**地把中文译文烘在正文里(金标 ko-fallen-angel / latin-purple-rain 里的酷我候选
	// 128→67 行、71→37 行),摘出来的译文照 qq/kugou 的口径接到译文轨(中文)。
	// 酷我的译文行挂在下一句的时间戳上,整首判断之后再逐行认一遍(adoptKuwoBakedTranslation)。
	// 逐字轨**不**传进去:它在 kuwolrcx.go 转换时已去掉译文行,而酷我的译文行跟下一句原文同一个时间戳,
	// 交给这里按时间删会把原文那行一起删掉。
	var kuwoTr string
	kuwoLyr, kuwoTr, bakedLines["kuwo"] = adoptKuwoBakedTranslation(kuwoLyr, foreignSong)
	amll.lrc, _, amll.yrc, bakedLines["amll"] = adoptBakedTranslation(amll.lrc, "", amll.yrc, foreignSong, false)
	// 本地 .lrc 常是下载工具导出的双语文件:每句原文下面一行同一时间戳的中文译文。不摘的话 App 同一时间戳取后一行,
	// 只显示译文。摘出来的译文固定中文,接到译文轨(同 qq / kugou)。见 09 章决策 333。
	localLRC.lyr, localLRC.tr, localLRC.yrc, bakedLines[localFileLyricsSource] = adoptBakedTranslation(localLRC.lyr, localLRC.tr, localLRC.yrc, foreignSong, true)
	var candidates []lyricCandidate
	if ne.Lyrics != "" {
		// 网易云的社区翻译固定中文(见下面附着处的注释),usable 判定按目标语言过闸;
		// 这两个标志必须在**打分前**算好挂到候选上(v3 的增值内容决胜分要读它),
		// 不能等选完冠军再附着。
		neTr, neRoma := usableValueAdd(ne.Lyrics, ne.Trans, "zh", ne.Roma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "netease", lyrics: ne.Lyrics, wordTimingYRC: usableYRC(ne.Lyrics, ne.YRC), hasWordTiming: usableWordTiming(ne.Lyrics, ne.YRC), hasUsableTranslation: neTr, hasUsableRomanization: neRoma, sourceReportedDurationSecs: ne.DurationSecs, title: ne.Title, artist: ne.Artist, album: ne.Album, cover: ne.Cover, identityFromLocalClient: ne.FromLocalClient})
	} else if ne.PlainLyrics != "" {
		// 只有不带时间戳的歌词:交成 plainOnly,直通打分层那道恒 -1 的闸,口径同 deezer / lrclib 的纯文本回退。
		candidates = append(candidates, lyricCandidate{source: "netease", lyrics: ne.PlainLyrics, sourceReportedDurationSecs: ne.DurationSecs, title: ne.Title, artist: ne.Artist, album: ne.Album, cover: ne.Cover, identityFromLocalClient: ne.FromLocalClient, plainTextOnly: true})
	}
	if qqLyr != "" {
		// QQ 的译文固定是中文(跟网易云 tlyric 同款),语言标 "zh";罗马音的可用判定
		// (原文假名占比 > 5%)也沿用同一套 usableValueAdd——韩文歌的罗马音会跟网易云
		// 一样被判不可用,这是既有口径,不是 QQ 这路新加的规则。
		qqUsableTr, qqUsableRoma := usableValueAdd(qqLyr, qqTr, "zh", qqRoma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "qq", lyrics: qqLyr, wordTimingYRC: usableYRC(qqLyr, qqYRC), hasWordTiming: usableWordTiming(qqLyr, qqYRC), hasUsableTranslation: qqUsableTr, hasUsableRomanization: qqUsableRoma, sourceReportedDurationSecs: qqDur, title: qqTitle, artist: qqArtist, album: qqAlbum, cover: qqCover, language: qqLang, identityFromLocalClient: qq.identityFromLocalClient, plainTextOnly: qqPlainOnly})
	}
	if kugouLyr != "" {
		// 酷狗 KRC `[language:]` 轨的译文固定中文,标 "zh";罗马音的可用判定同样走
		// usableValueAdd 的假名占比闸(韩文歌的谐音轨在 kugou.go 里已先按汉字占比挡掉一次)。
		kugouUsableTr, kugouUsableRoma := usableValueAdd(kugouLyr, kugouTr, "zh", kugouRoma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "kugou", lyrics: kugouLyr, wordTimingYRC: usableYRC(kugouLyr, kugouYRC), hasWordTiming: usableWordTiming(kugouLyr, kugouYRC), hasUsableTranslation: kugouUsableTr, hasUsableRomanization: kugouUsableRoma, sourceReportedDurationSecs: kugouDur, title: kugouTitle, artist: kugouArtist, album: kugouAlbum, cover: kugouCover, language: kugouLang, identityFromLocalClient: kugou.identityFromLocalClient})
	}
	if lrclibLyr != "" {
		// 罗马音来自 lyricsfile 的音译(lyricsfile.go),可用性跟别的源同一道 usableValueAdd;没有译文。
		_, lrclibUsableRoma := usableValueAdd(lrclibLyr, "", "", lrclibRoma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "lrclib", lyrics: lrclibLyr, wordTimingYRC: usableYRC(lrclibLyr, lrclibYRC), hasWordTiming: usableWordTiming(lrclibLyr, lrclibYRC), hasUsableRomanization: lrclibUsableRoma, sourceReportedDurationSecs: lrclibDur, title: lrclibTitle, artist: lrclibArtist, album: lrclibAlbum, cover: "", plainTextOnly: lrclibPlainOnly})
	}
	if lfLyr != "" {
		// 只有逐行,没有逐字/译文/罗马音——跟 lrclib 同一个形状(见 ytmusic.go 头注)。只有纯文本时 plainOnly 直通打分层那道
		// 恒 -1 的闸,口径同 deezer/lrclib 的纯文本回退。
		candidates = append(candidates, lyricCandidate{source: "lyricfind", lyrics: lfLyr, sourceReportedDurationSecs: lfDur, title: lfTitle, artist: lfArtist, album: lfAlbum, cover: lfCover, plainTextOnly: lfPlainOnly, identityFromLocalClient: lf.identityFromLocalClient})
	}
	if kuwoLyr != "" {
		// 逐行正文 + 可选的逐字轨(kuwolrcx.go),译文只有从正文摘出来的烘入译文,没有罗马音
		// (见 kuwo.go 头注)。逐字的可用性判定同网易云/QQ/酷狗(usableYRC / usableWordTiming)。
		kuwoUsableTr, _ := usableValueAdd(kuwoLyr, kuwoTr, "zh", "", features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "kuwo", lyrics: kuwoLyr, wordTimingYRC: usableYRC(kuwoLyr, kuwoYRC), hasWordTiming: usableWordTiming(kuwoLyr, kuwoYRC), hasUsableTranslation: kuwoUsableTr, sourceReportedDurationSecs: kuwoDur, title: kuwoTitle, artist: kuwoArtist, album: kuwoAlbum, cover: kuwoCover, identityFromLocalClient: kuwo.identityFromLocalClient})
	}
	if miguLyr != "" {
		// 逐行 LRC + 可选的逐字轨(MRC,migumrc.go)+ 可选的中文译文(trcUrl,外语歌才有),没有罗马音;
		// 封面用搜索结果自带的 imgItems(见 migu.go 头注)。译文固定中文、标 "zh",可用性同网易云/QQ/酷狗
		// 走 usableValueAdd,逐字同样走 usableYRC / usableWordTiming。
		// 搜索结果没有时长字段,sourceReportedDurationSecs 用文件大小估的(miguSearchItem.durationSecs),估不出时为 0。
		// plainOnly 直通打分层那道恒 -1 的闸,口径同 deezer/lrclib 的纯文本回退。
		miguUsableTr, _ := usableValueAdd(miguLyr, miguTr, "zh", "", features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "migu", lyrics: miguLyr, wordTimingYRC: usableYRC(miguLyr, miguYRC), hasWordTiming: usableWordTiming(miguLyr, miguYRC), hasUsableTranslation: miguUsableTr, sourceReportedDurationSecs: miguDur, title: miguTitle, artist: miguArtist, album: miguAlbum, cover: miguCover, plainTextOnly: miguPlainOnly})
	}
	if dzLyr != "" {
		// 逐行正文 + 可选的逐字轨 + 可选的译文(语言跟译文语言设置走),没有罗马音;封面用搜索
		// 结果自带的 album.cover_xl,时长用 Deezer 自报的 duration(见 deezer.go 头注)。逐字走
		// usableYRC / usableWordTiming,译文走 usableValueAdd,口径同别的源。plainOnly 直通打分层
		// 那道恒 -1 的闸(match.go 的 scoreRejectPlainTextOnly),口径与 lrclib 的纯文本回退一致。
		dzUsableTr, _ := usableValueAdd(dzLyr, dzTr, features().LyricsTranslationLanguage, "", features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "deezer", lyrics: dzLyr, wordTimingYRC: usableYRC(dzLyr, dzYRC), hasWordTiming: usableWordTiming(dzLyr, dzYRC), hasUsableTranslation: dzUsableTr, sourceReportedDurationSecs: dzDur, title: dzTitle, artist: dzArtist, album: dzAlbum, cover: dzCover, plainTextOnly: dzPlainOnly, isrc: dz.isrc})
	}
	if amLyr != "" {
		// 全部源里唯一的**官方逐字**来源:逐行 LRC + 逐字 YRC(itunes:timing="Word")+
		// 可选译文,封面用 artwork 模板替换出的 1000x1000,时长用 Apple 自报的
		// durationInMillis(见 applemusic.go 头注)。逐字的可用性判定走跟 amll 完全一样的
		// usableYRC/usableWordTiming —— 两边都是同一套 TTML 解析出来的,没理由用两套判据。
		// plainOnly 直通打分层那道恒 -1 的闸,口径同 deezer/lrclib 的纯文本回退。
		amUsableTr, amUsableRoma := usableValueAdd(amLyr, amTr, amTrLang, amRoma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{
			source: "applemusic", lyrics: amLyr,
			wordTimingYRC: usableYRC(amLyr, amYRC), hasWordTiming: usableWordTiming(amLyr, amYRC),
			hasUsableTranslation:       amUsableTr,
			hasUsableRomanization:      amUsableRoma,
			sourceReportedDurationSecs: amDur,
			isrc:                       am.isrc,
			title:                      amTitle, artist: amArtist, album: amAlbum,
			cover: amCover, plainTextOnly: amPlainOnly,
			identityFromLocalClient: am.identityFromLocalClient,
		})
	}
	if sodaLyr != "" {
		// 官方逐字(格式与酷狗 KRC 同构,归一化见 soda.go)+ 平台自带的中文译文(外语歌才有),
		// 没有罗马音。译文固定中文、标 "zh",可用性同网易云/QQ/酷狗走 usableValueAdd。没有
		// plainTextOnly —— 拿不到计时行时 krcToLRC 返回空串,这里根本进不来。
		sodaUsableTr, _ := usableValueAdd(sodaLyr, sodaTr, "zh", "", features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{
			source: "soda", lyrics: sodaLyr,
			wordTimingYRC: usableYRC(sodaLyr, sodaYRC), hasWordTiming: usableWordTiming(sodaLyr, sodaYRC),
			hasUsableTranslation:       sodaUsableTr,
			sourceReportedDurationSecs: sodaDur,
			title:                      sodaTitle, artist: sodaArtist, album: sodaAlbum,
			cover:                   sodaCover,
			identityFromLocalClient: soda.identityFromLocalClient,
		})
	}
	if vibe.lyr != "" {
		// 逐行 + 外语歌的韩文译文(标 "ko",译文语言设成韩文时才用得上),没有逐字和罗马音;封面是搜索结果自带的专辑图原图,
		// 时长是搜索结果自报的 playTime(见 vibe.go 头注)。plainOnly 直通打分层那道恒 -1 的闸,口径同 deezer / lrclib。
		vibeUsableTr, _ := usableValueAdd(vibe.lyr, vibe.tr, vibeTranslationLang, "", features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "vibe", lyrics: vibe.lyr, hasUsableTranslation: vibeUsableTr,
			sourceReportedDurationSecs: vibe.srcDur, title: vibe.matchTitle, artist: vibe.matchArtist, album: vibe.matchAlbum,
			cover: vibe.matchCover, plainTextOnly: vibe.plainOnly})
	}
	if genie.lyr != "" {
		// 逐行,没有逐字、译文、罗马音;封面、时长是搜索结果自带的(见 genie.go 头注)。plainOnly 口径同 vibe。
		candidates = append(candidates, lyricCandidate{source: "genie", lyrics: genie.lyr,
			sourceReportedDurationSecs: genie.srcDur, title: genie.matchTitle, artist: genie.matchArtist, album: genie.matchAlbum,
			cover: genie.matchCover, plainTextOnly: genie.plainOnly})
	}
	if petit.lyr != "" {
		// 逐字(取不到时纯文本),没有译文、罗马音;封面是按 ISRC 在 Deezer 上取的,时长是这份歌词登记的(见 petitlyrics.go 头注)。
		// plainOnly 口径同 vibe。
		candidates = append(candidates, lyricCandidate{source: "petitlyrics", lyrics: petit.lyr,
			wordTimingYRC: usableYRC(petit.lyr, petit.yrc), hasWordTiming: usableWordTiming(petit.lyr, petit.yrc),
			sourceReportedDurationSecs: petit.srcDur, title: petit.matchTitle, artist: petit.matchArtist, album: petit.matchAlbum,
			cover: petit.matchCover, plainTextOnly: petit.plainOnly, isrc: petit.isrc})
	}
	if zing.lyr != "" {
		// 逐行,逐字跟逐行对得上才带;没有译文、罗马音、纯文本;封面、时长是搜索结果自带的(见 zing.go 头注)。
		candidates = append(candidates, lyricCandidate{source: "zing", lyrics: zing.lyr,
			wordTimingYRC: usableYRC(zing.lyr, zing.yrc), hasWordTiming: usableWordTiming(zing.lyr, zing.yrc),
			sourceReportedDurationSecs: zing.srcDur, title: zing.matchTitle, artist: zing.matchArtist, album: zing.matchAlbum,
			cover: zing.matchCover})
	}
	if mgz.lyr != "" {
		// 逐行,没有逐字、译文、罗马音、封面、专辑、纯文本;时长是这份歌词登记的,歌词页地址给来源链接用(见 megalobiz.go 头注)。
		candidates = append(candidates, lyricCandidate{source: "megalobiz", lyrics: mgz.lyr,
			sourceReportedDurationSecs: mgz.srcDur, title: mgz.matchTitle, artist: mgz.matchArtist, sourceURL: mgz.sourceURL})
	}
	if kk.lyr != "" {
		// KKBOX 本地歌词(用 KKBOX 放歌时读它自己缓存里的那份,逐行,见 kkboxlyrics.go)。只精确到整秒的那类不置
		// identityFromLocalClient,不享受同源加权。
		candidates = append(candidates, lyricCandidate{
			source: kkboxLocalLyricsSource, lyrics: kk.lyr,
			sourceReportedDurationSecs: kk.srcDur,
			title:                      kk.matchTitle, artist: kk.matchArtist, album: kk.matchAlbum,
			cover:                   kk.matchCover,
			identityFromLocalClient: kk.identityFromLocalClient,
		})
	}
	if amz.lyr != "" {
		// Amazon Music 本地歌词(用它放歌时读它自己缓存里的那份,逐行,按 ASIN 认身份,见 amazonlibrary.go)。只精确到整秒的
		// 那类不置 identityFromLocalClient,同 KKBOX。
		candidates = append(candidates, lyricCandidate{
			source: amazonLocalLyricsSource, lyrics: amz.lyr,
			sourceReportedDurationSecs: amz.srcDur,
			title:                      amz.matchTitle, artist: amz.matchArtist, album: amz.matchAlbum,
			cover:                   amz.matchCover,
			identityFromLocalClient: amz.identityFromLocalClient,
		})
	}
	if lxm.lyr != "" {
		// 洛雪本地歌词(用洛雪放歌时读它存下的那份原版,按平台曲目 id 认身份,带逐字和译文,见 lxmusic.go)。
		lxmUsableTr, lxmUsableRoma := usableValueAdd(lxm.lyr, lxm.tr, "zh", lxm.roma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{
			source: lxMusicLocalLyricsSource, lyrics: lxm.lyr,
			wordTimingYRC: usableYRC(lxm.lyr, lxm.yrc), hasWordTiming: usableWordTiming(lxm.lyr, lxm.yrc),
			hasUsableTranslation: lxmUsableTr, hasUsableRomanization: lxmUsableRoma,
			sourceReportedDurationSecs: lxm.srcDur,
			title:                      lxm.matchTitle, artist: lxm.matchArtist, album: lxm.matchAlbum,
			identityFromLocalClient: lxm.identityFromLocalClient,
		})
	}
	if localLRC.lyr != "" {
		// reAMP 正在放的文件同名的 .lrc(用户自己配的,按文件认身份,见 localfilelyrics.go)。逐字写法的在开头拆成了 yrc。
		localUsableTr, _ := usableValueAdd(localLRC.lyr, localLRC.tr, "zh", "", features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{
			source: localFileLyricsSource, lyrics: localLRC.lyr,
			wordTimingYRC: usableYRC(localLRC.lyr, localLRC.yrc), hasWordTiming: usableWordTiming(localLRC.lyr, localLRC.yrc),
			hasUsableTranslation:       localUsableTr,
			sourceReportedDurationSecs: localLRC.srcDur,
			title:                      localLRC.matchTitle, artist: localLRC.matchArtist,
			identityFromLocalClient: localLRC.identityFromLocalClient, plainTextOnly: localLRC.plainOnly,
		})
	}
	if imp.lyr != "" {
		// 导入库里这首的那份(importstore.go)。身份就是本地这首;译文语言没标时按目标语言。
		impUsableTr, impUsableRoma := usableValueAdd(imp.lyr, imp.tr, importedTrLang(imp.trLang), imp.roma, features().LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{
			source: importLyricsSource, lyrics: imp.lyr,
			wordTimingYRC: usableYRC(imp.lyr, imp.yrc), hasWordTiming: usableWordTiming(imp.lyr, imp.yrc),
			hasUsableTranslation: impUsableTr, hasUsableRomanization: impUsableRoma,
			title: imp.matchTitle, artist: imp.matchArtist, album: imp.matchAlbum,
		})
	}
	if spl.lyr != "" {
		// Spotify 本地歌词(Spotify 自己拉过的那份,逐行,见 spotifylyrics.go)。Spotify 没有配同源
		// 歌词,不置 identityFromLocalClient,跟各源公平打分。
		candidates = append(candidates, lyricCandidate{
			source: spotifyLocalLyricsSource, lyrics: spl.lyr,
			sourceReportedDurationSecs: spl.srcDur,
			title:                      spl.matchTitle, artist: spl.matchArtist, album: spl.matchAlbum,
			cover: spl.matchCover,
		})
	}
	if !amll.empty() {
		// 按 ID 取回的那份身份是确定的 —— 这份 TTML 是按曲目 ID 直接取回来的,不是搜出来的,
		// 所以 title/artist/album 直接沿用本地曲目信息,不会在标题/歌手/专辑那几项上
		// 被扣分。按 ISRC / 歌名在索引里找到的(matchTitle 非空)报索引里的歌名 / 歌手 / 专辑,跟搜出来的源一样打分。
		// 它没有自报时长,sourceReportedDurationSecs 留 0(= 该项不参与打分)。
		// 它自己没有封面,只借能认定是同一条录音的那几家的(amllCandidateCover)。
		amllTitle, amllArtist, amllAlbum := title, artist, album
		if amll.matchTitle != "" {
			amllTitle, amllArtist, amllAlbum = amll.matchTitle, amll.matchArtist, amll.matchAlbum
		}
		amllCover := amllCandidateCover(amll, ne, qq, am, dz)
		target := features().LyricsTranslationLanguage
		amllTr, amllRoma := usableValueAdd(amll.lrc, amll.tr, amll.translationLang(target), amll.roma, target)
		candidates = append(candidates, lyricCandidate{
			source: "amll", lyrics: amll.lrc,
			wordTimingYRC: usableYRC(amll.lrc, amll.yrc), hasWordTiming: usableWordTiming(amll.lrc, amll.yrc),
			hasUsableTranslation:  amllTr,
			hasUsableRomanization: amllRoma,
			title:                 amllTitle, artist: amllArtist, album: amllAlbum, cover: amllCover,
			sourceURL: amll.pageURL,
		})
	}
	// 重音字母旁多切的空格,拿整批候选与缓存里见过的拼法证实之后删掉(见 accentsplit.go)。只删空格、不动时间轴。
	repairCandidateAccentSplits(candidates)
	// 括号里的背景人声拆成背景人声轨(见 bgparen.go)。在重挂时间轴与打分之前:打分看到的是拆过的正文。
	splitCandidateParenBackground(candidates)
	// 时间轴自洽修复:候选自带的行级 LRC 与逐字轴打架时,以逐字轴为准重挂行时间戳
	// (见 lyricstimeline.go 的完整来龙去脉)。**必须在这里**而不是选完冠军之后 ——
	// corroboratedEndings / contentConsensusPeers / scoreLyricCandidateDetailed 的
	// 时长判据全都读 LRC 末句,先修完再算,打分看到的才是修正后的时间轴。
	rehangCandidateTimelines(candidates, durationSecs)
	// v15:批级语种判决(见 match.go applyLanguageVersionVerdicts)。放在重挂时间轴之后、
	// 其余批级步骤之前——它只读 title/album/language/自报时长,与时间轴无关,位置只求跟另一条
	// 流水线(mergeLyricCandidateRounds)一致。
	applyLanguageVersionVerdicts(title, album, durationSecs, candidates)
	corroborated := corroboratedEndings(candidates, durationSecs)
	// v3:跨源正文共识,整批统一算(理由同 corroboratedEndings——peers 随后到的源变化,
	// 每轮全量重算)。artist/title 已是 toSimplified 后的搜索关键词,与打分入参一致。
	consensusPeers, familyPeers := contentConsensusPeers(artist, title, candidates, durationSecs)
	inheritIdentityTerms(title, album, candidates, familyPeers)
	applyLineScoreReference(candidates)
	// lrclib 明确说这首歌是纯音乐、且没有真的歌词候选(lrclibLyr=="")时,搭车塞一条
	// Score:-1 的标记进 results——见 Instrumental 字段定义处的注释,不参与打分/排序,
	// 不会被 pickLyricCandidate 选中,只是把这个信号原样带出这个函数。
	var instrumentalMarker *scoredLyricCandidateResult
	if lrclibLyr == "" && lrclibInstrumental {
		instrumentalMarker = &scoredLyricCandidateResult{Source: "lrclib", Score: -1, Instrumental: true}
	} else if (qqLyr == "" && qqInstrumental) || (isCreditOnlyLRC(qqLyr) && qq.noVocals) {
		// QQ 那一路。有的曲目只有 QQ 明确回了「此歌曲为没有填词的纯音乐」(网易云只有一行署名、没有 pureMusic 字段,
		// 酷狗、LRCLIB 都没有)。这句话不能在 resolveQQLyric 末尾的 isTimedLRC(要求 ≥3 行带戳)那里被当成"不是歌词"扔掉,
		// 否则这类曲目会落在「无歌词」而不是「纯音乐」:界面上看起来像失败,还要按退避白搜全部源。排在网易云之前只是
		// 因为 QQ 这句话是明文断言、语义比"正文只有占位"更硬。
		instrumentalMarker = &scoredLyricCandidateResult{Source: "qq", Score: -1, Instrumental: true}
	} else if ne.Lyrics == "" && (ne.PureMusic || ne.NoVocals) {
		// 网易云那一路同款。典型案例:LoL 原声带 The Music of League of Legends Vol.1
		// 十几首 —— lrclib 压根没有(五源全空、responded 是空的),而网易云**匹配上了歌**
		// (封面/单曲链接都给了)、歌词接口也明确回了 pureMusic=true。lrclib 优先只是因为
		// 它的标记是结构化字段、语义最干净。
		instrumentalMarker = &scoredLyricCandidateResult{Source: "netease", Score: -1, Instrumental: true}
	} else if isInstrumentalPlaceholderLyric(miguLyr) {
		// 咪咕对纯音乐回的歌词文件就是一句「此歌曲为纯音乐,请欣赏」,判定同 QQ 的占位。
		instrumentalMarker = &scoredLyricCandidateResult{Source: "migu", Score: -1, Instrumental: true}
	} else if isCreditOnlyLRC(kugouLyr) && kugou.noVocals {
		instrumentalMarker = &scoredLyricCandidateResult{Source: "kugou", Score: -1, Instrumental: true}
	}

	results := make([]scoredLyricCandidateResult, 0, len(candidates))
	for _, c := range candidates {
		r := scoredLyricCandidateResult{
			Source:                     c.source,
			Lyrics:                     c.lyrics,
			LyricsYRC:                  c.wordTimingYRC,
			HasWordTiming:              c.hasWordTiming,
			SourceReportedDurationSecs: c.sourceReportedDurationSecs,
			ISRC:                       c.isrc,
			Title:                      c.title,
			Artist:                     c.artist,
			Album:                      c.album,
			CoverURL:                   c.cover,
			SourceURL:                  c.sourceURL,
			Language:                   c.language,
			PlainTextOnly:              c.plainTextOnly,
			IdentityFromLocalClient:    c.identityFromLocalClient,
			BakedTranslationLines:      bakedLines[c.source],
		}
		if c.source == "amll" {
			r.BorrowedDurationSecs, r.BorrowedDurationFrom = amllCandidateDuration(amll, ne, qq, am, dz)
		}
		r.Score, r.ScoreTerms = scoreLyricCandidateDetailed(
			artist, title, album, durationSecs, c, corroborated[c.source], len(consensusPeers[c.source]))
		r.ConsensusPeers = consensusPeers[c.source]
		// 正文时间轴被重挂过的话,附属歌词也得搬 —— 它们的时间戳是照原文 LRC 抄的
		// (translate.go 的 assembleTranslationLRC)。
		// 下面 switch 里各源赋完 r.LyricsTr/r.LyricsRoma 之后统一搬,见循环末尾。
		switch c.source {
		case "netease":
			// 翻译/罗马音网易云固定给中文(QQ、酷狗同样,见下面各自的 case)。"固定中文"这件事必须记下来:目标语言不是中文时,这份译文
			// 用不上,得让机翻接手(见 needsTranslationBackfill)。
			//
			// 译文赋值前必须过 c.hasUsableTranslation 这道闸(罗马音走更宽的 usableRomaForResult,
			// 见那边注释)。"能不能用"的判定(usableValueAdd,已经算过"原文本来就是目标语言,同语言
			// 不同文字不算翻译"这类情况)如果只用来加 +50 的打分、不管赋值,candidates 里那份不可用的翻译内容
			// 就会原样抄进 r.LyricsTr,分数赢了就带着这份没有意义的"翻译"一起进缓存(繁体原文配
			// 一份只是转成简体的"翻译"就是这么来的)。判定为不可用时干脆不赋值,行为跟"这个源
			// 没有可用译文"一致。
			if c.hasUsableTranslation {
				r.LyricsTr = ne.Trans
				r.LyricsTrLang = "zh"
			}
			if usableRomaForResult(c.lyrics, ne.Roma) {
				r.LyricsRoma = ne.Roma
			}
		case "lrclib":
			if usableRomaForResult(c.lyrics, lrclibRoma) {
				r.LyricsRoma = lrclibRoma
			}
		case "amll":
			// amll 这条 case 不能漏。amll.tr 早就在 candidates 构造那一步被读出来过(见上面
			// usableValueAdd 调用,+50 分的打分信号靠它),但只要这个 switch 没有 amll 分支,分数
			// 算对了、内容却从没被抄进 r.LyricsTr:选中 amll 之后 lyrics_tr 永远是空的,机翻又拿
			// 这份本来就有毛病的原文(逐词粘连,见 amllttml.go)反复重试、屡试屡败,表现成"这首歌
			// 一直没有译文"。
			//
			// 语言标注跟 usableValueAdd 那次调用用同一个值(amllResult.translationLang:TTML 给译文标的语言,
			// 没标时按目标语言),"能不能用"和"语言标什么"两处口径一致。c.hasUsableTranslation 一并把关
			// "同语言不同文字不算翻译"这类情况。
			if c.hasUsableTranslation {
				r.LyricsTr = amll.tr
				r.LyricsTrLang = amll.translationLang(features().LyricsTranslationLanguage)
			}
			if usableRomaForResult(c.lyrics, amll.roma) {
				r.LyricsRoma = amll.roma
			}
			r.LyricsBG = amll.bg
			r.Songwriters = amll.songwriters
		case "applemusic":
			// 官方译文(<translations type="subtitle">)与官方音译(<transliterations>)。语言按译文块的 xml:lang,
			// 没标时按目标语言(网络那条按请求的语言给,applemusicLyricsQuery)。
			if c.hasUsableTranslation {
				r.LyricsTr = amTr
				r.LyricsTrLang = amTrLang
			}
			if usableRomaForResult(c.lyrics, amRoma) {
				r.LyricsRoma = amRoma
			}
			r.LyricsBG = amBG
			r.Songwriters = am.songwriters
		case "soda":
			// 汽水 lyric.translations.cn 固定中文,口径同 migu。
			if c.hasUsableTranslation {
				r.LyricsTr = sodaTr
				r.LyricsTrLang = "zh"
			}
		case "qq":
			// QQ GetPlayLyricInfo 的 trans/roma 两轨(见 qq.go qqQRCLyric / qqAuxiliaryLRC):
			// 译文跟网易云一样固定中文,标 "zh";两轨都由候选构造时算好的 usableValueAdd 结果
			// 把关。 这个 switch 的纪律是"接一个源就必须在这里补一个 case"(漏了的后果见上面
			// amll 那条:分数算对了、内容没抄进来)。
			if c.hasUsableTranslation {
				r.LyricsTr = qqTr
				r.LyricsTrLang = "zh"
			}
			if usableRomaForResult(c.lyrics, qqRoma) {
				r.LyricsRoma = qqRoma
			}
		case "kuwo":
			// 酷我自己没有译文轨,这里接的是从正文里摘出来的烘入译文(bakedtranslation.go),
			// 固定中文,可用性同样由候选装配时的 usableValueAdd 把关;中文歌里那段外文被它译全了的也收(kuwoBakedTranslationCovers)。
			if c.hasUsableTranslation || kuwoBakedTranslationCovers(c.lyrics, kuwoTr, features().LyricsTranslationLanguage, artist, title) {
				r.LyricsTr = kuwoTr
				r.LyricsTrLang = "zh"
			}
		case "kugou":
			// 酷狗 KRC `[language:]` 内嵌的中文译文 / 罗马音(见 kugou.go krcLanguageTracks),
			// 口径与 qq 完全一致:译文固定 "zh",两轨都由候选装配时的 usableValueAdd 结果把关。
			if c.hasUsableTranslation {
				r.LyricsTr = kugouTr
				r.LyricsTrLang = "zh"
			}
			if usableRomaForResult(c.lyrics, kugouRoma) {
				r.LyricsRoma = kugouRoma
			}
		case "migu":
			// 咪咕 trcUrl 的译文固定中文,标 "zh",可用性由候选装配时的 usableValueAdd 结果
			// 把关——口径同网易云/QQ/酷狗;这个 switch 的纪律仍是"接一个源就必须在这里补一个
			// case"(见上面 qq 那条)。
			if c.hasUsableTranslation {
				r.LyricsTr = miguTr
				r.LyricsTrLang = "zh"
			}
		case "vibe":
			// VIBE 只有韩文译文,可用性由候选装配时的 usableValueAdd 把关。
			if c.hasUsableTranslation {
				r.LyricsTr = vibe.tr
				r.LyricsTrLang = vibeTranslationLang
			}
		case localFileLyricsSource:
			// 本地 .lrc 里摘出来的烘入译文(见候选装配处),固定中文,口径同 qq。
			if c.hasUsableTranslation {
				r.LyricsTr = localLRC.tr
				r.LyricsTrLang = "zh"
			}
		case importLyricsSource:
			if c.hasUsableTranslation {
				r.LyricsTr = imp.tr
				r.LyricsTrLang = importedTrLang(imp.trLang)
			}
			if usableRomaForResult(c.lyrics, imp.roma) {
				r.LyricsRoma = imp.roma
			}
			r.LyricsBG = imp.bg
		case lxMusicLocalLyricsSource:
			// 洛雪存下的是平台原版的译文 / 音译轨(国内平台的译文固定中文),口径同 qq。
			if c.hasUsableTranslation {
				r.LyricsTr = lxm.tr
				r.LyricsTrLang = "zh"
			}
			if usableRomaForResult(c.lyrics, lxm.roma) {
				r.LyricsRoma = lxm.roma
			}
		case "deezer":
			// Deezer 的译文按请求时的译文语言设置取(deezer.go deezerAcceptLanguage),标同一个语言;
			// 文字系统对不上目标语言的已在 deezerBuildTranslation 丢掉。
			if c.hasUsableTranslation {
				r.LyricsTr = dzTr
				r.LyricsTrLang = features().LyricsTranslationLanguage
			}
			r.Songwriters = dz.songwriters
		}
		// 括号里拆出来的背景人声(bgparen.go):写进结果,译文 / 罗马音同一行的括号段去掉。时间戳是重挂之前的,所以排在搬时间轴之前。
		if len(c.parenBGStamps) > 0 {
			r.LyricsBG = c.parenBG
			r.LyricsTr = stripParenBackgroundAux(r.LyricsTr, c.parenBGStamps)
			r.LyricsRoma = stripParenBackgroundAux(r.LyricsRoma, c.parenBGStamps)
		}
		// 正文时间轴被重挂过就把附属歌词一起搬过去。放在 switch **之后** —— 各源的
		// r.LyricsTr/r.LyricsRoma 到这里才赋完值,搬早了搬的是空串。
		if len(c.timelineRemap) > 0 {
			if tr, ok := remapLRCTimestamps(r.LyricsTr, c.timelineRemap); ok {
				r.LyricsTr = tr
			}
			if roma, ok := remapLRCTimestamps(r.LyricsRoma, c.timelineRemap); ok {
				r.LyricsRoma = roma
			}
		}
		results = append(results, r)
	}
	if src := handwrittenPlayerInstrumentalSource(raw, results); src != "" {
		instrumentalMarker = &scoredLyricCandidateResult{Source: src, Score: -1, Instrumental: true, PlayerInstrumental: true}
	}
	if instrumentalMarker != nil {
		results = append(results, *instrumentalMarker)
	}
	results = append(results, handwrittenNoLyricsMarkers(raw, instrumentalMarker)...)
	// v5:必须在排序**之前**跑——它要看的是"排完序会是谁赢",然后据此
	// 决定要不要撤销冠军的逐字加分,晚了就成了在排好的结果上事后改分,顺序会跟着乱。
	// instrumentalMarker(Score:-1)不受影响,函数内部本来就跳过负分。
	// 时间轴整体平移的扣分排在它前面:那一步要看的是扣完之后谁赢(见 applyTimelineOffsetPenalty)。
	applySourceDurationNearMissPenalty(results, durationSecs)
	applyTimelineOffsetPenalty(results, durationSecs)
	handwrittenMegalobizTimelinePenalty(results)
	applyTimelineIntrusionPenalty(results, durationSecs)
	applyGarbledTextPenalty(results)
	applyDurationNearTie(results, durationSecs)
	applyNativeSourceWordYield(results)
	applyWordTimingTitleOverride(results)
	// 稳定排序:来源加分拿掉之后同分会变多(见 scoreLyricCandidateDetailed 里那段注释),
	// 不稳定的排序会让同分候选的先后随运行变化,同一首歌两次解析可能选出不同的源。
	// 稳定之后就是按 candidates 的构造顺序决胜,确定且可复现。
	sort.SliceStable(results, func(i, j int) bool { return results[i].Score > results[j].Score })
	applyUnmaskedWords(results)
	applyBorrowedTranslations(results)
	applyBorrowedCovers(results)
	return results
}

func handwrittenPlayerInstrumentalSource(raw map[string]lyricSourceResult, results []scoredLyricCandidateResult) string {
	for _, src := range []string{lyricSourceNetease, lyricSourceQQ, lyricSourceSoda, lyricSourceAppleMusic, spotifyLocalLyricsSource} {
		r, ok := raw[src]
		if !ok || !r.forPlayingTrack || !playerOwnsLyricSource(src) {
			continue
		}
		claims, local := r.noVocals || r.instrumental, r.identityFromLocalClient
		if src == lyricSourceNetease {
			claims, local = r.ne.PureMusic || r.ne.NoVocals, r.ne.FromLocalClient
		}
		if !claims || !local {
			continue
		}
		for _, c := range results {
			if c.Source == src && !c.Instrumental && (c.Score >= 0 || c.PlainTextOnly) {
				return ""
			}
		}
		return src
	}
	return ""
}

func handwrittenNoLyricsMarkers(raw map[string]lyricSourceResult, instrumental *scoredLyricCandidateResult) []scoredLyricCandidateResult {
	var out []scoredLyricCandidateResult
	for _, source := range networkLyricSourceNames() {
		r, ok := raw[source]
		if !ok {
			continue
		}
		// 网易云这一路的结论挂在 ne 上(它整条信息走 neteaseInfo,不走 lyr 那几个字段),
		// 其余源统一走 lyricSourceResult.trackFoundNoLyrics。
		found := r.trackFoundNoLyrics
		title, artist, album, dur := r.matchTitle, r.matchArtist, r.matchAlbum, r.srcDur
		if source == "netease" {
			found = r.ne.TrackFoundNoLyrics
			title, artist, album, dur = r.ne.Title, r.ne.Artist, r.ne.Album, r.ne.DurationSecs
		}
		if !found {
			continue
		}
		if instrumental != nil && instrumental.Source == source {
			continue // ③ 纯音乐优先
		}
		out = append(out, scoredLyricCandidateResult{
			Source:                     source,
			Score:                      -1,
			TrackFoundNoLyrics:         true,
			Title:                      title,
			Artist:                     artist,
			Album:                      album,
			SourceReportedDurationSecs: dur,
		})
	}
	return out
}

func handwrittenMegalobizTimelinePenalty(results []scoredLyricCandidateResult) {
	for i := range results {
		r := &results[i]
		if r.Source != lyricSourceMegalobiz || r.Score < 0 || r.Lyrics == "" || len(r.ConsensusPeers) == 0 ||
			scoreTermPoints(r.ScoreTerms, scoreTermTimelineOffset) != 0 {
			continue
		}
		families := map[string]bool{}
		for _, p := range r.ConsensusPeers {
			families[lyricSourceConsensusFamily(p)] = true
		}
		own := displayedTimeline(r.Lyrics, r.LyricsYRC)
		later, earlier := 0, 0
		aligned := false
		for j, peer := range results {
			if j == i || peer.Score < 0 || peer.Lyrics == "" || !families[lyricSourceConsensusFamily(peer.Source)] {
				continue
			}
			switch classifyTimelines(own, displayedTimeline(peer.Lyrics, peer.LyricsYRC), megalobizTimelineShiftMs) {
			case timelineAligned:
				aligned = true
			case timelineShiftedLater:
				later++
			case timelineShiftedEarlier:
				earlier++
			}
		}
		if aligned || later+earlier == 0 || (later > 0 && earlier > 0) {
			continue
		}
		r.Score = max(r.Score-timelineOffsetPenalty, 1)
		r.ScoreTerms = append(r.ScoreTerms, scoreTerm{Kind: scoreTermTimelineOffset, Points: -timelineOffsetPenalty})
	}
}
