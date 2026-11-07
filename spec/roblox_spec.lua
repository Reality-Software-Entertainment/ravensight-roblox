-- The Roblox adapter (ravensight/init.lua) against fake engine services:
-- Players, RunService, HttpService, DataStoreService and ScriptContext.
local Ravensight = require('ravensight')
local Core = require('ravensight.core')
local json = require('ravensight.json')

local function eq(a, b, msg) assert(a == b, (msg or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local SALT = 'a-long-random-game-salt-0123456789'
local ORIGIN = { session = 'ses_11111111111111111111111111111111', build = '7', platform = 'roblox', stamp = 'o1.x.y' }

local function signal()
  local s = { fns = {} }
  function s:Connect(fn)
    table.insert(s.fns, fn)
    return { Disconnect = function() for i, f in ipairs(s.fns) do if f == fn then table.remove(s.fns, i) end end end }
  end
  function s.fire(...) for _, fn in ipairs(s.fns) do fn(...) end end
  return s
end

--- A world: fake services and a DataStore that survives a server restart
--- (pass the same `saved` table to the next world).
local function world(opts)
  opts = opts or {}
  local w = { clock = 0, wall = 1800000000, requests = {}, warns = {}, prints = {}, saved = opts.saved or {}, list = {}, guid = 0, bound = nil }
  w.Players = { PlayerAdded = signal(), PlayerRemoving = signal() }
  function w.Players:GetPlayers() return w.list end
  w.RunService = { Heartbeat = signal() }
  w.ScriptContext = { Error = signal() }
  w.responder = opts.responder or function(o)
    if o.Url:find('/api/v1/settings', 1, true) then return { StatusCode = 200, Body = json.encode({ trackingEnabled = true }), Headers = {} } end
    if o.Url:find('/api/v1/session', 1, true) then return { StatusCode = 201, Body = json.encode({ token = 'tok', expiresIn = 3600, origin = ORIGIN, errorCapture = { enabled = true, trail = false } }), Headers = {} } end
    if o.Url:find('/api/v1/track/batch', 1, true) then
      local n = #json.decode(o.Body).events
      return { StatusCode = 202, Body = json.encode({ accepted = n }), Headers = {} }
    end
    return { StatusCode = 404, Body = '{}', Headers = {} }
  end
  w.HttpService = {
    GenerateGUID = function() w.guid = w.guid + 1 return string.format('%08x-0000-4000-8000-%012x', w.guid, w.guid) end,
    RequestAsync = function(_, o)
      table.insert(w.requests, o)
      if w.httpError then error(w.httpError) end
      return w.responder(o)
    end,
  }
  w.DataStoreService = {
    GetDataStore = function(_, name)
      w.storeName = name
      return {
        GetAsync = function(_, key)
          if w.readError then error(w.readError) end
          return w.saved[key]
        end,
        SetAsync = function(_, key, value) w.saved[key] = value end,
        RemoveAsync = function(_, key) w.saved[key] = nil end,
      }
    end,
  }
  w.game = { BindToClose = function(_, fn) w.bound = fn end }
  local services = { Players = w.Players, RunService = w.RunService, HttpService = w.HttpService, DataStoreService = w.DataStoreService, ScriptContext = w.ScriptContext }
  Ravensight._reset()
  Ravensight._env = {
    service = function(name) return assert(services[name], 'no fake ' .. name) end,
    now = function() return w.clock end,
    time = function() return w.wall end,
    timeMs = function() return w.wall * 1000 end,
    spawn = function(fn, ...) fn(...) end,
    wait = function(s) w.clock = w.clock + s end,
    print = function(line) table.insert(w.prints, line) end,
    warn = function(line) table.insert(w.warns, line) end,
    game = w.game,
  }
  function w.player(userId, joinData)
    local p = { UserId = userId, Name = 'p' .. userId }
    function p:GetJoinData() return joinData or {} end
    return p
  end
  function w.join(p) table.insert(w.list, p) w.Players.PlayerAdded.fire(p) return p end
  function w.leave(p) w.Players.PlayerRemoving.fire(p) end
  function w.tick(seconds)
    local stepTo = w.clock + (seconds or 0)
    repeat
      w.clock = math.min(stepTo, w.clock + 0.5)
      w.RunService.Heartbeat.fire(0.5)
    until w.clock >= stepTo
  end
  function w.events()
    local out = {}
    for _, r in ipairs(w.requests) do
      if r.Url:find('/track/batch', 1, true) then
        for _, e in ipairs(json.decode(r.Body).events) do out[#out + 1] = e end
      end
    end
    return out
  end
  function w.batches()
    local out = {}
    for _, r in ipairs(w.requests) do
      if r.Url:find('/track/batch', 1, true) then out[#out + 1] = json.decode(r.Body).events end
    end
    return out
  end
  return w
end

local function names(events)
  local out = {}
  for _, e in ipairs(events) do out[#out + 1] = e.event end
  return table.concat(out, ',')
end

local function init(w, extra)
  local options = { ingestKey = 'gt_live_k', salt = SALT, gameVersion = '7', apiUrl = 'https://api.test' }
  for k, v in pairs(extra or {}) do options[k] = v end
  return Ravensight.init(options)
end

return {
  { 'device id: an HMAC of the UserId under the salt, in the random id shape', function()
    local id = Ravensight.deviceIdFor(SALT, 156)
    assert(Core.is_random_device_id(id), id)
    eq(id:sub(-7), '-roblox')
    eq(id, Ravensight.deviceIdFor(SALT, 156), 'stable')
    assert(id ~= Ravensight.deviceIdFor(SALT, 157), 'differs by player')
    assert(id ~= Ravensight.deviceIdFor(SALT .. 'x', 156), 'differs by salt')
    assert(not pcall(Ravensight.deviceIdFor, 'short', 156), 'a short salt is refused')
    assert(Ravensight.serverDeviceIdFor(SALT) ~= id)
  end },

  { 'init: no key or no salt is inert, with one warning', function()
    local w = world()
    eq(Ravensight.init({ salt = SALT }), false)
    eq(#w.warns, 1)
    eq(Ravensight.init({ ingestKey = 'gt_live_k', salt = 'too-short' }), false)
    eq(#w.warns, 2)
    eq(Ravensight.init({ optional = true }), false)
    eq(#w.warns, 2, 'optional silences it')
    eq(#w.Players.PlayerAdded.fns, 0, 'nothing is connected')
  end },

  { 'a joining player gets the settings check, a session as their hashed device, and batched events', function()
    local w = world()
    assert(init(w))
    local p = w.join(w.player(42))
    local session = json.decode(w.requests[2].Body)
    eq(w.requests[1].Url, 'https://api.test/api/v1/settings')
    eq(w.requests[1].Body, nil, 'a GET has no body')
    eq(w.requests[2].Url, 'https://api.test/api/v1/session')
    eq(session.deviceId, Ravensight.deviceIdFor(SALT, 42))
    eq(session.platform, 'roblox')
    eq(session.sdk, 'roblox/0.1.0')
    eq(session.gameVersion, '7')
    eq(session.device, nil, 'a server knows no device fields')
    eq(w.requests[2].Headers['X-API-Key'], 'gt_live_k')
    eq(names(w.events()), 'game_started', 'game_started goes as the session opens')
    assert(Ravensight.track(p, 'level_start', { level = 'forest_1' }))
    w.tick(5)
    eq(#w.batches(), 1, 'waits for the flush interval')
    w.tick(11)
    eq(names(w.events()), 'game_started,level_start')
    assert(w.events()[2].data.rs_event_id, 'every event carries an id')
    eq(Ravensight.getDeviceId(p), session.deviceId)
    eq(Ravensight.getStatusReason(p), nil)
  end },

  { 'calls for an unknown player do nothing', function()
    local w = world()
    assert(init(w))
    local stranger = w.player(9)
    eq(Ravensight.track(stranger, 'x', {}), false)
    eq(Ravensight.getConfig(stranger, 'k', 3), 3)
    eq(Ravensight.setTrackingEnabled(stranger, false), false)
    eq(Ravensight.getStatusReason(stranger), 'disabled')
    eq(#w.requests, 0)
  end },

  { 'every request spends from one budget, so analytics never take the whole server', function()
    local w = world()
    assert(init(w, { maxRequestsPerMinute = 2 }))
    w.join(w.player(1))
    w.join(w.player(2))
    eq(#w.requests, 2, 'only two requests within the budget')
    w.tick(30)
    eq(#w.requests, 3, 'one more after half a minute')
    w.tick(30)
    eq(#w.requests, 4)
  end },

  { 'a leaving player sends game_exited, then the state is saved and the player let go', function()
    local w = world()
    assert(init(w))
    local p = w.join(w.player(7))
    Ravensight.track(p, 'pickup', {})
    w.leave(p)
    eq(names(w.events()), 'game_started,pickup,game_exited')
    w.tick(1)
    eq(Ravensight._players()[p], nil, 'let go once answered')
    eq(next(w.saved), nil, 'nothing left to save')
  end },

  { 'offline at leave: the queue is saved and the next server sends it under its old origin', function()
    local w = world()
    assert(init(w))
    local p = w.join(w.player(7))
    Ravensight.track(p, 'pickup', {})
    w.httpError = 'HttpError: ConnectFail'
    w.leave(p)
    w.tick(Ravensight.DEFAULT_QUIT_TIMEOUT + 1)
    eq(Ravensight._players()[p], nil)
    local key = 'rs1_' .. Ravensight.deviceIdFor(SALT, 7)
    assert(w.saved[key], 'saved under the device id, not the UserId')
    local doc = json.decode(w.saved[key][Core.queueFile('gt_live_k')])
    eq(doc.version, 2)
    eq(names(doc.groups[1].events), 'pickup,game_exited')
    eq(doc.groups[1].origin.session, ORIGIN.session)

    local NEW = { session = 'ses_22222222222222222222222222222222', build = '8', platform = 'roblox', stamp = 'o1.z.w' }
    local w2 = world({ saved = w.saved, responder = function(o)
      if o.Url:find('/session', 1, true) then return { StatusCode = 201, Body = json.encode({ token = 't2', expiresIn = 3600, origin = NEW }), Headers = {} } end
      if o.Url:find('/settings', 1, true) then return { StatusCode = 200, Body = '{"trackingEnabled":true}', Headers = {} } end
      if o.Url:find('/track/batch', 1, true) then return { StatusCode = 202, Body = '{}', Headers = {} } end
      return { StatusCode = 404, Body = '{}', Headers = {} }
    end })
    assert(init(w2))
    w2.join(w2.player(7))
    w2.tick(16)
    local events = w2.events()
    eq(names(events), 'pickup,game_exited,game_started')
    eq(events[1].origin.stamp, 'o1.x.y', 'the old origin, verbatim')
    eq(events[2].origin.session, ORIGIN.session)
    eq(events[3].origin, nil, 'this session needs none')
    eq(events[1].data.rs_event_id, doc.groups[1].events[1].data.rs_event_id, 'the same id on the resend')
  end },

  { 'a failed DataStore read keeps the player in memory only and never overwrites the save', function()
    local w = world()
    w.saved['rs1_' .. Ravensight.deviceIdFor(SALT, 5)] = { keep = 'me' }
    w.readError = 'DataStore request was rejected'
    assert(init(w))
    local p = w.join(w.player(5))
    Ravensight.setTrackingEnabled(p, false)
    w.leave(p)
    w.tick(1)
    eq(w.saved['rs1_' .. Ravensight.deviceIdFor(SALT, 5)].keep, 'me')
    eq(#w.warns, 1)
  end },

  { 'opt-out is saved at once and honoured on the next server, before any request', function()
    local w = world()
    assert(init(w))
    local p = w.join(w.player(3))
    eq(Ravensight.setTrackingEnabled(p, false), true)
    eq(Ravensight.isTrackingEnabled(p), false)
    assert(w.saved['rs1_' .. Ravensight.deviceIdFor(SALT, 3)], 'written now, not at leave')
    local w2 = world({ saved = w.saved })
    assert(init(w2))
    local p2 = w2.join(w2.player(3))
    eq(#w2.requests, 0, 'not even the settings check')
    eq(Ravensight.track(p2, 'x', {}), true)
    w2.tick(20)
    eq(#w2.requests, 0)
    eq(Ravensight.getStatusReason(p2), 'disabled')
  end },

  { 'opt_in consent sends nothing until the player says yes', function()
    local w = world()
    assert(init(w, { consent = 'opt_in' }))
    local p = w.join(w.player(4))
    eq(#w.requests, 0)
    Ravensight.setTrackingEnabled(p, true)
    assert(#w.requests > 0)
  end },

  { 'launch data: only utm fields, from a query string or JSON, sent once per player', function()
    local a = Ravensight.attributionFromLaunchData('utm_source=newsletter&utm_campaign=spring+sale&ref=secret&utm_medium=email')
    eq(a.source, 'utm')
    eq(a.network, 'newsletter')
    eq(a.campaign, 'spring sale')
    eq(a.adset, nil)
    local b = Ravensight.attributionFromLaunchData('{"utm_content":"banner%20a","level":3}')
    eq(b.creative, 'banner%20a', 'JSON is taken as written')
    eq(Ravensight.attributionFromLaunchData('level=3'), nil)
    eq(Ravensight.attributionFromLaunchData(''), nil)
    eq(Ravensight.attributionFromLaunchData(nil), nil)

    local w = world()
    assert(init(w))
    local p = w.join(w.player(8, { LaunchData = 'utm_campaign=spring' }))
    w.tick(16)
    local events = w.events()
    eq(names(events), 'game_started,rs_attribution')
    eq(events[2].data.rs_campaign, 'spring')
    eq(events[2].data.rs_touch_time, w.wall * 1000)
    w.leave(p)
    w.tick(1)
    local w2 = world({ saved = w.saved })
    assert(init(w2))
    w2.join(w2.player(8, { LaunchData = 'utm_campaign=spring' }))
    w2.tick(16)
    eq(names(w2.events()), 'game_started', 'the sent flag survived the server')
  end },

  { 'error capture is off by default; on, server errors go under one server device', function()
    local w = world()
    assert(init(w))
    eq(#w.ScriptContext.Error.fns, 0)
    eq(Ravensight.captureScriptError('boom', 'Script:1'), false)

    local w2 = world()
    assert(init(w2, { captureErrors = true }))
    eq(#w2.ScriptContext.Error.fns, 1)
    local session = json.decode(w2.requests[2].Body)
    eq(session.deviceId, Ravensight.serverDeviceIdFor(SALT))
    w2.ScriptContext.Error.fire('attempt to index nil with Parent at /Users/jo ann/x', 'ServerScriptService.Round:12')
    eq(Ravensight.captureScriptError('x', 'ServerScriptService.Ravensight.core:9'), false, 'never its own')
    w2.tick(16)
    local events = w2.events()
    eq(names(events), 'game_started,error')
    eq(events[2].data.rs_source, 'uncaught')
    eq(events[2].data.rs_severity, 'error')
    eq(events[2].data.rs_message, 'attempt to index nil with Parent at ~/x', 'scrubbed before it is queued')
  end },

  { 'manual errors, typed events, ads and attribution for a player', function()
    local w = world()
    assert(init(w))
    local p = w.join(w.player(11))
    assert(Ravensight.trackError(p, 'warning', 'shop failed', { errorType = 'ShopError' }))
    assert(Ravensight.purchase(p, 499, 'usd', 'gamepass', 'vip'))
    assert(Ravensight.trackAdRevenue(p, 'admob', 'rewarded', 'level_end', '1500', 'USD'))
    local ok, why = Ravensight.trackAd(p, 'admob', 'rewarded', 'clicked', { revenueMicros = '1', currency = 'USD' })
    eq(ok, false)
    assert(why)
    eq(Ravensight.microsFromRevenue(0.0015), '1500')
    eq(Ravensight.microsFromDecimalString('1.23456789'), '1234568')
    w.tick(16)
    local events = w.events()
    eq(names(events), 'game_started,error,purchase,rs_ad')
    eq(events[2].data.rs_source or 'manual', 'manual')
    eq(events[2].data.rs_error_type, 'ShopError')
    eq(events[4].data.rs_revenue_micros, '1500')
  end },

  { 'shutdown flushes every player outside the budget and saves what is left', function()
    local w = world()
    assert(init(w, { maxRequestsPerMinute = 3 }))
    local a = w.join(w.player(21))
    local b = w.join(w.player(22))
    w.tick(120)
    Ravensight.track(a, 'x', {})
    Ravensight.track(b, 'y', {})
    assert(w.bound, 'BindToClose was registered')
    w.bound()
    local seen = {}
    for _, events in ipairs(w.batches()) do
      for _, e in ipairs(events) do seen[e.event] = (seen[e.event] or 0) + 1 end
    end
    eq(seen.game_exited, 2)
    eq(seen.x, 1)
    eq(seen.y, 1)
    eq(next(Ravensight._players()), nil)
  end },

  { 'HTTP switched off in the game: one warning, events kept', function()
    local w = world()
    w.httpError = 'Http requests are not enabled. Enable via game settings'
    assert(init(w))
    local p = w.join(w.player(1))
    w.join(w.player(2))
    w.tick(40)
    local count = 0
    for _, line in ipairs(w.warns) do if line:find('Allow HTTP Requests', 1, true) then count = count + 1 end end
    eq(count, 1)
    eq(Ravensight.track(p, 'kept', {}), true)
  end },

  { 'forgetPlayer removes the saved state by device id', function()
    local w = world()
    assert(init(w))
    local key = 'rs1_' .. Ravensight.deviceIdFor(SALT, 99)
    w.saved[key] = { a = 'b' }
    assert(Ravensight.forgetPlayer(99))
    eq(w.saved[key], nil)
  end },

  { 'listeners get the player first', function()
    local w = world()
    assert(init(w))
    local got = {}
    local off = Ravensight.on('session_ready', function(player) table.insert(got, player.UserId) end)
    w.join(w.player(31))
    off()
    w.join(w.player(32))
    eq(table.concat(got, ','), '31')
  end },
}
