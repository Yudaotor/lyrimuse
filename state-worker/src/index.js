// Cloudflare Worker: 自建的 now-playing 状态中继(取代 ListenBrainz 作主仓库)。
//
// 采集器把富数据(封面/主色/歌词/进度/链接/设备/时长)推到这里,网页只读这里。
// LB 只在 KV 为空时兜底(比如采集器刚启动还没推),不再是主依赖。
//
//   POST /push       body=完整状态 JSON,需 x-token == PUSH_TOKEN → 写 KV "current"
//   GET  /now        → 读 "current"(空/过期则兜底 LB playing-now)
//   GET  /history    → 读 "history"(空则兜底 LB listens)
//
// Env: PUSH_TOKEN(secret,采集器共享)、LB_USER(兜底用)。KV 绑定名 NP_STATE。
//
// 历史上还有一个 POST /scrobble(把完成收听追加进 KV "history"),但采集器早已改为完成
// 收听只双写 LB(不耗 KV 写额度)、/history 也只读 LB 合并——/scrobble 从未再被调用、是
// 死代码,且仍会接受认证写入,已删除。
//
// ---- 访客互动(2026-07-12 新增)----
// 这是本项目第一批"匿名公开写"接口(此前唯一的写接口 /push 靠机器对机器的共享密钥保护,
// 浏览器没法安全持有那种密钥)。防刷用两层:①按 hash 过的访客 IP 做每接口独立的冷却期
// (POST /visit 1h、/comments 20s、/reactions 3s,命中冷却期直接 429);②一个全局每日写入
// 预算护栏(budget:writes:<日期>,上限 400/天),专门保护本来就紧张的 KV 免费写额度不被
// 这三个新接口挤占,一旦超限新接口 503,不影响 /push 和只读接口。两层都是 KV 上的"尽力
// 而为"计数(KV 没有原子自增),失败方向是安全的(宁可提前拒绝,不会放过量)。
//
//   POST /visit                     → visits:total 计数 +1,返回 {total}(前端靠 localStorage
//                                      去重,同一浏览器只在"从未访问过"时才发这个 POST)
//   GET  /visit                     → 只读 visits:total,不占预算/不触发限流
//   GET  /comments                  → 读 comments:list(最新在前,最多 50 条)
//   POST /comments {name?, text}    → 追加一条留言,超 50 条丢最旧;text 必填 1-200 字,
//                                      name 选填 0-20 字(默认"匿名")。存储时只做控制字符
//                                      清理,不做 HTML 转义——前端全程用 textContent 渲染,
//                                      转义后再 textContent 反而会把 &lt; 这类符号原样显示
//                                      给所有人看,是错的;textContent 本身就是 XSS 防线。
//   POST /comments/delete {id}      → 需 x-admin-token == ADMIN_TOKEN(区别于 /push 用的
//                                      PUSH_TOKEN——那个给采集器机器用,这个只给站长本人手动
//                                      curl 删违规留言用),无 UI。
//   GET  /reactions                 → 读全站统一的表情计数 {counts:{emoji:n,...}}——最初
//                                      设计成按"当前播放的歌曲"分开计数,上线当天用户反馈
//                                      预期跟留言墙一样是全站统一一份,改成单一 key。
//   POST /reactions {emoji}         → 给某个表情 +1;emoji 必须在服务端固定白名单里。
//
// Env 新增: ADMIN_TOKEN(secret,仅站长本人用于删除留言)。
const LB_API = "https://api.listenbrainz.org";
const CUR_KEY = "current";
const STALE_MS = 5 * 60 * 1000; // current 超过 5 分钟没更新 → 视为过期,转 LB 兜底。调短:KV 写配额爆时(采集器 /push 全 503、心跳也写不进)冻结的 KV 能更快退回 LB 显示当前在放,而非卡到 20 分钟。代价:正常期长歌/长暂停(> 5min 无 KV 更新)也会更早退 LB(LB 有同曲 playing_now、略糙)。彻底解法是 KV 别再爆(减写/付费)。
const HIST_MAX = 200;

