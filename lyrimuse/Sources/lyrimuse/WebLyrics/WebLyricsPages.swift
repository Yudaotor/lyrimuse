import Foundation
import LyrimuseCore

/// 网页歌词的两张网页(19 章)。单文件、不连任何 CDN,文字按 App 当前界面语言在服务端填进去。
///
enum WebLyricsPages {
    private static var htmlLanguage: String { UILanguage.localeIdentifier(for: L10n.current) }

    /// 副屏:全屏显示 App 推来的画面帧,尺寸变了就带新尺寸重连。帧在后台线程解码(`createImageBitmap`)后画进画布;
    /// 上一帧还没解完时新来的只留最新一张,解码跟不上也不积压。点画面时把相对位置(`{"tap":[u,v]}`)发回 App,
    /// 点中哪颗键、哪一句由 App 判。
    static func screenPage() -> String {
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
                 touch-action: manipulation; -webkit-tap-highlight-color: transparent; -webkit-user-select: none; user-select: none; }
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
          const key = new URLSearchParams(location.search).get('k') || '';
          const canvas = document.getElementById('frame');
          const ctx = canvas.getContext('2d', { alpha: false });
          const msg = document.getElementById('msg');
          let ws = null, retry = 1000, retryTimer = 0, resizeTimer = 0, decoding = false, pending = null;
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
          function show(blob) {
            if (decoding) { pending = blob; return; }
            decoding = true;
            decode(blob).then((frame) => {
              if (canvas.width !== frame.width || canvas.height !== frame.height) {
                canvas.width = frame.width;
                canvas.height = frame.height;
              }
              ctx.drawImage(frame, 0, 0);
              if (frame.close) frame.close();
              msg.style.display = 'none';
            }, () => {}).then(() => {
              decoding = false;
              if (pending) { const next = pending; pending = null; show(next); }
            });
          }
          function connect() {
            const url = new URL('/ws', location.href);
            url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
            if (key) url.searchParams.set('k', key);
            url.searchParams.set('w', Math.round(innerWidth));
            url.searchParams.set('h', Math.round(innerHeight));
            url.searchParams.set('dpr', Math.max(1, Math.min(3, devicePixelRatio || 1)).toFixed(2));
            const socket = new WebSocket(url);
            ws = socket;
            socket.binaryType = 'blob';
            socket.onopen = () => { retry = 1000; };
            socket.onmessage = (e) => {
              if (typeof e.data === 'string') return;
              show(e.data);
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
          canvas.addEventListener('click', (e) => {
            if (!ws || ws.readyState !== 1 || !canvas.width) return;
            const r = canvas.getBoundingClientRect();
            const k = Math.min(r.width / canvas.width, r.height / canvas.height);
            const w = canvas.width * k, h = canvas.height * k;
            const u = (e.clientX - r.left - (r.width - w) / 2) / w;
            const v = (e.clientY - r.top - (r.height - h) / 2) / h;
            if (u < 0 || u > 1 || v < 0 || v > 1) return;
            ws.send(JSON.stringify({ tap: [u, v] }));
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

    /// OBS 浏览器源:透明背景,底部一行当前句(读音、译文按悬浮歌词的开关),逐字填色。不在播放、间奏、断线时淡出。
    /// 逐字填色跟着 `requestAnimationFrame` 刷;OBS 窗口不在前台时浏览器源里的 rAF 可能被挂起,另有定时器在 rAF 停了时接着刷。
    static func obsPage() -> String {
        """
        <!doctype html>
        <html lang="\(htmlLanguage)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Lyrimuse</title>
        <style>
        html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; }
        #box { position: fixed; left: 4%; right: 4%; bottom: 6%; display: flex; justify-content: center;
               opacity: 0; transition: opacity .4s ease; }
        #box.on { opacity: 1; }
        #card { display: inline-block; max-width: 100%; text-align: center; border-radius: .45em; }
        #card.filled { padding: .35em .8em; }
        .roma { opacity: .85; margin-bottom: .15em; }
        .tr { opacity: .9; margin-top: .25em; }
        .stack { display: inline-grid; line-height: 1.25; }
        .stack > span { grid-area: 1 / 1; white-space: pre-wrap; }
        .w { -webkit-background-clip: text; background-clip: text; color: transparent;
             background-image: linear-gradient(90deg, var(--sung) 0, var(--sung) var(--p, 0%), var(--unsung) var(--p, 0%), var(--unsung) 100%); }
        </style>
        </head>
        <body>
        <div id="box"><div id="card"></div></div>
        <script>
        (() => {
          const box = document.getElementById('box');
          const card = document.getElementById('card');
          let style = null, track = null, pos = null, at = 0, shownKey = '', connected = false, lastTick = 0;
          let ws = null, retry = 1000;
          const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
          function now() {
            if (!pos) return 0;
            return pos.pos + (pos.state === 'playing' ? (performance.now() - at) * (pos.rate || 1) : 0);
          }
          function px() { return style ? style.size * innerWidth / 1200 : 40; }
          function applyStyle() {
            if (!style) return;
            const family = style.font ? `"${style.font}", ` : '';
            card.style.fontFamily = family + '-apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans", sans-serif';
            card.style.fontSize = px() + 'px';
            card.style.fontWeight = style.weight;
            card.style.setProperty('--sung', style.sung);
            card.style.setProperty('--unsung', style.unsung);
            card.style.color = style.sung;
            const blur = Math.max(1, px() / 40 * 1.2);
            card.style.filter = style.stroke
              ? `drop-shadow(0 0 ${blur}px ${style.stroke}) drop-shadow(0 0 ${blur}px ${style.stroke})` : 'none';
            card.style.background = style.card || 'transparent';
            card.classList.toggle('filled', !!style.card);
            shownKey = '';
          }
          function currentIndex(t) {
            if (!track) return -1;
            let found = -1;
            for (let i = 0; i < track.lines.length; i++) { if (track.lines[i].t <= t) found = i; else break; }
            return found;
          }
          function inGap(t) { return !!(track && track.gaps.some((g) => t >= g[0] && t < g[1])); }
          function lineHTML(line) {
            const words = line.w ? line.w.map((w) => `<span class="w" data-s="${w[0]}" data-d="${w[1]}">${esc(w[2])}</span>`).join('')
              : `<span>${esc(line.text)}</span>`;
            let html = '';
            if (style && style.roma && line.roma) html += `<div class="roma" style="font-size:.42em">${esc(line.roma)}</div>`;
            html += `<div><span class="stack"><span>${words}</span></span></div>`;
            if (style && style.tr && line.tr) html += `<div class="tr" style="font-size:.55em">${esc(line.tr)}</div>`;
            return html;
          }
          function tick() {
            lastTick = performance.now();
            const t = now();
            const idx = currentIndex(t);
            const visible = connected && pos && pos.state === 'playing' && idx >= 0 && !inGap(t);
            box.classList.toggle('on', !!visible);
            if (idx < 0 || !track) return;
            const key = track.id + '#' + idx;
            if (key !== shownKey) { shownKey = key; card.innerHTML = lineHTML(track.lines[idx]); }
            for (const w of card.querySelectorAll('.w')) {
              const s = +w.dataset.s, d = Math.max(1, +w.dataset.d);
              const f = t <= s ? 0 : t >= s + d ? 1 : (t - s) / d;
              const v = (Math.round(f * 1000) / 10) + '%';
              if (w.style.getPropertyValue('--p') !== v) w.style.setProperty('--p', v);
            }
          }
          function connect() {
            const url = new URL('/ws', location.href);
            url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
            url.searchParams.set('obs', '1');
            const key = new URLSearchParams(location.search).get('k');
            if (key) url.searchParams.set('k', key);
            ws = new WebSocket(url);
            ws.onopen = () => { connected = true; retry = 1000; };
            ws.onmessage = (e) => {
              const m = JSON.parse(e.data);
              if (m.type === 'style') { style = m; applyStyle(); }
              else if (m.type === 'track') { track = m; shownKey = ''; }
              else if (m.type === 'pos') { pos = m; at = performance.now(); }
            };
            ws.onclose = () => {
              connected = false;
              setTimeout(connect, retry);
              retry = Math.min(retry * 2, 10000);
            };
          }
          addEventListener('resize', () => { if (style) card.style.fontSize = px() + 'px'; });
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
