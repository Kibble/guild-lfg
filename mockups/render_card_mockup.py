"""Alternative card-based UI concept; uses installed SVG/Cairo libraries only."""
from html import escape
from pathlib import Path
import ctypes as C
import ctypes.util

OUT = Path(__file__).parent
STEM = 'GuildQueue-UI-cards-concept'
W, H = 1680, 1280
svg = [f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<title>Guild Queue — card-based interface concept</title>
<desc>A guild-only dungeon queue with multiple role and dungeon selections. Twelve example players form two suggested groups and two unmatched individuals. The player's group has a click-only Create party button. An additional preview shows its disabled state and explanatory tooltip when already grouped.</desc>
<defs>
 <linearGradient id="bg" x2="1" y2="1"><stop stop-color="#131b24"/><stop offset="1" stop-color="#080d13"/></linearGradient>
 <linearGradient id="panel" x2="0" y2="1"><stop stop-color="#202a34"/><stop offset="1" stop-color="#141d26"/></linearGradient>
 <linearGradient id="head" x2="1" y2="0"><stop stop-color="#36352e"/><stop offset="1" stop-color="#1b2731"/></linearGradient>
 <linearGradient id="cta" x2="0" y2="1"><stop stop-color="#d5b778"/><stop offset="1" stop-color="#ae8a4e"/></linearGradient>
 <linearGradient id="active" x2="0" y2="1"><stop stop-color="#3d3c32"/><stop offset="1" stop-color="#2b3030"/></linearGradient>
 <linearGradient id="leave" x2="0" y2="1"><stop stop-color="#5c343c"/><stop offset="1" stop-color="#3e2730"/></linearGradient>
</defs>''']


def box(x, y, w, h, fill, border='none', r=0, sw=1):
    svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{border}" stroke-width="{sw}"/>')


def text(x, y, value, size=18, color='#cdd7df', weight='normal', anchor='start', serif=False, spacing=0):
    family = 'DejaVu Serif' if serif else 'DejaVu Sans'
    svg.append(f'<text x="{x}" y="{y}" fill="{color}" font-family="{family}" font-size="{size}" font-weight="{weight}" text-anchor="{anchor}" letter-spacing="{spacing}">{escape(value)}</text>')


def line(x1, y1, x2, y2, color='#35434d', sw=1):
    svg.append(f'<path d="M{x1} {y1} L{x2} {y2}" fill="none" stroke="{color}" stroke-width="{sw}" stroke-linecap="round"/>')


def dot(x, y, radius, fill, border='none'):
    svg.append(f'<circle cx="{x}" cy="{y}" r="{radius}" fill="{fill}" stroke="{border}"/>')


def tick(x, y, checked, size=20):
    box(x, y, size, size, '#111b24', '#b9a06d' if checked else '#526573', 4)
    if checked:
        svg.append(f'<path d="M{x+4} {y+size*.51} l{size*.23} {size*.23} l{size*.41} -{size*.48}" fill="none" stroke="#edcf8b" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"/>')


def button(x, y, width, height, title, kind='normal', size=17):
    colors = {
        'normal': ('#24323e', '#455764', '#c3cfd7'),
        'active': ('url(#active)', '#a58b59', '#eed6a1'),
        'primary': ('url(#cta)', '#e0c48b', '#1a2026'),
        'disabled': ('#26313a', '#46535b', '#78858d'),
        'leave': ('url(#leave)', '#86525b', '#e7c8cb'),
    }
    fill, stroke, foreground = colors[kind]
    box(x, y, width, height, fill, stroke, 6)
    text(x+width/2, y+height/2+size*.35, title, size, foreground,
         'bold' if kind in ('primary', 'active') else 'normal', 'middle')


# Outer presentation: no game art or external assets.
box(0, 0, W, H, 'url(#bg)')
text(43, 43, 'GUILD QUEUE', 17, '#d0b882', 'bold', spacing=2.8)
text(1638, 43, 'CONCEPT 02  /  CARD LAYOUT', 14, '#8797a5', anchor='end', spacing=1.4)
box(39, 78, 1602, 1018, '#080e14', '#070d13', 12, 3)
box(42, 74, 1596, 1018, 'url(#panel)', '#8b7954', 10, 2)
box(49, 81, 1582, 1004, 'none', '#454b4b', 6)
box(51, 83, 1578, 127, 'url(#head)', r=6)
line(51, 210, 1629, 210, '#746449')
# Original geometric emblem.
svg.append('<path d="M80 115 L106 106 L132 115 L130 146 Q127 166 106 179 Q85 166 82 146 Z" fill="#16232b" stroke="#c6ae77" stroke-width="2"/>')
svg.append('<path d="M95 129 L106 120 L117 129 L106 143 Z M95 150 L106 141 L117 150" fill="none" stroke="#c6ae77" stroke-width="2"/>')
text(154, 137, 'Guild Queue', 34, '#edd6a5', 'bold', serif=True)
text(155, 170, 'SILVER VANGUARD', 14, '#adb9bf', 'bold', spacing=1.8)
dot(159, 192, 4, '#8fc6a0')
text(173, 198, 'Guild members with the addon only', 15, '#a6b8c0')
# Queue counts: 2 groups of 5 plus 2 individuals.
for x, value, title in ((900, '12', 'QUEUED'), (1065, '2', 'GROUPS'), (1230, '2', 'UNMATCHED')):
    text(x, 138, value, 29, '#e8d2a4', 'bold', 'middle')
    text(x, 165, title, 11, '#97a9b6', anchor='middle', spacing=1.1)
box(1390, 121, 174, 42, '#203b31', '#496e57', 21)
dot(1412, 142, 4, '#9cccac')
text(1430, 148, 'Solo · queued', 16, '#b8dcc4')
box(1582, 98, 28, 28, '#322a2d', '#6f5b59', 4)
line(1591, 107, 1602, 118, '#d6c8bd', 2)
line(1602, 107, 1591, 118, '#d6c8bd', 2)

# Persistent, compact selection sidebar.
box(68, 235, 366, 805, '#15212b', '#3a4a55', 7)
text(91, 269, 'YOUR QUEUE', 14, '#cbb37e', 'bold', spacing=1.8)
text(91, 302, 'Play as', 22, '#e3e7e9', 'bold')
text(409, 300, 'Choose 1 or more', 12, '#91a4b2', anchor='end')
for x, title, selected, width in ((90, 'Tank', True, 93), (193, 'Healer', False, 101), (304, 'Damage', True, 107)):
    box(x, 320, width, 46, 'url(#active)' if selected else '#202e39', '#a38c5e' if selected else '#445665', 5)
    tick(x+10, 334, selected, 18)
    text(x+36, 350, title, 14, '#e6cb91' if selected else '#b5c2cc')
line(91, 390, 410, 390)
text(91, 427, 'Dungeons', 22, '#e3e7e9', 'bold')
box(318, 405, 94, 28, '#34382f', '#5d624e', 14)
text(365, 424, '3 selected', 12, '#dac493', anchor='middle')
text(91, 454, 'Match on a shared dungeon.', 14, '#91a4b2')
dungeons = [
    ('The Deadmines', True), ('Shadowfang Keep', True), ('Blackfathom Deeps', True),
    ('Wailing Caverns', False), ('The Stockade', False), ('Hall of Thanes', False),
    ('Ruins of Lordaeron', False), ('Excavation Site', False),
]
for i, (name, selected) in enumerate(dungeons):
    y = 475+i*46
    box(83, y, 324, 40, '#2a342f' if selected else ('#192732' if i%2 == 0 else '#15212b'), r=4)
    tick(95, y+10, selected)
    text(130, y+26, name, 16, '#e5d3a8' if selected else '#aebdc8')
box(417, 479, 4, 361, '#0e1921', r=2)
box(417, 482, 4, 88, '#62747b', r=2)
text(91, 870, 'Scroll for the full dungeon list', 12, '#8298a8')
button(91, 889, 154, 36, 'Select all', size=15)
button(256, 889, 154, 36, 'Clear', size=15)
button(91, 945, 319, 48, 'Leave queue', 'leave', 17)
text(250, 1017, 'Selections update while queued.', 12, '#8ba39c', anchor='middle')

# Right content tabs.
button(459, 235, 269, 48, 'Groups + individuals', 'active')
button(739, 235, 208, 48, 'All queued (12)')
dot(1461, 260, 4, '#8fc6a0')
text(1598, 266, 'Live guild queue', 14, '#9aafb9', anchor='end')

# Your own full-size group card. One explicit invitation action, no auto-party flow.
box(459, 304, 1153, 332, '#192833', '#a18a57', 8, 1.5)
box(460, 305, 1151, 95, '#2c352f', r=7)
box(459, 319, 4, 65, '#d6bc7b', r=2)
text(484, 336, 'YOUR SUGGESTED GROUP', 12, '#a9c4b2', 'bold', spacing=1.5)
text(484, 374, 'The Deadmines', 29, '#f0d9a7', 'bold', serif=True)
box(1407, 333, 176, 37, '#224034', '#4c735b', 18)
text(1495, 357, '5 / 5 matched', 16, '#bedec6', 'bold', 'middle')
text(484, 422, 'Common dungeons: The Deadmines · Shadowfang Keep', 15, '#a9bdc6')
players = [
    ('Arden', 'Tank', 'Tank / Damage', '#9fc8df', True),
    ('Elowen', 'Healer', 'Healer', '#acd3a0', False),
    ('Torren', 'Damage', 'Damage', '#d6ad91', False),
    ('Nym', 'Damage', 'Damage', '#d6ad91', False),
    ('Brann', 'Damage', 'Damage', '#d6ad91', False),
]
for i, (name, role, selected, tint, own) in enumerate(players):
    x, y = 484+i*220, 443
    box(x, y, 208, 113, '#253a33' if own else '#202f3b', '#688271' if own else '#3d5161', 6)
    dot(x+24, y+27, 13, '#16252e', '#5c7281')
    text(x+24, y+32, role[0], 12, tint, 'bold', 'middle')
    text(x+46, y+33, role, 16, tint, 'bold')
    text(x+14, y+68, name + (' (you)' if own else ''), 20, '#c2e5c8' if own else '#e0e7ec', 'bold')
    text(x+14, y+94, selected, 13, '#9fb3bf')
line(483, 572, 1586, 572)
text(484, 604, 'You + 4 guildmates. Everyone must accept their invitation.', 15, '#acbdc5')
svg.append('<g role="button" aria-label="Create party" aria-disabled="false">')
button(1341, 583, 245, 39, 'Create party', 'primary', 17)
svg.append('</g>')

# Another complete group is visible but has no Create party action for this viewer.
text(463, 678, 'Other suggested groups', 21, '#d3bea0', 'bold', serif=True)
box(459, 697, 1153, 150, '#182630', '#3d5260', 7)
text(484, 728, 'GROUP 2', 11, '#829dac', 'bold', spacing=1.5)
text(484, 761, 'Blackfathom Deeps', 23, '#d7dce0', 'bold', serif=True)
text(1585, 729, '5 / 5 matched', 15, '#a7c4af', anchor='end')
text(1585, 757, "You're not in this group", 13, '#8ba2b1', anchor='end')
other_players = [('Kael', 'Tank', '#9fc8df'), ('Mira', 'Healer', '#acd3a0'),
                 ('Vex', 'Damage', '#d6ad91'), ('Dorn', 'Damage', '#d6ad91'), ('Sable', 'Damage', '#d6ad91')]
for i, (name, role, tint) in enumerate(other_players):
    x = 484+i*220
    box(x, 782, 208, 46, '#21323f', r=5)
    text(x+12, 811, role[0], 14, tint, 'bold')
    text(x+39, 811, name, 17, '#c5d1db')

# Individual players remain separate and are not implicitly reserved.
text(463, 892, 'Unmatched individuals', 21, '#d3bea0', 'bold', serif=True)
text(1598, 890, '2 waiting for a compatible group', 14, '#8fa8b7', anchor='end')
for x, name, roles, choices in (
    (459, 'Helia', 'Healer / Damage', 'The Deadmines · Wailing Caverns'),
    (1045, 'Fen', 'Damage', 'Shadowfang Keep'),
):
    box(x, 912, 567, 103, '#182630', '#3b505f', 7)
    dot(x+28, 944, 13, '#263a47', '#586d7b')
    text(x+28, 949, name[0], 12, '#b4c4cd', 'bold', 'middle')
    text(x+52, 950, name, 19, '#d7e0e7', 'bold')
    text(x+542, 948, roles, 14, '#afbdc7', anchor='end')
    text(x+20, 987, choices, 15, '#90a9b8')

# Window footnote keeps the original no-automatic-party contract explicit.
line(68, 1040, 1612, 1040, '#445149')
box(88, 1054, 20, 20, '#2d3d35', '#687b62', 4)
text(98, 1069, 'i', 13, '#dfcb96', 'bold', 'middle')
text(122, 1070, 'Invitations are sent only when you click Create party. Leave the queue once your party is formed.', 16, '#bac9bf')

# A clearly separate state preview, not another actionable control in the window.
text(43, 1132, 'ALREADY GROUPED · HOVER PREVIEW', 12, '#9cabb8', 'bold', spacing=1.1)
svg.append('<g role="button" aria-label="Create party" aria-disabled="true">')
button(43, 1150, 248, 47, 'Create party', 'disabled', 17)
svg.append('</g>')
line(313, 1173, 360, 1173, '#788b97', 1.5)
line(352, 1166, 360, 1173, '#788b97', 1.5)
line(352, 1180, 360, 1173, '#788b97', 1.5)
box(382, 1114, 1230, 101, '#111c26', '#8c7c57', 7)
text(405, 1143, 'Create party', 17, '#dcc794', 'bold')
text(405, 1170, 'You are already in a party or raid.', 17, '#cdd6dc')
text(405, 1195, 'Leave your current group to create a new party.', 17, '#cdd6dc')
text(1588, 1142, 'ON HOVER', 11, '#8197a8', anchor='end', spacing=1.2)
text(43, 1251, 'Visual concept with sample data — not an in-game screenshot or a change to the addon layout.', 14, '#7d94a5')
text(1638, 1251, '/gq', 15, '#c7ad76', anchor='end')
svg.append('</svg>')
svg_path = OUT / f'{STEM}.svg'
png_path = OUT / f'{STEM}.png'
svg_path.write_text('\n'.join(svg), encoding='utf-8')

# Same installed rendering APIs used by the previous mockup generator.
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
handle = rsvg.rsvg_handle_new_from_file(str(svg_path).encode(), None)
assert handle, 'SVG could not be loaded'
surface = cairo.cairo_image_surface_create(0, W, H)
context = cairo.cairo_create(surface)
try:
    assert rsvg.rsvg_handle_render_cairo(handle, context), 'Rendering failed'
    assert cairo.cairo_surface_write_to_png(surface, str(png_path).encode()) == 0
finally:
    cairo.cairo_destroy(context)
    cairo.cairo_surface_destroy(surface)
    gobject.g_object_unref(handle)
print(f'Rendered {png_path.name}: {W} x {H}')
