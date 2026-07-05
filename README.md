# JWMediaFix
Maintains JW Library's media window maximized on your chosen secondary monitor.

---

## The problem
On multi-monitor setups, JW Library's secondary window for media presentation opens in an exclusive fullscreen state. Exclusive fullscreen windows minimize the instant any other window on that display gets focus, interrupting presentations and causing distractions (e.g., Zoom Workplace hijacking the secondary monitor, or trying to move any program onto the media monitor).

Also, JW Library always opens its secondary window on the same monitor, regardless of whether the user moved the media window to a different monitor in a previous session.

## The Fix
**JWMediaFix** is an AutoHotkey script that automatically moves JW Library's media window to the monitor the user selects and keeps it maximized there, showing persistently, and making it possible to show other programs on the media monitor with no need to re-focus JW Library's media window.

## Usage
### First run

Place `JWMediaFix.exe` anywhere and run it. The program automatically picks your first non-primary monitor as the media monitor.

### Select a monitor

Left-click the tray icon or press Ctrl+Alt+J ─ A pulsing purple overlay appears over the monitor the cursor is on, move to the monitor for media display and left-click to confirm. Press Escape or Right-click to cancel monitor selection mode.

### The fix is automatic from that point

Whenever JW Library opens, the program detects the media window, fixes it, and moves it to your selected monitor. If the window gets minimized or windowed later, it is maximized automatically.

### Media Monitor

is stored in the Windows registry under `HKCU\Software\JWMediaWindowFix`.

### AutoStart

Right-click the tray icon and check AutoStart to have JW Library and the fix start automatically when you log in to Windows.

---

### JW Library Startup focus

JW Library has a bug where it can crash if it does not have window focus during the first few seconds after it opens. To work around this, on a fresh launch the script briefly gives JW Library main window focus while it waits for the media window to appear.

This workaround can still fail if focus is repeatedly pulled away from JW Library while it's still initializing. If you see JW Library crash on launch, try letting it sit focused and undisturbed for a few seconds after opening before switching to another window.

---

## Antivirus alerts

Some antivirus programs may flag this application. This is a **false positive**.

Here is why it happens: this program is built with AutoHotkey, a scripting tool that compiles to a standalone `.exe`. AutoHotkey is also commonly used to write automation scripts, and some antivirus engines flag any AutoHotkey-compiled executable as suspicious by pattern-matching the file format, regardless of what the code actually does.

**This program:**
- Does not connect to the internet
- Does not access your files, documents, or personal data
- Only interacts with JW Library's windows on screen
- Only writes to your own registry key (`HKCU\Software\JWMediaWindowFix`) to remember your monitor choice
- Creates Task Scheduler tasks (only if you enable AutoStart) that are visible in Windows Task Scheduler

**If you are suspicious, you are encouraged to:**
1. Read the source code — the full `.ahk` source is available in this repository
2. Compile it yourself using AutoHotkey v2 (see Compiling section below) — the resulting `.exe` will have the same behavior

To allow the program in your antivirus, add an exception for the `.exe` file. The exact steps depend on your antivirus software.

## Compiling from source

You need [AutoHotkey v2](https://github.com/AutoHotkey/AutoHotkey/releases) And [Ahk2Exe](https://github.com/AutoHotkey/Ahk2Exe/releases) installed.

1. Clone this repository

**Option A — Context menu**

2. Right-click `JWMediaFix.ahk` in File Explorer.
3. Click **Compile Script** (added to the context menu by the AutoHotkey installer).
4. `JWMediaFix.exe` is created in the same folder.

**Option B — Command line**

Run Ahk2Exe directly, pointing it at the script (installed by default under `C:\Program Files\AutoHotkey\Compiler\Ahk2exe.exe`):

```powershell
"C:\Program Files\AutoHotkey\Compiler\Ahk2exe.exe" /in "JWMediaFix.ahk"
```

---

## Donations

This program is free and will remain free. If it has been useful to you, a donation is appreciated but never required. [Github Sponsors](https://github.com/sponsors/vicentegaete5)


## Disclaimer

This project is not affiliated with, endorsed by, or connected to Jehovah's Witnesses or the Watch Tower Bible and Tract Society. JW Library is a trademark of the Watch Tower Bible and Tract Society of Pennsylvania.

## License

Released under the [MIT License](LICENSE).
