package.path = './?.lua;' .. package.path

local nm_data = require('wiki_nms')
local seen = {}
local count = 0

for _, names in pairs(nm_data.names) do
    for _, name in ipairs(names) do
        local levels = nm_data.levels[name]
        assert(levels, ('missing level range for %s'):format(name))
        assert(levels:match('^%d+%-?%d*$'), ('invalid level range for %s: %s'):format(name, levels))
        if not seen[name] then
            seen[name] = true
            count = count + 1
        end
    end
end

assert(count == 435, ('expected 435 unique zone NMs, got %d'):format(count))
assert(nm_data.levels['Jaggedy-Eared Jack'] == '9-10')
assert(nm_data.levels['Absolute Virtue'] == '92')
assert(nm_data.levels["Ix'aern (MNK)"] == '80-87')

print('NM level data regression test passed')
