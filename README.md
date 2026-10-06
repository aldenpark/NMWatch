# NMWatch

Windower 4 addon that alerts when a known Notorious Monster is nearby. It does
not send `/check` packets. Exact TargetInfo hex IDs are checked first; an
the bundled NM name/zone list is used as a fallback.

## Quick start

```text
//lua load NMWatch
//nmw on
```

Target an NM and save its exact zone-local ID:

```text
//nmw id
//nmw add
```

The ID is the same `mob.index` hex value displayed by this installation's
TargetInfo addon. Saved IDs persist in `data/settings.xml` and are scoped by
zone. `//nmw remove` removes the currently targeted ID; `//nmw list` prints the
saved IDs for the current zone.

## Matching

1. Exact current-zone + TargetInfo hex ID from `//nmw add`.
2. Exact bundled wiki current-zone + TargetInfo hex ID.
3. Exact mob name in the current zone from `wiki_nms.lua`, when the wiki
   fallback is enabled.

The bundled name list covers the known NM names and zones. Exact IDs come from
explicitly labeled NM IDs in the linked article text and BG Wiki NM page notes. A mob may legitimately have multiple IDs: for
example, Leaping Lizzy uses `0x17C` and `0x190` in South Gustaberg, and NMWatch
includes both. Use `//nmw wiki` to disable or enable the name fallback.

The addon scans only active, targetable monsters within the configured radius.
It alerts once while a matching entity remains alive and in range, then can
alert again after that entity disappears or dies.

The HUD always lists the bundled NMs for the current zone, labels each as
`timed`, `lottery`, `forced/quest`, `fished`, or `special`, and displays the
wiki's detailed spawn instruction. This includes placeholders, coordinates,
maps, timers, trade items, weather, and event conditions when documented.
Nearby matches appear above the zone list.

Each zone NM also displays a `Drops:` section populated from the BG Wiki
Treasure field. Entries without a usable Treasure field say
`None documented on BG Wiki.` rather than guessing.
Each NM row also shows `Last seen` for the most recent detection during the
current addon session, or `never` if NMWatch has not detected it yet.

HUD colors are used as follows:

- Magenta: current zone name.
- Cyan: clickable NM names when BG Wiki links are enabled.
- Gold: documented drops.
- Green/red circles: active/inactive Records of Eminence objectives.

The panel uses a translucent background and is tinted red while a newly
detected NM alert is active. That alert tint clears when the matching mob
disappears.

NMs with a matching Records of Eminence kill objective have a colored circle:

- Green: the objective is currently active.
- Red: the objective exists but is not currently active.
- No circle: NMWatch has no matching kill objective for that NM.

Objective state is read from the live RoE objective packet; NMWatch does not
start or cancel objectives.

## Commands

| Command | Purpose |
|---|---|
| `//nmw on`, `off`, `toggle` | Control scanning |
| `//nmw id` | Show the target's name, zone, hex index, and full ID |
| `//nmw add` | Save the targeted zone/index as an exact NM ID |
| `//nmw remove` | Remove the targeted zone/index |
| `//nmw list` | List exact IDs saved for this zone |
| `//nmw range <yalms>` | Change the scan radius |
| `//nmw wiki` | Toggle the bundled name fallback |
| `//nmw links [on\|off]` | Enable or disable clickable BG Wiki NM names |
| `//nmw hud` | Toggle the HUD |
| `//nmw alpha <0-255>` | Set HUD background opacity (`0` transparent, `255` solid) |
| `//nmw sound` | Toggle sound |
| `//nmw soundfile <path>` | Set the alert `.wav` |
| `//nmw clear` | Clear current detection history, not saved IDs |
| `//nmw test [name]` | Test the chat/HUD/sound alert |
| `//nmw status` | Show current settings |

## Data source

`wiki_nms.lua` contains the bundled name fallback: 435 unique
NM names across 447 zone/name combinations. Multi-zone entries are expanded so
each applicable zone can match independently.

Exact IDs are sourced from the corresponding BG Wiki page notes, for example:

<https://www.bg-wiki.com/ffxi/Leaping_Lizzy>

The wiki data can be replaced later with a cleaner list without changing the
scanner. Its `ids` table is keyed by numeric zone ID and TargetInfo hex index;
its `names` table is keyed by lowercase English zone name.
`spawn_types.lua` contains one documented pop-method annotation for every NM in
the bundled list. These annotations are display information only; detection
still uses the exact-ID and name rules above.
`spawn_details.lua` contains zone-specific instructions for all 447 zone/name
combinations. Zone-specific keys prevent shared NMs such as Goblin Archaeologist
from displaying the wrong coordinates.
`drops.lua` contains BG Wiki's documented Treasure drops for the same 447
zone/name combinations. The HUD shows `None documented on BG Wiki.` when the
page has no usable Treasure entry.
`roe_nms.lua` maps the 82 bundled NMs with known Records of Eminence kill
objectives to their objective IDs.

With wiki links enabled (the default), left-click an NM name in the HUD to open
its BG Wiki page. Drag the HUD by either header line. Steam Deck users can run
`//nmw links off` to prevent NMWatch from launching an external browser.
