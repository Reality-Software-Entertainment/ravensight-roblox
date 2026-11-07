-- ravensight/scrub.lua: the device scrub of error text.
--
-- The rules of the errors contract ("Scrub"), applied to an automatic
-- capture's message, stack and trail before it is queued. The server runs
-- the same rules again; this copy only makes sure nothing private leaves
-- the device. The binding cases are spec/scrub-vectors.json, copied from
-- the server repository.
--
-- Lua patterns cannot express the server's expressions, so each rule is a
-- small scanner over bytes that finds exactly what the server's expression
-- finds, in the same order:
--
--  1. a URL loses its query, fragment and any user:password@
--  2. Bearer tokens, JWT-shaped strings and gt_ keys become [token]
--  3. an email address becomes [email]
--  4. C:\Users\<name>, /Users/<name> and /home/<name> become ~
--  5. IPv4, full IPv6 and compressed IPv6 with a digit become [ip]
--  6. a run of 32 or more of [A-Za-z0-9+/=_-] with a digit becomes [token],
--     unless it is a path of path words
--
-- Pure Lua 5.1, no engine calls. MIT licensed, part of ravensight-roblox.

local Scrub = {}

local byte, sub = string.byte, string.sub

local function isDigit(b) return b ~= nil and b >= 48 and b <= 57 end
local function isUpper(b) return b ~= nil and b >= 65 and b <= 90 end
local function isLower(b) return b ~= nil and b >= 97 and b <= 122 end
local function isAlpha(b) return isUpper(b) or isLower(b) end
local function isAlnum(b) return isAlpha(b) or isDigit(b) end
--- A regular expression word character: [A-Za-z0-9_].
local function isWord(b) return isAlnum(b) or b == 95 end
local function isHex(b) return isDigit(b) or (b ~= nil and ((b >= 97 and b <= 102) or (b >= 65 and b <= 70))) end
--- \s for ASCII: space, tab, newline, vertical tab, form feed, return.
local function isSpace(b) return b == 32 or (b ~= nil and b >= 9 and b <= 13) end
local function lower(b) if isUpper(b) then return b + 32 end return b end

--- A word boundary before position i (i is a word character).
local function boundaryBefore(s, i) return not isWord(byte(s, i - 1)) end

