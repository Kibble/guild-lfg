import argparse
from html import escape
from pathlib import Path

parser = argparse.ArgumentParser(description='Render a Guild Queue Create party UI concept.')
parser.add_argument('variant', nargs='?', default='create-party', choices=('create-party', 'already-grouped'))
args = parser.parse_args()
already_grouped = args.variant == 'already-grouped'
OUT = Path(__file__).parent
output_stem = f'GuildQueue-UI-{args.variant}'
tooltip = 'You are already in a party or raid. Leave your current group to create a new party.'
parts = ['''<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1168" viewBox="0 0 1600 1168">
<title>Guild Queue: guild-only dungeon matchmaking UI concept</title>
<desc>Multi-select roles and dungeons on the left. On the right, your suggested five-player group and three unmatched individuals. Clicking Create party invites the other four members; invitations are never automatic.</desc>''']
parts.append(f'<desc>{escape(tooltip) if already_grouped else "You are solo. Create party is enabled for your suggested group."}</desc>')
parts.append('''
<defs>
  <linearGradient id="canvas" x2="1" y2="1"><stop stop-color="#14191d"/><stop offset="1" stop-color="#080c10"/></linearGradient>
  <linearGradient id="window" x2="0" y2="1"><stop stop-color="#23282c"/><stop offset="1" stop-color="#14191d"/></linearGradient>
  <linearGradient id="header" x2="1" y2="0"><stop stop-color="#343128"/><stop offset=".65" stop-color="#22282b"/><stop offset="1" stop-color="#1a2227"/></linearGradient>
  <linearGradient id="gold" x2="0" y2="1"><stop stop-color="#e6c987"/><stop offset="1" stop-color="#9c7942"/></linearGradient>
  <linearGradient id="selected" x2="0" y2="1"><stop stop-color="#37352c"/><stop offset="1" stop-color="#292b29"/></linearGradient>
  <linearGradient id="leave" x2="0" y2="1"><stop stop-color="#753b3a"/><stop offset="1" stop-color="#4c282b"/></linearGradient>
</defs>''')

def rect(x, y, w, h, fill, stroke='none', radius=0, sw=1):
    parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>')

def line(x1, y1, x2, y2, color, sw=1):
    parts.append(f'<path d="M{x1} {y1} L{x2} {y2}" fill="none" stroke="{color}" stroke-width="{sw}" stroke-linecap="round"/>')

def text(x, y, value, size=18, color='#d9dde0', weight='normal', family='DejaVu Sans', anchor='start', spacing=None):
    extra = f' letter-spacing="{spacing}"' if spacing is not None else ''
    parts.append(f'<text x="{x}" y="{y}" fill="{color}" font-family="{family}" font-size="{size}" font-weight="{weight}" text-anchor="{anchor}"{extra}>{escape(value)}</text>')

def circle(x, y, r, fill, stroke='none'):
    parts.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{fill}" stroke="{stroke}"/>')

def checkbox(x, y, checked, small=False):
    side = 19 if small else 22
    rect(x, y, side, side, '#10171b', '#bda36d' if checked else '#586167', 3, 1.5)
    if checked:
        parts.append(f'<path d="M{x+4} {y+side*.52} l{side*.22} {side*.22} l{side*.43} -{side*.49}" fill="none" stroke="#e8cd8e" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>')

def button(x, y, w, h, title, active=False, red=False, disabled=False):
    fill = '#20272b' if disabled else ('url(#leave)' if red else ('url(#selected)' if active else '#242b30'))
    stroke = '#535b5e' if disabled else ('#a46660' if red else ('#ab8c54' if active else '#444f56'))
    color = '#788286' if disabled else ('#f1dcd7' if red else ('#efd79e' if active else '#c8d0d5'))
    rect(x, y, w, h, fill, stroke, 5)
    text(x+w/2, y+h/2+6, title, 18, color, 'bold' if active or red else 'normal', anchor='middle')

# Presentation canvas, deliberately not an in-game screenshot.
rect(0, 0, 1600, 1168, 'url(#canvas)')
text(50, 49, 'GUILD QUEUE', 18, '#cdb783', 'bold', spacing=3)
text(1550, 49, 'UI CONCEPT  /  ILLUSTRATIVE DATA', 14, '#839198', anchor='end', spacing=1.5)

