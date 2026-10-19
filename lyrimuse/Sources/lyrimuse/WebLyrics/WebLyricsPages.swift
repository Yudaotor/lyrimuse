import CryptoKit
import Foundation
import LyrimuseCore

/// 网页歌词的两张网页(19 章)。单文件、不连任何 CDN,文字按 App 当前界面语言在服务端填进去。
///
/// 两张网页里都嵌着 `revision`,连上 WebSocket 后 App 先发一条 `{"type":"hello","rev":…}`:对不上就是 App 换过版本、
/// 网页还是旧的(OBS 浏览器源、一直开着的副屏不会自己刷新),网页自己重新载入,10 秒内最多一次。
enum WebLyricsPages {
    private static var htmlLanguage: String { UILanguage.localeIdentifier(for: L10n.current) }

    private static var revisionCache: (language: String, value: String)?

    /// 两张网页内容的摘要(不含它自己),网页或界面语言一变就跟着变。
    static var revision: String {
        let language = htmlLanguage
        if let revisionCache, revisionCache.language == language { return revisionCache.value }
        let digest = SHA256.hash(data: Data((screenPage(revision: "") + obsPage(revision: "")).utf8))
        let value = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        revisionCache = (language, value)
        return value
    }

    static func helloMessage() -> String {
        #"{"type":"hello","rev":"\#(revision)"}"#
    }

