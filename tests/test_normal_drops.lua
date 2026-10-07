package.path = './?.lua;' .. package.path

local normal_drops = require('normal_drops')
local count = 0
local condition_count = 0

for zone, entries in pairs(normal_drops) do
    assert(type(zone) == 'string' and zone == zone:lower(), 'zone key must be lowercase')
    assert(type(entries) == 'table' and #entries > 0, 'zone must have drop entries')
    for _, entry in ipairs(entries) do
        assert(type(entry.levels) == 'string' and entry.levels ~= '', 'missing level range')
        assert(type(entry.mob) == 'string' and entry.mob ~= '', 'missing monster name')
        assert(type(entry.drops) == 'string' and entry.drops ~= '', 'missing equipment drop')
        if entry.condition then
            assert(type(entry.condition) == 'string' and entry.condition ~= '',
                'invalid spawn condition')
            condition_count = condition_count + 1
        end
        count = count + 1
    end
end

assert(count == 52, 'unexpected normal drop entry count: ' .. tostring(count))
assert(condition_count == 8, 'unexpected spawn condition count: ' .. tostring(condition_count))
assert(normal_drops['north gustaberg'][1].mob == 'Young Quadav',
    'regional Young Quadav row was not expanded')
assert(normal_drops['fort ghelsba'][1].mob == 'Orcish Fodder',
    'regional Orcish Fodder row was not expanded')

print('normal drop data regression test passed')
