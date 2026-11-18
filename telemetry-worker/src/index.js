// Lyrimuse 匿名遥测的接收端(Cloudflare Worker + D1)。
//
// POST /v1/heartbeat  每台机器每天一条:安装 ID、版本与系统、开着哪些功能、之前几天的活动(含前几次卡顿的概况)
// POST /v1/crash      每份崩溃报告一条摘要(App 侧已把路径换成 <path>)
// GET  /v1/stats      汇总,要 Authorization: Bearer <ADMIN_TOKEN>
// GET  /v1/stats/bundle  一次给出几个窗口的汇总(含与不含自己的机器各一份),同样要令牌
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
const MAX_BODY = 64 * 1024;
// 每日活动里记次数的动作,跟 App 侧 Core TelemetryAction 的 rawValue 一致。
const ACTIONS = ["lyrics_window", "lyrics_picked", "offset_adjusted", "share_card"];
// 每日活动里放过的歌各拿到哪档歌词、是什么语言,跟 Core TelemetryLyricsResult、TelemetrySongLanguage 的 rawValue 一致。
const LYRICS_RESULTS = ["word", "line", "plain", "instrumental", "none"];
// 歌词文件夹里逐字歌词存成的格式,跟 Core LyricsWordFormat 的 rawValue 一致;心跳里第一个是主格式。
const LYRICS_WORD_FORMATS = ["yrc", "ttml", "qrc", "krc", "enhanced-lrc"];
// 每日活动里逐字 / 逐行 / 纯文本的歌显示的那份各来自哪个源,键是「源:档」(如 netease:line)。源名单跟 Core TelemetryLyricSource.tags
// 逐字一致(引擎的歌词源、本机来源、字幕,加 unknown / other),档跟 TelemetryLyricSource.results 一致,selftest telemetry 组核对。
// 见 14 章决策 208。
const LYRIC_SOURCES = ["netease", "qq", "kugou", "lrclib", "amll", "lyricfind", "kuwo", "migu", "deezer", "applemusic", "soda", "vibe", "genie", "petitlyrics", "zing", "megalobiz", "kkbox", "spotify", "amazon", "localfile", "lxmusic", "import", "subtitles", "unknown", "other"];
const LYRIC_SOURCE_RESULTS = ["word", "line", "plain"];
const MAX_LYRIC_SOURCE_KEYS = 40;
const SONG_LANGUAGES = ["zh", "yue", "ja", "ko", "ru", "uk", "bg", "be", "sr", "mk", "kk", "el", "th", "ar", "hi", "bn", "pa", "gu", "ta", "te", "kn", "ml", "si", "en", "es", "pt", "fr", "de", "it", "nl", "sv", "pl", "tr", "vi", "he", "other"];
// 卡顿概况(Core TelemetryHang)的取值,跟 Core 那几份名单一致,selftest telemetry 组核对。
const HANG_DURATIONS = ["5-10s", "10-30s", "30s+", "unrecovered"];
const HANG_ELAPSED = ["<1m", "1-10m", "10-60m", "1-6h", "6h+"];
const HANG_THERMAL = ["nominal", "fair", "serious", "critical"];
const HANG_WINDOWS = ["settings", "lyrics-manager", "lyrics-window", "lyrics-quick-search", "lyrics-share", "whats-new", "onboarding", "menubar-panel"];
// 停顿期间主线程被系统压着(锁屏、App Nap 把优先级压到后台档)的标记,跟 Core MainThreadThrottle.reasons 一致。
// 这类卡顿照收,统计默认不算(hangs),hangs_all 连它们一起算(14 章决策 202)。
const HANG_THROTTLE = ["locked", "low_priority"];
// 每台每天的卡顿概况条数:没被压着的、被压着的各有名额(Core TelemetryActivity 的两个同名常量)。
const MAX_HANG_DETAILS_PER_DAY = 3;
const MAX_THROTTLED_HANG_DETAILS_PER_DAY = 1;
// 窗口布局轮数超限被 AppKit 接住(Core DisplayCycleLimit / TelemetryLayoutLimit):pass 名单跟 Core 一致,selftest 核对;
// 窗口只收 HANG_WINDOWS 里的场景名,类名只收字母数字和 _ . $。
const LAYOUT_PASSES = ["update-constraints", "layout", "display", "other"];
const LAYOUT_CLASS_RE = /^[A-Za-z0-9_.$]{1,80}$/;
const MAX_LAYOUT_LIMITS_PER_DAY = 5;
const MAX_HANG_FRAMES = 6;
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
      if (request.method === "GET" && url.pathname === "/v1/stats/bundle") return await statsBundle(request, env, url);
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

function counts(v, keys) {
  const out = {};
  if (!v || typeof v !== "object" || Array.isArray(v)) return out;
  for (const k of keys) {
    const n = int(v[k], 1, 10_000);
    if (n != null) out[k] = n;
  }
  return out;
}

