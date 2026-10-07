package.path = './?.lua;' .. package.path

local nm_data = require('wiki_nms')
local browser = require('catalog_browser')
local model = browser.build(nm_data)

assert(model.entry_count == 499, 'expected 447 NM-zone rows plus 52 normal-drop rows')
assert(model.lines[1] == '--- Levels 1-9 ---', 'catalog did not start at the lowest level band')

local all_lines = table.concat(model.lines, '\n')
assert(all_lines:find('[NM 9-10] Jaggedy-Eared Jack', 1, true), 'missing NM row')
assert(all_lines:find('[DROP 03-10] Orcish Fodder', 1, true), 'missing normal-drop row')

local page, offset = browser.render(model, 99999, 12)
assert(offset == #model.lines - 12, 'scroll offset was not clamped')
assert(page:find('Mouse wheel to scroll', 1, true), 'missing scroll instructions')
local first_page, _, sections, zones, links, link_rows, suffixes =
    browser.render(model, 0, 12, true)
assert(not first_page:find('%-%-%- Levels'), 'level heading leaked into the white layer')
assert(sections:find('%-%-%- Levels'), 'missing colored level-heading layer')
assert(zones:find('%a'), 'missing colored zone-heading layer')
assert(links:find('%a'), 'missing colored mob-name layer')
assert(next(link_rows), 'missing clickable mob rows')
assert(links:find('Stone Eater', 1, true), 'mob name missing from link column')
assert(suffixes:find("%- Hermit's Ring"), 'drop missing from suffix column')

local unlinked = browser.render(model, 0, 12, false)
assert(unlinked:find('[NM ', 1, true), 'mob name row disappeared with links disabled')

print('catalog browser regression test passed')
