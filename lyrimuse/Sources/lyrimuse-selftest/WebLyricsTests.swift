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
        expectEqual(WebLyricsTap.parse(Data(#"{"tap":[0.25,0.75]}"#.utf8)), CGPoint(x: 0.25, y: 0.75), "网页歌词: 点按位置原样读出")
        expectEqual(WebLyricsTap.parse(Data(#"{"tap":[1.2,0.5]}"#.utf8)), nil, "网页歌词: 点按位置超出画面不认")
        expectEqual(WebLyricsTap.parse(Data(#"{"tap":[0.5]}"#.utf8)), nil, "网页歌词: 点按位置缺一维不认")
        expectEqual(WebLyricsTap.parse(Data("tap".utf8)), nil, "网页歌词: 不是 JSON 不认")
        expectEqual(WebLyricsTap.permits(remoteIsLoopback: true, lanControlEnabled: false), true, "网页歌词: 本机副屏一律能点")
        expectEqual(WebLyricsTap.permits(remoteIsLoopback: false, lanControlEnabled: false), false,
                    "网页歌词: 别的设备默认不能控制播放")
        expectEqual(WebLyricsTap.permits(remoteIsLoopback: false, lanControlEnabled: true), true, "网页歌词: 开了控制开关别的设备能点")

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
        expectEqual(sourceBytes(app("AppDelegate.swift"), contain: "WebLyricsServer.shared.start()"), true, "网页歌词: 启动时接上服务")
        let pages = app("WebLyrics/WebLyricsPages.swift")
        expectEqual(sourceBytes(pages, contain: "setInterval(() => { if (performance.now() - lastTick > 50) tick(); }, 33);"), true,
                    "网页歌词: OBS 页 rAF 停了由定时器接着刷(OBS 失焦时 rAF 会停)")
        expectEqual(sourceBytes(pages, contain: "https://") || sourceBytes(pages, contain: "http://"), false,
                    "网页歌词: 网页不连外部地址")
        let gapDots = app("UI/LyricsGapDots.swift")
        expectEqual(sourceBytes(gapDots, contain: "guard c.running, window != nil || rendersDetached else { return }"), true,
                    "网页歌词: 间奏点离屏时也装动画")
        let pagesSource = app("WebLyrics/WebLyricsPages.swift")
        expectEqual(sourceBytes(pagesSource, contain: "ws.send(JSON.stringify({ tap: [u, v] }));"), true, "网页歌词: 副屏点画面发回相对位置")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsServer.swift"),
                                contain: "if case .screen = role { server?.screens.tap(self, payload: frame.payload) }"), true,
                    "网页歌词: 只有副屏连接的文本帧当点按")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"),
                                contain: "lanControlEnabled: AppSettings.shared.webLyricsAllowLANControl"), true,
                    "网页歌词: 点按过控制开关")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"), contain: "coverHost.frame ="), false,
                    "网页歌词: 封面卡带缩放变换,不能设 frame(会按缩放反算 bounds,继续播放时封面变大)")
        expectEqual(sourceBytes(app("UI/LyricsLayerList.swift"), contain: "r.layer.shouldRasterize = d != 0"), true,
                    "网页歌词: 离屏时不在唱的行缓存成位图(每个逐字遮罩都是主线程上的一趟绘制)")
        expectEqual(sourceBytes(app("UI/LyricsLayerList.swift"), contain: "v.rendersDetached = rendersDetached"), true,
                    "网页歌词: 歌词列表把离屏开关传给间奏点")
        let screen = app("WebLyrics/WebLyricsScreen.swift")
        expectEqual(sourceBytes(screen, contain: "list.rendersDetached = true"), true, "网页歌词: 副屏那份歌词列表标成离屏")
        expectEqual(sourceBytes(screen, contain: "DetachedLayerTree.assemble(list)"), true, "网页歌词: 每帧给歌词列表拼树")
    }
}
