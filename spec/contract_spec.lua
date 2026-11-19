-- The parts of the SDK contract this SDK adds to the shared Lua core:
-- startup reasons, game_started at the real start, the mobile background
-- rule and its marker, error capture, apiUrl forms and the SDK name.
local Core = require('ravensight.core')
local Errors = require('ravensight.errors')
local json = require('ravensight.json')

local function eq(a, b, msg) assert(a == b, (msg or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local KEY = 'gt_live_k'
local ORIGIN = { session = 'ses_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', build = '2.0.0', platform = 'iOS', stamp = 'o1.aaa.bbb' }

local function harness(opts)
  opts = opts or {}
  local h = { requests = {}, files = opts.files or {}, clock = 0, wall = 1800000000, logs = {}, reasons = {} }
  h.core = Core.new({
    apiUrl = opts.apiUrl or 'https://api.test',
    ingestKey = opts.ingestKey or KEY,
    gameVersion = '2.0.0',
    log = function(level, message) table.insert(h.logs, level .. ' ' .. message) end,
    send = function(req, cb)
      if req.url:find('/ingest/config?', 1, true) then cb(404, '{}', {}) return end
      table.insert(h.requests, { req = req, cb = cb })
    end,
    now = function() return h.clock end,
    time = function() return h.wall end,
    timeMs = function() return h.wall * 1000 end,
    storage = {
      read = function(n) return h.files[n] end,
      write = function(n, t) h.files[n] = t end,
      remove = function(n) h.files[n] = nil end,
    },
    randomHex = function(n) return string.rep('ab', n) end,
    platform = 'iOS', osName = 'ios',
    random = function() return 1 end,
    mobile = opts.mobile,
    consent = opts.consent,
    captureErrors = opts.captureErrors,
    playtest = opts.playtest,
  })
  h.core:on('status_changed', function(r) table.insert(h.reasons, tostring(r)) end)
  function h.answer(path, status, body, headers)
    local r = table.remove(h.requests, 1)
    assert(r, 'expected a request to ' .. path .. ', but none was sent')
    assert(r.req.url:find(path, 1, true), 'expected ' .. path .. ', got ' .. r.req.url)
    r.cb(status, body and json.encode(body) or '', headers or {})
    return r.req
  end
  function h.boot(session)
    h.core:start()
    h.answer('/api/v1/settings', 200, { trackingEnabled = true, errorCapture = session and session.settingsCapture })
    local answer = { token = 'tok', expiresIn = 3600, origin = ORIGIN }
    for k, v in pairs(session or {}) do if k ~= 'settingsCapture' then answer[k] = v end end
    return h.answer('/api/v1/session', 201, answer)
  end
  function h.events(req) return json.decode(req.body).events end
  function h.names(req)
    local out = {}
    for _, e in ipairs(h.events(req)) do out[#out + 1] = e.event end
    return table.concat(out, ',')
  end
  function h.pendingNames()
    local out = {}
    for _, e in ipairs(h.core.pending) do out[#out + 1] = e.event end
    return table.concat(out, ',')
  end
  return h
end

return {
  -- --------------------------------------------------------- apiUrl forms
  { 'apiUrl: trimmed, trailing slashes and /api/v1 stripped, empty is the default host', function()
    eq(Core.normalizeApiUrl('https://api.ravensight.io'), 'https://api.ravensight.io')
    eq(Core.normalizeApiUrl('https://api.ravensight.io/'), 'https://api.ravensight.io')
    eq(Core.normalizeApiUrl('https://api.ravensight.io///'), 'https://api.ravensight.io')
    eq(Core.normalizeApiUrl('https://api.ravensight.io/api/v1'), 'https://api.ravensight.io')
    eq(Core.normalizeApiUrl('  https://api.ravensight.io/api/v1/  '), 'https://api.ravensight.io')
    eq(Core.normalizeApiUrl(''), 'https://api.ravensight.io')
    eq(Core.normalizeApiUrl(nil), 'https://api.ravensight.io')
    eq(Core.normalizeApiUrl('   '), 'https://api.ravensight.io')
  end },
  { 'the session names this SDK and version', function()
    local h = harness()
    local req = h.boot()
    eq(json.decode(req.body).sdk, 'roblox/0.2.0')
  end },

  -- ---------------------------------------------------------- lifecycle
  { 'game_started is queued at the start, first, with the start time', function()
    local h = harness()
    h.core:start()
    eq(h.pendingNames(), 'game_started')
    eq(h.core.pending[1].timestamp, 1800000000000)
    eq(#h.requests, 1, 'only the settings check is out')
  end },
  { 'game_started has a once-guard: a second settings check or a re-enable adds none', function()
    local h = harness()
    h.boot()
    h.answer('/api/v1/track/batch', 500, {})
    h.core:checkServerSettings()
    h.answer('/api/v1/settings', 200, { trackingEnabled = true })
    h.core:setTrackingEnabled(true)
    local count = 0
    for _, e in ipairs(h.core.pending) do if e.event == 'game_started' then count = count + 1 end end
    eq(count, 1)
  end },
  { 'an opted-out start queues nothing and sends nothing; a later yes queues game_started once', function()
    local h = harness({ files = { [Core.OPTOUT_FILE] = '1' } })
    h.core:start()
    eq(#h.core.pending, 0)
    eq(#h.requests, 0, 'not even the settings check')
    eq(h.core:getStatusReason(), 'disabled')
    h.core:setTrackingEnabled(true)
    eq(h.pendingNames(), 'game_started')
    h.core:setTrackingEnabled(true)
    eq(h.pendingNames(), 'game_started')
  end },
  { 'game_exited is queued once, however often the quit path runs', function()
    local h = harness()
    h.boot()
    h.core:beginQuit()
    h.core:beginQuit()
    h.core:finishQuit()
    local count = 0
    for _, e in ipairs(h.core.pending) do if e.event == 'game_exited' then count = count + 1 end end
    eq(count, 1)
  end },

  -- ------------------------------------------------------------ reasons
  { 'reasons: ready after a session, invalid_key after a 401, logged once at warning', function()
    local h = harness()
    h.boot()
    eq(h.core:getStatusReason(), nil)
    local refused = harness()
    refused.core:start()
    refused.answer('/api/v1/settings', 401, { error = 'invalid_api_key' })
    eq(refused.core:getStatusReason(), 'invalid_key')
    eq(refused.reasons[#refused.reasons], 'invalid_key')
    local warned = 0
    for _, line in ipairs(refused.logs) do
      if line:find('^warn ingest key refused %(invalid_key%), sending stopped for this run%. Check your gt_live_ key%.') then warned = warned + 1 end
    end
    eq(warned, 1)
  end },
  { 'reasons: tracking_disabled, rate_limited, offline, playtest_job_closed', function()
    local off = harness()
    off.core:start()
    off.answer('/api/v1/settings', 200, { trackingEnabled = false })
    eq(off.core:getStatusReason(), 'tracking_disabled')

    local limited = harness()
    limited.core:start()
    limited.answer('/api/v1/settings', 200, { trackingEnabled = true })
    limited.answer('/api/v1/session', 429, { error = 'rate_limited' }, { ['retry-after'] = '7' })
    eq(limited.core:getStatusReason(), 'rate_limited')
    eq(limited.core.retryAt, 7, 'Retry-After exactly')

    local offline = harness()
    offline.core:start()
    offline.answer('/api/v1/settings', 200, { trackingEnabled = true })
    offline.answer('/api/v1/session', 0, nil)
    eq(offline.core:getStatusReason(), 'offline')

    local pt = harness({ playtest = { token = 'ptk', run_id = 'run1' } })
    pt.core:start()
    pt.answer('/api/v1/settings', 200, { trackingEnabled = true })
    pt.answer('/api/v1/session', 403, { error = 'playtest_job_closed' })
    eq(pt.core:getStatusReason(), 'playtest_job_closed')
  end },
  { 'feedback while off is refused locally with disabled and makes no request', function()
    local h = harness({ files = { [Core.OPTOUT_FILE] = '1' } })
    h.core:start()
    local ok, reason = h.core:submitFeedback('hello', 'bug', 5)
    eq(ok, false)
    eq(reason, 'disabled')
    eq(#h.requests, 0)
  end },
  { 'playtest: pt- device id, the bare token header, nothing written', function()
    local h = harness({ playtest = { token = 'ptk', run_id = 'run1' } })
    h.core:start()
    h.answer('/api/v1/settings', 200, { trackingEnabled = true })
    local req = h.answer('/api/v1/session', 201, { token = 'tok', expiresIn = 3600 })
    eq(json.decode(req.body).deviceId, 'pt-run1')
    eq(req.headers['X-Ravensight-Playtest'], 'ptk')
    eq(h.files[Core.DEVICE_ID_FILE], nil)
    eq(h.files[Core.queueFile(KEY)], nil)
  end },

  -- ------------------------------------------------- the background rule
  { 'mobile: under 30 minutes away queues nothing and keeps the session', function()
    local h = harness({ mobile = true })
    h.boot()
    h.answer('/api/v1/track/batch', 202, { accepted = 1 })
    h.core:enterBackground()
    assert(h.files[Core.MARKER_FILE], 'a marker is written')
    h.wall = h.wall + 1799
    h.core:enterForeground()
    eq(#h.core.pending, 0)
    eq(h.core.sessionToken, 'tok')
    eq(h.files[Core.MARKER_FILE], nil, 'the marker is deleted on return')
  end },
  { 'mobile: 30 minutes away ends the old session at the moment it was left and starts a new one', function()
    local h = harness({ mobile = true })
    h.boot()
    h.answer('/api/v1/track/batch', 202, { accepted = 1 })
    local leftAt = h.wall * 1000
    h.core:enterBackground()
    h.wall = h.wall + 1800
    h.core:enterForeground()
    eq(h.pendingNames(), 'game_exited,game_started')
    eq(h.core.pending[1].timestamp, leftAt, 'game_exited carries the time the player left')
    eq(h.core.pending[1]._origin.session, ORIGIN.session, 'and the old session')
    eq(h.core.pending[2].timestamp, h.wall * 1000, 'game_started is now')
    eq(h.core.sessionToken, '', 'the old session is dropped')
    local req = h.answer('/api/v1/session', 201, { token = 'tok2', expiresIn = 3600, origin = { session = 'ses_new', build = '2.0.0', platform = 'iOS', stamp = 'o1.n.n' } })
    eq(json.decode(req.body).deviceId, h.core.deviceId)
    local batch = h.answer('/api/v1/track/batch', 202, { accepted = 2 })
    local events = h.events(batch)
    eq(events[1].origin.session, ORIGIN.session, 'game_exited goes with the old origin')
    eq(events[2].origin, nil, 'game_started belongs to the new session')
  end },
  { 'desktop: the background calls do nothing', function()
    local h = harness()
    h.boot()
    h.core:enterBackground()
    eq(h.files[Core.MARKER_FILE], nil)
  end },
  { 'a cold launch with a marker sends one game_exited under the old token, then deletes it', function()
    local marker = json.encode({ sessionToken = 'old', expiresAt = 1800000100, backgroundedAt = 1799999000000 })
    local h = harness({ mobile = true, files = { [Core.MARKER_FILE] = marker } })
    h.core:start()
    local first = h.answer('/api/v1/track/batch', 500, {})
    eq(first.headers['X-Session-Token'], 'old')
    local events = h.events(first)
    eq(#events, 1)
    eq(events[1].event, 'game_exited')
    eq(events[1].timestamp, 1799999000000)
    eq(h.files[Core.MARKER_FILE], nil)
    h.answer('/api/v1/settings', 200, { trackingEnabled = true })
    for t = 1, 100 do h.clock = t; h.core:update() end
    for _, r in ipairs(h.requests) do assert(not r.req.url:find('/track/batch', 1, true) or r.req.headers['X-Session-Token'] ~= 'old', 'one attempt, no retry') end
  end },
  { 'an expired marker, or an opted-out player, sends nothing', function()
    local expired = json.encode({ sessionToken = 'old', expiresAt = 1700000000, backgroundedAt = 1699999000000 })
    local h = harness({ mobile = true, files = { [Core.MARKER_FILE] = expired } })
    h.core:start()
    eq(h.answer('/api/v1/settings', 200, { trackingEnabled = true }).method, 'GET')
    eq(h.files[Core.MARKER_FILE], nil)
    local live = json.encode({ sessionToken = 'old', expiresAt = 1800000100, backgroundedAt = 1799999000000 })
    local out = harness({ mobile = true, files = { [Core.MARKER_FILE] = live, [Core.OPTOUT_FILE] = '1' } })
    out.core:start()
    eq(#out.requests, 0)
    eq(out.files[Core.MARKER_FILE], nil, 'an opt-out deletes it')
  end },

  -- ------------------------------------------------------- error capture
  { 'trackError: a manual error goes as written, cut to the contract lengths', function()
    local h = harness()
    h.boot()
    h.core:trackError('warning', 'mail jane@example.com ' .. string.rep('x', 300), { stack = 'at main.script:3', errorType = 'Boom' })
    local data = h.core.pending[#h.core.pending].data
    eq(data.rs_kind, 'error')
    eq(data.rs_severity, 'warning')
    eq(#data.rs_message, 200)
    assert(data.rs_message:find('jane@example.com', 1, true), 'not scrubbed on the device')
    eq(data.rs_source, nil, 'manual sends no source')
    eq(data.rs_error_type, 'Boom')
    eq(data.rs_trail, nil)
  end },
  { 'automatic capture is scrubbed and marked with its source', function()
    local h = harness()
    h.boot({ errorCapture = { enabled = true, trail = false } })
    assert(h.core:captureError({ source = 'uncaught', severity = 'error', message = 'oops for jane@example.com at 10.0.0.1', stack = '/Users/jacob/game/main.lua:3', errorType = 'LuaError' }))
    local data = h.core.pending[#h.core.pending].data
    eq(data.rs_message, 'oops for [email] at [ip]')
    eq(data.rs_stack, '~/game/main.lua:3')
    eq(data.rs_source, 'uncaught')
  end },
  { 'boot captures: at most 5 held until the answer, sent when capture is on', function()
    local h = harness()
    h.core:start()
    for i = 1, 7 do h.core:captureError({ source = 'uncaught', message = 'boot ' .. i .. ' ' .. string.rep('y', i), errorType = 'E' .. i }) end
    eq(#h.core.bootErrors, 5)
    h.answer('/api/v1/settings', 200, { trackingEnabled = true })
    eq(#h.core.pending, 1, 'nothing sent before the switches are known')
    h.answer('/api/v1/session', 201, { token = 'tok', expiresIn = 3600, errorCapture = { enabled = true, trail = false } })
    local errors = 0
    for _, e in ipairs(h.core.pending) do if e.data.rs_kind == 'error' then errors = errors + 1 end end
    eq(errors, 5)
  end },
  { 'boot captures are discarded unsent when the game switched capture off; later ones are not made', function()
    local h = harness()
    h.core:start()
    h.core:captureError({ source = 'uncaught', message = 'boot' })
    h.answer('/api/v1/settings', 200, { trackingEnabled = true, errorCapture = { enabled = false, trail = false } })
    eq(#h.core.bootErrors, 0)
    eq(h.core:captureError({ source = 'uncaught', message = 'later' }), false)
    for _, e in ipairs(h.core.pending) do assert(e.data.rs_kind ~= 'error') end
    h.core:trackError('error', 'manual always passes')
    eq(h.core.pending[#h.core.pending].data.rs_message, 'manual always passes')
  end },
  { 'nothing is captured opted out, or with captureErrors = false', function()
    local out = harness({ files = { [Core.OPTOUT_FILE] = '1' } })
    out.core:start()
    eq(out.core:captureError({ source = 'uncaught', message = 'x' }), false)
    local off = harness({ captureErrors = false })
    off.boot({ errorCapture = { enabled = true } })
    eq(off.core:captureError({ source = 'uncaught', message = 'x' }), false)
  end },
  { 'limits: 3 per dedupe key, 6 a minute, 30 a session', function()
    local h = harness()
    h.boot({ errorCapture = { enabled = true } })
    local kept = 0
    for i = 1, 5 do if h.core:captureError({ source = 'uncaught', message = 'slot ' .. i .. ' failed' }) then kept = kept + 1 end end
    eq(kept, 3, 'one template, three captures')
    kept = 0
    for i = 1, 10 do if h.core:captureError({ source = 'uncaught', message = 'other', errorType = 'T' .. i }) then kept = kept + 1 end end
    eq(kept, 3, 'the bucket of 6 had 3 left')
    local total = 6
    for minute = 1, 10 do
      h.clock = h.clock + 60
      for i = 1, 6 do
        if h.core:captureError({ source = 'uncaught', message = 'm', errorType = 'M' .. minute .. '_' .. i }) then total = total + 1 end
      end
    end
    eq(total, Errors.SESSION_CAP)
  end },
  { 'a pending record from a run that ended is sent on the next launch, at most 5, 30 days', function()
    local files = {}
    local first = harness({ files = files })
    first.boot({ errorCapture = { enabled = true } })
    for i = 1, 7 do first.core:savePendingError({ source = 'uncaught', message = 'fatal ' .. i }) end
    eq(#json.decode(files[Core.PENDING_ERRORS_FILE]), 5)
    local second = harness({ files = files })
    second.boot({ errorCapture = { enabled = true } })
    local errors = 0
    for _, e in ipairs(second.core.pending) do if e.data.rs_kind == 'error' then errors = errors + 1 end end
    eq(errors, 5)
    eq(files[Core.PENDING_ERRORS_FILE], nil, 'delivered records are deleted')

    local old = harness({ files = { [Core.PENDING_ERRORS_FILE] = json.encode({ { t = 1800000000000 - 31 * 86400000, data = { rs_kind = 'error', rs_message = 'old' } } }) } })
    old.boot({ errorCapture = { enabled = true } })
    for _, e in ipairs(old.core.pending) do assert(e.data.rs_kind ~= 'error', 'older than 30 days is dropped') end
  end },
  { 'an opt-out and a reset delete pending records', function()
    local h = harness({ files = { [Core.PENDING_ERRORS_FILE] = '[]' } })
    h.boot()
    h.core:setTrackingEnabled(false)
    eq(h.files[Core.PENDING_ERRORS_FILE], nil)
    local r = harness({ files = { [Core.PENDING_ERRORS_FILE] = '[]' } })
    r.boot()
    r.core:resetDeviceId()
    eq(r.files[Core.PENDING_ERRORS_FILE], nil)
  end },
  { 'automatic errors queue behind gameplay events', function()
    local h = harness()
    h.boot({ errorCapture = { enabled = true } })
    h.core:captureError({ source = 'uncaught', message = 'e' })
    h.core:track('gameplay', {})
    eq(h.core.pending[#h.core.pending].data.rs_kind, 'error')
  end },
  { 'error template and first frame', function()
    eq(Errors.template('slot 3 at 0xdeadbeef "name"'), 'slot # at # "?"')
    eq(Errors.firstFrame('stack traceback:\n  main.script:3: in f\n'), 'main.script:3: in f')
  end },
}
