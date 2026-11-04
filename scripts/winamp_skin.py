import io
import zipfile
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from PIL import Image

OUT = Path(__file__).resolve().parent.parent / "assets" / "winamp" / "nari.wsz"

BODY = (222, 235, 251)
BODY_HI = (242, 247, 254)
BODY_LO = (199, 219, 244)
EDGE = (150, 181, 222)
NAVY = (17, 40, 83)
NAVY_HI = (40, 72, 134)
NAVY_LO = (9, 22, 48)
SCREEN = (8, 18, 40)
SCREEN_EDGE = (30, 56, 104)
TEXT = (232, 238, 251)
SOFT = (169, 190, 228)
DIM = (92, 116, 166)
ACCENT = (64, 172, 255)
ACCENT_HI = (150, 212, 255)
ACCENT_LO = (22, 72, 128)
INK = (17, 40, 83)

FONT = {
    "A": ".##./#..#/####/#..#/#..#", "B": "###./#..#/###./#..#/###.", "C": ".###/#.../#.../#.../.###",
    "D": "###./#..#/#..#/#..#/###.", "E": "####/#.../###./#.../####", "F": "####/#.../###./#.../#...",
    "G": ".###/#.../#.##/#..#/.###", "H": "#..#/#..#/####/#..#/#..#", "I": "###/.#./.#./.#./###",
    "J": "..##/...#/...#/#..#/.##.", "K": "#..#/#.#./##../#.#./#..#", "L": "#.../#.../#.../#.../####",
    "M": "#...#/##.##/#.#.#/#...#/#...#", "N": "#..#/##.#/#.##/#..#/#..#", "O": ".##./#..#/#..#/#..#/.##.",
    "P": "###./#..#/###./#.../#...", "Q": ".##./#..#/#..#/#.#./.#.#", "R": "###./#..#/###./#.#./#..#",
    "S": ".###/#.../.##./...#/###.", "T": "###/.#./.#./.#./.#.", "U": "#..#/#..#/#..#/#..#/.##.",
    "V": "#...#/#...#/.#.#./.#.#./..#..", "W": "#...#/#...#/#.#.#/##.##/#...#", "X": "#..#/#..#/.##./#..#/#..#",
    "Y": "#.#/#.#/.#./.#./.#.", "Z": "####/..#./.#../#.../####", '"': "#.#/#.#/.../.../...",
    "@": ".##./#.##/#.##/#.../.###", "0": ".##./#..#/#..#/#..#/.##.", "1": ".#./##./.#./.#./###",
    "2": "###./...#/.##./#.../####", "3": "###./...#/.##./...#/###.", "4": "#..#/#..#/####/...#/...#",
    "5": "####/#.../###./...#/###.", "6": ".##./#.../###./#..#/.##.", "7": "####/...#/..#./.#../.#..",
    "8": ".##./#..#/.##./#..#/.##.", "9": ".##./#..#/.###/...#/.##.", "…": "...../...../...../...../#.#.#",
    ".": "../../../../#.", ":": "./#/./#/.", "(": ".#/#./#./#./.#", ")": "#./.#/.#/.#/#.",
    "-": "..../..../.###/..../....", "'": "#/#/./././", "!": "#/#/#/./#", "_": "..../..../..../..../####",
    "+": "..../.#../###./.#../....", "\\": "#.../.#../.#../..#./...#", "/": "...#/..#./.#../.#../#...",
    "[": "##/#./#./#./##", "]": "##/.#/.#/.#/##", "^": ".#./#.#/.../.../...", "&": ".#../#.#./.#../#.#./.##.",
    "%": "#..#/...#/..#./.#../#..#", ",": "../../../.#/#.", "=": "..../####/..../####/....",
    "$": ".###/##../.##./..##/###.", "#": ".#.#/####/.#.#/####/.#.#", "Å": ".##./..../.##./#..#/####",
    "Ö": "#..#/..../.##./#..#/.##.", "Ä": "#..#/..../.##./####/#..#", "?": "###./...#/.##./..../.#..",
    "*": "..../#.#./.#../#.#./....",
}
ROWS = ["ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@", "0123456789….:()-'!_+\\/[]^&%,=$#", "ÅÖÄ?*"]
ICONS = {
    "previous": "#....#/#...##/#..###/#.####/#..###/#...##/#....#",
    "play": "##..../###.../####../#####./####../###.../##....",
    "pause": "##.##/##.##/##.##/##.##/##.##/##.##/##.##",
    "stop": "######/######/######/######/######/######",
    "next": "#....#/##...#/###..#/####.#/###..#/##...#/#....#",
    "eject": "...#.../..###../.#####./#######/......./#######",
    "close": "#...#/.#.#./..#../.#.#./#...#",
    "minimize": "...../...../...../...../#####",
    "shade": "#####/...../...../...../.....",
    "unshade": "...../...../#####/...../.....",
    "note": "..###/..#.#/..#../..#../###../###..",
}
MINI = {"previous": "#..#/#.##/####/#.##/#..#", "play": "#.../##../###./##../#...", "pause": "#.#/#.#/#.#/#.#/#.#",
        "stop": "###/###/###/###/###", "next": "#..#/##.#/####/##.#/#..#", "eject": ".#./###/.../###"}
