-- The binding scrub cases (docs/errors/scrub-vectors.json on the server).
local Scrub = require('ravensight.scrub')
local json = require('ravensight.json')

local f = assert(io.open('spec/scrub-vectors.json', 'rb'))
local vectors = json.decode(f:read('*a'))
f:close()

local tests = {}
for _, case in ipairs(vectors.cases) do
  tests[#tests + 1] = { 'scrub vector: ' .. case.name, function()
    local out = Scrub.scrub(case['in'])
    assert(out == case.out, 'expected ' .. case.out .. ', got ' .. out)
  end }
end
tests[#tests + 1] = { 'scrub is idempotent on every vector', function()
  for _, case in ipairs(vectors.cases) do
    assert(Scrub.scrub(case.out) == case.out, case.name)
  end
end }
tests[#tests + 1] = { 'scrub leaves non-strings and empty text alone', function()
  assert(Scrub.scrub(nil) == nil and Scrub.scrub(5) == 5 and Scrub.scrub('') == '')
end }
return tests
