// 由 scripts/gen-test-tracks.py 从 shared/test-tracks.json 生成,请勿手改。
// 改名单:改那份 JSON → 跑 `python3 scripts/gen-test-tracks.py`。CI 跑 `--check` 对账,手改这里会红。

extension ScrobbleHold {
    public static let testArtistPrefixes: [String] = [
        "Lyrimuse测试",
        "Lyrimuse Test",
    ]

    public static let testArtists: [String] = [
        "测试歌手",
        "測試歌手",
        "Test Artist",
        "Test Artist One",
        "Test Artist Two",
        "Test Artist Three",
        "歌手A-B",
    ]

    public static let testUntaggedTitles: [String] = [
        "ToneClick",
        "ToneClick.wav",
        "Click A",
        "Click A.wav",
        "Click B",
        "Click B.wav",
        "Click C",
        "Click C.wav",
        "NoTag",
        "NoTag.mp3",
        "TagDash",
        "TagDash.mp3",
        "TagCtrl",
        "TagCtrl.mp3",
        "MyGo Click A",
        "MyGo Click A.wav",
        "MyGo Click B",
        "MyGo Click B.wav",
        "MyGo Click C",
        "MyGo Click C.wav",
        "MyGo Click M",
        "MyGo Click M.mp3",
        "MyGo Click N",
        "MyGo Click N.mp3",
        "Audirvana Click",
        "Audirvana Click.wav",
    ]
}
