_addon.name = 'NMWatch'
_addon.version = '1.6.0'
_addon.author = 'Alden Park'
_addon.commands = {'nmw', 'nmwatch'}

require('logger')
local config = require('config')
local packets = require('packets')
local res = require('resources')
local texts = require('texts')
local nm_data = require('wiki_nms')
local roe_nms = require('roe_nms')

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
target_text:color(255, 120, 80)
alert_text:color(255, 80, 80)
local seen = {}
local active = {}
local recent = {}
local last_seen = {}
local last_scan = 0
local last_hud_update = 0
local alert_until = 0
local alert_mob_id = nil
local wiki_cache = {}
local active_roe = {}
local hud_link_rows = {}
local hud_line_count = 0
local hud_drag = nil
local pending_link = nil

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
        end
    end
    active_roe = current
end

local function chat(message)
    windower.add_to_chat(settings.chat_color, '[NMW] ' .. message)
end

local function zone_info()
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

local function match_mob(mob, zone_id, zone_name)
    local exact_name = custom_name(zone_id, mob.index)
    if exact_name then
        return exact_name, match_source(exact_name, 'custom ID')
    end

    local bundled_ids = nm_data.ids[zone_id]
    local bundled_name = bundled_ids and bundled_ids[mob.index]
    if bundled_name then
        return bundled_name, match_source(bundled_name, 'wiki ID')
    end

    if settings.wiki_fallback and mob.name then
        local wiki_name = wiki_names(zone_name)[mob.name:lower()]
        if wiki_name then
            return wiki_name, nm_data.spawn_types[wiki_name] or 'wiki'
        end
    end
end

local function notify(match)
    chat(('>>> NM FOUND: %s [0x%03X, %s] <<<')
        :format(match.name, match.index, match.source))
    if settings.sound and settings.sound_file ~= '' then
        windower.play_sound(settings.sound_file)
    end
    alert_until = os.clock() + 5
    alert_mob_id = match.id
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

    for _, mob in pairs(mobs) do
        if mob and mob.id and mob.id > 0 and mob.index
            and mob.spawn_type == 16 and mob.valid_target
            and mob.hpp and mob.hpp > 0
        then
            local dx = (mob.x or 0) - (player.x or 0)
            local dy = (mob.y or 0) - (player.y or 0)
            local dz = (mob.z or 0) - (player.z or 0)
            local distance_sq = dx * dx + dy * dy + dz * dz
            if distance_sq <= range_sq then
                local name, source = match_mob(mob, zone_id, zone_name)
                if name then
                    local match = {
                        id = mob.id,
                        index = mob.index,
                        name = mob.name or name,
                        source = source,
                        distance = math.sqrt(distance_sq),
                    }
                    found[mob.id] = match
                    last_seen[zone_name:lower()] = last_seen[zone_name:lower()] or {}
                    last_seen[zone_name:lower()][name] = os.time()
                    if not seen[mob.id] then
                        notify(match)
                    end
                end
            end
        end
    end

    active = found
    seen = found
    if alert_mob_id and not found[alert_mob_id] then
        alert_mob_id = nil
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

    local _, zone_name = zone_info()
    local zone_nms = nm_data.names[zone_name:lower()] or {}
    local zone_details = nm_data.spawn_details[zone_name:lower()] or {}
    local zone_drops = nm_data.drops[zone_name:lower()] or {}
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
    local lines = {
        ('%-42s%s'):format(('NMWatch %s  range=%dy'):format(state, settings.range), string.rep(' ', #zone_name)),
    }
    zone_lines[1] = zone_name

    local target = selected_target()
    if target and target.id and target.id > 0 then
        local target_line = ('Target: %s | Hex ID=0x%03X | ID=%u'):format(
            target.name or 'Unknown', target.index or 0, target.id)
        table.insert(lines, target_line)
        target_lines[2] = target_line
    end

    if #active_list > 0 then
        table.insert(lines, ('Nearby (%d):'):format(#active_list))
    end
    for i = 1, math.min(#active_list, settings.hud.max_shown) do
        local match = active_list[i]
        local nearby_line = ('  %s [0x%03X] %.1fy'):format(match.name, match.index, match.distance)
        table.insert(lines, nearby_line)
        if match.id == alert_mob_id and os.clock() < alert_until then
            alert_lines[#lines] = nearby_line
        end
    end
    if #active_list == 0 and #recent > 0 then
        table.insert(lines, 'Last: ' .. recent[1].name)
    end

    table.insert(lines, 'Zone NMs:')
    for _, name in ipairs(zone_nms) do
        local row_line = #lines + 1
        local seen_at = last_seen[zone_name:lower()] and last_seen[zone_name:lower()][name]
        local seen_label = seen_at and os.time() - seen_at <= 86400
            and (' | Last seen: ' .. os.date('%Y-%m-%d %H:%M:%S', seen_at)) or ''
        table.insert(lines, ('       %s [%s]%s'):format(
            name, nm_data.spawn_types[name] or 'unknown', seen_label))
        if settings.wiki_links then link_lines[row_line] = '       ' .. name end
        local objective_id = roe_nms[name]
        if objective_id then
            if active_roe[objective_id] then
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
    if os.clock() < alert_until then
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
    if blocked and not (settings.wiki_links and line and hud_link_rows[line]) then return end

    if type == 1 then
        if settings.wiki_links and line and hud_link_rows[line] then
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
        if pending_link then
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

local function show_target_id()
    local mob = target_mob()
    local zone_id, zone_name = zone_info()
    if not mob or not mob.id or mob.id <= 0 then
        chat('no valid target')
        return
    end
    chat(('%s | %s (%d) | index=0x%03X | full=%u')
        :format(mob.name or 'Unknown', zone_name, zone_id, mob.index, mob.id))
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
    alert_mob_id = nil
    last_scan = 0
end)

windower.register_event('incoming chunk', function(id, data)
    if id == 0x111 then update_roe(data) end
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
    elseif cmd == 'id' then
        show_target_id()
    elseif cmd == 'list' then
        list_ids()
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
        chat('on|off|toggle, add, remove, id, list, clear, range <y>, wiki, links [on|off], hud, alpha <0-255>, sound, soundfile <path>, test [name], status')
    else
        chat('unknown command - type //nmw help')
    end
end)

chat(('loaded v%s - type //nmw help'):format(_addon.version))
