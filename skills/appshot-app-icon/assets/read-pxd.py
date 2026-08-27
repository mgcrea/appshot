#!/usr/bin/env python3
"""Read an icon's real settings out of a Pixelmator Pro document.

    python3 read-pxd.py MyIcon.pxd            # layers, styles, fonts, gradients
    python3 read-pxd.py MyIcon.pxd --flags    # the same, as appshot flags to paste

Why bother, when you can measure the PNG: because measuring answers a different question.
A raster tells you what a pixel ended up being, never what it *is*. On the document that
prompted this script, measuring got three things wrong and none of them looked wrong —
a long shadow read as stepping (24,27) when the document says exactly 45 degrees; a warm
band along the letterforms taken for a soft edge when it is the plate's own orange used as
an inner shadow; and a tracking of 0.014em inferred to explain a glyph that is really at 0,
because an inner shadow had eaten ~10px off the bottom of the white and a shorter box reads
as a wider face.

Exporting the document to SVG does not help either: it bakes the effects into paths or into
a filter approximation, and the numbers are gone.

FORMAT, verified against Pixelmator Pro 4.0 documents:

    MyIcon.pxd                     a zip archive
      metadata.info                a SQLite database
        document_info(key,value)   canvas size, guides, slices
        document_layers            id, identifier, parent_identifier, type
        layer_info(layer_id,key,value)
                                   per layer: name, position, size, styles-data,
                                   text-stringData, shape-shapeData, ...

Most values are wrapped in a small container: the 4-byte magic `4-tP`, a 4-byte type tag,
a little-endian uint32 length, then the payload. Numbers inside are **big-endian** doubles.
`styles-data` is plain JSON. `text-stringData` is JSON wrapping a base64 NSKeyedArchiver
plist of the NSAttributedString, which is where the font name and tracking live.

Nothing here writes to the document.
"""

import argparse
import base64
import json
import math
import plistlib
import sqlite3
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

MAGIC = b"4-tP"

LAYER_TYPES = {1: "?", 2: "text", 3: "shape", 4: "group"}

# The style groups Pixelmator stores, in the order they are worth reading. "i" is the one
# that has no equivalent you can draw by hand: an inner shadow is bounded by the layer's own
# alpha, so no second copy of the artwork stands in for it.
STYLE_GROUPS = {"S": "drop shadow", "i": "inner shadow", "f": "fill", "s": "stroke"}


def unwrap(value):
    """Strip the `4-tP` container if present and return the raw payload."""
    if isinstance(value, str):
        value = value.encode()
    if isinstance(value, (bytes, bytearray)) and value[:4] == MAGIC:
        (length,) = struct.unpack("<I", value[8:12])
        return bytes(value[12 : 12 + length])
    return bytes(value) if value is not None else b""


def as_text(value):
    """Strings carry their own uint32 length and are then padded to a multiple of four."""
    payload = unwrap(value)
    if len(payload) >= 4:
        (count,) = struct.unpack("<I", payload[:4])
        if 0 <= count <= len(payload) - 4:
            payload = payload[4 : 4 + count]
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError:
        return payload.hex()


def as_doubles(value):
    """Big-endian doubles — the encoding positions, sizes and scales use."""
    payload = unwrap(value)
    count = len(payload) // 8
    if count == 0:
        return []
    return list(struct.unpack(f">{count}d", payload[: count * 8]))


def as_json(value):
    payload = unwrap(value)
    try:
        return json.loads(payload.decode("utf-8", "replace"))
    except (ValueError, UnicodeDecodeError):
        return None


def colour(node):
    """`[1,{"c":[r,g,b,a],...}]` → `#RRGGBB`, plus its alpha."""
    if isinstance(node, list) and len(node) == 2 and isinstance(node[1], dict):
        rgba = node[1].get("c") or []
        if len(rgba) >= 3:
            hexes = "#%02X%02X%02X" % tuple(
                max(0, min(255, round(c * 255))) for c in rgba[:3]
            )
            return hexes, (rgba[3] if len(rgba) > 3 else 1.0)
    return None, 1.0


def open_document(path):
    if not path.exists():
        sys.exit(f"no such file: {path}")
    tmp = tempfile.mkdtemp(prefix="pxd-")
    try:
        with zipfile.ZipFile(path) as archive:
            archive.extractall(tmp)
    except zipfile.BadZipFile:
        sys.exit(
            f"{path.name} is not a zip archive, so it is not a Pixelmator document. "
            "A .pxd exports to PNG; the PNG is not readable this way — that is the whole "
            "point of reading the document instead."
        )
    meta = Path(tmp) / "metadata.info"
    if not meta.exists():
        sys.exit(f"{path.name}: no metadata.info inside — not a Pixelmator document?")
    return sqlite3.connect(meta)