# Window frame and ornamental edge.
rect(47, 84, 1506, 1014, '#080c0f', '#090e11', 12, 3)
rect(50, 80, 1500, 1014, 'url(#window)', '#9a8255', 10, 2)
rect(57, 87, 1486, 1000, 'none', '#4e4d42', 6)
rect(59, 89, 1482, 130, 'url(#header)', radius=4)
line(60, 220, 1540, 220, '#766448')
for x in (69, 1531):
    for y in (99, 1076):
        circle(x, y, 3, '#c1a268')
# Emblem: a shield and three small guild marks, drawn rather than copied game art.
parts.append('<path d="M87 122 L116 113 L145 122 L143 152 Q139 173 116 184 Q93 173 89 152 Z" fill="#161e22" stroke="#c7aa70" stroke-width="2"/>')
parts.append('<path d="M116 123 L116 168 M101 138 L131 138" stroke="#c7aa70" stroke-width="3"/>')
text(168, 143, 'Guild Queue', 34, '#eed6a0', 'bold', 'DejaVu Serif')
text(169, 175, 'DUNGEON MATCHMAKING  ·  GUILD MEMBERS ONLY', 14, '#aeb6b9', spacing=1.4)
circle(177, 201, 4, '#83bf97')
text(190, 207, 'Silver Vanguard', 17, '#ccd9cf')
text(375, 207, '8 members queued', 16, '#9daab0')
rect(1224, 130, 242, 46, '#1b2924', '#526c55', 23)
circle(1248, 153, 5, '#8cca9a')
text(1263, 160, 'Your queue is active', 17, '#b5d8bb')
rect(1493, 103, 29, 29, '#392a29', '#806059', 4)
line(1502, 112, 1513, 123, '#dcc4b6', 2)
line(1513, 112, 1502, 123, '#dcc4b6', 2)

# Left selection panel.
rect(76, 244, 410, 786, '#192024', '#3c464b', 6)
text(99, 278, 'YOUR SELECTIONS', 15, '#d3ba81', 'bold', spacing=1.6)
text(99, 308, 'Roles', 21, '#e4e6e4', 'bold')
text(462, 306, 'Select one or more', 13, '#929fa5', anchor='end')
for x, title, selected, width in ((99, 'Tank', True, 102), (211, 'Healer', False, 122), (343, 'Damage', True, 121)):
    rect(x, 326, width, 46, 'url(#selected)' if selected else '#20282d', '#9f8554' if selected else '#455057', 4)
    checkbox(x+11, 339, selected, True)
    text(x+39, 355, title, 16, '#ecd29a' if selected else '#b3bec4')
line(99, 394, 463, 394, '#354147')
text(99, 430, 'Dungeons', 21, '#e4e6e4', 'bold')
text(462, 429, '3 selected', 14, '#d7bd86', anchor='end')
text(99, 457, 'Only dungeons you want to run.', 15, '#929fa5')
rows = [
    ('Ragefire Chasm', False),
    ('Hall of Thanes', False),
    ('Ruins of Lordaeron', False),
    ('Wailing Caverns', False),
    ('The Deadmines', True),
    ('Shadowfang Keep', True),
    ('Blackfathom Deeps', True),
    ('The Stockade', False),
    ('Excavation Site', False),
]
for i, (title, selected) in enumerate(rows):
    y = 480 + i*38
    if selected:
        rect(91, y-2, 370, 35, '#2b302b', radius=3)
    checkbox(102, y+4, selected)
    text(137, y+21, title, 17, '#ead7aa' if selected else '#b6c0c5')
rect(470, 484, 5, 326, '#10171b', radius=2)
rect(470, 487, 5, 83, '#66726f', radius=2)
text(99, 894, 'Scroll for more dungeons', 13, '#87969e')
button(99, 913, 174, 36, 'Select all')
button(284, 913, 179, 36, 'Clear')
button(99, 965, 364, 44, 'Leave queue', red=True)

