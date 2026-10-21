import Foundation
import LyrimuseCore

/// 歌词同步引擎(App 侧)第三轮审计的修复(08 章决策 59)。sync-engine 组末尾调。
func checkSyncEngineAudit3() {
    // ---- 时间轴 ----
    do {
        // 同一行的两种时间版本不共用词组缓存:先建歌词窗口那版(保留真重叠),单行展示面那版的词组仍跟自己的逐字时间一致。
        let yrc = "[1000,3600](1000,500,0)き(1500,500,0)み(2000,2600,0)が\n[3000,1000](3000,500,0)そ(3500,500,0)ら\n"
        let engine = LyricsSyncEngine()
        engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)
        let window = engine.allLines(idPrefix: "a3").first?.line
        let single = engine.activeLine(atMs: 1200)
        expectEqual(single?.wordGroups != nil && window?.wordGroups != nil, true, "词组缓存: 这一行两版都有逐词读音分组")
        func groupDurations(_ line: SyncedLyricLine?) -> [Int] { (line?.wordGroups ?? []).flatMap { $0.words }.map { $0.durationMs } }
        expectEqual(groupDurations(single), (single?.words ?? []).map { $0.durationMs },
                    "词组缓存: 单行展示面那版的词组用自己的逐字时间,不拿歌词窗口那版的")
        expectEqual(groupDurations(window), (window?.words ?? []).map { $0.durationMs },
                    "词组缓存: 歌词窗口那版的词组用自己的逐字时间")
    }
    do {
        // 行首连着两个早到的字都夹到行首、照常逐字,不当成倒退把整行退化成匀速扫过。
        let out = LyricTimelineNormalizer.normalize([
            LyricLineWords(timeMs: 1000, words: [
                LyricWord(startMs: 900, durationMs: 100, text: "a"),
                LyricWord(startMs: 950, durationMs: 100, text: "b"),
                LyricWord(startMs: 1100, durationMs: 100, text: "c"),
            ]),
        ])
        expectEqual(out.lines.first?.words.map(\.startMs), [1000, 1000, 1100], "归一化: 早到的两个字都夹到行首")
        expectEqual(out.report.degradedLineCount, 0, "归一化: 倒退按源数据里的起点判,夹过的不算")
    }
    do {
        // 最后一句的兜底曲长换到歌词时间:总偏移 +5 秒时,最后一句多显示 5 秒。
        let lrc = "[00:10.00]第一句\n[00:20.00]最后一句\n"
        let engine = LyricsSyncEngine()
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        let plain = engine.tickQuery(atMs: 20_100, trackEndMs: 30_000).compactDwellMs
        engine.offsetMs = 5000
        let shifted = engine.tickQuery(atMs: 15_100, trackEndMs: 30_000).compactDwellMs
        expectEqual(plain != nil && shifted != nil, true, "最后一句时长: 给了曲长就有值")
        expectEqual(shifted.flatMap { s in plain.map { s - $0 } }, 5000, "最后一句时长: 曲长加上总偏移再兜底")
    }

    // ---- 译文 / 读音配对 ----
    do {
        // 就近判了不挂、又从没显示过的整行里补上的那一行:用补上的那条。
        let e = LyricsSyncEngine()
        e.load(lyrics: "[00:10.00]Hello there my friend\n[00:12.00]So every girl that I meet yeah this is what I say",
               lyricsTr: "[00:10.00]你好我的朋友\n[00:12.00]我会对遇到的每个女孩说",
               lyricsRoma: "",
               lyricsYRC: "[9000,1500](9000,1500,0)Hello there my friend\n" +
                   "[10600,1500](10600,1500,0)To every girl that I meet here this is what I say")
        expectEqual(e.allLines(idPrefix: "t2").map(\.line.translation), ["你好我的朋友", "我会对遇到的每个女孩说"],
                    "就近兜底: 判了不挂之后补上的译文照常显示")
    }
    do {
        // 带演唱者标签的行按剥掉标签的文字按内容配译文,不靠就近(逐字整体晚 0.7 秒、两句只隔 1 秒时就近会挂错)。
        let e = LyricsSyncEngine()
        e.load(lyrics: "[00:10.00]男：周末守着烤箱\n[00:11.00]女：一起看月亮",
               lyricsTr: "[00:10.00]甲\n[00:11.00]乙",
               lyricsRoma: "",
               lyricsYRC: "[10700,800](10700,300,0)男：(11000,500,0)周末守着烤箱\n[11700,800](11700,300,0)女：(12000,500,0)一起看月亮")
        expectEqual(e.allLines(idPrefix: "t3").map(\.line.translation), ["甲", "乙"],
                    "内容匹配: 演唱者标签剥掉再建键,带标签的行按内容配上自己的译文")
    }
    do {
        // 粤语歌:源粤拼只给了一部分,不整首清掉;没给的粤语行不现算(现算只会是普通话拼音)。
        let e = LyricsSyncEngine()
        e.load(lyrics: "[00:10.00]你好\n[00:12.00]早晨\n", lyricsTr: "", lyricsRoma: "[00:10.00]nei5 hou2\n", lyricsYRC: "",
               romanizationScripts: [.cantonese], songIsCantonese: true)
        let romas = e.allLines(idPrefix: "t1").map(\.line.romanization)
        expectEqual(romas.first ?? nil, "nei5 hou2", "粤语读音: 源粤拼覆盖不到八成也不整首清掉")
        expectEqual(romas.last ?? "x", nil, "粤语读音: 源粤拼只给了一部分时,缺的行照旧不现算")
        // 一首粤语歌里有一句韩文:纯汉字行照旧归粤拼。
        let k = LyricsSyncEngine()
        k.load(lyrics: "[00:10.00]你好\n[00:12.00]사랑해\n", lyricsTr: "", lyricsRoma: "[00:10.00]nei5 hou2\n", lyricsYRC: "",
               romanizationScripts: [.cantonese], songIsCantonese: true)
        expectEqual(k.allLines(idPrefix: "t6").first?.line.romanization, "nei5 hou2",
                    "粤语读音: 歌里有韩文行时纯汉字行仍按粤拼开关走")
    }

    // ---- 文本 ----
    expectEqual(LyricSongwriters.names(fromCreditLines: ["作词︰方文山"]), ["方文山"], "词曲作者: 竖排冒号变体也取得出名字")

    // ---- 偏移键 ----
    expectEqual(LyricsOffsetSiblings.name(ofWritingKey: "周杰伦|不散的筵席（I Miss You）|专辑"), "周杰伦|不散的筵席",
                "读穿: 兄弟写法的歌名段跟单曲偏移键同一套归一化(剥结尾的译名括号)")
    expectEqual(LyricsOffsetStore.trackKey(artist: "A", title: "Jasmine~dur2", lyrics: "[00:01.00]x", lyricsYRC: ""),
                LyricsOffsetStore.trackKey(artist: "A", title: "Jasmine", lyrics: "[00:01.00]x", lyricsYRC: ""),
                "单曲偏移键: 歌名的时长变体位不算(歌词管理拿的是缓存 key 里带变体位的歌名)")
    MainActor.assumeIsolated {
        let store = LyricsOffsetStore.shared
        // 每次一个新键:这个 store 落在 selftest 自己的 UserDefaults 上、跨运行留着,空指纹的键写进去之后也清不掉。
        let noLyrics = LyricsOffsetStore.trackKey(artist: "A-\(UUID().uuidString)", title: "T", lyrics: "", lyricsYRC: "")
        expectEqual(store.nudge(by: 300, forKey: noLyrics, pinKey: "", siblings: .none), 0,
                    "单曲偏移: 歌词还没出来时按加减不存,返回的是原值")
        expectEqual(store.offset(forKey: noLyrics), 0, "单曲偏移: 没有指纹的键不记账")
    }

    // ---- 接线(契约) ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
        }
        let local = source("LyrimuseCore/Local/LocalPlaybackSource.swift")
        let engineSrc = source("LyrimuseCore/Lyrics/LyricsSyncEngine.swift")
        let coordinator = source("lyrimuse/PlaybackCoordinator.swift")
        let manager = source("lyrimuse/LyricsManager/LyricsManagerView.swift")
        let parts = source("lyrimuse/LyricsManager/LyricsManagerParts.swift")
        let editor = source("lyrimuse/LyricsManager/LyricsExternalEditor.swift")
        expectEqual(sourceHas(sourceBody("private func retickSoon()", in: local),
                              "guard self.anchor == nil, self.pausedPositionMs != nil, !self.screenLocked else { return } self.resolveLinesForPausedPosition()"),
                    true, "暂停时改偏移 / 开关: 下一圈按冻结位置重选一次,不等轮询")
        let reload = sourceBody("private func reloadCurrentLyrics()", in: local)
        expectEqual(sourceHas(reload, "lastReloadSnapshot = reloadSnapshot // 内容真变了才清防回跳(LineSelectionHold):只是缓存文件被别的歌写了一下、内容没变的那次不算重载。 lineSelectionHeldMs = nil")
                    && !sourceHas(reload, "private func reloadCurrentLyrics() { lineSelectionHeldMs = nil"),
                    true, "防回跳: 只在歌词内容真变了时清")
        expectEqual(sourceHas(reload, "if siblings != currentOffsetSiblings { currentOffsetSiblings = siblings applyOffsets() } return"),
                    true, "读穿: 内容没变早退时也对一次兄弟写法")
        expectEqual(sourceHas(reload, "currentPinKey = EnrichCacheReader.resolvedKey(artist: pinArtist, title: pinTitle, album: pinAlbum)")
                    && sourceBytes(editor, contain: "pinKey: session.key,")
                    && !sourceBytes(editor, contain: "strippingDurationVariant(session.key)"),
                    true, "校准钉: 播放侧和外部编辑器都钉在实际那条(含时长变体位),跟引擎、歌词管理同一个身份")
        expectEqual(sourceBytes(local, contain: "lyricsBoundOffsetMs = track + radio")
                    && sourceBytes(parts, contain: "currentTrackMs: LocalPlaybackSource.shared.lyricsBoundOffsetMs,"),
                    true, "候选预览: 扣掉挂在这份歌词上的单曲和电台两档")
        expectEqual(sourceBytes(coordinator, contain: "trackDurationMs: currentDurationMs.map { $0 + currentLyricsOffsetMs })"),
                    true, "最后一句时长(菜单栏配速): 曲长换到歌词时间")
        expectEqual(sourceBytes(manager, contain: ".onChange(of: offsets.revision) { _, _ in refreshShownOffset() }")
                    && sourceHas(manager, "showStoredOffset(0)\n offsetBorrowedFrom = nil"),
                    true, "歌词管理: 偏移输入框跟着菜单、快捷键改的值刷新;清空全部时借用来源一起清")
        expectEqual(sourceHas(engineSrc, "let end = wordLines[index].words.map({ $0.startMs + max(0, $0.durationMs) }).max()"),
                    true, "间奏 / 提前量: 逐字行唱到几点取最晚的字,不取最后一个")
        expectEqual(engineSrc.components(separatedBy: "wordGroups(for: words, line: joined, lineTimeMs: ln.timeMs)").count - 1, 2,
                    "逐词读音: 整行那两处按行起点查")
    }
}
