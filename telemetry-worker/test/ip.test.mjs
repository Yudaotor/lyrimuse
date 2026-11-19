// node --test test/(在 telemetry-worker 目录下跑)
import test from "node:test";
import assert from "node:assert/strict";
import { quotaIPKey } from "../src/ip.js";

test("同一 /56 下的不同 IPv6 地址共用一个键", () => {
  const a = quotaIPKey("2001:db8:1:2ff:a:b:c:d");
  assert.equal(a, "2001:db8:1:200:0:0:0:0/56");
  for (const ip of ["2001:db8:1:200::1", "2001:0DB8:0001:02aa:ffff:ffff:ffff:ffff", "2001:db8:1:2ab::", "2001:db8:1:200::1%en0"]) {
    assert.equal(quotaIPKey(ip), a, ip);
  }
});

test("不同 /56 分开计", () => {
  const a = quotaIPKey("2001:db8:1:200::1");
  assert.notEqual(quotaIPKey("2001:db8:1:300::1"), a);
  assert.notEqual(quotaIPKey("2001:db8:2:200::1"), a);
  assert.notEqual(quotaIPKey("2001:db9:1:200::1"), a);
});

test("IPv4 不变", () => {
  assert.equal(quotaIPKey("198.51.100.7"), "198.51.100.7");
  assert.notEqual(quotaIPKey("198.51.100.8"), quotaIPKey("198.51.100.7"));
});

test("IPv4 映射的 IPv6 按里面的 IPv4 计", () => {
  assert.equal(quotaIPKey("::ffff:198.51.100.7"), "198.51.100.7");
  assert.equal(quotaIPKey("::FFFF:c633:6407"), "198.51.100.7");
  assert.equal(quotaIPKey("0:0:0:0:0:ffff:198.51.100.7"), "198.51.100.7");
  assert.notEqual(quotaIPKey("::ffff:198.51.100.8"), "198.51.100.7");
});

test("压缩写法、首尾的 ::、末尾带 IPv4 的写法都认得", () => {
  assert.equal(quotaIPKey("::1"), "0:0:0:0:0:0:0:0/56");
  assert.equal(quotaIPKey("fe80::"), "fe80:0:0:0:0:0:0:0/56");
  assert.equal(quotaIPKey("64:ff9b::198.51.100.7"), "64:ff9b:0:0:0:0:0:0/56");
  assert.equal(quotaIPKey("1:2:3:4:5:6:198.51.100.7"), "1:2:3:0:0:0:0:0/56");
});

test("认不出的原样当键,缺头当 unknown", () => {
  assert.equal(quotaIPKey(null), "unknown");
  assert.equal(quotaIPKey(""), "unknown");
  for (const bad of ["1:2:3", "1::2::3", "gggg::1", "1:2:3:4:5:6:7:8:9", "::ffff:300.1.1.1", "1:2:3:4:5:6:7::8:9"]) {
    assert.equal(quotaIPKey(bad), bad, bad);
  }
});
