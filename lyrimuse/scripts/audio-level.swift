#!/usr/bin/env swift
//
// 录几秒声音、只算音量,判「扬声器此刻有没有在出声」,或逐块打出音量当出声真值。不存声音、不出网。
//
//   swift lyrimuse/scripts/audio-level.swift [秒数]                       # 默认 2 秒,录系统混音
//   swift lyrimuse/scripts/audio-level.swift [秒数] --app <bundle id>     # 只录这个 App 的声音
//   swift lyrimuse/scripts/audio-level.swift [秒数] --trace [--app …]     # 逐块打「墙钟秒 RMS」
//
// 默认输出一行 `loud=<有声的块数>/<总块数> peak=<最大 RMS>`(每块约 20ms,RMS 超过 0.003 算有声)。
// `--trace` 每 5ms 打一行 `<墙钟 Unix 秒> <RMS>`(行缓冲),开录时往 stderr 打一行 `capturing`;
// 配咔哒声文件找每一声跳起的那一行,拿它的墙钟对 Lyrimuse 写出的进度。`--app` 让用户同时放别的声音不串进来。
// 录不了(没有屏幕录制权限、没有显示器、锁屏、`--app` 那个 App 没开)时退出码 2。
// play-experiment.sh 收尾用默认那种核对歌真的停了:
// 播放器自己报的状态可能跟不上(QQ 音乐弹出付费会员窗时菜单和媒体指令都不接,系统那份还报暂停)。
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

var seconds = 2.0
var appBundleID: String?
var trace = false
var argIndex = 1
while argIndex < CommandLine.arguments.count {
    let arg = CommandLine.arguments[argIndex]
    switch arg {
    case "--app":
        argIndex += 1
        guard argIndex < CommandLine.arguments.count else {
            FileHandle.standardError.write("audio-level: --app 后面要跟 bundle id\n".data(using: .utf8)!)
            exit(64)
        }
        appBundleID = CommandLine.arguments[argIndex]
    case "--trace":
        trace = true
    default:
        guard let value = Double(arg), value > 0 else {
            FileHandle.standardError.write("audio-level: 认不出参数 \(arg)\n".data(using: .utf8)!)
            exit(64)
        }
        seconds = value
    }
    argIndex += 1
}
let threshold = 0.003
let traceChunk = 240

final class Meter: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var loud = 0, total = 0
    private var peak = 0.0
    private let trace: Bool

    init(trace: Bool) {
        self.trace = trace
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        var list = AudioBufferList()
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr,
            let data = list.mBuffers.mData else { return }
        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let samples = data.bindMemory(to: Float.self, capacity: count)
        if trace {
            printTrace(samples, count: count, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            return
        }
        let rms = rootMeanSquare(samples, from: 0, count: count)
        lock.lock()
        total += 1
        if rms > threshold { loud += 1 }
        peak = max(peak, rms)
        lock.unlock()
    }

    private func rootMeanSquare(_ samples: UnsafeMutablePointer<Float>, from start: Int, count: Int) -> Double {
        var sum = 0.0
        for i in start..<(start + count) { sum += Double(samples[i]) * Double(samples[i]) }
        return (sum / Double(count)).squareRoot()
    }

    // PTS 在主机时钟上,按「此刻墙钟 − (此刻主机时钟 − PTS)」换成墙钟。
    private func printTrace(_ samples: UnsafeMutablePointer<Float>, count: Int, pts: CMTime) {
        let hostNow = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let wallStart = Date().timeIntervalSince1970 - (hostNow - CMTimeGetSeconds(pts))
        var start = 0
        while start < count {
            let n = min(traceChunk, count - start)
            print(String(format: "%.4f %.5f", wallStart + Double(start) / 48000, rootMeanSquare(samples, from: start, count: n)))
            start += n
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("audio-level: stopped: \(error)\n".data(using: .utf8)!)
        exit(2)
    }

    func report() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(format: "loud=%d/%d peak=%.4f", loud, total, peak)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("audio-level: \(message)\n".data(using: .utf8)!)
    exit(2)
}

setvbuf(stdout, nil, _IOLBF, 0)
_ = NSApplication.shared
let meter = Meter(trace: trace)
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // 锁屏时一块显示器都拿不到。
        guard let display = content.displays.first else { fail("没有可录的显示器(锁屏时也是这样)") }
        let filter: SCContentFilter
        if let appBundleID {
            guard let app = content.applications.first(where: { $0.bundleIdentifier == appBundleID }) else {
                fail("\(appBundleID) 没在运行")
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: meter)
        try stream.addStreamOutput(meter, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio-level"))
        try await stream.startCapture()
        if trace { FileHandle.standardError.write("capturing\n".data(using: .utf8)!) }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try await stream.stopCapture()
        if !trace { print(meter.report()) }
        exit(0)
    } catch {
        fail("\(error)")
    }
}
RunLoop.main.run()
