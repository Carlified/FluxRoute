import gdstk
import json
import sys


def main():
    if len(sys.argv) < 3:
        print("usage: gds_to_json.py <in.gds> <out.json>", file=sys.stderr)
        return 1

    gds_path = sys.argv[1]
    out_path = sys.argv[2]

    lib = gdstk.read_gds(gds_path)
    tops = lib.top_level()
    if not tops:
        tops = list(lib.cells)

    cells = []
    for cell in tops:
        polygons = []
        for poly in cell.get_polygons(True):
            pts = poly.points.tolist()
            if len(pts) < 3:
                continue
            polygons.append({"layer": int(poly.layer), "points": pts})
        cells.append({"name": cell.name, "polygons": polygons})

    data = {"file": gds_path, "cells": cells}
    with open(out_path, "w") as f:
        json.dump(data, f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
