import Foundation
import LyrimuseCore

/// 灵动岛音浪「跟随音乐跳动」:频段分析、自适应归一化与快升慢落、输出延迟、退回判定、跟哪些进程、默认关与接线。
func runRealAudioTests() {
    // MARK: 频段
    let edges = RealAudioSpectrum.bandEdges()
    expectEqual(edges.count, RealAudioSpectrum.bandCount + 1, "真实音浪: 5 段有 6 条边界")
    expectEqual([abs(edges.first! - 50) < 1e-9, abs(edges.last! - 16000) < 1e-6], [true, true], "真实音浪: 边界首尾 50Hz / 16kHz")
    let ratios = zip(edges.dropFirst(), edges).map { $0 / $1 }
    expectEqual(ratios.allSatisfy { abs($0 - ratios[0]) < 1e-9 }, true, "真实音浪: 频段按对数等分")
    expectEqual(RealAudioSpectrum.barBand.sorted(), Array(0..<RealAudioSpectrum.bandCount), "真实音浪: 条子 → 频段是一一对应")
    expectEqual(RealAudioSpectrum.barBand[RealAudioSpectrum.bandCount / 2], 0, "真实音浪: 最低的频段放在正中那根")

    expectEqual(RealAudioSpectrum.Analyzer(sampleRate: 0) == nil, true, "真实音浪: 采样率 0 不建分析器")
    for rate in [44100.0, 48000.0, 96000.0] {
        let a = RealAudioSpectrum.Analyzer(sampleRate: rate)!
        expectEqual(a.bandBins.allSatisfy { $0 != nil }, true, "真实音浪: \(Int(rate))Hz 下每段都落到频点")
    }
    let analyzer = RealAudioSpectrum.Analyzer(sampleRate: 48000)!
    func sine(_ hz: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<RealAudioSpectrum.fftSize).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / 48000)) }
    }
    for (hz, band) in [(90.0, 0), (300.0, 1), (1000.0, 2), (3000.0, 3), (8000.0, 4)] {
        let p = analyzer.bandPowers(sine(hz))
        let top = p.indices.max { p[$0] < p[$1] }!
        let others = p.indices.filter { $0 != band }.map { p[$0] }
        expectEqual(top, band, "真实音浪: \(Int(hz))Hz 正弦落在第 \(band) 段")
        expectEqual(others.allSatisfy { $0 * 100 < p[band] }, true, "真实音浪: \(Int(hz))Hz 正弦别的段低 20dB 以上")
    }
    expectEqual(analyzer.bandPowers([Float](repeating: 0, count: RealAudioSpectrum.fftSize)), [0, 0, 0, 0, 0], "真实音浪: 静音各段都是 0")
    expectEqual(analyzer.bandPowers([0.1, 0.2, Float.nan]).count, 5, "真实音浪: 采样不够数、带 NaN 也照样出 5 段")
    expectEqual(analyzer.bandPowers([0.1, 0.2, Float.nan]).allSatisfy { $0.isFinite }, true, "真实音浪: NaN 采样不污染结果")

    // MARK: 自适应归一化、快升慢落
    let step = 1.0 / 30
    func db(_ v: Double) -> Double { pow(10, v / 10) }
    func run(_ f: inout RealAudioBandFollower, _ powers: [Double], seconds: Double) {
        for _ in 0..<Int((seconds / step).rounded()) { f.update(powers: powers, dt: step) }
    }
    var f = RealAudioBandFollower()
    expectEqual(f.levels, [0, 0, 0, 0, 0], "真实音浪: 起始全 0")
    f.update(powers: Array(repeating: db(-10), count: 5), dt: step)
    expectEqual(f.levels.allSatisfy { $0 > 0.6 }, true, "真实音浪: 快升——一帧(1/30 秒)就升到六成以上")
    run(&f, Array(repeating: db(-10), count: 5), seconds: 1)
    expectEqual(f.levels.allSatisfy { $0 > 0.99 }, true, "真实音浪: 持续响一秒顶满")
    f.update(powers: [0, 0, 0, 0, 0], dt: step)
    expectEqual(f.levels.allSatisfy { $0 > 0.8 }, true, "真实音浪: 慢落——静音后第一帧还在八成以上")
    run(&f, [0, 0, 0, 0, 0], seconds: 1)
    expectEqual(f.levels.allSatisfy { $0 < 0.01 }, true, "真实音浪: 静音一秒落回底")

    var g = RealAudioBandFollower()
    run(&g, Array(repeating: db(6), count: 5), seconds: 1)
    expectEqual([g.levels.allSatisfy { $0 <= 1 }, g.ceilingsDB.allSatisfy { abs($0 - 6) < 1e-9 }], [true, true],
                "真实音浪: 峰值超过 1(+6dB)时上限跟上去、电平不超 1")
    run(&g, Array(repeating: db(-30), count: 5), seconds: 1)
    expectEqual(g.levels.allSatisfy { $0 < 0.3 }, true, "真实音浪: 响段刚过,安静段先矮下去")
    run(&g, Array(repeating: db(-30), count: 5), seconds: 12)
    expectEqual(g.levels.allSatisfy { $0 > 0.9 }, true, "真实音浪: 上限慢慢放下来,十几秒后安静段重新跳得起来")

    expectEqual([0, -3, -6, -12, -20].map { RealAudioBandFollower.level(db: -10 + $0, ceilingDB: -10) }, [1, 0.75, 0.5, 0, 0],
                "真实音浪: 贴着上限满格、低 6dB 半高、低 12dB 贴底")
    expectEqual([RealAudioBandFollower.level(db: -95, ceilingDB: -45), RealAudioBandFollower.level(db: .nan, ceilingDB: 0),
                 RealAudioBandFollower.level(db: 3, ceilingDB: 0)], [0, 0, 1], "真实音浪: 静音 / 坏值是 0,超过上限夹在 1")
    // 压得很响的歌:拍子上 -10dB、拍子间 -20dB,每拍 0.5 秒。条子在一拍里要有一半以上的起落;动态范围放宽到 15dB 就不到一半。
    var beat = RealAudioBandFollower()
    var beatLevels: [Double] = []
    for i in 0..<Int((4 / step).rounded()) {
        let on = (Double(i) * step).truncatingRemainder(dividingBy: 0.5) < 0.25
        beat.update(powers: Array(repeating: db(on ? -10 : -20), count: 5), dt: step)
        if Double(i) * step >= 3 { beatLevels.append(beat.levels[0]) }
    }
    expectEqual(beatLevels.max()! - beatLevels.min()! > 0.5, true, "真实音浪: 响的歌每拍 10dB 的起落在条子上看得出来(一半以上)")

    var noise = RealAudioBandFollower()
    run(&noise, Array(repeating: db(-80), count: 5), seconds: 30)
    expectEqual(noise.levels.allSatisfy { $0 < 0.05 }, true, "真实音浪: 只剩底噪时上限停在下限、底噪不被放大")
    var split = RealAudioBandFollower()
    run(&split, [db(-5), db(-15), db(-20), db(-30), db(-40)], seconds: 20)
    expectEqual(split.levels.allSatisfy { $0 > 0.95 }, true, "真实音浪: 各段各有上限,高频能量小也跳得起来")
    var junk = RealAudioBandFollower()
    junk.update(powers: [.nan, -1, .infinity, 0], dt: .nan)
    junk.update(powers: [.nan, -1, .infinity, 0, 1], dt: -3)
    expectEqual(junk.levels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, true, "真实音浪: 坏输入不出界")
    junk.reset()
    expectEqual(junk, RealAudioBandFollower(), "真实音浪: reset 回到初始")

    expectEqual([RealAudioSpectrum.barLevel(0), RealAudioSpectrum.barLevel(1), RealAudioSpectrum.barLevel(.nan),
                 RealAudioSpectrum.barLevel(2), RealAudioSpectrum.barLevel(-1)],
                [RealAudioSpectrum.liveFloorLevel, 1, RealAudioSpectrum.liveFloorLevel, 1, RealAudioSpectrum.liveFloorLevel],
                "真实音浪: 条高抬上地板、夹在 0…1")

    // MARK: 按输出延迟后推
    var delay = RealAudioDelayLine()
    for i in 0..<10 { delay.push(time: Double(i) / 30, levels: [Double(i)]) }
    expectEqual(delay.pop(now: 0.1, delay: 0.16), nil, "真实音浪: 没到延迟的帧不画")
    expectEqual(delay.pop(now: 0.2, delay: 0.16), [1], "真实音浪: 到点的帧里取最新那一帧(0.2-0.16=0.04 → 第 1 帧)")
    expectEqual(delay.pop(now: 0.2, delay: 0.16), nil, "真实音浪: 用过的帧连同更早的丢掉")
    expectEqual(delay.pop(now: 10, delay: .nan), [9], "真实音浪: 延迟读成 NaN 按 0")
    for i in 0..<100 { delay.push(time: Double(i), levels: []) }
    expectEqual(delay.count, RealAudioDelayLine.capacity, "真实音浪: 延迟线有上限")
    expectEqual([ProcessAudioOutput.needsRetap(targets: [7, 9], tapped: [9, 7], tapOutputUID: "spk", outputUID: "spk"),
                 ProcessAudioOutput.needsRetap(targets: [7], tapped: [9], tapOutputUID: "spk", outputUID: "spk"),
                 ProcessAudioOutput.needsRetap(targets: [7], tapped: [7], tapOutputUID: "airpods", outputUID: "spk"),
                 ProcessAudioOutput.needsRetap(targets: [7], tapped: [7], tapOutputUID: "airpods", outputUID: nil),
                 ProcessAudioOutput.needsRetap(targets: [], tapped: [], tapOutputUID: nil, outputUID: "spk")],
                [false, true, true, false, false], "真实音浪: 进程没换、输出设备没换不重建;换了进程或换了输出设备(拔耳机)重建")
    expectEqual(sourceHas(sourceBody("private func retarget(bundleID: String, now: Double)", in: (try? String(contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lyrimuse/UI/RealAudioMeter.swift"), encoding: .utf8)) ?? ""),
                          "tapOutputUID: (tap as? ProcessAudioTap)?.outputDeviceUID"), true,
                "真实音浪(契约): 重建与否连同输出设备一起判")
    expectEqual([ProcessAudioOutput.outputLatencySeconds(frames: 7680, sampleRate: 48000),
                 ProcessAudioOutput.outputLatencySeconds(frames: 0, sampleRate: 48000),
                 ProcessAudioOutput.outputLatencySeconds(frames: 480000, sampleRate: 48000),
                 ProcessAudioOutput.outputLatencySeconds(frames: 512, sampleRate: 0)],
                [0.16, 0, 0.5, 0], "真实音浪: 输出延迟按帧数折秒,夹在 0…0.5")

    // MARK: 退回判定
    var gate = RealAudioLevelGate()
    expectEqual(gate.isLive(now: 0), false, "真实音浪: 没建 tap 不跟随")
    gate.tapStarted(at: 0)
    gate.noteCallbacks(at: 0.5, heard: false)
    expectEqual(gate.isLive(now: 0.6), false, "真实音浪: 回调在来但从没读到声音,不跟随(退回时间轴音浪)")
    expectEqual([gate.likelyDenied(now: 2.9, playerOutputting: true), gate.likelyDenied(now: 3, playerOutputting: true),
                 gate.likelyDenied(now: 30, playerOutputting: false)],
                [false, true, false], "真实音浪: 播放器在出声、tap 一直静音满 3 秒才判作没授权;播放器不出声不算")
    gate.noteCallbacks(at: 4, heard: true)
    expectEqual([gate.isLive(now: 4.2), gate.likelyDenied(now: 10, playerOutputting: true)], [true, false],
                "真实音浪: 读到过声音就跟随,不再提示授权")
    gate.noteCallbacks(at: 5, heard: false)
    expectEqual(gate.isLive(now: 5.3), true, "真实音浪: 读到过声音后,真安静的段落照样跟随(条子贴地板)")
    expectEqual(gate.isLive(now: 5.6), false, "真实音浪: 回调停了 0.5 秒(播放器不在本机出声)就退回")
    gate.tapStopped()
    expectEqual(gate.isLive(now: 5.6), false, "真实音浪: 拆了 tap 不跟随")
    gate.tapStarted(at: 6)
    expectEqual([gate.everHeard, gate.likelyDenied(now: 20, playerOutputting: true)], [true, false],
                "真实音浪: 换播放器重建 tap 不清「读到过声音」")

    // MARK: 采样环
    let ring = SampleRing(capacity: 4)
    let stereo: [Float] = [1, -9, 2, -9, 3, -9]
    stereo.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 3, stride: 2) }
    let zeros: [Float] = [0, 0]
    zeros.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 2, stride: 1) }
    let snap = ring.snapshot()
    expectEqual([snap.samples, [Float(snap.callbacks), Float(snap.heardCallbacks)]], [[2, 3, 0, 0], [2, 1]],
                "真实音浪: 采样环只留最近的、按时间排、多声道取第一个,记回调数和有声的回调数")

    // MARK: 跟哪些进程
    let gpu = "com.apple.WebKit.GPU"
    let table: [TapProcess] = [
        TapProcess(bundleID: "com.apple.Music", pid: 100),
        TapProcess(bundleID: gpu, pid: 201, responsiblePID: 200),
        TapProcess(bundleID: "com.apple.Safari", pid: 200),
        TapProcess(bundleID: "com.spotify.client", pid: 300),
        TapProcess(bundleID: "com.spotify.client.helper", pid: 301),
        TapProcess(bundleID: "com.spotify.clientx", pid: 310),
        TapProcess(bundleID: gpu, pid: 401, responsiblePID: 400),
        TapProcess(bundleID: gpu, pid: 501, responsiblePID: 500),
        TapProcess(bundleID: "com.apple.mail", pid: 400),
        TapProcess(bundleID: "com.netease.163music", pid: 600),
        TapProcess(bundleID: NetEaseIPadNowPlaying.bundleID, pid: 610),
        TapProcess(bundleID: "com.audirvana.Audirvana-Origin", pid: 700),
        TapProcess(bundleID: "com.amazon.music", pid: 800, responsiblePID: 800),
        TapProcess(bundleID: "com.amazon.music-renderer", pid: 801, responsiblePID: 800),
        TapProcess(bundleID: "com.google.Chrome.helper", pid: 901, responsiblePID: 990),
    ]
    func targets(_ bundleID: String, reporting: String? = nil, hostPIDs: Set<pid_t> = []) -> [Int] {
        ProcessAudioOutput.tapTargetIndices(hosts: ProcessAudioOutput.tapHosts(bundleID: bundleID, reportingClient: reporting),
                                            table: table, hostPIDs: hostPIDs)
    }
    expectEqual(targets("com.apple.Music"), [0], "真实音浪: 本地播放器读它自己")
    expectEqual([targets(gpu), targets("com.apple.Safari")], [[1, 2], [1, 2]],
                "真实音浪: Safari 网页在放(系统报的是 WebKit 媒体进程)只读 Safari 和负责进程是它的那个媒体进程,别的 App 的媒体进程不读")
    var safariHidden = table
    safariHidden.remove(at: 2)
    expectEqual(ProcessAudioOutput.tapTargetIndices(hosts: ["com.apple.Safari"], table: safariHidden, hostPIDs: [200]), [1],
                "真实音浪: 宿主自己没有进程对象时按它在跑的进程号认媒体进程")
    expectEqual(targets("com.sertacozercan.Kaset", hostPIDs: [500]), [7],
                "真实音浪: 内嵌网页的 App(Kaset)读负责进程是它的那个媒体进程")
    var unknownOwner = table
    unknownOwner[6].responsiblePID = nil
    unknownOwner[6].pid = 0
    expectEqual([ProcessAudioOutput.tapTargetIndices(hosts: ["com.apple.Safari"], table: unknownOwner, hostPIDs: []),
                 ProcessAudioOutput.tapTargetIndices(hosts: ["com.apple.Safari"], table: unknownOwner, hostPIDs: [], ownerLookup: false)],
                [[1, 2], [1, 2, 6]],
                "真实音浪: 查不到负责进程(进程对象报 pid 0)的媒体进程不读;整个查询用不了时才按表把媒体进程都算给 Safari")
    expectEqual(targets("com.spotify.client"), [3, 4],
                "真实音浪: 连辅助进程一起读,名字只是前缀相同的别的 App 不算")
    expectEqual([targets("com.netease.163music"), targets("com.netease.163music", reporting: NetEaseIPadNowPlaying.bundleID)],
                [[9], [10]], "真实音浪: 另一个程序的版本(iPad 版网易云)只在会话是它报的时候读它,本体就不读")
    expectEqual(targets("com.audirvana.Audirvana-Studio"), [11], "真实音浪: 同一个播放器的别的版本(Audirvana Origin)也读")
    expectEqual(targets("com.amazon.music"), [12, 13], "真实音浪: bundle id 跟本体不沾边、负责进程是它的子进程也读(Amazon Music 的渲染进程)")
    expectEqual(targets("com.google.Chrome"), [14], "真实音浪: 负责进程是别的 App(从终端拉起的浏览器)的辅助进程照 bundle id 前缀读")
    expectEqual([targets(""), targets("com.example.bridge")], [[], []],
                "真实音浪: 没识别出播放器、本机没有它的进程(iPhone 桥接)时不建 tap")

    // MARK: 默认关、接线、不落盘
    let selftestDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let sources = selftestDir.deletingLastPathComponent()
    let pkg = sources.deletingLastPathComponent()
    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func app(_ rel: String) -> String { read(sources.appendingPathComponent("lyrimuse/" + rel)) }
    func core(_ rel: String) -> String { read(sources.appendingPathComponent("LyrimuseCore/" + rel)) }
    let settings = app("Settings/AppSettings.swift")
    expectEqual(sourceHas(settings, "static let defaultNotchEqualizerFollowsAudio = false"), true, "真实音浪: 开关默认关")
    expectEqual(sourceHas(settings, "notchEqualizerFollowsAudio = (defaults.object(forKey: Keys.notchEqualizerFollowsAudio) as? Bool) ?? Self.defaultNotchEqualizerFollowsAudio"),
                true, "真实音浪: 没存过时取默认值")
    expectEqual(sourceHas(app("Settings/ConfigPortability.swift"), "\"np:notchEqualizerFollowsAudio\","), true,
                "真实音浪: 开关不随配置搬家(授权是每台机器各自的)")
    expectEqual([sourceHas(read(pkg.appendingPathComponent("build.sh")), "<key>NSAudioCaptureUsageDescription</key>"),
                 sourceHas(read(pkg.appendingPathComponent("Localization/generate-strings.py")), "\"NSAudioCaptureUsageDescription\":")],
                [true, true], "真实音浪: Info.plist 有系统录音的用途说明,各语言走 InfoPlist.strings")
    let meter = app("UI/RealAudioMeter.swift")
    expectEqual([sourceHas(meter, "$notchEqualizerFollowsAudio .removeDuplicates().dropFirst()"),
                 sourceHas(meter, "if on { self.engine.primeAuthorization() }")], [true, true],
                "真实音浪: 只在开关拨开的那一下要授权,启动时不弹")
    let bars = app("UI/EqualizerBars.swift")
    expectEqual([sourceHas(sourceBody("private func syncListening()", in: bars), "let listening = followsAudio && isPlaying && window != nil"),
                 sourceHas(sourceBody("private func reinstall()", in: bars), "if liveAudio { return }"),
                 sourceHas(app("UI/NotchLyricsView+TopRow.swift"), "followsAudio: playback.equalizerFollowsAudio")],
                [true, true, true], "真实音浪: 只在开关开、在播、在窗口里时登记;跟随时停掉关键帧;灵动岛音浪接上开关")
    let rows = app("UI/NotchSettingsRows.swift")
    let equalizerRow = sourceBody("private var equalizerRow: some View", in: rows)
    expectEqual([sourceHas(rows, "private var showsFollowsAudioButton: Bool { showsEqualizerHere && RealAudioMeter.isSupported }"),
                 sourceHas(equalizerRow, "HStack(spacing: 8) {\nfollowsAudioButton\nToggle(\"\", isOn: Binding("),
                 sourceHas(sourceBody("private var followsAudioButton: some View", in: rows),
                           "if showsFollowsAudioButton {\nSettingsGlassPopoverButton(label: L10n.t(\"跟随音乐跳动\")"),
                 sourceHas(sourceBody("var body: some View", in: sourceBody("struct NotchEarSettingsRows: View", in: rows)),
                           "equalizerRow\nCardDivider()\nSettingsRow(icon: \"rectangle.lefthalf.inset.filled\""),
                 sourceHas(sourceBody("struct NotchFollowsAudioPopover: View", in: rows),
                           "Toggle(\"\", isOn: $settings.notchEqualizerFollowsAudio)")],
                [true, true, true, true, true],
                "真实音浪: 开关在音浪那一行开关左边的按钮浮层里,不单独占一行;按钮只在音浪贴这一侧、系统支持时出现")
    let tap = core("Local/ProcessAudioTap.swift")
    let leaks = ["write(to:", "FileManager", "AVAudioFile", "ExtAudioFile", "AudioFileCreate", "FileHandle", "FileIO."]
    expectEqual(leaks.filter { tap.contains($0) || meter.contains($0) }, [], "真实音浪: 读到的采样不写盘")
    expectEqual(sourceHas(tap, "desc.muteBehavior = .unmuted"), true, "真实音浪: tap 不静音源 App")
}