    /// 副屏:全屏显示 App 推来的画面帧,尺寸变了就带新尺寸重连。每帧开头 8 字节是 App 画它的时刻(毫秒,大端 Float64),
    /// 后面是 JPEG;浏览器能硬解 H.264(`VideoDecoder`)时改要视频流(`WebLyricsVideo`,连上就解码出错的标签页 10 分钟内退回 JPEG);
    /// 没有 `VideoDecoder`(非安全上下文)但有 MediaSource 的也要视频流,封成分段 MP4 交给 `<video>`(见 19 章决策 36)。
    /// 帧在后台线程解码(`createImageBitmap` / `VideoDecoder`)后排队,`requestAnimationFrame`(它停了时由定时器接着)每一拍按画它的时刻晚
    /// `delay()` 毫秒放出来:网络和解码的快慢不均被这段余量吸掉,画面照 App 画的间隔匀速走。余量至少 40ms,到得越不齐越长
    /// (近 20 秒里到帧比最快那次晚得最多的,涨得快、落得慢)。视频流最多 2 秒(排的是没解的数据),App 按回报的余量提前画,
    /// 屏上歌词不跟着拖后;逐帧 JPEG 最多攒得下的帧数个帧间隔、500ms:解好的帧很占内存,按这一帧的像素数留 6～24 帧
    /// (合计约 80MB),App 缩小编码尺寸时留得多。点按的反馈也跟着晚这么多。解码跟不上时新来的直接丢,不积压。手指按下、拖动、抬起都把画面上的相对位置(`{"ptr":["d",u,v]}`)发回 App,点中什么、拖的是什么由 App 判;
    /// 拖动 16ms 最多发一次,发送缓冲里还压着东西时不再发。菜单里平台页那几行的位置由 App 发来(`links`),
    /// 网页在手指抬起那一刻自己开链接。
    static func screenPage(revision: String = revision) -> String {
        let strings = jsonStrings([
            "connecting": L10n.t("正在连接 Lyrimuse…"),
            "reconnecting": L10n.t("连接已断开，正在重连…"),
            "statsVideo": L10n.t("视频流"),
            "statsJpeg": L10n.t("逐帧 JPEG"),
            "statsRendered": L10n.t("画帧"),
            "statsReceived": L10n.t("到帧"),
            "statsShown": L10n.t("上屏"),
            "statsDownload": L10n.t("接收"),
            "statsBitrate": L10n.t("码率"),
            "statsEncoder": L10n.t("编码器"),
            "statsDelay": L10n.t("放帧余量"),
            "statsLag": L10n.t("上屏延迟"),
            "statsDecode": L10n.t("解码"),
            "statsLead": L10n.t("提前画"),
            "statsQueue": L10n.t("排队"),
            "statsDropped": L10n.t("丢帧"),
            "statsFps": L10n.t("帧/秒"),
        ])
        return """
        <!doctype html>
        <html lang="\(htmlLanguage)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
        <meta name="mobile-web-app-capable" content="yes">
        <meta name="theme-color" content="#000000">
        <title>Lyrimuse</title>
        <style>
        html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
        canvas { position: fixed; inset: 0; width: 100%; height: 100%; object-fit: contain; display: block;
                 touch-action: none; -webkit-tap-highlight-color: transparent; -webkit-user-select: none; user-select: none; }
        #safe { position: fixed; visibility: hidden; pointer-events: none;
                padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); }
        #msg { position: fixed; top: 0; right: 0; bottom: 0; left: 0; display: flex; align-items: center; justify-content: center;
               color: rgba(255,255,255,.55); font: 15px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; }
        </style>
        </head>
        <body>
        <canvas id="frame" width="0" height="0"></canvas>
        <div id="safe"></div>
        <div id="msg"></div>
        <script>
        (() => {
          const T = \(strings);
          const REV = "\(revision)";
          function checkRevision(rev) {
            if (rev === REV) return;
            try {
              if (Date.now() - (Number(sessionStorage.getItem('lyrimuse.reload')) || 0) < 10000) return;
              sessionStorage.setItem('lyrimuse.reload', String(Date.now()));
            } catch (err) {}
            location.reload();
          }
          const key = new URLSearchParams(location.search).get('k') || '';
          const canvas = document.getElementById('frame');
          const ctx = canvas.getContext('2d', { alpha: false });
          const msg = document.getElementById('msg');
          const MIN_DELAY = 40, MAX_DELAY = 500, MAX_VIDEO_DELAY = 2000, BUFFER_BYTES = 8e7, PEAK_HOLD = 20000, PEAK_DECAY = 0.01;
          let ws = null, retry = 1000, retryTimer = 0, resizeTimer = 0;
          let queue = [], decoding = 0, offset = Infinity, lastShown = -Infinity, lastFrame = 0;
          // 别的设备上开的(不是本机回环)余量从 START_DELAY 起步,头一次停顿就接得住;App 按余量提前画,歌词不跟着拖后
          const START_DELAY = 300;
          const remote = !['localhost', '127.0.0.1', '[::1]', '::1'].includes(location.hostname);
          let jitter = remote ? START_DELAY - 16 : 0, jitterAt = performance.now(), lastArrival = 0;
          let gap = 1000 / 60, lastT = 0, framePixels = 0;
          // 暂停、跳转时 App 发来的 [from, to]:画帧时刻落在里面的帧是提前画押错的,收到了也不放(视频照解,后面的帧要参照)
          let cuts = [];
          function cutOut(t) { return cuts.some((c) => t > c[0] && t <= c[1]); }
          function cut(from, to) {
            cuts.push([from, to]);
            if (cuts.length > 8) cuts.shift();
            queue = queue.filter((item) => {
              if (!cutOut(item.t)) return true;
              release(item);
              return false;
            });
          }
          function bufferCap() { return framePixels ? Math.max(6, Math.min(24, Math.floor(BUFFER_BYTES / (framePixels * 4)))) : 6; }
          // 逐帧 JPEG 排的是解好的图,余量受内存限制;视频排的是没解的数据(每帧几 KB),只按时间封顶。视频还要留出解码的工夫
          // (decodeCost):到得晚的帧收到就解,解完也得赶在放之前;走 MediaSource 的换成固定多留 MSE_MARGIN(<video> 自己解,
          // 解好的帧压在里面一阵才放)。这份余量报给 App,提前画也就把解码算了进去
          function delay() {
            const cap = useVideo ? MAX_VIDEO_DELAY : Math.min(gap * bufferCap(), MAX_DELAY);
            return Math.max(MIN_DELAY, Math.min(jitter + 16 + (useVideo ? (viaMse ? MSE_MARGIN : decodeCost) : 0), cap));
          }
          msg.textContent = T.connecting;
          function decode(blob) {
            if (window.createImageBitmap) return createImageBitmap(blob);
            return new Promise((resolve, reject) => {
              const url = URL.createObjectURL(blob);
              const image = new Image();
              image.onload = () => { URL.revokeObjectURL(url); resolve(image); };
              image.onerror = () => { URL.revokeObjectURL(url); reject(); };
              image.src = url;
            });
          }
          function release(item) { if (item.frame.close) item.frame.close(); }
          function frameWidth(f) { return f.displayWidth || f.width; }
          function frameHeight(f) { return f.displayHeight || f.height; }
          // 记一帧到达:t 是 App 画它的时刻
          function arrived(t) {
            statsArrived++;
            // 两边时钟之差加最短路上的延迟:取见过的最小值,再慢慢往上松,网络路径变慢了也跟得上
            const now = performance.now(), lag = now - t;
            offset = lag < offset ? lag : offset + (lag - offset) * 0.002;
            // 这一帧比最快那次晚到多少:近 PEAK_HOLD 毫秒里最晚的那次定余量,晚了立刻放宽,停过一次的网络多半还会再停;
            // 之后每秒收回 PEAK_DECAY 秒,约每百帧少放一帧,看不出跳
            const late = lag - offset;
            if (late >= jitter) { jitter = late; jitterAt = now; }
            else if (now - jitterAt > PEAK_HOLD) jitter = Math.max(late, jitter - (now - lastArrival) * PEAK_DECAY);
            lastArrival = now;
            if (lastT && t > lastT) gap += (t - lastT - gap) * 0.1;
            if (t > lastT) lastT = t;
          }
          // 解好的一帧(图片或视频帧)排进队列,按画帧时刻放
          function accept(t, frame) {
            const item = { t, frame };
            if (t <= lastShown || cutOut(t)) { release(item); return; }
            queue.push(item);
            queue.sort((a, b) => a.t - b.t);
            framePixels = frameWidth(frame) * frameHeight(frame);
            while (queue.length > bufferCap() + 2) release(queue.shift());
          }
          function receive(buffer) {
            statsBytes += buffer.byteLength;
            if (useVideo) { receiveVideo(buffer); return; }
            if (buffer.byteLength <= 8) return;
            const t = new DataView(buffer).getFloat64(0);
            arrived(t);
            if (decoding >= 3) return;
            decoding++;
            decode(new Blob([new Uint8Array(buffer, 8)], { type: 'image/jpeg' })).then((frame) => { accept(t, frame); }, () => {})
              .then(() => { decoding--; });
          }
          // 能硬解 H.264 就要视频流(只发跟上一帧的差别,慢网上流量小几十倍):每条消息 1 字节类型(1 解码配置 avcC、2 关键帧、
          // 3 普通帧)+ 8 字节画帧时刻 + 数据。连上 VIDEO_TRUST_MS 内解码就出错的,当这个浏览器解不了,这个标签页 NO_VIDEO_MS 内
          // 改回逐帧 JPEG 重连;用了一阵才出错的(标签页在后台时浏览器回收了解码器之类)不记,重连接着要视频流。别记成永久的:
          // 偶尔一次出错就让这个标签页一直走 JPEG,又糊又卡、也没有提前画
          // 视频帧收到后先按没解的数据排着,快到放的时候才按顺序送去解:解好的 VideoFrame 占着解码器的输出缓冲,压多了解码器会
          // 停住不再出帧。提前多少按这个浏览器实测解一帧要多久(最近 DECODE_SAMPLES 帧的 p95 + 16ms,在 DECODE_LEAD～DECODE_MAX_LEAD
          // 之间)。别固定提前:机器一忙解一帧要几百毫秒,不够的那些帧解完已经过了该放的时候,只能跳过。排得太多(标签页在后台
          // 很久)就整个丢掉,等下一个关键帧
          const DECODE_LEAD = 50, DECODE_MAX_LEAD = 300, DECODE_SAMPLES = 180, MAX_PENDING_CHUNKS = 600;
          let decodeCost = 0, decodeSamples = [], decodeStarted = new Map();
          function noteDecoded(timestamp) {
            const started = decodeStarted.get(timestamp);
            if (started === undefined) return;
            decodeStarted.delete(timestamp);
            decodeSamples.push(performance.now() - started);
            if (decodeSamples.length > DECODE_SAMPLES) decodeSamples.shift();
            if (decodeSamples.length % 30 === 0 || decodeSamples.length === DECODE_SAMPLES) {
              const sorted = decodeSamples.slice().sort((a, b) => a - b);
              decodeCost = sorted[Math.floor(sorted.length * 0.95)];
            }
          }
          function decodeLead() { return Math.max(DECODE_LEAD, Math.min(DECODE_MAX_LEAD, decodeCost + 16)); }
          const VIDEO_TRUST_MS = 30000, NO_VIDEO_MS = 600000;
          let useVideo = false, decoder = null, decoderConfig = '', needKey = true, chunks = [], videoSince = 0;
          function videoAllowed() {
            if (!window.VideoDecoder && !mseSupported()) return false;
            try { return !(Date.now() - (Number(sessionStorage.getItem('lyrimuse.noVideo')) || 0) < NO_VIDEO_MS); } catch (err) { return true; }
          }
          useVideo = videoAllowed();
          function dropVideo() {
            if (performance.now() - videoSince < VIDEO_TRUST_MS) {
              try { sessionStorage.setItem('lyrimuse.noVideo', String(Date.now())); } catch (err) {}
              useVideo = false;
            }
            if (decoder) { try { decoder.close(); } catch (err) {} }
            decoder = null;
            decoderConfig = '';
            chunks = [];
            decodeStarted.clear();
            closeMse();
            if (ws) ws.close();
          }
          // 收帧回报(每 FEEDBACK_MS 一次):最后一条消息的画帧时刻、连上以来收到的字节数、最后一条到了多少毫秒、此刻的
          // 放帧余量。App 按它控码率和在途上限,并按余量提前画,屏上歌词跟音乐对得上
          const FEEDBACK_MS = 200;
          let rxStamp = 0, rxBytes = 0, rxAt = 0;
          setInterval(() => {
            if (!useVideo || !rxStamp || !ws || ws.readyState !== 1) return;
            ws.send(JSON.stringify({ fb: [rxStamp, rxBytes, Math.round(performance.now() - rxAt), Math.round(delay())] }));
          }, FEEDBACK_MS);
          // 诊断浮层:按 D 或网址带 stats=1 开关。网页自己数到帧、上屏、接收,App 每秒发来画帧、码率、排队、提前量(开着时才发)
          let statsOn = new URLSearchParams(location.search).get('stats') === '1';
          let statsBox = null, statsServer = null, statsArrived = 0, statsShown = 0, statsBytes = 0, statsAt = performance.now();
          // 上屏延迟:放出来那一刻比画帧时刻(折到这边的钟、去掉最短路上的延迟)晚多少,跟放帧余量比就看得出解码、放帧多花的那段
          let statsLagSum = 0, statsLagCount = 0;
          function noteLag(ms) { statsLagSum += ms; statsLagCount++; }
          function sendStatsToggle() {
            if (ws && ws.readyState === 1) ws.send(JSON.stringify({ stats: statsOn ? 1 : 0 }));
          }
          function renderStats() {
            const now = performance.now(), secs = Math.max(0.001, (now - statsAt) / 1000);
            if (mse && mse.video.getVideoPlaybackQuality) {
              const q = mse.video.getVideoPlaybackQuality(), shown = q.totalVideoFrames - q.droppedVideoFrames;
              statsShown = Math.max(0, shown - mse.shown);
              mse.shown = shown;
            }
            const arrivedPerSec = Math.round(statsArrived / secs), shownPerSec = Math.round(statsShown / secs);
            const mb = (statsBytes / secs / 1e6).toFixed(2), lag = statsLagCount ? Math.round(statsLagSum / statsLagCount) : null;
            statsLagSum = 0;
            statsLagCount = 0;
            statsArrived = 0;
            statsShown = 0;
            statsBytes = 0;
            statsAt = now;
            if (!statsOn) return;
            if (!statsBox) {
              statsBox = document.createElement('div');
              statsBox.style.cssText = 'position:fixed;top:8px;left:8px;z-index:10;padding:6px 9px;border-radius:7px;' +
                'background:rgba(0,0,0,0.6);color:#fff;font:12px/1.5 ui-monospace,Menlo,monospace;white-space:pre;pointer-events:none';
              document.body.appendChild(statsBox);
            }
            const st = statsServer || {};
            const lines = [
              (useVideo ? T.statsVideo + (viaMse ? ' (MSE)' : '') : T.statsJpeg) + ' · ' + T.statsRendered + ' ' + (st.fps ?? '-') + ' · ' + T.statsReceived + ' ' +
                arrivedPerSec + ' · ' + T.statsShown + ' ' + shownPerSec + ' ' + T.statsFps,
              T.statsDownload + ' ' + mb + ' MB/s' + (st.kbps != null ? ' · ' + T.statsBitrate + ' ' + (st.kbps / 1000).toFixed(1) +
                ' Mbps (' + T.statsEncoder + ' ' + ((st.enc ?? 0) / 1000).toFixed(1) + ')' : ''),
              T.statsDelay + ' ' + Math.round(delay()) + ' ms · ' + T.statsLag + ' ' + (lag ?? '-') + ' ms' +
                (useVideo && !viaMse ? ' · ' + T.statsDecode + ' ' + Math.round(decodeCost) + ' ms' : '') +
                ' · ' + T.statsLead + ' ' + (st.lead ?? 0) + ' / ' + (st.target ?? 0) + ' ms',
              (st.queue != null ? T.statsQueue + ' ' + st.queue + ' ms · ' : '') + T.statsDropped + ' ' + (st.drop ?? 0),
            ];
            statsBox.textContent = lines.join(String.fromCharCode(10));
            statsBox.style.display = 'block';
          }
          setInterval(renderStats, 1000);
          document.addEventListener('keydown', (e) => {
            if (e.metaKey || e.ctrlKey || e.altKey || (e.key !== 'd' && e.key !== 'D')) return;
            statsOn = !statsOn;
            if (!statsOn && statsBox) statsBox.style.display = 'none';
            sendStatsToggle();
            renderStats();
          });
          function receiveVideo(buffer) {
            rxBytes += buffer.byteLength;
            if (buffer.byteLength <= 9) return;
            const view = new DataView(buffer);
            const type = view.getUint8(0), t = view.getFloat64(1);
            rxStamp = t;
            rxAt = performance.now();
            const data = new Uint8Array(buffer, 9);
            if (viaMse) { receiveMse(type, t, data); return; }
            if (type === 1) {
              const config = Array.from(data).join(',');
              if (decoder && config === decoderConfig) return;
              if (!decoder) {
                decoder = new VideoDecoder({ output: (f) => { noteDecoded(f.timestamp); accept(f.timestamp / 1000, f); }, error: dropVideo });
              }
              try {
                decoder.configure({ codec: avcCodec(data), description: data.slice(), optimizeForLatency: true });
                decoderConfig = config;
                needKey = true;
                chunks = [];
              } catch (err) { dropVideo(); }
              return;
            }
            if (!decoder || decoder.state !== 'configured') return;
            if (type !== 2 && needKey) return;
            arrived(t);
            if (type === 2) needKey = false;
            chunks.push(new EncodedVideoChunk({ type: type === 2 ? 'key' : 'delta', timestamp: Math.round(t * 1000), data }));
            if (chunks.length > MAX_PENDING_CHUNKS) { chunks = []; needKey = true; }
          }
          // 没有 WebCodecs 的浏览器(Firefox、Chromium 用局域网主机名打开时不是安全上下文,没有 VideoDecoder)照样要视频流:
          // 每帧封成一段分段 MP4 交给 MediaSource,由垫在画布下面的 <video> 解码,每出一帧画到画布上。<video> 按自己的时钟放,
          // 播放位置钉在「此刻 − 两边时钟差 − 放帧余量」:超前就停住等,落后分档调快追,落后超过 MSE_SEEK 秒直接跳过去。
          // 别往回跳:余量变大时那一下跳回去会把放过的画面再放一遍。每帧扣下来,等下一帧到了按两帧画帧时刻之差填时长再交出去,
          // 时间轴首尾相接:时长填长了 Firefox 把缓冲切成几段、放的是旧帧;填短了中间留缺口,两帧相隔超过两倍时长浏览器还当成断流,
          // 丢到下一个关键帧为止。重连(窗口尺寸变了之类)不拆 <video>:时间轴接着用,新连接的解码配置换一份初始化段,
          // 扣着的那一帧盖住重连的空档;拆了要等新连接重新攒够余量才出画面。别靠 requestVideoFrameCallback 画:Firefox 里它
          // 一秒只回调二十几次,实际上屏有将近 60 帧
          const viaMse = !window.VideoDecoder;
          // MSE_MARGIN:Firefox 的 <video> 比自己解码(WebCodecs)多要这么多余量,少了在关键帧那几下卡、丢帧
          const MSE_TIMESCALE = 90000, MSE_KEEP = 10, MSE_SEEK = 1, MSE_AHEAD = 0.05, MSE_MARGIN = 50;
          let mse = null;
          function mseSupported() {
            try { return !!window.MediaSource && MediaSource.isTypeSupported('video/mp4; codecs="avc1.640033"'); } catch (err) { return false; }
          }
          function avcCodec(avcc) { return 'avc1.' + [avcc[1], avcc[2], avcc[3]].map((x) => x.toString(16).padStart(2, '0')).join(''); }
          function concatBytes(parts) {
            let size = 0;
            for (const p of parts) size += p.length;
            const out = new Uint8Array(size);
            let at = 0;
            for (const p of parts) { out.set(p, at); at += p.length; }
            return out;
          }
          function u32(...v) { const a = new Uint8Array(v.length * 4), d = new DataView(a.buffer); v.forEach((x, i) => d.setUint32(i * 4, x)); return a; }
          function u16(...v) { const a = new Uint8Array(v.length * 2), d = new DataView(a.buffer); v.forEach((x, i) => d.setUint16(i * 2, x)); return a; }
          function chars(s) { return Uint8Array.from(s, (c) => c.charCodeAt(0)); }
          function mp4Box(type, ...parts) {
            const body = concatBytes(parts), out = new Uint8Array(body.length + 8);
            new DataView(out.buffer).setUint32(0, out.length);
            out.set(chars(type), 4);
            out.set(body, 8);
            return out;
          }
          // avcC 里第一份 SPS 写的画面尺寸:去掉防竞争字节,按指数哥伦布码读到裁边那几项
          function spsSize(avcc) {
            const raw = avcc.subarray(9, 8 + ((avcc[6] << 8) | avcc[7])), rbsp = [];
            let zeros = 0;
            for (const b of raw) {
              if (zeros >= 2 && b === 3) { zeros = 0; continue; }
              rbsp.push(b);
              zeros = b === 0 ? zeros + 1 : 0;
            }
            let pos = 0;
            const bit = () => (rbsp[pos >> 3] >> (7 - (pos++ & 7))) & 1;
            const bits = (n) => { let v = 0; for (let i = 0; i < n; i++) v = v * 2 + bit(); return v; };
            const ue = () => { let z = 0; while (!bit() && z < 32) z++; return 2 ** z - 1 + bits(z); };
            const se = () => { const k = ue(); return k % 2 ? (k + 1) / 2 : -k / 2; };
            const profile = bits(8);
            bits(16);
            ue();
            let chroma = 1;
            if ([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].includes(profile)) {
              chroma = ue();
              if (chroma === 3) bit();
              ue();
              ue();
              bit();
              if (bit()) {
                for (let i = 0; i < (chroma === 3 ? 12 : 8); i++) {
                  if (!bit()) continue;
                  let last = 8, next = 8;
                  for (let j = 0; j < (i < 6 ? 16 : 64); j++) {
                    if (next) next = (last + se() + 256) % 256;
                    last = next || last;
                  }
                }
              }
            }
            ue();
            const pocType = ue();
            if (pocType === 0) ue();
            else if (pocType === 1) { bit(); se(); se(); const n = ue(); for (let i = 0; i < n; i++) se(); }
            ue();
            bit();
            const mbWidth = ue() + 1, mapHeight = ue() + 1, frameMbsOnly = bit();
            if (!frameMbsOnly) bit();
            bit();
            const crop = bit() ? [ue(), ue(), ue(), ue()] : [0, 0, 0, 0];
            const cropX = chroma === 1 || chroma === 2 ? 2 : 1, cropY = (chroma === 1 ? 2 : 1) * (2 - frameMbsOnly);
            return [mbWidth * 16 - cropX * (crop[0] + crop[1]), (2 - frameMbsOnly) * mapHeight * 16 - cropY * (crop[2] + crop[3])];
          }
          // 初始化段(ftyp + moov):一条视频轨,样本全在后面的 moof 里
          function mseInit(avcc) {
            const [w, h] = spsSize(avcc);
            const matrix = u32(0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000);
            const avc1 = mp4Box('avc1', new Uint8Array(6), u16(1, 0, 0), u32(0, 0, 0), u16(w, h), u32(0x480000, 0x480000, 0), u16(1),
              new Uint8Array(32), u16(0x18, 0xffff), mp4Box('avcC', avcc));
            const stbl = mp4Box('stbl', mp4Box('stsd', u32(0, 1), avc1), mp4Box('stts', u32(0, 0)), mp4Box('stsc', u32(0, 0)),
              mp4Box('stsz', u32(0, 0, 0)), mp4Box('stco', u32(0, 0)));
            const minf = mp4Box('minf', mp4Box('vmhd', u32(1), u16(0, 0, 0, 0)),
              mp4Box('dinf', mp4Box('dref', u32(0, 1), mp4Box('url ', u32(1)))), stbl);
            const trak = mp4Box('trak', mp4Box('tkhd', u32(3, 0, 0, 1, 0, 0, 0, 0), u16(0, 0, 0, 0), matrix, u32(w * 65536, h * 65536)),
              mp4Box('mdia', mp4Box('mdhd', u32(0, 0, 0, MSE_TIMESCALE, 0), u16(0x55c4, 0)),
                mp4Box('hdlr', u32(0, 0), chars('vide'), u32(0, 0, 0), chars('Lyrimuse'), new Uint8Array(1)), minf));
            const mvhd = mp4Box('mvhd', u32(0, 0, 0, 1000, 0, 0x10000), u16(0x100), new Uint8Array(10), matrix, new Uint8Array(24), u32(2));
            return concatBytes([mp4Box('ftyp', chars('isom'), u32(0x200), chars('isomiso6avc1mp41')),
              mp4Box('moov', mvhd, trak, mp4Box('mvex', mp4Box('trex', u32(0, 1, 1, 0, 0, 0))))]);
          }
          // 一帧一段(moof + mdat):时刻按画帧时刻,样本标记分关键帧和普通帧
          function mseSegment(seq, time, duration, key, data) {
            const moof = (offset) => mp4Box('moof', mp4Box('mfhd', u32(0, seq)), mp4Box('traf', mp4Box('tfhd', u32(0x20000, 1)),
              mp4Box('tfdt', u32(0x1000000, Math.floor(time / 4294967296), time % 4294967296)),
              mp4Box('trun', u32(0x701, 1, offset, duration, data.length, key ? 0x2000000 : 0x1010000))));
            return concatBytes([moof(moof(0).length + 8), mp4Box('mdat', data)]);
          }
          function receiveMse(type, t, data) {
            if (type === 1) {
              const config = Array.from(data).join(',');
              if (mse && config === mse.config) return;
              if (!mse) openMse(avcCodec(data));
              try { mse.init = mseInit(data); } catch (err) { dropVideo(); return; }
              mse.config = config;
              needKey = true;
              return;
            }
            if (!mse || !mse.init || (type !== 2 && needKey)) return;
            arrived(t);
            if (mse.baseMs === null) mse.baseMs = t;
            if (t < mse.baseMs) return;
            const time = Math.round((t - mse.baseMs) * MSE_TIMESCALE / 1000), held = mse.held;
            if (held) mse.pending.push(mseSegment(++mse.seq, held.time, Math.max(1, time - held.time), held.key, held.data));
            if (type === 2) {
              if (needKey) mse.pending.push(mse.init);
              needKey = false;
            }
            mse.held = { time, key: type === 2, data };
            if (mse.pending.length > MAX_PENDING_CHUNKS) { mse.pending = []; mse.held = null; needKey = true; }
            flushMse();
          }
          function flushMse() {
            if (!mse || !mse.sb || mse.sb.updating || !mse.pending.length) return;
            const all = concatBytes(mse.pending);
            mse.pending = [];
            try { mse.sb.appendBuffer(all); } catch (err) { dropVideo(); }
          }
          function openMse(codec) {
            const video = document.createElement('video'), source = new MediaSource();
            video.muted = true;
            video.playsInline = true;
            video.style.cssText = 'position:fixed;inset:0;width:100%;height:100%;object-fit:contain;z-index:-1';
            document.body.insertBefore(video, canvas);
            const m = { video, source, sb: null, url: URL.createObjectURL(source), config: '', init: null, baseMs: null, seq: 0, pending: [], held: null, drawn: -1, shown: 0 };
            mse = m;
            source.addEventListener('sourceopen', () => {
              if (mse !== m) return;
              try {
                m.sb = source.addSourceBuffer('video/mp4; codecs="' + codec + '"');
                m.sb.addEventListener('updateend', () => { if (mse === m) flushMse(); });
                m.sb.addEventListener('error', () => { if (mse === m) dropVideo(); });
                flushMse();
              } catch (err) { dropVideo(); }
            }, { once: true });
            video.addEventListener('error', () => { if (mse === m) dropVideo(); });
            video.src = m.url;
          }
          function closeMse() {
            if (!mse) return;
            const m = mse;
            mse = null;
            m.video.removeAttribute('src');
            try { m.video.load(); } catch (err) {}
            m.video.remove();
            URL.revokeObjectURL(m.url);
          }
          // 播放位置没动(停着等)就不重画;落在暂停、跳转的丢帧窗口里也不画,画布停在窗口前那一帧
          function drawMse() {
            const v = mse.video;
            if (!v.videoWidth || v.readyState < 2 || v.currentTime === mse.drawn) return;
            if (mse.baseMs !== null && cutOut(mse.baseMs + v.currentTime * 1000)) return;
            mse.drawn = v.currentTime;
            if (canvas.width !== v.videoWidth || canvas.height !== v.videoHeight) {
              canvas.width = v.videoWidth;
              canvas.height = v.videoHeight;
            }
            ctx.drawImage(v, 0, 0);
            msg.style.display = 'none';
            if (mse.baseMs !== null) noteLag(performance.now() - offset - mse.baseMs - v.currentTime * 1000);
          }
          function steerMse(now) {
            const v = mse.video, sb = mse.sb;
            if (!sb || mse.baseMs === null || offset === Infinity || v.seeking || !sb.buffered.length) return;
            const target = (now - offset - delay() - mse.baseMs) / 1000, ahead = v.currentTime - target;
            if (target < sb.buffered.start(0)) return;
            if (v.paused) {
              if (ahead > 0) return;
              if (ahead < -MSE_SEEK) v.currentTime = target;
              v.play().catch(() => {});
              return;
            }
            if (ahead > MSE_AHEAD) { v.pause(); return; }
            if (ahead < -MSE_SEEK) { v.currentTime = target; return; }
            // 分几档、死区内不动:每次改播放速度浏览器都要重新对时钟,连续微调会丢帧
            const rate = ahead < -0.25 ? 1.25 : ahead < -0.1 ? 1.1 : ahead < -0.03 ? 1.03 : ahead > 0.02 ? 0.95 : 1;
            if (rate !== v.playbackRate) v.playbackRate = rate;
          }
          // 放过的清掉,只留最近 MSE_KEEP 秒
          setInterval(() => {
            if (!mse || !mse.sb || mse.sb.updating || mse.pending.length || !mse.sb.buffered.length) return;
            const until = mse.video.currentTime - MSE_KEEP;
            if (until > mse.sb.buffered.start(0) + 1) { try { mse.sb.remove(0, until); } catch (err) {} }
          }, 2000);
          // 把快到放的时候的那些按顺序送去解
          function decodeDue(now) {
            if (!chunks.length || !decoder || decoder.state !== 'configured') return;
            const until = now - offset - delay() + decodeLead();
            let n = 0;
            while (n < chunks.length && chunks[n].timestamp / 1000 <= until) n++;
            if (!n) return;
            const due = chunks.slice(0, n);
            chunks = chunks.slice(n);
            if (decodeStarted.size > MAX_PENDING_CHUNKS) decodeStarted.clear();
            try {
              for (const c of due) { decodeStarted.set(c.timestamp, now); decoder.decode(c); }
            } catch (err) { dropVideo(); }
          }
          function present() {
            const now = performance.now(), wait = offset + delay();
            if (mse) {
              steerMse(now);
              drawMse();
              return;
            }
            if (useVideo) decodeDue(now);
            let pick = -1;
            for (let i = 0; i < queue.length && queue[i].t + wait <= now; i++) pick = i;
            if (pick < 0) return;
            for (let i = 0; i < pick; i++) release(queue[i]);
            const item = queue[pick];
            queue = queue.slice(pick + 1);
            lastShown = item.t;
            if (canvas.width !== frameWidth(item.frame) || canvas.height !== frameHeight(item.frame)) {
              canvas.width = frameWidth(item.frame);
              canvas.height = frameHeight(item.frame);
            }
            ctx.drawImage(item.frame, 0, 0);
            statsShown++;
            noteLag(now - item.t - offset);
            release(item);
            msg.style.display = 'none';
          }
          function frame() { lastFrame = performance.now(); present(); requestAnimationFrame(frame); }
          requestAnimationFrame(frame);
          // 浏览器不把这页当成在显示时(从别的 App 打开的小窗、不在前台的标签页)rAF 可能一直不来:停了 50ms 以上就由定时器接着放
          setInterval(() => { if (performance.now() - lastFrame > 50) present(); }, 16);
          // 标签页切到后台、窗口被盖住或最小化时告诉 App,它就不再按 60 帧画
          function sendVisibility() {
            if (ws && ws.readyState === 1) ws.send(JSON.stringify({ vis: document.visibilityState === 'hidden' ? 0 : 1 }));
          }
          document.addEventListener('visibilitychange', sendVisibility);
          function connect() {
            const url = new URL('/ws', location.href);
            url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
            if (key) url.searchParams.set('k', key);
            // 画面按画布此刻实际铺开的大小要,画布别按 100vh 铺:iOS Safari 的 100vh 比看得见的高度多出工具栏那截,
            // 画面和画布宽高比一不等,contain 就在上下各留一条黑边
            const box = canvas.getBoundingClientRect();
            url.searchParams.set('w', Math.round(box.width || innerWidth));
            url.searchParams.set('h', Math.round(box.height || innerHeight));
            const safe = getComputedStyle(document.getElementById('safe'));
            [['st', 'paddingTop'], ['sr', 'paddingRight'], ['sb', 'paddingBottom'], ['sl', 'paddingLeft']].forEach(([k, side]) => {
              const v = Math.round(parseFloat(safe[side]) || 0);
              if (v > 0) url.searchParams.set(k, v);
            });
            url.searchParams.set('dpr', Math.max(1, Math.min(3, devicePixelRatio || 1)).toFixed(2));
            useVideo = videoAllowed();
            videoSince = performance.now();
            if (useVideo) url.searchParams.set('codec', 'avc');
            needKey = true;
            chunks = [];
            rxStamp = 0;
            rxBytes = 0;
            const socket = new WebSocket(url);
            ws = socket;
            socket.binaryType = 'arraybuffer';
            socket.onopen = () => { retry = 1000; sendVisibility(); if (statsOn) sendStatsToggle(); };
            socket.onmessage = (e) => {
              if (typeof e.data === 'string') {
                try {
                  const m = JSON.parse(e.data);
                  if (m.type === 'hello') checkRevision(m.rev);
                  else if (m.type === 'links') links = m.items;
                  else if (m.type === 'cut') cut(m.from, m.t);
                  else if (m.type === 'stats') statsServer = m;
                  else if (m.type === 'no-video') dropVideo();
                } catch (err) {}
                return;
              }
              receive(e.data);
            };
            socket.onclose = () => {
              if (ws !== socket) return;
              msg.style.display = 'flex';
              msg.textContent = T.reconnecting;
              clearTimeout(retryTimer);
              retryTimer = setTimeout(connect, retry);
              retry = Math.min(retry * 2, 10000);
            };
          }
          let pointerId = null, lastMove = 0, links = [], downLink = null;
          // 菜单里平台页那几行:手机浏览器只肯在手指抬起那一刻开新标签页,所以按下、抬起都落在同一行时由网页自己开
          function linkAt(u, v) {
            for (const l of links) { if (u >= l[0] && u <= l[0] + l[2] && v >= l[1] && v <= l[1] + l[3]) return l[4]; }
            return null;
          }
          function where(e) {
            const r = canvas.getBoundingClientRect();
            const k = Math.min(r.width / canvas.width, r.height / canvas.height);
            const w = canvas.width * k, h = canvas.height * k;
            return [(e.clientX - r.left - (r.width - w) / 2) / w, (e.clientY - r.top - (r.height - h) / 2) / h];
          }
          function sendPointer(phase, e) {
            if (!ws || ws.readyState !== 1 || !canvas.width) return;
            const [u, v] = where(e);
            ws.send(JSON.stringify({ ptr: [phase, Math.round(u * 1e4) / 1e4, Math.round(v * 1e4) / 1e4] }));
          }
          // 放帧余量大(慢网)时点按的反馈要晚这么久才在画面上出来:按下就在手指底下先画一个圆点、拖动时跟着走、抬起淡掉,
          // 只说明「点到了」,点中什么照旧由 App 判、画面上出来
          const TOUCH_DOT_DELAY = 150;
          let touchDot = null;
          function showTouchDot(e) {
            if (delay() < TOUCH_DOT_DELAY) return;
            if (!touchDot) {
              touchDot = document.createElement('div');
              touchDot.style.cssText = 'position:fixed;width:40px;height:40px;margin:-20px 0 0 -20px;border-radius:50%;opacity:0;' +
                'background:rgba(255,255,255,0.3);pointer-events:none;z-index:9;transition:opacity 0.25s,transform 0.15s';
              document.body.appendChild(touchDot);
            }
            touchDot.style.left = e.clientX + 'px';
            touchDot.style.top = e.clientY + 'px';
            touchDot.style.opacity = '1';
            touchDot.style.transform = 'scale(1)';
            touchDot.dataset.on = '1';
          }
          function moveTouchDot(e) {
            if (!touchDot || touchDot.dataset.on !== '1') return;
            touchDot.style.left = e.clientX + 'px';
            touchDot.style.top = e.clientY + 'px';
          }
          function hideTouchDot() {
            if (!touchDot) return;
            touchDot.dataset.on = '';
            touchDot.style.opacity = '0';
            touchDot.style.transform = 'scale(0.6)';
          }
          canvas.addEventListener('pointerdown', (e) => {
            if (pointerId !== null || !canvas.width) return;
            const [u, v] = where(e);
            if (u < 0 || u > 1 || v < 0 || v > 1) return;
            pointerId = e.pointerId;
            downLink = linkAt(u, v);
            try { canvas.setPointerCapture(e.pointerId); } catch (err) {}
            sendPointer('d', e);
            showTouchDot(e);
            e.preventDefault();
          });
          // 滚轮 / 触控板:攒着按 16ms 发一次,滚动量按画面显示高度折成相对值
          let wheelDy = 0, wheelAt = null, wheelTimer = 0;
          canvas.addEventListener('wheel', (e) => {
            e.preventDefault();
            if (!canvas.width) return;
            const r = canvas.getBoundingClientRect();
            const shownHeight = canvas.height * Math.min(r.width / canvas.width, r.height / canvas.height);
            const lines = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? shownHeight : 1;
            wheelDy += e.deltaY * lines / shownHeight;
            wheelAt = where(e);
            if (wheelTimer) return;
            wheelTimer = setTimeout(() => {
              wheelTimer = 0;
              const [u, v] = wheelAt;
              if (ws && ws.readyState === 1 && u >= 0 && u <= 1 && v >= 0 && v <= 1) {
                ws.send(JSON.stringify({ whl: [Math.round(u * 1e4) / 1e4, Math.round(v * 1e4) / 1e4, Math.round(wheelDy * 1e4) / 1e4] }));
              }
              wheelDy = 0;
            }, 16);
          }, { passive: false });
          canvas.addEventListener('pointermove', (e) => {
            if (e.pointerId !== pointerId) return;
            const now = performance.now();
            if (now - lastMove < 16 || (ws && ws.bufferedAmount > 4096)) return;
            lastMove = now;
            sendPointer('m', e);
            moveTouchDot(e);
          });
          canvas.addEventListener('pointerup', (e) => {
            if (e.pointerId !== pointerId) return;
            pointerId = null;
            const [u, v] = where(e);
            if (downLink && linkAt(u, v) === downLink) window.open(downLink, '_blank', 'noopener');
            downLink = null;
            sendPointer('u', e);
            hideTouchDot();
          });
          canvas.addEventListener('pointercancel', (e) => {
            if (e.pointerId !== pointerId) return;
            pointerId = null;
            sendPointer('c', e);
            hideTouchDot();
          });
          addEventListener('resize', () => {
            clearTimeout(resizeTimer);
            resizeTimer = setTimeout(() => {
              const old = ws;
              ws = null;
              if (old) old.close();
              connect();
            }, 400);
          });
          connect();
        })();
        </script>
        </body>
        </html>
        """
    }