PIXEL = {
    "A": ".###./#...#/#...#/#####/#...#/#...#/#...#", "B": "####./#...#/#...#/####./#...#/#...#/####.",
    "C": ".###./#...#/#..../#..../#..../#...#/.###.", "D": "####./#...#/#...#/#...#/#...#/#...#/####.",
    "E": "#####/#..../#..../####./#..../#..../#####", "F": "#####/#..../#..../####./#..../#..../#....",
    "G": ".###./#...#/#..../#.###/#...#/#...#/.####", "H": "#...#/#...#/#...#/#####/#...#/#...#/#...#",
    "I": "###/.#./.#./.#./.#./.#./###", "J": "..###/...#./...#./...#./...#./#..#./.##..",
    "K": "#...#/#..#./#.#../##.../#.#../#..#./#...#", "L": "#..../#..../#..../#..../#..../#..../#####",
    "M": "#...#/##.##/#.#.#/#.#.#/#...#/#...#/#...#", "N": "#...#/##..#/#.#.#/#..##/#...#/#...#/#...#",
    "O": ".###./#...#/#...#/#...#/#...#/#...#/.###.", "P": "####./#...#/#...#/####./#..../#..../#....",
    "Q": ".###./#...#/#...#/#...#/#.#.#/#..#./.##.#", "R": "####./#...#/#...#/####./#.#../#..#./#...#",
    "S": ".####/#..../#..../.###./....#/....#/####.", "T": "#####/..#../..#../..#../..#../..#../..#..",
    "U": "#...#/#...#/#...#/#...#/#...#/#...#/.###.", "V": "#...#/#...#/#...#/#...#/#...#/.#.#./..#..",
    "W": "#...#/#...#/#...#/#.#.#/#.#.#/#.#.#/.#.#.", "X": "#...#/#...#/.#.#./..#../.#.#./#...#/#...#",
    "Y": "#...#/#...#/.#.#./..#../..#../..#../..#..", "Z": "#####/....#/...#./..#../.#.../#..../#####",
    "a": "..../..../.##./...#/.###/#..#/.###", "b": "#.../#.../###./#..#/#..#/#..#/###.",
    "c": "..../..../.###/#.../#.../#.../.###", "d": "...#/...#/.###/#..#/#..#/#..#/.###",
    "e": "..../..../.##./#..#/####/#.../.###", "f": ".##/#../###/#../#../#../#..",
    "g": "..../..../.###/#..#/#..#/#..#/.###/...#/.##.", "h": "#.../#.../###./#..#/#..#/#..#/#..#",
    "i": "#/./#/#/#/#/#", "j": ".#/../.#/.#/.#/.#/.#/.#/#.", "k": "#.../#.../#..#/#.#./##../#.#./#..#",
    "l": "#./#./#./#./#./#./.#", "m": "...../...../####./#.#.#/#.#.#/#.#.#/#.#.#",
    "n": "..../..../###./#..#/#..#/#..#/#..#", "o": "..../..../.##./#..#/#..#/#..#/.##.",
    "p": "..../..../###./#..#/#..#/#..#/###./#.../#...", "q": "..../..../.###/#..#/#..#/#..#/.###/...#/...#",
    "r": "..../..../#.##/##../#.../#.../#...", "s": "..../..../.###/#.../.##./...#/###.",
    "t": ".#../.#../####/.#../.#../.#../..##", "u": "..../..../#..#/#..#/#..#/#..#/.###",
    "v": "...../...../#...#/#...#/.#.#./.#.#./..#..", "w": "...../...../#...#/#.#.#/#.#.#/#.#.#/.#.#.",
    "x": "..../..../#..#/#..#/.##./#..#/#..#", "y": "..../..../#..#/#..#/#..#/#..#/.###/...#/.##.",
    "z": "..../..../####/..#./.#../#.../####",
    "0": ".###./#...#/#..##/#.#.#/##..#/#...#/.###.", "1": "..#../.##../..#../..#../..#../..#../.###.",
    "2": ".###./#...#/....#/...#./..#../.#.../#####", "3": "#####/...#./..#../...#./....#/#...#/.###.",
    "4": "...#./..##./.#.#./#..#./#####/...#./...#.", "5": "#####/#..../####./....#/....#/#...#/.###.",
    "6": "..##./.#.../#..../####./#...#/#...#/.###.", "7": "#####/....#/...#./..#../.#.../.#.../.#...",
    "8": ".###./#...#/#...#/.###./#...#/#...#/.###.", "9": ".###./#...#/#...#/.####/....#/...#./.##..",
    "!": "#/#/#/#/#/./#", '"': "#.#/#.#", "#": "...../.#.#./#####/.#.#./#####/.#.#.",
    "$": "..#../.####/#.#../.###./..#.#/####./..#..", "%": "##..#/##.#./...#./..#../.#.../.#.##/#..##",
    "&": ".##../#..#./#.#../.#.../#.#.#/#..#./.##.#", "'": "#/#", "(": ".#/#./#./#./#./#./.#",
    ")": "#./.#/.#/.#/.#/.#/#.", "*": "...../..#../#.#.#/.###./#.#.#/..#..", "+": "...../..#../..#../#####/..#../..#..",
    ",": "../../../../../.#/.#/#.", "-": "..../..../..../####", ".": "././././././#",
    "/": "....#/...#./...#./..#../.#.../.#.../#....", ":": "././#/./././#", ";": "../../.#/../../.#/.#/#.",
    "<": "...#/..#./.#../#.../.#../..#./...#", "=": "..../..../####/..../####", ">": "#.../.#../..#./...#/..#./.#../#...",
    "?": ".###./#...#/....#/...#./..#../...../..#..", "@": ".###./#...#/#.###/#.#.#/#.###/#..../.###.",
    "[": "##/#./#./#./#./#./##", "\\": "#..../.#.../.#.../..#../...#./...#./....#", "]": "##/.#/.#/.#/.#/.#/##",
    "^": "..#../.#.#./#...#", "_": "..../..../..../..../..../..../####", "`": "#./.#",
    "{": "..#/.#./.#./#../.#./.#./..#", "|": "#/#/#/#/#/#/#", "}": "#../.#./.#./..#/.#./.#./#..",
    "~": "...../...../.#..#/#.#.#/#..#.",
}
ACCENTS = {"´": "..#/.#.", "`": "#../.#.", "~": ".#.#/#.#.", "¨": "#.#", "^": ".#./#.#"}
MARKED = {"á": "a´", "é": "e´", "í": "i´", "ó": "o´", "ú": "u´", "à": "a`", "è": "e`", "ì": "i`", "ò": "o`", "ù": "u`",
          "ñ": "n~", "ã": "a~", "õ": "o~", "ä": "a¨", "ë": "e¨", "ï": "i¨", "ö": "o¨", "ü": "u¨", "â": "a^", "ê": "e^",
          "î": "i^", "ô": "o^", "û": "u^"}
