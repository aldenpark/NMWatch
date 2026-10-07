_addon.name = 'NMWatch'
_addon.version = '1.12.0'
_addon.author = 'Alden Park'
_addon.commands = {'nmw', 'nmwatch'}

require('logger')
local config = require('config')
local packets = require('packets')
local res = require('resources')
local texts = require('texts')
local nm_data = require('wiki_nms')
local roe_nms = require('roe_nms')
local placeholder_tracker_module = require('placeholder_tracker')

local defaults = {
    enabled = false,
    wiki_fallback = true,
    wiki_links = true,
    range = 50,
    scan_interval = 1.0,
    sound = true,
    sound_file = '',
    chat_color = 200,
    custom_ids = {},
    hud = {
        visible = true,
        max_shown = 8,
        pos = {x = 10, y = 300},
        bg = {red = 0, green = 0, blue = 0, alpha = 0, visible = true},
        text = {font = 'Consolas', size = 11, red = 255, green = 255, blue = 255, alpha = 255},
        flags = {draggable = true, bold = false, italic = false},
        padding = 4,
    },
}

local settings = config.load(defaults)
local placeholder_observations = config.load('data/placeholder_observations.xml', {zones = {}})
local placeholder_tracker = placeholder_tracker_module.new(
    placeholder_observations,
    function(data) config.save(data, 'all') end)
local hud = texts.new('', settings.hud, settings)
-- NM rows handle clicks themselves so the header can remain the drag handle.
hud:draggable(false)
local function icon_settings()
    return {
        pos = {x = settings.hud.pos.x, y = settings.hud.pos.y},
        bg = {red = 0, green = 0, blue = 0, alpha = 0, visible = false},
        text = {font = settings.hud.text.font, size = settings.hud.text.size,
            red = 255, green = 255, blue = 255, alpha = settings.hud.text.alpha},
        flags = {draggable = false, bold = true, italic = false},
        padding = settings.hud.padding,
    }
end
local active_icons = texts.new('', icon_settings())
local inactive_icons = texts.new('', icon_settings())
local link_settings = icon_settings()
link_settings.flags.bold = settings.hud.flags.bold
link_settings.flags.italic = settings.hud.flags.italic
local link_text = texts.new('', link_settings)
local drop_text = texts.new('', link_settings)
local zone_text = texts.new('', link_settings)
local target_text = texts.new('', link_settings)
local alert_text = texts.new('', link_settings)
active_icons:color(80, 255, 80)
inactive_icons:color(255, 80, 80)
link_text:color(100, 200, 255)
drop_text:color(255, 210, 80)
zone_text:color(255, 80, 255)
target_text:color(210, 150, 255)
alert_text:color(255, 80, 80)
local seen = {}
local active = {}
local recent = {}
local last_seen = {}
local last_scan = 0
local last_hud_update = 0
local alert_until = 0
local alert_mob_ids = {}
local alert_mob_names = {}
local wiki_cache = {}
local active_roe = {}
local completed_roe = {}
local hud_link_rows = {}
local hud_target_rows = {}
local hud_line_count = 0
local widescan_first_line
local widescan_last_line
local hud_drag = nil
local pending_link = nil
local pending_target = nil
local pending_widescan_clear

-- Keep the last useful widescan visible until a new nonempty scan replaces it.
-- A scan is ordered data: duplicate numbering and placeholder rules both depend
-- on preserving the exact packet order in widescan_entries.
local widescan_entries = {}
local widescan_counts = {}
-- FFXI can natively track only one widescan row, even though NMWatch may mark
-- several NMs and placeholders from the same scan.
local widescan_track
-- Start/reset packets arrive before mob rows. Deferring the clear until the
-- first mob preserves the old list when a scan returns no results.
local widescan_scan_pending = false
local annotate_widescan
local zone_info
local chat

local function clear_widescan()
    -- Centralize every piece of scan and HUD interaction state so zone changes,
    -- explicit clears, and nonempty replacement scans cannot leave stale rows.
    widescan_entries = {}
    widescan_counts = {}
    widescan_track = nil
    widescan_scan_pending = false
    widescan_first_line = nil
    widescan_last_line = nil
    pending_widescan_clear = nil
end

local wiki_page_overrides = {
    ['Bloodsucker'] = 'Bloodsucker (Notorious Monster)',
    ['Cerberus'] = 'Cerberus (Notorious Monster)',
    ['Giant Orobon'] = 'Giant Orobon (Fished)',
    ['Golden-Tongued Culberry'] = 'Golden-tongued Culberry',
    ['Hydra'] = 'Hydra (Notorious Monster)',
    ['Ixtab'] = 'Ixtab (Monster)',
    ['Orobon'] = 'Orobon (Notorious Monster)',
}

local function url_encode(value)
    return value:gsub('([^%w%-._~])', function(char)
        return ('%%%02X'):format(char:byte())
    end)
end

local function wiki_url(name)
    if name == 'Boll Weevil' then
        return 'https://www.bg-wiki.com/ffxi/Special:Search?search=Boll%20Weevil'
    end
    local title = wiki_page_overrides[name] or name
    return 'https://www.bg-wiki.com/ffxi/' .. url_encode(title:gsub(' ', '_'))
end

local function update_roe(data)
    local parsed = packets.parse('incoming', data)
    if not parsed then return end

    local current = {}
    for i = 1, 30 do
        local objective_id = parsed[('RoE Quest ID %d'):format(i)]
        if objective_id and objective_id > 0 then
            current[objective_id] = true
            local progress = parsed[('RoE Quest Progress %d'):format(i)]
            if progress and progress > 0 then completed_roe[objective_id] = true end
        end
    end
    active_roe = current
end

