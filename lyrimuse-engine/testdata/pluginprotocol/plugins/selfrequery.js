// 清单写了 requery: "self" 的插件:先按歌名加歌手搜,ctx.match 说没有一条过闸,再只按歌名搜一次。
async function searchOnce(ctx, title, artist) {
  const res = await ctx.fetch("https://lyrics.example/search?title=" + encodeURIComponent(title) +
    "&artist=" + encodeURIComponent(artist));
  if (res.status !== 200) return [];
  return JSON.parse(res.body).items;
}

module.exports = {
  lyrics: {
    async search(q, ctx) {
      let items = await searchOnce(ctx, q.cleanTitle, q.primaryArtist);
      const verdicts = await ctx.match(items);
      if (!verdicts.some((v) => v.accepted)) items = await searchOnce(ctx, q.cleanTitle, "");
      return items;
    },
  },
};
