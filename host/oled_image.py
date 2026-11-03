"""A picture -> the 1024-byte page map an SSD1306 wants -> the RTL that holds it.

The panel stores one byte per column per page, and **bit 0 of that byte is the
top pixel** of the page's eight rows.  Getting that wrong is not a blank
screen: it is an image that is vertically mirrored inside every 8-pixel band,
which looks like a wiring fault and wastes a build.  So the packing is defined
once, here, tested bit by bit, and the RTL is generated from the same bytes the
test checks.

Two outputs from one frame:

* ``.mem`` -- 1024 lines of ``hh``, for a preview or for a ROM IP flow;
* ``v2_oled_image.sv`` -- the framebuffer as an inferred block RAM initialised
  in an ``initial`` block, so the image costs one BSRAM and no LUTs.

The input is a PGM (P5, standard library only) or any format Pillow can read.
The image is placed at the top left and cropped or padded, never rescaled: a
logo drawn at 1:1 is what the panel is for.
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

WIDTH = 128
HEIGHT = 64
PAGE_ROWS = 8
PAGES = HEIGHT // PAGE_ROWS
SIZE = WIDTH * PAGES          # 1024 bytes
THRESHOLD = 128               # grey >= this is ink
DEFAULT_MEM = Path("artifacts/oled/logo.mem")
DEFAULT_RTL = Path("rtl/v2_oled_image.sv")


# --------------------------------------------------------------------- packing


def blank() -> list[int]:
    """A dark frame: 1024 zero bytes."""
    return [0] * SIZE


def from_rows(rows) -> list[int]:
    """Pack ``rows[y][x]`` (64 x 128, 0/1) into the panel's page order."""
    if len(rows) != HEIGHT:
        raise ValueError("expected %d rows, got %d" % (HEIGHT, len(rows)))
    frame = blank()
    for page in range(PAGES):
        base = page * PAGE_ROWS
        for col in range(WIDTH):
            byte = 0
            for bit in range(PAGE_ROWS):
                row = rows[base + bit]
                if len(row) != WIDTH:
                    raise ValueError("row %d has %d columns, want %d"
                                     % (base + bit, len(row), WIDTH))
                if row[col]:
                    byte |= 1 << bit
            frame[page * WIDTH + col] = byte
    return frame


def to_rows(frame) -> list[list[int]]:
    """The inverse of :func:`from_rows`, so a frame can be looked at."""
    if len(frame) != SIZE:
        raise ValueError("expected %d bytes, got %d" % (SIZE, len(frame)))
    rows = [[0] * WIDTH for _ in range(HEIGHT)]
    for page in range(PAGES):
        for col in range(WIDTH):
            byte = frame[page * WIDTH + col]
            for bit in range(PAGE_ROWS):
                rows[page * PAGE_ROWS + bit][col] = (byte >> bit) & 1
    return rows


def to_bytes(frame) -> bytes:
    """The frame as the 1024 bytes that go to the panel, in send order."""
    if len(frame) != SIZE:
        raise ValueError("expected %d bytes, got %d" % (SIZE, len(frame)))
    if any(not 0 <= value <= 0xFF for value in frame):
        raise ValueError("a frame byte must be 0..255")
    return bytes(frame)


def preview(frame, ink: str = "#", paper: str = ".") -> str:
    """64 rows of 128 characters: the image as it will look, for a human."""
    return "\n".join("".join(ink if pixel else paper for pixel in row)
                     for row in to_rows(frame))


# --------------------------------------------------------------------- loading


def resize_pad(rows) -> list[list[int]]:
    """Place an image at the top left of a 128x64 dark canvas, crop if larger."""
    out = [[0] * WIDTH for _ in range(HEIGHT)]
    for y in range(min(HEIGHT, len(rows))):
        row = rows[y]
        for x in range(min(WIDTH, len(row))):
            out[y][x] = 1 if row[x] else 0
    return out


