#!/usr/bin/env swift
//
// 录几秒系统混音、只算音量,判「扬声器此刻有没有在出声」。不存声音、不出网。
//
//   swift lyrimuse/scripts/audio-level.swift [秒数]     # 默认 2 秒
//
// 输出一行 `loud=<有声的块数>/<总块数> peak=<最大 RMS>`(每块约 20ms,RMS 超过 0.003 算有声);
// 录不了(没有屏幕录制权限、没有显示器)时退出码 2。play-experiment.sh 收尾用它核对歌真的停了:
// 播放器自己报的状态可能跟不上(QQ 音乐弹出付费会员窗时菜单和媒体指令都不接,系统那份还报暂停)。
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 2 : 2
let threshold = 0.003

final class Meter: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var loud = 0, total = 0
    private var peak = 0.0

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
        var sum = 0.0
        for i in 0..<count { sum += Double(samples[i]) * Double(samples[i]) }
        let rms = (sum / Double(count)).squareRoot()
        lock.lock()
        total += 1
        if rms > threshold { loud += 1 }
        peak = max(peak, rms)
        lock.unlock()
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

_ = NSApplication.shared
let meter = Meter()
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { exit(2) }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: meter)
        try stream.addStreamOutput(meter, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio-level"))
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try await stream.stopCapture()
        print(meter.report())
        exit(0)
    } catch {
        FileHandle.standardError.write("audio-level: \(error)\n".data(using: .utf8)!)
        exit(2)
    }
}
RunLoop.main.run()