# Right side: tabs and a full match.
button(511, 244, 289, 48, 'Groups + individuals', active=True)
button(811, 244, 226, 48, 'All queued (8)')
text(1519, 274, 'Live guild queue', 15, '#9aa9af', anchor='end')
circle(1382, 269, 4, '#86b89a')
text(515, 331, 'Suggested groups', 23, '#e8d09b', 'bold', 'DejaVu Serif')
rect(768, 309, 33, 28, '#303329', '#6d654c', 12)
text(784, 329, '1', 16, '#e1ca94', 'bold', anchor='middle')
text(1518, 329, '1 tank  /  1 healer  /  3 damage', 15, '#99a8b0', anchor='end')
rect(511, 352, 1015, 394, '#1a2227', '#685c42', 6)
rect(512, 353, 1013, 148, '#2b2d28', radius=5)
text(536, 386, 'GROUP 1  ·  YOUR MATCH', 12, '#b2a37e', 'bold', spacing=1.5)
text(536, 417, 'The Deadmines', 26, '#f0d8a2', 'bold', 'DejaVu Serif')
rect(1070, 377, 170, 34, '#20352a', '#516d50', 17)
text(1155, 399, '5-player match', 15, '#b7d8b5', 'bold', anchor='middle')
parts.append(f'<g role="button" aria-label="Create party" aria-disabled="{str(already_grouped).lower()}">')
parts.append(f'<title>{escape(tooltip) if already_grouped else "Click to invite the other four members of Group 1."}</title>')
button(1282, 369, 218, 44, 'Create party', active=True, disabled=already_grouped)
parts.append('</g>')
if not already_grouped:
    text(1391, 440, 'Click to invite the other 4', 14, '#c9b985', anchor='middle')
text(536, 443, 'Common dungeons: The Deadmines, Shadowfang Keep', 15, '#aab8ae')
text(536, 479, 'Includes you + 4 guildmates', 15, '#b9c6b4')
if already_grouped:
    # A visible disabled-hover cursor and anchored tooltip, clear of all player rows.
    circle(1481, 402, 8, '#20272b', '#b1b8bb')
    line(1476, 407, 1486, 397, '#b1b8bb', 1.5)
    rect(1043, 423, 460, 73, '#080d10', radius=5)
    rect(1040, 420, 460, 73, '#11191f', '#a08d63', 5)
    parts.append('<path d="M1381 420 L1391 411 L1401 420" fill="#11191f" stroke="#a08d63" stroke-linejoin="round"/>')
    parts.append(f'<g role="tooltip" aria-label="{escape(tooltip)}">')
    for y, value in ((442, 'You are already in a party or raid.'),
                     (462, 'Leave your current group to create a new party.')):
        text(1055, y, value, 16, '#e3d9c4')
    parts.append('</g>')
text(536, 527, 'ASSIGNED ROLE', 12, '#83959e', spacing=1.3)
text(795, 527, 'GUILD MEMBER', 12, '#83959e', spacing=1.3)
text(1498, 527, 'SELECTED ROLES', 12, '#83959e', anchor='end', spacing=1.3)
players = [
    ('T', 'Tank', 'Arden-Azeroth (you)', 'Tank / Damage', '#96bed8', True),
    ('H', 'Healer', 'Elowen-Azeroth', 'Healer', '#a8c99d', False),
    ('D', 'Damage', 'Torren-Azeroth', 'Damage', '#d9ab91', False),
    ('D', 'Damage', 'Nym-Azeroth', 'Damage', '#d9ab91', False),
    ('D', 'Damage', 'Brann-Azeroth', 'Damage', '#d9ab91', False),
]
for i, (initial, role, name, choices, tint, own) in enumerate(players):
    y = 540+i*39
    rect(526, y, 984, 36, '#26322d' if own else ('#1d272c' if i%2 == 0 else '#1a2227'), radius=3)
    rect(538, y+6, 24, 24, '#172024', '#52606a', 4)
    text(550, y+23, initial, 13, tint, 'bold', anchor='middle')
    text(576, y+24, role, 17, tint)
    text(795, y+24, name, 17, '#b7dfb7' if own else '#d3dade', 'bold' if own else 'normal')
    text(1498, y+24, choices, 16, '#9cabb3', anchor='end')

