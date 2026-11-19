# Changelog

## 0.2.0 - 2026-11-19

Needs a Ravensight server with `POST /identify` and `identify.salt` on the
session answer; until then identify sends nothing.

### Added

- `Ravensight.identify(player, accountId)`, `Ravensight.resetIdentity(player)` and `Ravensight.isIdentified(player)` for games with their own account system on top of Roblox. Only a salted hash of the id (`accountHash`, HMAC-SHA256 keyed with Ravensight's identify salt from the session answer) is sent, with the player's session token, once per session; the raw id is never sent or saved and is held in memory only until the salt is known. The hash is saved in the player's DataStore entry at once. A value that is not a string or whole number, is empty, is over 256 bytes of UTF-8, contains `@`, or is the player's UserId, name or display name is refused (`false` and the reason, one warning). A failed or refused request is tried again at the next session, never in a loop; a second `no_session` answer in a row stops identify for the player until `resetIdentity`. Before the player's opt-in yes nothing is saved or sent, and opting out deletes the saved hash. A call before the player's saved state has loaded is held and applied when it has. A different account first resets the identity. `resetIdentity` switches the player to a fresh random device id for the rest of the server visit only: the device id comes from the UserId, so the next visit is back on that id (see docs/FEASIBILITY.md).
- `Ravensight.setCampaignLink(player, linkId)`, and `rs_link` read from a join's launch data (query string or JSON, with `attributionFromLaunchData`): a link id (24 hex characters, sent lowercased) goes as `campaignLink` on the player's next session and is cleared only when that session answers with a token. Returns `true`, or `false` and the reason. Memory only, with the same consent rules as everything else. `Ravensight.campaignLinkFromLaunchData(launchData)` returns the link id a launch data carries.

### Changed

- The README opens with a preview line saying what has and has not been verified, and installs from the public repository's `v0.2.0` tag, with Rojo or by copying the files into Studio; it no longer names a package registry, since nothing is published to one. CI runs nightly on weekdays and on demand, not on pushes or pull requests, and a pre-push hook in `.githooks` runs the specs before every push.

## 0.1.0 - 2026-11-06

### Added

- First release of the Roblox SDK, version 0.1.0: a server-side SDK that
  reports on behalf of each player in the server, with one session, queue
  and opt-out per player.
- Device id as an HMAC-SHA256 of the UserId keyed with the game's salt.
- Delivery contract: queue format 2 with origins, saved in a DataStore at
  leave, at shutdown, every 120 seconds and on a privacy choice;
  `rs_event_id` on every event; the response table, backoff and
  `Retry-After`; signed requests when the session gives a secret.
- One request budget for the whole SDK (90 a minute by default).
- Typed events, ads, attribution (including `utm_*` from launch data),
  remote config with exposure tags per player, feedback.
- Optional capture of server script errors, scrubbed with the shared rules
  (scrub vectors version 6).
- `forgetPlayer(userId)` for erasure requests.
