-- A `bit32` for the specs, with Luau's semantics (unsigned 32-bit results,
-- arguments taken modulo 2^32), so `ravensight.bitcompat` runs its Roblox
-- branch outside Roblox. Built on LuaJIT's `bit`, or on the native
-- operators of Lua 5.3 and later.
local M = 2 ^ 32
local function u(x) return x % M end

local ok, bit = pcall(require, 'bit')
if ok and bit then
  local function wrap(f) return function(...) return u(f(...)) end end
  return {
    band = wrap(bit.band), bor = wrap(bit.bor), bxor = wrap(bit.bxor), bnot = wrap(bit.bnot),
    rshift = wrap(bit.rshift), lshift = wrap(bit.lshift), rrotate = wrap(bit.ror),
  }
end

-- Lua 5.3+: the operators are not even parsed by LuaJIT, hence load().
return assert(load([[
  local M = 2 ^ 32
  local function i(x) return math.tointeger(x % M) end
  local function fold(op, a, ...)
    local r = i(a)
    for k = 1, select('#', ...) do r = op(r, i((select(k, ...)))) end
    return r
  end
  return {
    band = function(...) return fold(function(a, b) return a & b end, ...) end,
    bor = function(...) return fold(function(a, b) return a | b end, ...) end,
    bxor = function(...) return fold(function(a, b) return a ~ b end, ...) end,
    bnot = function(a) return (~i(a)) & 0xffffffff end,
    rshift = function(a, n) return (i(a) >> n) & 0xffffffff end,
    lshift = function(a, n) return (i(a) << n) & 0xffffffff end,
    rrotate = function(a, n) a = i(a) n = n % 32 return ((a >> n) | (a << (32 - n))) & 0xffffffff end,
  }
]]))()