# Individuals stay visibly separate from the five-person match.
text(515, 789, 'Unmatched individuals', 23, '#e8d09b', 'bold', 'DejaVu Serif')
rect(841, 767, 33, 28, '#303329', '#6d654c', 12)
text(857, 787, '3', 16, '#e1ca94', 'bold', anchor='middle')
text(1518, 786, 'Waiting for compatible players', 15, '#99a8b0', anchor='end')
rect(511, 808, 1015, 222, '#192126', '#3c484f', 6)
text(535, 839, 'GUILD MEMBER', 12, '#83959e', spacing=1.2)
text(820, 839, 'ROLES', 12, '#83959e', spacing=1.2)
text(1066, 839, 'DUNGEONS', 12, '#83959e', spacing=1.2)
line(530, 855, 1505, 855, '#344047')
individuals = [
    ('Kael-Azeroth', 'Tank', 'Shadowfang Keep'),
    ('Mira-Azeroth', 'Healer / Damage', 'Blackfathom Deeps'),
    ('Vex-Azeroth', 'Damage', 'The Deadmines, Shadowfang Keep'),
]
for i, (name, roles, dungeons) in enumerate(individuals):
    y = 885+i*56
    text(536, y, name, 17, '#d0d8dc')
    text(820, y, roles, 16, '#b9c5cb')
    text(1066, y, dungeons, 16, '#a6b4bc')
    if i < 2:
        line(535, y+21, 1502, y+21, '#2b363c')

# Invitations require an explicit click; a suggested match never sends them automatically.
line(76, 1047, 1524, 1047, '#494c40')
rect(97, 1059, 19, 19, '#29342c', '#779175', 4)
text(106.5, 1073, 'i', 13, '#d8cb9e', 'bold', anchor='middle')
text(130, 1075, 'Invitations go to the other four members only after you click Create party. Nothing is sent automatically.', 17, '#c5c9bb')
text(50, 1137, 'Concept mockup — not an in-game screenshot. Styling is illustrative; all names and queue entries are examples.', 15, '#85959e')
text(1550, 1137, '/gq', 15, '#b6a075', anchor='end')
parts.append('</svg>')
(OUT / f'{output_stem}.svg').write_text('\n'.join(parts), encoding='utf-8')
print(f'Wrote {output_stem}.svg (1600 x 1168).')

# Render with the already-installed system libraries, without a browser or packages.
# ImageMagick's internal SVG renderer does not faithfully reproduce these gradients.
import ctypes as C
import ctypes.util
rsvg = C.CDLL(ctypes.util.find_library('rsvg-2'))
cairo = C.CDLL(ctypes.util.find_library('cairo'))
gobject = C.CDLL(ctypes.util.find_library('gobject-2.0'))
rsvg.rsvg_handle_new_from_file.argtypes = [C.c_char_p, C.c_void_p]
rsvg.rsvg_handle_new_from_file.restype = C.c_void_p
rsvg.rsvg_handle_render_cairo.argtypes = [C.c_void_p, C.c_void_p]
rsvg.rsvg_handle_render_cairo.restype = C.c_int
cairo.cairo_image_surface_create.argtypes = [C.c_int, C.c_int, C.c_int]
cairo.cairo_image_surface_create.restype = C.c_void_p
cairo.cairo_create.argtypes = [C.c_void_p]
cairo.cairo_create.restype = C.c_void_p
cairo.cairo_surface_write_to_png.argtypes = [C.c_void_p, C.c_char_p]
cairo.cairo_surface_write_to_png.restype = C.c_int
cairo.cairo_destroy.argtypes = [C.c_void_p]
cairo.cairo_surface_destroy.argtypes = [C.c_void_p]
gobject.g_object_unref.argtypes = [C.c_void_p]
handle = rsvg.rsvg_handle_new_from_file(str(OUT / f'{output_stem}.svg').encode(), None)
assert handle, 'Could not load SVG'
surface = cairo.cairo_image_surface_create(0, 1600, 1168)
context = cairo.cairo_create(surface)
try:
    assert rsvg.rsvg_handle_render_cairo(handle, context), 'SVG rendering failed'
    assert cairo.cairo_surface_write_to_png(surface, str(OUT / f'{output_stem}.png').encode()) == 0
finally:
    cairo.cairo_destroy(context)
    cairo.cairo_surface_destroy(surface)
    gobject.g_object_unref(handle)
print(f'Rendered {output_stem}.png (1600 x 1168).')
