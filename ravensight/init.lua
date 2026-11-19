-- ravensight (init.lua): Ravensight for Roblox, a server-side SDK.
--
-- Roblox lets only the game server make HTTP requests (HttpService), so
-- this SDK runs in a server Script and reports on behalf of the players in
-- that server. Each player gets their own Core (ravensight/core.lua): their
-- own device id, session, queue and opt-out. See docs/FEASIBILITY.md for
-- every way this differs from the client SDK contract.
--
--   local Ravensight = require(game.ServerScriptService.Ravensight)
--   Ravensight.init({ ingestKey = 'gt_live_...', salt = '<a long random secret>' })
--   Ravensight.track(player, 'level_start', { level = 'forest_1' })
--
-- The device id is never the UserId: it is an HMAC-SHA256 of the UserId
-- keyed with the game's own salt, so it is stable for one player in one game
-- and cannot be turned back into the account without the salt.
--
-- MIT licensed, part of ravensight-roblox.

local function import(name)
  if script ~= nil then return require(script:WaitForChild(name)) end
  return require('ravensight.' .. name)
end

local Core = import('core')
local Typed = import('typed')
local Hmac = import('hmac')
local json = import('json')

local M = {}

M.VERSION = Core.VERSION
M.FEEDBACK_CATEGORIES = { 'bug', 'suggestion', 'complaint', 'praise', 'playtest', 'other' }
--- Defaults chosen for a shared server: every request comes out of the
--- server's HttpService budget (500 a minute for the whole server).
M.DEFAULT_FLUSH_INTERVAL = 15
M.DEFAULT_MAX_REQUESTS_PER_MINUTE = 90
M.DEFAULT_QUIT_TIMEOUT = 10
M.SHUTDOWN_TIMEOUT = 25
M.SAVE_INTERVAL = 120
M.MIN_SALT_LENGTH = 16
M.DATASTORE_NAME = 'Ravensight'
M.PLATFORM = 'roblox'

local config = nil
local initialized = false
local players = {}     -- Player -> entry {core, store, leaving}
local pending = {}     -- Player -> {account, reset, link} set before their core exists
local serverEntry = nil -- the error capture device, when captureErrors is on
local listeners = {}
local sender = nil
local connections = {}
local lastSave = 0
local warned = {}

-- ------------------------------------------------------------- environment

--- Services and clocks. On Roblox they come from the engine; the specs set
--- M._env to fakes before init().
local function env()
  if M._env then return M._env end
  local DateTimeLib = rawget(_G, 'DateTime') or DateTime
  M._env = {
    service = function(name) return game:GetService(name) end,
    now = os.clock,
    time = os.time,
    timeMs = function() return DateTimeLib.now().UnixTimestampMillis end,
    spawn = task.spawn,
    wait = task.wait,
    print = print,
    warn = warn,
    isStudio = function() return game:GetService('RunService'):IsStudio() end,
  }
  return M._env
end

local function log(level, message)
  local e = env()
  if level == 'info' and not (config and config.debug) then return end
  local line = 'Ravensight: ' .. message
  if level == 'info' then e.print(line) else e.warn(line) end
end

local function warnOnce(key, message)
  if warned[key] then return end
  warned[key] = true
  log('warn', message)
end

local function emit(name, player, ...)
  for _, fn in ipairs(listeners[name] or {}) do
    pcall(fn, player, ...)
  end
end

-- ----------------------------------------------------------------- identity