    /// OBS 浏览器源:透明背景,照悬浮歌词的版式画一张卡,贴在底部正中。歌词按悬浮歌词断好的段(长句拆分 / 短句合并之后);
    /// 主行逐字填色,下面依次是读音、译文、下一句(字号、字重、颜色深浅、行距、对齐、对唱两侧留白、换行或滚动都照
    /// `LyricsOverlayView`,日文逐词读音按「字在上、读音在下」一列一列排,读音按整组填色);前奏和够格的间奏里画「•••」
    /// (`GapDotsCurve` 同一条曲线)和接下来那句。换句动画照 `OverlayLineRise`:新的一句从下一句的位置、字号、亮度起步走到
    /// 当前行,旧的一句原地淡完,新的下一句后半程淡入。描边照 `LyricsTextStrokeMetrics`:模糊剪影再把透明度拉成实心。
    /// 停播、广告 / 口白、断线时淡出,暂停时按悬浮歌词的「暂停时隐藏」。带 `preview=1` 时铺棋盘格底(设置里的「预览」)。
    /// 逐字填色跟着 `requestAnimationFrame` 刷;OBS 窗口不在前台时浏览器源里的 rAF 可能被挂起,另有定时器在 rAF 停了时接着刷。
    static func obsPage(revision: String = revision) -> String {
        """
        <!doctype html>
        <html lang="\(htmlLanguage)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Lyrimuse</title>
        <style>
        html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; }
        #box { position: fixed; left: 0; right: 0; bottom: 6%; display: flex; justify-content: center;
               opacity: 0; transition: opacity .4s ease; }
        #box.on { opacity: 1; }
        #card { position: relative; box-sizing: border-box; max-width: 96vw; line-height: normal; }
        .row { white-space: pre-wrap; overflow-wrap: break-word; }
        .row > .in { display: inline-block; max-width: 100%; vertical-align: top; }
        .row > .in.cols { display: inline-flex; flex-wrap: wrap; align-items: flex-start; }
        .col { display: inline-flex; flex-direction: column; align-items: center; white-space: pre; }
        #card.scroll .row { white-space: pre; overflow: hidden; }
        #card.scroll .row > .in { max-width: none; will-change: transform; }
        #card.scroll .row > .in.cols { flex-wrap: nowrap; }
        #card.stroked .tx { filter: url(#lmStroke); }
        .w { -webkit-background-clip: text; background-clip: text; color: transparent;
             background-image: linear-gradient(90deg, var(--sung) 0, var(--sung) var(--p, 0%), var(--unsung) var(--p, 0%), var(--unsung) 100%); }
        .dots { display: flex; gap: .3em; padding-top: .25em; }
        .dots > i { width: .32em; height: .32em; border-radius: 50%; background: var(--sung); }
        .ghost { position: absolute; left: 0; right: 0; pointer-events: none; }
        body.preview { background: repeating-conic-gradient(#8c8c8c 0 25%, #b3b3b3 0 50%) 0 0 / 32px 32px; }
        </style>
        </head>
        <body>
        <svg width="0" height="0" style="position: absolute">
          <filter id="lmStroke" x="-0.1" y="-0.5" width="1.2" height="2" color-interpolation-filters="sRGB">
            <feGaussianBlur id="lmBlur" in="SourceAlpha" stdDeviation="2" result="blur"/>
            <feComponentTransfer in="blur" result="mask"><feFuncA id="lmRamp" type="linear" slope="1" intercept="0"/></feComponentTransfer>
            <feFlood id="lmFlood" flood-color="black" result="ink"/>
            <feComposite in="ink" in2="mask" operator="in" result="outline"/>
            <feMerge><feMergeNode in="outline"/><feMergeNode in="SourceGraphic"/></feMerge>
          </filter>
        </svg>
        <div id="box"><div id="card"></div></div>
        <script>
        (() => {
          const REV = "\(revision)";
          function checkRevision(rev) {
            if (rev === REV) return;
            try {
              if (Date.now() - (Number(sessionStorage.getItem('lyrimuse.reload')) || 0) < 10000) return;
              sessionStorage.setItem('lyrimuse.reload', String(Date.now()));
            } catch (err) {}
            location.reload();
          }
          const box = document.getElementById('box');
          const card = document.getElementById('card');
          if (new URLSearchParams(location.search).get('preview') === '1') document.body.classList.add('preview');
          const blurNode = document.getElementById('lmBlur');
          const rampNode = document.getElementById('lmRamp');
          const floodNode = document.getElementById('lmFlood');
          const ALIGN = { leading: 'left', trailing: 'right', center: 'center' };
          const FLEX = { leading: 'flex-start', trailing: 'flex-end', center: 'center' };
          // 换句动画的时序同 `OverlayLineRise`。
          const RISE = { ms: 250, ease: 'cubic-bezier(0.4, 0, 0.2, 1)', outMs: 120, lateDelay: 130, lateMs: 120, preview: .4 };
          const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
          let style = null, track = null, pos = null, at = 0, shownKey = '', connected = false, lastTick = 0;
          let view = null, ws = null, retry = 1000;
          const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
          const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
          function now() {
            if (!pos) return 0;
            return pos.pos + (pos.state === 'playing' ? (performance.now() - at) * (pos.rate || 1) : 0);
          }
          // 悬浮歌词的 1pt 在这里是多少 px。
          function unit() { return innerWidth / 1200; }
          function erfc(x) {
            const z = Math.abs(x), t = 1 / (1 + 0.3275911 * z);
            const y = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429)))) * Math.exp(-z * z);
            return x >= 0 ? y : 2 - y;
          }
          function alphaOf(css) {
            const m = /rgba?[(]([^)]*)[)]/.exec(css || '');
            const parts = m ? m[1].split(',') : [];
            return parts.length > 3 ? Number(parts[3]) : 1;
          }
          function applyStyle() {
            if (!style) return;
            const u = unit();
            const family = style.font ? `"${style.font}", ` : '';
            card.style.fontFamily = family + '-apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans", sans-serif';
            card.style.fontSize = style.size * u + 'px';
            card.style.width = style.width * u + 'px';
            card.style.padding = `${4 * u}px ${20 * u}px ${8 * u}px`;
            card.style.borderRadius = 16 * u + 'px';
            card.style.background = style.card || 'transparent';
            card.style.setProperty('--sung', style.sung);
            card.style.setProperty('--unsung', style.unsung);
            card.style.setProperty('--sung-reading', `color-mix(in srgb, ${style.sung} 75%, transparent)`);
            card.classList.toggle('scroll', style.overflow === 'scroll');
            card.classList.toggle('stroked', !!style.stroke);
            // 描边外沿取模糊剪影透明度 1% 的等值线(离字边 2.326σ),透明度在跨一个设备像素的区间里拉到 0…1。
            const sigma = 1.2 * u;
            const half = 0.5 / (sigma * Math.max(devicePixelRatio || 1, 1 / u));
            const tail = (x) => 0.5 * erfc(x / Math.SQRT2);
            const lo = tail(2.326 + half), hi = tail(2.326 - half);
            blurNode.setAttribute('stdDeviation', String(sigma));
            rampNode.setAttribute('slope', String(1 / (hi - lo)));
            rampNode.setAttribute('intercept', String(-lo / (hi - lo)));
            floodNode.setAttribute('flood-color', style.stroke || 'transparent');
            shownKey = '';
          }
          function currentIndex(t) {
            let found = -1;
            for (let i = 0; i < track.lines.length; i++) { if (track.lines[i].t <= t) found = i; else break; }
            return found;
          }
          // 此刻画什么:前奏、够格的间奏里是「•••」加接下来那句,其余时候是当前句加下一句。
          function resolve(t) {
            const lines = track.lines;
            const idx = currentIndex(t);
            if (idx < 0) return { key: 'g-1', gap: [0, lines[0].t], next: 0 };
            const nextT = idx + 1 < lines.length ? lines[idx + 1].t : Infinity;
            const g = nextT === Infinity ? null : track.gaps.find((g) => g[0] > lines[idx].t && g[0] < nextT && t >= g[0]);
            if (g) return { key: 'g' + idx, gap: [g[0], nextT], next: idx + 1 };
            return { key: 'l' + idx, line: idx, next: idx + 1 < lines.length ? idx + 1 : -1 };
          }
          function color(pct) { return `color-mix(in srgb, var(--sung) ${pct}%, transparent)`; }
          function row(inner, o) {
            return `<div class="row tx${o.cls ? ' ' + o.cls : ''}" data-side="${o.side || ''}" style="font-size:${o.em}em;font-weight:${o.weight};` +
              `color:${o.color};margin-top:${(o.top || 0) * unit()}px"><span class="in${o.cols ? ' cols' : ''}">${inner}</span></div>`;
          }
          function perWord(line) { return !!(style.karaoke && style.roma && line.w && line.g); }
          function wordSpans(ws, fill) {
            return ws.map((w) => fill ? `<span class="w" data-s="${w[0]}" data-d="${w[1]}">${esc(w[2])}</span>` : esc(w[2])).join('');
          }
          // 逐词读音:一组一列,字在上、读音在下;读音按整组起止填色,已唱是前景色 75%,未唱同主行。
          function columns(line, fill, mainEm) {
            const u = unit();
            const readStyle = `font-size:${.65 / mainEm}em;font-weight:${style.weights[1]};margin-top:${(style.spacing[0] - 4) * u}px;` +
              (fill ? '--sung:var(--sung-reading)' : '');
            let i = 0, html = '';
            for (const [n, reading] of line.g) {
              const ws = line.w.slice(i, i + n);
              i += n;
              if (!ws.length) continue;
              const s = ws[0][0], e = ws[ws.length - 1][0] + ws[ws.length - 1][1];
              const r = esc(reading || ' ');
              html += `<span class="col"><span>${wordSpans(ws, fill)}</span>` +
                (fill ? `<span class="w" data-s="${s}" data-d="${Math.max(1, e - s)}" style="${readStyle}">${r}</span>`
                      : `<span style="${readStyle}">${r}</span>`) + '</span>';
            }
            if (i < line.w.length) html += `<span class="col"><span>${wordSpans(line.w.slice(i), fill)}</span></span>`;
            return html;
          }
          function mainRow(line) {
            const opts = { em: 1, weight: style.weights[0], color: 'var(--sung)', side: line.s, cls: 'main' };
            if (perWord(line)) return row(columns(line, true, 1), { ...opts, cols: true });
            return row(style.karaoke && line.w ? wordSpans(line.w, true) : esc(line.text), opts);
          }
          function secondaryRows(line, side, cls) {
            let html = '';
            if (style.roma && line.roma && !perWord(line)) {
              html += row(esc(line.roma), { em: .65, weight: style.weights[1], color: color(60), top: style.spacing[0], side, cls });
            }
            if (style.tr && line.tr) html += row(esc(line.tr), { em: .7, weight: style.weights[2], color: color(75), top: style.spacing[1], side, cls });
            return html;
          }
          function nextRow(next, em, weight, upcoming) {
            const opts = { em, weight, color: color(40), top: style.spacing[2], side: next.s, cls: 'next' };
            if (upcoming && perWord(next)) return row(columns(next, false, em), { ...opts, cols: true });
            return row(esc(next.text), opts);
          }
          function render(v) {
            const lines = track.lines;
            let html = '';
            if (v.gap) {
              html += '<div class="row dots"><i></i><i></i><i></i></div>';
              const up = lines[v.next];
              if (up) {
                if (style.next) html += nextRow(up, 1, style.weights[0], true);
                html += secondaryRows(up, up.s, 'sub');
              }
            } else {
              const line = lines[v.line];
              html += mainRow(line) + secondaryRows(line, line.s, 'sub');
              const next = lines[v.next];
              if (style.next && next) {
                // 下一句换了个人唱时用主行的字号,换过去那一刻不跳。
                const big = style.align === 'automatic' && !!next.s && next.s !== line.s;
                html += nextRow(next, big ? 1 : .7, style.weights[big ? 0 : 3], false);
              }
            }
            card.innerHTML = html;
            layoutRows();
          }
          function sideOf(raw) { return style.align === 'automatic' ? (raw || 'center') : style.align; }
          // 对唱留白照 `OverlayCardGeometry.cardInsets`:左右声部只在近侧留舞台缩进,合唱两侧留;
          // 只占用不到的那部分宽度(`elasticInsetScale`,按整张卡里最宽那一行算一个系数)。
          function insetsOf(raw) {
            if (style.align !== 'automatic' || !raw) return [0, 0];
            const u = unit(), stage = style.duet[0] * u, center = style.duet[1] * u;
            return raw === 'leading' ? [stage, 0] : raw === 'trailing' ? [0, stage] : [center, center];
          }
          function layoutRows() {
            const u = unit();
            const avail = card.clientWidth - 40 * u;
            const scroll = style.overflow === 'scroll';
            const rows = [...card.querySelectorAll(':scope > .row.tx')];
            let widest = 0, total = 0;
            for (const r of rows) {
              widest = Math.max(widest, r.firstElementChild.getBoundingClientRect().width);
              const [l, rr] = insetsOf(r.dataset.side || null);
              total = Math.max(total, l + rr);
            }
            const slack = avail - widest - 2 * u;
            const k = total <= .5 ? 1 : slack > 0 ? Math.min(1, slack / total) : 0;
            for (const r of card.querySelectorAll(':scope > .row')) {
              const raw = r.dataset.side || null;
              if (r.classList.contains('dots')) { r.style.justifyContent = FLEX[sideOf(null)]; continue; }
              const [left, right] = insetsOf(raw);
              const inner = r.firstElementChild;
              const width = inner.getBoundingClientRect().width;
              r.style.paddingLeft = left * k + 'px';
              r.style.paddingRight = right * k + 'px';
              const overflows = scroll && width > r.clientWidth - left * k - right * k + .5;
              r.style.textAlign = overflows ? 'left' : ALIGN[sideOf(raw)];
              if (inner.classList.contains('cols')) inner.style.justifyContent = overflows ? 'flex-start' : FLEX[sideOf(raw)];
              r.dataset.over = overflows ? '1' : '';
            }
          }
          // 换句动画:上一拍的下一句那一格量好位置,新的一句(连同读音、译文)从那里、按那一格的字号和亮度起步走到终点;
          // 旧的一句(连同读音、译文)留一份原地淡完;新的下一句等走上来那句到位、后半程淡入。
          function snapshot() {
            const next = card.querySelector(':scope > .row.next');
            const main = card.querySelector(':scope > .row.main');
            if (!main) return null;
            const ghost = document.createElement('div');
            ghost.className = 'ghost';
            ghost.style.padding = getComputedStyle(card).padding;
            ghost.style.paddingTop = '0px';
            for (const r of card.querySelectorAll(':scope > .row.main, :scope > .row.sub')) ghost.appendChild(r.cloneNode(true));
            return { ghost, mainTop: main.getBoundingClientRect().top, next: next ? next.getBoundingClientRect() : null,
                     nextEm: next ? parseFloat(next.style.fontSize) || .7 : 1 };
          }
          function animateRise(before) {
            const main = card.querySelector(':scope > .row.main');
            if (!main) return;
            // 卡片贴底,换句后高度变了上沿会挪;旧的一句留在它原来在屏幕上的位置。
            before.ghost.style.top = before.mainTop - card.getBoundingClientRect().top - card.clientTop + 'px';
            card.appendChild(before.ghost);
            before.ghost.animate([{ opacity: 1 }, { opacity: 0 }], { duration: RISE.outMs, easing: 'ease-out', fill: 'forwards' })
              .onfinish = () => before.ghost.remove();
            const block = [main, ...card.querySelectorAll(':scope > .row.sub')];
            if (!before.next) {
              for (const r of block) r.animate([{ opacity: 0 }, { opacity: 1 }], { duration: RISE.ms, easing: RISE.ease });
              return;
            }
            const end = main.getBoundingClientRect();
            const side = sideOf(main.dataset.side || null);
            const ax = side === 'leading' ? end.left : side === 'trailing' ? end.right : (end.left + end.right) / 2;
            const bx = side === 'leading' ? before.next.left : side === 'trailing' ? before.next.right : (before.next.left + before.next.right) / 2;
            const s = before.nextEm;
            const dx = bx - ax, dy = before.next.top - end.top;
            const words = !!main.querySelector('.w');
            const startOpacity = style.stroke ? 1 : words ? Math.min(1, RISE.preview / Math.max(.01, alphaOf(style.unsung))) : RISE.preview;
            for (const r of block) {
              r.style.transformOrigin = `${ax - r.getBoundingClientRect().left}px ${end.top - r.getBoundingClientRect().top}px`;
              r.animate([{ transform: `translate(${dx}px, ${dy}px) scale(${s})` }, { transform: 'none' }], { duration: RISE.ms, easing: RISE.ease });
            }
            main.animate([{ opacity: startOpacity }, { opacity: 1 }], { duration: RISE.ms, easing: RISE.ease });
            for (const r of card.querySelectorAll(':scope > .row.sub')) {
              r.animate([{ opacity: 0 }, { opacity: 1 }], { duration: RISE.ms, easing: RISE.ease });
            }
            for (const r of card.querySelectorAll(':scope > .row.next')) {
              r.animate([{ opacity: 0 }, { opacity: 1 }], { duration: RISE.lateMs, delay: RISE.lateDelay, easing: 'ease-out', fill: 'backwards' });
            }
          }
          function tickDots(t) {
            const p = clamp((t - view.gap[0]) / Math.max(1, view.gap[1] - view.gap[0]), 0, 1);
            const phase = (((t % 7000) + 7000) % 7000) / 7000;
            const scale = .9 + .38 * Math.pow(.5 - .5 * Math.cos(2 * Math.PI * phase), 2);
            card.querySelectorAll('.dots > i').forEach((d, i) => {
              d.style.opacity = String(.22 + .78 * clamp(p * 3 - i, 0, 1));
              d.style.transform = `scale(${scale})`;
            });
          }
          // 滚动模式下放不下的行:主行跟着填色走,读音、译文按这一句唱到哪儿匀速挪;下一句不动,从头显示。
          function tickScroll(t, fillX) {
            const line = track.lines[view.line];
            const nextT = view.next >= 0 ? track.lines[view.next].t : line.t + 5000;
            const f = clamp((t - line.t) / Math.max(1, nextT - line.t), 0, 1);
            for (const r of card.querySelectorAll('.row.main, .row.sub')) {
              if (r.dataset.over !== '1') continue;
              const inner = r.firstElementChild;
              const room = r.clientWidth;
              const extra = inner.scrollWidth - room;
              const x = r.classList.contains('main') && fillX !== null ? clamp(fillX - inner.offsetLeft - room / 2, 0, extra) : f * extra;
              inner.style.transform = `translateX(${-x}px)`;
            }
          }
          function tick() {
            lastTick = performance.now();
            const t = now();
            const playing = !!pos && pos.state === 'playing';
            const paused = !!pos && pos.state === 'paused';
            const ready = connected && style && track && track.lines.length > 0;
            box.classList.toggle('on', !!(ready && (playing || (paused && !style.hidePaused))));
            if (!ready) return;
            const previous = view;
            view = resolve(t);
            const key = track.id + '#' + view.key;
            if (key !== shownKey) {
              const rises = style.anim && !reduceMotion.matches && playing && previous && !previous.gap && !view.gap &&
                shownKey.startsWith(track.id + '#') && view.line === previous.line + 1;
              const before = rises ? snapshot() : null;
              shownKey = key;
              render(view);
              if (before) animateRise(before);
            }
            if (view.gap) { tickDots(t); return; }
            let fillX = null;
            for (const w of card.querySelectorAll('.row.main .w')) {
              const s = +w.dataset.s, d = Math.max(1, +w.dataset.d);
              const f = t <= s ? 0 : t >= s + d ? 1 : (t - s) / d;
              const v = (Math.round(f * 1000) / 10) + '%';
              if (w.style.getPropertyValue('--p') !== v) w.style.setProperty('--p', v);
              if (f > 0 && !w.style.fontSize) fillX = w.offsetLeft + f * w.offsetWidth;
            }
            if (style.overflow === 'scroll') tickScroll(t, fillX);
          }
          function connect() {
            const url = new URL('/ws', location.href);
            url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
            const key = new URLSearchParams(location.search).get('k');
            if (key) url.searchParams.set('k', key);
            ws = new WebSocket(url);
            ws.onopen = () => { connected = true; retry = 1000; };
            ws.onmessage = (e) => {
              const m = JSON.parse(e.data);
              if (m.type === 'style') { style = m; applyStyle(); }
              else if (m.type === 'track') { track = m; shownKey = ''; }
              else if (m.type === 'pos') { pos = m; at = performance.now(); }
              else if (m.type === 'hello') checkRevision(m.rev);
            };
            ws.onclose = () => {
              connected = false;
              setTimeout(connect, retry);
              retry = Math.min(retry * 2, 10000);
            };
          }
          addEventListener('resize', applyStyle);
          function frame() { tick(); requestAnimationFrame(frame); }
          requestAnimationFrame(frame);
          setInterval(() => { if (performance.now() - lastTick > 50) tick(); }, 33);
          connect();
        })();
        </script>
        </body>
        </html>
        """
    }

    /// 链接不对时的那一页。
    static func messagePage(_ text: String) -> String {
        """
        <!doctype html>
        <html lang="\(htmlLanguage)">
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Lyrimuse</title>
        <style>html,body{margin:0;height:100%;background:#000;color:rgba(255,255,255,.7);display:flex;align-items:center;
        justify-content:center;font:16px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;text-align:center;padding:0 24px}</style>
        </head><body>\(escapeHTML(text))</body></html>
        """
    }

    private static func jsonStrings(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text.replacingOccurrences(of: "</", with: "<\\/")
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
