#!/usr/bin/env python3
"""Builds the die GDS from a placement recipe (JSON).

The Delphi client writes the recipe; this script does the gdstk work so the app
never has to author binary GDS. Recipe schema:

{
  "sources": ["blocklib/PTL_M1.gds", "cell_gds/TH_XORT.gds", ...],
  "die":        {"w_um": 120.0, "h_um": 80.0},
  "boundary_layer": 0,
  "instances": [
    # one straight run => one reference to the unit tile, repeated (AREF-like):
    {"cell": "PTL_M1", "x_um": 0.0, "y_um": 5.0, "rot": 0,
     "cols": 8, "rows": 1, "dx_um": 10.0, "dy_um": 0.0},
    # a single placement (no repetition):
    {"cell": "VIA_M1_M3_STRAIGHT", "x_um": 80.0, "y_um": 5.0, "rot": 0}
  ],
  "out": "die.gds"
}

Coordinate/rotation conventions (block authoring contract):
  - the app grid is Y-down; GDS is Y-up, so every block's block [y, y+pitch]
    lands at gds [h - (y+pitch), h - y] (the writer applies this mirror);
  - an UNROTATED block's own (0,0) aligns to its grid block's bottom-left corner;
  - a ROTATED unit block pivots about its grid-block centre (pitch/2, pitch/2) -
    deterministic, no per-block numbers, because every block is authored centred
    on its block;
  - "mirror": true places a rotated trunk CELL exactly as the routing page does:
    the recipe gives the final reference origin, and the transform is a rotation
    plus x_reflection (the app's cell-rotation is a mirror in GDS terms);
  - rotation is in degrees (GDS CCW).
"""

import gdstk
import json
import math
import sys


def main():
    if len(sys.argv) < 2:
        print("usage: write_die_gds.py <recipe.json> [--bbox]", file=sys.stderr)
        return 2
    with open(sys.argv[1]) as f:
        recipe = json.load(f)

    if "--bbox" in sys.argv:
        # Diagnostic: report every source cell's extent and the first instances,
        # so tile-origin/rotation conventions can be verified without guessing.
        for src in recipe.get("sources", []):
            try:
                sub = gdstk.read_gds(src)
            except Exception as exc:
                print("cannot read %s: %s" % (src, exc), file=sys.stderr)
                continue
            for cell in sub.cells:
                try:
                    bb = cell.bounding_box()
                    print("CELL %-24s bbox=(%.3f, %.3f, %.3f, %.3f)"
                          % (cell.name, bb[0][0], bb[0][1], bb[1][0], bb[1][1]))
                except Exception:
                    print("CELL %s: no geometry" % cell.name)
        insts = recipe.get("instances", [])
        for inst in insts[:20]:
            print("INST %-16s x=%.1f y=%.1f rot=%d cols=%d rows=%d dx=%.1f dy=%.1f%s"
                  % (inst["cell"], inst["x_um"], inst["y_um"], inst.get("rot", 0),
                     inst.get("cols", 1), inst.get("rows", 1),
                     inst.get("dx_um", 0.0), inst.get("dy_um", 0.0),
                     " file=" + inst.get("file", "") if inst.get("file") else ""))
        return 0

    lib = gdstk.Library()
    by_name = {}
    file_cells = {}   # source path -> [cells in that file]
    file_tops = {}   # source path -> top-level cells of that file
    # Merge every source library; the block/cell names live in one namespace.
    for src in recipe.get("sources", []):
        try:
            sub = gdstk.read_gds(src)
        except Exception as exc:          # noqa: BLE001 - report and abort
            print("cannot read %s: %s" % (src, exc), file=sys.stderr)
            return 3
        file_cells[src] = list(sub.cells)
        file_tops[src] = list(sub.top_level())
        for cell in sub.cells:
            if cell.name not in by_name:
                by_name[cell.name] = cell
                lib.add(cell)

    top = lib.new_cell("DIE")

    die = recipe["die"]
    bl = recipe.get("boundary_layer", 0)
    top.add(gdstk.rectangle((0, 0), (die["w_um"], die["h_um"]),
                            layer=bl, datatype=0))

    for inst in recipe.get("instances", []):
        src = inst.get("file", "")
        cell = None
        if src and src in file_cells:
            # Cells carry their exact GDS file: prefer the cell named as the
            # instance (version suffixes allowed via top-level/fallback below).
            cells = file_cells[src]
            cell = next((c for c in cells if c.name == inst["cell"]), None)
            if cell is None:
                cs = file_tops.get(src, [])
                cell = cs[0] if cs else cells[0]
        if cell is None:
            cell = by_name.get(inst["cell"])
        if cell is None:
            print("missing cell %s in the sources" % inst["cell"], file=sys.stderr)
            return 4
        # Placement: every cell lands at its grid position found during
        # enumeration. Y-mirror for GDS Y-up: the app block [y, y+10] maps to gds
        # [H-(y+10), H-y], so the bottom-left anchor is H - y - blockHeight, and Y
        # repetition runs NEGATIVE (downward in GDS). X is untouched.
        p = die["pitch"]
        if inst.get("mirror"):
            # Exact placement (rotated trunk cells): the recipe gives the final
            # reference origin, and the routing page's transform maps to a
            # rotation plus x_reflection. No block/pivot maths.
            ref = gdstk.Reference(cell, origin=(inst["x_um"], inst["y_um"]),
                                  rotation=math.radians(inst.get("rot", 0)),
                                  x_reflection=True)
            top.add(ref)
            continue
        bb = cell.bounding_box()
        if inst.get("file"):
            # Library cell instance: the authored geometry spans its grid-block
            # extent, so its height gives the block extent to mirror.
            bh = bb[1][1] if bb is not None else p
        else:
            # Unit block tile (PTL/BIAS/BEND/VIA/SPLIT/CAP): one block tall.
            bh = p
        ox = inst["x_um"]
        oy = die["h_um"] - inst["y_um"] - bh
        # Rotation: the recipe carries the GDS-frame angle (90 * direction steps)
        # already. Rotate the block about its grid-block centre: the centre sits
        # (pitch/2, pitch/2) above the block's bottom-left. gdstk rotates about
        # the reference origin, so offset the origin by centre - R(centre).
        rot = inst.get("rot", 0)
        if rot != 0:
            px = p / 2.0
            py = p / 2.0
            r = math.radians(rot)
            c = math.cos(r)
            s = math.sin(r)
            ox = ox + p / 2.0 - (px * c - py * s)
            oy = oy + p / 2.0 - (px * s + py * c)
        ref = gdstk.Reference(cell, origin=(ox, oy), rotation=math.radians(rot))
        top.add(ref)
        cols = inst.get("cols", 1)
        rows = inst.get("rows", 1)
        if cols > 1 or rows > 1:
            ref.repetition = gdstk.Repetition(
                columns=cols, rows=rows,
                spacing=(inst.get("dx_um", 0.0), -inst.get("dy_um", 0.0)))

    lib.write_gds(recipe["out"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