const VISITS_KEY = "visits:total";
const COMMENTS_KEY = "comments:list";
const COMMENTS_MAX = 50;
const REACTIONS_KEY = "reactions:global"; // 全站统一一份,不跟哪首歌绑定(跟留言墙一样)
const REACTION_EMOJI = ["❤️", "🔥", "👍", "🎉", "😮", "😢"];
const WRITE_BUDGET_CAP = 400; // 每日"新写"接口(访客计数/留言/表情)预算上限,留够 /push 的额度
const RL_TTL = { visit: 3600, comment: 20, react: 3 }; // 各接口按 IP 的冷却期(秒)

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, x-token, x-admin-token",
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const kv = env.NP_STATE || null;

    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

    // ---- 写入(采集器)----
    if (request.method === "POST" && url.pathname === "/push") {
      if (!env.PUSH_TOKEN || request.headers.get("x-token") !== env.PUSH_TOKEN) {
        return json({ ok: false, error: "unauthorized" }, 401);
      }
      if (!kv) return json({ ok: false, error: "no kv" }, 500);
      let body;
      try { body = await request.json(); } catch { return json({ ok: false, error: "bad json" }, 400); }

      // KV 免费版 1000 写/天:写满时 kv.put 抛异常。捕获返回 503(而非未捕获抛出→CF 1101),
      // 便于诊断;此时 /now 退回 LB 兜底(不耗写额度),歌词/进度/封面仍由 LB playing_now 提供。
      try {
        await kv.put(CUR_KEY, JSON.stringify({ ...body, at: Date.now() }));
      } catch (e) {
        return json({ ok: false, error: "kv write failed (quota?)", detail: String(e) }, 503);
      }
      return json({ ok: true });
    }

    // ---- 读取(网页)----
    if (url.pathname === "/now") {
      // 加 ageMs = 服务器侧算出的锚点真实年龄(Cloudflare 时钟,NTP 准)。网页据此 +
      // 本设备时钟相对差外推,不依赖查看设备的绝对时钟,消除跨设备时钟偏差导致的进度错位。
      const stamp = (o) => { if (o && typeof o.progressTs === "number") o.ageMs = Date.now() - o.progressTs; return o; };
      if (kv) {
        try {
          const rec = await kv.get(CUR_KEY, { type: "json" });
          if (rec && rec.at && Date.now() - rec.at < STALE_MS && (rec.title || rec.empty)) {
            return json(stamp({ ...rec, source: "kv" }));
          }
        } catch (e) { /* 转兜底 */ }
      }
      try { return json(stamp({ ...(await lbNow(env)), source: "lb" })); }
      catch (e) { return json({ ok: false, empty: true, source: "lb", error: String(e) }); }
    }

    if (url.pathname === "/history") {
      // 历史只读 LB:采集器每条完成收听都双写 LB(single),LB 走 HTTP、不受 KV 写额度影响。
      // 采集器已不再写 KV /scrobble(省写额度),旧的 KV 历史是冻结的陈旧数据且无 device 标,
      // 故不再合并它——只用 LB,每条都带 device(mac/iphone)且始终最新。
      // lbHistory 失败(LB 挂/超时)此前会被 .catch(()=>[]) 悄悄吞掉,返回体跟"真的没有
      // 历史"长得一模一样——跟 /now 显式带 error 字段的处理方式不一致,出问题时无从
      // 分辨。这里也加 console.error(供 wrangler tail 排查)+ 在响应里带上 error 字段,
      // 但仍返回 ok:true + 已有的空数组,不改变前端行为。
      let lbHist = [];
      let histErr = null;
      try {
        lbHist = await lbHistory(env);
      } catch (e) {
        histErr = String(e);
        console.error("history: lbHistory failed:", histErr);
      }
      const seen = new Set(), merged = [];
      for (const x of lbHist) {
        if (!x || !x.title) continue;
        const k = `${x.artist}|${x.title}|${x.listenedAt}`;
        if (seen.has(k)) continue;
        seen.add(k);
        merged.push(x);
      }
      merged.sort((a, b) => (b.listenedAt || 0) - (a.listenedAt || 0));
      const resp = { ok: true, items: merged.slice(0, HIST_MAX), source: "lb" };
      if (histErr) resp.error = histErr;
      return json(resp);
    }

    // ---- 访客互动:计数/留言/表情反应(见文件头注释)----
    if (url.pathname === "/visit") {
      if (!kv) return json({ ok: false, error: "no kv" }, 500);
      if (request.method === "POST") {
        const hash = await ipHash(request);
        if (!(await checkRateLimit(kv, "visit", hash, RL_TTL.visit))) {
          return json({ ok: false, error: "too many requests" }, 429);
        }
        if (!(await checkWriteBudget(kv))) {
          return json({ ok: false, error: "今日写入配额已用完,请明天再来" }, 503);
        }
        const cur = parseInt((await kv.get(VISITS_KEY)) || "0", 10);
        const total = cur + 1;
        try { await kv.put(VISITS_KEY, String(total)); }
        catch (e) { return json({ ok: false, error: "kv write failed", detail: String(e) }, 503); }
        return json({ ok: true, total });
      }
      const total = parseInt((await kv.get(VISITS_KEY)) || "0", 10);
      return json({ ok: true, total });
    }

    if (url.pathname === "/comments" && request.method !== "POST") {
      if (!kv) return json({ ok: true, items: [] });
      const items = (await kv.get(COMMENTS_KEY, { type: "json" })) || [];
      return json({ ok: true, items });
    }

    if (url.pathname === "/comments" && request.method === "POST") {
      if (!kv) return json({ ok: false, error: "no kv" }, 500);
      let body;
      try { body = await request.json(); } catch { return json({ ok: false, error: "bad json" }, 400); }
      const text = sanitizeText(body.text, 200);
      const name = sanitizeText(body.name, 20) || "匿名";
      if (!text) return json({ ok: false, error: "text required" }, 400);

      const hash = await ipHash(request);
      if (!(await checkRateLimit(kv, "comment", hash, RL_TTL.comment))) {
        return json({ ok: false, error: "too many requests" }, 429);
      }
      if (!(await checkWriteBudget(kv))) {
        return json({ ok: false, error: "今日写入配额已用完,请明天再来" }, 503);
      }
      const items = (await kv.get(COMMENTS_KEY, { type: "json" })) || [];
      items.unshift({ id: crypto.randomUUID(), name, text, at: Date.now() });
      const trimmed = items.slice(0, COMMENTS_MAX);
      try { await kv.put(COMMENTS_KEY, JSON.stringify(trimmed)); }
      catch (e) { return json({ ok: false, error: "kv write failed", detail: String(e) }, 503); }
      return json({ ok: true, items: trimmed });
    }

    if (url.pathname === "/comments/delete" && request.method === "POST") {
      if (!env.ADMIN_TOKEN || request.headers.get("x-admin-token") !== env.ADMIN_TOKEN) {
        return json({ ok: false, error: "unauthorized" }, 401);
      }
      if (!kv) return json({ ok: false, error: "no kv" }, 500);
      let body;
      try { body = await request.json(); } catch { return json({ ok: false, error: "bad json" }, 400); }
      const items = (await kv.get(COMMENTS_KEY, { type: "json" })) || [];
      const idx = items.findIndex((c) => c.id === body.id);
      if (idx === -1) return json({ ok: false, error: "not found" }, 404);
      items.splice(idx, 1);
      try { await kv.put(COMMENTS_KEY, JSON.stringify(items)); }
      catch (e) { return json({ ok: false, error: "kv write failed", detail: String(e) }, 503); }
      return json({ ok: true, items });
    }

    // 表情反应是全局的(跟留言墙一样,不跟哪首歌绑定)——2026-07-12 上线时最初设计成按
    // "当前播放的歌曲"分开计数,用户反馈预期跟留言一样是全站统一一份,当天改成单一
    // REACTIONS_KEY,不再要 key 参数。
    if (url.pathname === "/reactions" && request.method !== "POST") {
      if (!kv) return json({ ok: true, counts: {} });
      const counts = (await kv.get(REACTIONS_KEY, { type: "json" })) || {};
      return json({ ok: true, counts });
    }

    if (url.pathname === "/reactions" && request.method === "POST") {
      if (!kv) return json({ ok: false, error: "no kv" }, 500);
      let body;
      try { body = await request.json(); } catch { return json({ ok: false, error: "bad json" }, 400); }
      const emoji = body.emoji;
      if (!REACTION_EMOJI.includes(emoji)) return json({ ok: false, error: "bad emoji" }, 400);

      const hash = await ipHash(request);
      if (!(await checkRateLimit(kv, "react", hash, RL_TTL.react))) {
        return json({ ok: false, error: "too many requests" }, 429);
      }
      if (!(await checkWriteBudget(kv))) {
        return json({ ok: false, error: "今日写入配额已用完,请明天再来" }, 503);
      }
      const counts = (await kv.get(REACTIONS_KEY, { type: "json" })) || {};
      counts[emoji] = (counts[emoji] || 0) + 1;
      try { await kv.put(REACTIONS_KEY, JSON.stringify(counts)); }
      catch (e) { return json({ ok: false, error: "kv write failed", detail: String(e) }, 503); }
      return json({ ok: true, counts });
    }

    // ---- 社交解链:把固定链接粘到 Slack/Discord/微信/X 等,不点也能看到当前在听 ----
    // /cover:代理当前封面(带 referer 取网易云),给 unfurler 当 og:image(它抓不到需 referer 的原图)。
    if (url.pathname === "/cover") {
      let art = "", haveFresh = false;
      try {
        const rec = kv ? await kv.get(CUR_KEY, { type: "json" }) : null;
        if (rec && rec.at && Date.now() - rec.at < STALE_MS) { haveFresh = true; art = rec.artwork || ""; }
      } catch (e) { /* 转兜底 */ }
      // 仅 KV 缺失/过期才去 LB 兜底;KV 新鲜但无封面(空闲态)直接 404,不追陈旧封面。
      if (!art && !haveFresh) { try { art = (await lbNow(env)).artwork || ""; } catch (e) { /* ignore */ } }
      if (!art) return new Response("no cover", { status: 404, headers: CORS });
      try {
        const small = (art.includes("music.126.net") || art.includes("music.127.net"))
          ? art.split("?")[0] + "?param=600y600" : art;
        const r = await fetch(small, {
          headers: { referer: "https://music.163.com/", "user-agent": "Mozilla/5.0" },
          signal: AbortSignal.timeout(3000),
        });
        if (!r.ok) return new Response("bad cover", { status: 502, headers: CORS });
        const ctype = /^image\//.test(r.headers.get("content-type") || "") ? r.headers.get("content-type") : "image/jpeg";
        return new Response(r.body, {
          headers: { "content-type": ctype, "cache-control": "public, max-age=60", "access-control-allow-origin": "*" },
        });
      } catch (e) { return new Response("cover error", { status: 502, headers: CORS }); }
    }

    // /share:返回带"动态 og 标签"的 HTML —— unfurler 读 head 显示当前歌名/歌手/封面;
    // 人点开则跳转到真正的展示页。这样一个固定链接到处粘,都能看到此刻在听什么。
    if (url.pathname === "/share") {
      let rec = null;
      try { rec = kv ? await kv.get(CUR_KEY, { type: "json" }) : null; } catch (e) { /* 转兜底 */ }
      if (!rec || !rec.at || Date.now() - rec.at >= STALE_MS || (!rec.title && !rec.empty)) {
        try { rec = await lbNow(env); } catch (e) { rec = null; }
      }
      const has = !!(rec && rec.title);
      const playing = has && !!rec.playing;
      const title = has ? rec.title : "";
      const artist = has ? (rec.artist || "") : "";
      const album = has ? (rec.album || "") : "";
      const ogTitle = has ? `${playing ? "♪ 正在听" : "🎧 最近在听"}：${title}${artist ? " — " + artist : ""}` : "正在听什么 ♪";
      const ogDesc = has ? (album ? `专辑《${album}》 · via Apple Music` : "via Apple Music") : "看看我此刻在听的歌";
      const page = "https://yudaotor.github.io/nowplaying/?user=yudaotor";
      const img = `${url.origin}/cover`;
      const h = (v) => String(v || "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
      const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${h(ogTitle)}</title>
<meta property="og:type" content="music.song">
<meta property="og:site_name" content="正在听什么 ♪">
<meta property="og:title" content="${h(ogTitle)}">
<meta property="og:description" content="${h(ogDesc)}">
<meta property="og:image" content="${h(img)}">
<meta property="og:image:width" content="600"><meta property="og:image:height" content="600">
<meta property="og:url" content="${h(page)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${h(ogTitle)}">
<meta name="twitter:description" content="${h(ogDesc)}">
<meta name="twitter:image" content="${h(img)}">
<meta http-equiv="refresh" content="0;url=${h(page)}">
<link rel="canonical" href="${h(page)}">
</head><body style="font-family:-apple-system,sans-serif;background:#0d0f14;color:#c8cdd6;padding:40px">
正在跳转到 <a href="${h(page)}" style="color:#66ccff">正在听什么 ♪</a> …</body></html>`;
      return new Response(html, {
        headers: { "content-type": "text/html; charset=UTF-8", "cache-control": "no-store", "access-control-allow-origin": "*" },
      });
    }

    if (url.pathname === "/" ) return json({ ok: true, service: "nowplaying-state-relay" });
    return json({ ok: false, error: "not found" }, 404);
  },
};

// ---- LB 兜底(仅 KV 空时)----
async function lbNow(env) {
  const user = env.LB_USER || "yudaotor";
  const pn = await getJSON(`${LB_API}/1/user/${encodeURIComponent(user)}/playing-now`);
  const now = pn?.payload?.listens?.[0];
  if (now) return fromLB(now, true, null);
  const re = await getJSON(`${LB_API}/1/user/${encodeURIComponent(user)}/listens?count=1`);
  const last = re?.payload?.listens?.[0];
  if (last) return fromLB(last, false, last.listened_at);
  return { ok: true, empty: true, playing: false };
}
// lbHistory 归一化 ListenBrainz 的历史列表,供 /history 端点用。web/index.html 的
// fetchHistory() LB 兜底分支里有一份取值逻辑相近但形状不同的映射(它是本地变量、只留
// renderHistory() 真正用得到的字段,不是要对外暴露的 API 响应,没必要跟这边完全同形状)。
async function lbHistory(env) {
  const user = env.LB_USER || "yudaotor";
  const re = await getJSON(`${LB_API}/1/user/${encodeURIComponent(user)}/listens?count=100`);
  const listens = re?.payload?.listens || [];
  return listens.map((l) => {
    const m = l.track_metadata || {}, ai = m.additional_info || {};
    return { title: m.track_name, artist: m.artist_name || "", listenedAt: l.listened_at,
      durationMs: typeof ai.duration_ms === "number" ? ai.duration_ms : null,
      device: ai.source || "", // 来源:mac / iphone(采集器打的 source 标),供历史列表标设备
      url: ai.apple_music_url || ai.netease_url || ai.qq_music_url || "" };
  }).filter((x) => x.title);
}
// fromLB 把 ListenBrainz 原始 listen 归一化成 /now 的响应形状。
// ⚠️ web/index.html 的 fetchState() 里有一份几乎逐字段相同的拷贝(它直连 LB 兜底用,
// 字段基本一致,就是没有 ok、且这边叫 device 那边叫 source——那边是给 paint() 直接消费,
// 这边是本 relay 自己的 API 响应契约,命名不同是特意的)。两处分别部署在 Cloudflare
// Workers 和 GitHub Pages 两个不相关平台,没有共用构建/打包步骤,做不到真的共享同一份
// 源码——改这里的字段,务必去 web/index.html 那边也照样改一遍,否则两边会悄悄不一致。
function fromLB(l, playing, listenedAt) {
  const m = l.track_metadata || {}, ai = m.additional_info || {};
  const num = (v) => (typeof v === "number" ? v : null);
  return {
    ok: true,
    title: m.track_name, artist: m.artist_name, album: m.release_name, playing, listenedAt,
    artwork: ai.cover_url || "", accent: ai.accent_color || "", device: ai.source || "",
    lyrics: ai.lyrics || "", lyricsTr: ai.lyrics_tr || "", lyricsRoma: ai.lyrics_roma || "", lyricsYRC: ai.lyrics_yrc || "",
    coverSource: ai.cover_source || "", lyricsSource: ai.lyrics_source || "",
    links: { apple: ai.apple_music_url, qq: ai.qq_music_url, netease: ai.netease_url, spotify: ai.spotify_url },
    durationMs: num(ai.duration_ms), progressMs: num(ai.progress_ms), progressTs: num(ai.progress_ts), rate: num(ai.playback_rate),
  };
}
async function getJSON(u) {
  const r = await fetch(u, { headers: { "user-agent": "nowplaying-state-relay" }, signal: AbortSignal.timeout(3000) });
  if (!r.ok) throw new Error(`${u} -> ${r.status}`);
  return r.json();
}
function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { ...CORS, "content-type": "application/json; charset=UTF-8", "cache-control": "no-store" },
  });
}

// ---- 访客互动用的小 helper(见文件头注释)----
// 按访客 IP 算 hash 当 KV key 用,不存明文 IP。
async function ipHash(request) {
  const ip = request.headers.get("cf-connecting-ip") || "0.0.0.0";
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 16);
}
// 冷却期限流:存的是上次放行的时间戳,按实际经过时间比较是否还在冷却期内——不能靠"key
// 是否存在"判断,因为 KV 的 expirationTtl 有 60 秒下限,而 comment/react 的冷却期(20s/3s)
// 比这个下限还短;TTL 单独取 max(冷却期,60) 只是为了满足 KV 自身限制,不代表真实冷却时长。
async function checkRateLimit(kv, prefix, hash, cooldownSec) {
  const key = `rl:${prefix}:${hash}`;
  const last = parseInt((await kv.get(key)) || "0", 10);
  const now = Date.now();
  if (now - last < cooldownSec * 1000) return false;
  await kv.put(key, String(now), { expirationTtl: Math.max(cooldownSec, 60) });
  return true;
}
// 每日写入预算护栏,key 按 UTC 日期分桶,2 天后自然过期不用手动清。
async function checkWriteBudget(kv) {
  const key = `budget:writes:${todayKey()}`;
  const cur = parseInt((await kv.get(key)) || "0", 10);
  if (cur >= WRITE_BUDGET_CAP) return false;
  await kv.put(key, String(cur + 1), { expirationTtl: 172800 });
  return true;
}
function todayKey() {
  const d = new Date();
  return `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, "0")}${String(d.getUTCDate()).padStart(2, "0")}`;
}
// 留言/昵称清理:只去控制字符 + 收边 + 截断,不做 HTML 转义(见文件头注释——前端用
// textContent 渲染,转义是前端的事,这里转义反而会显示成乱码给所有人看)。
function sanitizeText(s, maxLen) {
  return String(s || "").replace(/[\x00-\x1F\x7F]/g, "").trim().slice(0, maxLen);
}