// lyric_sources:只收「名单里的源:名单里的档」,首数 1～10000,最多 MAX_LYRIC_SOURCE_KEYS 个键(按名单顺序取),别的键丢掉。
function lyricSourceCounts(v) {
  const out = {};
  if (!v || typeof v !== "object" || Array.isArray(v)) return out;
  for (const source of LYRIC_SOURCES) {
    for (const result of LYRIC_SOURCE_RESULTS) {
      if (Object.keys(out).length >= MAX_LYRIC_SOURCE_KEYS) return out;
      const k = source + ":" + result;
      const n = Object.hasOwn(v, k) ? int(v[k], 1, 10_000) : null;
      if (n != null) out[k] = n;
    }
  }
  return out;
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

// 统计窗口和崩溃按北京时间(UTC+8)划日;心跳和活动的日期是各机器自己报的本地自然日。
function bjDay(ms) {
  return utcDay(ms + 8 * 3600 * 1000);
}

function dayDistance(a, b) {
  return Math.round((Date.parse(a + "T00:00:00Z") - Date.parse(b + "T00:00:00Z")) / DAY_MS);
}

function cleanEnv(e) {
  e = e && typeof e === "object" ? e : {};
  return {
    app_version: str(e.app_version, 32), build: str(e.build, 32), os_version: str(e.os_version, 32),
    arch: tag(e.arch), ui_language: str(e.ui_language, 16), system_language: str(e.system_language, 16),
    // 系统设置里的地区,两字母;旧版 App 不发。
    system_region: typeof e.system_region === "string" && /^[A-Z]{2}$/.test(e.system_region) ? e.system_region : null,
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
    // 安装渠道 homebrew / direct;改过默认值的设置项(只有属性名);
    // 勾选的播放器里缺的权限(automation.apple_music 这类)。旧版 App 不发这几项。
    install_method: f.install_method === "homebrew" || f.install_method === "direct" ? f.install_method : null,
    settings_changed: ids(f.settings_changed, 200), permissions_missing: tags(f.permissions_missing, 60),
    // 逐字歌词格式:保持 App 给的顺序(第一个是主格式),只收名单里的、去重。旧版 App 不发,记成空。
    lyrics_word_formats: Array.isArray(f.lyrics_word_formats)
      ? [...new Set(f.lyrics_word_formats.filter((v) => LYRICS_WORD_FORMATS.includes(v)))] : [],
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
                               system_language, country, features, system_region)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
       ON CONFLICT (day, install_id) DO UPDATE SET received_at = excluded.received_at, app_version = excluded.app_version,
         build = excluded.build, os_version = excluded.os_version, arch = excluded.arch, ui_language = excluded.ui_language,
         system_language = excluded.system_language, country = excluded.country, features = excluded.features,
         system_region = excluded.system_region`
    ).bind(day, installID, now, e.app_version, e.build, e.os_version, e.arch, e.ui_language, e.system_language,
           country, features, e.system_region),
  ];
  const activity = Array.isArray(body.activity) ? body.activity.slice(0, 3) : [];
  for (const a of activity) {
    if (!a || typeof a.day !== "string" || !DAY_RE.test(a.day)) continue;
    const back = dayDistance(day, a.day);
    if (back < 1 || back > 7) continue;
    const hangs = int(a.hangs, 0, 10_000) ?? 0;
    // 其中停顿期间主线程被系统压着的次数;旧版 App 不发,存空。
    const throttledHangs = int(a.throttled_hangs, 0, 10_000);
    statements.push(env.DB.prepare(
      `INSERT INTO activity (day, install_id, players_played, hangs, actions, lyrics, languages, layout_limits, throttled_hangs,
                             lyric_sources)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
       ON CONFLICT (day, install_id) DO UPDATE SET players_played = excluded.players_played, hangs = excluded.hangs,
                                                   actions = excluded.actions, lyrics = excluded.lyrics,
                                                   languages = excluded.languages, layout_limits = excluded.layout_limits,
                                                   throttled_hangs = excluded.throttled_hangs, lyric_sources = excluded.lyric_sources`
    ).bind(a.day, installID, JSON.stringify(ids(a.players_played)), hangs,
           JSON.stringify(counts(a.actions, ACTIONS)), JSON.stringify(counts(a.lyrics, LYRICS_RESULTS)),
           JSON.stringify(counts(a.languages, SONG_LANGUAGES)), JSON.stringify(cleanLayoutLimits(a.layout_limits)),
           throttledHangs == null ? null : Math.min(throttledHangs, hangs),
           // 旧版 App 不发 lyric_sources,存空,统计里跟「报了但一首都没有」分得开。
           a.lyric_sources === undefined ? null : JSON.stringify(lyricSourceCounts(a.lyric_sources))));
    // 那一天的卡顿概况整批替换(同一天重发时以新的为准)。版本与系统取这条心跳的,活动是之前几天的,升级当天可能差一版。
    statements.push(env.DB.prepare(`DELETE FROM hang_events WHERE day = ?1 AND install_id = ?2`).bind(a.day, installID));
    const details = Array.isArray(a.hang_details)
      ? a.hang_details.slice(0, MAX_HANG_DETAILS_PER_DAY + MAX_THROTTLED_HANG_DETAILS_PER_DAY) : [];
    details.map(cleanHang).filter(Boolean).forEach((h, seq) => statements.push(env.DB.prepare(
      `INSERT INTO hang_events (day, install_id, seq, received_at, app_version, os_version, arch, duration, since_launch,
                                since_wake, player, windows, thermal, stack, signature, throttled)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)`
    ).bind(a.day, installID, seq, now, e.app_version, e.os_version, e.arch, h.duration, h.since_launch, h.since_wake,
           h.player, JSON.stringify(h.windows), h.thermal, JSON.stringify(h.stack), hangSignature(h.stack),
           h.throttled.length ? JSON.stringify(h.throttled) : null)));
  }
  await env.DB.batch(statements);
  return json({ ok: true });
}

// 旧版本 App 不发这一项,存成空数组。不合法的条目整条丢掉。
function cleanLayoutLimits(v) {
  if (!Array.isArray(v)) return [];
  return v.slice(0, MAX_LAYOUT_LIMITS_PER_DAY).map((l) => {
    if (!l || typeof l !== "object" || Array.isArray(l)) return null;
    const cls = typeof l.class === "string" && LAYOUT_CLASS_RE.test(l.class) ? l.class : null;
    const pass = oneOf(l.pass, LAYOUT_PASSES), count = int(l.count, 1, 10_000);
    if (!cls || !pass || count == null) return null;
    return { window: oneOf(l.window, HANG_WINDOWS), class: cls, pass, count };
  }).filter(Boolean);
}

function oneOf(v, list) {
  return typeof v === "string" && list.includes(v) ? v : null;
}

function cleanHang(h) {
  if (!h || typeof h !== "object" || Array.isArray(h)) return null;
  const duration = oneOf(h.duration, HANG_DURATIONS), sinceLaunch = oneOf(h.since_launch, HANG_ELAPSED);
  if (!duration || !sinceLaunch) return null;
  return {
    duration, since_launch: sinceLaunch, since_wake: oneOf(h.since_wake, HANG_ELAPSED),
    player: typeof h.player === "string" && ID_RE.test(h.player) ? h.player : null,
    windows: Array.isArray(h.windows) ? [...new Set(h.windows.filter((w) => HANG_WINDOWS.includes(w)))].sort() : [],
    thermal: oneOf(h.thermal, HANG_THERMAL),
    stack: cleanFrames(h.stack).slice(0, MAX_HANG_FRAMES),
    // 旧版 App 不发,记成空(没被压着)。
    throttled: Array.isArray(h.throttled) ? [...new Set(h.throttled.filter((r) => HANG_THROTTLE.includes(r)))].sort() : [],
  };
}

// 卡顿的归并键:最深那一帧(卡在什么上:等锁、等跨进程回复、画图……)+ 栈里前两个自家帧(谁在那儿等)。没采样的单独一组。
function hangSignature(stack) {
  if (!stack.length) return "(no stack)";
  const name = (f) => f.symbol || `${f.image}+${f.offset}`;
  const own = stack.slice(1).filter((f) => f.image && OWN_IMAGE_RE.test(f.image)).slice(0, 2);
  return [stack[0], ...own].map(name).join(" | ").slice(0, 500);
}

function cleanFrames(v) {
  if (!Array.isArray(v)) return [];
  return v.slice(0, 12).map((f) => ({
    image: str(f && f.image, 80), symbol: str(f && f.symbol, 300), offset: int(f && f.offset, 0, 2 ** 40),
  }));
}

// 同一种崩溃的归并键:进程 + 异常类型 + 前三帧落在自家镜像里的符号;没有自家帧就跳过 abort / 断言 / 异常重抛这类
// 收尾帧再取前三帧(不跳的话不同崩溃都并成 `__pthread_kill | pthread_kill | abort`),再不行用终止原因。
// dyld 启动失败(缺库、签名)没有有用的帧,用终止原因第一句(`Library not loaded: …`)。
// 带异常调用栈的(未捕获的 Objective-C 异常)按异常调用栈取帧:故障线程那几帧每份都是 abort / 重抛。
const OWN_IMAGE_RE = /^(lyrimuse|lyrimuse-engine|collector|LyrimuseCore)/i;
const TEARDOWN_IMAGE_RE = /^(libsystem_kernel|libsystem_pthread|libc\+\+abi|libobjc\.A)\.dylib$/;
const TEARDOWN_SYMBOL_RE = /^(abort|__abort|abort_with_payload|__assert_rtn|__cxa_(re)?throw|objc_exception_(re)?throw|_objc_terminate|.*precondition_failure|.*(_assertionFailure|_fatalErrorMessage))\b/;

function crashSignature(c) {
  const head = [c.process, c.exception_type || c.termination_namespace || "?"].join(" ");
  if (c.termination_namespace === "DYLD" && c.termination_reasons.length) {
    return `${head} :: ${c.termination_reasons[0]}`.slice(0, 500);
  }
  const pool = c.exception_frames.length ? c.exception_frames : c.frames;
  const own = pool.filter((f) => f.image && OWN_IMAGE_RE.test(f.image));
  const meaningful = pool.filter((f) => !TEARDOWN_IMAGE_RE.test(f.image || "") && !TEARDOWN_SYMBOL_RE.test(f.symbol || ""));
  const source = own.length ? own : (meaningful.length ? meaningful : pool);
  const picked = source.slice(0, 3).map((f) => f.symbol || `${f.image}+${f.offset}`);
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
  const day = bjDay(now);
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
  const days = clampDays(url.searchParams.get("days") || "30");
  const now = Date.now();
  const raw = await loadStatsRows(env.DB, earliestDay(now, [days]));
  return json(computeStats(raw, { days, now, includeExcluded: url.searchParams.get("include_excluded") === "1" }));
}

// 一次给出好几个窗口、含与不含自己的机器各一份(SecondBrain 面板每小时拉的就是这 2 × N 份):
// { windows: { "7": <同 /v1/stats>, … }, windows_all: { "7": <同 /v1/stats?include_excluded=1>, … } }。
async function statsBundle(request, env, url) {
  if (!authorized(request, env)) return json({ error: "unauthorized" }, 401);
  const list = [...new Set((url.searchParams.get("days") || "7,30,90,180").split(",").slice(0, 6).map(clampDays))];
  const now = Date.now();
  const raw = await loadStatsRows(env.DB, earliestDay(now, list));
  const pick = (includeExcluded) => Object.fromEntries(list.map((days) => [String(days), computeStats(raw, { days, now, includeExcluded })]));
  return json({ windows: pick(false), windows_all: pick(true) });
}

function clampDays(v) {
  return Math.min(Math.max(parseInt(v, 10) || 30, 1), 180);
}

function windowSince(now, days) {
  return bjDay(now - (days - 1) * DAY_MS);
}

// 要读到的最早一天:最长的窗口,且不晚于「近 7 天活跃」要的那天。
function earliestDay(now, list) {
  return windowSince(now, Math.max(7, ...list));
}

// 每张表按 since 只读一遍,各窗口、含不含自己的机器都在内存里从这一份算。D1 按扫过的行数计读取额度,
// 别改回每个数字各写一条 SQL:那样每份统计要把心跳表扫好几遍(见 14 章决策 187)。
async function loadStatsRows(db, since) {
  const [heartbeats, installs, activity, crashes, hangEvents, excluded] = await Promise.all([
    db.prepare(`SELECT * FROM heartbeats WHERE day >= ?1`).bind(since).all(),
    db.prepare(`SELECT install_id, first_day, origin FROM installs`).all(),
    db.prepare(`SELECT day, install_id, players_played, hangs, throttled_hangs, actions, lyrics, languages, lyric_sources
                FROM activity WHERE day >= ?1`)
      .bind(since).all(),
    db.prepare(`SELECT day, install_id, received_at, signature, process, exception_type, termination_indicator, app_version, frames,
                       termination_reasons, exception_frames FROM crashes WHERE day >= ?1`).bind(since).all(),
    db.prepare(`SELECT day, install_id, app_version, duration, since_launch, since_wake, player, windows, thermal, stack, signature, received_at,
                       throttled
                FROM hang_events WHERE day >= ?1`).bind(since).all(),
    db.prepare(`SELECT install_id FROM excluded_installs`).all(),
  ]);
  // 每行标上安装的序号(ix,去重计数用)和是不是自己的机器(own),各份统计不再按字符串查集合。
  const excludedIDs = new Set(excluded.results.map((r) => r.install_id));
  const index = new Map();
  const mark = (r) => {
    let ix = index.get(r.install_id);
    if (ix === undefined) index.set(r.install_id, (ix = index.size));
    r.ix = ix;
    r.own = excludedIDs.has(r.install_id);
    return r;
  };
  heartbeats.results.forEach(mark);
  installs.results.forEach(mark);
  crashes.results.forEach(mark);
  const originByIx = new Map(installs.results.map((r) => [r.ix, r.origin ?? null]));
  // 每台机器最近的那条心跳:窗口一直开到今天,所以窗口内最近的一条就是它(只要它落在窗口里)。
  const latestByInstall = new Map();
  for (const h of heartbeats.results) {
    const cur = latestByInstall.get(h.ix);
    if (!cur || h.day > cur.day) latestByInstall.set(h.ix, h);
  }
  const latest = [...latestByInstall.values()].map((r) => ({ ...r, features: safeJSON(r.features, {}) }));
  // JSON 列在这里解析一次,一次请求要算好几份统计,别在每份里再解析。
  const parsedActivity = activity.results.map(mark).map((a) => ({
    ix: a.ix, own: a.own, day: a.day, install_id: a.install_id, hangs: a.hangs || 0,
    throttled_hangs: Math.min(a.throttled_hangs || 0, a.hangs || 0), players_played: safeJSON(a.players_played, []),
    actions: safeJSON(a.actions, {}), lyrics: safeJSON(a.lyrics, {}), languages: safeJSON(a.languages, {}),
    lyric_sources: a.lyric_sources == null ? null : safeJSON(a.lyric_sources, {}),
  }));
  const parsedHangs = hangEvents.results.map(mark).map((h) => ({ ...h, windows: safeJSON(h.windows, []), stack: safeJSON(h.stack, []),
                                                                    throttled: safeJSON(h.throttled, []) }));
  return { heartbeats: heartbeats.results, latest, installs: installs.results, activity: parsedActivity,
           crashes: crashes.results, hangEvents: parsedHangs, excluded: excludedIDs, installCount: index.size, originByIx };
}

function countRows(rows, key) {
  const out = new Map();
  for (const r of rows) {
    const k = key(r);
    out.set(k, (out.get(k) || 0) + 1);
  }
  return out;
}

function byText(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

function crashGroups(crashes) {
  const groups = new Map();
  for (const c of crashes) {
    let g = groups.get(c.signature);
    if (!g) groups.set(c.signature, (g = { n: 0, ids: new Set(), versions: new Set(), last: c }));
    g.n += 1;
    g.ids.add(c.ix);
    if (c.app_version) g.versions.add(c.app_version);
    if (c.received_at > g.last.received_at) g.last = c;
  }
  return [...groups.entries()].map(([signature, g]) => ({
    signature, process: g.last.process, exception_type: g.last.exception_type, termination_indicator: g.last.termination_indicator,
    n: g.n, installs: g.ids.size, versions: [...g.versions].join(","), last_at: g.last.received_at,
    frames: g.last.frames, reasons: g.last.termination_reasons, exception_frames: g.last.exception_frames,
  })).sort((a, b) => b.n - a.n || b.last_at - a.last_at).slice(0, 50);
}

function distinct(rows, size) {
  const seen = new Uint8Array(size);
  let n = 0;
  for (const r of rows) if (!seen[r.ix]) { seen[r.ix] = 1; n += 1; }
  return n;
}

function computeStats(raw, { days, now, includeExcluded }) {
  const since = windowSince(now, days);
  const since7 = windowSince(now, 7);
  // excluded_installs 里的安装(作者自己的机器、测试机)默认不进任何统计;原始数据照存,删掉那一行就恢复统计。
  // include_excluded=1 时连它们一起算(SecondBrain 面板遥测页的「含我们自己的机器」开关)。
  const kept = (r) => includeExcluded || !r.own;
  const inWindow = (r) => r.day >= since && kept(r);
  const beats = raw.heartbeats.filter(inWindow);
  const daily = { results: [...countRows(beats, (r) => r.day)].sort((a, b) => byText(a[0], b[0])).map(([day, n]) => ({ day, n })) };
  const newInstalls = raw.installs.filter((r) => r.first_day >= since && kept(r));
  const fresh = { results: [...countRows(newInstalls, (r) => r.first_day)].sort((a, b) => byText(a[0], b[0])).map(([day, n]) => ({ day, n })) };
  const freshByOrigin = { results: [...countRows(newInstalls, (r) => JSON.stringify([r.first_day, r.origin ?? null]))]
    .map(([k, n]) => { const [day, origin] = JSON.parse(k); return { day, origin, n }; })
    .sort((a, b) => byText(a.day, b.day) || byText(a.origin ?? "", b.origin ?? "")) };
  const totals = {
    installs: raw.installs.filter(kept).length,
    active7: distinct(raw.heartbeats.filter((r) => r.day >= since7 && kept(r)), raw.installCount),
    active_window: distinct(beats, raw.installCount),
    excluded: raw.excluded.size,
  };
  const latest = { results: raw.latest.filter(inWindow) };
  const activity = { results: raw.activity.filter(inWindow) };
  const crashes = { results: crashGroups(raw.crashes.filter(inWindow)) };
  const hangEvents = { results: raw.hangEvents.filter(inWindow) };
  const rows = latest.results;
  const featureFlags = ["translation", "romanization", "machine_translation", "show_in_dock", "launch_at_login", "beta_updates"];
  const playedByInstall = {};
  let hangs = 0, throttledHangs = 0;
  const installsWithHangs = new Set(), installsWithAnyHangs = new Set();
  const actionTotals = {}, actionInstalls = {};
  const lyricsTotals = {}, languageTotals = {}, lyricsByDay = {};
  const lyricSourceTotals = {}, lyricSourceInstalls = {};
  let lyricSourceReports = 0;
  for (const a of activity.results) {
    const lyrics = a.lyrics;
    if (Object.keys(lyrics).length > 0) {
      const d = (lyricsByDay[a.day] ||= { day: a.day, installs: 0, ...Object.fromEntries(LYRICS_RESULTS.map((k) => [k, 0])) });
      d.installs += 1;
      for (const [k, n] of Object.entries(lyrics)) {
        lyricsTotals[k] = (lyricsTotals[k] || 0) + n;
        if (k in d) d[k] += n;
      }
    }
    for (const [k, n] of Object.entries(a.languages)) languageTotals[k] = (languageTotals[k] || 0) + n;
    if (a.lyric_sources) {
      lyricSourceReports += 1;
      for (const [k, n] of Object.entries(a.lyric_sources)) {
        const [source, result] = k.split(":");
        const t = (lyricSourceTotals[source] ||= Object.fromEntries(LYRIC_SOURCE_RESULTS.map((r) => [r, 0])));
        if (result in t) t[result] += n;
        (lyricSourceInstalls[source] ||= new Set()).add(a.ix);
      }
    }
    for (const p of a.players_played) (playedByInstall[p] ||= new Set()).add(a.ix);
    hangs += a.hangs - a.throttled_hangs;
    throttledHangs += a.throttled_hangs;
    if (a.hangs > a.throttled_hangs) installsWithHangs.add(a.ix);
    if (a.hangs > 0) installsWithAnyHangs.add(a.ix);
    for (const [k, n] of Object.entries(a.actions)) {
      actionTotals[k] = (actionTotals[k] || 0) + n;
      (actionInstalls[k] ||= new Set()).add(a.ix);
    }
  }
  return {
    window_days: days,
    since,
    include_excluded: includeExcluded,
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
      // 界面语言是跟随系统还是在设置里手动选的:看改过默认值的设置项里有没有 appLanguage(默认「跟随系统」)。
      // 那份名单跟 install_method 是同一版 App 开始报的,没有 install_method 的旧版本判不出,记成 (unknown)。
      ui_language_source: countBy(rows, uiLanguageSource),
      ui_language_system: countBy(rows.filter((r) => uiLanguageSource(r) === "system"), (r) => r.ui_language),
      ui_language_manual: countBy(rows.filter((r) => uiLanguageSource(r) === "manual"), (r) => r.ui_language),
      system_language: countBy(rows, (r) => r.system_language),
      system_region: countBy(rows, (r) => r.system_region),
      country: countBy(rows, (r) => r.country),
      surfaces: countBy(rows, (r) => r.features.surfaces || []),
      players_selected: countBy(rows, (r) => r.features.players_selected || []),
      accounts: countBy(rows, (r) => r.features.accounts || []),
      trusted_players: countBy(rows, (r) => r.features.trusted_players || []),
      web_platforms: countBy(rows, (r) => r.features.web_platforms || []),
      lyrics_source_mode: countBy(rows, (r) => r.features.lyrics_source_mode),
      // 下面三项只算报了这一项的机器(旧版本不发,记成 (unknown) 的也在里面)。
      install_method: countBy(rows, (r) => r.features.install_method),
      settings_changed: countBy(rows, (r) => r.features.settings_changed || []),
      permissions_missing: countBy(rows, (r) => r.features.permissions_missing || []),
      // 逐字歌词格式:主格式(旧版本记成 (unknown))与勾选的全部(多选计数)。默认值分两种:1.12.0 起新装的是 TTML,
      // 更早装的老用户是 YRC,所以主格式再按这台是新下载还是老用户升级(installs.origin)各数一份,判不出的不进这两份。
      lyrics_word_format: countBy(rows, primaryWordFormat),
      lyrics_word_formats: countBy(rows, (r) => r.features.lyrics_word_formats || []),
      lyrics_word_format_new: countBy(rows.filter((r) => primaryWordFormat(r) && raw.originByIx.get(r.ix) === "new"), primaryWordFormat),
      lyrics_word_format_existing: countBy(rows.filter((r) => primaryWordFormat(r) && raw.originByIx.get(r.ix) === "existing"),
                                           primaryWordFormat),
      flags: featureFlags.map((k) => [k, rows.filter((r) => r.features[k] === true).length]),
    },
    players_played: Object.entries(playedByInstall).map(([k, v]) => [k, v.size]).sort((a, b) => b[1] - a[1]),
    // detailed:带了概况的那几次(新版本才有,每台每天最多 3 + 1 次);context 是这几次的情况分布,hotspots 按卡住的位置归并。
    // hangs 不算停顿期间主线程被系统压着(锁屏、App Nap)的那些,hangs_all 连它们一起算;throttled 是窗口内被压着的次数
    // (两份一样)。旧版 App 不报这一项,它们的卡顿全算没被压着。
    hangs: { total: hangs, installs: installsWithHangs.size, throttled: throttledHangs,
             ...hangSummary(hangEvents.results.filter((h) => !h.throttled.length)) },
    hangs_all: { total: hangs + throttledHangs, installs: installsWithAnyHangs.size, throttled: throttledHangs,
                 ...hangSummary(hangEvents.results) },
    // 每个动作:窗口内一共几次、几台机器做过。
    actions: ACTIONS.map((k) => ({ action: k, total: actionTotals[k] || 0, installs: actionInstalls[k] ? actionInstalls[k].size : 0 })),
    // 放过的歌各拿到哪档歌词、各是什么语言(窗口内首数之和;同一首一台机器一天只算一次)。lyrics_daily 每天一行,installs 是报了的机器数。
    lyrics: LYRICS_RESULTS.map((k) => ({ result: k, songs: lyricsTotals[k] || 0 })),
    languages: SONG_LANGUAGES.map((k) => ({ language: k, songs: languageTotals[k] || 0 })),
    lyrics_daily: Object.values(lyricsByDay).sort((a, b) => (a.day < b.day ? -1 : 1)),
    // 逐字 / 逐行 / 纯文本的歌显示的那份各来自哪个源(窗口内首数之和,同一首一台机器一天只算一次),songs 是三档之和,
    // installs 是记到过这个源的机器数,按 songs 从多到少;reports 是报了这一项的机器日数(旧版 App 不报,不算进来)。
    lyric_sources: {
      reports: lyricSourceReports,
      sources: Object.entries(lyricSourceTotals)
        .map(([source, t]) => ({ source, ...t, songs: LYRIC_SOURCE_RESULTS.reduce((n, r) => n + t[r], 0),
                                 installs: lyricSourceInstalls[source].size }))
        .sort((a, b) => b.songs - a.songs || byText(a.source, b.source)),
    },
    machines: rows.length,
    crashes: crashes.results.map(({ versions, ...c }) => {
      const sorted = (versions || "").split(",").filter(Boolean).sort(compareVersions);
      return { ...c, min_version: sorted[0] || null, max_version: sorted[sorted.length - 1] || null,
               frames: safeJSON(c.frames, []), exception_frames: safeJSON(c.exception_frames, []), reasons: safeJSON(c.reasons, []) };
    }),
  };
}

// events 的 windows / stack 已解析(loadStatsRows)。
function hangSummary(parsed) {
  const context = {
    duration: countBy(parsed, (h) => h.duration),
    since_launch: countBy(parsed, (h) => h.since_launch),
    since_wake: countBy(parsed, (h) => h.since_wake || "(no sleep)"),
    player: countBy(parsed, (h) => h.player),
    windows: countBy(parsed, (h) => (h.windows.length ? h.windows : ["(none)"])),
    thermal: countBy(parsed, (h) => h.thermal),
    throttled: countBy(parsed, (h) => (h.throttled.length ? h.throttled : ["(none)"])),
  };
  const groups = {};
  for (const h of parsed) (groups[h.signature] ||= []).push(h);
  const hotspots = Object.entries(groups).map(([signature, list]) => {
    const latest = list.reduce((a, b) => (b.received_at > a.received_at ? b : a));
    const sorted = [...new Set(list.map((h) => h.app_version).filter(Boolean))].sort(compareVersions);
    return {
      signature, n: list.length, installs: new Set(list.map((h) => h.ix)).size,
      min_version: sorted[0] || null, max_version: sorted[sorted.length - 1] || null, last_at: latest.received_at,
      stack: latest.stack, duration: countBy(list, (h) => h.duration), since_wake: countBy(list, (h) => h.since_wake || "(no sleep)"),
      player: countBy(list, (h) => h.player), windows: countBy(list, (h) => (h.windows.length ? h.windows : ["(none)"])),
      throttled: list.filter((h) => h.throttled.length).length,
    };
  }).sort((a, b) => b.n - a.n).slice(0, 50);
  return { detailed: parsed.length, context, hotspots };
}

function primaryWordFormat(r) {
  return (r.features.lyrics_word_formats || [])[0] ?? null;
}

// 界面语言的来源:system = 跟随系统,manual = 手动选的,null = 旧版本判不出。
function uiLanguageSource(r) {
  if (!r.features.install_method) return null;
  return (r.features.settings_changed || []).includes("appLanguage") ? "manual" : "system";
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
const LABELS = { app_version: "版本", os_version: "macOS 大版本", arch: "芯片", ui_language: "界面语言",
  ui_language_source: "界面语言来源(system 跟随系统 / manual 手动选)", ui_language_system: "界面语言 · 跟随系统",
  ui_language_manual: "界面语言 · 手动选", system_language: "系统语言",
  system_region: "地区(系统设置)", country: "出口 IP 所在地区", surfaces: "开着的展示面", players_selected: "勾选的播放器", accounts: "连接的账号", trusted_players: "信任的第三方播放器", web_platforms: "网页版平台", lyrics_source_mode: "匹配算法",
  flags: "其他开关", install_method: "安装渠道", settings_changed: "改过默认值的设置",
  permissions_missing: "缺的权限", lyrics_word_format: "逐字歌词格式(主格式)", lyrics_word_formats: "逐字歌词格式(勾选的全部)",
  lyrics_word_format_new: "逐字歌词主格式 · 新下载(默认 TTML)", lyrics_word_format_existing: "逐字歌词主格式 · 老用户(默认 YRC)" };
const ACTION_LABELS = { lyrics_window: "打开歌词窗口", lyrics_picked: "手动采用歌词", offset_adjusted: "调时间偏移", share_card: "分享歌词卡" };
const LYRICS_LABELS = { word: "逐字", line: "逐行", plain: "纯文本", instrumental: "纯音乐", none: "没找到" };
const LANGUAGE_LABELS = { zh: "中文", yue: "粤语", ja: "日语", ko: "韩语", ru: "俄语", uk: "乌克兰语", bg: "保加利亚语",
  be: "白俄罗斯语", sr: "塞尔维亚语", mk: "马其顿语", kk: "哈萨克语", el: "希腊语", th: "泰语", ar: "阿拉伯字母", hi: "印地语等",
  bn: "孟加拉语", pa: "旁遮普语", gu: "古吉拉特语", ta: "泰米尔语", te: "泰卢固语", kn: "卡纳达语", ml: "马拉雅拉姆语",
  si: "僧伽罗语", en: "英语", es: "西班牙语", pt: "葡萄牙语", fr: "法语", de: "德语", it: "意大利语", nl: "荷兰语",
  sv: "瑞典语", pl: "波兰语", tr: "土耳其语", vi: "越南语", he: "希伯来语", other: "其他" };
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
     ["卡顿次数", s.hangs.total + '<span> · ' + s.hangs.installs + " 台" +
       (s.hangs.throttled ? " · 另有 " + s.hangs.throttled + " 次在锁屏 / 被节流期间" : "") + "</span>"]]
      .map(([k, v]) => '<div class="kpi"><span>' + k + "</span><b>" + v + "</b></div>").join("") + "</div>";
  html += bars(s.daily_active, "每日活跃") + bars(s.new_installs, "每日新安装");
  html += '<div class="grid">' + Object.entries(s.breakdown).map(([k, rows]) =>
    '<div class="card"><h2>' + esc(LABELS[k] || k) + "</h2>" + table(rows, s.machines) + "</div>").join("") +
    '<div class="card"><h2>放过歌的播放器</h2>' + table(s.players_played, s.machines) + "</div>" +
    '<div class="card"><h2>动作(次数 · 台数)</h2>' + table((s.actions || []).map((a) =>
      [ACTION_LABELS[a.action] || a.action, a.total + " 次 · " + a.installs + " 台"])) + "</div>" +
    '<div class="card"><h2>歌词结果(首)</h2>' + table((s.lyrics || []).map((r) => [LYRICS_LABELS[r.result] || r.result, r.songs]),
      (s.lyrics || []).reduce((n, r) => n + r.songs, 0)) + "</div>" +
    '<div class="card"><h2>歌曲语言(首)</h2>' + table((s.languages || []).filter((r) => r.songs > 0).map((r) => [LANGUAGE_LABELS[r.language] || r.language, r.songs]),
      (s.languages || []).reduce((n, r) => n + r.songs, 0)) + "</div>" +
    '<div class="card"><h2>歌词来源(首,逐字 / 逐行 / 纯文本)</h2>' + table(((s.lyric_sources || {}).sources || []).map((r) =>
      [r.source + "(" + r.word + " / " + r.line + " / " + r.plain + ")", r.songs]),
      ((s.lyric_sources || {}).sources || []).reduce((n, r) => n + r.songs, 0)) + "</div></div>";
  const hg = s.hangs || {};
  if (hg.detailed) {
    const ctx = hg.context || {};
    html += '<div class="grid">' + [["duration", "卡顿时长"], ["since_launch", "启动后多久"], ["since_wake", "唤醒后多久"],
      ["player", "最近放歌的播放器"], ["windows", "开着的窗口"], ["thermal", "温度状态"]].map(([k, label]) =>
      '<div class="card"><h2>' + label + "(带概况的 " + hg.detailed + " 次)</h2>" + table(ctx[k] || [], hg.detailed) + "</div>").join("") + "</div>";
    html += '<div class="card"><h2>卡顿(按卡住的位置)</h2>' + (hg.hotspots || []).map((h) =>
      "<details><summary><b>" + h.n + " 次 · " + h.installs + " 台</b> " + esc(h.signature) + ' <span class="muted">' +
      esc(h.min_version) + (h.max_version !== h.min_version ? "–" + esc(h.max_version) : "") + "</span></summary><pre>" +
      esc([...(h.stack || []).map(frameLine), "时长: " + h.duration.map(([k, v]) => k + " " + v).join(" · "),
           "唤醒后: " + h.since_wake.map(([k, v]) => k + " " + v).join(" · "),
           "窗口: " + h.windows.map(([k, v]) => k + " " + v).join(" · ")].join("\\n")) + "</pre></details>").join("") + "</div>";
  }
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
  $("msg").textContent = "窗口:" + s.since + " 起(北京时间) " + s.window_days + " 天 · " + s.machines + " 台机器";
  render(s);
}
$("f").addEventListener("submit", (e) => { e.preventDefault(); load(); });
if ($("token").value) load();
</script>
</body>
</html>`;