--- The player's device id: the first 32 hex characters of
--- HMAC-SHA256(salt, "roblox-user:" .. userId), then "-roblox". The shape
--- of the SDK's random ids, so the core treats it as one.
function M.deviceIdFor(salt, userId)
  assert(type(salt) == 'string' and #salt >= M.MIN_SALT_LENGTH, 'ravensight: salt must be at least 16 characters')
  local id = tostring(userId)
  assert(id:match('^%d+$'), 'ravensight: userId must be a whole number')
  return Hmac.hex(salt, 'roblox-user:' .. id):sub(1, 32) .. '-roblox'
end

--- The device that automatic error capture reports under: one per game,
--- never a player.
function M.serverDeviceIdFor(salt)
  return Hmac.hex(salt, 'roblox-server'):sub(1, 32) .. '-roblox'
end

--- Random hex for event id nonces: HttpService:GenerateGUID, dashes taken
--- out, as many as needed.
local function randomHex(count)
  local http = env().service('HttpService')
  local out = ''
  while #out < count * 2 do
    out = out .. http:GenerateGUID(false):gsub('[^%x]', ''):lower()
  end
  return out:sub(1, count * 2)
end

-- ------------------------------------------------------------------ sender

--- Every Core's requests go through one sender, which spends at most
--- `perMinute` requests a minute (a token bucket), so analytics can never
--- take the whole server's HttpService budget. Requests wait in order.
--- During shutdown the bucket is ignored: the server is going away.
local function newSender(perMinute)
  local s = { queue = {}, tokens = perMinute, last = nil, burst = false, inflight = 0 }

  local function lowerHeaders(headers)
    local out = {}
    for k, v in pairs(headers or {}) do out[string.lower(tostring(k))] = v end
    return out
  end

  local function perform(req, callback)
    local e = env()
    local http = e.service('HttpService')
    local options = { Url = req.url, Method = req.method, Headers = req.headers }
    if req.method ~= 'GET' then options.Body = req.body end
    s.inflight = s.inflight + 1
    local ok, res = pcall(http.RequestAsync, http, options)
    s.inflight = s.inflight - 1
    if not ok then
      local text = tostring(res)
      if text:lower():find('not enabled', 1, true) then
        warnOnce('http_disabled', 'HTTP requests are not enabled for this experience. Turn on Allow HTTP Requests in Game Settings > Security.')
      end
      callback(0, '', {})
      return
    end
    callback(tonumber(res.StatusCode) or 0, res.Body or '', lowerHeaders(res.Headers))
  end

  function s.send(req, callback)
    s.queue[#s.queue + 1] = { req = req, callback = callback }
    s.pump()
  end

  function s.pump()
    local e = env()
    local t = e.now()
    if s.last then
      s.tokens = math.min(perMinute, s.tokens + (t - s.last) * perMinute / 60)
    end
    s.last = t
    while #s.queue > 0 and (s.burst or s.tokens >= 1) do
      local item = table.remove(s.queue, 1)
      if not s.burst then s.tokens = s.tokens - 1 end
      e.spawn(perform, item.req, item.callback)
    end
  end

  function s.idle() return #s.queue == 0 and s.inflight == 0 end
  return s
end

-- ----------------------------------------------------------------- storage

--- One player's saved state in a DataStore entry keyed by the device id
--- (never the UserId): the opt-out or opt-in choice, the attribution flag,
--- the unsent queue and identify's salted hash. Read once when the player
--- joins; written when the player leaves, when the server shuts down, every
--- SAVE_INTERVAL seconds while changed, and at once for a privacy choice or
--- an identify call. The device id itself is never stored: it is recomputed
--- from the salt. A device id the core resets (resetIdentity) lasts for the
--- rest of this server visit only, in memory.
local function newStore(deviceId, persist)
  local store = { files = {}, dirty = false, persist = persist, key = 'rs1_' .. deviceId, visitDeviceId = nil }

  function store.read(name)
    if name == Core.DEVICE_ID_FILE then return store.visitDeviceId or deviceId end
    return store.files[name]
  end
  function store.write(name, text)
    if name == Core.DEVICE_ID_FILE then
      if text ~= deviceId then store.visitDeviceId = text end
      return
    end
    if store.files[name] ~= text then
      store.files[name] = text
      store.dirty = true
    end
  end
  store.replace = store.write
  function store.remove(name)
    if name == Core.DEVICE_ID_FILE then
      store.visitDeviceId = nil
      return
    end
    if store.files[name] ~= nil then
      store.files[name] = nil
      store.dirty = true
    end
  end

  local function dataStore()
    local ok, ds = pcall(function()
      return env().service('DataStoreService'):GetDataStore(config.dataStoreName)
    end)
    if ok then return ds end
    return nil
  end

  --- Reads the saved entry. A failed read turns saving off for this
  --- player, so an empty state never overwrites a good one.
  function store.load()
    if not store.persist then return end
    local ds = dataStore()
    if not ds then store.persist = false return end
    local ok, value = pcall(ds.GetAsync, ds, store.key)
    if not ok then
      store.persist = false
      warnOnce('datastore_read', 'could not read saved analytics state; this server keeps it in memory only. (' .. tostring(value) .. ')')
      return
    end
    if type(value) == 'table' then
      for k, v in pairs(value) do
        if type(k) == 'string' and type(v) == 'string' then store.files[k] = v end
      end
    end
  end

  --- Writes the entry when it changed. An empty state removes it.
  function store.commit()
    if not store.persist or not store.dirty then return true end
    local ds = dataStore()
    if not ds then return false end
    store.dirty = false
    local ok, err
    if next(store.files) == nil then
      ok, err = pcall(ds.RemoveAsync, ds, store.key)
    else
      local copy = {}
      for k, v in pairs(store.files) do copy[k] = v end
      ok, err = pcall(ds.SetAsync, ds, store.key, copy)
    end
    if not ok then
      store.dirty = true
      log('warn', 'could not save analytics state: ' .. tostring(err))
    end
    return ok
  end

  return store
end

-- -------------------------------------------------------------------- cores

local function newCore(deviceId, store)
  local e = env()
  local core = Core.new({
    apiUrl = config.apiUrl,
    ingestKey = config.ingestKey,
    gameVersion = config.gameVersion,
    maxQueueSize = config.maxQueueSize,
    flushInterval = config.flushInterval,
    send = sender.send,
    now = e.now,
    time = e.time,
    timeMs = e.timeMs,
    storage = store,
    randomHex = randomHex,
    platform = M.PLATFORM,
    osName = M.PLATFORM,
    log = log,
    consent = config.consent,
    distribution = config.distribution,
    captureErrors = true,
    quitTimeout = config.quitTimeout,
  })
  return core
end

--- Forwards a Core's events to M.on listeners with the player first.
local FORWARDED = {
  'session_ready', 'session_failed', 'status_changed', 'tracking_disabled', 'events_flushed',
  'flush_failed', 'feedback_submitted', 'feedback_failed', 'event_tracked', 'config_ready',
}
local function forward(core, player)
  for _, name in ipairs(FORWARDED) do
    core:on(name, function(...) emit(name, player, ...) end)
  end
end

--- One query string value, decoded: "+" is a space, %XX a byte.
local function queryValue(v)
  return (v:gsub('%+', ' '):gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end

--- Reads utm_source, utm_campaign, utm_term and utm_content from a join's
--- launch data (a query string or a JSON object), and nothing else. Nil
--- when none is present.
function M.attributionFromLaunchData(launchData)
  if type(launchData) ~= 'string' or launchData == '' or #launchData > 2000 then return nil end
  local fields = {}
  local parsed = json.decode(launchData)
  if type(parsed) == 'table' then
    for _, k in ipairs({ 'utm_source', 'utm_campaign', 'utm_term', 'utm_content' }) do
      if type(parsed[k]) == 'string' then fields[k] = parsed[k] end
    end
  else
    for pair in launchData:gsub('^%?', ''):gmatch('[^&]+') do
      local k, v = pair:match('^([^=]+)=(.*)$')
      if k == 'utm_source' or k == 'utm_campaign' or k == 'utm_term' or k == 'utm_content' then
        fields[k] = queryValue(v)
      end
    end
  end
  local function value(k)
    local v = fields[k]
    if type(v) ~= 'string' then return nil end
    v = v:match('^%s*(.-)%s*$')
    if v == '' then return nil end
    return v
  end
  local out = {
    source = 'utm', network = value('utm_source'), campaign = value('utm_campaign'),
    adset = value('utm_term'), creative = value('utm_content'),
  }
  if not (out.network or out.campaign or out.adset or out.creative) then return nil end
  return out
end

--- The campaign link id in a join's launch data: `rs_link` in a query
--- string (the first one, decoded) or in a JSON object, lowercased when it
--- is a link id (24 hex characters), else nil. Nothing else is read. A
--- campaign link's redirect cannot put it there by itself: the studio puts
--- it in the experience link's launch data (see the README).
function M.campaignLinkFromLaunchData(launchData)
  if type(launchData) ~= 'string' or launchData == '' or #launchData > 2000 then return nil end
  local value
  local parsed = json.decode(launchData)
  if type(parsed) == 'table' then
    value = parsed.rs_link
  else
    for pair in launchData:gsub('^%?', ''):gmatch('[^&]+') do
      local k, v = pair:match('^([^=]+)=(.*)$')
      if k == 'rs_link' and value == nil then value = queryValue(v) end
    end
  end
  return Core.campaignLinkId(value)
end

--- Runs fn(core) and keeps the player's attribution flag. A reset device id
--- lasts only for this server visit (the id comes back from the UserId on
--- the next one), and that device already sent its attribution.
local function keepingAttribution(entry, fn)
  local flag = entry.store.files[Core.ATTRIBUTION_FILE]
  local a, b = fn(entry.core)
  if flag and entry.store.files[Core.ATTRIBUTION_FILE] == nil then entry.store.write(Core.ATTRIBUTION_FILE, flag) end
  return a, b
end


local function addPlayer(player)
  if not initialized or players[player] then return end
  local deviceId = M.deviceIdFor(config.salt, player.UserId)
  local store = newStore(deviceId, config.persistQueue)
  -- Claimed before the DataStore read yields, so a second PlayerAdded for
  -- the same player does nothing.
  local entry = { store = store, core = nil, leaving = false, joinedAt = env().timeMs() }
  players[player] = entry
  store.load()
  if players[player] ~= entry then return end -- left while loading
  local core = newCore(deviceId, store)
  entry.core = core
  forward(core, player)
  local launchData = nil
  if config.attributionFromLaunchData and player.GetJoinData then
    local ok, joinData = pcall(player.GetJoinData, player)
    if ok and type(joinData) == 'table' then launchData = joinData.LaunchData end
  end
  -- A campaign link goes with the player's first session: the one in the
  -- launch data, replaced by one the game set before the state loaded.
  local waiting = pending[player]
  pending[player] = nil
  local launchLink = M.campaignLinkFromLaunchData(launchData)
  if launchLink then core:setCampaignLink(launchLink) end
  if waiting and waiting.link then core:setCampaignLink(waiting.link) end
  -- A sign-out the game asked for before the state loaded happens before
  -- the first session, so a saved identity is never sent; an identify
  -- waits for the start, which reads the saved one to compare with.
  if waiting and waiting.reset then keepingAttribution(entry, function(c) c:resetIdentity() end) end
  core:start()
  local attribution = M.attributionFromLaunchData(launchData)
  if attribution then
    attribution.touchTime = entry.joinedAt
    core:setAttribution(attribution)
  end
  if waiting and waiting.account then keepingAttribution(entry, function(c) return c:identify(waiting.account) end) end
  if waiting and (waiting.reset or waiting.account) then env().spawn(store.commit) end
  if entry.leaving then core:beginQuit() end
end

local function removePlayer(player)
  pending[player] = nil
  local entry = players[player]
  if not entry or entry.leaving then return end
  entry.leaving = true
  if entry.core then
    entry.core:beginQuit()
  else
    -- Left before the saved state loaded: nothing was tracked.
    players[player] = nil
  end
end

local function finishLeaving()
  for player, entry in pairs(players) do
    if entry.leaving and entry.core and entry.core.quitReady then
      players[player] = nil
      env().spawn(entry.store.commit)
    end
  end
end

local syncErrorHook
local function step()
  if not initialized then return end
  sender.pump()
  for _, entry in pairs(players) do
    if entry.core then entry.core:update() end
  end
  if serverEntry then
    serverEntry.core:update()
    syncErrorHook()
  end
  finishLeaving()
  local t = env().now()
  if t - lastSave >= M.SAVE_INTERVAL then
    lastSave = t
    for _, entry in pairs(players) do
      if entry.core and not entry.leaving and entry.store.dirty then env().spawn(entry.store.commit) end
    end
  end
end
M._step = step

--- Called from game:BindToClose: every player's game_exited, the last
--- batches (outside the request budget) and the saved state, within
--- SHUTDOWN_TIMEOUT seconds.
function M.shutdown()
  if not initialized then return end
  local e = env()
  sender.burst = true
  for _, entry in pairs(players) do
    if entry.core then entry.core:beginQuit() end
  end
  if serverEntry then serverEntry.core:beginQuit() end
  local deadline = e.now() + M.SHUTDOWN_TIMEOUT
  while e.now() < deadline do
    step()
    local busy = not sender.idle()
    for _, entry in pairs(players) do
      if entry.core and not entry.core.quitReady then busy = true end
    end
    if serverEntry and not serverEntry.core.quitReady then busy = true end
    if not busy then break end
    e.wait(0.1)
  end
  for player, entry in pairs(players) do
    entry.store.commit()
    players[player] = nil
  end
end

-- ---------------------------------------------------------- error capture

--- Automatic capture of server script errors (ScriptContext.Error), off
--- unless captureErrors = true. They are sent under one server device per
--- game, never a player's, since a server error belongs to no one player.
local function startErrorCapture()
  local deviceId = M.serverDeviceIdFor(config.salt)
  local store = newStore(deviceId, false)
  local core = newCore(deviceId, store)
  serverEntry = { core = core, store = store }
  core:start()
  local ok, scriptContext = pcall(env().service, 'ScriptContext')
  if not ok or not scriptContext then return end
  serverEntry.connection = scriptContext.Error:Connect(function(message, trace, source)
    M.captureScriptError(message, trace, source)
  end)
end

--- With the game's error capture switch off (the session or settings
--- answer), the hook is taken out rather than left to drop every error.
function syncErrorHook()
  local entry = serverEntry
  if not entry or not entry.connection then return end
  local capture = entry.core.errorCapture
  if capture and not capture.enabled then
    pcall(function() entry.connection:Disconnect() end)
    entry.connection = nil
  end
end

--- Feeds one server script error to automatic capture. The SDK's own
--- errors are never captured.
function M.captureScriptError(message, trace, source)
  if not serverEntry then return false end
  local text = tostring(message or '')
  local stack = trace and tostring(trace) or nil
  if (stack and stack:lower():find('ravensight', 1, true)) or text:lower():find('ravensight', 1, true) then return false end
  if script ~= nil and typeof and typeof(source) == 'Instance' and source:IsDescendantOf(script) then return false end
  return serverEntry.core:captureError({ source = 'uncaught', severity = 'error', message = text, stack = stack, errorType = 'LuaError' })
end

-- -------------------------------------------------------------------- init

--- options:
---   ingestKey        your game's key (gt_live_... recommended: it never
---                    leaves the server). Empty means inert.
---   salt             at least 16 characters, secret, never changed: the
---                    key the UserIds are hashed with. Required.
---   apiUrl           default https://api.ravensight.io
---   gameVersion      default tostring(game.PlaceVersion)
---   consent          "opt_out" (default) or "opt_in"
---   flushInterval    seconds an event waits to be batched, default 15
---   maxQueueSize     unsent events kept per player, default 500
---   maxRequestsPerMinute  the SDK's share of HttpService, default 90
---   persistQueue     save each player's state in a DataStore, default true
---   dataStoreName    default "Ravensight"
---   captureErrors    capture server script errors, default false
---   attributionFromLaunchData  read utm_* from join launch data, default true
---   distribution     a short label sent on each session
---   quitTimeout      seconds a leaving player's last batch may take, default 10
---   debug            print informational lines
---   optional         silence the warning an inert start prints
function M.init(options)
  if initialized then return true end
  options = options or {}
  local key = type(options.ingestKey) == 'string' and options.ingestKey:match('^%s*(.-)%s*$') or ''
  if key == '' then
    if not options.optional then log('warn', 'no ingestKey, analytics are off (pass optional = true to silence this)') end
    return false
  end
  local salt = options.salt
  if type(salt) ~= 'string' or #salt < M.MIN_SALT_LENGTH then
    log('warn', 'a salt of at least 16 characters is required, analytics are off')
    return false
  end
  local e = env()
  local gameVersion = options.gameVersion
  if gameVersion == nil and game ~= nil then gameVersion = tostring(game.PlaceVersion) end
  config = {
    ingestKey = key,
    salt = salt,
    apiUrl = options.apiUrl,
    gameVersion = gameVersion or '1.0.0',
    consent = options.consent,
    flushInterval = options.flushInterval or M.DEFAULT_FLUSH_INTERVAL,
    maxQueueSize = options.maxQueueSize,
    persistQueue = options.persistQueue ~= false,
    dataStoreName = options.dataStoreName or M.DATASTORE_NAME,
    captureErrors = options.captureErrors == true,
    attributionFromLaunchData = options.attributionFromLaunchData ~= false,
    distribution = options.distribution,
    quitTimeout = options.quitTimeout or M.DEFAULT_QUIT_TIMEOUT,
    debug = options.debug == true,
  }
  sender = newSender(options.maxRequestsPerMinute or M.DEFAULT_MAX_REQUESTS_PER_MINUTE)
  initialized = true
  lastSave = e.now()

  local Players = e.service('Players')
  local RunService = e.service('RunService')
  connections[#connections + 1] = Players.PlayerAdded:Connect(function(player) addPlayer(player) end)
  connections[#connections + 1] = Players.PlayerRemoving:Connect(function(player) removePlayer(player) end)
  connections[#connections + 1] = RunService.Heartbeat:Connect(step)
  local dataModel = e.game or game
  if dataModel and dataModel.BindToClose then
    dataModel:BindToClose(M.shutdown)
  end
  if config.captureErrors then startErrorCapture() end
  for _, player in ipairs(Players:GetPlayers()) do
    e.spawn(addPlayer, player)
  end
  return true
end

-- ------------------------------------------------------------- the events

local function coreFor(player)
  local entry = player and players[player]
  return entry and entry.core or nil
end
M._coreFor = coreFor

function M.track(player, name, data)
  local core = coreFor(player)
  if not core then return false end
  core:track(name, data)
  return true
end

function M.purchase(player, amount, currency, itemType, itemId, opts)
  local name, props = Typed.purchase(amount, currency, itemType, itemId, opts)
  return M.track(player, name, props)
end

function M.resource(player, flow, resource, amount, opts)
  local name, props = Typed.resource(flow, resource, amount, opts)
  return M.track(player, name, props)
end

function M.progression(player, status, p1, opts)
  local name, props = Typed.progression(status, p1, opts)
  return M.track(player, name, props)
end

--- An error the game reports itself, for one player. severity: debug, info,
--- warning, error or critical. opts: stack, errorType, name, props.
function M.trackError(player, severity, message, opts)
  local core = coreFor(player)
  if not core then return false end
  return core:trackError(severity, message, opts)
end

function M.trackAd(player, network, format, result, opts)
  local name, props = Typed.ad(network, format, result, opts)
  if not name then
    log('warn', 'ad event not sent: ' .. tostring(props))
    return false, props
  end
  return M.track(player, name, props)
end

function M.trackAdRevenue(player, network, format, placement, revenueMicros, currency, opts)
  local merged = {}
  for k, v in pairs(opts or {}) do merged[k] = v end
  merged.placement, merged.revenueMicros, merged.currency = placement, revenueMicros, currency
  return M.trackAd(player, network, format, 'shown', merged)
end

M.microsFromDecimalString = Typed.microsFromDecimalString
M.microsFromRevenue = Typed.microsFromRevenue

--- Where this player came from, sent once per player (the flag is saved
--- with their state). Returns true, or false and why.
function M.setAttribution(player, attribution)
  local core = coreFor(player)
  if not core then return false, 'not_started' end
  return core:setAttribution(attribution)
end

function M.fetchConfig(player)
  local core = coreFor(player)
  return core and core:fetchConfig() or false
end

--- A remote config value for this player; reading one is what marks the
--- player as exposed to a running experiment.
function M.getConfig(player, key, fallback)
  local core = coreFor(player)
  if not core then return fallback end
  return core:getConfig(key, fallback)
end

function M.flush(player)
  if player then
    local core = coreFor(player)
    if core then core:flush() end
    return
  end
  for _, entry in pairs(players) do
    if entry.core then entry.core:flush() end
  end
end

function M.submitFeedback(player, message, category, rating)
  local core = coreFor(player)
  if not core then return false, 'disabled' end
  return core:submitFeedback(message, category, rating)
end

-- ----------------------------------------------------------------- privacy

--- The player's choice, saved at once (their DataStore entry is written
--- now). With false their queue is dropped and nothing more is sent.
function M.setTrackingEnabled(player, enabled)
  local entry = player and players[player]
  if not entry or not entry.core then return false end
  entry.core:setTrackingEnabled(enabled and true or false)
  env().spawn(entry.store.commit)
  return true
end

function M.isTrackingEnabled(player)
  local core = coreFor(player)
  return core ~= nil and core:isTrackingEnabled() == true
end

--- Deletes a player's saved state, for an erasure request: their DataStore
--- entry is removed. The events already sent are deleted from Ravensight
--- by device id (getDeviceId), not by this call.
function M.forgetPlayer(userId)
  assert(initialized, 'ravensight: call init() first')
  local deviceId = M.deviceIdFor(config.salt, userId)
  local ok, ds = pcall(function()
    return env().service('DataStoreService'):GetDataStore(config.dataStoreName)
  end)
  if not ok or not ds then return false end
  local removed = pcall(ds.RemoveAsync, ds, 'rs1_' .. deviceId)
  return removed
end

-- ------------------------------------------- identify players who sign in

--- True when `id` is the player's UserId, name or display name: public, and
--- tied to their Roblox account, so never an account id to hash.
local function isRobloxIdentity(player, id)
  if type(player) ~= 'table' and type(player) ~= 'userdata' then return false end
  local ok, same = pcall(function()
    return id == tostring(player.UserId) or id == player.Name or id == player.DisplayName
  end)
  return ok and same == true
end

--- Links this player to your game's OWN account system, after your own
--- sign-in. A Roblox player is already one id across every device they play
--- on, so a game without its own accounts never needs this. Pass a random,
--- high-entropy id stored with the account (a random UUID or analytics id),
--- a string or a whole number used as its decimal digits; never the UserId,
--- a name, a handle, a sequential database key or an email: they are public
--- or guessable, and Ravensight's identify salt for your game reaches every
--- key of the game, so a guessable id can be matched. The hash is a
--- pseudonymous identifier to declare in the game's privacy notice.
---
--- Only a salted hash (accountHash, HMAC-SHA256 keyed with Ravensight's
--- identify salt from the session answer, not your device id salt) is sent,
--- with the player's session token, once per session, and saved in the
--- player's DataStore entry. The id itself is held in memory only until
--- that salt is known. A different account first does resetIdentity. It
--- never enters the event queue or delays an event. Before the player's
--- opt_in yes it is held in memory only. A call before the player's saved
--- state has loaded is held and applied when it has.
---
--- Returns true, or false and the reason: "not_text", "empty", "too_long"
--- (over 256 bytes of UTF-8), "looks_like_email" (any "@"),
--- "looks_like_user_id" (the player's UserId, name or display name),
--- "no_player" or "not_started" (before init, or inert). A refusal changes
--- nothing and prints one warning.
function M.identify(player, accountId)
  local id, reason = Core.identifyRefusal(accountId)
  if not id then
    log('warn', 'identify() refused (' .. reason .. '): pass a non-empty random id of at most 256 bytes with no @')
    return false, reason
  end
  if not initialized then return false, 'not_started' end
  if player == nil then return false, 'no_player' end
  if isRobloxIdentity(player, id) then
    log('warn', 'identify() refused (looks_like_user_id): pass a random id your game stores with its own account, never the UserId or a name')
    return false, 'looks_like_user_id'
  end
  local entry = players[player]
  if entry and entry.core then
    local ok, why = keepingAttribution(entry, function(core) return core:identify(id) end)
    env().spawn(entry.store.commit)
    return ok, why
  end
  local waiting = pending[player] or {}
  waiting.account = id
  pending[player] = waiting
  return true
end

--- For sign-out from your game's own account: forgets it and deletes the
--- saved hash from the player's entry at once. Sends nothing; does nothing
--- when no account is set. Roblox derives the device id from the UserId, so
--- the fresh device id the other SDKs switch to lasts only for the rest of
--- this server visit; on the next visit the player is back on the id from
--- their UserId, which may still count as the account they signed out of
--- until they sign in again (see docs/FEASIBILITY.md).
function M.resetIdentity(player)
  if player == nil or not initialized then return end
  local entry = players[player]
  if entry and entry.core then
    keepingAttribution(entry, function(core) core:resetIdentity() end)
    env().spawn(entry.store.commit)
    return
  end
  local waiting = pending[player] or {}
  waiting.account = nil
  waiting.reset = true
  pending[player] = waiting
end

--- True while an account is set by identify for this player. The id is
--- never readable.
function M.isIdentified(player)
  local entry = player and players[player]
  if entry and entry.core then return entry.core:isIdentified() end
  local waiting = player and pending[player]
  return waiting ~= nil and waiting.account ~= nil
end

-- ---------------------------------------------------------- campaign links

--- Sends a Ravensight campaign link with this player's next session, so the
--- player is counted on the Campaign links page. The SDK already reads
--- rs_link from the join's launch data (with attributionFromLaunchData,
--- the default); call this when your game carries the link another way.
--- A call before the player's state has loaded goes with their first
--- session.
---
--- Returns true when `linkId` is a link id (24 hex characters, in any case),
--- which then replaces any link waiting; otherwise false and the reason:
--- "invalid_link", "no_player" or "not_started". A refusal changes nothing.
--- Memory only; sent once, and only when the player's session may open
--- (the player's consent).
function M.setCampaignLink(player, linkId)
  local id = Core.campaignLinkId(linkId)
  if not id then return false, 'invalid_link' end
  if not initialized then return false, 'not_started' end
  if player == nil then return false, 'no_player' end
  local entry = players[player]
  if entry and entry.core then return entry.core:setCampaignLink(id) end
  local waiting = pending[player] or {}
  waiting.link = id
  pending[player] = waiting
  return true
end

function M.getDeviceId(player)
  local core = coreFor(player)
  return core and core.deviceId or nil
end

function M.getStatusReason(player)
  local core = coreFor(player)
  if not core then return 'disabled' end
  return core:getStatusReason()
end

function M.getDeliveryStats(player)
  local core = coreFor(player)
  return core and core:getDeliveryStats() or {}
end

--- Subscribe to an SDK event for every player; fn(player, ...). Returns a
--- function that unsubscribes. Events: session_ready, session_failed(reason),
--- status_changed(reason), tracking_disabled(source), events_flushed(count),
--- flush_failed(reason), feedback_submitted, feedback_failed(reason),
--- event_tracked(name, data), config_ready(source).
function M.on(name, fn)
  listeners[name] = listeners[name] or {}
  table.insert(listeners[name], fn)
  return function()
    for i, f in ipairs(listeners[name] or {}) do
      if f == fn then table.remove(listeners[name], i) return end
    end
  end
end

--- For the specs only: forget everything so init() can run again.
function M._reset()
  for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
  if serverEntry and serverEntry.connection then pcall(function() serverEntry.connection:Disconnect() end) end
  config, initialized, players, serverEntry, listeners, sender, connections, lastSave, warned =
    nil, false, {}, nil, {}, nil, {}, 0, {}
  pending = {}
end
function M._players() return players end
function M._server() return serverEntry end
function M._sender() return sender end

return M
