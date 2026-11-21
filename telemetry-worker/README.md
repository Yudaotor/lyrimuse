# telemetry-worker

Receives Lyrimuse's anonymous usage data ("Share Anonymous Usage Data" in Settings › About › Diagnostics & Data, on by default). It runs on Cloudflare Workers with a D1 database at `telemetry.yudaotor.me`.

| Endpoint | What |
|---|---|
| `POST /v1/heartbeat` | At most one per machine per day: random install ID, app and macOS version, chip, languages, which features are on, which built-in players played music and how many hangs on previous days, how many songs got each lyrics tier and which lyric source each word-synced, line-synced or plain-text one came from |
| `POST /v1/crash` | One summary per crash report: exception, termination reason, top frames of the crashed thread and, for an uncaught exception, of the backtrace where it was thrown (paths already removed by the app) |
| `GET /v1/stats` | Aggregates; needs `Authorization: Bearer <ADMIN_TOKEN>`. `days=1..180`; `include_excluded=1` also counts the installs in `excluded_installs` (our own machines) |
| `GET /v1/stats/bundle` | Same aggregates for several windows in one request (`days=7,30,90,180`), as `{windows, windows_all}` (without / with `excluded_installs`); each table is read once. D1 free tier bills rows read, so the SecondBrain panel's hourly pull uses this |
| `GET /` | Dashboard that reads `/v1/stats` with the token |

Only whitelisted fields are stored; strings and lists are truncated. No IP addresses are stored, only the country code Cloudflare derives from the request.

Request bodies over 64 KB (counted in bytes) get `413`. Dates must be real calendar days (`2026-13-01` or `2026-11-31` get `400`); activity days up to 30 days before the heartbeat's day are kept. Per source IP (an IPv6 address counts by its /56 prefix, so rotating addresses inside one network doesn't reset the count; an IPv4-mapped IPv6 address counts as its IPv4 address), at most 5 heartbeats a minute, 20 new install IDs a day and 30 crash reports a minute are accepted; past that heartbeats get `429` and crash reports `503` (the app retries both later). The counters live in the `ingest_quota` table, keyed by a keyed HMAC of the IP and the time window (the IP itself is never stored), and rows older than two windows are deleted as new ones are written. A crash report without its own app version is stored with the version of the app that sent it. The app never sends song titles, artists, local paths, account names or credentials (see `lyrimuse/Sources/LyrimuseCore/Telemetry/Telemetry.swift`).

## Deploy

```sh
npx wrangler d1 create lyrimuse-telemetry          # first time only; put the id into wrangler.toml
npx wrangler d1 execute lyrimuse-telemetry --remote --file schema.sql
npx wrangler@4 deploy
npx wrangler secret put ADMIN_TOKEN
```

Deploy with wrangler 4: wrangler 3 drops the `[[ratelimits]]` binding.

A database created before the `exception_frames` column existed needs it added once, before deploying the worker that writes it:

```sh
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE crashes ADD COLUMN exception_frames TEXT"
```

Same for `installs.origin` (new install vs. upgraded from an older version):

```sh
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE installs ADD COLUMN origin TEXT"
```

And for the later columns: `activity.actions`, `activity.lyrics`, `activity.languages` and `heartbeats.system_region` (the region set in macOS settings):

```sh
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE activity ADD COLUMN actions TEXT"
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE activity ADD COLUMN lyrics TEXT"
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE activity ADD COLUMN languages TEXT"
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE heartbeats ADD COLUMN system_region TEXT"
```

