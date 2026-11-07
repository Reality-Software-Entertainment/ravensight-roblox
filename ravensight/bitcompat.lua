-- ravensight/bitcompat.lua: the few 32-bit operations the SDK needs, over
-- whichever bit library the runtime has.
--
-- Roblox runs Luau, which has `bit32` (results are unsigned). The specs run
-- under LuaJIT, which has `bit` (results are signed). The SHA-256 and the
-- FNV-1a hash only combine results with other bit operations, additions
-- and byte extraction, so either sign works, as long as `tobit` wraps a
-- sum back into 32 bits.
--
-- MIT licensed, part of ravensight-roblox.

local bit32lib = rawget(_G, 'bit32') or bit32
if bit32lib then
  return {
    band = bit32lib.band,
    bor = bit32lib.bor,
    bxor = bit32lib.bxor,
    bnot = bit32lib.bnot,
    rshift = bit32lib.rshift,
    lshift = bit32lib.lshift,
    ror = bit32lib.rrotate,
    tobit = function(x) return bit32lib.band(x, 0xffffffff) end,
  }
end

local BIT_MODULE = 'bit'
local bit = rawget(_G, 'bit') or require(BIT_MODULE)
return {
  band = bit.band, bor = bit.bor, bxor = bit.bxor, bnot = bit.bnot,
  rshift = bit.rshift, lshift = bit.lshift, ror = bit.ror, tobit = bit.tobit,
}
