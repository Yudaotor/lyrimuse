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
}
