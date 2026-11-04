-- Lyrimuse 匿名遥测的 D1 表。不存 IP;country 是 Cloudflare 按 IP 给的两字母国家/地区码。
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
  PRIMARY KEY (day, install_id)
);
CREATE INDEX IF NOT EXISTS heartbeats_day ON heartbeats(day);

CREATE TABLE IF NOT EXISTS activity (
  day            TEXT NOT NULL,
  install_id     TEXT NOT NULL,
  players_played TEXT,
  hangs          INTEGER NOT NULL DEFAULT 0,
  actions        TEXT,  -- {"lyrics_window": 2, …},见 index.js 的 ACTIONS
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

-- 不进统计的安装(作者自己的机器、测试机):/v1/stats 的每条查询都跳过它们,原始数据照存;删掉一行即恢复统计。
CREATE TABLE IF NOT EXISTS excluded_installs (
  install_id TEXT PRIMARY KEY,
  note       TEXT,
  added_day  TEXT NOT NULL
);
