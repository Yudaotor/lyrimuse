// 只导出 lyrics.search:搜索结果自带歌词,不写 getLyrics。上游 200 的正文是 {items: [...]}。
module.exports = {
  lyrics: {
    async search(q, ctx) {
      const res = await ctx.fetch("https://lyrics.example/search?title=" + encodeURIComponent(q.search.title) +
        "&artist=" + encodeURIComponent(q.search.artist));
      if (res.status !== 200) return [];
      return JSON.parse(res.body).items;
    },
  },
};
