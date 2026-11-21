-- Lyrimuse 匿名遥测的 D1 表。不存 IP;country 是 Cloudflare 按 IP 给的两字母国家/地区码,
-- system_region 是 App 报的系统设置里的地区(旧版本为空)。
CREATE TABLE IF NOT EXISTS installs (
  install_id TEXT PRIMARY KEY,
  first_day  TEXT NOT NULL,
  last_day   TEXT NOT NULL,
  origin     TEXT  -- new / existing,App 判不出或旧版本不发时为空
);

CREATE TABLE IF NOT EXISTS heartbeats (
  day             TEXT NOT NULL,
  install_id      TEXT NOT NULL,
  received_at     INTEGER NOT NULL,
  app_version     TEXT,
  build           TEXT,
  os_version      TEXT,
  arch            TEXT,
  ui_language     TEXT,
  system_language TEXT,
  country         TEXT,
  features        TEXT,
  system_region   TEXT,
  PRIMARY KEY (day, install_id)
);
CREATE INDEX IF NOT EXISTS heartbeats_day ON heartbeats(day);

CREATE TABLE IF NOT EXISTS activity (
  day            TEXT NOT NULL,
  install_id     TEXT NOT NULL,
  players_played TEXT,
  hangs          INTEGER NOT NULL DEFAULT 0,
  actions        TEXT,  -- {"lyrics_window": 2, …},见 index.js 的 ACTIONS
  lyrics         TEXT,  -- {"word": 12, "none": 1, …},见 index.js 的 LYRICS_RESULTS
  languages      TEXT,  -- {"zh": 8, "en": 3, …},见 index.js 的 SONG_LANGUAGES
  layout_limits  TEXT,  -- [{"window": "onboarding", "class": "SwiftUI.AppKitWindow", "pass": "layout", "count": 3}],见 index.js 的 cleanLayoutLimits;
                        -- 旧库:ALTER TABLE activity ADD COLUMN layout_limits TEXT
  throttled_hangs INTEGER,  -- hangs 里停顿期间主线程被系统压着(锁屏、App Nap)的次数,旧版 App 不报为空;
                            -- 旧库:ALTER TABLE activity ADD COLUMN throttled_hangs INTEGER
  lyric_sources  TEXT,  -- {"netease:line": 47, "qq:word": 12, …},逐字 / 逐行 / 纯文本的歌显示的那份各来自哪个源,见 index.js 的 lyricSourceCounts;
                        -- 旧版 App 不报为空。旧库:ALTER TABLE activity ADD COLUMN lyric_sources TEXT
  PRIMARY KEY (day, install_id)
);

CREATE TABLE IF NOT EXISTS crashes (
  install_id            TEXT NOT NULL,
  report_id             TEXT NOT NULL,
  received_at           INTEGER NOT NULL,
  day                   TEXT NOT NULL,
  process               TEXT,
  app_version           TEXT,
  os_version            TEXT,
  occurred_at           TEXT,
  exception_type        TEXT,
  exception_signal      TEXT,
  termination_namespace TEXT,
  termination_indicator TEXT,
  termination_reasons   TEXT,
  frames                TEXT,
  exception_frames      TEXT,
  signature             TEXT,
  env                   TEXT,
  PRIMARY KEY (install_id, report_id)
);
CREATE INDEX IF NOT EXISTS crashes_day ON crashes(day);

-- 主线程卡顿的概况(心跳活动里的 hang_details,每台每天最多 3 + 1 条);取值见 index.js 的 HANG_* 名单。
-- app_version / os_version / arch 取带它来的那条心跳的。
CREATE TABLE IF NOT EXISTS hang_events (
  day          TEXT NOT NULL,
  install_id   TEXT NOT NULL,
  seq          INTEGER NOT NULL,
  received_at  INTEGER NOT NULL,
  app_version  TEXT,
  os_version   TEXT,
  arch         TEXT,
  duration     TEXT,
  since_launch TEXT,
  since_wake   TEXT,
  player       TEXT,
  windows      TEXT,
  thermal      TEXT,
  stack        TEXT,
  signature    TEXT,
  throttled    TEXT,  -- ["locked", "low_priority"] 的子集(JSON),停顿期间主线程被系统压着;没被压着、旧版 App 为空。
                      -- 旧库:ALTER TABLE hang_events ADD COLUMN throttled TEXT
  memory_pressure TEXT,  -- normal / warning / critical:停顿期间看到的最紧的系统内存压力;旧版 App、读不到为空。
                         -- 旧库:ALTER TABLE hang_events ADD COLUMN memory_pressure TEXT
  pageins      INTEGER,  -- 停顿期间 App 进程的换页次数(page-in);旧版 App、读不到为空。
                         -- 旧库:ALTER TABLE hang_events ADD COLUMN pageins INTEGER
  main_cpu_ms  INTEGER,  -- 停顿期间主线程用掉的 CPU 时间(毫秒);旧版 App、读不到为空。
                         -- 旧库:ALTER TABLE hang_events ADD COLUMN main_cpu_ms INTEGER
  simulated    INTEGER,  -- 调试深链 / 启动参数故意造的停顿为 1,统计不算;真卡顿、旧版 App 为空。
                         -- 旧库:ALTER TABLE hang_events ADD COLUMN simulated INTEGER
  settings_page TEXT,    -- 卡住时设置窗口停在哪一页(lyrics/display、account/lastfm/stats 这类);设置窗口关着、旧版 App 为空。
                         -- 旧库:ALTER TABLE hang_events ADD COLUMN settings_page TEXT
  PRIMARY KEY (day, install_id, seq)
);
CREATE INDEX IF NOT EXISTS hang_events_day ON hang_events(day);

-- 不进统计的安装(作者自己的机器、测试机):/v1/stats 的每条查询都跳过它们,原始数据照存;删掉一行即恢复统计。
CREATE TABLE IF NOT EXISTS excluded_installs (
  install_id TEXT PRIMARY KEY,
  note       TEXT,
  added_day  TEXT NOT NULL
);

-- 按来源 IP 的限额计数(index.js 的 quota()):kind 是哪种限额(heartbeat / new_install / crash),win 是第几个时间窗
-- (按分钟或按天),ip_key 是 IP 的带密钥 HMAC 前 16 位十六进制,不存 IP 本身;两个时间窗以前的行随写随删。
CREATE TABLE IF NOT EXISTS ingest_quota (
  kind   TEXT NOT NULL,
  win    INTEGER NOT NULL,
  ip_key TEXT NOT NULL,
  n      INTEGER NOT NULL,
  PRIMARY KEY (kind, win, ip_key)
);