def read_pgm(path) -> list[list[int]]:
    """A binary PGM (P5), maxval <= 255.  Comments start with '#'."""
    raw = Path(path).read_bytes()
    tokens: list[bytes] = []
    index = 0
    while len(tokens) < 4:
        while index < len(raw) and raw[index:index + 1].isspace():
            index += 1
        if index < len(raw) and raw[index:index + 1] == b"#":
            while index < len(raw) and raw[index:index + 1] not in (b"\n", b"\r"):
                index += 1
            continue
        start = index
        while index < len(raw) and not raw[index:index + 1].isspace():
            index += 1
        if start == index:
            raise ValueError("%s: truncated PGM header" % path)
        tokens.append(raw[start:index])
    if tokens[0] != b"P5":
        raise ValueError("%s: not a binary PGM (magic %r)" % (path, tokens[0]))
    width, height, maxval = (int(token) for token in tokens[1:4])
    if not 0 < maxval <= 255:
        raise ValueError("%s: maxval %d is not supported" % (path, maxval))
    index += 1                                   # exactly one whitespace byte
    pixels = raw[index:index + width * height]
    if len(pixels) != width * height:
        raise ValueError("%s: %d pixel bytes, want %d"
                         % (path, len(pixels), width * height))
    return [[1 if value >= THRESHOLD else 0 for value in
             pixels[y * width:(y + 1) * width]] for y in range(height)]


def read_image(path) -> list[list[int]]:
    """Any format Pillow reads.  Pillow is optional, like ttkbootstrap is."""
    try:
        from PIL import Image
    except Exception as exc:                      # pragma: no cover - env dependent
        raise RuntimeError("Pillow is not installed; convert the image to PGM "
                           "first (or: python -m pip install pillow)") from exc
    with Image.open(path) as image:
        grey = image.convert("L")
        return [[1 if grey.getpixel((x, y)) >= THRESHOLD else 0
                 for x in range(grey.width)] for y in range(grey.height)]


def load_rows(path) -> list[list[int]]:
    suffix = Path(path).suffix.lower()
    if suffix == ".pgm":
        return read_pgm(path)
    if suffix in (".png", ".bmp", ".gif", ".jpg", ".jpeg", ".tif", ".tiff"):
        return read_image(path)
    raise ValueError("%s: unknown image type %r; use .pgm or a Pillow format"
                     % (path, suffix))


def load_frame(path) -> list[int]:
    """Size the image into the panel and pack it into 1024 bytes."""
    return from_rows(resize_pad(load_rows(path)))


# --------------------------------------------------------------------- drawing


def _line(rows, x0: int, y0: int, x1: int, y1: int) -> None:
    steps = max(abs(x1 - x0), abs(y1 - y0), 1)
    for step in range(steps + 1):
        x = round(x0 + (x1 - x0) * step / steps)
        y = round(y0 + (y1 - y0) * step / steps)
        if 0 <= x < WIDTH and 0 <= y < HEIGHT:
            rows[y][x] = 1


def _box(rows, inset: int = 0) -> None:
    left, top = inset, inset
    right, bottom = WIDTH - 1 - inset, HEIGHT - 1 - inset
    _line(rows, left, top, right, top)
    _line(rows, left, bottom, right, bottom)
    _line(rows, left, top, left, bottom)
    _line(rows, right, top, right, bottom)


def demo_lissajous() -> list[int]:
    """A 3:2 figure with a frame around it.

    The frame is the diagnostic: a missing or doubled column/row shows up as a
    border that is not one pixel thick, before anyone argues about the curve.
    """
    rows = [[0] * WIDTH for _ in range(HEIGHT)]
    _box(rows, 0)
    for step in range(1440):
        angle = 2.0 * math.pi * step / 1440
        x = 64 + round(58.0 * math.sin(3.0 * angle))
        y = 32 + round(26.0 * math.sin(2.0 * angle + math.pi / 2.0))
        if 0 <= x < WIDTH and 0 <= y < HEIGHT:
            rows[y][x] = 1
    return from_rows(rows)


