package.path = './?.lua;' .. package.path

local tracker_module = require('placeholder_tracker')
local storage = {zones = {}}
local saves = 0
local tracker = tracker_module.new(storage, function() saves = saves + 1 end,
    {follow_window = 900})

tracker:record_scan(100, {}, {{nm = 'Fungus Beetle', index = 0x0D2}}, 100)
tracker:record_scan(100, {}, {{nm = 'Fungus Beetle', index = 0x0D2}}, 110)
local d2 = tracker:stats(100, 'Fungus Beetle')[1]
assert(d2.sightings == 2, 'consecutive scans should count sightings')
assert(d2.encounters == 1, 'same living candidate should be one encounter')

tracker:record_scan(100, {}, {{nm = 'Fungus Beetle', index = 0x0D3}}, 120)
assert(#tracker:stats(100, 'Fungus Beetle') == 2, 'new candidate ID was not retained')
assert(tracker:mark_killed(100, 'Fungus Beetle', 0x0D3, 130), 'active kill not recorded')
assert(not tracker:mark_killed(100, 'Fungus Beetle', 0x0D3, 131), 'corpse counted twice')

tracker:record_scan(100, {['Fungus Beetle'] = true}, {}, 140)
local stats = tracker:stats(100, 'Fungus Beetle')
local by_index = {}
for _, entry in ipairs(stats) do by_index[entry.index] = entry end
assert(by_index[0x0D3].kills == 1, 'candidate kill count missing')
assert(by_index[0x0D3].nm_followed == 1, 'NM-followed outcome missing')

tracker:record_scan(100, {}, {{nm = 'Fungus Beetle', index = 0x0D3}}, 150)
assert(by_index[0x0D3].encounters == 2, 'post-kill respawn was not a new encounter')
assert(tracker:mark_killed(100, 'Fungus Beetle', 0x0D3, 160), 'second kill missing')
tracker:record_scan(100, {}, {{nm = 'Fungus Beetle', index = 0x0D2}}, 170)
assert(by_index[0x0D3].placeholder_returned == 1, 'placeholder-returned outcome missing')

assert(tracker:compact(100, 'Fungus Beetle'):find('0x0D3 2x', 1, true),
    'compact summary missing encounter count')
assert(tracker:encounters(100, 'Fungus Beetle', 0x0D3) == 2,
    'current candidate encounter lookup failed')
assert(saves == 8, 'unexpected persistence count: ' .. tostring(saves))

tracker:reset_session()
tracker:record_scan(100, {}, {{nm = 'Fungus Beetle', index = 0x0D2}}, 180)
assert(by_index[0x0D2].encounters == 3, 'new zone session was not a new encounter')
assert(tracker:mark_killed(100, 'Fungus Beetle', 0x0D2, 181), 'expiry test kill missing')
local followed = by_index[0x0D2].nm_followed
tracker:record_scan(100, {['Fungus Beetle'] = true}, {}, 1082)
assert(by_index[0x0D2].nm_followed == followed, 'expired kill was correlated to a later NM')

assert(tracker:reset_stats(100, 'Fungus Beetle'), 'NM reset failed')
assert(#tracker:stats(100, 'Fungus Beetle') == 0, 'NM reset retained observations')

local reloaded = {zones = {z100 = {fungus_beetle = {
    name = 'Fungus Beetle',
    ids = {i0d2 = {index = 0x0D2, sightings = 4, encounters = 2}},
}}}}
local after_reload = tracker_module.new(reloaded)
after_reload:record_scan(100, {}, {{nm = 'Fungus Beetle', index = 0x0D2}}, 200)
assert(reloaded.zones.z100.fungus_beetle.ids.i0d2.sightings == 5,
    'lowercased XML key was not reused after reload')
local id_count = 0
for _ in pairs(reloaded.zones.z100.fungus_beetle.ids) do id_count = id_count + 1 end
assert(id_count == 1, 'reload created a duplicate candidate ID key')

print('placeholder tracker regression test passed')
