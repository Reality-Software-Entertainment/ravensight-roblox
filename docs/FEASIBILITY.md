# Roblox: feasibility against the SDK contract

Checked on 2026-11-06 against the Roblox Engine API reference and the
Creator Hub guides for HttpService, DataStoreService, Players, ScriptContext
and DataModel. Nothing here has run inside Roblox yet: every verdict is
"documented", and the specs prove the logic under LuaJIT and Lua 5.4 with
Luau's `bit32` semantics, against fake engine services. The owner's first
Studio run is the observation step (see "Before release").

## The shape: a server-side SDK

Roblox lets only the game server make HTTP requests (`HttpService` refuses
on a client). So this SDK runs in a server Script and reports on behalf of
the players in that server. Every player gets their own core, with their
own device id, session, queue and opt-out, so the server sees the same
per-device contract every other SDK speaks. Events come from game code on
the server (`Ravensight.track(player, ...)`); anything that happens only on
a client reaches the SDK through the game's own RemoteEvents.

## Verdicts

| Contract need | Engine API | Verdict |
|---|---|---|
| HTTP with custom headers and a body | `HttpService:RequestAsync{Url, Method, Headers, Body}` answers `StatusCode`, `Headers`, `Body` for any status. Server only. Off until the game turns on Allow HTTP Requests. | Possible, documented. An error from `RequestAsync` (no network, HTTP not enabled) is status 0 and backs off; "not enabled" warns once. |
| Request budget | 500 HTTP requests a minute for each game server, shared with the game's own requests. | Degraded by design: the SDK spends at most `maxRequestsPerMinute` (default 90) through one token bucket, and batches every 15 seconds instead of 2. Shutdown ignores the bucket. 90 also stays under the ingest API's default per-address limit of 100 requests a minute, which every player in one server shares (item 9 below). |
| Persistent storage | `DataStoreService:GetDataStore(name)`: `GetAsync`, `SetAsync`, `RemoveAsync`, 4 MB a value, a per-server request budget that grows with the player count. | Degraded: the queue, the opt-out or opt-in and the attribution flag are kept in memory and saved in one entry per player when the player leaves, when the server shuts down, every 120 seconds while changed, and at once for a privacy choice. A server crash can lose up to 120 seconds of events. Two servers writing the same player at once: the last write wins. A failed read turns saving off for that player, so it never overwrites a good entry. |
| Atomic queue file | DataStore writes are whole-value. | Possible: each save replaces the entry whole. |
| gzip | `RequestAsync` has no body compression this SDK relies on. | Not used: every body is sent plain (the contract's SHOULD). |
| HMAC-SHA256 | No hash for scripts. | Possible: pure Luau SHA-256 over `bit32`, checked against the delivery contract's vectors with `bit32` semantics. |
| Device id | No device on a server. `Player.UserId` is the account. | Deviation: the device id is `HMAC-SHA256(salt, "roblox-user:" .. UserId)`, first 32 hex characters, then `-roblox`. The salt is the game's own secret (at least 16 characters, kept in ServerStorage). Stable for one player in one game, on every device they play from, and not reversible without the salt. Without a salt the SDK stays off. |
| Random bytes | `HttpService:GenerateGUID` | Used only for the per-launch nonce inside `rs_event_id`, where uniqueness is what matters. The engine does not document it as a cryptographic source. |
| Quit hook | `Players.PlayerRemoving`; `game:BindToClose` gives the server up to 30 seconds. | Possible: a leaving player gets `game_exited` and up to 10 seconds for the last batch; shutdown flushes every player within 25 seconds, then saves. |
| Background hook | None on a server. | Not applicable: a session is one visit to one server. A teleport to another place is a `game_exited` here and a `game_started` there. |
| Device fields | Model, OS and GPU are client-side only. | Omitted: the session carries `platform: "roblox"` and no `device` object. |
| Error capture | `ScriptContext.Error` on the server: message, stack trace, script. A connection observes and never swallows. | Degraded: off by default (`captureErrors = true` turns it on), server script errors only, all sent under one server device per game (a server error belongs to no player). No client errors, no log trail, no crash records. Caps, token bucket and the on-device scrub as the contract says. |
| Consent | The player's choice reaches the server through the game's own RemoteEvent; Roblox names the firing player. | Possible: `setTrackingEnabled(player, on)` saves at once. `consent = "opt_in"` sends nothing for a player until they say yes. |
| Remote config and exposure | Per player: `fetchConfig(player)`, `getConfig(player, key, fallback)`. | Possible: a read marks only that player's session as exposed. |
| Ads | No mediation callbacks on Roblox. | `trackAd` and `trackAdRevenue` take what the game reports, per player. |
| Attribution | `Player:GetJoinData().LaunchData`, the string an experience link carries. | Possible: `utm_source`, `utm_campaign`, `utm_term` and `utm_content` are read from it (query string or JSON) and nothing else, once per player. |
| Playtest command line | None. | Not supported. |
| Packaging | Rojo project (`default.project.json`), or the files copied into Studio as ModuleScripts. | Possible. Modules load each other by instance on Roblox and by name in the specs. Nothing is published to any package registry or store; the source is the public repository and its tags. |

## Contract items degraded

1. The device id is a salted hash of the UserId, not a random per-install id. It follows the account across devices, and there is no reset.
2. No device fields, and the platform is always `roblox`.
3. The queue is saved at leave, at shutdown, every 120 seconds and on a privacy choice, not on every change. A server crash can lose up to 120 seconds.
4. Bodies are never gzip compressed.
5. Batches every 15 seconds and at most 90 requests a minute by default, from the server's shared budget.
6. A session is one server visit; there is no background rule.
7. Error capture is off by default, server-only, under one server device, with no trail and no crash records.
8. No playtest mode.
9. Every request comes from the game server's address, so a country derived from the request address is the server's, not the player's, and the ingest per-address rate limit sees one address for every player in the server.

## Privacy and platform rules (owner checks before listing)

- Roblox has many players under 13. Before release, the owner should confirm that sending a salted, pseudonymous per-player id and gameplay events to a third-party service is allowed under the Roblox Terms of Use and the Creator Hub rules on external services, and under children's privacy law for the studios that use it.
- The SDK never sends the UserId, a username, a display name, chat or any text the player typed. A game must not put them in event data either; the README says so.
- `forgetPlayer(userId)` deletes the player's saved state for an erasure request. Events already sent are deleted in Ravensight by device id.

## Before release

1. Load `default.project.json` with Rojo into a test place, turn on Allow HTTP Requests and Studio access to API services, and run `example.project.json` against a staging key: confirm the session, a batch, a 429 `Retry-After`, a DataStore save at leave and a resend with its origin on the next server.
2. Confirm `RequestAsync` passes the `X-Ravensight-*` and `X-API-Key` headers unchanged and returns a 429's `Retry-After`.
3. Check `luau-analyze` in strict mode is clean, or add `--!nonstrict` headers.