def demo_checker(cell: int = 8) -> list[int]:
    """Alternating cells with a one-pixel border: the 'is it wired' pattern."""
    rows = [[0] * WIDTH for _ in range(HEIGHT)]
    for y in range(HEIGHT):
        for x in range(WIDTH):
            rows[y][x] = (x // cell + y // cell) & 1
    _box(rows, 0)
    return from_rows(rows)


# --------------------------------------------------------------------- output


def write_mem(frame, path) -> Path:
    """1024 lines of two hex digits: page 0 columns 0..127 first."""
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    lines = ["%02x" % byte for byte in to_bytes(frame)]
    target.write_bytes(("\n".join(lines) + "\n").encode("ascii"))
    return target


def render_rtl(frame, module: str = "v2_oled_image") -> str:
    """The framebuffer as an inferred BSRAM with its contents in an initial block.

    Inferred, not an IP core: the build has no generated IP in it, and the
    contents are then part of the source that git sees.  One BSRAM, zero LUTs.
    """
    data = to_bytes(frame)
    body = "\n".join("        mem[%4d] = 8'h%02x;" % (index, byte)
                     for index, byte in enumerate(data))
    return (
        "// GENERATED by host/oled_image.py -- do not edit by hand.\n"
        "// Frame: 128x64, page order, bit 0 = top pixel of each page.\n"
        "// Regenerate: python host/oled_image.py --demo lissajous\n"
        "module %s (\n"
        "    input  logic       clk,\n"
        "    input  logic [9:0] addr,\n"
        "    output logic [7:0] data\n"
        ");\n"
        "    // One 1024x8 block RAM. The initial block is the image.\n"
        '    (* ram_style = "block" *) logic [7:0] mem [0:1023];\n'
        "    initial begin\n"
        "%s\n"
        "    end\n"
        "    always_ff @(posedge clk) data <= mem[addr];\n"
        "endmodule\n"
    ) % (module, body)


def write_rtl(frame, path=DEFAULT_RTL, module: str = "v2_oled_image") -> Path:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(render_rtl(frame, module).encode("utf-8"))
    return target


# --------------------------------------------------------------------- selftest


def selftest() -> None:
    """Prove the bit order and the round trip without a screen or a simulator."""
    rows = [[0] * WIDTH for _ in range(HEIGHT)]
    for x in range(WIDTH):
        rows[0][x] = 1                            # the very top row
    frame = from_rows(rows)
    assert frame[0] == 0x01 and frame[WIDTH - 1] == 0x01, "top row is not bit 0"
    assert set(frame[WIDTH:]) == {0}, "ink leaked into the other pages"
    assert to_rows(frame)[0] == rows[0], "round trip lost the top row"
    assert len(to_bytes(frame)) == SIZE

    rows = [[0] * WIDTH for _ in range(HEIGHT)]
    for y in range(HEIGHT):
        rows[y][5] = 1                            # one pixel in every page row
    frame = from_rows(rows)
    assert frame[5] == 0xFF, "a full page column is not eight ones"
    assert preview(frame).count("#") == HEIGHT, "preview lost pixels"
    assert len(preview(frame).splitlines()) == HEIGHT

    assert len(demo_lissajous()) == SIZE
    assert len(demo_checker()) == SIZE
    text = render_rtl(blank())
    assert "mem[   0] = 8'h00;" in text and "mem[1023] = 8'h00;" in text
    print("selftest: PASS")


# --------------------------------------------------------------------- command


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--in", dest="source", type=Path, help="PNG or PGM")
    parser.add_argument("--demo", choices=("lissajous", "checker"),
                        help="draw a frame instead of reading a file")
    parser.add_argument("--out", type=Path, default=DEFAULT_MEM)
    parser.add_argument("--rtl", type=Path, default=DEFAULT_RTL,
                        help="generated framebuffer module ('' to skip)")
    parser.add_argument("--preview", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)

    if args.selftest:
        selftest()
        return 0
    if args.demo == "lissajous":
        frame = demo_lissajous()
    elif args.demo == "checker":
        frame = demo_checker()
    elif args.source is not None:
        frame = load_frame(args.source)
    else:
        parser.error("give --in, --demo or --selftest")

    written = write_mem(frame, args.out)
    print("%s: %d bytes, %d pixels lit" % (written, len(frame),
                                           preview(frame).count("#")))
    if args.rtl:
        print("%s: %d initial assignments"
              % (write_rtl(frame, args.rtl), len(frame)))
    if args.preview:
        print(preview(frame))
    return 0


if __name__ == "__main__":
    sys.exit(main())
