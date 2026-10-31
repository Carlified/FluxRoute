#!/usr/bin/env python3
"""Assemble a macOS .app bundle from a macOS build, without deploying via PAServer.

    python packaging/make-macos-app.py <build-dir> [--icon PnRGUI.icns]

For a macOS target, RAD Studio's *Build* writes the linked executable plus the
generated property list into the configuration folder:

    OSXARM64\\Release\\PnRGUI                (Mach-O executable)
    OSXARM64\\Release\\PnRGUI.info.plist     (generated Info.plist)

The .app bundle itself is normally only produced by *Deploy* (which copies it to
a Mac through PAServer). This script lays out the bundle locally instead:

    OSXARM64\\Release\\PnRGUI.app/Contents/MacOS/PnRGUI
    OSXARM64\\Release\\PnRGUI.app/Contents/Info.plist
    OSXARM64\\Release\\PnRGUI.app/Contents/Resources/PnRGUI.icns   (if given)

The result is an unsigned bundle: macOS quarantines it after a download, so end
users right-click > Open once, or run
`xattr -dr com.apple.quarantine PnRGUI.app`. See docs/BUILDING.md.
"""

import os
import shutil
import sys


def find_one(directory, names):
    for name in names:
        path = os.path.join(directory, name)
        if os.path.exists(path):
            return path
    return None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    icon = None
    if "--icon" in sys.argv:
        icon = sys.argv[sys.argv.index("--icon") + 1]
        args = [a for a in args if a != icon]

    if len(args) != 1:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    build_dir = args[0].rstrip("\\/")
    if not os.path.isdir(build_dir):
        print(f"not a directory: {build_dir}", file=sys.stderr)
        return 2

    exe = find_one(build_dir, ("PnRGUI", "PnRGUI.exe"))
    plist = find_one(build_dir, ("PnRGUI.info.plist", "PnRGUI.plist"))
    if exe is None or plist is None:
        print("expected PnRGUI and PnRGUI.info.plist in " + build_dir, file=sys.stderr)
        print("build the macOS target first (Project > Build, Release configuration).",
              file=sys.stderr)
        return 1

    app = os.path.join(build_dir, "PnRGUI.app")
    if os.path.exists(app):
        shutil.rmtree(app, ignore_errors=True)
    macos = os.path.join(app, "Contents", "MacOS")
    res = os.path.join(app, "Contents", "Resources")
    os.makedirs(macos)
    os.makedirs(res)

    shutil.copy2(exe, os.path.join(macos, "PnRGUI"))
    # The generated plist starts with a UTF-8 BOM; strip it so CoreFoundation
    # always sees a clean XML document.
    with open(plist, "rb") as f:
        blob = f.read()
    if blob.startswith(b"\xef\xbb\xbf"):
        blob = blob[3:]
    with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
        f.write(blob)
    if icon and os.path.exists(icon):
        shutil.copy2(icon, os.path.join(res, "PnRGUI.icns"))

    print(f"assembled {app}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
