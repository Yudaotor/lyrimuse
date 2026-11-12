import Foundation
import LyrimuseCore

func runLyricsWritebackTests() {
    let file = NowPlayingLocalFile(player: "com.example.player", path: "/Users/a/Music/x.MP3")
    expectEqual(LyricsWriteback.unavailable(isNowPlaying: true, file: file, probeError: nil), nil,
                "写回: 正在放的本地 MP3(扩展名不分大小写)能写")
    expectEqual(LyricsWriteback.unavailable(isNowPlaying: false, file: file, probeError: nil), .notPlayingLocalFile,
                "写回: 不是正在放的那首不能写")
    expectEqual(LyricsWriteback.unavailable(isNowPlaying: true, file: nil, probeError: nil), .notPlayingLocalFile,
                "写回: 没在放本地文件不能写")
    expectEqual(LyricsWriteback.unavailable(isNowPlaying: true, file: NowPlayingLocalFile(player: "p", path: "/a/x.m4a"),
                                            probeError: nil), .unsupportedFormat, "写回: M4A 不在第一期")
    expectEqual(LyricsWriteback.unavailable(isNowPlaying: true, file: file, probeError: "unsupported_tag"),
                .engine("unsupported_tag"), "写回: 引擎查文件报的错(ID3v2.2 之类)灰掉菜单项")
    expectEqual(LyricsWriteback.reasonKey(.engine("unsupported_tag")), "这个文件的标签格式暂不支持写入",
                "写回: ID3v2.2 悬停说明是标签格式不支持")
    expectEqual(LyricsWriteback.wantsPlainText(player: PlaybackPlayer.appleMusic.bundleIdentifier), true,
                "写回: Apple Music 的曲目只写文字")
    expectEqual(LyricsWriteback.wantsPlainText(player: "com.reamp.reAMP"), false, "写回: 别的播放器写 LRC")

    // 跟引擎对拍:错误码、格式、Apple Music 规则都在引擎源码里,文案键都在 catalog 里。
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    func text(_ path: String) -> String {
        (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
    }
    let engine = text("lyrimuse-engine/lyricswriteback.go")
    let engineCodes = engine.split(separator: "\n").compactMap { line -> String? in
        guard line.contains("wbErr"), line.contains("= \""), let start = line.range(of: "= \"") else { return nil }
        let rest = line[start.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
    expectEqual(Set(engineCodes), Set(LyricsWriteback.engineErrorCodes), "写回: App 认的错误码跟引擎 lyricswriteback.go 一致")
    expectEqual(sourceHas(engine, "\"mp3\": id3WritebackLayout,") && sourceHas(engine, "\"flac\": flacWritebackLayout,")
                && LyricsWriteback.supportedExtensions == ["mp3", "flac"], true, "写回: 支持的格式两边一致")
    expectEqual(sourceHas(engine, "return bundleID == appleMusicBundleID"), true,
                "写回: 只写文字的判据两边一致(引擎 writebackWantsPlainText)")
    let catalog = (try? Data(contentsOf: root.appendingPathComponent("lyrimuse/Localization/Localizable.xcstrings"))) ?? Data()
    var missing: [String] = []
    let keys = LyricsWriteback.engineErrorCodes.map(LyricsWriteback.errorKey(code:))
        + [LyricsWriteback.reasonKey(.notPlayingLocalFile), LyricsWriteback.reasonKey(.unsupportedFormat), LyricsWriteback.errorKey(code: "?")]
    for key in Set(keys) where catalog.range(of: Data("\"\(key)\" : {".utf8)) == nil {
        missing.append(key)
    }
    expectEqual(missing, [], "写回: 每条原因文案都在 Localizable.xcstrings 里")
}