The `hang_events` table (per-hang summaries carried in each day's activity) is created by `schema.sql`; on an existing database run the file again before deploying (every statement is `IF NOT EXISTS`):

```sh
npx wrangler d1 execute lyrimuse-telemetry --remote --file schema.sql
```

Hangs during which the main thread was held back by the system (screen locked, or App Nap dropping it to background priority) carry a `throttled` flag. `/v1/stats` leaves them out of `hangs` and counts them in `hangs_all`. The two columns for them, added once before deploying:

```sh
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE activity ADD COLUMN throttled_hangs INTEGER"
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE hang_events ADD COLUMN throttled TEXT"
```

Each hang summary also carries the tightest system memory pressure seen during the stall (`normal` / `warning` / `critical`) and how many pages the app had to read back in (page-ins) meanwhile, so a hang where the main thread waited on paging can be told apart from slow code. Older apps don't send them; both columns stay empty. Added once before deploying:

```sh
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE hang_events ADD COLUMN memory_pressure TEXT"
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE hang_events ADD COLUMN pageins INTEGER"
```

Each hang summary also carries how much CPU time the main thread used during the stall (`main_cpu_ms`, milliseconds): close to the stall's length means it was busy computing, close to zero means it was waiting (on WindowServer, a lock, a reply) or not getting the CPU. Older apps don't send it; the column stays empty. Added once before deploying:

```sh
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE hang_events ADD COLUMN main_cpu_ms INTEGER"
```

Stalls started on purpose from a debug link (`debug/main-thread-stall`) or the `--debug-launch-stall` launch argument carry `simulated: true` in their hang summary. The app doesn't count them in the day's `hangs`; the Worker still stores the summary (`hang_events.simulated = 1`) but `/v1/stats` leaves it out. Added once before deploying:

```sh
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE hang_events ADD COLUMN simulated INTEGER"
```

When the Settings window is open, a hang summary also says which page it was on (`settings_page`): the `lyrimuse://settings/<path>` path, plus the section on pages that have one (`lyrics/display`, `account/lastfm/stats`). Values outside `HANG_SETTINGS_PAGES` (the same list as Core `TelemetryHang.settingsPages`) are stored as empty, as are older apps. `/v1/stats` adds a `settings_page` distribution to the hang context and each hotspot; hangs with Settings closed count as `(settings closed)`, Settings open without a page (older apps) as `(not reported)`. Added once before deploying:

```sh
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE hang_events ADD COLUMN settings_page TEXT"
```

`activity.lyric_sources` counts, per day, which lyric source the shown lyrics came from for each word-synced, line-synced or plain-text song (keys like `netease:line`, sources and tiers from a fixed list). `/v1/stats` returns it as `lyric_sources`. Added once before deploying:

```sh
npx wrangler d1 execute lyrimuse-telemetry --remote --command "ALTER TABLE activity ADD COLUMN lyric_sources TEXT"
```

The per-IP limits need the `ingest_quota` table; on an existing database run `schema.sql` again before deploying (every statement is `IF NOT EXISTS`).

## Tests

```sh
npm test    # node --test: the IP prefix key, and the per-IP limits against index.js with node:sqlite standing in for D1
```

---

接收 Lyrimuse 的匿名使用数据（设置 › 关于 › 诊断与数据「发送匿名使用数据」，默认开），跑在 Cloudflare Workers + D1 上，域名 `telemetry.yudaotor.me`。只存白名单字段，不存 IP，只存 Cloudflare 按 IP 给的国家 / 地区码；App 另报系统设置里的地区（`system_region`）。请求体超过 64 KB（按字节）回 413；日期要是真实存在的公历日期；活动最多收心跳那天之前 30 天的。按来源 IP 限额（IPv6 按前 56 位算一个来源，同一段里换源地址不重新计；IPv4 映射的 IPv6 按里面的 IPv4 算）：心跳每分钟 5 条、新安装 ID 每天 20 个、崩溃每分钟 30 份，超了心跳回 429、崩溃回 503，App 都会下次再发；计数在 `ingest_quota` 表，键是 IP 加时间窗的带密钥 HMAC，不存 IP 本身，旧时间窗的行随写随删。App 不发歌名、歌手、本机路径、账号名和凭据。部署步骤同上（用 wrangler 4 部署）；上面列的这几列之前建的库，部署前先按对应的 `ALTER TABLE` 各补一次，`ingest_quota` 表重跑一遍 `schema.sql` 建出来。单测：`npm test`（node 自带的测试，D1 用 `node:sqlite` 代）。
