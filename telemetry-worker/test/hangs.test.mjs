// 直接 import index.js,用 node:sqlite 当 D1,验卡顿概况入库与 /v1/stats 的口径。
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import worker from "../src/index.js";

const db = new DatabaseSync(":memory:");
db.exec(readFileSync(new URL("../schema.sql", import.meta.url), "utf8"));
const stmt = (sql, args = []) => ({
  bind: (...b) => stmt(sql, b),
  all: async () => ({ results: db.prepare(sql).all(...args).map((r) => ({ ...r })), success: true, meta: {} }),
  first: async () => { const r = db.prepare(sql).all(...args)[0]; return r ? { ...r } : null; },
  run: async () => { db.prepare(sql).run(...args); return { success: true, meta: {} }; },
  exec: () => ({ results: db.prepare(sql).all(...args).map((r) => ({ ...r })) }),
});
const DB = {
  prepare: (sql) => stmt(sql),
  batch: async (list) => {
    db.exec("BEGIN");
    try { const out = list.map((s) => s.exec()); db.exec("COMMIT"); return out; } catch (e) { db.exec("ROLLBACK"); throw e; }
  },
};
const env = { DB, ADMIN_TOKEN: "local-test-token", INGEST_LIMITER: { limit: async () => ({ success: true }) } };
const today = new Date().toISOString().slice(0, 10);
const yesterday = new Date(Date.now() - 86400e3).toISOString().slice(0, 10);
const hang = (extra = {}) => ({ duration: "5-10s", since_launch: "<1m", windows: [], thermal: "nominal", stack: [], ...extra });
let ipSeq = 0;
const beat = (installID, hangs, details) => worker.fetch(new Request("http://local/v1/heartbeat", {
  method: "POST", headers: { "content-type": "application/json", "cf-connecting-ip": `198.51.100.${++ipSeq}` },
  body: JSON.stringify({ v: 1, install_id: installID, day: today, env: { app_version: "9.9.9" }, features: {},
                         activity: [{ day: yesterday, hangs, hang_details: details }] }),
}), env);
const stats = async () => (await worker.fetch(new Request("http://local/v1/stats?days=7", {
  headers: { authorization: "Bearer " + env.ADMIN_TOKEN },
}), env)).json();
const stored = (installID) => db.prepare(`SELECT seq, simulated FROM hang_events WHERE install_id = ? ORDER BY seq`).all(installID)
  .map((r) => r.simulated);

test("模拟的卡顿概况照存、统计不算;不计进次数的模拟概况也收得进来", async () => {
  const mixed = randomUUID(), onlySimulated = randomUUID(), notTrue = randomUUID();
  assert.equal((await beat(mixed, 1, [hang(), hang({ simulated: true, duration: "10-30s" })])).status, 200);
  assert.equal((await beat(onlySimulated, 0, [hang({ simulated: true })])).status, 200);
  assert.equal((await beat(notTrue, 1, [hang({ simulated: "yes" }), hang({ simulated: true })])).status, 200);
  assert.deepEqual(stored(mixed), [null, 1]);
  assert.deepEqual(stored(onlySimulated), [1]);
  assert.deepEqual(stored(notTrue), [null, 1]);
  const s = await stats();
  for (const view of [s.hangs, s.hangs_all]) {
    assert.equal(view.total, 2);
    assert.equal(view.detailed, 2);
    assert.deepEqual(view.context.duration, [["5-10s", 2]]);
  }
});

test("没带模拟标记的概况照旧不超过当天报的卡顿次数", async () => {
  const id = randomUUID();
  assert.equal((await beat(id, 1, [hang(), hang(), hang()])).status, 200);
  assert.deepEqual(stored(id), [null]);
});

test("设置页按名单收,名单外的记空;统计按页分,设置窗口没开、开着没报页的各一档", async () => {
  const id = randomUUID();
  const settings = { windows: ["settings"] };
  assert.equal((await beat(id, 3, [hang({ ...settings, settings_page: "account/lastfm/stats" }),
                                   hang({ ...settings, settings_page: "/Users/me/Music" }), hang(settings)])).status, 200);
  assert.deepEqual(db.prepare(`SELECT settings_page FROM hang_events WHERE install_id = ? ORDER BY seq`).all(id).map((r) => r.settings_page),
                   ["account/lastfm/stats", null, null]);
  const s = await stats();
  const page = Object.fromEntries(s.hangs.context.settings_page);
  assert.equal(page["account/lastfm/stats"], 1);
  assert.equal(page["(not reported)"], 2);
  assert.ok(page["(settings closed)"] > 0);
  assert.equal(Object.values(page).reduce((n, v) => n + v, 0), s.hangs.detailed);
  const hotspot = s.hangs.hotspots.find((h) => h.settings_page.some(([k]) => k === "account/lastfm/stats"));
  assert.ok(hotspot);
});
