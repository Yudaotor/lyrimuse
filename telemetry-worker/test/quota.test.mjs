// 直接 import index.js,用 node:sqlite 当 D1,验按 IP 的限额(quota())按 quotaIPKey 的键计。
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
// INGEST_LIMITER 的假绑定:记下每次拿来计数的键。
const limiterKeys = [];
const env = { DB, ADMIN_TOKEN: "local-test-token", INGEST_LIMITER: { limit: async ({ key }) => { limiterKeys.push(key); return { success: true }; } } };
const today = new Date().toISOString().slice(0, 10);
const beat = (installID) => ({ v: 1, install_id: installID, day: today, env: { app_version: "9.9.9" }, features: {} });
const post = (path, body, ip) => worker.fetch(new Request("http://local" + path, {
  method: "POST", headers: { "content-type": "application/json", "cf-connecting-ip": ip }, body: JSON.stringify(body),
}), env);
const heartbeats = async (ips, installID = randomUUID()) => {
  const codes = [];
  for (const ip of ips) codes.push((await post("/v1/heartbeat", beat(installID), ip)).status);
  return codes;
};
// 每条用例各用一段前缀,同一分钟的计数不串。
let seq = 0;
const block = () => `2001:db8:${(++seq).toString(16)}`;

test("同一 /56 里每次换源地址:心跳第 6 条起 429", async () => {
  const p = block();
  const ips = Array.from({ length: 7 }, (_, i) => `${p}:${(i * 0x11).toString(16)}:${i}::${i + 1}`);
  assert.deepEqual(await heartbeats(ips), [200, 200, 200, 200, 200, 429, 429]);
});

test("不同 /56 各计各的", async () => {
  const p = block(), q = block();
  assert.deepEqual(await heartbeats(Array(5).fill(`${p}::1`)), [200, 200, 200, 200, 200]);
  assert.deepEqual(await heartbeats([`${q}::1`, `${p}:ff::1`]), [200, 429]);
});

test("IPv4 照旧按完整地址计", async () => {
  assert.deepEqual(await heartbeats(Array(6).fill("198.51.100.7")), [200, 200, 200, 200, 200, 429]);
  assert.deepEqual(await heartbeats(["198.51.100.8"]), [200]);
});

test("IPv4 映射的 IPv6 跟同一个 IPv4 共用名额", async () => {
  assert.deepEqual(await heartbeats([...Array(3).fill("203.0.113.9"), ...Array(3).fill("::ffff:203.0.113.9")]),
                   [200, 200, 200, 200, 200, 429]);
});

test("新安装 ID 每天 20 个按 /56 计", async () => {
  const p = block();
  // 每条心跳换一个地址、一个新安装 ID;心跳每分钟 5 条的限额会先挡住,所以每 5 条换一段 /64 也不行,这里直接写心跳计数。
  const codes = [];
  for (let i = 0; i < 21; i++) {
    db.exec(`DELETE FROM ingest_quota WHERE kind = 'heartbeat'`);
    codes.push((await post("/v1/heartbeat", beat(randomUUID()), `${p}:${i.toString(16)}::1`)).status);
  }
  assert.deepEqual(codes, [...Array(20).fill(200), 429]);
});

test("崩溃每分钟 30 份按 /56 计,超了 503", async () => {
  const p = block(), iid = randomUUID(), codes = [];
  for (let i = 0; i < 31; i++) {
    const r = await post("/v1/crash", { v: 1, install_id: iid, report_id: i.toString(16).padStart(16, "0"), process: "app", frames: [] },
                         `${p}:${i.toString(16)}::${i + 1}`);
    codes.push(r.status);
  }
  assert.deepEqual(codes.slice(0, 30).every((c) => c === 200), true);
  assert.equal(codes[30], 503);
});

test("INGEST_LIMITER 也按前缀计", async () => {
  const p = block();
  limiterKeys.length = 0;
  await heartbeats([`${p}::1`, `${p}:ab:cd:ef:1:2`, "198.51.100.20"]);
  assert.deepEqual(limiterKeys, [`${p}:0:0:0:0:0/56`, `${p}:0:0:0:0:0/56`, "198.51.100.20"]);
});
