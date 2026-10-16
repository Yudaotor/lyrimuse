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
    /// 后面是 JPEG。帧在后台线程解码(`createImageBitmap`)后排队,`requestAnimationFrame`(它停了时由定时器接着)每一拍按画它的时刻晚
    /// `DELAY` 毫秒放出来:网络和解码的快慢不均被这段余量吸掉,画面照 App 画的间隔匀速走。解码跟不上时新来的直接丢,
    /// 不积压。手指按下、拖动、抬起都把画面上的相对位置(`{"ptr":["d",u,v]}`)发回 App,点中什么、拖的是什么由 App 判;
    /// 拖动 16ms 最多发一次,发送缓冲里还压着东西时不再发。菜单里平台页那几行的位置由 App 发来(`links`),
    /// 网页在手指抬起那一刻自己开链接。
    static func screenPage(revision: String = revision) -> String {
        let strings = jsonStrings([
            "connecting": L10n.t("正在连接 Lyrimuse…"),
            "reconnecting": L10n.t("连接已断开，正在重连…"),
        ])
        return """
        <!doctype html>
        <html lang="\(htmlLanguage)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="mobile-web-app-capable" content="yes">
        <meta name="theme-color" content="#000000">
        <title>Lyrimuse</title>
        <style>
        html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
        canvas { position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; object-fit: contain; display: block;
                 touch-action: none; -webkit-tap-highlight-color: transparent; -webkit-user-select: none; user-select: none; }
        #msg { position: fixed; top: 0; right: 0; bottom: 0; left: 0; display: flex; align-items: center; justify-content: center;
               color: rgba(255,255,255,.55); font: 15px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; }
        </style>
        </head>
        <body>
        <canvas id="frame" width="0" height="0"></canvas>
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
          const DELAY = 40;
          let ws = null, retry = 1000, retryTimer = 0, resizeTimer = 0;
          let queue = [], decoding = 0, offset = Infinity, lastShown = -Infinity, lastFrame = 0;
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
          function receive(buffer) {
            if (buffer.byteLength <= 8) return;
            const t = new DataView(buffer).getFloat64(0);
            // 两边时钟之差加最短路上的延迟:取见过的最小值,再慢慢往上松,网络路径变慢了也跟得上
            const lag = performance.now() - t;
            offset = lag < offset ? lag : offset + (lag - offset) * 0.002;
            if (decoding >= 3) return;
            decoding++;
            decode(new Blob([new Uint8Array(buffer, 8)], { type: 'image/jpeg' })).then((frame) => {
              const item = { t, frame };
              if (t <= lastShown) { release(item); return; }
              queue.push(item);
              queue.sort((a, b) => a.t - b.t);
              while (queue.length > 8) release(queue.shift());
            }, () => {}).then(() => { decoding--; });
          }
          function present() {
            const now = performance.now();
            let pick = -1;
            for (let i = 0; i < queue.length && queue[i].t + offset + DELAY <= now; i++) pick = i;
            if (pick < 0) return;
            for (let i = 0; i < pick; i++) release(queue[i]);
            const item = queue[pick];
            queue = queue.slice(pick + 1);
            lastShown = item.t;
            if (canvas.width !== item.frame.width || canvas.height !== item.frame.height) {
              canvas.width = item.frame.width;
              canvas.height = item.frame.height;
            }
            ctx.drawImage(item.frame, 0, 0);
            release(item);
            msg.style.display = 'none';
          }
          function frame() { lastFrame = performance.now(); present(); requestAnimationFrame(frame); }
          requestAnimationFrame(frame);
          // 浏览器不把这页当成在显示时(从别的 App 打开的小窗、不在前台的标签页)rAF 可能一直不来:停了 50ms 以上就由定时器接着放
          setInterval(() => { if (performance.now() - lastFrame > 50) present(); }, 16);
          function connect() {
            const url = new URL('/ws', location.href);
            url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
            if (key) url.searchParams.set('k', key);
            url.searchParams.set('w', Math.round(innerWidth));
            url.searchParams.set('h', Math.round(innerHeight));
            url.searchParams.set('dpr', Math.max(1, Math.min(3, devicePixelRatio || 1)).toFixed(2));
            const socket = new WebSocket(url);
            ws = socket;
            socket.binaryType = 'arraybuffer';
            socket.onopen = () => { retry = 1000; };
            socket.onmessage = (e) => {
              if (typeof e.data === 'string') {
                try {
                  const m = JSON.parse(e.data);
                  if (m.type === 'hello') checkRevision(m.rev);
                  else if (m.type === 'links') links = m.items;
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
          canvas.addEventListener('pointerdown', (e) => {
            if (pointerId !== null || !canvas.width) return;
            const [u, v] = where(e);
            if (u < 0 || u > 1 || v < 0 || v > 1) return;
            pointerId = e.pointerId;
            downLink = linkAt(u, v);
            try { canvas.setPointerCapture(e.pointerId); } catch (err) {}
            sendPointer('d', e);
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
          });
          canvas.addEventListener('pointerup', (e) => {
            if (e.pointerId !== pointerId) return;
            pointerId = null;
            const [u, v] = where(e);
            if (downLink && linkAt(u, v) === downLink) window.open(downLink, '_blank', 'noopener');
            downLink = null;
            sendPointer('u', e);
          });
          canvas.addEventListener('pointercancel', (e) => {
            if (e.pointerId !== pointerId) return;
            pointerId = null;
            sendPointer('c', e);
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
