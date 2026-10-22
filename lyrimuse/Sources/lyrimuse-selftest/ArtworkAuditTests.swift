import Foundation
import LyrimuseCore

/// 封面整模块审计的修复(03 章决策 66)。cover-art 组开头调。
func checkArtworkAudit() {
    // ---- 均值色:预乘 alpha 的那一个像素除回 alpha ----
    do {
        typealias L = LocalPlaybackSource
        expectEqual(L.averageHex(premultipliedRGBA: [200, 100, 50, 255]), "#C86432FF", "均值色: 不透明的原样")
        expectEqual(L.averageHex(premultipliedRGBA: [100, 50, 25, 128]), "#C76432FF",
                    "均值色: 半透明封面除回 alpha,不按黑色压暗")
        expectEqual(L.averageHex(premultipliedRGBA: [0, 0, 0, 0]), nil, "均值色: 整张透明不给颜色")
    }

    // ---- 接线(契约) ----
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    let lps = source("LyrimuseCore/Local/LocalPlaybackSource.swift")
    let coordinator = source("lyrimuse/PlaybackCoordinator.swift")
    let store = source("lyrimuse/MotionCoverStore.swift")
    let window = source("lyrimuse/UI/LyricsWindowView.swift")

    // 取图
    do {
        let fetch = sourceBody("private func fetchArtworkForCurrentTrack(expectedKey: String, album: String?, bundleID: String?)", in: lps)
        expectEqual(sourceHas(fetch, "@MainActor func current() -> Bool {\n generation == self.artworkFetchGeneration && expectedKey == self.lastKey")
                    && fetch.components(separatedBy: "guard current() else { return }").count - 1 == 7
                    && !fetch.contains("guard expectedKey == self.lastKey else { return }"), true,
                    "取图: 重试与二次确认每一步都核这一轮还作数(代次 + 曲目),A→B→A 切回时旧那一轮让位")
        expectEqual(sourceHas(fetch, "self.artworkStaleTimeoutTask = nil\n // 字节没变也重新发布一次")
                    && sourceHas(fetch, "self.artworkData = confirmData\n continue"), true,
                    "取图: 留着的旧封面恰好就是这首的,也重新发布一次(引擎按发布时的 play_seq 认设备封面)")
    }

    // 高清替代 / Spotify 原图
    do {
        expectEqual(coordinator.contains("if onlyIfMissing, highResArtworkImage != nil, highResCoverApplied == nil { return }"), true,
                    "高清替代: 补查路按缓存里此刻的候选重核这里铺上的图,引擎这次播放改了 cover_url 就换")
        let highRes = sourceBody("private func refreshHighResCover(onlyIfMissing: Bool = false)", in: coordinator)
        expectEqual(highRes.components(separatedBy: "Self.stillTrack(title, artist, album)").count - 1, 2,
                    "高清替代: 下载、取色回来按歌名、歌手、专辑整组核对")
        expectEqual(sourceHas(coordinator, "if let url, spotifyCoverTask != nil, spotifyCoverTaskURL == url { return }\n spotifyCoverTask?.cancel()"),
                    true, "Spotify 原图: 同一地址那一轮还在升级就让它跑完,不被系统封面到货掐掉")
        expectEqual(coordinator.contains(".map { $0.flatMap(ImageMemoryCache.Variant.original.decode) }")
                    && !coordinator.contains(".map { $0.flatMap { NSImage(data: $0) } }"), true,
                    "系统封面: 解码时封顶 1024px")
    }

    // 动态封面
    do {
        expectEqual(sourceHas(coordinator, "guard MotionCoverDemand.wanted else {\n clear()\n return\n }")
                    && coordinator.contains("NotificationCenter.default.publisher(for: MotionCoverDemand.changed)")
                    && sourceHas(coordinator, "WebLyricsServer.screen.$viewerCount\n .map { $0 > 0 }\n .removeDuplicates()\n .dropFirst()\n .receive(on: DispatchQueue.main)")
                    && sourceHas(window, "artworkCard\n // 动态封面只在这张卡上播:卡在不在屏上决定要不要下载、取帧(MotionCoverDemand)。\n .onAppear { MotionCoverDemand.cardAppeared() }\n .onDisappear { MotionCoverDemand.cardDisappeared() }"),
                    true, "动态封面: 歌词窗口封面卡、副屏网页都没在显示时不下载不取帧,出现了再补")
        expectEqual(sourceHas(store, "guard let reference, running.reference != reference else { return result }\n if let hit = cachedFile(master: master) {\n return await checkCached(hit, key: key, reference: reference)"),
                    true, "动态封面: 加入别的参照图在跑的那一轮,下好了按自己的参照图再比一次")
        expectEqual(sourceHas(store, "case .mismatch:\n // 资源本身没问题")
                    && sourceHas(store, "try Self.moveIntoPlace(scratch, final: final)\n await MainActor.run { self.pruneIfNeeded() }\n return .referenceMismatch"),
                    true, "动态封面: 终审没过也落盘,封面到了按新参照图比,不再下第二遍")
        expectEqual(store.contains("if let backoff = transientBackoff[key], backoff.until > Date() { return nil }")
                    && store.contains("if http.statusCode == 429 || http.statusCode >= 500 { throw URLError(.badServerResponse) }"), true,
                    "动态封面: 清单 429 / 5xx 按网络层失败,暂时失败退避重试,不封到进程重启")
        expectEqual(store.contains("config.urlCache = nil") && !store.contains("URLSession.shared"), true,
                    "动态封面: 下载不进共享 URL 缓存,不挤掉静态高清封面")
    }
}
