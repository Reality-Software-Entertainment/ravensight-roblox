# Ravensight for Roblox

Player analytics for Roblox experiences: sessions, events, retention,
levels, purchases, errors, remote config and experiments, sent to
[Ravensight](https://ravensight.io) from your game server.

Preview: not yet verified inside Roblox; tested with the specs under LuaJIT
and Lua 5.4 with Luau's `bit32` semantics against fake engine services, and
every module compiles as Luau in CI.

Version 0.2.0. See [docs/FEASIBILITY.md](docs/FEASIBILITY.md) for how a
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
| `attributionFromLaunchData` | `true` | Read `utm_*` and `rs_link` from a player's launch data. |
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
| `identify(player, accountId)` | Link the player to your game's own account after your own sign-in. Returns `true`, or `false` and a reason. See "Identify players who sign in". |
| `resetIdentity(player)` | On sign-out from your own account: forget it. See "Identify players who sign in" for what happens to the device id on Roblox. |
| `isIdentified(player)` | `true` while an account is set by `identify` for this player. |
| `setCampaignLink(player, linkId)` | Send a Ravensight campaign link id with the player's next session. Returns `true`, or `false` and a reason. See "Campaign links". |
| `campaignLinkFromLaunchData(launchData)` | The `rs_link` link id in a join's launch data, lowercased, or `nil`. |
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
Nothing else in the launch data is read, apart from a campaign link's
`rs_link` (see "Campaign links").

## Campaign links

A Ravensight campaign link adds `rs_link=<link id>` to the address it
redirects to. Roblox does not pass a web address into the game, so the tag
on that address never reaches your server by itself. Two ways to carry it:

- **In the experience link's launch data.** Roblox hands a join's launch
  data to the server (`Player:GetJoinData().LaunchData`). Make the campaign
  link's destination an experience link whose launch data carries the link
  id, such as
  `https://www.roblox.com/games/start?placeId=<your place id>&launchData=rs_link%3D<link id>`,
  or add an `rs_link` field to the JSON launch data you already use. The
  link id is the 24 hex `rs_link` value on the address the campaign link
  sends people to. When the player joins, the SDK reads `rs_link` from the
  launch data (with `attributionFromLaunchData`, on by default), as a query
  string or a JSON field, and sends it with the player's first session.
- **Pass it yourself** with `Ravensight.setCampaignLink(player, linkId)`
  when your game carries it another way, for example in data your own lobby
  place hands on. A call before the player's saved state has loaded goes
  with their first session and replaces a link from the launch data.

`setCampaignLink(player, linkId)` returns `true` when the value is a link id
(24 hex characters, in any case), which then replaces a link still waiting.
Otherwise it returns `false` and the reason (`"invalid_link"`,
`"no_player"`, or `"not_started"` before `init`), and nothing changes. The
id goes lowercased, as `campaignLink`, on the player's session:

- **Sent once.** Only a session answer with a token clears it, so a failed
  attempt keeps it for the next one. Later sessions carry none.
- **Same consent as everything else.** With `consent = "opt_in"` it goes
  with the player's first session after their yes, and an opted out player
  sends nothing.
- **Nothing is stored.** The id is one your studio made, not personal data.
- The server keeps it only when it names a link of the same game. The player
  and the session are then counted on the Campaign links page, by link.

## Identify players who sign in

A Roblox player is already one id in your game on every device they play
from: the device id comes from their UserId (see "Privacy"). Most games
never need `identify`. It is only for a game with its own account system on
top of Roblox, for example one shared with a version of the game outside
Roblox, so one of your accounts counts as one player everywhere.

```lua
Ravensight.identify(player, account.analyticsId)  -- after your own sign-in: a random id stored with the account
Ravensight.resetIdentity(player)                  -- on sign-out from your own account
```

- **Never pass the UserId, the player's name or display name, or any
  handle.** They are public and guessable. The SDK refuses the player's own
  UserId, name and display name (`"looks_like_user_id"`).
- **Pass a random, high-entropy id**, such as a random UUID or a random
  analytics id you make once for each account and store with it, never a
  sequential database key or an email. Ravensight's identify salt for your
  game reaches every key of the game, so anyone holding it could hash 1, 2,
  3 and onward and match a guessable id; a random one cannot be guessed.
  The hash is still a pseudonymous identifier for the player: declare it in
  your game's privacy notice. Pass it as a string; a whole number is
  accepted and used as its decimal digits, but a sequential number is
  exactly the guessable kind.
- **What is sent:** a salted hash of the id (`accountHash`, 64 hex
  characters, keyed with Ravensight's identify salt for your game, which
  arrives in the session answer; not the `salt` you pass to `init`) and the
  player's session token, once per session. The raw account id is never
  sent and never saved; until the player's first session answer it is held
  in memory only.
- **Refusals.** A value that is empty, over 256 bytes of UTF-8 or contains
  `@` is refused, as is the player's UserId or name: `identify` returns
  `false` and the reason (`"not_text"`, `"empty"`, `"too_long"`,
  `"looks_like_email"` or `"looks_like_user_id"`; `"no_player"` without a
  player, `"not_started"` before `init`), prints one warning, and nothing
  changes.
- **One event per identified session** on your usage balance. The same
  account again in the same session sends nothing; a refused or failed
  request is tried once more at the player's next session, never in a loop.
  A server that does not offer identify turns it off for the rest of the
  player's visit. If the server answers twice in a row that the session was not live
  (`no_session`), identify stops for that player until `resetIdentity`.
- **Saved** in the player's DataStore entry, beside the rest of their state,
  at once. It never enters the event queue and never delays an event.
  Before the player's yes under `consent = "opt_in"` it is held in memory
  only. `setTrackingEnabled(player, false)` deletes it, and
  `forgetPlayer(userId)` deletes it with the whole entry.
- A call made before the player's saved state has loaded is held in memory
  and applied when it has.
- **A different account** for the same player first does `resetIdentity`.
- **`resetIdentity(player)` on Roblox.** It deletes the saved hash from the
  player's entry at once and switches the player to a fresh random device
  id for the rest of this server visit, so the rest of the visit is not
  linked to the account. The other SDKs keep that fresh id; Roblox cannot,
  because the device id comes from the UserId. The next time the player
  joins, they are back on the id from their UserId, which Ravensight may
  still count as the account they signed out of until they sign in again.

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
- With launch data: the four `utm_*` fields and a campaign link's
  `rs_link` only.
- With `identify`: a salted hash of your own account id, once per session
  (see "Identify players who sign in").

Requests come from your game server, so Ravensight sees the server's
address, not the player's.

Saved per player in your experience's DataStore, under the device id (never
the UserId): unsent events, the player's choice, whether attribution was
sent, and the salted hash from `identify`. `forgetPlayer(userId)` deletes
it. To delete a player's events in Ravensight, use their device id from
`deviceIdFor(salt, userId)`.

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
