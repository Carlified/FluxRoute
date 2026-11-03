# Building and releasing FluxRoute

The GUI is a Delphi FireMonkey application (`FluxRoute.dproj`). Everything below is
about producing a binary you can hand to someone, not about running from the IDE.

Two things worth knowing up front:

- **Build ≠ Run.** `Project > Build` compiles and links *on your Windows machine*
  and leaves the binary in the project's platform output folder. `Run` (F9) for a
  macOS target copies the app to a Mac through **PAServer** and launches it there.
  PAServer is only needed for the second one; the `.app` bundle produced by
  *Build* is the permanent binary.
- The app has no external assets (styles and the form are compiled in), so a
  built `.exe` or `.app` is self-contained. Only the optional export helpers need
  the `tools/` folder and Python.

---

## 1. Prerequisites

| Platform | Needs |
|---|---|
| Windows | RAD Studio with Delphi + FireMonkey (project version 20.1, i.e. RAD Studio 12.x). Win64 target is the tested one. |
| macOS (Intel) | The `OSX64` platform plus a macOS 64-bit SDK configured in RAD Studio |
| macOS (Apple silicon) | The `OSXARM64` platform plus the macOS ARM 64 SDK |

The macOS SDK is a one-off setup: **Tools > Options > Deployment > SDK Manager**
(older IDEs: Platform Manager). The IDE fetches the SDK files from a Mac through
PAServer once, after which macOS targets compile on Windows without a Mac.
A connection profile is still needed to *run* on the Mac.

