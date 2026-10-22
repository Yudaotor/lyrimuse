import Foundation
import LyrimuseCore

/// 打卡与账号整模块审计的修复(12 章决策 91)。lastfm 组开头调。
func checkScrobbleAudit() {
    // ---- 日桶键解析:零点切夏令时的那一天也解得出 ----
    do {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Santiago")!
        // 跟 LastfmStatsService.dayKeyFormatter 同样配(不设 calendar)
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // 智利这一天 0 点直接跳到 1 点
        expectEqual(formatter.date(from: "2024-09-08") == nil, true, "日桶键: 前提——按格式串解析的 DateFormatter 在这一天解出 nil")
        let day = ListeningMilestones.parseDay("2024-09-08", calendar: calendar)
        expectEqual(day.map { calendar.component(.day, from: $0) }, 8, "日桶键: 夏令时那天解成当天第一个存在的时刻")
        expectEqual(ListeningMilestones.parseDay("2024-09-07", calendar: calendar).map { calendar.component(.hour, from: $0) }, 0,
                    "日桶键: 平常日子是 0 点")
    }

    // ---- 接线(契约) ----
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    let stats = source("lyrimuse/Settings/LastfmStatsService.swift")
    let section = source("lyrimuse/LastfmStatsSection.swift")
    let store = source("lyrimuse/Settings/ConfigStore.swift")
    let portability = source("lyrimuse/Settings/ConfigPortability.swift")
    let settings = source("lyrimuse/SettingsView.swift")
    let accounts = source("lyrimuse/AccountLinkingTab.swift")

    // 账号凭据
    do {
        let split = sourceBody("private func writeSplittingCredentials(fields: [String: Any], knownKeys: Set<String>) throws", in: store)
        expectEqual(sourceHas(split, "if vaultContents == nil, CredentialVault.clearsCredential(from: credentialedRaw, to: full) {\n throw ConfigFileSaveError.keychainUnavailable"),
                    true, "账号凭据: 钥匙串读不出时拒绝清空凭据")
        expectEqual(sourceHas(sourceBody("public func reloadIfVaultWasUnreadable()", in: store),
                              "guard vaultContents == nil, !isDirty, CredentialVaultStore.shared.load() != nil else { return }"),
                    true, "账号凭据: 钥匙串之前没读出、现在读得出、没有待存改动才重载")
        expectEqual(sourceHas(accounts, ".onAppear { config.reloadIfVaultWasUnreadable() }"), true, "账号凭据: 进账号页补读一次")
        let clear = sourceBody("static func clearAllConfig() async -> Bool", in: portability)
        let vaultAt = clear.range(of: "try CredentialVaultStore.shared.clearAccountCredentials()")?.lowerBound
        let fileAt = clear.range(of: "removeItem(at: configURL)")?.lowerBound
        expectEqual(vaultAt != nil && fileAt != nil && vaultAt! < fileAt! && sourceHas(clear, "} catch {"), true,
                    "清除全部: 先清钥匙串,清不掉就什么都不动")
        expectEqual(sourceHas(settings, "guard await ConfigPortability.clearAllConfig() else {\n configMessage = L10n.t(\"钥匙串当前无法读取，设置未清除\")\n return\n }"),
                    true, "清除全部: 清不掉不重启、给提示")
        let importBody = sourceBody("static func importData(_ data: Data) async -> Bool", in: portability)
        let writeAt = importBody.range(of: "try configData.writeSecurely(to: configURL)")?.lowerBound
        let wipeAt = importBody.range(of: "try CredentialVaultStore.shared.clearAccountCredentials()")?.lowerBound
        let reloadAt = importBody.range(of: "await MainActor.run { ConfigStore.shared.load() }")?.lowerBound
        expectEqual(writeAt != nil && wipeAt != nil && reloadAt != nil && writeAt! < wipeAt! && wipeAt! < reloadAt!, true,
                    "导入: 写完文件再清钥匙串里的旧凭据,然后重载")
        expectEqual(sourceHas(sourceBody("static func buildExportData() -> Data?", in: portability),
                              "lastExportOmittedCredentials = vault == nil"), true, "导出: 记下钥匙串读不出")
        expectEqual(settings.components(separatedBy: "ConfigPortability.lastExportOmittedCredentials").count - 1, 2,
                    "导出: iCloud 和导出到文件两处都提示")
    }

    // 「第 N 次听」
    do {
        let refresh = sourceBody("func refreshNowPlayingCount(title: String, artist: String)", in: stats)
        expectEqual(sourceHas(refresh, "guard var total = results[0]?.count else {\n nowPlayingCountKey = \"\"\n return\n }"), true,
                    "第 N 次听: 本尊没答上来时孪生的半截合计不写表、不显示")
        expectEqual(sourceHas(refresh, "if total >= known {\n // 顺手把这个**新鲜的合并总数**写回历史行用的那张表(见 adoptFreshTotal)。\n adoptFreshTotal(")
                    && sourceHas(refresh, "nowPlayingCount = displayedNowPlayingCount(total: max(total, known))"), true,
                    "第 N 次听: 换歌那一刻的偏低旧数不冲掉表里更大的")
        let scrobbled = sourceBody("private func currentPlayIsScrobbled(familyKey key: String) -> Bool", in: stats)
        expectEqual(sourceHas(scrobbled, "PlayCountFold.familyKey(artist: pc.artist, title: pc.title) == key")
                    && sourceHas(scrobbled, "&& PlayCountFold.familyKey(artist: $0.artist, title: $0.title) == key"), true,
                    "第 N 次听: 落库判据按写法族比(本机写法、Last.fm 规范名折到一起)")
        expectEqual(section.components(separatedBy: "stats.refreshNowPlayingCount(title: live.title, artist: live.countArtist)").count - 1, 2,
                    "第 N 次听: 设置页实时行用本机歌手名取数")
        expectEqual(sourceHas(section, "countArtist: playback.artist,"), true, "第 N 次听: 本机这首的取数歌手是本机写法")
    }

    // 历史扫描与榜单
    do {
        expectEqual(sourceHas(stats, "if full && page <= totalPages {\n historyCheckpoint = HistorySyncCheckpoint(\n username: cred.user, page: page - 1,"),
                    true, "历史扫描: 用完一轮请求预算还没扫完按中断处理,落断点")
        let direct = sourceBody("private func fetchChartDirect(kind: ChartKind, period: Period, key: String,", in: stats)
        expectEqual(direct.components(separatedBy: "guard epoch == accountEpoch else { return true }").count - 1, 2,
                    "榜单: 直取的结果写回前核对账号")
        let merged = sourceBody("private func refreshMergedArtistChart(cacheKey: String, period: Period)", in: stats)
        expectEqual(sourceHas(merged, "if mergedArtistChartRunEpoch == accountEpoch {\n mergedArtistChartWaiting[cacheKey] = period\n return\n }"),
                    true, "榜单: 歌手榜子进程在跑就等它,不再起第二个")
        expectEqual(merged.components(separatedBy: "guard svc.accountEpoch == epoch else { return }").count - 1, 2,
                    "榜单: 子进程结果写回前核对账号(成功、失败两条)")
        let onThisDay = sourceBody("func refreshOnThisDay(force: Bool = false)", in: stats)
        expectEqual(onThisDay.components(separatedBy: "generation == onThisDayGeneration").count - 1, 3,
                    "那年今日: 只认最后起飞的那一轮")
        expectEqual(sourceHas(sourceBody("private func loadRecentPageCache()", in: stats),
                              "if snap.mergedCountsVersion == Self.mergedCountsVersion, let counts = snap.playCounts"), true,
                    "翻页缓存: 口径版本对不上不还原次数")
        let reset = sourceBody("func resetAll()", in: stats)
        expectEqual(sourceHas(reset, "truncationRescanAttempted = false") && sourceHas(reset, "playCountVerifiedAt = [:]"), true,
                    "换账号: 截断自愈和验证时刻一起清")
        expectEqual(sourceHas(sourceBody("func loadDayListens(_ dayKey: String, force: Bool = false)", in: stats),
                              "guard let start = ListeningMilestones.parseDay(dayKey, calendar: .current),"), true,
                    "热力图: 点开某天按日历组件解析")
    }
}
