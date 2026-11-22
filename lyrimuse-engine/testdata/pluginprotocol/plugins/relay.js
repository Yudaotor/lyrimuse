// 上游应答决定插件交什么:换用例只换 fixture.http,脚本不动。
// 上游 200 的正文是 JSON:带 throw 就照它抛错,否则 search 交 items、getLyrics 原样交正文。
// 请求失败不接:ctx.fetch 抛出来的错误原样冒出去。
function searchURL(q) {
  return "https://lyrics.example/search?title=" + encodeURIComponent(q.search.title) +
    "&artist=" + encodeURIComponent(q.search.artist);
}

async function getJSON(ctx, url) {
  const res = await ctx.fetch(url);
  if (res.status !== 200) return { status: res.status, body: null };
  return { status: 200, body: JSON.parse(res.body) };
}

module.exports = {
  lyrics: {
    async search(q, ctx) {
      const r = await getJSON(ctx, searchURL(q));
      if (r.status !== 200) return [];
      if (r.body.throw) throw ctx.error(r.body.throw.code, r.body.throw);
      return r.body.items;
    },
    async getLyrics(item, ctx) {
      const r = await getJSON(ctx, "https://lyrics.example/lyrics/" + encodeURIComponent(item.id));
      if (r.status === 404) throw ctx.error("NOT_FOUND");
      if (r.status !== 200) return {};
      if (r.body.throw) throw ctx.error(r.body.throw.code, r.body.throw);
      return r.body;
    },
  },
};