Optional, for the helper tools: Python 3.9+ with `gdstk` (GDS export/import) and
`matplotlib`/`numpy` (plots), and [JoSIM](https://github.com/JoSIM-Tools/JoSIM)
for simulation.

---

## 2. Windows build

1. Open `FluxRoute.dproj`.
2. In the Projects window select the **Win64** platform (or Win32) and the
   **Release** configuration.
3. `Project > Build` (Shift+F9).
4. Output: `Win64\Release\FluxRoute.exe`.

Run it from the repository folder so the `tools/` lookup works, or copy the
`tools/` folder next to the executable. The app searches for its helper scripts
next to the executable, in `tools/` below it, and walking up from the executable.

Command line (RAD Studio command prompt):

```bat
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"
msbuild FluxRoute.dproj /t:Build /p:Platform=Win64 /p:Config=Release
```

(Adjust the Studio version folder to your installation.)

---

## 3. macOS: producing a permanent `.app`

### 3.1 One-time platform setup

1. **Tools > Options > Deployment > SDK Manager** (or Platform Manager) and make
   sure the macOS 64-bit (Intel) and/or macOS ARM 64 SDK is present.
2. In **Tools > Options > Environment Options > Connection Profile Manager**, add
   a profile for your Mac if you also want to run/debug there (needed only for
   PAServer runs, not for building).

### 3.2 Build the bundle

1. In the Projects window, expand **Target Platforms** and double-click
   **macOS ARM 64** (Apple silicon) or **macOS 64-bit** (Intel).
2. Select the **Release** configuration.
3. `Project > Build` (Shift+F9). Do **not** use Run for this step.
4. The bundle appears in the project folder:

```
OSXARM64\Release\FluxRoute.app      (Apple silicon)
OSX64\Release\FluxRoute.app         (Intel)
```

That `.app` is the permanent binary. It is a directory bundle — copy it whole
(`scp -r`, AirDrop, or zip it first; see §6).

**If Build only produced `FluxRoute` + `FluxRoute.info.plist`** (the bundle itself is
normally created by *Deploy*), lay the bundle out locally - no PAServer, no Mac:

```bat
python packaging\make-macos-app.py OSXARM64\Release --icon FluxRoute_Icns.icns
```

That creates `OSXARM64\Release\FluxRoute.app` with the executable, the generated
`Info.plist` (UTF-8 BOM stripped) and the icon. Pass `--icon FluxRoute_Icns.icns`
from the project root: **Build alone does not place the icon in the bundle**, so
a bundle assembled without it keeps whatever `Resources/FluxRoute.icns` was there
before. Check the file size - about 174 KB is the FluxRoute icon, 524 KB is the
generic Delphi one.

### 3.3 First launch on the Mac - always sign the bundle

A bundle assembled on Windows has **no code signature**, and Apple silicon will
not execute an arm64 binary without one: the app just reports that it cannot be
opened. (Deploying through PAServer signs it on the Mac for you; assembling with
`make-macos-app.py` cannot.) So both steps are required, in this order:

```sh
xattr -dr com.apple.quarantine /Applications/FluxRoute.app
codesign --force --deep --sign - /Applications/FluxRoute.app
```

The release archive ships `first-launch.command` next to `FluxRoute.app`, which
does exactly these two steps and then opens the app - double-click it, or run
`sh first-launch.command`. If Gatekeeper blocks the script itself, right-click
it → **Open** once, or run it from Terminal.

To confirm the signature afterwards, `codesign -dv FluxRoute.app` should print
`Signature=adhoc`, and `spctl --assess --verbose FluxRoute.app` will still reject
the bundle (ad-hoc signatures are not notarised) - that is expected and does not
stop it launching.

### 3.4 Optional: a universal (Intel + ARM) bundle

Build both macOS targets, then merge the two executables:

```sh
lipo -create \
  OSX64/Release/FluxRoute.app/Contents/MacOS/FluxRoute \
  OSXARM64/Release/FluxRoute.app/Contents/MacOS/FluxRoute \
  -output /tmp/FluxRoute-universal
cp /tmp/FluxRoute-universal OSXARM64/Release/FluxRoute.app/Contents/MacOS/FluxRoute
codesign --force --deep --sign - OSXARM64/Release/FluxRoute.app
```

Otherwise ship two zips (`-arm64` and `-x64`); Apple silicon runs the Intel
build through Rosetta 2 anyway.

### 3.5 Signing and notarising for public downloads

Without this, every user has to do the right-click/Open dance. You need an Apple
Developer account and a **Developer ID Application** certificate.

```sh
codesign --deep --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" FluxRoute.app

ditto -c -k --sequesterRsrc --keepParent FluxRoute.app FluxRoute.zip
xcrun notarytool submit FluxRoute.zip --apple-id you@example.com \
  --team-id TEAMID --password "app-specific-password" --wait
xcrun stapler staple FluxRoute.app
spctl -a -vvv FluxRoute.app          # should say "accepted, Notarized Developer ID"
```

---

### 3.6 Troubleshooting

- **`CreateInfoPlistFile` fails with `DirectoryNotFoundException` for
  `OSXARM64\Release\FluxRoute.info.plist`** ? the Release output folder does not
  exist yet (Debug was built first) and the task does not create it. Create it
  once and rebuild:

  ```bat
  mkdir OSXARM64\Release
  ```

  The same applies to `Win64\Release` after a clean.
- **`.inc` files appear in the home folder on the Mac** - the `{$I}` include
  files used to be project items, so RAD Studio's Deployment Manager
  classified them as deployable `ProjectFile` entries and PAServer copied
  them relative to the deployment root. They are compile-time only, so the
  project no longer lists them and ships no deployment entries for them. If an
  older checkout or a re-saved project brings them back, open
  **Project > Deployment** and delete those rows.
- **`FluxRoute.res` shrinks to 32 bytes after a build** - expected. The IDE
  regenerates the project resource from the project options on save, and this
  project keeps its icon and version info there (`Icon_MainIcon`,
  `Icns_MainIcns`, `VerInfo_Keys`), which the linker embeds directly. The empty
  `.res` is what is committed, so a build leaves the tree clean; do not restore
  an older copy over it.
- **"macOS SDK not found"** ? the platform is installed but no SDK is configured;
  add one in the SDK Manager (?3.1).
- **Build succeeds but the app will not start on the Mac** ? see ?3.3
  (quarantine/signature), and check the Mac's `Console.app` for a crash report.

## 4. Command-line builds (optional)

From the RAD Studio command prompt:

```bat
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"

msbuild FluxRoute.dproj /t:Build /p:Platform=Win64     /p:Config=Release
msbuild FluxRoute.dproj /t:Build /p:Platform=OSXARM64  /p:Config=Release
msbuild FluxRoute.dproj /t:Build /p:Platform=OSX64     /p:Config=Release
```

CI note: GitHub-hosted runners do not include RAD Studio, so a public workflow
cannot build these targets. Use a self-hosted Windows runner with RAD Studio
installed if you want automated builds.

---

## 5. Versioning

Set the release version in **Project > Options > Version Info** (Windows) and in
the `CFBundleShortVersionString`/`CFBundleVersion` entries for macOS (they live
in the same dialog). The README and packaging scripts take the version as a
parameter.

---

## 6. Packaging for a GitHub Release

Two small scripts are provided:

**Windows** (`packaging/package-win.ps1`):

```powershell
pwsh packaging/package-win.ps1 -Version 1.0.0
# -> dist/FluxRoute-1.0.0-win64.zip
```

**macOS** ? two equivalent routes:

```sh
# on macOS (uses ditto, preserves the bundle)
sh packaging/package-macos.sh OSXARM64/Release/FluxRoute.app 1.0.0
# -> dist/FluxRoute-1.0.0-macos-arm64.zip

# on Windows (no ditto): stores the bundle entry by entry with the right modes
python packaging/package-macos.py "C:\path\to\FluxRoute.app" 1.0.0 arm64
```

Package a **Release** build: a Debug deployment copies the `{$I}` sources into
`FluxRoute.app/Contents/Resources/StartUp/` (the packagers strip them, but the
Release binary is also smaller and faster).

Both bundles contain the binary, `README.md`, `LICENSE` and the `tools/` folder,
so the optional export helpers work out of the box.

Publish with the GitHub UI or:

```sh
gh release create v1.0.0 dist/*.zip --title "FluxRoute 1.0.0" --notes "First release."
```

Mention in the release notes that the macOS build is unsigned (unless you
notarised it) and how to get past Gatekeeper.

---

## 7. Release checklist

- [ ] Version bumped in the project options
- [ ] `Release` configuration builds clean for each platform you ship
- [ ] Smoke test: load a LEF, then `examples/blif/rca4.blif`, run the flow
- [ ] `tools/config.example.json` is untouched (no machine paths committed)
- [ ] Packages built, checksums noted
- [ ] Release notes list known limitations (`.def` export, unsigned macOS bundle)
