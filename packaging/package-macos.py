#!/usr/bin/env python3
"""Package a macOS .app bundle into a release zip, from any OS.

    python tools/../packaging/package-macos.py <path/to/PnRGUI.app> 1.0.0 [arm64|x64]

Why not just zip it? A .app is a directory bundle and macOS needs the main
executable to carry the executable bit. Zip tools on Windows do not store Unix
modes, so this script writes the archive entry by entry with the right modes
(0755 for Contents/MacOS/*, 0644 elsewhere). The archive layout matches the
Windows package: PnRGUI.app, tools/, README.md, LICENSE at the zip root.

Run it on macOS with `ditto` instead if you prefer (packaging/package-macos.sh);
both produce the same layout.
"""

import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXEC_DIR = os.path.join("Contents", "MacOS")


def add_tree(zf, src, arc_root):
    """Adds src under arc_root, storing Unix modes the way macOS expects."""
    for dirpath, dirnames, filenames in os.walk(src):
        # __pycache__ is build noise; _CodeSignature is dropped because the
        # package strips files from the bundle (see below), which would leave the
        # signature invalid. Ship it plainly unsigned.
        dirnames[:] = sorted(d for d in dirnames
                             if d not in ("__pycache__", "_CodeSignature"))
        rel = os.path.relpath(dirpath, src)
        arc_dir = arc_root if rel == "." else os.path.join(arc_root, rel)
        if rel != ".":
            info = zipfile.ZipInfo(arc_dir.replace(os.sep, "/") + "/")
            info.external_attr = (0o40755 << 16) | 0x10  # dir, drwxr-xr-x
            zf.writestr(info, b"")
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            rel_file = os.path.relpath(path, src).replace(os.sep, "/")
            arcname = (arc_root + "/" + rel_file).replace(os.sep, "/")
            if arcname == "tools/config.json":
                continue  # per-machine paths, never shipped
            if arcname.endswith(".inc"):
                continue  # Debug deployment copies source includes; never loaded
            mode = 0o100755 if rel_file.startswith(EXEC_DIR.replace(os.sep, "/") + "/") else 0o100644
            info = zipfile.ZipInfo(arcname)
            info.external_attr = mode << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(path, "rb") as f:
                zf.writestr(info, f.read())


def main():
    if len(sys.argv) < 3:
        print("usage: package-macos.py <path/to/PnRGUI.app> <version> [arm64|x64]",
              file=sys.stderr)
        return 2
    app = sys.argv[1].rstrip("\\/")
    version = sys.argv[2]
    arch = sys.argv[3] if len(sys.argv) > 3 else "arm64"
    if not os.path.isdir(app):
        print(f"not a directory: {app}", file=sys.stderr)
        return 2

    name = f"FluxRoute-{version}-macos-{arch}"
    dist = os.path.join(ROOT, "dist")
    os.makedirs(dist, exist_ok=True)
    out = os.path.join(dist, name + ".zip")
    if os.path.exists(out):
        os.remove(out)

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        add_tree(zf, app, "PnRGUI.app")
        add_tree(zf, os.path.join(ROOT, "tools"), "tools")
        for extra in ("README.md", "LICENSE"):
            src = os.path.join(ROOT, extra)
            if not os.path.exists(src):
                raise SystemExit(f"missing: {src}")
            info = zipfile.ZipInfo(extra)
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(src, "rb") as f:
                zf.writestr(info, f.read())

    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
