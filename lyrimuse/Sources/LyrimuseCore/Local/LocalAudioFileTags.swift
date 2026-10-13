import AudioToolbox
import Foundation

/// 本地音频文件里的标签(AudioToolbox 的信息字典:MP3 的 ID3v1 / ID3v2、M4A、AIFF、FLAC 等它认得的格式都在这一处)。
/// 字符串是 AudioToolbox 原样给的:老 MP3 按 GBK 存、它按 Latin-1 解出来的乱码不在这里还原,由调用方决定(`PlayerTitleSplit`)。
public struct LocalAudioFileTags: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    /// 秒;读不到为 nil。
    public var duration: Double?

    public init(title: String, artist: String, album: String, duration: Double?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    /// 读一个文件的标签;打不开或不是音频文件时为 nil。会读盘,别在主线程上调。
    public static func read(path: String) -> LocalAudioFileTags? {
        var file: AudioFileID?
        guard AudioFileOpenURL(URL(fileURLWithPath: path) as CFURL, .readPermission, 0, &file) == noErr, let file else {
            return nil
        }
        defer { AudioFileClose(file) }
        var dictSize = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        var dict: Unmanaged<CFDictionary>?
        let info = AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &dictSize, &dict) == noErr
            ? (dict?.takeRetainedValue() as? [String: Any] ?? [:]) : [:]
        var seconds: Float64 = 0
        var secondsSize = UInt32(MemoryLayout<Float64>.size)
        let hasDuration = AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &secondsSize, &seconds) == noErr
            && seconds > 0
        func text(_ key: String) -> String {
            ((info[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return LocalAudioFileTags(title: text(kAFInfoDictionary_Title), artist: text(kAFInfoDictionary_Artist),
                                  album: text(kAFInfoDictionary_Album), duration: hasDuration ? seconds : nil)
    }
}
