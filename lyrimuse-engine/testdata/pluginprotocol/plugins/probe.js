// 按 query.title 选一种行为,把看到的东西写进结果的 lyrics.plain,让线上的另一头核对 plugin-host 交给脚本的是什么。
// 抛 fetch 错误的探针由 search 接住、交空数组;hang / spin / hog / throw / bad-result 这几种不经过这层。
const base = "https://lyrics.example";

function describe(res) {
  const body = typeof res.body === "string" ? res.body : Array.from(res.body).join(",");
  return [res.status, res.url, res.redirected, body].join("\n");
}

const probes = {
  "get": async (ctx) => describe(await ctx.fetch(base + "/echo")),
  "post": async (ctx) => describe(await ctx.fetch(base + "/submit", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Fixture": "1" },
    body: "{\"k\":1}",
  })),
  "bytes": async (ctx) => describe(await ctx.fetch(base + "/blob", { responseType: "bytes" })),
  "headers": async (ctx) => {
    const res = await ctx.fetch(base + "/cookies");
    return [res.headers.get("X-Fixture"), res.headers.getSetCookie().join("|")].join("\n");
  },
  "offlist": async (ctx) => describe(await ctx.fetch("https://not-declared.example/x")),
  "forbidden-header": async (ctx) => describe(await ctx.fetch(base + "/echo", { headers: { Host: "other.example" } })),
  "timeout": async (ctx) => describe(await ctx.fetch(base + "/slow", { timeoutMs: 100 })),
  "large": async (ctx) => describe(await ctx.fetch(base + "/large")),
  "redirect-follow": async (ctx) => describe(await ctx.fetch(base + "/moved")),
  "redirect-manual": async (ctx) => {
    const res = await ctx.fetch(base + "/moved", { redirect: "manual" });
    return [res.status, res.headers.get("location"), res.redirected].join("\n");
  },
  "redirect-offlist": async (ctx) => describe(await ctx.fetch(base + "/leaves")),
  "redirect-loop": async (ctx) => describe(await ctx.fetch(base + "/loop/0")),
  "twice": async (ctx) => {
    const first = await ctx.fetch(base + "/echo");
    const second = await ctx.fetch(base + "/echo");
    return [first.status, second.status].join("\n");
  },
  "parallel": async (ctx) => {
    const [a, b] = await Promise.all([ctx.fetch(base + "/a"), ctx.fetch(base + "/b")]);
    return [a.body, b.body].join("\n");
  },
  "retry-after-429": async (ctx) => {
    const first = await ctx.fetch(base + "/limited");
    if (first.status !== 429) return String(first.status);
    await ctx.fetch(base + "/limited");
    return "unreachable";
  },
  "abort-own": async (ctx) => {
    const controller = new AbortController();
    const pending = ctx.fetch(base + "/slow", { signal: controller.signal });
    controller.abort();
    try {
      await pending;
      return "completed";
    } catch (e) {
      return "aborted";
    }
  },
  "storage": async (ctx) => {
    await ctx.storage.set("token", { v: 1 }, { ttlSecs: 60 });
    const got = await ctx.storage.get("token");
    const keys = await ctx.storage.keys();
    await ctx.storage.delete("token");
    const gone = await ctx.storage.get("token");
    return [JSON.stringify(got), keys.join(","), String(gone)].join("\n");
  },
  "storage-quota": async (ctx) => {
    await ctx.storage.set("big", "x".repeat(300000));
    return "stored";
  },
  "log": async (ctx) => {
    ctx.log("fixture says hi");
    return describe(await ctx.fetch(base + "/echo"));
  },
  "big-result": async () => "x".repeat(5000),
  "external-ids": async (ctx, q) => JSON.stringify(q.externalIds === undefined ? null : q.externalIds),
  "none": async () => "no requests",
};

module.exports = {
  lyrics: {
    async search(q, ctx) {
      if (q.title === "hang") return new Promise(() => {});
      if (q.title === "spin") for (;;) {}
      if (q.title === "hog") {
        const chunks = [];
        for (;;) chunks.push(new Array(1 << 16).fill(chunks.length));
      }
      if (q.title === "throw") throw new TypeError("fixture: script bug");
      if (q.title === "unknown-code") throw ctx.error("not a code");
      if (q.title === "bad-result") return "not an array";
      if (q.title === "empty") return [];
      let plain;
      try {
        plain = await probes[q.title](ctx, q);
      } catch (e) {
        return [];
      }
      return [{ id: q.title, title: q.title, artist: q.artist, lyrics: { plain } }];
    },
    async getLyrics(item, ctx) {
      if (item.id === "bad-result") return ["not an object"];
      return { plain: JSON.stringify(item) };
    },
  },
};
