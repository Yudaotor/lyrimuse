// Cloudflare Worker: legacy redirect for the link pasted into Feishu's
// personal signature ("Apple Music now playing").
//
// This Worker used to also handle Feishu's url.preview.get callback (POST
// /feishu) — reading ListenBrainz and building an inline card with an
// uploaded cover image. That flow was retired in favor of feishu-bot's
// long-lived connection (see repo README); Feishu no longer calls back to
// this Worker at all, only its URL-rule string-matching cares that the link
// exists. The card-building code (getNowPlaying/buildCard/resolveImageKey/
// uploadArt/tenantToken, ~120 lines) was dead — deleted. All that's left is
// the plain redirect for a human clicking the pasted link.
//
// Env (wrangler.toml [vars]):
//   LB_USER       ListenBrainz username, used only in the redirect fallback
//   WEB_CARD_URL  page to redirect to

export default {
  async fetch(request, env) {
    const target = env.WEB_CARD_URL || "https://listenbrainz.org/user/" + (env.LB_USER || "");
    return Response.redirect(target, 302);
  },
};
