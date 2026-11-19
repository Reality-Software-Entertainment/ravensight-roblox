# Ravensight for Roblox

Player analytics for Roblox experiences: sessions, events, retention,
levels, purchases, errors, remote config and experiments, sent to
[Ravensight](https://ravensight.io) from your game server.

Preview: not yet verified inside Roblox; tested with the specs under LuaJIT
and Lua 5.4 with Luau's `bit32` semantics against fake engine services, and
every module compiles as Luau in CI.

Version 0.1.0. See [docs/FEASIBILITY.md](docs/FEASIBILITY.md) for how a
server-side SDK differs from the client SDKs.

## How it works

Roblox lets only the game server make HTTP requests, so this SDK runs in a
server Script and reports on behalf of each player in that server. Every
player gets their own session, queue and opt-out. You call it with the
player:

```lua
Ravensight.track(player, 'level_start', { level = 'forest_1' })
```

Something that happens only on a player's screen reaches the server through
your own RemoteEvent, as any server logic would.

## Install

The source is the public repository
[ravensight-roblox](https://github.com/Reality-Software-Entertainment/ravensight-roblox);
use its `v0.2.0` tag. Nothing is published to any package registry or to
the Creator Store. Clone or download the repository at that tag, then
either sync `default.project.json` into `ServerScriptService` with Rojo,
as a ModuleScript named `Ravensight`, or copy the `ravensight` folder into
Studio by hand: `init.lua` becomes a ModuleScript named `Ravensight` and
every other file a ModuleScript child of it, named after the file without
`.lua`.

Then:

1. Game Settings > Security: turn on **Allow HTTP Requests**.
2. For DataStore saves while testing in Studio, turn on **Enable Studio
   Access to API Services**.
3. Put your key and a salt in a ModuleScript in **ServerStorage**, which
   is never sent to players.

## Use

```lua
-- ServerScriptService/Analytics.server.lua
local Ravensight = require(game.ServerScriptService.Ravensight)
local secrets = require(game.ServerStorage.RavensightSecrets)

Ravensight.init({ ingestKey = secrets.ingestKey, salt = secrets.salt })

-- anywhere on the server
Ravensight.track(player, 'boss_defeated', { rs_kind = 'level_complete', level = 'forest_1' })
```

`init` connects to `Players.PlayerAdded`, `Players.PlayerRemoving`,
`RunService.Heartbeat` and `game:BindToClose` itself. A leaving player gets
`game_exited` and up to 10 seconds for the last batch; a server shutting
down flushes everyone within 25 seconds.

The salt is at least 16 random characters, and must never change: each
player's device id is an HMAC-SHA256 of their UserId keyed with it. Without
a salt, or without an `ingestKey`, the SDK stays off and warns once.

Use a `gt_live_` key. It never leaves your server.

`example.project.json` builds a test place with the example server script,
a secrets module and an analytics switch on the player's screen.

## Options

| Option | Default | What it does |
|---|---|---|
| `ingestKey` | none | Your game's key. Empty means off. |
| `salt` | none | At least 16 characters, secret, never changed. Required. |
| `apiUrl` | `https://api.ravensight.io` | With or without `/api/v1`. |
| `gameVersion` | `game.PlaceVersion` | Sent on every session. |
| `consent` | `"opt_out"` | `"opt_in"` sends nothing for a player until `setTrackingEnabled(player, true)`. |
| `flushInterval` | `15` | Seconds an event waits to be batched. |
| `maxQueueSize` | `500` | Unsent events kept per player, oldest dropped first. |
| `maxRequestsPerMinute` | `90` | The SDK's share of the server's HTTP budget. |
| `persistQueue` | `true` | Save each player's state in a DataStore. |
| `dataStoreName` | `"Ravensight"` | The DataStore used. |
| `captureErrors` | `false` | Capture server script errors (see "Errors"). |
| `attributionFromLaunchData` | `true` | Read `utm_*` from a player's launch data. |
| `distribution` | none | A short label sent on each session. |
| `quitTimeout` | `10` | Seconds a leaving player's last batch may take. |
| `debug` | `false` | Print informational lines. |
| `optional` | `false` | Silence the warning an inert start prints. |

## Functions

Every function that is about a player takes the `Player` first, and does
nothing for a player the SDK has not seen join.

| Function | What it does |
|---|---|
| `init(options)` | Start. Call once. Returns `true` when running. |
| `track(player, name, data)` | Queue an event. `data` is a flat table. |
| `purchase(player, amount, currency, itemType, itemId, opts)` | A purchase, `amount` in whole minor units. |
| `resource(player, flow, resource, amount, opts)`, `progression(player, status, p1, opts)` | Typed events. |
| `trackError(player, severity, message, opts)` | An error the game reports. |
| `trackAd(player, network, format, result, opts)`, `trackAdRevenue(player, network, format, placement, micros, currency)` | Ads. |
| `microsFromDecimalString(text)`, `microsFromRevenue(number)` | Revenue in micros without a float multiply. |
| `setAttribution(player, { source, network, campaign, adset, creative, touchTime })` | Once per player. |
| `fetchConfig(player)`, `getConfig(player, key, fallback)` | Remote config. A read is what counts as seeing an experiment. |
| `submitFeedback(player, message, category, rating)` | Player feedback. |
| `flush(player)` | Send now (every player when `player` is nil). |
| `setTrackingEnabled(player, on)`, `isTrackingEnabled(player)` | The player's choice, saved at once. |
| `forgetPlayer(userId)` | Delete a player's saved state, for an erasure request. |
| `getDeviceId(player)`, `getStatusReason(player)`, `getDeliveryStats(player)` | Identity and state. |
| `deviceIdFor(salt, userId)` | The device id a UserId maps to. |
| `on(name, fn)` | Subscribe; `fn(player, ...)`. Returns an unsubscribe function. |
| `shutdown()` | What `BindToClose` runs. |

## Levels and deaths

Give a level or death event a reserved `rs_kind`: `level_start`,
`level_complete`, `death` or `none`.

## Errors

Manual errors work for any player: `trackError(player, 'warning', 'shop
failed', { errorType = 'ShopError' })`.

Automatic capture is off by default on Roblox. With `captureErrors = true`
the SDK listens to `ScriptContext.Error` on the server and sends server
script errors under one server device for the game, because a server error
belongs to no one player. They are scrubbed on the server before queueing
(emails, tokens, keys, addresses, home folders, URL queries) and capped at
30 a session, 3 for one error, 6 a minute. Errors on players' screens are
not captured. There is no log trail.

## Attribution

When a player joins through an experience link whose launch data carries
`utm_source`, `utm_campaign`, `utm_term` or `utm_content` (as a query string
or a JSON object), one attribution event is sent for that player, once.
Nothing else in the launch data is read.

## Privacy

What is sent, for each player in the server:

- A device id that is an HMAC-SHA256 of the player's UserId keyed with your
  salt. The UserId itself is never sent, nor the username, the display name,
  chat or anything the player typed.
- On each session: that id, your game version, `platform: "roblox"`, the SDK
  name and version, and your `distribution` label if set. No device model,
  OS or GPU: a server cannot see them.
- The events your code tracks, with their time, and an `rs_event_id` so a
  resend is not counted twice.
- With `captureErrors`: server script errors, scrubbed first.
- With launch data: the four `utm_*` fields only.

Requests come from your game server, so Ravensight sees the server's
address, not the player's.

Saved per player in your experience's DataStore, under the device id (never
the UserId): unsent events, the player's choice, and whether attribution was
sent. `forgetPlayer(userId)` deletes it. To delete a player's events in
Ravensight, use their device id from `deviceIdFor(salt, userId)`.

Do not put usernames, display names, chat or other personal text in event
data. Many Roblox players are children: check the Roblox Terms of Use and
the rules where your players live before you collect analytics.

The player's choice: `setTrackingEnabled(player, false)` stops sending for
that player, drops their queue and is saved at once. The example shows a
button wired to it through a RemoteEvent.

## Running the tests

```
luajit spec/run.lua           # LuaJIT's bit library
luajit spec/run.lua bit32     # Luau's bit32 semantics, the Roblox path
lua5.4 spec/run.lua bit32     # PUC Lua, stricter number handling
```

CI also compiles every module as Luau, nightly and on demand
(`.github/workflows/test.yml`).

Install the local checks once per clone: `git config core.hooksPath .githooks`. The pre-push hook then runs this repository's tests before every push, with a time limit, and refuses the push if they fail. CI runs nightly and on demand, not on pushes or pull requests, so this hook is where a change is checked first.

The hook runs the three passes above. Without Lua 5.4 it uses the `lua` on
your path when that is 5.3 or later, and without either it runs the two
LuaJIT passes only.

## License

MIT. See [LICENSE](LICENSE).
