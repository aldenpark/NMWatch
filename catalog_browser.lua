local browser = {}

local function level_range(value)
    local first, last = value:match('^(%d+)%-(%d+)$')
    if not first then first = value:match('^(%d+)$') end
    first = tonumber(first) or 0
    return first, tonumber(last) or first
end

local function level_band(level)
    if level < 10 then return 1, 9 end
    local first = math.floor(level / 10) * 10
    return first, first + 9
end

local function clipped(value, width)
    if #value <= width then return value end
    return value:sub(1, width - 3) .. '...'
end

function browser.build(nm_data)
    local entries = {}
    for zone, names in pairs(nm_data.names) do
        for _, name in ipairs(names) do
            local levels = nm_data.levels[name]
            local first, last = level_range(levels)
            local band = level_band(first)
            table.insert(entries, {
                band = band,
                zone = zone,
                first = first,
                last = last,
                levels = levels,
                name = name,
                kind = 'NM',
                drops = nm_data.drops[zone] and nm_data.drops[zone][name],
            })
        end
    end
    for zone, drops in pairs(nm_data.normal_drops) do
        for _, drop in ipairs(drops) do
            local first, last = level_range(drop.levels)
            local band = level_band(first)
            table.insert(entries, {
                band = band,
                zone = zone,
                first = first,
                last = last,
                levels = drop.levels,
                name = drop.mob,
                kind = 'DROP',
                drops = drop.drops,
            })
        end
    end

    table.sort(entries, function(a, b)
        if a.band ~= b.band then return a.band < b.band end
        if a.zone ~= b.zone then return a.zone < b.zone end
        if a.first ~= b.first then return a.first < b.first end
        if a.last ~= b.last then return a.last < b.last end
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.name < b.name
    end)

    local lines = {}
    local kinds = {}
    local names = {}
    local previous_band
    local previous_zone
    for _, entry in ipairs(entries) do
        if entry.band ~= previous_band then
            local first, last = level_band(entry.first)
            table.insert(lines, ('--- Levels %d-%d ---'):format(first, last))
            kinds[#lines] = 'section'
            previous_band = entry.band
            previous_zone = nil
        end
        if entry.zone ~= previous_zone then
            table.insert(lines, (entry.zone:gsub('^%l', string.upper)))
            kinds[#lines] = 'zone'
            previous_zone = entry.zone
        end
        local detail = ('  [%s %s] %s'):format(entry.kind, entry.levels, entry.name)
        if entry.drops and entry.drops ~= 'None documented on BG Wiki.' then
            detail = detail .. ' - ' .. entry.drops
        end
        table.insert(lines, clipped(detail, 76))
        kinds[#lines] = 'entry'
        names[#lines] = entry.name
    end

    local max_prefix = 0
    local max_name = 0
    local max_line = 0
    for i, value in ipairs(lines) do
        max_line = math.max(max_line, #value)
        local name = names[i]
        local name_start = name and value:find(name, 1, true)
        if name_start then
            max_prefix = math.max(max_prefix, name_start - 1)
            max_name = math.max(max_name, #name)
        end
    end
    local link_indent = math.ceil(max_prefix * 1.8)
    local suffix_indent = math.ceil((max_prefix + max_name + 10) * 1.8)
    return {
        lines = lines,
        kinds = kinds,
        names = names,
        entry_count = #entries,
        link_indent = link_indent,
        suffix_indent = suffix_indent,
        panel_columns = math.max(50, max_line + 10),
    }
end

function browser.clamp(model, offset, page_size)
    return math.max(0, math.min(offset, math.max(0, #model.lines - page_size)))
end

function browser.render(model, offset, page_size, show_links)
    offset = browser.clamp(model, offset, page_size)
    local last = math.min(#model.lines, offset + page_size)
    local lines = {
        ('All-zone guide | %d entries | %d-%d/%d'):format(
            model.entry_count, math.min(offset + 1, #model.lines), last, #model.lines),
        'Mouse wheel to scroll; click Guide to close',
    }
    local section_lines = {' ', ' '}
    local zone_lines = {' ', ' '}
    local prefix_lines = {' ', ' '}
    local link_lines = {' ', ' '}
    local suffix_lines = {' ', ' '}
    local link_rows = {}
    for i = offset + 1, last do
        local value = model.lines[i]
        local kind = model.kinds[i]
        local name = show_links and model.names[i]
        local name_start = name and value:find(name, 1, true)
        if name_start then
            -- Windower renders spaces narrower than glyphs. Fixed per-page
            -- columns keep variable-width names and drop text from colliding.
            local prefix = value:sub(1, name_start - 1)
            local suffix = value:sub(name_start + #name):gsub('^%s+', '')
            table.insert(lines, ' ')
            table.insert(prefix_lines, prefix)
            table.insert(link_lines, string.rep(' ', model.link_indent) .. name)
            table.insert(suffix_lines, suffix ~= ''
                and string.rep(' ', model.suffix_indent) .. suffix or ' ')
            link_rows[#lines] = name
        else
            table.insert(lines, kind == 'entry' and value or string.rep(' ', #value))
            table.insert(prefix_lines, ' ')
            table.insert(link_lines, ' ')
            table.insert(suffix_lines, ' ')
        end
        table.insert(section_lines, kind == 'section' and value or ' ')
        table.insert(zone_lines, kind == 'zone' and value or ' ')
    end
    return table.concat(lines, '\n'), offset,
        table.concat(section_lines, '\n'), table.concat(zone_lines, '\n'),
        table.concat(link_lines, '\n'), link_rows, table.concat(suffix_lines, '\n'),
        table.concat(prefix_lines, '\n')
end

return browser