CAPITALS = {"Á": "A", "É": "E", "Í": "I", "Ó": "O", "Ú": "U", "À": "A", "È": "E", "Ì": "I", "Ò": "O", "Ù": "U",
            "Ñ": "N", "Ä": "A", "Ë": "E", "Ï": "I", "Ö": "O", "Ü": "U", "Ç": "C", "ç": "c"}
SEGMENTS = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F]


class Sheet:
    def __init__(self, width, height, fill=BODY):
        self.image = Image.new("RGB", (width, height), fill)
        self.pixels = self.image.load()

    def put(self, x, y, color):
        if 0 <= x < self.image.width and 0 <= y < self.image.height:
            self.pixels[x, y] = color

    def rect(self, x, y, width, height, color):
        for py in range(y, y + height):
            for px in range(x, x + width):
                self.put(px, py, color)

    def outline(self, x, y, width, height, color):
        self.rect(x, y, width, 1, color)
        self.rect(x, y + height - 1, width, 1, color)
        self.rect(x, y, 1, height, color)
        self.rect(x + width - 1, y, 1, height, color)

    def round(self, x, y, width, height, fill, light=None, dark=None, behind=None):
        self.rect(x, y, width, height, fill)
        if light:
            self.rect(x + 1, y, width - 2, 1, light)
            self.rect(x, y + 1, 1, height - 2, light)
        if dark:
            self.rect(x + 1, y + height - 1, width - 2, 1, dark)
            self.rect(x + width - 1, y + 1, 1, height - 2, dark)
        if behind:
            for cx, cy in ((x, y), (x + width - 1, y), (x, y + height - 1), (x + width - 1, y + height - 1)):
                self.put(cx, cy, behind)

    def gradient(self, x, y, width, height, top, bottom):
        for row in range(height):
            t = row / max(height - 1, 1)
            self.rect(x, y + row, width, 1, tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))

    def art(self, x, y, rows, color):
        for dy, row in enumerate(rows.split("/")):
            for dx, cell in enumerate(row):
                if cell == "#":
                    self.put(x + dx, y + dy, color)

    def centred(self, x, y, width, height, rows, color, shift=0):
        lines = rows.split("/")
        self.art(x + (width - max(map(len, lines))) // 2 + shift, y + (height - len(lines)) // 2 + shift, rows, color)

    def text(self, x, y, value, color):
        for character in value:
            rows = FONT.get(character, "")
            self.art(x, y, rows, color)
            x += (max(map(len, rows.split("/"))) if rows else 3) + 1

    def text_centred(self, x, y, width, height, value, color, shift=0):
        size = sum((max(map(len, FONT[c].split("/"))) if c in FONT else 3) + 1 for c in value) - 1
        self.text(x + (width - size) // 2 + shift, y + (height - 5) // 2 + shift, value, color)

    def bmp(self):
        out = io.BytesIO()
        self.image.save(out, "BMP")
        return out.getvalue()


def body(sheet, x, y, width, height):
    sheet.gradient(x, y, width, height, BODY_HI, BODY_LO)
    sheet.outline(x, y, width, height, EDGE)


def screen(sheet, x, y, width, height, behind=BODY):
    sheet.round(x, y, width, height, SCREEN, None, None, behind)
    sheet.rect(x + 1, y, width - 2, 1, SCREEN_EDGE)


def button(sheet, x, y, width, height, pressed, icon=None, label=None, on=False, behind=BODY):
    fill, light, dark = (ACCENT_LO, NAVY_LO, NAVY_HI) if pressed else (NAVY, NAVY_HI, NAVY_LO)
    sheet.round(x, y, width, height, fill, light, dark, behind)
    color = ACCENT if on or pressed else TEXT if icon else SOFT
    if icon:
        sheet.centred(x, y, width, height, ICONS[icon], color, 1 if pressed else 0)
    if label:
        sheet.text_centred(x, y, width, height, label, color, 1 if pressed else 0)


def thumb(sheet, x, y, width, height, pressed, behind=BODY):
    fill, light, dark = (ACCENT, ACCENT_HI, ACCENT_LO) if pressed else (TEXT, (255, 255, 255), SOFT)
    sheet.round(x, y, width, height, fill, light, dark, behind)
    sheet.rect(x + width // 2, y + 2, 1, height - 4, ACCENT_LO if pressed else DIM)


def track(sheet, x, y, width, height, filled=0, centre=None):
    sheet.round(x, y, width, height, SCREEN, None, None, BODY)
    middle = y + height // 2 - 1
    sheet.rect(x + 2, middle, width - 4, 3, NAVY_HI)
    if centre is None and filled:
        sheet.rect(x + 2, middle, filled, 3, ACCENT)
    elif centre is not None:
        sheet.rect(centre - filled, middle, 2 * filled + 1, 3, ACCENT)


def title(sheet, x, y, width, label, active, shade=False):
    sheet.round(x, y, width, 14, NAVY if active else NAVY_LO, NAVY_HI if active else None, NAVY_LO, BODY)
    color = TEXT if active else DIM
    if shade:
        sheet.text(x + 20, y + 4, label, color)
        return
    size = sum(max(map(len, FONT[c].split("/"))) + 1 for c in label if c in FONT) + 3 * label.count(" ") - 1
    start = x + (width - size) // 2
    sheet.text(start, y + 4, label, color)
    for left, right in ((x + 18, start - 6), (start + size + 6, x + width - 34)):
        if right > left:
            sheet.rect(left, y + 5, right - left, 1, ACCENT if active else DIM)
            sheet.rect(left, y + 8, right - left, 1, NAVY_HI if active else NAVY)


def small(sheet, x, y, icon, pressed, behind=NAVY):
    sheet.round(x, y, 9, 9, ACCENT_LO if pressed else NAVY_HI, None, None, behind)
    sheet.centred(x, y, 9, 9, ICONS[icon], ACCENT if pressed else TEXT)


def logo(sheet, x, y, width, height, pressed=False):
    sheet.round(x, y, width, height, ACCENT_LO if pressed else ACCENT, ACCENT_HI, ACCENT_LO, BODY)
    sheet.centred(x, y, width, height, ICONS["note"], TEXT)


def main():
    s = Sheet(275, 116)
    body(s, 0, 0, 275, 116)
    screen(s, 9, 21, 95, 46)
    screen(s, 106, 21, 165, 35)
    s.text(128, 43, "KBPS", DIM)
    s.text(168, 43, "KHZ", DIM)
    s.rect(72, 29, 2, 2, ACCENT)
    s.rect(72, 34, 2, 2, ACCENT)
    logo(s, 253, 91, 13, 15)
    return s


def titlebar():
    s = Sheet(344, 87, NAVY)
    for y, active, shade in ((0, True, False), (15, False, False), (29, True, True), (42, False, True), (57, True, False), (72, False, False)):
        title(s, 27, y, 275, "NARI", active, shade)
        behind = NAVY if active else NAVY_LO
        s.round(27 + 6, y + 3, 9, 9, ACCENT if active else NAVY_HI, None, None, behind)
        s.centred(27 + 6, y + 3, 9, 9, "..#/.##/#.#/#..", TEXT)
        for x, icon in ((244, "minimize"), (254, "unshade" if shade else "shade"), (264, "close")):
            small(s, 27 + x, y + 3, icon, False, behind)
        if shade:
            for gx, width, icon in ((169, 7, "previous"), (176, 10, "play"), (186, 9, "pause"), (195, 9, "stop"), (204, 10, "next"), (215, 10, "eject")):
                s.centred(27 + gx, y + 2, width, 10, MINI[icon], SOFT)
            screen(s, 27 + 124, y + 2, 36, 10, NAVY)
            screen(s, 27 + 226, y + 4, 17, 7, NAVY)
    for y, pressed in ((0, False), (9, True)):
        s.round(0, y, 9, 9, ACCENT_LO if pressed else ACCENT, None, None, NAVY)
        s.centred(0, y, 9, 9, "..#/.##/#.#/#..", TEXT)
    for x, y, icon, pressed in ((9, 0, "minimize", False), (9, 9, "minimize", True), (0, 18, "shade", False), (9, 18, "shade", True), (18, 0, "close", False), (18, 9, "close", True), (0, 27, "unshade", False), (9, 27, "unshade", True)):
        small(s, x, y, icon, pressed)
    screen(s, 0, 36, 17, 7, NAVY)
    s.rect(17, 36, 3, 7, SOFT)
    s.rect(20, 36, 3, 7, ACCENT)
    s.rect(23, 36, 3, 7, SOFT)
    letters = (("O", 3), ("A", 11), ("I", 18), ("D", 25), ("V", 33))
    for x, color in ((304, SOFT), (312, DIM)):
        s.rect(x, 0, 8, 43, SCREEN)
        for letter, y in letters:
            s.centred(x, y, 8, 7, FONT[letter], color)
    for (letter, _), (x, y, height) in zip(letters, ((304, 47, 8), (312, 55, 7), (320, 62, 7), (328, 69, 8), (336, 77, 7))):
        s.rect(x, y, 8, height, SCREEN)
        s.centred(x, y, 8, height, FONT[letter], ACCENT)
    return s


def cbuttons():
    s = Sheet(136, 36)
    for x, width, height, icon in ((0, 23, 18, "previous"), (23, 23, 18, "play"), (46, 23, 18, "pause"), (69, 23, 18, "stop"), (92, 22, 18, "next"), (114, 22, 16, "eject")):
        button(s, x, 0, width, height, False, icon)
        button(s, x, height, width, height, True, icon)
    return s


def shufrep():
    s = Sheet(92, 85)
    for row, (pressed, on) in enumerate(((False, False), (True, False), (False, True), (True, True))):
        button(s, 0, 15 * row, 28, 15, pressed, None, "REP", on)
        button(s, 28, 15 * row, 47, 15, pressed, None, "SHUFFLE", on)
    for x, pressed in ((0, False), (46, True)):
        for y, on in ((61, False), (73, True)):
            button(s, x, y, 23, 12, pressed, None, "EQ", on)
            button(s, x + 23, y, 23, 12, pressed, None, "PL", on)
    return s


def posbar():
    s = Sheet(307, 10)
    track(s, 0, 0, 248, 10)
    thumb(s, 248, 0, 29, 10, False)
    thumb(s, 278, 0, 29, 10, True)
    return s


def volume():
    s = Sheet(68, 433)
    for frame in range(28):
        track(s, 0, 15 * frame, 68, 13, 64 * frame // 27)
    thumb(s, 15, 422, 14, 11, False)
    thumb(s, 0, 422, 14, 11, True)
    return s


def balance():
    s = Sheet(47, 433)
    for frame in range(28):
        track(s, 9, 15 * frame, 38, 13, 16 * frame // 27, 9 + 19)
    thumb(s, 15, 422, 14, 11, False)
    thumb(s, 0, 422, 14, 11, True)
    return s


def monoster():
    s = Sheet(56, 24, SCREEN)
    for y, color in ((0, ACCENT), (12, NAVY_HI)):
        s.text_centred(0, y, 29, 12, "STEREO", color)
        s.text_centred(29, y, 27, 12, "MONO", color)
    return s


def playpaus():
    s = Sheet(42, 9, SCREEN)
    s.art(2, 1, "#..../##.../###../####./###../##.../#....", ACCENT)
    s.art(11, 1, "##.##/##.##/##.##/##.##/##.##/##.##/##.##", ACCENT)
    s.rect(19, 1, 7, 7, ACCENT)
    s.rect(39, 3, 3, 3, ACCENT)
    return s


def digit(s, x, mask):
    bars = ((1, 0, 7, 2), (7, 1, 2, 5), (7, 7, 2, 5), (1, 11, 7, 2), (0, 7, 2, 5), (0, 1, 2, 5), (1, 5, 7, 2))
    for bit, (bx, by, width, height) in enumerate(bars):
        if mask & (1 << bit):
            s.rect(x + bx, by, width, height, TEXT)


def numbers(extended):
    s = Sheet(108 if extended else 99, 13, SCREEN)
    for value, mask in enumerate(SEGMENTS):
        digit(s, 9 * value, mask)
    if extended:
        digit(s, 99, 0x40)
    return s


def text():
    s = Sheet(155, 18, SCREEN)
    for row, cells in enumerate(ROWS):
        for column, character in enumerate(cells):
            s.art(5 * column, 6 * row, FONT[character], ACCENT_HI)
    return s


def pledit():
    s = Sheet(280, 186, NAVY)
    for y, active in ((0, True), (21, False)):
        s.rect(0, y, 178, 20, NAVY if active else NAVY_LO)
        s.rect(0, y, 178, 1, NAVY_HI if active else NAVY)
        s.rect(0, y + 19, 178, 1, NAVY_LO)
        s.text_centred(26, y, 100, 20, "PLAYLIST", TEXT if active else DIM)
        for left, right in ((4, 25), (26, 46), (106, 126), (127, 152), (153, 168)):
            s.rect(left, y + 8, right - left, 1, ACCENT if active else DIM)
            s.rect(left, y + 11, right - left, 1, NAVY_HI if active else NAVY)
        small(s, 157, y + 3, "shade", False, NAVY if active else NAVY_LO)
        small(s, 167, y + 3, "close", False, NAVY if active else NAVY_LO)
    s.rect(0, 42, 12, 29, NAVY)
    s.rect(11, 42, 1, 29, NAVY_HI)
    s.rect(31, 42, 20, 29, NAVY)
    s.rect(31, 42, 1, 29, NAVY_HI)
    s.rect(36, 42, 8, 29, NAVY_LO)
    for x, icon in ((52, "close"), (62, "shade"), (150, "unshade")):
        small(s, x, 42, icon, True)
    thumb(s, 52, 53, 8, 18, False, NAVY)
    thumb(s, 61, 53, 8, 18, True, NAVY)
    for x, y, width, active in ((72, 42, 25, True), (72, 57, 25, False), (99, 57, 50, False), (99, 42, 50, True)):
        s.rect(x, y, width, 14, NAVY if active else NAVY_LO)
        s.rect(x, y, width, 1, NAVY_HI if active else NAVY)
    for y, active in ((42, True), (57, False)):
        small(s, 128, y + 3, "unshade", False, NAVY if active else NAVY_LO)
        small(s, 138, y + 3, "close", False, NAVY if active else NAVY_LO)
    s.rect(0, 72, 276, 38, NAVY)
    s.rect(0, 72, 276, 1, NAVY_HI)
    for x, label in ((14, "ADD"), (43, "REM"), (72, "SEL"), (101, "MISC")):
        button(s, x, 80, 22, 18, False, None, label, False, NAVY)
    screen(s, 130, 78, 64, 12, NAVY)
    for index, icon in enumerate(("previous", "play", "pause", "stop", "next", "eject")):
        s.centred(129 + 10 * index, 94, 10, 10, MINI[icon], SOFT)
    screen(s, 189, 93, 27, 12, NAVY)
    button(s, 231, 80, 22, 18, False, None, None, False, NAVY)
    s.text(233, 83, "LIST", SOFT)
    s.text(233, 90, "OPTS", SOFT)
    for dy in range(9):
        for dx in range(9):
            if dx + dy >= 8 and (dx + dy) % 3 == 2:
                s.put(265 + dx, 99 + dy, SOFT)
    s.rect(179, 0, 25, 38, NAVY)
    screen(s, 205, 0, 75, 38, NAVY)
    return s


def eqmain():
    s = Sheet(275, 315)
    body(s, 0, 0, 275, 116)
    s.text(44, 39, "+12DB", INK)
    s.text(48, 67, "+0DB", INK)
    s.text(44, 96, "-12DB", INK)
    s.text(8, 104, "PREAMP", INK)
    for band, label in enumerate(("60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K")):
        size = sum(max(map(len, FONT[c].split("/"))) + 1 for c in label) - 1
        s.text(78 + 18 * band + 7 - size // 2, 104, label, INK)
    screen(s, 84, 16, 117, 22)
    for y, active in ((134, True), (149, False)):
        title(s, 0, y, 275, "EQUALIZER", active)
        small(s, 254, y + 3, "shade", False, NAVY if active else NAVY_LO)
        small(s, 264, y + 3, "close", False, NAVY if active else NAVY_LO)
    small(s, 0, 116, "close", False, BODY)
    small(s, 0, 125, "close", True, BODY)
    for x, pressed, on in ((10, False, False), (69, False, True), (128, True, False), (187, True, True)):
        button(s, x, 119, 26, 12, pressed, None, "ON", on)
        button(s, x + 26, 119, 32, 12, pressed, None, "AUTO", on)
    for frame in range(28):
        x, y = 13 + (frame % 14) * 15, 164 + (frame // 14) * 65
        s.round(x, y, 14, 63, SCREEN, None, None, BODY)
        s.rect(x + 6, y + 3, 2, 57, NAVY_HI)
        level = 3 + round((27 - frame) * 54 / 27)
        top, bottom = sorted((level, 31))
        s.rect(x + 6, y + top, 2, bottom - top + 1, ACCENT)
    thumb(s, 0, 164, 11, 11, False)
    thumb(s, 0, 176, 11, 11, True)
    button(s, 224, 164, 44, 12, False, None, "PRESETS")
    button(s, 224, 176, 44, 12, True, None, "PRESETS", True)
    s.rect(0, 294, 113, 19, SCREEN)
    s.rect(0, 303, 113, 1, NAVY_HI)
    for row in range(19):
        t = abs(row - 9) / 9
        s.put(115, 294 + row, tuple(round(a + (b - a) * t) for a, b in zip(ACCENT_HI, ACCENT)))
    s.rect(0, 314, 113, 1, SOFT)
    return s


def eq_ex():
    s = Sheet(275, 56, NAVY)
    for y, active in ((0, True), (15, False)):
        title(s, 0, y, 275, "EQUALIZER", active, True)
        for x, width in ((61, 97), (164, 43)):
            screen(s, x, y + 3, width, 9, NAVY)
            s.rect(x + 2, y + 7, width - 4, 1, NAVY_HI)
        small(s, 254, y + 3, "unshade", False, NAVY if active else NAVY_LO)
        small(s, 264, y + 3, "close", False, NAVY if active else NAVY_LO)
    for index, x in enumerate((1, 4, 7, 11, 14, 17)):
        s.rect(x, 30, 3, 7, ACCENT if index in (2, 3, 5) else SOFT)
    for x, y, icon, pressed in ((1, 38, "shade", True), (1, 47, "unshade", True), (11, 38, "close", False), (11, 47, "close", True)):
        small(s, x, y, icon, pressed)
    return s


def gen():
    divider = (0, 198, 255)
    s = Sheet(194, 109, divider)
    for row, active in ((0, True), (21, False)):
        for tile in range(6):
            x = 26 * tile
            s.rect(x, row, 25, 20, NAVY if active else NAVY_LO)
            s.rect(x, row, 25, 1, NAVY_HI if active else NAVY)
            s.rect(x, row + 19, 25, 1, NAVY_LO)
            if tile not in (1, 2, 3):
                width = 12 if tile == 5 else 25
                s.rect(x, row + 8, width, 1, ACCENT if active else DIM)
                s.rect(x, row + 11, width, 1, NAVY_HI if active else NAVY)
        small(s, 130 + 14, row + 3, "close", False, NAVY if active else NAVY_LO)
    for x, y, width, height in ((0, 42, 125, 14), (0, 57, 125, 14), (127, 72, 25, 14)):
        s.rect(x, y, width, height, NAVY)
        s.rect(x, y + height - 1, width, 1, NAVY_LO)
    for x, y, width, height in ((127, 42, 11, 29), (139, 42, 8, 29), (158, 42, 11, 24), (170, 42, 8, 24)):
        s.rect(x, y, width, height, NAVY)
    for x, height in ((137, 29), (168, 24), (139, 29), (170, 24)):
        s.rect(x, 42, 1, height, NAVY_HI)
    small(s, 148, 42, "close", True)
    for step in range(3):
        s.rect(106 + 4 * step, 67 - 3 * step, 3 * (3 - step) + 1, 1, SOFT)
    for y, color, fill in ((88, TEXT, NAVY), (96, DIM, NAVY_LO)):
        for index, letter in enumerate("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):
            x = 1 + 7 * index
            s.rect(x, y, 6, 7, fill)
            s.art(x + (6 - max(map(len, FONT[letter].split("/")))) // 2, y + 1, FONT[letter], color)
    return s


def genex():
    s = Sheet(130, 75, NAVY)
    for index, color in enumerate((SCREEN, TEXT, SCREEN, TEXT, TEXT, NAVY_HI, ACCENT, NAVY, TEXT)):
        s.put(48 + 2 * index, 0, color)
    return s


def viscolor():
    colors = [SCREEN, SCREEN_EDGE]
    for band in range(16):
        t = band / 15
        colors.append(tuple(round(a + (b - a) * t) for a, b in zip(ACCENT_HI, ACCENT_LO)))
    colors += [TEXT, ACCENT_HI, ACCENT, ACCENT, ACCENT_LO, TEXT]
    return "\r\n".join(",".join(map(str, color)) for color in colors) + "\r\n"


def marked(base, accent):
    rows = PIXEL[base].split("/")
    width = max(map(len, rows))
    mark = [row.center(width, ".")[:width] for row in ACCENTS[accent].split("/")]
    return "/".join(["." * width] * (2 - len(mark)) + mark + rows[2:])


def pixel_font():
    glyphs = dict(PIXEL)
    for character, (base, accent) in MARKED.items():
        glyphs[character] = marked(base, accent)
    for character, base in CAPITALS.items():
        glyphs[character] = PIXEL[base]
    unit, names, charmap, outlines, metrics = 100, [".notdef", "space"], {32: "space"}, {}, {".notdef": (400, 0), "space": (300, 0)}
    outlines[".notdef"] = TTGlyphPen(None).glyph()
    outlines["space"] = TTGlyphPen(None).glyph()
    for character, art in glyphs.items():
        name = f"uni{ord(character):04X}"
        pen = TTGlyphPen(None)
        rows = art.split("/")
        for row, cells in enumerate(rows):
            column = 0
            while column < len(cells):
                if cells[column] != "#":
                    column += 1
                    continue
                end = column
                while end < len(cells) and cells[end] == "#":
                    end += 1
                top, bottom = (7 - row) * unit, (6 - row) * unit
                pen.moveTo((column * unit, bottom))
                pen.lineTo((column * unit, top))
                pen.lineTo((end * unit, top))
                pen.lineTo((end * unit, bottom))
                pen.closePath()
                column = end
        names.append(name)
        charmap[ord(character)] = name
        outlines[name] = pen.glyph()
        metrics[name] = ((max(map(len, rows)) + 1) * unit, 0)
    builder = FontBuilder(1000, isTTF=True)
    builder.setupGlyphOrder(names)
    builder.setupCharacterMap(charmap)
    builder.setupGlyf(outlines)
    builder.setupHorizontalMetrics(metrics)
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupNameTable({"familyName": "Nari Pixel", "styleName": "Regular"})
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    builder.setupPost()
    out = io.BytesIO()
    builder.save(out)
    return out.getvalue()


def build():
    sheets = {"main": main(), "titlebar": titlebar(), "cbuttons": cbuttons(), "shufrep": shufrep(), "posbar": posbar(),
              "volume": volume(), "balance": balance(), "monoster": monoster(), "playpaus": playpaus(),
              "numbers": numbers(False), "nums_ex": numbers(True), "text": text(), "pledit": pledit(),
              "eqmain": eqmain(), "eq_ex": eq_ex(), "gen": gen(), "genex": genex()}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, sheet in sheets.items():
            archive.writestr(zipfile.ZipInfo(f"{name}.bmp", (1980, 1, 1, 0, 0, 0)), sheet.bmp())
        archive.writestr(zipfile.ZipInfo("nari_pixel.ttf", (1980, 1, 1, 0, 0, 0)), pixel_font())
        archive.writestr(zipfile.ZipInfo("pledit.txt", (1980, 1, 1, 0, 0, 0)),
                         "[Text]\r\nNormal=#A9BEE4\r\nCurrent=#FFFFFF\r\nNormalBG=#081228\r\nSelectedBG=#1C4880\r\nFont=Nari Pixel\r\n")
        archive.writestr(zipfile.ZipInfo("viscolor.txt", (1980, 1, 1, 0, 0, 0)), viscolor())
    print(OUT)


if __name__ == "__main__":
    build()
