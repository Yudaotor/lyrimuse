// Cloudflare Worker: live "now playing" SVG badge for a GitHub README.
//
// GET /badge → an SVG card built from the self-hosted relay (np.yudaotor.me/now,
//   which itself falls back to ListenBrainz). Album art is inlined as a data: URI
//   (so GitHub's camo proxy can serve it), accent-colored, with a 💻/📱 device
//   glyph, a progress bar and animated EQ bars (SMIL) that advance while playing.
//
//   Note on animation: GitHub's camo caches the image and usually renders a static
//   snapshot, so the moving progress/EQ shows when the badge URL is opened directly;
//   inside a README it's a fresh snapshot on each camo refresh (still shows the
//   current progress %, cover, device — just not moving).
//
// Embed in README:  ![now playing](https://<worker>.workers.dev/badge)
//
// Env (wrangler.toml [vars]): RELAY_URL (default https://np.yudaotor.me).
const RELAY_DEFAULT = "https://np.yudaotor.me";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/badge" && url.pathname !== "/") {
      return new Response("not found", { status: 404 });
    }
    const relay = (env && env.RELAY_URL) || RELAY_DEFAULT;
    let snap = null;
    try { snap = await getNowPlaying(relay); } catch (e) { /* fall through to idle card */ }
    const svg = await buildSVG(snap);
    return new Response(svg, {
      headers: {
        "content-type": "image/svg+xml; charset=utf-8",
        // Best-effort freshness; GitHub's camo still caches, so updates lag a bit.
        "cache-control": "no-cache, no-store, max-age=0, must-revalidate",
      },
    });
  },
};

function num(v) { return typeof v === "number" ? v : null; }

// Read the self-hosted relay (which already falls back to LB when its KV is empty).
async function getNowPlaying(relay) {
  const d = await fetchJSON(`${relay.replace(/\/$/, "")}/now`);
  if (!d || !d.ok || d.empty || !d.title) return null;
  return {
    title: d.title || "", artist: d.artist || "", album: d.album || "",
    cover: d.artwork || "", accent: d.accent || "", source: d.device || "",
    playing: !!d.playing,
    durationMs: num(d.durationMs), progressMs: num(d.progressMs),
    progressTs: num(d.progressTs), rate: num(d.rate), ageMs: num(d.ageMs),
  };
}

async function fetchJSON(u) {
  const r = await fetch(u, { headers: { "user-agent": "nowplaying-badge" }, signal: AbortSignal.timeout(3000) });
  if (!r.ok) throw new Error(`${u} -> ${r.status}`);
  return r.json();
}

// Current playback fraction [0,1], extrapolated from the anchor the same way the
// web page does (progress_ms + age*rate). ageMs is server-computed (clock-safe).
export function progressFrac(snap) {
  if (!(snap.durationMs > 0) || snap.progressMs == null) return null;
  let pos = snap.progressMs;
  const age = snap.ageMs != null ? snap.ageMs : (snap.progressTs != null ? Date.now() - snap.progressTs : 0);
  if (snap.playing && snap.rate > 0 && age > 0) pos += age * snap.rate;
  pos = Math.max(0, Math.min(snap.durationMs, pos));
  return { frac: pos / snap.durationMs, remainMs: Math.max(0, snap.durationMs - pos) };
}

// Fetch a small cover and inline it as a data: URI so the SVG is self-contained.
async function coverDataURI(coverUrl) {
  if (!coverUrl) return "";
  try {
    const small = coverUrl.includes("music.126.net") || coverUrl.includes("music.127.net")
      ? coverUrl.split("?")[0] + "?param=130y130" : coverUrl;
    const r = await fetch(small, {
      headers: { referer: "https://music.163.com/", "user-agent": "Mozilla/5.0" },
      signal: AbortSignal.timeout(2500),
    });
    if (!r.ok) return "";
    const buf = await r.arrayBuffer();
    if (buf.byteLength > 200000) return ""; // guard oversized
    const ok = /^image\/(png|jpe?g|gif|webp)$/.test(r.headers.get("content-type") || "");
    const ct = ok ? r.headers.get("content-type") : "image/jpeg";
    let bin = ""; const bytes = new Uint8Array(buf);
    for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return `data:${ct};base64,${btoa(bin)}`;
  } catch (e) { return ""; }
}

