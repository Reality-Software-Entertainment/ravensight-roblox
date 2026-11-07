-- ravensight/errors.lua: error events and the device limits on automatic
-- capture, with no engine calls in it.
--
-- The errors contract (docs/errors/CONTRACT.md on the server) defines the
-- event: rs_kind "error", rs_severity, rs_message (200 characters),
-- rs_stack (2,000), rs_source, rs_error_type (100). A manual trackError is
-- sent as the game wrote it, cut to those lengths, and the server scrubs
-- it. An automatic capture is scrubbed here first, and is held to the
-- per-session limits: 30 captures, 3 for one dedupe key, and a token bucket
-- of 6 a minute. The caps and the bucket are checked before any scrub or
-- template work, so a game that fails every frame pays almost nothing once
-- they are spent.
--
-- There is no log trail in this SDK: the engine gives no hook on its log,
-- so rs_trail is never sent.
--
-- MIT licensed, part of ravensight-roblox.

-- Modules load by instance on Roblox (this file's siblings) and by name
-- everywhere else (the specs).
local function import(name)
  if script ~= nil then return require(script.Parent:WaitForChild(name)) end
  return require('ravensight.' .. name)
end

local Typed = import('typed')
local Scrub = import('scrub')

local Errors = {}
Errors.__index = Errors

Errors.MESSAGE_CHARS = 200
Errors.STACK_CHARS = 2000
Errors.TYPE_CHARS = 100
Errors.SESSION_CAP = 30
Errors.PER_KEY_CAP = 3
Errors.BUCKET_SIZE = 6
Errors.BUCKET_SECONDS = 60
--- Captures held before the session answer says whether capture is on.
Errors.BOOT_HOLD = 5
--- Pending crash records: how many, and for how long.
Errors.PENDING_MAX = 5
Errors.PENDING_MAX_AGE_MS = 30 * 86400 * 1000

Errors.SEVERITIES = { debug = true, info = true, warning = true, error = true, critical = true }
Errors.SOURCES = {
  manual = true, uncaught = true, unhandled_rejection = true, request = true,
  console = true, log = true, dead_click = true, crash = true,
}

--- A string cut to `limit` characters, never inside a UTF-8 character.
--- Bytes are never fewer than characters, so the cut is within the limit.
local function cut(value, limit)
  if type(value) ~= 'string' then return nil end
  return Typed.cut(value, limit)
end

--- Scrubbed text: cut to four times the limit first, so a huge line never
--- costs more than a bounded scrub, then to the limit.
function Errors.scrubbed(value, limit)
  if type(value) ~= 'string' or value == '' then return nil end
  return cut(Scrub.scrub(cut(value, limit * 4)), limit)
end

--- The data of one error event. info: severity, message, stack, source,
--- errorType, props (extra properties, which the reserved keys override).
--- `scrub` is true for automatic captures.
function Errors.build(info, scrub)
  local data = {}
  if type(info.props) == 'table' then
    for k, v in pairs(info.props) do data[k] = v end
  end
  data.rs_kind = 'error'
  data.rs_severity = Errors.SEVERITIES[info.severity] and info.severity or 'error'
  local message = tostring(info.message or '')
  if scrub then
    data.rs_message = Errors.scrubbed(message, Errors.MESSAGE_CHARS) or ''
    data.rs_stack = Errors.scrubbed(info.stack, Errors.STACK_CHARS)
  else
    data.rs_message = cut(message, Errors.MESSAGE_CHARS)
    data.rs_stack = cut(info.stack, Errors.STACK_CHARS)
  end
  if data.rs_stack == '' then data.rs_stack = nil end
  local source = info.source
  if Errors.SOURCES[source] and source ~= 'manual' then data.rs_source = source end
  if type(info.errorType) == 'string' and info.errorType ~= '' then
    data.rs_error_type = cut(info.errorType, Errors.TYPE_CHARS)
  end
  return data
end

--- The local dedupe template of a message: digit runs, hex runs and quoted
--- text become placeholders, so "slot 3" and "slot 4" are one key.
function Errors.template(message)
  local text = tostring(message or '')
  text = text:gsub('"[^"]*"', '"?"'):gsub("'[^']*'", "'?'")
  text = text:gsub('0x%x+', '#'):gsub('%x%x%x%x%x%x%x%x+', '#'):gsub('%d+', '#')
  return text
end

--- The first line of a stack, as the frame part of the dedupe key.
function Errors.firstFrame(stack)
  if type(stack) ~= 'string' then return '' end
  for line in stack:gmatch('[^\n]+') do
    local trimmed = line:match('^%s*(.-)%s*$')
    if trimmed ~= '' and trimmed ~= 'stack traceback:' then return trimmed end
  end
  return ''
end

--- The per-session limiter. now() is monotonic seconds.
function Errors.newLimiter(now)
  local self = setmetatable({}, Errors)
  self.now = now
  self:resetSession()
  return self
end

function Errors:resetSession()
  self.captures = 0
  self.perKey = {}
  self.tokens = Errors.BUCKET_SIZE
  self.refilledAt = self.now()
end

--- True when one more automatic capture may be made now. The caps and the
--- bucket are checked first; only then is the dedupe key worked out.
function Errors:allow(info)
  if self.captures >= Errors.SESSION_CAP then return false end
  local t = self.now()
  local elapsed = t - self.refilledAt
  if elapsed > 0 then
    self.tokens = math.min(Errors.BUCKET_SIZE, self.tokens + elapsed * Errors.BUCKET_SIZE / Errors.BUCKET_SECONDS)
    self.refilledAt = t
  end
  if self.tokens < 1 then return false end
  -- Cut to four times the limits before any template or frame work, so a
  -- huge line costs a bounded amount.
  local message = cut(tostring(info.message or ''), Errors.MESSAGE_CHARS * 4)
  local stack = type(info.stack) == 'string' and cut(info.stack, Errors.STACK_CHARS * 4) or nil
  local key = cut(tostring(info.errorType or ''), Errors.TYPE_CHARS) .. '|' .. Errors.template(message) .. '|' .. Errors.firstFrame(stack)
  local seen = self.perKey[key] or 0
  if seen >= Errors.PER_KEY_CAP then return false end
  self.perKey[key] = seen + 1
  self.tokens = self.tokens - 1
  self.captures = self.captures + 1
  return true
end

return Errors
