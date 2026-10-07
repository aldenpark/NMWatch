local M = {}
local Tracker = {}
Tracker.__index = Tracker

local DEFAULT_FOLLOW_WINDOW = 15 * 60

-- Persistent layout:
-- zones.z100.fungus_beetle.ids.i0d2 = {
--     index, sightings, encounters, kills, nm_followed,
--     placeholder_returned, first_seen, last_seen
-- }
-- XML-safe keys keep the file readable while the original NM name and numeric
-- index remain in values for display and sorting.

local function zone_key(zone_id)
    return 'z' .. tostring(zone_id)
end

local function nm_key(name)
    return name:lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
end

local function index_key(index)
    -- Windower's XML loader lowercases tag names, so persisted table keys must
    -- also be lowercase or a reload would create a duplicate for the same ID.
    return ('i%03x'):format(index)
end

local function runtime_key(zone_id, name)
    return tostring(zone_id) .. '\0' .. name:lower()
end

local function number(value)
    return tonumber(value) or 0
end

function M.new(data, save_callback, options)
    data = data or {}
    data.zones = data.zones or {}
    return setmetatable({
        data = data,
        save_callback = save_callback,
        follow_window = options and options.follow_window or DEFAULT_FOLLOW_WINDOW,
        -- Runtime state is deliberately not persisted. Reloading or returning
        -- to a zone begins a new encounter rather than assuming the old mob is
        -- still the same live spawn.
        active = {},
        pending = {},
    }, Tracker)
end

function Tracker:_save()
    if self.save_callback then self.save_callback(self.data) end
end

function Tracker:_nm(zone_id, name, create)
    local zones = self.data.zones
    local zkey = zone_key(zone_id)
    local zone = zones[zkey]
    if not zone and create then
        zone = {}
        zones[zkey] = zone
    end
    if not zone then return nil end

    local key = nm_key(name)
    local nm = zone[key]
    if not nm and create then
        nm = {name = name, ids = {}}
        zone[key] = nm
    end
    if nm then
        nm.name = nm.name or name
        nm.ids = nm.ids or {}
    end
    return nm
end

function Tracker:_entry(zone_id, name, index, create)
    local nm = self:_nm(zone_id, name, create)
    if not nm then return nil end
    local key = index_key(index)
    local entry = nm.ids[key]
    if not entry and create then
        entry = {
            index = index,
            sightings = 0,
            encounters = 0,
            kills = 0,
            nm_followed = 0,
            placeholder_returned = 0,
            first_seen = 0,
            last_seen = 0,
        }
        nm.ids[key] = entry
    end
    return entry
end

function Tracker:_valid_pending(key, now)
    local pending = self.pending[key]
    -- Do not attribute an unrelated NM seen much later to an old candidate
    -- death. Candidate and NM observations both pass through this check.
    if pending and now - pending.time > self.follow_window then
        self.pending[key] = nil
        pending = nil
    end
    return pending
end

function Tracker:_record_nm(zone_id, name, now)
    local key = runtime_key(zone_id, name)
    local pending = self:_valid_pending(key, now)
    if not pending then return false end

    local entry = self:_entry(zone_id, name, pending.index, true)
    entry.nm_followed = number(entry.nm_followed) + 1
    self.pending[key] = nil
    return true
end

function Tracker:_observe(zone_id, name, index, now)
    local key = runtime_key(zone_id, name)
    local pending = self:_valid_pending(key, now)
    if pending then
        local killed = self:_entry(zone_id, name, pending.index, true)
        killed.placeholder_returned = number(killed.placeholder_returned) + 1
        self.pending[key] = nil
    end

    local entry = self:_entry(zone_id, name, index, true)
    -- Every completed scan is a sighting. Encounters are the lower-noise count:
    -- first observation, changed ID, new session, or reappearance after death.
    entry.sightings = number(entry.sightings) + 1
    entry.first_seen = number(entry.first_seen) > 0 and number(entry.first_seen) or now
    entry.last_seen = now

    local active = self.active[key]
    if not active or active.index ~= index or active.killed then
        entry.encounters = number(entry.encounters) + 1
    end
    self.active[key] = {index = index, killed = false}
end

-- Record one completed widescan as a single transaction. Actual NMs are
-- processed first so a scan containing both an NM and another candidate does
-- not incorrectly classify the candidate as the post-kill replacement.
function Tracker:record_scan(zone_id, actual_nms, candidates, now)
    now = now or os.time()
    local changed = false
    for name in pairs(actual_nms or {}) do
        changed = self:_record_nm(zone_id, name, now) or changed
    end
    for _, candidate in ipairs(candidates or {}) do
        self:_observe(zone_id, candidate.nm, candidate.index, now)
        changed = true
    end
    if changed then self:_save() end
end

-- Kills are counted only when the candidate is the currently active encounter.
-- Repeated mob-array scans of the same corpse therefore cannot inflate totals.
function Tracker:mark_killed(zone_id, name, index, now)
    now = now or os.time()
    local key = runtime_key(zone_id, name)
    local active = self.active[key]
    if not active or active.index ~= index or active.killed then return false end

    local entry = self:_entry(zone_id, name, index, true)
    entry.kills = number(entry.kills) + 1
    entry.last_seen = math.max(number(entry.last_seen), now)
    active.killed = true
    self.pending[key] = {index = index, time = now}
    self:_save()
    return true
end

function Tracker:reset_session()
    self.active = {}
    self.pending = {}
end

function Tracker:reset_stats(zone_id, name)
    if name == 'all' then
        -- "all" is intentionally global, matching the explicit command text;
        -- an NM-name reset below affects only the current zone.
        self.data.zones = {}
        self:reset_session()
        self:_save()
        return true
    end

    local zone = self.data.zones[zone_key(zone_id)]
    local key = name and nm_key(name)
    if not zone or not key or not zone[key] then return false end
    zone[key] = nil
    self.active[runtime_key(zone_id, name)] = nil
    self.pending[runtime_key(zone_id, name)] = nil
    self:_save()
    return true
end

function Tracker:stats(zone_id, name)
    local nm = self:_nm(zone_id, name, false)
    local result = {}
    if not nm then return result end
    for _, entry in pairs(nm.ids) do
        table.insert(result, entry)
    end
    table.sort(result, function(a, b)
        local a_encounters, b_encounters = number(a.encounters), number(b.encounters)
        if a_encounters ~= b_encounters then return a_encounters > b_encounters end
        return number(a.index) < number(b.index)
    end)
    return result
end

function Tracker:zone_stats(zone_id)
    local zone = self.data.zones[zone_key(zone_id)] or {}
    local result = {}
    for _, nm in pairs(zone) do
        local ids = self:stats(zone_id, nm.name)
        local encounters = 0
        for _, entry in ipairs(ids) do encounters = encounters + number(entry.encounters) end
        table.insert(result, {name = nm.name, ids = ids, encounters = encounters})
    end
    table.sort(result, function(a, b) return a.name:lower() < b.name:lower() end)
    return result
end

function Tracker:compact(zone_id, name, limit)
    local stats = self:stats(zone_id, name)
    if #stats == 0 then return nil end
    limit = limit or 3
    local parts = {}
    for i = 1, math.min(#stats, limit) do
        table.insert(parts, ('0x%03X %dx'):format(
            number(stats[i].index), number(stats[i].encounters)))
    end
    if #stats > limit then table.insert(parts, '+' .. tostring(#stats - limit)) end
    return table.concat(parts, ', ')
end

function Tracker:encounters(zone_id, name, index)
    local entry = self:_entry(zone_id, name, index, false)
    return entry and number(entry.encounters) or 0
end

return M
