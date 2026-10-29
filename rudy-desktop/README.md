# Rudy

A little black robot who walks back and forth along the bottom of your screen.

He is the character who walks the `WalkingLine` on
[gouwylieven.github.io/portfolio](https://gouwylieven.github.io/portfolio/),
cut loose from the browser and put on your desktop instead.

Two builds, one 24 KB sprite sheet, no runtimes to install:

| | Artifact | Needs |
|---|---|---|
| Windows 10/11 | `dist/Rudy.exe` (~100 KB) | nothing — .NET Framework 4.8 is part of Windows |
| macOS 11+ | `dist/Rudy.app` (~300 KB) | Xcode Command Line Tools, to build it |

---

## What it does

- Walks a six-frame sprite back and forth along the bottom of the main screen.
  One crossing takes 60 s, exactly like the site.
- Flips to face the direction of travel when he reaches an edge.
- Sits above the taskbar (Windows) / Dock (macOS).
- Floats over other windows. Clicks pass straight through everywhere except
  his own body.
- **Click him to pause** — he dims to 55% while stopped. Click again to walk on.
- **Double-click him to quit.** He also quits from the tray icon / menu bar.
- Never takes focus, never appears in the taskbar, Dock, Alt-Tab or Cmd-Tab.
- Freezes while the screen is locked.

## What it never does

- No network access of any kind. No sockets, no HTTP, no telemetry, no update check.
- Writes no files, reads no files except its own embedded sprite.
- Touches no registry keys, no login items, no startup entries.
- Requests no admin rights (`asInvoker` / no elevation).
- No installer, no background service, no drivers, no input hooks, no
  accessibility permissions, no screen recording. He cannot see your keystrokes
  or your windows; he only draws himself.
- No persistence after quit. Close him and there is nothing left running.

The whole thing is ~300 lines of readable source per platform. Every line is in
this folder.

---

## Windows

### Run it

Build it with the two commands below, then run `dist/Rudy.exe`.

The first launch shows Windows SmartScreen — *"Windows protected your PC"* —
because the file is not code-signed. Click **More info → Run anyway**. That is
a one-time dialog and it is the only prompt you will ever see: there is no
installer, no UAC prompt, and no runtime to download.

Quit him by right-clicking the tray icon → **Quit Rudy**, or by double-clicking him.

### Build it

```powershell
powershell -ExecutionPolicy Bypass -File win\make-icon.ps1   # only needed if the sprite changes
powershell -ExecutionPolicy Bypass -File win\build.ps1
```

`build.ps1` calls the C# compiler that ships inside Windows itself
(`%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`), so there is no SDK,
no NuGet, and no project file. The sprite sheet and the icon are embedded as
resources, which is why the output is a single self-contained file.

---

## macOS

### Build it (10 seconds)

```bash
xcode-select --install     # once, if you have never used a compiler
cd mac
./build.sh
open ../dist/Rudy.app
```

Building it yourself is the point: a locally compiled app carries no quarantine
flag, so macOS opens it with **no "unidentified developer" dialog at all**. An
unsigned `.app` that arrives over the internet would need a detour through
System Settings → Privacy & Security → Open Anyway, which is exactly the kind of
thing that makes an app look suspicious.

Quit him from the **Rudy** menu-bar item → **Quit Rudy**, or by double-clicking him.

---

## Tuning

All the behaviour lives in a small block of constants at the top of each file.

| Constant | Default | Meaning |
|---|---|---|
| `CROSS_SECONDS` | 60 | Seconds to walk the full screen width |
| `FRAME_FPS` | 6 | Walk-cycle frame rate (the sheet has 6 frames) |
| `INSET_L` | 11 | Empty columns left of the drawn edge in each cell |
| `INSET_R` | 12 | Empty columns right of the drawn edge |
| `PAD_BOTTOM` | 9 | Empty rows under his feet |
| `PAUSED_OPACITY` | 0.55 | How much he dims while paused |
| `CLICK_DELAY_MS` / `CLICK_DELAY` | 250 | How long a single click waits in case it is a double-click |

**Clicks and click-through.** Pausing on click means he can no longer ignore the
mouse entirely. On Windows a layered window hit-tests by its own alpha, so only
his drawn silhouette catches clicks — the empty corners of his cell still pass
straight through to whatever is behind him. AppKit has no equivalent, so on
macOS his whole ~96 pt box is clickable; that is the only behavioural
difference between the two builds.

**The outline.** Rudy is a solid black silhouette with a 1 px pink edge, which
is what keeps him readable over a dark wallpaper — on the site he has the light
`WalkingLine` strip behind him instead. The outline is part of
`spritesheetV2.png`; neither build draws one of its own.

**Retina.** `spritesheet.png` is 128 px per frame. On a Retina Mac that is
slightly soft, exactly like the site is. Re-exporting the six frames at 256 px
from `Untitled-1.psd` and dropping them at `shared/spritesheet.png` fixes it for
both platforms.

---

## Layout

```
shared/spritesheet.png   spritesheetV2.png — 6 x 128 px frames (30 KB)
win/Rudy.cs              the Windows app
win/app.manifest         per-monitor DPI, no elevation
win/make-icon.ps1        generates rudy.ico from the sprite
win/build.ps1            one csc call
mac/Rudy.swift           the macOS app
mac/Info.plist           LSUIElement (menu-bar only, no Dock icon)
mac/build.sh             swiftc + lipo + ad-hoc codesign
```

## Verifying it

If you are on the receiving end and would rather not trust a stranger:

1. Read the source above. It is short.
2. Check the imports — neither binary links `WinINet`, `WinHTTP`, `ws2_32`,
   `URLSession` or anything else that could phone home.
3. Run it once and watch it in Process Monitor / Little Snitch. Nothing happens
   except drawing.
4. Quit it. Nothing remains installed.