function esc(s) {
  return String(s || "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
function clip(s, n) { s = String(s || ""); return s.length > n ? s.slice(0, n - 1) + "…" : s; }

export async function buildSVG(snap) {
  const W = 400, H = 120;
  if (!snap || !snap.title) {
    return card({ W, H, accent: "#5b6472", cover: "", statusText: "🎧 这会儿没在听歌", title: "—", artist: "", playing: false, prog: null });
  }
  const accent = /^#[0-9a-fA-F]{6}$/.test(snap.accent) ? snap.accent : "#8a5cff";
  const dev = snap.source === "iphone" ? "📱" : snap.source === "mac" ? "💻" : "";
  const statusText = (snap.playing ? "正在播放" : "上次播放") + (dev ? " " + dev : "");
  const cover = await coverDataURI(snap.cover);
  return card({ W, H, accent, cover, statusText, title: snap.title, artist: snap.artist, playing: snap.playing, prog: progressFrac(snap) });
}

function card({ W, H, accent, cover, statusText, title, artist, playing, prog }) {
  const pad = 16, art = 88, tx = pad + art + 16; // 120
  const coverEl = cover
    ? `<image x="${pad}" y="${pad}" width="${art}" height="${art}" href="${cover}" clip-path="url(#r)"/>`
    : `<rect x="${pad}" y="${pad}" width="${art}" height="${art}" rx="12" fill="#2b2f3a"/>`;

  // EQ 三条:播放时 SMIL 跳动,暂停静止(camo 缓存下退化为静态首帧)。
  const eqY = pad + 2, eqH = 12;
  const eq = [0, 1, 2].map((i) => {
    const x = tx + i * 6;
    if (playing) {
      const dur = [0.7, 0.5, 0.9][i], a = [10, 4, 8][i], b = [3, 12, 5][i];
      return `<rect x="${x}" width="3" rx="1.5" fill="${accent}" y="${eqY + eqH - a}" height="${a}">`
        + `<animate attributeName="height" values="${a};${b};${a}" dur="${dur}s" repeatCount="indefinite"/>`
        + `<animate attributeName="y" values="${eqY + eqH - a};${eqY + eqH - b};${eqY + eqH - a}" dur="${dur}s" repeatCount="indefinite"/></rect>`;
    }
    return `<rect x="${x}" y="${eqY + eqH - 4}" width="3" height="4" rx="1.5" fill="${accent}" opacity="0.55"/>`;
  }).join("");
  const stx = tx + 3 * 6 + 8;

  // 标题:过长则在裁剪窗口内 marquee 横向滚动。
  const ty = pad + 46, maxTitle = 22;
  let titleEl;
  if (title.length > maxTitle) {
    const dbl = esc(title) + "   " + esc(title);
    const shift = (title.length + 3) * 15;
    titleEl = `<g clip-path="url(#tc)"><text x="${tx}" y="${ty}" fill="#f2f4f7" font-size="17" font-weight="700">${dbl}`
      + `<animateTransform attributeName="transform" type="translate" from="0 0" to="-${shift} 0" dur="${Math.max(8, Math.round(title.length * 0.45))}s" repeatCount="indefinite"/></text></g>`;
  } else {
    titleEl = `<text x="${tx}" y="${ty}" fill="#f2f4f7" font-size="17" font-weight="700">${esc(title)}</text>`;
  }

  // 进度条:静态显示当前比例;播放时 SMIL 让填充随剩余时间前进到满。
  const barY = H - 20, barW = W - tx - pad, barH = 5;
  let progEl = "";
  if (prog) {
    const fillW = Math.max(2, Math.round(prog.frac * barW));
    const advance = playing && prog.remainMs > 1500
      ? `<animate attributeName="width" from="${fillW}" to="${barW}" dur="${Math.round(prog.remainMs / 1000)}s" fill="freeze"/>` : "";
    progEl = `<rect x="${tx}" y="${barY}" width="${barW}" height="${barH}" rx="2.5" fill="#2b2f3a"/>`
      + `<rect x="${tx}" y="${barY}" width="${fillW}" height="${barH}" rx="2.5" fill="${accent}">${advance}</rect>`;
  }

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" font-family="-apple-system,'Segoe UI',Roboto,'PingFang SC','Microsoft YaHei',sans-serif">
  <defs>
    <clipPath id="r"><rect x="${pad}" y="${pad}" width="${art}" height="${art}" rx="12"/></clipPath>
    <clipPath id="tc"><rect x="${tx - 2}" y="${pad + 30}" width="${barW + 4}" height="24"/></clipPath>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#171a22"/><stop offset="1" stop-color="#0d0f14"/>
    </linearGradient>
  </defs>
  <rect width="${W}" height="${H}" rx="18" fill="url(#bg)"/>
  <rect x="0.5" y="0.5" width="${W - 1}" height="${H - 1}" rx="17.5" fill="none" stroke="${accent}" stroke-opacity="0.35"/>
  ${coverEl}
  ${eq}
  <text x="${stx}" y="${pad + 11}" fill="${accent}" font-size="12" font-weight="700">${esc(statusText)}</text>
  ${titleEl}
  <text x="${tx}" y="${pad + 68}" fill="#c8cdd6" font-size="13">${esc(clip(artist, 30))}</text>
  ${progEl}
</svg>`;
}