def canvas_size(db):
    row = db.execute("select value from document_info where key='size'").fetchone()
    if not row:
        return None
    # The size record carries its own little header before the two dimensions; the last two
    # 32-bit words are the ones that read as the canvas.
    payload = unwrap(row[0])
    words = struct.unpack(f"<{len(payload) // 4}I", payload[: (len(payload) // 4) * 4])
    plausible = [w for w in words if 16 <= w <= 32768]
    return (plausible[0], plausible[1]) if len(plausible) >= 2 else None


def read_font(db, layer_id):
    """Font name, size and tracking, out of the archived NSAttributedString."""
    row = db.execute(
        "select value from layer_info where layer_id=? and key='text-stringData'",
        (layer_id,),
    ).fetchone()
    if not row:
        return None
    blob = row[0].encode() if isinstance(row[0], str) else row[0]
    try:
        outer = json.loads(blob.decode("utf-8", "replace"))
    except ValueError:
        return None
    # Pixelmator has shipped both spellings of this key.
    container = outer.get("versionSpecifiContainer") or outer.get(
        "versionSpecificContainer", {}
    )
    encoded = container.get("stringNSCodingData")
    if not encoded:
        return None
    archive = plistlib.loads(base64.b64decode(encoded))
    objects = archive.get("$objects", [])

    def deref(ref):
        return objects[ref.data] if isinstance(ref, plistlib.UID) else ref

    info = {}
    for index, obj in enumerate(objects):
        # The string is usually wrapped in an NSMutableString, but some documents archive it
        # bare. Take the first plain string that is not one of the attribute keys.
        if isinstance(obj, dict) and "NS.string" in obj:
            info["text"] = obj["NS.string"]
        elif (
            "text" not in info
            and isinstance(obj, str)
            and index < 5
            and obj != "$null"
            and "." not in obj
        ):
            info["text"] = obj
        if isinstance(obj, dict) and "NS.keys" in obj:
            for key, value in zip(
                (deref(k) for k in obj["NS.keys"]),
                (deref(v) for v in obj["NS.objects"]),
            ):
                if not isinstance(key, str):
                    continue
                name = key.rsplit(".", 1)[-1]
                if name == "font-style-data" and isinstance(value, bytes):
                    # `[1,{"b":1,"n":"SFProRounded-Regular","s":1024}]` — "b" is the bold
                    # toggle, and it selects the Bold *face*: do not read it as a synthetic
                    # embolden, or you will go looking for metrics that do not exist.
                    try:
                        spec = json.loads(value.decode())[1]
                        info["font"] = spec.get("n")
                        info["size"] = spec.get("s")
                        info["bold"] = bool(spec.get("b"))
                        info["italic"] = bool(spec.get("i"))
                    except (ValueError, IndexError, UnicodeDecodeError):
                        pass
                elif name == "character-spacing":
                    info["tracking"] = value
    return info or None


def read_styles(db, layer_id):
    row = db.execute(
        "select value from layer_info where layer_id=? and key='styles-data'", (layer_id,)
    ).fetchone()
    if not row:
        return []
    parsed = as_json(row[0])
    if not parsed:
        return []
    body = parsed[1] if isinstance(parsed, list) and len(parsed) > 1 else parsed
    if not isinstance(body, dict):
        return []

    found = []
    for group, label in STYLE_GROUPS.items():
        for entry in body.get(group) or []:
            style = entry[1] if isinstance(entry, list) and len(entry) > 1 else entry
            if not isinstance(style, dict) or not style.get("E"):
                continue  # disabled in the document; it is not in the artwork
            hexes, alpha = colour(style.get("c"))
            record = {
                "group": group,
                "label": label,
                "angle": math.degrees(style["a"]) % 360 if "a" in style else None,
                "distance": style.get("d"),
                "blur": style.get("b"),
                "opacity": style.get("o"),
                "color": hexes,
                "color_alpha": alpha,
            }
            gradient = style.get("g")
            if isinstance(gradient, list) and len(gradient) > 1:
                stops = []
                for stop in gradient[1].get("s") or []:
                    rgba, offset = stop[1]
                    stops.append(
                        (
                            offset,
                            "#%02X%02X%02X"
                            % tuple(max(0, min(255, round(c * 255))) for c in rgba[:3]),
                        )
                    )
                if stops:
                    record["gradient"] = sorted(stops)
                    record["gradient_from"] = style.get("gSP")
                    record["gradient_to"] = style.get("gEP")
            found.append(record)
    return found


VISIBLE_BIT = 0x1


def visibility(db):
    """Which layers actually render: bit 0x1 on the layer *and* on every ancestor.

    Checking the layer alone is not enough, and the failure is quiet. Icon documents are
    routinely made by duplicating the last one, so they carry whole hidden groups holding
    the previous app's artwork — styles enabled, `E: 1`, indistinguishable from the real
    thing until you notice the layer is called something like "R2". Reading those emits a
    treatment nobody can see, in the previous product's accent colour.
    """
    by_identifier, parent_of, flags = {}, {}, {}
    for layer_id, identifier, parent in db.execute(
        "select id, identifier, parent_identifier from document_layers"
    ):
        by_identifier[identifier] = layer_id
        parent_of[layer_id] = parent
    for layer_id, value in db.execute(
        "select layer_id, value from layer_info where key='flags'"
    ):
        payload = unwrap(value)
        if len(payload) >= 8:
            flags[layer_id] = struct.unpack("<Q", payload[:8])[0]

    def shown(layer_id):
        seen = set()
        while layer_id is not None and layer_id not in seen:
            seen.add(layer_id)
            if not flags.get(layer_id, VISIBLE_BIT) & VISIBLE_BIT:
                return False
            parent = parent_of.get(layer_id)
            layer_id = by_identifier.get(parent) if parent else None
        return True

    return {lid: shown(lid) for lid in parent_of}


def describe(db, canvas, include_hidden=False):
    rows = db.execute(
        "select id, parent_identifier, index_at_parent, type from document_layers order by id"
    ).fetchall()
    names = {
        lid: as_text(v)
        for lid, v in db.execute(
            "select layer_id, value from layer_info where key='name'"
        )
    }
    shown = visibility(db)
    out = []
    for layer_id, parent, index, kind in rows:
        if not include_hidden and not shown.get(layer_id, True):
            continue
        entry = {
            "id": layer_id,
            "name": names.get(layer_id, ""),
            "type": LAYER_TYPES.get(kind, str(kind)),
            "index": index,
            "has_parent": parent is not None,
            "styles": read_styles(db, layer_id),
            "font": read_font(db, layer_id) if kind == 2 else None,
            "position": as_doubles(
                (
                    db.execute(
                        "select value from layer_info where layer_id=? and key='position'",
                        (layer_id,),
                    ).fetchone()
                    or [None]
                )[0]
            ),
            "size": as_doubles(
                (
                    db.execute(
                        "select value from layer_info where layer_id=? and key='size'",
                        (layer_id,),
                    ).fetchone()
                    or [None]
                )[0]
            ),
        }
        out.append(entry)
    return out


def print_report(layers, canvas):
    print(f"canvas: {canvas[0]}x{canvas[1]}" if canvas else "canvas: unknown")
    print()
    for layer in layers:
        if not layer["styles"] and not layer["font"]:
            continue
        head = f"layer {layer['id']:>3}  {layer['type']:<6} {layer['name']!r}"
        print(head)
        if layer["font"]:
            f = layer["font"]
            bits = [f"{f.get('font')} @ {f.get('size')}"]
            if f.get("bold"):
                bits.append("bold")
            if f.get("italic"):
                bits.append("italic")
            bits.append(f"tracking {f.get('tracking', 0)}")
            print(f"    text {f.get('text')!r}: " + ", ".join(bits))
        for s in layer["styles"]:
            if s.get("gradient"):
                stops = "  ".join(f"{o:.2f}:{c}" for o, c in s["gradient"])
                print(f"    {s['label']:<13} gradient {stops}")
                print(
                    f"    {'':13} from {s.get('gradient_from')} to {s.get('gradient_to')}"
                )
            else:
                print(
                    f"    {s['label']:<13} angle {s['angle']:.0f}  distance {s['distance']}"
                    f"  blur {s['blur']}  opacity {s['opacity']:.4f}  {s['color']}"
                )
        print()


def print_flags(layers, canvas):
    """The shadows as appshot flags.

    Two conversions, and both are easy to forget. Distances and blurs are in the document's
    own pixels while appshot's are per 1024 canvas, so they scale by 1024/canvas_width. And
    appshot's `blur` is the Gaussian standard deviation while a design tool's slider quotes
    roughly twice that, so it halves again.
    """
    if not canvas:
        sys.exit("cannot emit flags without knowing the canvas size")
    k = 1024 / canvas[0]
    print(f"# canvas {canvas[0]}px -> appshot's 1024, so lengths scale by {k:g}")
    print("# blur halves again: appshot's blur is sigma, the slider quotes about 2 sigma")
    for layer in layers:
        for s in layer["styles"]:
            if s["group"] not in ("S", "i"):
                continue
            flag = "--mark-shadow" if s["group"] == "S" else "--mark-inner-shadow"
            print(
                f"  {flag} 'angle={s['angle']:.0f},distance={s['distance'] * k:g},"
                f"blur={s['blur'] * k / 2:g},opacity={s['opacity']:.4f},color={s['color']}' \\"
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("document", type=Path)
    parser.add_argument(
        "--flags", action="store_true", help="emit appshot --mark-shadow flags"
    )
    parser.add_argument(
        "--include-hidden",
        action="store_true",
        help="also report layers the document hides (previous drafts usually)",
    )
    args = parser.parse_args()

    db = open_document(args.document)
    canvas = canvas_size(db)
    layers = describe(db, canvas, include_hidden=args.include_hidden)
    if args.flags:
        print_flags(layers, canvas)
    else:
        print_report(layers, canvas)


if __name__ == "__main__":
    main()
