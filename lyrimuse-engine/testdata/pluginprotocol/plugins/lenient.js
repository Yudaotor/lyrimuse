// 跟 relay.js 的 search 一样问上游,但 ctx.fetch 抛的错误一律接住、当成没问到,交空数组。
module.exports = {
  lyrics: {
    async search(q, ctx) {
      let res;
      try {
        res = await ctx.fetch("https://lyrics.example/search?title=" + encodeURIComponent(q.search.title) +
          "&artist=" + encodeURIComponent(q.search.artist));
      } catch (e) {
        return [];
      }
      if (res.status !== 200) return [];
      return JSON.parse(res.body).items;
    },
  },
};
