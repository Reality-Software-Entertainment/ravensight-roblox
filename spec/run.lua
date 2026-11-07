-- A dependency-free test runner, from the repo root:
--   luajit spec/run.lua           LuaJIT's `bit`
--   luajit spec/run.lua bit32     Luau's `bit32` semantics (the Roblox path)
--   lua spec/run.lua bit32        PUC Lua 5.3 or later, stricter numbers
-- Each spec file returns a list of {name, fn}; a failing assert fails the
-- test, and the process exits non-zero if any test failed.

package.path = './?.lua;./?/init.lua;./spec/?.lua;' .. package.path

if arg and arg[1] == 'bit32' then
  _G.bit32 = dofile('spec/bit32_shim.lua')
end

local files = {
  'spec/json_spec.lua', 'spec/scrub_spec.lua', 'spec/config_spec.lua', 'spec/typed_spec.lua',
  'spec/core_spec.lua', 'spec/wave_spec.lua', 'spec/contract_spec.lua',
  'spec/roblox_spec.lua',
}
local passed, failed = 0, 0

for _, file in ipairs(files) do
  local tests = dofile(file)
  for _, t in ipairs(tests) do
    local ok, err = xpcall(t[2], debug.traceback)
    if ok then
      passed = passed + 1
    else
      failed = failed + 1
      print('FAIL ' .. file .. ': ' .. t[1] .. '\n  ' .. tostring(err):gsub('\n', '\n  '))
    end
  end
end

print(string.format('%s: %d passed, %d failed', (_G.bit32 and 'bit32' or 'bit'), passed, failed))
os.exit(failed == 0 and 0 or 1)
