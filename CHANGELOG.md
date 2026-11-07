# Changelog

## Unreleased

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
