import AppKit
import Foundation
import LyrimuseCore

/// 网页歌词(19 章):HTTP 解析 / WebSocket 握手与分帧 / 谁能打开 / 副屏尺寸 / OBS 消息 / 离屏拼图层树,外加几条接线契约。
@MainActor
func runWebLyricsTests() {
    // ---- HTTP 请求头 ----
    do {
        let raw = Data("GET /ws?k=abc&w=390&h=844&dpr=3&x=%E4%B8%AD HTTP/1.1\r\nHost: 192.168.1.5:3939\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\nrest".utf8)
        guard case let .request(request, consumed) = WebLyricsHTTP.parse(raw) else {
            expectEqual(false, true, "网页歌词: 完整请求头能解析")
            return
        }
        expectEqual(request.method, "GET", "网页歌词: 方法")
        expectEqual(request.path, "/ws", "网页歌词: 路径不含查询串")
        expectEqual(request.query["k"], "abc", "网页歌词: 查询串")
        expectEqual(request.query["x"], "中", "网页歌词: 查询串去掉百分号编码")
        expectEqual(request.headers["host"], "192.168.1.5:3939", "网页歌词: 头名转小写")
        expectEqual(request.isWebSocketUpgrade, true, "网页歌词: 认出 WebSocket 升级(Connection 里带别的值也认)")
        expectEqual(consumed, raw.count - 4, "网页歌词: 消耗到空行为止,后面的字节留着")
        expectEqual(WebLyricsHTTP.parse(Data("GET / HTTP/1.1\r\nHost: x".utf8)), .needMore, "网页歌词: 没收到空行时等更多")
        expectEqual(WebLyricsHTTP.parse(Data("NOT A REQUEST\r\n\r\n".utf8)), .invalid, "网页歌词: 请求行不对")
        expectEqual(WebLyricsHTTP.parse(Data("GET http://evil/ HTTP/1.1\r\n\r\n".utf8)), .invalid, "网页歌词: 只认以 / 开头的路径")
        expectEqual(WebLyricsHTTP.parse(Data(repeating: 0x41, count: WebLyricsHTTP.maxHeaderBytes + 1)), .invalid,
                    "网页歌词: 请求头超长当坏请求")
        let plain = Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        if case let .request(r, _) = WebLyricsHTTP.parse(plain) {
            expectEqual(r.isWebSocketUpgrade, false, "网页歌词: 普通请求不是升级")
        }
    }

    // ---- WebSocket ----
    do {
        // RFC 6455 §1.3 的示例。
        expectEqual(WebLyricsHTTP.webSocketAccept(key: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
                    "网页歌词: Sec-WebSocket-Accept 跟 RFC 示例一致")
        let small = WebSocketFrame.encode(Data(repeating: 1, count: 5), opcode: .text)
        expectEqual(Array(small.prefix(2)), [0x81, 5], "网页歌词: 短帧两字节头、不加掩码")
        let medium = WebSocketFrame.encode(Data(repeating: 1, count: 300), opcode: .binary)
        expectEqual(Array(medium.prefix(4)), [0x82, 126, 0x01, 0x2C], "网页歌词: 126 档长度用两字节")
        let large = WebSocketFrame.encode(Data(repeating: 1, count: 70_000), opcode: .binary)
        expectEqual(Array(large.prefix(10)), [0x82, 127, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70], "网页歌词: 大帧长度用八字节")
        expectEqual(large.count, 70_010, "网页歌词: 大帧总长")

        func clientFrame(_ payload: [UInt8], opcode: UInt8, masked: Bool = true) -> Data {
            var frame: [UInt8] = [0x80 | opcode, (masked ? 0x80 : 0) | UInt8(payload.count)]
            let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
            if masked { frame += mask }
            frame += payload.enumerated().map { masked ? $0.element ^ mask[$0.offset % 4] : $0.element }
            return Data(frame)
        }
        let ping = clientFrame(Array("hi".utf8), opcode: 0x9)
        expectEqual(WebSocketFrame.decode(ping), .frame(.init(opcode: 0x9, payload: Data("hi".utf8), consumed: ping.count)),
                    "网页歌词: 解开客户端的掩码")
        expectEqual(WebSocketFrame.decode(ping.prefix(4)), .needMore, "网页歌词: 帧没收全时等更多")
        expectEqual(WebSocketFrame.decode(clientFrame([1, 2], opcode: 0x1, masked: false)), .invalid, "网页歌词: 客户端帧不带掩码算坏连接")
        let huge = Data([0x82, 0xFF, 0, 0, 0, 0, 0, 0x10, 0, 0])
        expectEqual(WebSocketFrame.decode(huge), .invalid, "网页歌词: 客户端大帧算坏连接")
    }

    // ---- 设置卡「其他设备」那一行 ----
    do {
        let link = WebLyricsLinks.url(host: "DJ-Mac.local", port: 3940, token: "abc")
        expectEqual(WebLyricsLANStatus.make(enabled: false, allowLAN: true, link: link, remoteViewers: 2), .off,
                    "网页歌词: 开关关着时不列地址")
        expectEqual(WebLyricsLANStatus.make(enabled: true, allowLAN: false, link: link, remoteViewers: 0), .lanOff,
                    "网页歌词: 局域网访问关着")
        expectEqual(WebLyricsLANStatus.make(enabled: true, allowLAN: true, link: nil, remoteViewers: 0), .noNetwork,
                    "网页歌词: 没有局域网")
        expectEqual(WebLyricsLANStatus.make(enabled: true, allowLAN: true, link: link, remoteViewers: 0),
                    .reachable(address: "DJ-Mac.local:3940", remoteViewers: 0), "网页歌词: 只写名字和端口,不带密钥")
        expectEqual(WebLyricsLANStatus.make(enabled: true, allowLAN: true, link: link, remoteViewers: 2),
                    .reachable(address: "DJ-Mac.local:3940", remoteViewers: 2), "网页歌词: 带上别的设备连进来的页面数")
    }

    // ---- 谁能打开 ----
    do {
        let token = WebLyricsAccess.makeToken()
        expectEqual(token.count, 32, "网页歌词: 密钥 128 位十六进制")
        expectNotEqual(token, WebLyricsAccess.makeToken(), "网页歌词: 每次生成的密钥不同")
        expectEqual(WebLyricsAccess.permits(remoteIsLoopback: true, lanEnabled: false, token: token, query: [:]), true,
                    "网页歌词: 本机回环不要密钥")
        expectEqual(WebLyricsAccess.permits(remoteIsLoopback: false, lanEnabled: false, token: token, query: ["k": token]), false,
                    "网页歌词: 局域网没开时别的设备带对的密钥也不行")
        expectEqual(WebLyricsAccess.permits(remoteIsLoopback: false, lanEnabled: true, token: token, query: ["k": "nope"]), false,
                    "网页歌词: 密钥不对")
        expectEqual(WebLyricsAccess.permits(remoteIsLoopback: false, lanEnabled: true, token: token, query: [:]), false,
                    "网页歌词: 没带密钥")
        expectEqual(WebLyricsAccess.permits(remoteIsLoopback: false, lanEnabled: true, token: token, query: ["k": token]), true,
                    "网页歌词: 局域网开着、密钥对")
        expectEqual(WebLyricsAccess.permits(remoteIsLoopback: false, lanEnabled: true, token: "", query: ["k": ""]), false,
                    "网页歌词: 空密钥一律不认")

        let names: Set<String> = ["DJ-Mac.local"]
        let allowed = ["localhost", "localhost:3939", "127.0.0.1:3939", "[::1]:3939", "192.168.31.24", "dj-mac.local:3939", "DJ-MAC.LOCAL"]
        for host in allowed {
            expectEqual(WebLyricsAccess.hostAllowed(host, localNames: names), true, "网页歌词: Host \(host) 放行")
        }
        let denied: [String?] = [nil, "", "evil.example", "evil.example:3939", "localhost:abc", "256.1.1.1", "1.2.3", "[::1", "other.local"]
        for host in denied {
            expectEqual(WebLyricsAccess.hostAllowed(host, localNames: names), false, "网页歌词: Host \(host ?? "nil") 挡住")
        }
    }

    // ---- 副屏尺寸 ----
    do {
        let phone = WebLyricsViewport(query: ["w": "390", "h": "844", "dpr": "3"])
        expectEqual([phone.width, phone.height, phone.pixelWidth, phone.pixelHeight], [390, 844, 1170, 2532], "网页歌词: 手机竖屏原样")
        expectEqual(phone.scale, 3, "网页歌词: 手机 3x 原样")
        expectEqual(phone.showsPlayerPane, false, "网页歌词: 窄于 640 不摆左栏(同歌词窗口)")
        let tablet = WebLyricsViewport(query: ["w": "1180", "h": "820", "dpr": "2"])
        expectEqual(tablet.showsPlayerPane, true, "网页歌词: 平板横屏摆左栏")
        func arrangement(_ w: Int, _ h: Int) -> WebLyricsViewport.Arrangement { WebLyricsViewport(width: w, height: h, scale: 2).arrangement }
        expectEqual([arrangement(1180, 820), arrangement(1512, 900), arrangement(844, 390)], [.columns, .columns, .columns],
                    "网页歌词: 够宽又横着的照歌词窗口左右两栏(手机横放也是)")
        expectEqual([arrangement(820, 1180), arrangement(744, 1133), arrangement(1024, 1366)], [.stacked, .stacked, .stacked],
                    "网页歌词: 够宽但竖着(平板竖放)播放器在上、歌词在下")
        expectEqual([arrangement(390, 844), arrangement(430, 932), arrangement(600, 400)], [.compact, .compact, .compact],
                    "网页歌词: 窄于 640 是手机那种排法(顶上一行歌名、底部播放条)")
        expectEqual(arrangement(640, 640), .columns, "网页歌词: 正方形按横着算(高大于宽才算竖)")
        let laptop = WebLyricsViewport(query: ["w": "1512", "h": "900", "dpr": "2"])
        expectEqual([laptop.pixelWidth, laptop.pixelHeight], [3024, 1800], "网页歌词: 笔记本全屏浏览器照样 2x")
        let big = WebLyricsViewport(width: 2560, height: 1440, scale: 3)
        expectEqual(big.scale > 1.3 && big.scale < 1.4, true, "网页歌词: 像素超上限时按比例压倍数,不整档降到 1x")
        expectEqual(big.pixelWidth * big.pixelHeight <= WebLyricsViewport.maxPixels, true, "网页歌词: 压倍后像素在上限内")
        expectEqual(big.pixelWidth % 2 == 0 && big.pixelHeight % 2 == 0, true, "网页歌词: 像素宽高取偶数")
        let tiny = WebLyricsViewport(width: 10, height: 99_999, scale: 9)
        expectEqual([tiny.width, tiny.height], [WebLyricsViewport.pointRange.lowerBound, WebLyricsViewport.pointRange.upperBound],
                    "网页歌词: 宽高夹进范围")
        expectEqual(tiny.scale >= 1, true, "网页歌词: 倍数至少 1")
        let fallback = WebLyricsViewport(query: ["w": "abc", "dpr": "1.5"])
        expectEqual([fallback.width, fallback.height, fallback.pixelWidth], [1180, 820, 1770], "网页歌词: 认不出的取默认,小数倍数原样用")
        let junk = WebLyricsViewport(query: ["dpr": "nan"])
        expectEqual(junk.scale, 2, "网页歌词: 倍数认不出按 2x")
    }

    // ---- 副屏点按 ----
    do {
        expectEqual(WebLyricsPointer.parse(Data(#"{"ptr":["d",0.25,0.75]}"#.utf8)),
                    WebLyricsPointer(phase: .down, point: CGPoint(x: 0.25, y: 0.75)), "网页歌词: 按下位置原样读出")
        expectEqual(WebLyricsPointer.parse(Data(#"{"ptr":["m",1.2,-0.1]}"#.utf8)),
                    WebLyricsPointer(phase: .move, point: CGPoint(x: 1, y: 0)), "网页歌词: 拖出画面的位置夹回 0…1")
        expectEqual(WebLyricsPointer.parse(Data(#"{"ptr":["u",3,0.5]}"#.utf8)), nil, "网页歌词: 离画面太远不认")
        expectEqual(WebLyricsPointer.parse(Data(#"{"ptr":["x",0.5,0.5]}"#.utf8)), nil, "网页歌词: 不认识的阶段不认")
        expectEqual(WebLyricsPointer.parse(Data(#"{"ptr":["d",0.5]}"#.utf8)), nil, "网页歌词: 缺一维不认")
        expectEqual(WebLyricsPointer.parse(Data("ptr".utf8)), nil, "网页歌词: 不是 JSON 不认")
        expectEqual(WebLyricsPointer.parse(Data(#"{"ptr":["c",0,1]}"#.utf8))?.phase, .cancel, "网页歌词: 取消")
        expectEqual(WebLyricsWheel.parse(Data(#"{"whl":[0.5,0.25,0.1]}"#.utf8)),
                    WebLyricsWheel(point: CGPoint(x: 0.5, y: 0.25), dy: 0.1), "网页歌词: 滚轮位置和滚动量原样读出")
        expectEqual(WebLyricsWheel.parse(Data(#"{"whl":[0.5,0.5,9]}"#.utf8))?.dy, 2, "网页歌词: 一次滚动最多算两屏")
        expectEqual(WebLyricsWheel.parse(Data(#"{"whl":[1.5,0.5,0.1]}"#.utf8)), nil, "网页歌词: 滚轮在画面外不认")
        expectEqual(WebLyricsPointer.parse(Data(#"{"whl":[0.5,0.5,0.1]}"#.utf8)), nil, "网页歌词: 滚轮消息不当指针事件")
        expectEqual(WebLyricsVisibility.parse(Data(#"{"vis":0}"#.utf8)), false, "网页歌词: 副屏报不可见")
        expectEqual(WebLyricsVisibility.parse(Data(#"{"vis":1}"#.utf8)), true, "网页歌词: 副屏报看得见")
        expectEqual(WebLyricsVisibility.parse(Data(#"{"vis":0.5}"#.utf8)), nil, "网页歌词: 可见性只认 0 / 1")
        expectEqual(WebLyricsVisibility.parse(Data(#"{"ptr":["d",0.5,0.5]}"#.utf8)), nil, "网页歌词: 指针事件不当可见性")
        expectEqual(WebLyricsPointer.permits(remoteIsLoopback: true, lanControlEnabled: false), true, "网页歌词: 本机副屏一律能点")
        expectEqual(WebLyricsPointer.permits(remoteIsLoopback: false, lanControlEnabled: false), false,
                    "网页歌词: 别的设备默认不能控制播放")
        expectEqual(WebLyricsPointer.permits(remoteIsLoopback: false, lanControlEnabled: true), true, "网页歌词: 开了控制开关别的设备能点")

        // 平板 1180 宽:封面边长 0.279W ≈ 329
        let layout = WebLyricsControlsLayout(width: 329, rowTop: 500, rowHeight: 32, skipGlyphWidth: 24)
        let cells = layout.cells
        expectEqual(cells[.shuffle]?.minX, 0, "网页歌词: 随机贴左缘")
        expectEqual(cells[.repeatMode]?.maxX, 329, "网页歌词: 循环贴右缘")
        let play = cells[.playPause] ?? .zero
        expectEqual(abs(play.midX - 329 / 2) < 0.01, true, "网页歌词: 播放键居中")
        expectEqual([layout.modeFontSize, layout.skipFontSize, layout.playFontSize].map { ($0 * 100).rounded() / 100 },
                    [14.15, 19.74, 25.99], "网页歌词: 控制键字号照歌词窗口的比例")
        expectEqual(layout.button(at: CGPoint(x: play.midX, y: 516)), .playPause, "网页歌词: 点播放键")
        expectEqual(layout.button(at: CGPoint(x: (cells[.next] ?? .zero).midX, y: 495)), .next,
                    "网页歌词: 点在键上方一点也算(命中区扩到 44)")
        expectEqual(layout.button(at: CGPoint(x: 2, y: 516)), .shuffle, "网页歌词: 点随机")
        expectEqual(layout.button(at: CGPoint(x: play.midX, y: 600)), nil, "网页歌词: 控制排以外不算")
        let gapX = ((cells[.previous] ?? .zero).maxX + play.minX) / 2
        let between = layout.button(at: CGPoint(x: gapX, y: 516))
        expectEqual(between == .previous || between == .playPause, true, "网页歌词: 两键之间只归一颗")
    }

    // ---- 端口与链接 ----
    do {
        expectEqual(WebLyricsPort.parse(" 8080 "), 8080, "网页歌词: 端口输入去掉空格")
        expectEqual(WebLyricsPort.parse("80"), nil, "网页歌词: 1024 以下的端口不收")
        expectEqual(WebLyricsPort.parse("65536"), nil, "网页歌词: 超出 65535 不收")
        expectEqual(WebLyricsPort.parse("abc"), nil, "网页歌词: 不是数字不收")
        expectEqual(WebLyricsPort.clamped(70_000), WebLyricsPort.standard, "网页歌词: 存坏了的端口按默认")
        expectEqual(WebLyricsLinks.url(host: "localhost", port: 3939)?.absoluteString, "http://localhost:3939/", "网页歌词: 本机链接不带密钥")
        expectEqual(WebLyricsLinks.url(host: "localhost", port: 3940, preview: true)?.absoluteString,
                    "http://localhost:3940/?preview=1", "网页歌词: OBS 预览链接")
        expectEqual(WebLyricsLinks.url(host: "Studio-Mac.local", port: 3940, token: "ab12")?.absoluteString,
                    "http://Studio-Mac.local:3940/?k=ab12", "网页歌词: 别的电脑上 OBS 用的链接带密钥")
        expectEqual(WebLyricsPort.clamped(80, fallback: WebLyricsPort.obsStandard), WebLyricsPort.obsStandard,
                    "网页歌词: OBS 端口存坏了按 OBS 的默认")
        expectEqual(WebLyricsPort.standard == WebLyricsPort.obsStandard, false, "网页歌词: 网页、OBS 默认端口不同")
        expectEqual(WebLyricsAccess.hostAllowed("studio-mac.local:3939", localNames: ["Studio-Mac.local"]), true,
                    "网页歌词: .local 名字不分大小写")
    }

    // ---- OBS 消息 ----
    do {
        expectEqual(WebLyricsObsPayload.obsTimelineMs(timelineMs: 10_000, bundleID: "com.apple.Music", playerOffsets: [:], globalOffsetMs: 180),
                    9_820, "网页歌词: OBS 扣掉「全部播放器」那档(耳机延迟)")
        expectEqual(WebLyricsObsPayload.obsTimelineMs(timelineMs: 10_000, bundleID: "com.google.Chrome",
                                                      playerOffsets: ["com.google.Chrome": 400], globalOffsetMs: 180),
                    10_000, "网页歌词: 这个播放器单独配过偏移时照常算")
        expectEqual(WebLyricsObsPayload.obsTimelineMs(timelineMs: 10_000, bundleID: nil, playerOffsets: ["x": 1], globalOffsetMs: 180),
                    9_820, "网页歌词: 不知道是哪个播放器时按「全部」那档扣")
        expectEqual(WebLyricsObsPayload.cssColor(red: 1, green: 0.5, blue: 0, alpha: 0.35), "rgba(255,128,0,0.35)", "网页歌词: CSS 颜色")
        expectEqual(WebLyricsObsPayload.cssColor(red: 2, green: -1, blue: 0, alpha: 3), "rgba(255,0,0,1.0)", "网页歌词: CSS 颜色夹值")
        expectEqual(OverlayFontWeight.allCases.map(WebLyricsObsPayload.cssWeight), [300, 400, 500, 600, 700, 800], "网页歌词: 字重映射")
        expectEqual(WebLyricsObsPayload.cssWeights(.semibold), [600, 400, 300, 400], "网页歌词: 读音 / 译文 / 下一句的字重照悬浮歌词的档位差")
        let styleJSON = WebLyricsObsPayload.style(.init(
            fontFamily: "", fontSize: 31, weights: [600, 400, 300, 400], sung: "rgba(0,0,0,1.0)", unsung: "rgba(0,0,0,0.55)",
            stroke: nil, card: nil, showRomanization: true, showTranslation: false, showNextLine: true, karaoke: true,
            alignment: .leading, overflow: .scroll, spacing: .init(romanization: 4, translation: 6, nextLine: 99),
            width: 640, hideWhenPaused: true, lineChangeAnimation: true, duetStageInset: 76, duetCenterInset: 84))
        let styleObject = (try? JSONSerialization.jsonObject(with: Data(styleJSON.utf8))) as? [String: Any]
        expectEqual(styleObject?["next"] as? Bool, true, "网页歌词: style 带下一句开关")
        expectEqual(styleObject?["align"] as? String, "leading", "网页歌词: style 带对齐方式")
        expectEqual(styleObject?["overflow"] as? String, "scroll", "网页歌词: style 带换行或滚动")
        expectEqual(styleObject?["width"] as? Double, 640, "网页歌词: style 带悬浮歌词宽度")
        expectEqual(styleObject?["hidePaused"] as? Bool, true, "网页歌词: style 带暂停时隐藏")
        expectEqual(styleObject?["anim"] as? Bool, true, "网页歌词: style 带换句动画")
        let duet = WebLyricsObsPayload.duetInsets(overlayWidth: 640, fontSize: 31)
        expectEqual(duet.stage, Double(OverlayCardGeometry.duetStageInset(availableWidth: 600, fontSize: 31)),
                    "网页歌词: 对唱舞台缩进同悬浮歌词(可用宽度 = 宽度 − 40)")
        expectEqual(duet.center, Double(LyricDuetLayout.insets(for: .leading, availableWidth: 600, fontSize: 31).trailing),
                    "网页歌词: 合唱两侧留白同悬浮歌词")
        expectEqual(styleObject?["spacing"] as? [Double], [4, 6, OverlayRowSpacing.range.upperBound], "网页歌词: style 行距夹回范围")

        let withWords = LyricsSyncEngine()
        _ = withWords.load(lyrics: "[00:01.00]あい\n[00:05.00]うえ", lyricsTr: "[00:01.00]啊\n[00:05.00]呜", lyricsRoma: "",
                           lyricsYRC: "[1000,800](1000,400,0)あ(1400,400,0)い\n[5000,800](5000,400,0)う(5400,400,0)え")
        let json = WebLyricsObsPayload.track(id: "t", lines: withWords.allLines(idPrefix: "t"), gaps: withWords.gapMarkers())
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let encoded = object?["lines"] as? [[String: Any]] ?? []
        expectEqual(object?["type"] as? String, "track", "网页歌词: track 消息类型")
        expectEqual(encoded.count, 2, "网页歌词: 行数")
        expectEqual(encoded.first?["t"] as? Int, 1_000, "网页歌词: 行起点")
        expectEqual(encoded.first?["text"] as? String, "あい", "网页歌词: 整行文字")
        expectEqual((encoded.first?["w"] as? [[Any]])?.count, 2, "网页歌词: 逐字每个字一项")
        expectEqual((encoded.first?["w"] as? [[Any]])?.first?.count, 3, "网页歌词: 逐字是 [起点, 时长, 字]")
        expectEqual(encoded.first?["tr"] as? String, "啊", "网页歌词: 译文")
        expectEqual(encoded.first?["s"] == nil, true, "网页歌词: 没有对唱声部的行省略 s")
        let groups = encoded.first?["g"] as? [[Any]]
        expectEqual(groups?.compactMap { $0.first as? Int }.reduce(0, +), (encoded.first?["w"] as? [[Any]])?.count,
                    "网页歌词: 日文逐词读音按顺序覆盖整行的字")
        let segmented = withWords.surfaceWindowLines(.overlay, idPrefix: "t")
        expectEqual(segmented.map(\.timeMs), [1_000, 5_000], "网页歌词: 悬浮歌词断好的段带开始时刻(没开拆分时一行一段)")
        expectEqual(object?["gaps"] is [Any], true, "网页歌词: 带间奏列表")
        let lineLevel = LyricsSyncEngine()
        _ = lineLevel.load(lyrics: "[00:01.00]整行歌词", lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        let plainObject = (try? JSONSerialization.jsonObject(with: Data(
            WebLyricsObsPayload.track(id: "p", lines: lineLevel.allLines(idPrefix: "p"), gaps: []).utf8))) as? [String: Any]
        let plainLines = plainObject?["lines"] as? [[String: Any]] ?? []
        expectEqual(plainLines.first?["text"] as? String, "整行歌词", "网页歌词: 整行歌词的文字")
        expectEqual(plainLines.first?["w"] == nil, true, "网页歌词: 没有逐字时间的行省略 w")
        let pos = WebLyricsObsPayload.position(timelineMs: 1_234, rate: 1, state: .paused)
        expectEqual(pos, #"{"pos":1234,"rate":1,"state":"paused","type":"pos"}"#, "网页歌词: pos 消息")
    }

    // ---- 离屏拼图层树 ----
    do {
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        root.wantsLayer = true
        let child = Flipped(frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        child.wantsLayer = true
        child.bounds.origin = CGPoint(x: 0, y: 30)
        let grandchild = NSView(frame: CGRect(x: 5, y: 6, width: 20, height: 10))
        root.addSubview(child)
        child.addSubview(grandchild)
        expectEqual(root.layer?.sublayers?.contains { $0 === child.layer } ?? false, false,
                    "网页歌词: 不挂窗口时 AppKit 确实不把子视图图层挂上去(拼树的前提)")
        DetachedLayerTree.assemble(root)
        expectEqual(child.layer?.superlayer === root.layer, true, "网页歌词: 子视图图层挂到父图层下")
        expectEqual(grandchild.layer?.superlayer === child.layer, true, "网页歌词: 孙视图没开图层也补上并挂好")
        expectEqual(child.layer?.position, CGPoint(x: 10, y: 20), "网页歌词: 位置取视图 frame 原点")
        expectEqual(child.layer?.bounds.origin, CGPoint(x: 0, y: 30), "网页歌词: 滚动偏移(bounds.origin)同步到图层")
        expectEqual(child.layer?.isGeometryFlipped, true, "网页歌词: 翻转视图在不翻转的父视图下翻转坐标")
        expectEqual(grandchild.layer?.isGeometryFlipped, true, "网页歌词: 不翻转的视图在翻转的父视图下也翻一次")
        grandchild.removeFromSuperview()
        DetachedLayerTree.assemble(root)
        expectEqual(child.layer?.sublayers?.contains { $0 === grandchild.layer } ?? false, false,
                    "网页歌词: 拿掉的子视图,它的图层一并摘掉")
        let plain = CALayer()
        child.layer?.addSublayer(plain)
        DetachedLayerTree.assemble(root)
        expectEqual(plain.superlayer === child.layer, true, "网页歌词: 组件自己加的普通图层不动")
    }

    // ---- 接线契约 ----
    do {
        let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func app(_ path: String) -> String {
            let text = (try? String(contentsOf: appDir.appendingPathComponent(path), encoding: .utf8)) ?? ""
            expectEqual(text.isEmpty, false, "网页歌词: 读到了 \(path)")
            return text
        }
        let server = app("WebLyrics/WebLyricsServer.swift")
        expectEqual(sourceBytes(server, contain: "params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)"), true,
                    "网页歌词: 局域网没开时只绑 127.0.0.1")
        expectEqual(sourceBytes(server, contain: "WebLyricsAccess.permits(remoteIsLoopback: connection.isLoopback"), true,
                    "网页歌词: 每个请求都过访问控制")
        expectEqual(sourceBytes(server, contain: "WebLyricsAccess.hostAllowed(request.headers[\"host\"]"), true,
                    "网页歌词: 每个请求都核 Host 头")
        expectEqual(sourceBytes(app("AppDelegate.swift"), contain: "WebLyricsServer.startAll()"), true, "网页歌词: 启动时接上两个服务")
        let pages = app("WebLyrics/WebLyricsPages.swift")
        expectEqual(sourceBytes(pages, contain: "get('preview') === '1') document.body.classList.add('preview');"), true,
                    "网页歌词: OBS 页带 preview=1 时铺棋盘格底")
        expectEqual(sourceBytes(server, contain: "token.dropFirst().removeDuplicates()"), true,
                    "网页歌词: 换了密钥就断开别的设备")
        expectEqual(sourceBytes(server, contain: "Publishers.CombineLatest4(enabled, lan, port, other)"), true,
                    "网页歌词: 改端口重新监听,另一个的端口变了也重新核")
        expectEqual(sourceBytes(server, contain: "if Self.otherPort(of: channel) == port {"), true,
                    "网页歌词: 两个服务端口相同时都不监听")
        expectEqual(sourceBytes(server, contain: "let page = channel == .obs ? WebLyricsPages.obsPage() : WebLyricsPages.screenPage()"), true,
                    "网页歌词: 网页、OBS 各占一个端口,根路径就是各自的页面")
        expectEqual(sourceBytes(pages, contain: "--sung:var(--sung-reading)"), true,
                    "网页歌词: 逐词读音的已唱色走单独的变量(写成引用自己的 --sung 会整段失效、读音看不见)")
        expectEqual(sourceBytes(pages, contain: "setInterval(() => { if (performance.now() - lastTick > 50) tick(); }, 33);"), true,
                    "网页歌词: OBS 页 rAF 停了由定时器接着刷(OBS 失焦时 rAF 会停)")
        expectEqual(sourceBytes(pages, contain: "<feGaussianBlur id=\"lmBlur\" in=\"SourceAlpha\""), true,
                    "网页歌词: OBS 页描边照悬浮歌词用模糊剪影")
        expectEqual(sourceBytes(pages, contain: "html += '<div class=\"row dots\"><i></i><i></i><i></i></div>';"), true,
                    "网页歌词: OBS 页前奏 / 间奏画「•••」")
        expectEqual(sourceBytes(pages, contain: "https://") || sourceBytes(pages, contain: "http://"), false,
                    "网页歌词: 网页不连外部地址")
        let gapDots = app("UI/LyricsGapDots.swift")
        expectEqual(sourceBytes(gapDots, contain: "guard c.running, window != nil || rendersDetached else { return }"), true,
                    "网页歌词: 间奏点离屏时也装动画")
        let pagesSource = app("WebLyrics/WebLyricsPages.swift")
        expectEqual(sourceBytes(pagesSource, contain: "ws.send(JSON.stringify({ ptr: [phase,"), true, "网页歌词: 副屏把按下、拖动、抬起发回 App")
        expectEqual(sourceBytes(pagesSource, contain: "if (downLink && linkAt(u, v) === downLink) window.open(downLink, '_blank', 'noopener');"),
                    true, "网页歌词: 平台页在手指抬起那一刻由网页自己打开(等 App 回话再开会被浏览器拦掉)")
        expectEqual(sourceBytes(app("UI/LyricsWindowView.swift"), contain: "@StateObject private var moreMenu = LyricsMoreMenuModel()"),
                    true, "网页歌词: 歌词窗口「…」菜单的直接动作跟副屏共用 LyricsMoreMenuModel")
        expectEqual(sourceBytes(pagesSource, contain: "touch-action: none;"), true, "网页歌词: 副屏画布自己接拖动,浏览器不拿去滚页面、缩放")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsServer.swift"),
                                contain: "if case .screen = role { server?.screens.message(self, payload: frame.payload) }"), true,
                    "网页歌词: 只有副屏连接的文本帧当点按 / 可见性")
        expectEqual(sourceBytes(pagesSource, contain: "document.addEventListener('visibilitychange', sendVisibility);"), true,
                    "网页歌词: 副屏网页可见性一变就报给 App")
        expectEqual(sourceBytes(pagesSource, contain: "socket.onopen = () => { retry = 1000; sendVisibility(); };"), true,
                    "网页歌词: 副屏网页连上时先报一次可见性(后台标签页重连上来也算数)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"),
                                contain: "let active = viewersVisible && (playback.isPlayingNow || now < fastUntil)"), true,
                    "网页歌词: 这一尺寸的网页全看不见时按暂停那一档出帧")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"),
                                contain: "lanControlEnabled: AppSettings.shared.webLyricsAllowLANControl"), true,
                    "网页歌词: 点按过控制开关")
        let screenSource = app("WebLyrics/WebLyricsScreen.swift")
        expectEqual(sourceBytes(screenSource, contain: "timer = DispatchSource.makeTimerSource(queue: queue)"), true,
                    "网页歌词: 副屏出帧在自己的队列上按节拍画,不挂在主线程定时器上")
        expectEqual(sourceBytes(screenSource, contain: "private let titleLayer = CATextLayer()"), false,
                    "网页歌词: 歌名不用 CATextLayer(截断过长的一行时整行错位)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsServer.swift"), contain: "connection.sendText(WebLyricsPages.helloMessage())"), true,
                    "网页歌词: 连上后先告诉网页这一版的 revision,旧网页自己刷新")
        expectEqual(sourceBytes(pagesSource, contain: "if (m.type === 'hello') checkRevision(m.rev);"), true,
                    "网页歌词: 副屏网页认 hello")
        expectEqual(sourceBytes(pagesSource, contain: "else if (m.type === 'hello') checkRevision(m.rev);"), true,
                    "网页歌词: OBS 网页认 hello")
        expectEqual(sourceBytes(pagesSource, contain: "setInterval(() => { if (performance.now() - lastFrame > 50) present(); }, 16);"), true,
                    "网页歌词: 副屏 rAF 不来时由定时器接着放(从别的 App 打开的浏览器小窗里 rAF 可能一直不来)")
        expectEqual(sourceBytes(pagesSource, contain: "queue[i].t + offset + DELAY <= now"), true,
                    "网页歌词: 副屏网页按画帧时刻匀速放")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"), contain: "coverHost.frame ="), false,
                    "网页歌词: 封面卡带缩放变换,不能设 frame(会按缩放反算 bounds,继续播放时封面变大)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"), contain: "layer.frame = Self.timeFrame(in: slot)")
                        && sourceBytes(app("WebLyrics/WebLyricsScreen.swift"), contain: "elapsedLayer.frame = Self.timeFrame(in: elapsedSlot)")
                        && !sourceBytes(app("WebLyrics/WebLyricsScreen.swift"), contain: "frame: elapsedLayer.frame"), true,
                    "网页歌词: 进度时间布局和更新都从固定格子算位置(拿图层自己的 frame 当基准,重排时两个时间上下跳)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsChrome.swift"), contain: "4 + max(value?.size.width ?? 0, widestValue)")
                        && sourceBytes(app("WebLyrics/WebLyricsChrome.swift"), contain: "4 + widestButtons + 10 + 6)"), true,
                    "网页歌词: 「…」菜单宽度按出现「重置」、数值最长时留足(偏移一变就变宽的话 ± 跟着右移,连点「＋」落空)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsObsFeed.swift"),
                                contain: "if subs.isEmpty { subscribe() }\n        clients[ObjectIdentifier(connection)] = connection"), true,
                    "网页歌词: OBS 第一条连接先订阅再登记(登记在前会把样式、整首歌词、位置各收两份)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"), contain: "moved: false, seeks: chromeShown)")
                        && sourceBytes(app("WebLyrics/WebLyricsScreen.swift"), contain: "if !moved, seeks { seekToLine(at: p) }"), true,
                    "网页歌词: 控件收着时点歌词只唤出控件、不跳转(触屏上本想点一下叫出控件,会把歌跳走)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"),
                                contain: "private var coverWidth: CGFloat { max(80, min(width * 0.279, 460, height - 216)) }"), true,
                    "网页歌词: 封面边长另按高度封顶(手机横放时左栏整组放不下,封面上缘出画)")
        let chromeSource = app("WebLyrics/WebLyricsChrome.swift")
        expectEqual(chromeSource.components(separatedBy: "panel.frame = panelFrame(width: width, height: height, anchor: anchor, in: s.size)").count - 1,
                    4, "网页歌词: 「…」菜单和三种面板都按 panelFrame 摆(竖排时「…」在顶上,上方放不下要挂到下方、右边要收回画面)")
        expectEqual(sourceBytes(chromeSource, contain: "let y = above >= 8 ? above : (below + height <= size.height - 8 ? below : 8)"), true,
                    "网页歌词: 面板上方放不下时挂在「…」下方")
        let paneSource = app("WebLyrics/WebLyricsScreen.swift")
        expectEqual(sourceBytes(paneSource, contain: "guard pane.transportInteractive else { return nil }")
                        && sourceBytes(paneSource, contain: "pane.transportAbsorbs(CGPoint(x: p.x - paneRect.minX, y: p.y - paneRect.minY))")
                        && sourceBytes(paneSource, contain: "pane.setTransportVisible(chromeVisible, animated: true)"), true,
                    "网页歌词: 手机底部播放条跟着控件闲置收起;收着时点那里只唤出控件,露着时点空白处不落到歌词上跳句")
        expectEqual(sourceBytes(paneSource, contain: "list.frame = wrapperFrame(listFrame)")
                        && sourceBytes(paneSource, contain: "pane.frame = wrapperFrame(paneRect)"), true,
                    "网页歌词: 竖排时设给外层画布的 frame 要上下翻一次(外层 y 向上),命中仍按 y 向下的框")
        expectEqual(sourceBytes(app("UI/LyricsLayerList.swift"), contain: "r.layer.shouldRasterize = d != 0"), true,
                    "网页歌词: 离屏时不在唱的行缓存成位图(每个逐字遮罩都是主线程上的一趟绘制)")
        expectEqual(sourceBytes(app("UI/LyricsLayerList.swift"), contain: "v.rendersDetached = rendersDetached"), true,
                    "网页歌词: 歌词列表把离屏开关传给间奏点")
        let screen = app("WebLyrics/WebLyricsScreen.swift")
        expectEqual(sourceBytes(screen, contain: "list.rendersDetached = true"), true, "网页歌词: 副屏那份歌词列表标成离屏")
        expectEqual(sourceBytes(screen, contain: "DetachedLayerTree.assemble(list)"), true, "网页歌词: 每帧给歌词列表拼树")
    }
}
