// Lyrimuse 匿名遥测的接收端(Cloudflare Worker + D1)。
//
// POST /v1/heartbeat  每台机器每天一条:安装 ID、版本与系统、开着哪些功能、之前几天的活动
// POST /v1/crash      每份崩溃报告一条摘要(App 侧已把路径换成 <path>)
// GET  /v1/stats      汇总,要 Authorization: Bearer <ADMIN_TOKEN>
// GET  /              统计页(输入令牌后读 /v1/stats)
//
// 只认白名单字段,其余丢掉;字符串截长度、列表截条数。不存 IP,只存 Cloudflare 按 IP 给的国家/地区码。
// 字段与 App 侧 Core Telemetry.swift 的 CodingKeys 一一对应,selftest telemetry 组核对。

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
// 枚举值:PlaybackPlayer 的 rawValue(apple_music)、网页平台 id(youtubeMusic)、arch(x86_64) 都要过。
// selftest telemetry 组拿 App 侧真实取值逐个对这两个正则。
const TAG_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const HEX16_RE = /^[0-9a-f]{16}$/;
// bundle id 与 players_played 里的播放器(内置的 rawValue 带下划线)。
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
const MAX_BODY = 32 * 1024;
const MAX_CRASHES_PER_INSTALL_DAY = 20;
const DAY_MS = 86_400_000;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (request.method === "POST" && (url.pathname === "/v1/heartbeat" || url.pathname === "/v1/crash")) {
        // 按来源 IP 限流,防有人刷请求灌假数据、耗光 D1 写额度。超了回 503 而不是 4xx:App 把 4xx 当成这一份本身不合格、
        // 不再重发,503 才会过一阵再试。正常一台机器一天只发一条心跳、最多 5 份崩溃。
        if (env.INGEST_LIMITER) {
          const ip = request.headers.get("cf-connecting-ip") || "unknown";
          const { success } = await env.INGEST_LIMITER.limit({ key: ip });
          if (!success) return new Response(JSON.stringify({ error: "rate limited" }), {
            status: 503, headers: { "content-type": "application/json; charset=utf-8", "retry-after": "60", "cache-control": "no-store" },
          });
        }
      }
      if (request.method === "POST" && url.pathname === "/v1/heartbeat") return await heartbeat(request, env);
      if (request.method === "POST" && url.pathname === "/v1/crash") return await crash(request, env);
      if (request.method === "GET" && url.pathname === "/v1/stats") return await stats(request, env, url);
      if (request.method === "GET" && url.pathname === "/") {
        return new Response(DASHBOARD, {
          headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store",
                     "content-security-policy": "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'" },
        });
      }
      return json({ error: "not found" }, 404);
    } catch (err) {
      console.error(err && err.stack || err);
      return json({ error: "internal" }, 500);
    }
  },
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

async function readBody(request) {
  const text = await request.text();
  if (text.length > MAX_BODY) return null;
  try {
    const obj = JSON.parse(text);
    return obj && typeof obj === "object" && !Array.isArray(obj) ? obj : null;
  } catch {
    return null;
  }
}

function str(v, max = 64) {
  return typeof v === "string" && v.length > 0 ? v.slice(0, max) : null;
}

function tag(v) {
  return typeof v === "string" && TAG_RE.test(v) ? v : null;
}

function tags(v, maxItems = 24) {
  if (!Array.isArray(v)) return [];
  return [...new Set(v.map(tag).filter(Boolean))].slice(0, maxItems).sort();
}

function ids(v, maxItems = 40) {
  if (!Array.isArray(v)) return [];
  return [...new Set(v.filter((x) => typeof x === "string" && ID_RE.test(x)))].slice(0, maxItems).sort();
}

function int(v, min, max) {
  return Number.isInteger(v) && v >= min && v <= max ? v : null;
}

function bool(v) {
  return typeof v === "boolean" ? v : null;
}

