# Security Policy

## Supported versions

Lyrimuse is maintained by one person. Only the latest release gets security
fixes; there are no long-term support branches.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Anything older | No |

The app updates itself through Sparkle, so staying current usually takes no
action. `brew upgrade --cask lyrimuse` works too.

## Reporting a vulnerability

Report privately through
[GitHub private vulnerability reporting](https://github.com/Yudaotor/lyrimuse/security/advisories/new),
under this repository's **Security** tab. Please don't open a public issue for
anything you think is exploitable.

Useful things to include: the version, your macOS version, what an attacker
gains, and the smallest reproduction you have.

What to expect, best effort from a side project with no bug bounty:

- Acknowledgement within 7 days.
- An assessment within 30 days, and either a fix or an explanation of why I
  don't consider it a vulnerability.
- Credit in the release notes, if you want it.

If something is already being exploited in the wild, say so and I'll treat it
accordingly.

## What the app touches

Worth knowing before you look for issues:

- **No listening sockets.** Neither the menu-bar app nor the background helper
  (`com.lyrimuse.collector`, a launchd agent) opens one. All network activity is
  outbound.
- **Credentials sit in a file, not the Keychain.** The Last.fm session key and
  the ListenBrainz token live in `~/.config/lyrimuse/config.json`, written
  atomically with mode `0600`. Anything that can read your user's files can read
  them. If your machine is compromised, revoke those tokens at Last.fm and
  ListenBrainz.
- **Logs and diagnostic exports go through a redactor** that removes known
  credential values, sensitive query parameters (`api_key`, `token`, `sk`,
  `session_key`, ...), and credentials carried in URL paths. If you find a way to
  get a live credential into a log or an export, that is a bug worth reporting.
- **Outbound traffic** goes to the lyrics and metadata providers, and to Last.fm
  and ListenBrainz once you connect those accounts.
- **Nothing leaves your Mac for a third-party service by default.** Pushing
  now-playing state to a relay is opt-in: it only happens if you set
  `state_relay_url` yourself, and there is no default relay compiled into the
  app.
- **Automation permission.** The app asks for macOS Automation access so it can
  send Apple Events to media players and browsers to read the current track. It
  is not sandboxed.
- **Updates** are delivered by Sparkle over HTTPS from GitHub Releases and are
  verified against an EdDSA public key pinned in the app bundle. A malicious
  appcast alone is not enough to install anything.

## Known limitations

These are deliberate trade-offs, not undisclosed bugs. Please don't report them
as vulnerabilities, but do tell me if you think the reasoning is wrong.

- **Builds are signed ad hoc.** There is no Apple Developer ID signature and no
  notarization, so the signature does not identify a publisher and Gatekeeper
  warns on first launch. To check you got the real file, compare it against the
  `.sha256` published alongside each release, install through the Homebrew cask
  (which pins a checksum), or build from source.
- **Credentials are not in the Keychain**, as described above.

## Scope

In scope: this repository, the released app and its background helper, and the
Homebrew tap at `Yudaotor/homebrew-lyrimuse`.

Out of scope: the third-party lyrics, metadata and scrobbling services the app
talks to. Report those to the service in question.
