import CoreMedia
import Foundation
import LyrimuseCore
import QuartzCore
import VideoToolbox

/// 出帧线程交给主线程分发的一帧:已经包好的 WebSocket 帧(视频关键帧前面连着一份解码配置)、是不是关键帧、
/// 画帧时刻(毫秒)、消息内容字节数(不含帧头,跟网页回报的收到字节数同一个数法)。逐帧 JPEG 每帧都是关键帧。
struct WebLyricsScreenFrame: Sendable {
    let data: Data
    let isKeyFrame: Bool
    let stamp: Double
    let payloadBytes: Int
}

/// 副屏视频流的 H.264 编码器(见 `WebLyricsVideo`)。硬件编码、低延迟码率控制、不重排帧(没有 B 帧,解出来的顺序就是
/// 放的顺序);新网页连上或某个网页掉了帧时要关键帧,最多每秒插一个(不到一秒的请求记着,到点补出),免得关键帧把慢网
/// 堵得更死。定期的关键帧只是保险,5 秒一个:窄路上关键帧是大头。
/// 码率按网页回报定(`WebLyricsRateControl`,主线程设)。别设 `DataRateLimits`:硬件编码器为守住它每帧编得慢几倍,
/// 两帧在途就供不上 60 帧。
/// 在出帧线程上建,编码在编码队列上。
final class WebLyricsVideoEncoder: @unchecked Sendable {
    static let keyFrameInterval: TimeInterval = 5
    static let minForcedKeyFrameGap: TimeInterval = 1

    private let session: VTCompressionSession
    private let lock = NSLock()
    // 以下由 `lock` 保护。
    private var bitRate = 0
    private var keyFrameWanted = true
    private var lastForcedKeyFrame: CFTimeInterval = -.infinity

    init?(width: Int, height: Int) {
        var made: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                   encoderSpecification: lowLatency, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        if made == nil {
            VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                       encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                       outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        }
        guard let made else { return nil }
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // 只参考上一帧,SPS 里的解码缓冲跟着声明成 1 帧:浏览器的 <video>(MediaSource)按这个帧数压着再出,默认的 9 帧
        // 在 Firefox 里要多留约 200ms 余量才不在关键帧那几下卡。见 19 章决策 36
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ReferenceBufferCount, value: 1 as CFNumber)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: Self.keyFrameInterval as CFNumber)
        session = made
        setBitRate(WebLyricsRateControl.maxBitRate)
        VTCompressionSessionPrepareToEncodeFrames(made)
    }

    func setBitRate(_ target: Int) {
        lock.lock()
        let changed = target != bitRate
        bitRate = target
        lock.unlock()
        guard changed else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: target as CFNumber)
    }

    /// 要一个关键帧:距上次插关键帧满 1 秒的那一帧编成关键帧。
    func requestKeyFrame() {
        lock.lock()
        keyFrameWanted = true
        lock.unlock()
    }

    /// 编一帧,`done` 在编码回调的线程上收到包好的消息(失败给 nil)。`stamp` 是画帧时刻(毫秒)。
    func encode(_ source: CVPixelBuffer, at time: CMTime, stamp: Double, done: @escaping (WebLyricsScreenFrame?) -> Void) {
        let now = CACurrentMediaTime()
        lock.lock()
        let force = keyFrameWanted && now - lastForcedKeyFrame >= Self.minForcedKeyFrameGap
        if force {
            keyFrameWanted = false
            lastForcedKeyFrame = now
        }
        lock.unlock()
        let properties = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: source, presentationTimeStamp: time, duration: .invalid, frameProperties: properties,
            infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample, let frame = Self.package(sample, stamp: stamp) else {
                done(nil)
                return
            }
            done(frame)
        }
        if status != noErr { done(nil) }
    }

    func invalidate() {
        VTCompressionSessionInvalidate(session)
    }

    private static func package(_ sample: CMSampleBuffer, stamp: Double) -> WebLyricsScreenFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { return nil }
        let payload = Data(bytes: pointer, count: length)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        guard isKey else {
            let message = WebLyricsVideo.message(.deltaFrame, stamp: stamp, payload: payload)
            return WebLyricsScreenFrame(data: WebSocketFrame.encode(message, opcode: .binary), isKeyFrame: false,
                                        stamp: stamp, payloadBytes: message.count)
        }
        guard let format = CMSampleBufferGetFormatDescription(sample), let config = decoderConfiguration(format) else { return nil }
        let configMessage = WebLyricsVideo.message(.config, stamp: stamp, payload: config)
        let keyMessage = WebLyricsVideo.message(.keyFrame, stamp: stamp, payload: payload)
        var data = WebSocketFrame.encode(configMessage, opcode: .binary)
        data.append(WebSocketFrame.encode(keyMessage, opcode: .binary))
        return WebLyricsScreenFrame(data: data, isKeyFrame: true, stamp: stamp,
                                    payloadBytes: configMessage.count + keyMessage.count)
    }

    /// 从格式描述里取 SPS、PPS 拼 avcC。
    private static func decoderConfiguration(_ format: CMFormatDescription) -> Data? {
        func parameterSet(_ index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let sps = parameterSet(0), let pps = parameterSet(1) else { return nil }
        return WebLyricsVideo.decoderConfiguration(sps: sps, pps: pps)
    }
}