--- Rewrites s with matcher(s, i) tried at every position from left to
--- right: matcher returns the end of a match (exclusive) and its
--- replacement, or nil. Scanning resumes after a match, as a global
--- replace does.
local function replaceAll(s, matcher)
  local out, i, n, last = {}, 1, #s, 1
  while i <= n do
    local stop, replacement = matcher(s, i)
    if stop then
      out[#out + 1] = sub(s, last, i - 1)
      out[#out + 1] = replacement
      i, last = stop, stop
    else
      i = i + 1
    end
  end
  out[#out + 1] = sub(s, last)
  return table.concat(out)
end

-- 1. URL: (?<![a-z0-9+.-])([a-z][a-z0-9+.-]*://)(?:[^\s/?#@'"<>]*@)?([^\s?#'"<>]*)(?:[?#][^\s'"<>]*)?
local function isSchemeChar(b) return isAlnum(b) or b == 43 or b == 46 or b == 45 end
local function isQuoteOrAngle(b) return b == 39 or b == 34 or b == 60 or b == 62 end
local function urlMatch(s, i)
  if not isAlpha(byte(s, i)) or isSchemeChar(byte(s, i - 1)) then return nil end
  local j = i
  while isSchemeChar(byte(s, j)) do j = j + 1 end
  if sub(s, j, j + 2) ~= '://' then return nil end
  local scheme = sub(s, i, j + 2)
  local k = j + 3
  -- Optional user:password@ before the host.
  local u = k
  while true do
    local b = byte(s, u)
    if b == nil or isSpace(b) or b == 47 or b == 63 or b == 35 or b == 64 or isQuoteOrAngle(b) then break end
    u = u + 1
  end
  if byte(s, u) == 64 then k = u + 1 end
  local h = k
  while true do
    local b = byte(s, h)
    if b == nil or isSpace(b) or b == 63 or b == 35 or isQuoteOrAngle(b) then break end
    h = h + 1
  end
  local rest = sub(s, k, h - 1)
  local e = h
  local b = byte(s, e)
  if b == 63 or b == 35 then
    e = e + 1
    while true do
      b = byte(s, e)
      if b == nil or isSpace(b) or isQuoteOrAngle(b) then break end
      e = e + 1
    end
  end
  return e, scheme .. rest
end

-- 2. \bBearer\s+[A-Za-z0-9\-._~+/]+=*   (case-insensitive)
local function isBearerChar(b) return isAlnum(b) or b == 45 or b == 46 or b == 95 or b == 126 or b == 43 or b == 47 end
local BEARER = { 98, 101, 97, 114, 101, 114 }
local function bearerMatch(s, i)
  if lower(byte(s, i)) ~= 98 or not boundaryBefore(s, i) then return nil end
  for k = 1, 6 do if lower(byte(s, i + k - 1)) ~= BEARER[k] then return nil end end
  local j = i + 6
  if not isSpace(byte(s, j)) then return nil end
  while isSpace(byte(s, j)) do j = j + 1 end
  if not isBearerChar(byte(s, j)) then return nil end
  while isBearerChar(byte(s, j)) do j = j + 1 end
  while byte(s, j) == 61 do j = j + 1 end
  return j, '[token]'
end

-- \beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*
local function isB64Url(b) return isWord(b) or b == 45 end
local function jwtMatch(s, i)
  if sub(s, i, i + 2) ~= 'eyJ' or not boundaryBefore(s, i) then return nil end
  local j = i + 3
  if not isB64Url(byte(s, j)) then return nil end
  while isB64Url(byte(s, j)) do j = j + 1 end
  if byte(s, j) ~= 46 or not isB64Url(byte(s, j + 1)) then return nil end
  j = j + 1
  while isB64Url(byte(s, j)) do j = j + 1 end
  if byte(s, j) ~= 46 then return nil end
  j = j + 1
  while isB64Url(byte(s, j)) do j = j + 1 end
  return j, '[token]'
end

-- \bgt_[A-Za-z0-9_]+
local function gtKeyMatch(s, i)
  if sub(s, i, i + 2) ~= 'gt_' or not boundaryBefore(s, i) or not isWord(byte(s, i + 3)) then return nil end
  local j = i + 3
  while isWord(byte(s, j)) do j = j + 1 end
  return j, '[token]'
end

-- 3. (?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}
local function isLocalChar(b) return isAlnum(b) or b == 46 or b == 95 or b == 37 or b == 43 or b == 45 end
local function isDomainChar(b) return isAlnum(b) or b == 46 or b == 45 end
local function emailMatch(s, i)
  if not isLocalChar(byte(s, i)) or isLocalChar(byte(s, i - 1)) then return nil end
  local at = i
  while isLocalChar(byte(s, at)) do at = at + 1 end
  if byte(s, at) ~= 64 then return nil end
  local d = at + 1
  while isDomainChar(byte(s, d)) do d = d + 1 end
  -- The rightmost dot with at least one domain character before it and
  -- at least two letters after it; the letters run as far as they go.
  for dot = d - 1, at + 2, -1 do
    if byte(s, dot) == 46 and isAlpha(byte(s, dot + 1)) and isAlpha(byte(s, dot + 2)) then
      local e = dot + 1
      while e < d and isAlpha(byte(s, e)) do e = e + 1 end
      return e, '[email]'
    end
  end
  return nil
end

-- 4. \b[A-Za-z]:[\\/](?:Users|Documents and Settings)[\\/][^/\\'"<>:\r\n]+
--    (case-insensitive). The name runs to the next slash, quote, <, >, :
--    or line end, spaces included: a user name can contain spaces.
local function isSlash(b) return b == 47 or b == 92 end
local function homeNameEnd(s, j)
  local start = j
  while true do
    local b = byte(s, j)
    if b == nil or isSlash(b) or b == 39 or b == 34 or b == 60 or b == 62 or b == 58 or b == 13 or b == 10 then break end
    j = j + 1
  end
  if j == start then return nil end
  return j
end
local function ciWord(s, i, word)
  for k = 1, #word do
    if lower(byte(s, i + k - 1)) ~= byte(word, k) then return false end
  end
  return true
end
local function homeWindowsMatch(s, i)
  if not isAlpha(byte(s, i)) or not boundaryBefore(s, i) then return nil end
  if byte(s, i + 1) ~= 58 or not isSlash(byte(s, i + 2)) then return nil end
  local j
  if ciWord(s, i + 3, 'users') then j = i + 8
  elseif ciWord(s, i + 3, 'documents and settings') then j = i + 25
  else return nil end
  if not isSlash(byte(s, j)) then return nil end
  local e = homeNameEnd(s, j + 1)
  if not e then return nil end
  return e, '~'
end

-- \/(?:Users|home)\/[^/\\'"<>:\r\n]+
local function homeUnixMatch(s, i)
  if byte(s, i) ~= 47 then return nil end
  local j
  if sub(s, i + 1, i + 6) == 'Users/' then j = i + 7
  elseif sub(s, i + 1, i + 5) == 'home/' then j = i + 6
  else return nil end
  local e = homeNameEnd(s, j)
  if not e then return nil end
  return e, '~'
end

-- 5. \b(?:\d{1,3}\.){3}\d{1,3}\b
local function ipv4Match(s, i)
  if not isDigit(byte(s, i)) or not boundaryBefore(s, i) then return nil end
  local j = i
  for group = 1, 4 do
    local start = j
    while isDigit(byte(s, j)) do j = j + 1 end
    local length = j - start
    if length < 1 or length > 3 then return nil end
    if group < 4 then
      if byte(s, j) ~= 46 then return nil end
      j = j + 1
    end
  end
  if isWord(byte(s, j)) then return nil end
  return j, '[ip]'
end

-- \b(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}\b   (case-insensitive)
local function ipv6FullMatch(s, i)
  if not isHex(byte(s, i)) or not boundaryBefore(s, i) then return nil end
  local j = i
  for group = 1, 8 do
    local start = j
    while isHex(byte(s, j)) and j - start < 4 do j = j + 1 end
    if j == start then return nil end
    if group < 8 then
      if byte(s, j) ~= 58 then return nil end
      j = j + 1
    end
  end
  if isWord(byte(s, j)) then return nil end
  return j, '[ip]'
end

--- The ends (exclusive) of [0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6} from i, in
--- the order a backtracking engine tries them: longest first at each step.
local function hexChainEnds(s, i, groupsLeft, out)
  for length = 4, 1, -1 do
    local ok = true
    for k = 0, length - 1 do
      if not isHex(byte(s, i + k)) then ok = false break end
    end
    if ok then
      local e = i + length
      if groupsLeft > 0 and byte(s, e) == 58 then
        hexChainEnds(s, e + 1, groupsLeft - 1, out)
      end
      out[#out + 1] = e
    end
  end
  return out
end

-- (?:\b[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6})?::(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6}\b)?
local function ipv6ShortAfter(s, c)
  -- c is the position of '::'; the optional suffix ends at a boundary.
  for _, e in ipairs(hexChainEnds(s, c + 2, 6, {})) do
    if not isWord(byte(s, e)) then return e end
  end
  return c + 2
end
local function ipv6ShortMatch(s, i)
  local e
  if isHex(byte(s, i)) and boundaryBefore(s, i) then
    for _, p in ipairs(hexChainEnds(s, i, 6, {})) do
      if sub(s, p, p + 1) == '::' then e = ipv6ShortAfter(s, p) break end
    end
  end
  if not e and sub(s, i, i + 1) == '::' then e = ipv6ShortAfter(s, i) end
  if not e then return nil end
  local text = sub(s, i, e - 1)
  if text:find('%d') then return e, '[ip]' end
  return e, text
end

-- 6. (?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/=_-]{32,}
local function isRunChar(b) return isAlnum(b) or b == 43 or b == 47 or b == 61 or b == 95 or b == 45 end

--- One part of a path word: lowercase [a-z0-9]+, CamelCase
--- [A-Z][a-z0-9]*([A-Z][a-z0-9]+)*, or an acronym [A-Z0-9]{1,6}.
function Scrub.isPathPart(part)
  local n = #part
  if n == 0 then return false end
  local allLower, allAcronym = true, n <= 6
  for k = 1, n do
    local b = byte(part, k)
    if not (isLower(b) or isDigit(b)) then allLower = false end
    if not (isUpper(b) or isDigit(b)) then allAcronym = false end
  end
  if allLower or allAcronym then return true end
  if not isUpper(byte(part, 1)) then return false end
  local k = 2
  while k <= n and (isLower(byte(part, k)) or isDigit(byte(part, k))) do k = k + 1 end
  while k <= n do
    if not isUpper(byte(part, k)) then return false end
    k = k + 1
    if not (isLower(byte(part, k)) or isDigit(byte(part, k))) then return false end
    while k <= n and (isLower(byte(part, k)) or isDigit(byte(part, k))) do k = k + 1 end
  end
  return true
end

local function split(text, isSeparator)
  local parts, start = {}, 1
  for k = 1, #text do
    if isSeparator(byte(text, k)) then
      parts[#parts + 1] = sub(text, start, k - 1)
      start = k + 1
    end
  end
  parts[#parts + 1] = sub(text, start)
  return parts
end

function Scrub.isPathWord(piece)
  if piece == '' then return true end
  if #piece >= 32 then return false end
  for _, part in ipairs(split(piece, function(b) return b == 95 or b == 45 end)) do
    if not Scrub.isPathPart(part) then return false end
  end
  return true
end

function Scrub.isPath(run)
  if not run:find('/', 1, true) then return false end
  for _, piece in ipairs(split(run, function(b) return b == 47 end)) do
    if not Scrub.isPathWord(piece) then return false end
  end
  return true
end

local function longRunMatch(s, i)
  if not isRunChar(byte(s, i)) or isRunChar(byte(s, i - 1)) then return nil end
  local j = i
  while isRunChar(byte(s, j)) do j = j + 1 end
  if j - i < 32 then return nil end
  local run = sub(s, i, j - 1)
  if run:find('%d') and not Scrub.isPath(run) then return j, '[token]' end
  return j, run
end

local RULES = {
  urlMatch, bearerMatch, jwtMatch, gtKeyMatch, emailMatch, homeWindowsMatch,
  homeUnixMatch, ipv4Match, ipv6FullMatch, ipv6ShortMatch, longRunMatch,
}

--- The scrubbed text. Anything that is not a non-empty string comes back
--- unchanged.
function Scrub.scrub(value)
  if type(value) ~= 'string' or value == '' then return value end
  for _, rule in ipairs(RULES) do value = replaceAll(value, rule) end
  return value
end

return Scrub
