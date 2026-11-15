"""Bottom-tab UI previews over the supplied native-WoW screenshot; no dependencies added."""
import argparse
from pathlib import Path
from html import escape
import base64
import ctypes as C
import ctypes.util
import struct
import xml.etree.ElementTree as ET

OUT = Path(__file__).parent
SOURCE = OUT.parent / 'docs/images/guild-queue.png'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('page', nargs='?', default='quests', choices=('dungeons', 'quests'))
page = parser.parse_args().page
STEM = f'GuildQueue-bottom-{page}-mockup'
W, H = 1652, 1290
GOLD, GRAY, WHITE = '#ffdf00', '#aaaaaa', '#f2f0ed'
png = SOURCE.read_bytes()
assert png[:8] == b'\x89PNG\r\n\x1a\n'
assert struct.unpack('>II', png[16:24]) == (1612, 1135)
payload = base64.b64encode(png).decode('ascii')
svg = [f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
       f'<title>Guild Queue — bottom tabs, {page.title()} page</title>',
       '<desc>Two bottom navigation tabs, Dungeons followed by Quests. Dungeons contains the queue and its filters; Quests uses the whole page for same-zone guildmates and shared quests. Illustrative data, not an in-game capture.</desc>',
       f'<defs><image id="screen" width="1612" height="1135" xlink:href="data:image/png;base64,{payload}"/>',
       f'<image id="auctionTabs" width="22" height="87" xlink:href="data:image/png;base64,{base64.b64encode((OUT / "assets/auction-house-tabs.png").read_bytes()).decode("ascii")}"/>',
       '<clipPath id="window"><rect x="12" y="12" width="1592" height="1114"/></clipPath>',
       '<clipPath id="belowFrame"><rect x="12" y="1124" width="1592" height="70"/></clipPath></defs>']


def box(x, y, w, h, fill, border='none', radius=0, stroke=1):
    svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}" stroke="{border}" rx="{radius}" stroke-width="{stroke}"/>')


def text(x, y, value, size=19, color=WHITE, anchor='start', bold=False):
    svg.append(f'<text x="{x}" y="{y}" fill="{color}" font-family="DejaVu Serif" font-size="{size}" font-weight="{"bold" if bold else "normal"}" text-anchor="{anchor}">{escape(value)}</text>')


def crop(x, y, w, h, sx, sy, sw, sh, image='screen'):
    svg.append(f'<svg x="{x}" y="{y}" width="{w}" height="{h}" viewBox="{sx} {sy} {sw} {sh}" preserveAspectRatio="none" overflow="hidden"><use xlink:href="#{image}"/></svg>')


def button(x, y, w, h, title, active=False):
    # Slice the existing native red button's blank edges/gradient, not its text.
    crop(x, y, 18, h, 780, 184, 18, 42)
    crop(x + 18, y, w - 36, h, 805, 184, 1, 42)
    crop(x + w - 18, y, 18, h, 1007, 184, 18, 42)
    if active:
        box(x + 6, y + 6, w - 12, h - 12, '#00000055', radius=2)
    text(x + w / 2, y + h / 2 + 7, title, 20, GOLD, 'middle')


def member(y, name, level, summary, quests=None):
    quests = quests or []
    height = 117 + len(quests) * 66
    box(41, y, 1509, height, '#070706', '#b7b7b7', 3, 1.3)
    box(43, y + 2, 1505, height - 4, 'none', '#33332f', 2, .65)
    text(59, y + 34, name, 22)
    text(1526, y + 32, f'Level {level}', 18, GRAY, 'end')
    text(59, y + 81, summary, 18, GRAY)
    if quests:
        button(1286, y + 54, 240, 42, 'Hide quests')
    for index, (title, ours, theirs) in enumerate(quests):
        qy = y + 114 + index * 66
        text(65, qy + 23, title, 21, GOLD)
        text(65, qy + 51, f'You: {ours}  |  Guildmate: {theirs}', 18, GRAY)
    return y + height + 18


def bottom_tab(x, title, selected, width):
    # Use only blank native tab-art strips from the supplied AH screenshot;
    # the original labels, chat, money and character information are not bundled.
    y, source_y, height = 1118, 0 if selected else 49, 49 if selected else 38
    crop(x, y, 10, height, 0, source_y, 10, height, 'auctionTabs')
    crop(x + 10, y, width - 21, height, 10, source_y, 1, height, 'auctionTabs')
    crop(x + width - 11, y, 11, height, 11, source_y, 11, height, 'auctionTabs')
    text(x + width / 2, y + (31 if selected else 24), title, 18, WHITE if selected else GOLD, 'middle')


# Preserve the actual native game border, sidebar, role icons and stock controls.
box(0, 0, W, H, '#141414')
svg.append('<g transform="translate(20 20)"><g clip-path="url(#window)"><use xlink:href="#screen"/>')
# Keep the original frame height; Auction House tabs hang underneath it.

# Update the screenshot's old three-counter header to the current four-counter one.
box(700, 51, 607, 96, '#050504')
for index, (number, caption) in enumerate((('1', 'QUEUED'), ('0', 'GROUPS'), ('1', 'UNMATCHED'), ('9', 'ADDON ONLINE'))):
    x = 14 + 1.5 * (18 + 452 + index * 94 + 45)
    text(x, 85, number, 26, GOLD, 'middle')
    text(x, 124, caption, 14, GRAY, 'middle')
box(59, 125, 638, 24, '#050504')
text(64, 142, 'Guild members with addon seen in the last 75 seconds', 15, GRAY)

if page == 'quests':
    # A full page replaces both the dungeon sidebar and its two queue-view filters.
    box(41, 181, 1538, 868, '#050503')
    text(44, 210, 'Questing in Duskwood', 23, GOLD)
    crop(41, 231, 34, 30, 60, 530, 34, 30)
    text(80, 254, 'Share my zone and active quests with my guild', 18, GOLD)
    text(44, 295, 'Guild roster zones can include members without this addon. Shared quest data expires after 75 seconds;', 16, GRAY)
    text(44, 319, 'same zone does not guarantee the same layer or phase.', 16, GRAY)
    next_y = member(347, 'Arden-CAMWOWEU5Realm4PvP', 26, '3 shared active quests', [
        ('The Night Watch', 'In progress', 'Ready to turn in'),
        ('Worgen in the Woods', 'In progress', 'In progress'),
        ('Raven Hill', 'Ready to turn in', 'In progress'),
    ])
    next_y = member(next_y, 'Elowen-CAMWOWEU5Realm4PvP', 28, '0 shared active quests')
    next_y = member(next_y, 'Torren-CAMWOWEU5Realm4PvP', 23, 'Quest data unavailable')
    assert next_y < 1049, 'Cards overflow the visible viewport'

svg.append('</g><g clip-path="url(#belowFrame)">')
bottom_tab(44, 'Dungeons', page == 'dungeons', 146)
bottom_tab(198, 'Quests', page == 'quests', 124)
svg.append('</g></g>')

# These are design previews, not actual in-game verification.
text(44, 1241, f'AUCTION HOUSE STYLE TABS / {page.upper()} / v0.7.1', 19, GOLD)
text(44, 1270, 'Tab art from your reference. Illustrative data and font/layout approximations; not an in-game capture.', 16, '#b8b8b8')
svg.append('</svg>')
svg_path, png_path = OUT / f'{STEM}.svg', OUT / f'{STEM}.png'
svg_path.write_text('\n'.join(svg), encoding='utf-8')
ET.parse(svg_path)

# Installed librsvg/Cairo, as used by the existing mockup generator.
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
