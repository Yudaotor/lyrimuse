import CoreMedia
import Foundation
import LyrimuseCore
import QuartzCore
import VideoToolbox

/// 出帧线程交给主线程分发的一帧:已经包好的 WebSocket 帧(视频关键帧前面连着一份解码配置),和它是不是关键帧。
/// 逐帧 JPEG 每帧都是关键帧。
struct WebLyricsScreenFrame: Sendable {
    let data: Data
    let isKeyFrame: Bool
}

/// 副屏视频流的 H.264 编码器(见 `WebLyricsVideo`)。硬件编码、低延迟码率控制、不重排帧(没有 B 帧,解出来的顺序就是
/// 放的顺序),约 2 秒一个关键帧;新网页连上或某个网页掉了帧时要关键帧,最多每秒插一个(不到一秒的请求记着,到点补出),
/// 免得关键帧把慢网堵得更死。
/// 码率跟节拍器的质量档走:原质量 4Mbps,降一档 2Mbps。在出帧线程上建、设码率,编码在 GPU 完成回调的线程上。
final class WebLyricsVideoEncoder: @unchecked Sendable {
    static let fullBitRate = 4_000_000
    static let reducedBitRate = 2_000_000
    static let keyFrameInterval: TimeInterval = 2
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
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: Self.keyFrameInterval as CFNumber)
        session = made
        setQuality(WebLyricsFramePacer.fullQuality)
        VTCompressionSessionPrepareToEncodeFrames(made)
    }

    /// 节拍器的质量档换成码率。
    func setQuality(_ quality: Double) {
        let target = quality >= WebLyricsFramePacer.fullQuality ? Self.fullBitRate : Self.reducedBitRate
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
            return WebLyricsScreenFrame(data: WebSocketFrame.encode(message, opcode: .binary), isKeyFrame: false)
        }
        guard let format = CMSampleBufferGetFormatDescription(sample), let config = decoderConfiguration(format) else { return nil }
        var data = WebSocketFrame.encode(WebLyricsVideo.message(.config, stamp: stamp, payload: config), opcode: .binary)
        data.append(WebSocketFrame.encode(WebLyricsVideo.message(.keyFrame, stamp: stamp, payload: payload), opcode: .binary))
        return WebLyricsScreenFrame(data: data, isKeyFrame: true)
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
