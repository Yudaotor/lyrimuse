# telemetry-worker

Receives Lyrimuse's anonymous usage data ("Share Anonymous Usage Data" in Settings › About › Diagnostics & Data, on by default). It runs on Cloudflare Workers with a D1 database at `telemetry.yudaotor.me`.

| Endpoint | What |
|---|---|
| `POST /v1/heartbeat` | At most one per machine per day: random install ID, app and macOS version, chip, languages, which features are on, which built-in players played music and how many hangs on previous days |
| `POST /v1/crash` | One summary per crash report: exception, termination reason, top frames of the crashed thread and, for an uncaught exception, of the backtrace where it was thrown (paths already removed by the app) |
| `GET /v1/stats` | Aggregates; needs `Authorization: Bearer <ADMIN_TOKEN>`. `days=1..180`; `include_excluded=1` also counts the installs in `excluded_installs` (our own machines) |
| `GET /` | Dashboard that reads `/v1/stats` with the token |

Only whitelisted fields are stored; strings and lists are truncated. No IP addresses are stored, only the country code Cloudflare derives from the request. The app never sends song titles, artists, local paths, account names or credentials (see `lyrimuse/Sources/LyrimuseCore/Telemetry/Telemetry.swift`).

## Deploy

```sh
npx wrangler d1 create lyrimuse-telemetry          # first time only; put the id into wrangler.toml
npx wrangler d1 execute lyrimuse-telemetry --remote --file schema.sql
npx wrangler deploy
npx wrangler secret put ADMIN_TOKEN
```

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

---

接收 Lyrimuse 的匿名使用数据（设置 › 关于 › 诊断与数据「发送匿名使用数据」，默认开），跑在 Cloudflare Workers + D1 上，域名 `telemetry.yudaotor.me`。只存白名单字段，不存 IP，只存 Cloudflare 按 IP 给的国家 / 地区码；App 另报系统设置里的地区（`system_region`）。App 不发歌名、歌手、本机路径、账号名和凭据。部署步骤同上；上面列的这几列之前建的库，部署前先按对应的 `ALTER TABLE` 各补一次。