local function update_widescan_mob(data)
    local mob = packets.parse('incoming', data)
    if not mob or not mob.Name then return end
    local name = mob.Name:gsub('%z.*', '')
    if name == '' then return end
    if widescan_scan_pending then
        -- This is the first result of a new scan, so replacing the old list is
        -- safe. An empty scan never reaches this branch and retains old data.
        clear_widescan()
    end
    widescan_counts[name] = (widescan_counts[name] or 0) + 1
    table.insert(widescan_entries, {
        name = name,
        index = mob.Index,
        number = widescan_counts[name],
        x_offset = mob['X Offset'],
        y_offset = mob['Y Offset'],
    })
    local normalized_name = name:lower():gsub('%s+', '')
    local zone_id, zone_name = zone_info()
    local zone_nms = nm_data.names[zone_name:lower()] or {}
    for _, nm_name in ipairs(zone_nms) do
        if normalized_name == nm_name:lower():gsub('%s+', '') then
            local entry = widescan_entries[#widescan_entries]
            entry.placeholder_for = nil
            entry.tracked_nm = nm_name
            break
        end
    end
end

annotate_widescan = function()
    local zone_id = zone_info()
    widescan_track = nil
    -- Rules describe positions in the native widescan list, not physical
    -- distance between mobs. Record each entry's absolute list position once.
    local scan_position = {}
    for position, entry in ipairs(widescan_entries) do
        scan_position[entry] = position
    end
    local function anchor_position(anchor)
        if not anchor then return nil end
        local positions = {}
        local anchor_name = anchor.name:lower():gsub('%s+', '')
        for position, entry in ipairs(widescan_entries) do
            if entry.name:lower():gsub('%s+', '') == anchor_name then
                table.insert(positions, position)
            end
        end
        local occurrence = anchor.occurrence
        if occurrence == 'first' then occurrence = 1 end
        if occurrence == 'last' then occurrence = #positions end
        return positions[occurrence or 1]
    end
    for _, entry in ipairs(widescan_entries) do
        entry.placeholder_for = nil
        entry.area = nil
    end
    local rules = nm_data.widescan_placeholders[zone_id] or {}
    for _, rule in ipairs(rules) do
        local candidates = {}
        local after_position = anchor_position(rule.after)
        local before_position = anchor_position(rule.before)
        local anchors_ready = (not rule.after or after_position)
            and (not rule.before or before_position)
        for _, entry in ipairs(widescan_entries) do
            local position = scan_position[entry]
            if anchors_ready
                and entry.name:lower():gsub('%s+', '') == rule.placeholder_name:lower():gsub('%s+', '')
                and (not after_position or position > after_position)
                and (not before_position or position < before_position) then
                table.insert(candidates, entry)
            end
        end
        local groups = {}
        if rule.scope == 'scan' then
            -- Scan-scoped rules count every matching name between optional
            -- anchor rows, even when other mob names appear between matches.
            table.insert(groups, {entries = candidates})
        else
            -- Group rules split only when another widescan row interrupts the
            -- matching names. Map offsets are intentionally not used here.
            local group
            for _, entry in ipairs(candidates) do
                local previous = group and group.entries[#group.entries]
                local consecutive = previous
                    and scan_position[entry] == scan_position[previous] + 1
                if not consecutive then
                    group = {entries = {}}
                    table.insert(groups, group)
                end
                table.insert(group.entries, entry)
                entry.group = #groups
            end
        end
        for group_number, group in ipairs(groups) do
            local wanted_occurrence = rule.occurrence
            if wanted_occurrence == 'first' then wanted_occurrence = 1 end
            if wanted_occurrence == 'last' then wanted_occurrence = #group.entries end
            for occurrence, entry in ipairs(group.entries) do
                -- "Group of N" is exact. Treating N as a minimum can select a
                -- similarly named mob from a different widescan grouping.
                if occurrence == wanted_occurrence
                    and (not rule.group_occurrence or group_number == rule.group_occurrence)
                    and (not rule.group_size or #group.entries == rule.group_size)
                    and #group.entries >= wanted_occurrence then
                    entry.placeholder_for = rule.nm
                    entry.area = rule.area
                end
            end
        end
    end

    -- Persist one observation per completed scan. Process actual NMs before
    -- candidates so post-kill correlation records the stronger NM outcome.
    local actual_nms = {}
    local candidates = {}
    for _, entry in ipairs(widescan_entries) do
        if entry.tracked_nm then actual_nms[entry.tracked_nm] = true end
        if entry.placeholder_for and entry.index then
            table.insert(candidates, {nm = entry.placeholder_for, index = entry.index})
        end
    end
    placeholder_tracker:record_scan(zone_id, actual_nms, candidates, os.time())

    -- Prefer an actual NM for the game's one native tracking slot. Every other
    -- marked row remains available to the HUD and nearby scanner below.
    for _, entry in ipairs(widescan_entries) do
        if entry.tracked_nm then
            widescan_track = entry
            break
        end
    end
    if not widescan_track then
        for _, entry in ipairs(widescan_entries) do
            if entry.placeholder_for then
                widescan_track = entry
                break
            end
        end
    end
    if widescan_track and windower.ffxi.wide_scan_track_index then
        windower.ffxi.wide_scan_track_index(widescan_track.index)
        if chat then
            local label = widescan_track.tracked_nm
                or (widescan_track.placeholder_for .. ' placeholder')
            chat(('tracking %s at widescan index 0x%03X'):format(
                label, widescan_track.index or 0))
        end
    end
end

local function update_widescan_track(data)
    local track = packets.parse('incoming', data)
    if track and (track.Status == 2 or track.Status == 'Reset (zone)') then
        -- The Windower zone-change event owns clearing. Packet reset alone can
        -- also occur while useful results should remain displayed.
        return
    end
    if track and (track.Status == 3 or track.Status == 'Reset (new scan)') then
        -- Do not clear yet: the new scan may be empty.
        widescan_scan_pending = true
        return
    end
    if track and widescan_track and track.Index == widescan_track.index then
        widescan_track.x, widescan_track.y, widescan_track.z = track.X, track.Y, track.Z
    end
end

local function update_widescan_mark(data)
    local mark = packets.parse('incoming', data)
    if not mark then return end
    if mark.Type == 1 or mark.Type == 'Start' then
        widescan_scan_pending = true
    elseif mark.Type == 2 or mark.Type == 'End' then
        -- The first mob clears pending while replacing the list. If pending is
        -- still true, this was an empty scan and the previous annotations stay.
        if not widescan_scan_pending then annotate_widescan() end
        widescan_scan_pending = false
    end
end

chat = function(message)
    windower.add_to_chat(settings.chat_color, '[NMW] ' .. message)
end

zone_info = function()
    local info = windower.ffxi.get_info()
    local zone_id = info and info.zone
    local zone = zone_id and res.zones[zone_id]
    return zone_id, zone and zone.english or 'Unknown'
end

local function zone_key(zone_id)
    return 'z' .. tostring(zone_id)
end

local function index_key(index)
    -- Config XML tag names are normalized to lowercase on reload.
    return ('i%03x'):format(index)
end

local function wiki_names(zone_name)
    local key = zone_name:lower()
    if wiki_cache[key] then
        return wiki_cache[key]
    end

    local names = {}
    for _, name in ipairs(nm_data.names[key] or {}) do
        names[name:lower()] = name
    end
    wiki_cache[key] = names
    return names
end

local function custom_name(zone_id, index)
    local zone_ids = settings.custom_ids[zone_key(zone_id)]
    return zone_ids and zone_ids[index_key(index)] or nil
end

local function match_source(name, source)
    local pop_type = nm_data.spawn_types[name]
    return pop_type and (source .. ', ' .. pop_type) or source
end

local function relative_direction(player, mob)
    local dx = (mob.x or 0) - (player.x or 0)
    local dy = (mob.y or 0) - (player.y or 0)
    local direction = ''
    if math.abs(dy) >= 1 then direction = direction .. (dy > 0 and 'N' or 'S') end
    if math.abs(dx) >= 1 then direction = direction .. (dx > 0 and 'E' or 'W') end
    return direction ~= '' and direction or 'here'
end

local function matched_widescan_entry(index)
    -- Native tracking exposes coordinates for one row, but nearby matching must
    -- recognize every NM and placeholder identified in the captured scan.
    for _, entry in ipairs(widescan_entries) do
        if entry.index == index and (entry.tracked_nm or entry.placeholder_for) then
            return entry
        end
    end
end

local function match_mob(mob, zone_id, zone_name)
    local widescan_entry = matched_widescan_entry(mob.index)
    if widescan_entry then
        if widescan_entry.tracked_nm then
            return widescan_entry.tracked_nm,
                match_source(widescan_entry.tracked_nm, 'widescan NM')
        end
        if widescan_entry.placeholder_for then
            return widescan_entry.placeholder_for,
                match_source(widescan_entry.placeholder_for, 'widescan placeholder')
        end
    end
    local exact_name = custom_name(zone_id, mob.index)
    if exact_name then
        return exact_name, match_source(exact_name, 'custom ID')
    end

    local bundled_ids = nm_data.ids[zone_id]
    local bundled_name = bundled_ids and bundled_ids[mob.index]
    if bundled_name then
        return bundled_name, match_source(bundled_name, 'wiki ID')
    end

    local placeholder_ids = nm_data.placeholder_ids[zone_id]
    local placeholder_name = placeholder_ids and placeholder_ids[mob.index]
    if placeholder_name then
        return placeholder_name, match_source(placeholder_name, 'placeholder ID')
    end

    if settings.wiki_fallback and mob.name then
        local wiki_name = wiki_names(zone_name)[mob.name:lower()]
        if wiki_name then
            return wiki_name, nm_data.spawn_types[wiki_name] or 'wiki'
        end
    end

    if mob.name then
        for _, entry in ipairs(nm_data.normal_drops[zone_name:lower()] or {}) do
            if mob.name:lower() == entry.mob:lower() then
                return entry.mob, 'normal equipment drop', 'normal'
            end
        end
    end
end

local function notify(match)
    local label = match.category == 'normal' and 'DROP MOB' or 'NM'
    chat(('>>> %s FOUND: %s [0x%03X, %s] <<<')
        :format(label, match.name, match.index, match.source))
    if settings.sound and settings.sound_file ~= '' then
        windower.play_sound(settings.sound_file)
    end
    alert_until = os.clock() + 5
    alert_mob_ids[match.id] = true
    alert_mob_names[match.id] = match.name
    table.insert(recent, 1, match)
    while #recent > settings.hud.max_shown do
        table.remove(recent)
    end
end

local function scan()
    local info = windower.ffxi.get_info()
    if not info or not info.logged_in then return end

    local player = windower.ffxi.get_mob_by_target('me')
    local mobs = windower.ffxi.get_mob_array()
    if not player or not mobs then return end

    local zone_id, zone_name = zone_info()
    local range_sq = settings.range * settings.range
    local found = {}
    local announced_normal = {}

    for _, mob in pairs(mobs) do
        if mob and mob.id and mob.id > 0 and mob.index and mob.hpp and mob.hpp <= 0 then
            local widescan_entry = matched_widescan_entry(mob.index)
            if widescan_entry and widescan_entry.placeholder_for then
                placeholder_tracker:mark_killed(
                    zone_id, widescan_entry.placeholder_for, mob.index, os.time())
            end
            local defeated_name = match_mob(mob, zone_id, zone_name)
            if defeated_name and last_seen[zone_name:lower()] then
                last_seen[zone_name:lower()][defeated_name] = nil
            end
        end
        local known_placeholder = nm_data.placeholder_ids[zone_id]
            and nm_data.placeholder_ids[zone_id][mob and mob.index]
        -- A widescan-derived placeholder can have a normal mob spawn type and
        -- no fixed placeholder ID, so its captured index must opt it into scan().
        local tracked_widescan = mob and matched_widescan_entry(mob.index)
        if mob and mob.id and mob.id > 0 and mob.index
            and (mob.spawn_type == 16 or known_placeholder or tracked_widescan)
            and mob.hpp and mob.hpp > 0
        then
            local dx = (mob.x or 0) - (player.x or 0)
            local dy = (mob.y or 0) - (player.y or 0)
            local dz = (mob.z or 0) - (player.z or 0)
            local distance_sq = dx * dx + dy * dy + dz * dz
            if distance_sq <= range_sq then
                local name, source, category = match_mob(mob, zone_id, zone_name)
                if name then
                    local match = {
                        id = mob.id,
                        index = mob.index,
                        name = mob.name or name,
                        source = source,
                        category = category,
                        distance = math.sqrt(distance_sq),
                        x = mob.x, y = mob.y, z = mob.z,
                    }
                    found[mob.id] = match
                    last_seen[zone_name:lower()] = last_seen[zone_name:lower()] or {}
                    last_seen[zone_name:lower()][name] = {
                        time = os.time(), x = mob.x, y = mob.y, z = mob.z,
                    }
                    if not seen[mob.id] then
                        local normal_key = category == 'normal' and name:lower()
                        if normal_key and announced_normal[normal_key] then
                            -- Track every instance without replaying the same
                            -- alert repeatedly in one scan.
                            alert_mob_ids[match.id] = true
                            alert_mob_names[match.id] = match.name
                        else
                            notify(match)
                            if normal_key then announced_normal[normal_key] = true end
                        end
                    end
                end
            end
        end
    end

    active = found
    seen = found
    for mob_id in pairs(alert_mob_ids) do
        if not found[mob_id] then
            alert_mob_ids[mob_id] = nil
            local name = alert_mob_names[mob_id]
            if name and last_seen[zone_name:lower()] then last_seen[zone_name:lower()][name] = nil end
            alert_mob_names[mob_id] = nil
        end
    end
    if next(alert_mob_ids) == nil then
        alert_until = 0
    end
end

local function current_zone_id_count()
    local zone_id = zone_info()
    local ids = settings.custom_ids[zone_key(zone_id)] or {}
    local count = 0
    for _ in pairs(ids) do count = count + 1 end
    return count
end

local function append_wrapped(lines, prefix, value, continuation_prefix)
    continuation_prefix = continuation_prefix or prefix
    local current_prefix = prefix
    local line = prefix
    for word in value:gmatch('%S+') do
        if #line > #current_prefix and #line + #word + 1 > 76 then
            table.insert(lines, line)
            current_prefix = continuation_prefix
            line = current_prefix .. word
        else
            line = line .. (#line > #current_prefix and ' ' or '') .. word
        end
    end
    table.insert(lines, line)
end

local function selected_target()
    return windower.ffxi.get_mob_by_target('st') or windower.ffxi.get_mob_by_target('t')
end

local function target_nearby_mob(entry)
    local player = windower.ffxi.get_mob_by_target('me')
    local mob = windower.ffxi.get_mob_by_index(entry.index)
    if not player or not mob or mob.id ~= entry.id or (mob.hpp or 0) <= 0
        or mob.valid_target == false
    then
        chat(entry.name .. ' is no longer available to target')
        return
    end

    local ok = pcall(function()
        packets.inject(packets.new('incoming', 0x058, {
            ['Player'] = player.id,
            ['Target'] = mob.id,
            ['Player Index'] = player.index,
        }))
    end)
    if not ok then chat('could not target ' .. entry.name) end
end

local function update_hud()
    if not settings.hud.visible then
        hud:hide()
        active_icons:hide()
        inactive_icons:hide()
        link_text:hide()
        drop_text:hide()
        zone_text:hide()
        target_text:hide()
        alert_text:hide()
        return
    end

    local zone_id, zone_name = zone_info()
    local zone_nms = nm_data.names[zone_name:lower()] or {}
    local zone_details = nm_data.spawn_details[zone_name:lower()] or {}
    local zone_drops = nm_data.drops[zone_name:lower()] or {}
    local zone_normal_drops = nm_data.normal_drops[zone_name:lower()] or {}
    local player = windower.ffxi.get_mob_by_target('me')
    local active_list = {}
    for _, match in pairs(active) do table.insert(active_list, match) end
    table.sort(active_list, function(a, b) return a.distance < b.distance end)

    local state = settings.enabled and '[ON]' or '[OFF]'
    local active_marker_lines = {}
    local inactive_marker_lines = {}
    local link_lines = {}
    local drop_lines = {}
    local zone_lines = {}
    local target_lines = {}
    local alert_lines = {}
    hud_link_rows = {}
    hud_target_rows = {}
    widescan_first_line = nil
    widescan_last_line = nil
    local lines = {
        ('%-42s%s'):format(('NMWatch %s  range=%dy'):format(state, settings.range), string.rep(' ', #zone_name)),
    }
    zone_lines[1] = zone_name

    local target = selected_target()
    local target_name
    local target_category
    if target and target.id and target.id > 0 then
        local target_source
        target_name, target_source, target_category = match_mob(target, zone_id, zone_name)
        if not target_name then
            for _, match in pairs(active) do
                if match.id == target.id then
                    target_name = match.name
                    target_category = match.category
                    break
                end
            end
        end
        local target_line = ('Target: %s | Hex ID=0x%03X | ID=%u'):format(
            target.name or 'Unknown', target.index or 0, target.id)
        table.insert(lines, target_line)
        target_lines[2] = target_line
        if target_name then target_text:color(80, 255, 120) else target_text:color(210, 150, 255) end
    end

    if #active_list > 0 then
        table.insert(lines, ('Nearby (%d):'):format(#active_list))
    end
    if #active_list == 0 and target and target_name and target.x and player then
        local dx, dy, dz = target.x - player.x, target.y - player.y, (target.z or 0) - (player.z or 0)
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        table.insert(lines, 'Nearby (1):')
        local target_label = target_category == 'normal' and target_name .. ' [drop]' or target_name
        table.insert(lines, ('  %s [0x%03X] %.1fy %s (%.1f, %.1f, %.1f)'):format(
            target_label, target.index or 0, distance, relative_direction(player, target),
            target.x, target.y, target.z or 0))
    end
    for i = 1, math.min(#active_list, settings.hud.max_shown) do
        local match = active_list[i]
        local name = match.category == 'normal' and match.name .. ' [drop]' or match.name
        local nearby_line = ('  %s [0x%03X] %.1fy %s (%.1f, %.1f, %.1f)'):format(
            name, match.index, match.distance, relative_direction(player, match),
            match.x or 0, match.y or 0, match.z or 0)
        table.insert(lines, nearby_line)
        hud_target_rows[#lines] = {
            id = match.id, index = match.index, name = match.name,
        }
        if alert_mob_ids[match.id] or (match.source and match.source:find('placeholder ID', 1, true)) then
            alert_lines[#lines] = nearby_line
        end
    end
    for i = settings.hud.max_shown + 1, #active_list do
        local match = active_list[i]
        if match.category ~= 'normal'
            and (alert_mob_ids[match.id]
                or (match.source and match.source:find('placeholder ID', 1, true)))
        then
            local name = match.category == 'normal' and match.name .. ' [drop]' or match.name
            local nearby_line = ('  %s [0x%03X] %.1fy %s (%.1f, %.1f, %.1f)'):format(
                name, match.index, match.distance, relative_direction(player, match),
                match.x or 0, match.y or 0, match.z or 0)
            table.insert(lines, nearby_line)
            hud_target_rows[#lines] = {
                id = match.id, index = match.index, name = match.name,
            }
            alert_lines[#lines] = nearby_line
        end
    end
    if #active_list == 0 and #recent > 0 then
        table.insert(lines, 'Last: ' .. recent[1].name)
    end

    table.insert(lines, 'Zone NMs by lvl:')
    local longest_nm_name = 0
    for _, name in ipairs(zone_nms) do
        longest_nm_name = math.max(longest_nm_name, #name)
    end
    local zone_name_padding = math.ceil(longest_nm_name * 1.8) + 6
    for _, name in ipairs(zone_nms) do
        local row_line = #lines + 1
        local level_prefix = ('  [%s] '):format(nm_data.levels[name] or '?')
        local seen = last_seen[zone_name:lower()] and last_seen[zone_name:lower()][name]
        local seen_label = ''
        if seen and os.time() - seen.time <= 86400 then
            local distance = player and seen.x and seen.y and seen.z
                and math.sqrt((seen.x - player.x)^2 + (seen.y - player.y)^2 + (seen.z - player.z)^2)
            seen_label = ' | Last seen: ' .. os.date('%Y-%m-%d %H:%M:%S', seen.time)
            if distance then seen_label = seen_label .. (' | last spot: %.1fy'):format(distance) end
        end
        if settings.wiki_links then
            -- Spaces are narrower than glyphs in Windower's proportional font.
            -- Reserve one column based on the zone's longest name so every
            -- white suffix aligns and the column expands for longer names.
            table.insert(lines, level_prefix .. string.rep(' ', zone_name_padding)
                .. ('[%s]%s'):format(nm_data.spawn_types[name] or 'unknown', seen_label))
            link_lines[row_line] = '                ' .. name
        else
            table.insert(lines, level_prefix .. ('%s [%s]%s'):format(
                name, nm_data.spawn_types[name] or 'unknown', seen_label))
        end
        local objective_id = roe_nms[name]
        if objective_id then
            if active_roe[objective_id] or completed_roe[objective_id] then
                active_marker_lines[#lines] = true
            else
                inactive_marker_lines[#lines] = true
            end
        end
        hud_link_rows[#lines] = wiki_url(name)
        append_wrapped(lines, '    ', zone_details[name] or 'The wiki does not document the spawn condition.')
        local drop_start = #lines + 1
        local drop_value = zone_drops[name] or 'None documented on BG Wiki.'
        append_wrapped(lines, '    Drops: ', drop_value, '           ')
        local drop_overlay = {}
        append_wrapped(drop_overlay, '    Drops: ', drop_value, '           ')
        for i, value in ipairs(drop_overlay) do drop_lines[drop_start + i - 1] = value end
    end
    if #zone_nms == 0 then
        table.insert(lines, '  none in bundled list')
    end

    if #zone_normal_drops > 0 then
        table.insert(lines, 'Normal mob equipment drops by lvl:')
        for _, entry in ipairs(zone_normal_drops) do
            local row_line = #lines + 1
            local level_prefix = ('  [%s] '):format(entry.levels)
            if settings.wiki_links then
                table.insert(lines, level_prefix .. string.rep(' ', #entry.mob))
                -- Spaces render narrower than glyphs in Windower's text layer,
                -- so the link overlay needs extra padding beyond #level_prefix.
                link_lines[row_line] = '                ' .. entry.mob
            else
                table.insert(lines, level_prefix .. entry.mob)
            end
            hud_link_rows[row_line] = wiki_url(entry.mob)
            if entry.condition then append_wrapped(lines, '    ', entry.condition) end

            local drop_rendered = {}
            append_wrapped(drop_rendered, '    Drops: ', entry.drops, '           ')
            for _, value in ipairs(drop_rendered) do
                -- Render drop text only in the gold layer to avoid doubled glyphs.
                table.insert(lines, string.rep(' ', #value))
                drop_lines[#lines] = value
            end
        end
    end

    if #widescan_entries > 0 then
        table.insert(lines, 'Widescan (map offsets):')
        -- Store the rendered section bounds because wrapped NM details make
        -- their absolute positions vary by zone. Mouse handling uses this
        -- range so the heading and every displayed mob row are clickable.
        widescan_first_line = #lines
        local ordinary_shown = 0
        for _, entry in ipairs(widescan_entries) do
            local flagged = entry.placeholder_for or entry.tracked_nm
            -- The configured limit applies only to ordinary rows. Always show
            -- every discovered NM and placeholder, without duplicating entries.
            if flagged or ordinary_shown < settings.hud.max_shown then
                if not flagged then ordinary_shown = ordinary_shown + 1 end
                local label
                if entry.placeholder_for then
                    label = ('  %s%s PH [0x%03X]'):format(
                        widescan_track == entry and '▶ ' or '• ',
                        entry.placeholder_for, entry.index or 0)
                elseif entry.tracked_nm then
                    label = ('  %s%s NM [0x%03X]'):format(
                        widescan_track == entry and '▶ ' or '• ',
                        entry.tracked_nm, entry.index or 0)
                else
                    label = ('  %s #%d [0x%03X]'):format(
                        entry.name, entry.number, entry.index or 0)
                end
                if entry.x and player then
                    local dx, dy = entry.x - player.x, entry.y - player.y
                    local distance = math.sqrt(dx * dx + dy * dy)
                    label = label .. (' | %.1fy %s'):format(
                        distance, relative_direction(player, entry))
                end
                if entry.placeholder_for then
                    local encounters = placeholder_tracker:encounters(
                        zone_id, entry.placeholder_for, entry.index)
                    if encounters > 0 then
                        label = label .. (' | seen %dx'):format(encounters)
                    end
                end
                table.insert(lines, label)
            end
        end
        widescan_last_line = #lines
    end

    local green_lines = {}
    local red_lines = {}
    for i = 1, #lines do
        green_lines[i] = active_marker_lines[i] and '  ●' or ''
        red_lines[i] = inactive_marker_lines[i] and '  ●' or ''
        -- Keep blank rows non-empty so Windower preserves their vertical spacing.
        link_lines[i] = link_lines[i] or ' '
        drop_lines[i] = drop_lines[i] or ' '
        zone_lines[i] = zone_lines[i] or ' '
        target_lines[i] = target_lines[i] or ' '
        alert_lines[i] = alert_lines[i] or ' '
    end
    hud_line_count = #lines

    hud:text(table.concat(lines, '\n'))
    active_icons:text(table.concat(green_lines, '\n'))
    inactive_icons:text(table.concat(red_lines, '\n'))
    link_text:text(table.concat(link_lines, '\n'))
    drop_text:text(table.concat(drop_lines, '\n'))
    zone_text:text(table.concat(zone_lines, '\n'))
    target_text:text(table.concat(target_lines, '\n'))
    alert_text:text(table.concat(alert_lines, '\n'))
    local hud_x, hud_y = hud:pos()
    active_icons:pos(hud_x, hud_y)
    inactive_icons:pos(hud_x, hud_y)
    link_text:pos(hud_x, hud_y)
    drop_text:pos(hud_x, hud_y)
    zone_text:pos(hud_x + 275, hud_y)
    target_text:pos(hud_x, hud_y)
    alert_text:pos(hud_x, hud_y)
    if next(alert_mob_ids) ~= nil then
        alert_text:show()
    else
        alert_text:hide()
    end
    hud:bg_color(settings.hud.bg.red, settings.hud.bg.green, settings.hud.bg.blue)
    hud:bg_alpha(settings.hud.bg.alpha)
    hud:show()
    active_icons:show()
    inactive_icons:show()
    if settings.wiki_links then link_text:show() else link_text:hide() end
    drop_text:show()
    zone_text:show()
    target_text:show()
end

local function hud_line_at(x, y)
    if not settings.hud.visible or hud_line_count == 0 then return nil end
    local hud_x, hud_y = hud:pos()
    local width, height = hud:extents()
    if not width or not height or width <= 0 or height <= 0
        or x < hud_x or x > hud_x + width or y < hud_y or y > hud_y + height
    then
        return nil
    end
    return math.min(hud_line_count, math.floor((y - hud_y) / (height / hud_line_count)) + 1)
end

windower.register_event('mouse', function(type, x, y, delta, blocked)
    if not settings.hud.visible then return end
    local line = hud_line_at(x, y)
    local over_widescan = line and widescan_first_line and widescan_last_line
        and line >= widescan_first_line and line <= widescan_last_line
    local interactive_line = line and (hud_target_rows[line]
        or (settings.wiki_links and hud_link_rows[line])
        or over_widescan)
    if blocked and not interactive_line and not pending_target then return end

    -- Windower mouse types 4 and 5 are right-button down and up. Require both
    -- events in the widescan section so a release elsewhere cannot clear data.
    if type == 4 then
        if over_widescan then
            pending_widescan_clear = true
            return true
        end
    elseif type == 5 and pending_widescan_clear then
        local clear = over_widescan
        pending_widescan_clear = nil
        if clear then
            clear_widescan()
            chat('widescan results cleared')
        end
        return true
    elseif type == 1 then
        if line and hud_target_rows[line] then
            pending_target = {line = line, entry = hud_target_rows[line]}
            return true
        elseif settings.wiki_links and line and hud_link_rows[line] then
            pending_link = {line = line, url = hud_link_rows[line]}
            return true
        elseif line and line <= 2 then
            local hud_x, hud_y = hud:pos()
            hud_drag = {x = x - hud_x, y = y - hud_y}
            return true
        end
    elseif type == 0 and hud_drag then
        hud:pos(x - hud_drag.x, y - hud_drag.y)
        active_icons:pos(x - hud_drag.x, y - hud_drag.y)
        inactive_icons:pos(x - hud_drag.x, y - hud_drag.y)
        link_text:pos(x - hud_drag.x, y - hud_drag.y)
        drop_text:pos(x - hud_drag.x, y - hud_drag.y)
        zone_text:pos(x - hud_drag.x + 275, y - hud_drag.y)
        target_text:pos(x - hud_drag.x, y - hud_drag.y)
        alert_text:pos(x - hud_drag.x, y - hud_drag.y)
        return true
    elseif type == 2 then
        if pending_target then
            local target = pending_target
            pending_target = nil
            if line == target.line then target_nearby_mob(target.entry) end
            return true
        elseif pending_link then
            local link = pending_link
            pending_link = nil
            if line == link.line then windower.open_url(link.url) end
            return true
        elseif hud_drag then
            settings.hud.pos.x, settings.hud.pos.y = hud:pos()
            config.save(settings)
            hud_drag = nil
            return true
        end
    end
end)

local function target_mob()
    return selected_target()
end

local function add_target()
    local mob = target_mob()
    local zone_id = zone_info()
    if not mob or not mob.id or mob.id <= 0 or not mob.index then
        chat('no valid target')
        return
    end

    local key = zone_key(zone_id)
    settings.custom_ids[key] = settings.custom_ids[key] or {}
    settings.custom_ids[key][index_key(mob.index)] = mob.name or ('ID 0x%03X'):format(mob.index)
    config.save(settings, 'all')
    chat(('saved %s at zone %d, index 0x%03X'):format(mob.name, zone_id, mob.index))
end

local function remove_target()
    local mob = target_mob()
    local zone_id = zone_info()
    local ids = settings.custom_ids[zone_key(zone_id)]
    if not mob or not mob.index or not ids or not ids[index_key(mob.index)] then
        chat('current target is not in the ID list')
        return
    end

    local name = ids[index_key(mob.index)]
    ids[index_key(mob.index)] = nil
    config.save(settings, 'all')
    chat(('removed %s [0x%03X]'):format(name, mob.index))
end

local function list_ids()
    local zone_id, zone_name = zone_info()
    local ids = settings.custom_ids[zone_key(zone_id)] or {}
    chat(('saved IDs for %s:'):format(zone_name))
    local count = 0
    for key, name in pairs(ids) do
        chat(('  0x%s  %s'):format(key:sub(2):upper(), name))
        count = count + 1
    end
    if count == 0 then chat('  none') end
end

local function list_widescan()
    if #widescan_entries == 0 then
        chat('no widescan results captured')
        return
    end
    chat(('widescan results (%d):'):format(#widescan_entries))
    for _, entry in ipairs(widescan_entries) do
        local label = ('  %s #%d [0x%03X] offsets=(%s,%s)'):format(
            entry.name, entry.number, entry.index or 0,
            tostring(entry.x_offset or '?'), tostring(entry.y_offset or '?'))
        if entry.placeholder_for then label = label .. ' -> ' .. entry.placeholder_for .. ' placeholder' end
        if entry.tracked_nm then
            label = label .. (widescan_track == entry and ' -> NM tracked' or ' -> NM found')
        end
        chat(label)
    end
end

local function placeholder_stats(name)
    local zone_id, zone_name = zone_info()
    local observed = placeholder_tracker:zone_stats(zone_id)
    if name and name ~= '' then
        local wanted = name:lower()
        local filtered = {}
        for _, nm in ipairs(observed) do
            if nm.name:lower() == wanted then table.insert(filtered, nm) end
        end
        observed = filtered
    end

    if #observed == 0 then
        chat(('no placeholder observations for %s'):format(name and name ~= '' and name or zone_name))
        return
    end

    for _, nm in ipairs(observed) do
        chat(('%s: %d candidate encounters'):format(nm.name, nm.encounters))
        for _, entry in ipairs(nm.ids) do
            chat(('  0x%03X: %d encounters, %d sightings, %d kills'):format(
                tonumber(entry.index) or 0,
                tonumber(entry.encounters) or 0,
                tonumber(entry.sightings) or 0,
                tonumber(entry.kills) or 0))
            chat(('    outcomes: NM followed=%d, placeholder returned=%d'):format(
                tonumber(entry.nm_followed) or 0,
                tonumber(entry.placeholder_returned) or 0))
            if tonumber(entry.first_seen) and tonumber(entry.first_seen) > 0 then
                chat(('    first=%s last=%s'):format(
                    os.date('%Y-%m-%d %H:%M:%S', tonumber(entry.first_seen)),
                    os.date('%Y-%m-%d %H:%M:%S', tonumber(entry.last_seen))))
            end
        end
    end
end

local function reset_placeholder_stats(name)
    local zone_id = zone_info()
    if not name or name == '' then
        chat('usage: //nmw phreset <NM name|all>')
        return
    end
    if name:lower() == 'all' then
        placeholder_tracker:reset_stats(zone_id, 'all')
        chat('all placeholder observations cleared')
    elseif placeholder_tracker:reset_stats(zone_id, name) then
        chat(('placeholder observations cleared for %s'):format(name))
    else
        chat(('no placeholder observations for %s'):format(name))
    end
end

windower.register_event('prerender', function()
    local now = os.clock()
    if settings.enabled and now - last_scan >= settings.scan_interval then
        last_scan = now
        scan()
    end
    if now - last_hud_update >= 0.2 then
        last_hud_update = now
        update_hud()
    end
end)

windower.register_event('zone change', function()
    seen = {}
    active = {}
    recent = {}
    alert_until = 0
    alert_mob_ids = {}
    alert_mob_names = {}
    last_scan = 0
    placeholder_tracker:reset_session()
    clear_widescan()
end)

windower.register_event('incoming chunk', function(id, data)
    if id == 0x111 then update_roe(data) end
    if id == 0x0F4 then update_widescan_mob(data) end
    if id == 0x0F5 then update_widescan_track(data) end
    if id == 0x0F6 then update_widescan_mark(data) end
end)

windower.register_event('load', function()
    local data = windower.packets and windower.packets.last_incoming(0x111)
    if data then update_roe(data) end
end)

windower.register_event('unload', function()
    hud:hide()
    active_icons:hide()
    inactive_icons:hide()
end)

windower.register_event('addon command', function(cmd, ...)
    cmd = (cmd or 'toggle'):lower()
    local args = {...}

    if cmd == 'on' or cmd == 'off' or cmd == 'toggle' then
        settings.enabled = cmd == 'on' or (cmd == 'toggle' and not settings.enabled)
        config.save(settings)
        if not settings.enabled then active = {} end
        chat(settings.enabled and 'enabled' or 'disabled')
    elseif cmd == 'add' then
        add_target()
    elseif cmd == 'remove' then
        remove_target()
    elseif cmd == 'list' then
        list_ids()
    elseif cmd == 'widescan' or cmd == 'ws' then
        list_widescan()
    elseif cmd == 'wsclear' then
        clear_widescan()
        chat('widescan results cleared')
    elseif cmd == 'phstats' then
        placeholder_stats(table.concat(args, ' '))
    elseif cmd == 'phreset' then
        reset_placeholder_stats(table.concat(args, ' '))
    elseif cmd == 'clear' then
        seen = {}
        active = {}
        recent = {}
        chat('detection history cleared')
    elseif cmd == 'range' and tonumber(args[1]) and tonumber(args[1]) > 0 then
        settings.range = tonumber(args[1])
        config.save(settings)
        chat(('range = %dy'):format(settings.range))
    elseif cmd == 'wiki' then
        settings.wiki_fallback = not settings.wiki_fallback
        config.save(settings)
        chat('wiki name fallback ' .. (settings.wiki_fallback and 'on' or 'off'))
    elseif cmd == 'links' then
        local value = (args[1] or 'toggle'):lower()
        if value == 'on' then
            settings.wiki_links = true
        elseif value == 'off' then
            settings.wiki_links = false
        elseif value == 'toggle' then
            settings.wiki_links = not settings.wiki_links
        else
            chat('links must be on or off')
            return
        end
        config.save(settings)
        chat('wiki links ' .. (settings.wiki_links and 'on' or 'off'))
    elseif cmd == 'sound' then
        settings.sound = not settings.sound
        config.save(settings)
        chat('sound ' .. (settings.sound and 'on' or 'off'))
    elseif cmd == 'soundfile' and args[1] then
        settings.sound_file = table.concat(args, ' ')
        config.save(settings)
        chat('sound file = ' .. settings.sound_file)
    elseif cmd == 'hud' then
        settings.hud.visible = not settings.hud.visible
        config.save(settings)
        chat('hud ' .. (settings.hud.visible and 'shown' or 'hidden'))
    elseif cmd == 'pos' then
        if not args[1] and not args[2] then
            chat(('hud position = %d, %d'):format(settings.hud.pos.x, settings.hud.pos.y))
        elseif tonumber(args[1]) and tonumber(args[2]) then
            local x, y = math.floor(tonumber(args[1])), math.floor(tonumber(args[2]))
            settings.hud.pos.x, settings.hud.pos.y = x, y
            hud:pos(x, y)
            active_icons:pos(x, y)
            inactive_icons:pos(x, y)
            link_text:pos(x, y)
            drop_text:pos(x, y)
            zone_text:pos(x + 275, y)
            target_text:pos(x, y)
            alert_text:pos(x, y)
            config.save(settings)
            chat(('hud position = %d, %d'):format(x, y))
        else
            chat('usage: //nmw pos <x> <y>')
        end
    elseif cmd == 'alpha' and tonumber(args[1]) then
        local value = math.floor(tonumber(args[1]))
        if value >= 0 and value <= 255 then
            settings.hud.bg.alpha = value
            config.save(settings)
            chat(('background alpha = %d'):format(value))
        else
            chat('alpha must be between 0 and 255')
        end
    elseif cmd == 'test' then
        notify({name = table.concat(args, ' ') ~= '' and table.concat(args, ' ') or 'Test NM', index = 0, source = 'test'})
    elseif cmd == 'status' then
        chat(('enabled=%s range=%dy scan=%.1fs wiki=%s links=%s sound=%s hud=%s alpha=%d')
            :format(tostring(settings.enabled), settings.range, settings.scan_interval,
                tostring(settings.wiki_fallback), tostring(settings.wiki_links), tostring(settings.sound),
                tostring(settings.hud.visible), settings.hud.bg.alpha))
    elseif cmd == 'help' then
        chat('on|off|toggle, add, remove, list, clear, range <y>, wiki, links [on|off], hud, pos <x> <y>, alpha <0-255>, sound, soundfile <path>, test [name], status')
        chat('widescan|ws, wsclear, phstats [NM name], phreset <NM name|all>')
    else
        chat('unknown command - type //nmw help')
    end
end)

chat(('loaded v%s - type //nmw help'):format(_addon.version))
