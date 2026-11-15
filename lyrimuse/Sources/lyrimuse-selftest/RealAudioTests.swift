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
    let table = ["com.apple.Music", "com.apple.WebKit.GPU", "com.apple.Safari", "com.spotify.client",
                 "com.spotify.client.helper", "com.spotify.clientx", "com.apple.WebKit.GPU"]
    expectEqual(ProcessAudioOutput.tapTargetIndices(bundleID: "com.apple.Music", table: table), [0], "真实音浪: 本地播放器读它自己")
    expectEqual(ProcessAudioOutput.tapTargetIndices(bundleID: "com.apple.Safari", table: table), [1, 2, 6],
                "真实音浪: Safari 连它的 WebKit 媒体进程一起读")
    expectEqual(ProcessAudioOutput.tapTargetIndices(bundleID: "com.spotify.client", table: table), [3, 4],
                "真实音浪: 连辅助进程一起读,名字只是前缀相同的别的 App 不算")
    expectEqual([ProcessAudioOutput.tapTargetIndices(bundleID: "", table: table),
                 ProcessAudioOutput.tapTargetIndices(bundleID: "com.example.bridge", table: table)], [[], []],
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
    expectEqual(sourceHas(app("UI/NotchSettingsRows.swift"), "if showsEqualizerHere && RealAudioMeter.isSupported {"), true,
                "真实音浪: 设置行只在音浪贴这一侧、系统支持时出现")
    let tap = core("Local/ProcessAudioTap.swift")
    let leaks = ["write(to:", "FileManager", "AVAudioFile", "ExtAudioFile", "AudioFileCreate", "FileHandle", "FileIO."]
    expectEqual(leaks.filter { tap.contains($0) || meter.contains($0) }, [], "真实音浪: 读到的采样不写盘")
    expectEqual(sourceHas(tap, "desc.muteBehavior = .unmuted"), true, "真实音浪: tap 不静音源 App")
}