function utcDay(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

function dayDistance(a, b) {
  return Math.round((Date.parse(a + "T00:00:00Z") - Date.parse(b + "T00:00:00Z")) / DAY_MS);
}

function cleanEnv(e) {
  e = e && typeof e === "object" ? e : {};
  return {
    app_version: str(e.app_version, 32), build: str(e.build, 32), os_version: str(e.os_version, 32),
    arch: tag(e.arch), ui_language: str(e.ui_language, 16), system_language: str(e.system_language, 16),
  };
}

function cleanFeatures(f) {
  f = f && typeof f === "object" ? f : {};
  return {
    surfaces: tags(f.surfaces), players_selected: tags(f.players_selected, 40),
    lyrics_source_mode: tag(f.lyrics_source_mode), lyrics_sources_enabled: int(f.lyrics_sources_enabled, 0, 100),
    translation: bool(f.translation), romanization: bool(f.romanization), machine_translation: bool(f.machine_translation),
    accounts: tags(f.accounts), trusted_players: ids(f.trusted_players), web_platforms: tags(f.web_platforms),
    show_in_dock: bool(f.show_in_dock), launch_at_login: bool(f.launch_at_login),
    beta_updates: bool(f.beta_updates),
  };
}

async function heartbeat(request, env) {
  const body = await readBody(request);
  if (!body || body.v !== 1) return json({ error: "bad request" }, 400);
  const installID = body.install_id;
  const day = body.day;
  const now = Date.now();
  if (typeof installID !== "string" || !UUID_RE.test(installID)) return json({ error: "bad install_id" }, 400);
  // 客户端按本地自然日记;跟服务器的 UTC 日期最多差一天,放宽到两天。
  if (typeof day !== "string" || !DAY_RE.test(day) || Math.abs(dayDistance(day, utcDay(now))) > 2) {
    return json({ error: "bad day" }, 400);
  }
  const e = cleanEnv(body.env);
  const features = JSON.stringify(cleanFeatures(body.features));
  const country = str(request.cf && request.cf.country, 2);
  // 新装还是从旧版本升级上来的;旧版 App 不发,判不出的也不发。第一次收到的为准。
  const origin = body.origin === "new" || body.origin === "existing" ? body.origin : null;
  const statements = [
    env.DB.prepare(
      `INSERT INTO installs (install_id, first_day, last_day, origin) VALUES (?1, ?2, ?2, ?3)
       ON CONFLICT (install_id) DO UPDATE SET last_day = max(last_day, excluded.last_day),
                                              first_day = min(first_day, excluded.first_day),
                                              origin = COALESCE(installs.origin, excluded.origin)`
    ).bind(installID, day, origin),
    env.DB.prepare(
      `INSERT INTO heartbeats (day, install_id, received_at, app_version, build, os_version, arch, ui_language,
                               system_language, country, features)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
       ON CONFLICT (day, install_id) DO UPDATE SET received_at = excluded.received_at, app_version = excluded.app_version,
         build = excluded.build, os_version = excluded.os_version, arch = excluded.arch, ui_language = excluded.ui_language,
         system_language = excluded.system_language, country = excluded.country, features = excluded.features`
    ).bind(day, installID, now, e.app_version, e.build, e.os_version, e.arch, e.ui_language, e.system_language,
           country, features),
  ];
  const activity = Array.isArray(body.activity) ? body.activity.slice(0, 3) : [];
  for (const a of activity) {
    if (!a || typeof a.day !== "string" || !DAY_RE.test(a.day)) continue;
    const back = dayDistance(day, a.day);
    if (back < 1 || back > 7) continue;
    statements.push(env.DB.prepare(
      `INSERT INTO activity (day, install_id, players_played, hangs) VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT (day, install_id) DO UPDATE SET players_played = excluded.players_played, hangs = excluded.hangs`
    ).bind(a.day, installID, JSON.stringify(ids(a.players_played)), int(a.hangs, 0, 10_000) ?? 0));
  }
  await env.DB.batch(statements);
  return json({ ok: true });
}

function cleanFrames(v) {
  if (!Array.isArray(v)) return [];
  return v.slice(0, 12).map((f) => ({
    image: str(f && f.image, 80), symbol: str(f && f.symbol, 300), offset: int(f && f.offset, 0, 2 ** 40),
  }));
}

// 同一种崩溃的归并键:进程 + 异常类型 + 前三帧落在自家镜像里的符号(没有就前三帧),再不行用终止原因。
// 带异常调用栈的(未捕获的 Objective-C 异常)按异常调用栈取帧:故障线程那几帧每份都是 abort / 重抛。
function crashSignature(c) {
  const pool = c.exception_frames.length ? c.exception_frames : c.frames;
  const own = pool.filter((f) => f.image && /^(lyrimuse|lyrimuse-engine|collector|LyrimuseCore)/i.test(f.image));
  const picked = (own.length ? own : pool).slice(0, 3).map((f) => f.symbol || `${f.image}+${f.offset}`);
  const head = [c.process, c.exception_type || c.termination_namespace || "?"].join(" ");
  const tail = picked.length ? picked.join(" | ") : (c.termination_indicator || "no frames");
  return `${head} :: ${tail}`.slice(0, 500);
}

async function crash(request, env) {
  const body = await readBody(request);
  if (!body || body.v !== 1) return json({ error: "bad request" }, 400);
  const installID = body.install_id;
  if (typeof installID !== "string" || !UUID_RE.test(installID)) return json({ error: "bad install_id" }, 400);
  if (typeof body.report_id !== "string" || !HEX16_RE.test(body.report_id)) return json({ error: "bad report_id" }, 400);
  const now = Date.now();
  const day = utcDay(now);
  const { n } = await env.DB.prepare(`SELECT COUNT(*) AS n FROM crashes WHERE install_id = ?1 AND day = ?2`)
    .bind(installID, day).first();
  if (n >= MAX_CRASHES_PER_INSTALL_DAY) return json({ ok: true, dropped: "daily limit" });
  const c = {
    process: body.process === "engine" ? "engine" : "app",
    app_version: str(body.app_version, 32), os_version: str(body.os_version, 64), occurred_at: str(body.occurred_at, 40),
    exception_type: str(body.exception_type, 80), exception_signal: str(body.exception_signal, 40),
    termination_namespace: str(body.termination_namespace, 40), termination_indicator: str(body.termination_indicator, 200),
    termination_reasons: Array.isArray(body.termination_reasons)
      ? body.termination_reasons.slice(0, 3).map((r) => str(r, 300)).filter(Boolean) : [],
    frames: cleanFrames(body.frames),
    exception_frames: cleanFrames(body.exception_frames),
  };
  await env.DB.prepare(
    `INSERT OR IGNORE INTO crashes (install_id, report_id, received_at, day, process, app_version, os_version, occurred_at,
       exception_type, exception_signal, termination_namespace, termination_indicator, termination_reasons, frames,
       exception_frames, signature, env)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)`
  ).bind(installID, body.report_id, now, day, c.process, c.app_version, c.os_version, c.occurred_at, c.exception_type,
         c.exception_signal, c.termination_namespace, c.termination_indicator, JSON.stringify(c.termination_reasons),
         JSON.stringify(c.frames), JSON.stringify(c.exception_frames), crashSignature(c), JSON.stringify(cleanEnv(body.env))).run();
  return json({ ok: true });
}

function authorized(request, env) {
  const header = request.headers.get("authorization") || "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  const want = env.ADMIN_TOKEN || "";
  if (!want || token.length !== want.length) return false;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= token.charCodeAt(i) ^ want.charCodeAt(i);
  return diff === 0;
}

function countBy(rows, pick) {
  const out = {};
  for (const r of rows) {
    const values = pick(r);
    for (const v of Array.isArray(values) ? values : [values]) {
      const k = v == null || v === "" ? "(unknown)" : String(v);
      out[k] = (out[k] || 0) + 1;
    }
  }
  return Object.entries(out).sort((a, b) => b[1] - a[1]);
}

async function stats(request, env, url) {
  if (!authorized(request, env)) return json({ error: "unauthorized" }, 401);
  const days = Math.min(Math.max(parseInt(url.searchParams.get("days") || "30", 10) || 30, 1), 180);
  const now = Date.now();
  const since = utcDay(now - (days - 1) * DAY_MS);
  const since7 = utcDay(now - 6 * DAY_MS);
  const db = env.DB;
  // excluded_installs 里的安装(作者自己的机器、测试机)不进任何统计;原始数据照存,删掉那一行就恢复统计。
  const kept = (col = "install_id") => `${col} NOT IN (SELECT install_id FROM excluded_installs)`;
  const [daily, fresh, freshByOrigin, totals, latest, activity, crashes] = await Promise.all([
    db.prepare(`SELECT day, COUNT(*) AS n FROM heartbeats WHERE day >= ?1 AND ${kept()} GROUP BY day ORDER BY day`).bind(since).all(),
    db.prepare(`SELECT first_day AS day, COUNT(*) AS n FROM installs WHERE first_day >= ?1 AND ${kept()} GROUP BY first_day ORDER BY first_day`)
      .bind(since).all(),
    db.prepare(`SELECT first_day AS day, origin, COUNT(*) AS n FROM installs WHERE first_day >= ?1 AND ${kept()}
                GROUP BY first_day, origin ORDER BY first_day`).bind(since).all(),
    db.prepare(`SELECT (SELECT COUNT(*) FROM installs WHERE ${kept()}) AS installs,
                       (SELECT COUNT(DISTINCT install_id) FROM heartbeats WHERE day >= ?1 AND ${kept()}) AS active7,
                       (SELECT COUNT(DISTINCT install_id) FROM heartbeats WHERE day >= ?2 AND ${kept()}) AS active_window,
                       (SELECT COUNT(*) FROM excluded_installs) AS excluded`)
      .bind(since7, since).first(),
    // 窗口内每台机器最近的那条心跳:版本、系统、功能分布都按它算。
    db.prepare(`SELECT h.* FROM heartbeats h JOIN (SELECT install_id, MAX(day) AS d FROM heartbeats WHERE day >= ?1 AND ${kept()}
                GROUP BY install_id) l ON h.install_id = l.install_id AND h.day = l.d`).bind(since).all(),
    db.prepare(`SELECT install_id, players_played, hangs FROM activity WHERE day >= ?1 AND ${kept()}`).bind(since).all(),
    db.prepare(`SELECT signature, process, exception_type, termination_indicator, COUNT(*) AS n,
                       COUNT(DISTINCT install_id) AS installs, GROUP_CONCAT(DISTINCT app_version) AS versions,
                       MAX(received_at) AS last_at,
                       (SELECT frames FROM crashes c2 WHERE c2.signature = c.signature AND ${kept("c2.install_id")} ORDER BY received_at DESC LIMIT 1) AS frames,
                       (SELECT termination_reasons FROM crashes c3 WHERE c3.signature = c.signature AND ${kept("c3.install_id")} ORDER BY received_at DESC LIMIT 1) AS reasons,
                       (SELECT exception_frames FROM crashes c4 WHERE c4.signature = c.signature AND ${kept("c4.install_id")} ORDER BY received_at DESC LIMIT 1) AS exception_frames
                FROM crashes c WHERE day >= ?1 AND ${kept("c.install_id")} GROUP BY signature ORDER BY n DESC LIMIT 50`).bind(since).all(),
  ]);
  const rows = latest.results.map((r) => ({ ...r, features: safeJSON(r.features, {}) }));
  const featureFlags = ["translation", "romanization", "machine_translation", "show_in_dock", "launch_at_login", "beta_updates"];
  const playedByInstall = {};
  let hangs = 0;
  const installsWithHangs = new Set();
  for (const a of activity.results) {
    for (const p of safeJSON(a.players_played, [])) (playedByInstall[p] ||= new Set()).add(a.install_id);
    hangs += a.hangs || 0;
    if (a.hangs > 0) installsWithHangs.add(a.install_id);
  }
  return json({
    window_days: days,
    since,
    totals: { installs: totals.installs, active_7d: totals.active7, active_window: totals.active_window, excluded: totals.excluded },
    daily_active: daily.results,
    new_installs: fresh.results,
    // origin: new = 新下载,existing = 老用户升级后第一次上报,null = 还没报过(旧版本或判不出)
    new_installs_by_origin: freshByOrigin.results,
    breakdown: {
      app_version: countBy(rows, (r) => r.app_version),
      os_version: countBy(rows, (r) => (r.os_version || "").split(".")[0]),
      arch: countBy(rows, (r) => r.arch),
      ui_language: countBy(rows, (r) => r.ui_language),
      system_language: countBy(rows, (r) => r.system_language),
      country: countBy(rows, (r) => r.country),
      surfaces: countBy(rows, (r) => r.features.surfaces || []),
      players_selected: countBy(rows, (r) => r.features.players_selected || []),
      accounts: countBy(rows, (r) => r.features.accounts || []),
      trusted_players: countBy(rows, (r) => r.features.trusted_players || []),
      web_platforms: countBy(rows, (r) => r.features.web_platforms || []),
      lyrics_source_mode: countBy(rows, (r) => r.features.lyrics_source_mode),
      flags: featureFlags.map((k) => [k, rows.filter((r) => r.features[k] === true).length]),
    },
    players_played: Object.entries(playedByInstall).map(([k, v]) => [k, v.size]).sort((a, b) => b[1] - a[1]),
    hangs: { total: hangs, installs: installsWithHangs.size },
    machines: rows.length,
    crashes: crashes.results.map(({ versions, ...c }) => {
      const sorted = (versions || "").split(",").filter(Boolean).sort(compareVersions);
      return { ...c, min_version: sorted[0] || null, max_version: sorted[sorted.length - 1] || null,
               frames: safeJSON(c.frames, []), exception_frames: safeJSON(c.exception_frames, []), reasons: safeJSON(c.reasons, []) };
    }),
  });
}

// 按点分的数字段比较(1.9.0 < 1.12.0),预发布后缀按字符串比。
function compareVersions(a, b) {
  const pa = a.split(/[.-]/), pb = b.split(/[.-]/);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] ?? "", y = pb[i] ?? "";
    const nx = /^\d+$/.test(x) ? Number(x) : NaN, ny = /^\d+$/.test(y) ? Number(y) : NaN;
    if (!Number.isNaN(nx) && !Number.isNaN(ny)) { if (nx !== ny) return nx - ny; continue; }
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

function safeJSON(text, fallback) {
  try { return text ? JSON.parse(text) : fallback; } catch { return fallback; }
}

const DASHBOARD = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Lyrimuse 遥测</title>
<style>
:root { --bg: #f6f6f8; --card: #fff; --text: #1d1d1f; --muted: #6e6e73; --line: #e3e3e8; --accent: #5b5bd6; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #111114; --card: #1c1c20; --text: #f2f2f5; --muted: #9a9aa2; --line: #2e2e34; --accent: #8b8bf0; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.5 -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; }
main { max-width: 1080px; margin: 0 auto; padding: 24px 16px 48px; }
h1 { font-size: 22px; margin: 0 0 16px; }
h2 { font-size: 15px; margin: 0 0 10px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 16px; margin-bottom: 14px; }
.kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; }
.kpi b { display: block; font-size: 26px; }
.kpi span { color: var(--muted); font-size: 12px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
td { padding: 3px 0; border-bottom: 1px solid var(--line); vertical-align: top; }
td.n { text-align: right; color: var(--muted); white-space: nowrap; padding-left: 8px; }
.bars { display: flex; align-items: flex-end; gap: 2px; height: 120px; }
.bars div { flex: 1; background: var(--accent); border-radius: 3px 3px 0 0; min-height: 1px; }
.axis { display: flex; justify-content: space-between; color: var(--muted); font-size: 11px; margin-top: 4px; }
form { display: flex; gap: 8px; flex-wrap: wrap; }
input, select, button { font: inherit; padding: 6px 10px; border-radius: 8px; border: 1px solid var(--line); background: var(--card); color: var(--text); }
button { background: var(--accent); color: #fff; border: none; cursor: pointer; }
details summary { cursor: pointer; }
pre { white-space: pre-wrap; word-break: break-all; font-size: 12px; color: var(--muted); margin: 6px 0 0; }
.muted { color: var(--muted); }
</style>
</head>
<body>
<main>
<h1>Lyrimuse 遥测</h1>
<div class="card">
  <form id="f">
    <input id="token" type="password" placeholder="令牌" autocomplete="current-password" style="flex:1;min-width:200px">
    <select id="days"><option>7</option><option selected>30</option><option>90</option><option>180</option></select>
    <button>查看</button>
  </form>
  <p id="msg" class="muted"></p>
</div>
<div id="out"></div>
</main>
<script>
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
try { $("token").value = localStorage.getItem("lyrimuse-telemetry-token") || ""; } catch {}
const LABELS = { app_version: "版本", os_version: "macOS 大版本", arch: "芯片", ui_language: "界面语言", system_language: "系统语言",
  country: "国家/地区", surfaces: "开着的展示面", players_selected: "勾选的播放器", accounts: "连接的账号", trusted_players: "信任的第三方播放器", web_platforms: "网页版平台", lyrics_source_mode: "匹配算法",
  flags: "其他开关" };
function table(rows, total) {
  if (!rows.length) return '<p class="muted">没有数据</p>';
  return "<table>" + rows.map(([k, v]) => "<tr><td>" + esc(k) + '</td><td class="n">' + v +
    (total ? " · " + Math.round(v * 100 / total) + "%" : "") + "</td></tr>").join("") + "</table>";
}
function bars(series, label) {
  if (!series.length) return "";
  const max = Math.max(...series.map((d) => d.n), 1);
  return '<div class="card"><h2>' + label + '</h2><div class="bars">' +
    series.map((d) => '<div title="' + esc(d.day) + ": " + d.n + '" style="height:' + (d.n * 100 / max) + '%"></div>').join("") +
    '</div><div class="axis"><span>' + esc(series[0].day) + "</span><span>" + esc(series[series.length - 1].day) + "</span></div></div>";
}
function render(s) {
  const t = s.totals;
  let html = '<div class="card kpis">' +
    [["总安装", t.installs], ["近 7 天活跃", t.active_7d], ["近 " + s.window_days + " 天活跃", t.active_window],
     ["卡顿次数", s.hangs.total + '<span> · ' + s.hangs.installs + " 台</span>"]]
      .map(([k, v]) => '<div class="kpi"><span>' + k + "</span><b>" + v + "</b></div>").join("") + "</div>";
  html += bars(s.daily_active, "每日活跃") + bars(s.new_installs, "每日新安装");
  html += '<div class="grid">' + Object.entries(s.breakdown).map(([k, rows]) =>
    '<div class="card"><h2>' + esc(LABELS[k] || k) + "</h2>" + table(rows, s.machines) + "</div>").join("") +
    '<div class="card"><h2>放过歌的播放器</h2>' + table(s.players_played, s.machines) + "</div></div>";
  html += '<div class="card"><h2>崩溃(按归并键)</h2>' + (s.crashes.length ? s.crashes.map((c) =>
    "<details><summary><b>" + c.n + " 次 · " + c.installs + " 台</b> " + esc(c.signature) + ' <span class="muted">' +
    esc(c.min_version) + (c.max_version !== c.min_version ? "–" + esc(c.max_version) : "") + "</span></summary><pre>" +
    esc([...(c.reasons || []),
         ...((c.exception_frames || []).length ? ["抛出异常处:", ...c.exception_frames.map(frameLine), "故障线程:"] : []),
         ...(c.frames || []).map(frameLine)].join("\\n")) +
    "</pre></details>").join("") : '<p class="muted">窗口内没有崩溃</p>') + "</div>";
  $("out").innerHTML = html;
}
function frameLine(f, i) { return i + "  " + (f.image || "?") + "  " + (f.symbol || "+" + f.offset); }
async function load() {
  const token = $("token").value.trim();
  if (!token) return;
  try { localStorage.setItem("lyrimuse-telemetry-token", token); } catch {}
  $("msg").textContent = "读取中…";
  const r = await fetch("/v1/stats?days=" + $("days").value, { headers: { authorization: "Bearer " + token } });
  if (!r.ok) { $("msg").textContent = r.status === 401 ? "令牌不对" : "读取失败(" + r.status + ")"; return; }
  const s = await r.json();
  $("msg").textContent = "窗口:" + s.since + " 起 " + s.window_days + " 天 · " + s.machines + " 台机器";
  render(s);
}
$("f").addEventListener("submit", (e) => { e.preventDefault(); load(); });
if ($("token").value) load();
</script>
</body>
</html>`;
