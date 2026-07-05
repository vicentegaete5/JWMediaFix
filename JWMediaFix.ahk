#Requires AutoHotkey v2.0

;@Ahk2Exe-ExeName JWMediaFix
;@Ahk2Exe-SetMainIcon JWMediaFix.ico
;@Ahk2Exe-SetName JWMediaFix
;@Ahk2Exe-SetCompanyName Unnamed250
;@Ahk2Exe-SetProductName JWMediaFix
;@Ahk2Exe-SetVersion 1.0

A_IconTip := "JWMediaFix"

#SingleInstance Force
SendMode "Event"
SetWorkingDir A_ScriptDir

; ── CONFIG ───────────────────────────────────────────────────
MEDIA_SETTLE_MS     := 300    ; pause before double-clicking
CHECK_INTERVAL_MS   := 250    ; how often the watch loop polls

; Registry path for persistent settings (HKCU, no admin required).
REG_KEY := "HKCU\Software\JWMediaWindowFix"

; Secondary/media monitor bounds - computed dynamically from
; whichever monitor number is saved in the config (see Settings
; section below).
global SecMonLeft   := 0
global SecMonTop    := 0
global SecMonRight  := 0
global SecMonBottom := 0
global SecMonCX     := 0
global SecMonCY     := 0
global MediaMonitorNum := 0

; ── Pick-Monitor mode state ──────────────────────────────────
; When the user activates Pick-Monitor mode (Ctrl+Alt+J or left-clicking 
; tray icon), the script enters a state where the next left mouse click selects
; the media monitor. A translucent light-purple overlay covers the
; monitor the cursor is currently on, fading in/out as the cursor
; moves between monitors.
global PickModeActive       := false  ; true while pick-mode is running
global PickModeOverlayGui   := 0      ; Gui object for the overlay window
global PickModeLastMonitor  := 0      ; last AHK monitor index the cursor was on
global PickModeOverlayAlpha := 0      ; current overlay alpha (for pulse animation)
global PickModeAlphaDir     := 1      ; 1 = fading in, -1 = fading out

; ── Cached window identities ────────────────────────────────
; MainHwnd is kept only as a reference / for completeness
; No fix routine ever targets it.
global MainHwnd  := 0
global MediaHwnd := 0
; Tracks whether the media window has ever been successfully
; identified during the current JW Library launch. Reset to false
; whenever JW Library fully closes (see DiscoverWindowIdentities),
; Used to gate main window focus while waiting for media window
; so it only fires on a genuine fresh launch, not every time the
; cache gets cleared (e.g. by a monitor change).
global HasSeenMediaWindowThisSession := false
; Tick-count timestamp of the last time the media window was
; successfully detected/confirmed to exist. Used to suppress the
; main-window focus-grab below if the media window was seen very
; recently (within MEDIA_RECENT_DETECTION_MS) - if the media
; window is already known and active, there's no reason to pull
; focus toward the main window at all.
global LastMediaWindowSeenTick := 0
MEDIA_RECENT_DETECTION_MS := 2000  ; "recently seen" threshold

; ── Physical resolution ─────────────────────────────────────

; Returns the TRUE physical pixel resolution of the monitor that
; contains the given point, using GetDeviceCaps on a monitor DC.
GetMonitorPhysicalResolution(monLeft, monTop, monRight, monBottom) {
    cx := monLeft + ((monRight - monLeft) // 2)
    cy := monTop  + ((monBottom - monTop) // 2)

    pt := Buffer(8, 0)
    NumPut("Int", cx, pt, 0)
    NumPut("Int", cy, pt, 4)

    hMon := DllCall(
        "MonitorFromPoint",
        "Int64", NumGet(pt, 0, "Int64"),
        "UInt",  2,          ; MONITOR_DEFAULTTONEAREST
        "Ptr"
    )

    ; To get per-monitor physical size a DC specific to that 
    ; monitor is needed. The most reliable cross-version way is 
    ; to use the MONITORINFOEX device name to create the DC.
    MONITORINFOEX_SIZE := 104
    mi := Buffer(MONITORINFOEX_SIZE, 0)
    NumPut("UInt", MONITORINFOEX_SIZE, mi, 0)  ; cbSize must be set before call
    if !DllCall("GetMonitorInfo", "Ptr", hMon, "Ptr", mi)
        return {w: monRight - monLeft, h: monBottom - monTop}  ; logical fallback
    ; Device name starts at offset 40 (after cbSize+flags+2xRECT)
    devName := StrGet(mi.Ptr + 40, 32, "UTF-16")

    hDC := DllCall("CreateDCA", "Str", devName, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr")
    if !hDC
        return {w: monRight - monLeft, h: monBottom - monTop}  ; logical fallback

    ; HORZRES (8) = physical horizontal pixel count
    ; VERTRES (10) = physical vertical pixel count
    physW := DllCall("GetDeviceCaps", "Ptr", hDC, "Int", 8,  "Int")  ; HORZRES
    physH := DllCall("GetDeviceCaps", "Ptr", hDC, "Int", 10, "Int")  ; VERTRES
    DllCall("DeleteDC", "Ptr", hDC)

    return {w: physW, h: physH}
}

; ── Monitor enumeration ──────────────────────────────────────

; Returns an array of {num, left, top, right, bottom, isPrimary}
; for every connected monitor.
;   num       = AHK's internal 1-based index, used for all API
;               calls and config persistence.
;   isPrimary = true for the system's main/primary display.
GetMonitorList() {
    list := []
    primaryIdx := MonitorGetPrimary()

    Loop MonitorGetCount() {
        MonitorGet A_Index, &l, &t, &r, &b
        list.Push({
            num:       A_Index,
            left:  l,
            top:   t,
            right: r,
            bottom:b,
            isPrimary: (A_Index = primaryIdx)
        })
    }

    return list
}


; ── Settings persistence (registry) ─────────────────────────
; Settings are stored in HKCU\Software\JWMediaWindowFix so they
; persist across sessions without needing a file next to the exe.
; HKCU requires no admin rights and is per-user by design.

LoadMediaMonitorSetting() {
    global REG_KEY
    try
        return Integer(RegRead(REG_KEY, "MediaMonitor"))
    catch
        return 0  ; key doesn't exist yet (first run)
}

SaveMediaMonitorSetting(monitorNum) {
    global REG_KEY
    RegWrite(monitorNum, "REG_DWORD", REG_KEY, "MediaMonitor")
}

; Returns the monitor number (matching GetMonitorList()'s .num)
; whose bounds contain the given window's center point, or 0 if
; the window doesn't exist or doesn't fall on any monitor.
GetMonitorNumForWindow(hwnd) {
    if !WinExist("ahk_id " . hwnd)
        return 0

    try
        WinGetPos &wx, &wy, &ww, &wh, "ahk_id " . hwnd
    catch
        return 0

    cx := wx + (ww // 2)
    cy := wy + (wh // 2)

    monitors := GetMonitorList()
    for m in monitors {
        if (cx >= m.left && cx < m.right && cy >= m.top && cy < m.bottom)
            return m.num
    }

    return 0
}

; ── Autostart Task Scheduler ────────────────────────────────
; Implemented via schtasks.exe so the task can be configured to 
; ignore AC/battery power state and run at logon for the current 
; user with 15 seconds of delay giving Explorer time to finish 
; starting up before running.

AUTOSTART_TASK_NAME := "JWMediaFix"

; Returns true if a scheduled task with our task name currently
; exists (regardless of its exact configuration).
IsAutoStartTaskEnabled() {
    global AUTOSTART_TASK_NAME

    ; /Query with a specific /TN returns a non-zero exit code if
    ; the task does not exist, and 0 if it does - this is the
    ; standard way to check task existence via schtasks.exe.
    exitCode := RunWait(
        'schtasks.exe /Query /TN "' . AUTOSTART_TASK_NAME . '"',
        ,
        "Hide"
    )

    return (exitCode = 0)
}

; Creates the scheduled task.
EnableAutoStartTask() {
    global AUTOSTART_TASK_NAME

    ; This script must be running as a compiled .exe for the
    ; scheduled task to have something stable to point at - if
    ; run as a raw .ahk script during development, autostart
    ; can't be meaningfully configured this way.
    if !A_IsCompiled {
        MsgBox(
            "AutoStart via Task Scheduler requires the compiled "
            . ".exe version of this script (not the raw .ahk "
            . "script). Compile it first, then try again.",
            "JWMediaFix"
        )
        return false
    }

    exePath := A_ScriptFullPath
    ; A_UserName (e.g. "John") is used rather than a SID - Task
    ; Scheduler resolves a plain username to the correct account
    ; at import time, and unlike a hardcoded SID, a username stays
    ; valid if this XML is ever inspected/reused on a different
    ; machine.
    userId := A_UserName

    ; XML escaping for the few characters that could plausibly
    ; appear in a Windows file path (backslashes are fine as-is in
    ; XML text content and need no escaping).
    exePathXml := StrReplace(exePath, "&", "&amp;")
    exePathXml := StrReplace(exePathXml, "<", "&lt;")
    exePathXml := StrReplace(exePathXml, ">", "&gt;")

    ; Minimal Task Scheduler XML task definition:
    ;   - LogonTrigger with a 15s Delay -> waits briefly after logon
    ;     before running (see WaitForInteractiveDesktop below too)
    ;   - DisallowStartIfOnBatteries = false -> runs even on battery
    ;   - StopIfGoingOnBatteries     = false -> doesn't get killed
    ;     if AC is unplugged while it's already running
    ;   - RunLevel = LeastPrivilege  -> standard user rights, no
    ;     elevation/UAC prompt needed
    taskXml :=
        '<?xml version="1.0" encoding="UTF-16"?>`n'
        . '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">`n'
        . '  <Triggers>`n'
        . '    <LogonTrigger>`n'
        . '      <Enabled>true</Enabled>`n'
        . '      <UserId>' . userId . '</UserId>`n'
        . '      <Delay>PT15S</Delay>`n'
        . '    </LogonTrigger>`n'
        . '  </Triggers>`n'
        . '  <Principals>`n'
        . '    <Principal id="Author">`n'
        . '      <LogonType>InteractiveToken</LogonType>`n'
        . '      <RunLevel>LeastPrivilege</RunLevel>`n'
        . '    </Principal>`n'
        . '  </Principals>`n'
        . '  <Settings>`n'
        . '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>`n'
        . '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>`n'
        . '    <StartWhenAvailable>true</StartWhenAvailable>`n'
        . '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>`n'
        . '  </Settings>`n'
        . '  <Actions Context="Author">`n'
        . '    <Exec>`n'
        . '      <Command>' . exePathXml . '</Command>`n'
        . '      <Arguments>--Launch JW</Arguments>`n'
        . '    </Exec>`n'
        . '  </Actions>`n'
        . '</Task>'

    ; Write the XML to a temp file - /Create /XML requires a file
    ; path, it cannot take the XML content inline on the command
    ; line.
    xmlPath := A_Temp . "\JWMediaFixTask.xml"

    try {
        ; Task Scheduler expects UTF-16 LE with BOM for /XML import.
        f := FileOpen(xmlPath, "w", "UTF-16")
        f.Write(taskXml)
        f.Close()
    } catch as e {
        MsgBox("Could not write the task definition file:`n" . e.Message)
        return false
    }

    createCmd :=
        'schtasks.exe /Create /F'
        . ' /TN "' . AUTOSTART_TASK_NAME . '"'
        . ' /XML "' . xmlPath . '"'

    exitCode := RunWait(createCmd, , "Hide")

    try FileDelete(xmlPath)

    if (exitCode != 0) {
        MsgBox("Could not create the scheduled task (exit code " . exitCode . ").")
        return false
    }

    return true
}

; Removes the scheduled task created by EnableAutoStartTask(), if
; it exists.
DisableAutoStartTask() {
    global AUTOSTART_TASK_NAME

    RunWait(
        'schtasks.exe /Delete /F /TN "' . AUTOSTART_TASK_NAME . '"',
        ,
        "Hide"
    )

    ; Always report success: the end state we want (no task) is
    ; achieved whether the task existed and was deleted, or never
    ; existed in the first place.
    return true
}

; ── Apply a chosen monitor number to the global SecMon* vars ──

ApplyMediaMonitor(monitorNum) {
    global SecMonLeft, SecMonTop, SecMonRight, SecMonBottom
    global SecMonCX, SecMonCY, MediaMonitorNum
    global MediaHwnd

    monitors := GetMonitorList()

    found := 0
    for m in monitors {
        if (m.num = monitorNum) {
            found := m
            break
        }
    }

    if !found {
        ; Saved monitor number no longer exists (e.g. monitor was
        ; unplugged/rearranged) - fall back to the first non-
        ; primary monitor if one exists, else monitor 1.
        for m in monitors {
            if !m.isPrimary {
                found := m
                break
            }
        }
        if !found
            found := monitors[1]
    }

    SecMonLeft   := found.left
    SecMonTop    := found.top
    SecMonRight  := found.right
    SecMonBottom := found.bottom
    SecMonCX     := SecMonLeft + ((SecMonRight  - SecMonLeft) // 2)
    SecMonCY     := SecMonTop  + ((SecMonBottom - SecMonTop)  // 2)
    MediaMonitorNum := found.num

    ; If the media window is already open, move it immediately
    ; to the newly selected monitor.
    if (MediaHwnd && WinExist("ahk_id " . MediaHwnd))
        ApplyMoveToTargetMonitor(MediaHwnd)
}

; ── Monitor change detection ─────────────────────────────────
; Periodically checks whether the display configuration has changed
; (monitor count, bounds, or which monitor is primary) and silently
; re-applies if so, without requiring a restart.

global LastMediaMonitorSignature := ""
global LastMonitorCheckTick := 0
MONITOR_CHECK_INTERVAL_MS := 3000  ; how often to check for display changes

; Builds a short string capturing everything about the current
; display config that matters to this script, so a single string
; comparison detects any relevant change.
BuildMonitorSignature() {
    global MediaMonitorNum

    sig := "count=" . MonitorGetCount() . "|primary=" . MonitorGetPrimary()

    monitors := GetMonitorList()
    for m in monitors {
        if (m.num = MediaMonitorNum) {
            phys := GetMonitorPhysicalResolution(m.left, m.top, m.right, m.bottom)
            sig .= "|media=" . m.num . ":" . m.left . "," . m.top . "," . m.right . "," . m.bottom . "," . phys.w . "x" . phys.h
            break
        }
    }

    return sig
}

; If the monitor currently selected for media has become the
; PRIMARY display (e.g. user changed it in Windows Display
; Settings), picks the lowest-numbered non-primary monitor 
; and switches to it. Returns true if a switch was made.
ResolveMediaMonitorIsNowPrimary() {
    global MediaMonitorNum

    if !MediaMonitorNum
        return false

    monitors := GetMonitorList()

    selectedIsPrimary := false
    for m in monitors {
        if (m.num = MediaMonitorNum && m.isPrimary) {
            selectedIsPrimary := true
            break
        }
    }

    if !selectedIsPrimary
        return false  ; no problem

    newChoice := 0
    for m in monitors {
        if !m.isPrimary {
            newChoice := m.num
            break  ; monitors are already in ascending .num order
        }
    }

    if !newChoice
        return false  ; only one monitor exists - nothing else to pick

    SaveMediaMonitorSetting(newChoice)
    ApplyMediaMonitor(newChoice)
    return true
}

; If MainHwnd is currently a cached, valid window handle, and that
; window is sitting on the monitor selected for media, picks the
; lowest-numbered monitor that does NOT contain it and switches to
; that. Returns true if a switch was made, false otherwise (no
; cached MainHwnd, window no longer exists, or it's not on the
; media monitor).
;
; MainHwnd is only set by DiscoverWindowIdentities(), which only
; runs while the media window is unknown - see the note in
; CheckForMonitorChanges() for why this makes the check unreliable
; once the media window is already up and running.
ResolveMainWindowMonitorCollision() {
    global MainHwnd, MediaMonitorNum

    if !MainHwnd
        return false

    mainMonNum := GetMonitorNumForWindow(MainHwnd)

    if (!mainMonNum || mainMonNum != MediaMonitorNum)
        return false  ; no collision

    ; The main window is on the currently-selected media monitor -
    ; find the lowest-numbered monitor that does NOT contain it.
    monitors := GetMonitorList()

    newChoice := 0
    for m in monitors {
        if (m.num != mainMonNum) {
            newChoice := m.num
            break  ; monitors are already in ascending .num order
        }
    }

    if !newChoice
        return false  ; only one monitor exists - nothing else to pick

    SaveMediaMonitorSetting(newChoice)
    ApplyMediaMonitor(newChoice)
    return true
}

; Call periodically from the main loop. Throttled to
; MONITOR_CHECK_INTERVAL_MS to avoid running every tick.
; Checks three situations and silently re-applies if needed:
;   1. Selected media monitor became the primary display.
;   2. Main JW window moved onto the media monitor.
;   3. Display config changed (resolution, monitor count, etc.).
CheckForMonitorChanges() {
    global LastMonitorCheckTick, LastMediaMonitorSignature
    global MONITOR_CHECK_INTERVAL_MS, MediaMonitorNum

    if (A_TickCount - LastMonitorCheckTick < MONITOR_CHECK_INTERVAL_MS)
        return

    LastMonitorCheckTick := A_TickCount

    ; Check #1: has the monitor currently selected for media
    ; become the PRIMARY display (e.g. changed in Windows Display
    ; Settings)? This is checked independent of whether JW Library
    ; is even running, since the media monitor should never be the
    ; main display regardless.
    if ResolveMediaMonitorIsNowPrimary() {
        RebuildTrayMenu()
        LastMediaMonitorSignature := BuildMonitorSignature()
        return
    }

    ; Check #2: if MainHwnd happens to already be cached with a
    ; valid handle, is it currently sitting on the monitor selected
    ; for media? If so, switch the media monitor to the lowest-
    ; numbered monitor that isn't the main window's monitor.
    ;
    ; NOTE: this is NOT a continuous "main window moved" watchdog.
    ; MainHwnd is only ever (re)populated inside
    ; DiscoverWindowIdentities(), which the main loop only calls
    ; while the media window is unknown/missing. Once the media
    ; window is confirmed working, MainHwnd is never refreshed
    ; again for the rest of that session - so this check either
    ; keeps working off a handle captured earlier (if one was
    ; captured), or stays a permanent no-op for the whole session
    ; if the script started while the media window was already
    ; correctly placed (that startup path never sets MainHwnd at
    ; all). Don't rely on this to catch the main window being
    ; dragged onto the media monitor after the fact.
    if ResolveMainWindowMonitorCollision() {
        RebuildTrayMenu()
        LastMediaMonitorSignature := BuildMonitorSignature()
        return
    }

    ; Check #3: has the display configuration itself changed -
    ; monitor count, primary display, or the selected media
    ; monitor's own bounds?
    currentSig := BuildMonitorSignature()

    if (currentSig = LastMediaMonitorSignature)
        return  ; nothing relevant changed

    LastMediaMonitorSignature := currentSig

    ; Something changed. Re-resolve the saved monitor number
    ; against the current display config - ApplyMediaMonitor()
    ; already handles the "saved monitor no longer exists"
    ; fallback case too.
    ApplyMediaMonitor(MediaMonitorNum)
    RebuildTrayMenu()
}


; ── First-run monitor auto-selection ────────────────────────

; Silently picks the first non-primary monitor and saves it.
; Called when no saved setting exists or the saved monitor is gone.
; The user can change the selection at any time via the tray menu.
AutoSelectMediaMonitor() {
    monitors := GetMonitorList()

    if (monitors.Length < 1) {
        MsgBox("No monitors detected.",
            "JWMediaFix")
        ExitApp
    }

    chosen := 0
    for m in monitors {
        if !m.isPrimary {
            chosen := m.num
            break
        }
    }

    ; Only one monitor exists (it's the primary) - nothing else
    ; to pick, use it anyway since there's no alternative.
    if !chosen
        chosen := monitors[1].num

    SaveMediaMonitorSetting(chosen)
    ApplyMediaMonitor(chosen)
}

; ── Tray menu ────────────────────────────────────────────────


; Shows a brief info popup when the "JWMediaFix" header
; item is clicked - this keeps it as a genuinely normal, clickable
; (non-grayed) menu entry rather than a fake disabled label, per
; the request that this entry not appear grayed out.
OnHeaderMenuClick(*) {
    MsgBox(
        "Maintains JW Library media window maximized "
        "on your chosen secondary monitor.`n`n"
        "Left-click the TrayIcon or Press Ctrl+Alt+J to enter monitor "
        "selection mode, then click the monitor for media display.`n`n"
        "Press Escape or Right-click to cancel.",
        "JWMediaFix v1.0"
    )
}


; ── PICK-MONITOR MODE ───────────────────────────────────────
; Allows the user to select the media monitor by clicking on it,
; with a pulsing light-purple overlay highlighting the monitor
; currently under the cursor.
;
; Entry points:
;   - "Pick monitor by clicking" tray menu item
;   - Ctrl+Alt+J hotkey
;
; While active:
;   - A pulsing translucent light-purple overlay covers the
;     monitor the cursor is currently on.
;   - Moving the cursor to a different monitor moves the overlay.
;   - Left-clicking confirms the monitor under the cursor.
;   - Escape or Right Click cancels without changing anything.
; ────────────────────────────────────────────────────────────

; Returns the AHK monitor index (1-based) that the cursor is
; currently on, or 0 if the cursor isn't on any monitor.
GetCursorMonitorNum() {
    CoordMode "Mouse", "Screen"
    MouseGetPos &mx, &my

    Loop MonitorGetCount() {
        MonitorGet A_Index, &l, &t, &r, &b
        if (mx >= l && mx < r && my >= t && my < b)
            return A_Index
    }

    return 0
}

; Creates and shows the pick-mode overlay on the given AHK monitor
; index. Destroys any existing overlay first.
ShowPickOverlay(monitorNum) {
    global PickModeOverlayGui, PickModeOverlayAlpha, PickModeAlphaDir

    DestroyPickOverlay()

    MonitorGet monitorNum, &l, &t, &r, &b
    w := r - l
    h := b - t

    ; Build a borderless, topmost, click-through, toolwindow Gui
    ; (toolwindow = no taskbar button) filled with light purple.
    ; WS_EX_TRANSPARENT makes it click-through so the click that
    ; confirms the monitor selection lands on whatever is behind
    ; the overlay, not on the overlay itself.
    PickModeOverlayGui := Gui(
        "+AlwaysOnTop -Caption +ToolWindow +E0x20",  ; E0x20 = WS_EX_TRANSPARENT
        "JWPickOverlay"
    )
    PickModeOverlayGui.BackColor := "9B59B6"  ; light purple (Material-ish)
    PickModeOverlayGui.Show(
        "x" . l . " y" . t . " w" . w . " h" . h . " NoActivate"
    )

    ; Start at low alpha and let the pulse timer animate it.
    PickModeOverlayAlpha := 20
    PickModeAlphaDir := 1
    WinSetTransparent(PickModeOverlayAlpha, PickModeOverlayGui)
}

; Destroys the overlay Gui if it exists.
DestroyPickOverlay() {
    global PickModeOverlayGui
    try {
        if PickModeOverlayGui {
            PickModeOverlayGui.Destroy()
            PickModeOverlayGui := 0
        }
    }
}

; Timer callback - runs every 40ms while pick-mode is active.
; Handles two things:
;   1. Moves the overlay to follow the cursor if it changes monitor.
;   2. Pulses the overlay alpha between ~20 and ~80 for the
;      appearing/disappearing light-purple effect.
PickModeTick() {
    global PickModeActive, PickModeLastMonitor
    global PickModeOverlayGui, PickModeOverlayAlpha, PickModeAlphaDir

    if !PickModeActive {
        SetTimer(PickModeTick, 0)  ; stop the timer
        return
    }

    ; ── Move overlay if cursor changed monitor ───────────────
    curMon := GetCursorMonitorNum()
    if (curMon && curMon != PickModeLastMonitor) {
        PickModeLastMonitor := curMon
        ShowPickOverlay(curMon)
    }

    ; ── Pulse the alpha ──────────────────────────────────────
    ; Step the alpha by 4 per tick (40ms * 4 = ~160ms full cycle).
    PickModeOverlayAlpha += PickModeAlphaDir * 4
    if (PickModeOverlayAlpha >= 80) {
        PickModeOverlayAlpha := 80
        PickModeAlphaDir := -1   ; start fading out
    }
    else if (PickModeOverlayAlpha <= 20) {
        PickModeOverlayAlpha := 20
        PickModeAlphaDir := 1    ; start fading in
    }

    if PickModeOverlayGui
        WinSetTransparent(PickModeOverlayAlpha, PickModeOverlayGui)
}

; Enters pick-monitor mode.
EnterPickMode() {
    global PickModeActive, PickModeLastMonitor

    if PickModeActive
        return  ; already active

    PickModeActive := true

    ; Show the overlay on whichever monitor the cursor is on now.
    PickModeLastMonitor := GetCursorMonitorNum()
    if PickModeLastMonitor
        ShowPickOverlay(PickModeLastMonitor)

    ; Start the tick timer for overlay movement + pulse animation.
    SetTimer(PickModeTick, 40)

    ; Intercept the next left click to confirm the selection.
    ; The click is consumed so it doesn't reach whatever is underneath.
    Hotkey("LButton", OnPickModeClick, "On")

    ; Escape or Right Click cancels pick-mode without changing anything.
    ; Right-click is also consumed.
    Hotkey("Escape", OnPickModeCancel, "On")
    Hotkey("RButton Up", OnPickModeCancel, "On")
}

; Exits pick-mode cleanly, removing all hooks and the overlay.
; Called both on confirm and on cancel.
ExitPickMode() {
    global PickModeActive

    PickModeActive := false

    SetTimer(PickModeTick, 0)
    DestroyPickOverlay()

    ; Remove all three pick-mode hotkeys.
    try Hotkey("LButton", "Off")
    try Hotkey("Escape",  "Off")
    try Hotkey("RButton Up", "Off")
}

; Called when the user left-clicks while in pick-mode.
; Reads which monitor the cursor is on and sets it as the media
; monitor, then exits pick-mode.
OnPickModeClick(*) {
    global MediaHwnd

    ExitPickMode()

    monNum := GetCursorMonitorNum()
    if !monNum
        return  ; cursor not on any monitor - treat as cancel

    ; Don't allow picking the primary monitor as the media monitor,
    ; consistent with the tray menu's disabled primary entry.
    primaryIdx := MonitorGetPrimary()
    if (monNum = primaryIdx) {
        MsgBox(
            "The main display cannot be used as the media monitor.",
            "JWMediaFix",
            0x30  ; MB_ICONWARNING
        )
        return
    }

    SaveMediaMonitorSetting(monNum)
    ApplyMediaMonitor(monNum)

    if (MediaHwnd && WinExist("ahk_id " . MediaHwnd))
        ApplyMoveToTargetMonitor(MediaHwnd)

    RebuildTrayMenu()
}

; Called when the user presses Escape or Right Click while in pick-mode.
OnPickModeCancel(*) {
    ExitPickMode()
}

; ── Hotkey registration ──────────────────────────────────────
; Ctrl+Alt+J or left-clicking the tray icon activates pick-monitor mode.
; The ~LButton and Escape hotkeys are registered/unregistered
; dynamically inside EnterPickMode/ExitPickMode so they only
; intercept input during pick-mode, not all the time.

Hotkey("^!j", (*) => EnterPickMode())

OnMessage(0x404, TrayIconHandler)

TrayIconHandler(wParam, lParam, msg, hwnd) {
    static WM_LBUTTONUP := 0x202

    if (lParam = WM_LBUTTONUP) {
        EnterPickMode()
        return 0
    }
}

RebuildTrayMenu() {
    tray := A_TrayMenu
    tray.Delete()

    ; Version entry - clickable, shows a brief info popup.
    tray.Add("JWMediaFix", OnHeaderMenuClick)

    tray.Add()  ; separator

    ; AutoStart - reflects the actual current state of the scheduled
    ; task (queried live via schtasks.exe), so it can never drift
    ; out of sync with reality even if the task is managed manually.
    autoStartLabel := "AutoStart"
    tray.Add(autoStartLabel, OnAutoStartMenuClick)
    if IsAutoStartTaskEnabled()
        tray.Check(autoStartLabel)

    tray.Add()  ; separator

    tray.Add("Exit", (*) => ExitApp())
}

; Toggles the AutoStart scheduled task on/off and refreshes the
; tray menu to reflect the new state.
OnAutoStartMenuClick(*) {
    if IsAutoStartTaskEnabled()
        DisableAutoStartTask()
    else
        EnableAutoStartTask()

    RebuildTrayMenu()
}

; ── Settings initialization (runs once at script start) ──────

InitializeSettings() {
    savedMonitor := LoadMediaMonitorSetting()
    monitors := GetMonitorList()

    monitorStillValid := false
    for m in monitors {
        if (m.num = savedMonitor) {
            monitorStillValid := true
            break
        }
    }

    if (savedMonitor = 0 || !monitorStillValid) {
        ; No saved monitor yet, or the saved one no longer exists
        ; (monitor count/arrangement changed) - auto-pick silently,
        ; no prompt. User can change it anytime via the tray menu.
        AutoSelectMediaMonitor()
    } else {
        ApplyMediaMonitor(savedMonitor)
    }

    RebuildTrayMenu()

    ; Establish the baseline signature so CheckForMonitorChanges()
    ; doesn't immediately think something changed on its first run.
    global LastMediaMonitorSignature, LastMonitorCheckTick
    LastMediaMonitorSignature := BuildMonitorSignature()
    LastMonitorCheckTick := A_TickCount
}

InitializeSettings()

; ── Mouse Lock System ───────────────────────────────────────
global OrigMouseX := 0
global OrigMouseY := 0
global MouseLocked := false

LockMouse() {
    global OrigMouseX, OrigMouseY, MouseLocked
    if MouseLocked
        return
    CoordMode "Mouse", "Screen"
    MouseGetPos &OrigMouseX, &OrigMouseY
    BlockInput "MouseMove"
    MouseLocked := true
}

UnlockMouse() {
    global OrigMouseX, OrigMouseY, MouseLocked
    if !MouseLocked
        return
    try BlockInput "MouseMoveOff"
    CoordMode "Mouse", "Screen"
    MouseMove OrigMouseX, OrigMouseY, 0
    MouseLocked := false
}

WaitFor(fn, timeoutMs, intervalMs := 400) {
    deadline := A_TickCount + timeoutMs
    loop {
        result := fn()
        if result
            return result
        if (A_TickCount >= deadline)
            return 0
        Sleep intervalMs
    }
}

; ── WindowFromPoint-based detection (pre-click, invisible state) ─

GetRootHwndAtPoint(x, y) {
    pt := Buffer(8, 0)
    NumPut("Int", x, pt, 0)
    NumPut("Int", y, pt, 4)
    hwnd := DllCall("WindowFromPoint", "Int64", NumGet(pt, 0, "Int64"), "Ptr")
    if !hwnd
        return 0
    return DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr")  ; GA_ROOT
}

GetClassOf(hwnd) {
    try {
        buf := Buffer(512, 0)
        DllCall("GetClassName", "Ptr", hwnd, "Ptr", buf, "Int", 256)
        return StrGet(buf)
    } catch {
        return ""
    }
}

GetTitleOf(hwnd) {
    try {
        buf := Buffer(512, 0)
        DllCall("GetWindowText", "Ptr", hwnd, "Ptr", buf, "Int", 256)
        return StrGet(buf)
    } catch {
        return ""
    }
}

GetExeOf(hwnd) {
    try {
        return WinGetProcessName("ahk_id " . hwnd)
    } catch {
        return ""
    }
}

; Returns the hwnd if the given screen point is currently showing
; JW Library's Exclusive Fullscreen state (pre-click, unenumerable),
; or 0 if not. Does NOT require the point to be on any specific
; monitor - just checks that whatever window is there is a JW
; Library window in the Exclusive Fullscreen geometry.
CheckPointForExclusiveFSJWWindow(px, py) {
    hwnd := GetRootHwndAtPoint(px, py)
    if !hwnd
        return 0

    if (GetClassOf(hwnd) != "ApplicationFrameWindow")
        return 0

    if !InStr(GetTitleOf(hwnd), "JW Library")
        return 0

    exe := GetExeOf(hwnd)
    if (exe != "JWLibrary.exe" && exe != "ApplicationFrameHost.exe")
        return 0

    ; Already a real maximized window -> not the Exclusive Fullscreen state.
    try {
        if (WinGetMinMax("ahk_id " . hwnd) = 1)
            return 0
    }

    ; Must be approximately monitor-sized (the Exclusive Fullscreen UWP state
    ; always fills the entire monitor it's on) - check against the
    ; actual monitor that contains this point, not just SecMon*.
    try {
        WinGetPos &wx, &wy, &ww, &wh, "ahk_id " . hwnd

        ; Find whichever monitor this window is actually on.
        monitors := GetMonitorList()
        for m in monitors {
            if (
                Abs(wx - m.left) <= 5
                && Abs(wy - m.top) <= 5
                && Abs(ww - (m.right - m.left)) <= 5
                && Abs(wh - (m.bottom - m.top)) <= 5
            )
                return hwnd  ; fills this monitor -> Exclusive Fullscreen state confirmed
        }
    }

    return 0
}

; Checks every non-primary monitor for JW Library's
; Exclusive Fullscreen media window.
;
; The selected media monitor is checked first for
; responsiveness, followed by every remaining
; non-primary monitor.
;
; No assumptions are made about where JW Library
; chooses to open the media window.
DetectExclusiveFSHwnd() {
    global SecMonCX, SecMonCY

    monitors := GetMonitorList()

    ; Check selected monitor first.
    hwnd := CheckPointForExclusiveFSJWWindow(SecMonCX, SecMonCY)

    if hwnd {
        return {
            hwnd: hwnd,
            clickX: SecMonCX,
            clickY: SecMonCY
        }
    }

    ; Check every other non-primary monitor.
    for m in monitors {

        if m.isPrimary
            continue

        centerX := m.left + ((m.right - m.left) // 2)
        centerY := m.top  + ((m.bottom - m.top) // 2)

        ; Skip target monitor (already checked).
        if (centerX = SecMonCX && centerY = SecMonCY)
            continue

        hwnd := CheckPointForExclusiveFSJWWindow(centerX, centerY)

        if hwnd {
            return {
                hwnd: hwnd,
                clickX: centerX,
                clickY: centerY
            }
        }
    }

    return 0
}

; ── Content-based identification (post-click / already-fixed) ───
;
; CONFIRMED RULE (Window Spy "Visible Text" field, via WinGetText):
;   Media window -> Visible Text is EXACTLY "CoreInput", nothing
;                    else, ever (this is the one constant signal
;                    that distinguishes it - always present).
;   Main window  -> Visible Text is "JW Library" alone, OR
;                    "JW Library" + "CoreInput" together, but
;                    NEVER "CoreInput" alone.
;
; So the reliable test is: if text is exactly "CoreInput" -> media.
; Otherwise, if text contains "JW Library" -> main. Checking the
; exact-match media test FIRST guarantees no ambiguity, since the
; two patterns never overlap (main always has "JW Library" present
; somewhere; media never does).

IsJWWindow(id) {
    try {
        exe := WinGetProcessName("ahk_id " . id)
        if (exe != "ApplicationFrameHost.exe" && exe != "JWLibrary.exe")
            return false
        return InStr(WinGetTitle("ahk_id " . id), "JW Library") > 0
    } catch {
        return false
    }
}

; Main window Visible Text is "JW Library" alone, or "JW Library"
; plus "CoreInput" together - but NEVER "CoreInput" by itself.
IsMainWindowByContent(id) {
    try {
        txt := WinGetText("ahk_id " . id)
        return InStr(txt, "JW Library") > 0
    } catch {
        return false
    }
}

; Media window Visible Text is EXACTLY "CoreInput" - confirmed to
; hold true at all times: in the Exclusive Fullscreen pre-fix state, right
; after the click, and once correctly maximized. This is the one
; constant, unambiguous signal for the media window.
IsMediaWindowByContent(id) {
    try {
        txt := Trim(WinGetText("ahk_id " . id), "`r`n `t")
        return (txt = "CoreInput")
    } catch {
        return false
    }
}

; Discover MainHwnd / MediaHwnd via content classification and
; cache the results. Checks media FIRST (stricter exact-match
; test) so it always wins over the looser main-window test for
; any given window.
; NOTE: the one-time main-window focus-grab on fresh JW Library
; launch is now handled directly in the main watch loop (before
; this function is called), not here. This function is purely
; for window identity discovery.
DiscoverWindowIdentities() {
    global MainHwnd, MediaHwnd, HasSeenMediaWindowThisSession

    ids := WinGetList("JW Library")

    foundMain  := 0
    foundMedia := 0

    for id in ids {
        if !IsJWWindow(id)
            continue

        if IsMediaWindowByContent(id)
            foundMedia := id
        else if IsMainWindowByContent(id)
            foundMain := id
    }

    MainHwnd  := foundMain
    MediaHwnd := foundMedia

    ; If the media window is found, mark the session so the
    ; one-time main-window focus-grab doesn't fire again.
    if MediaHwnd
        HasSeenMediaWindowThisSession := true

    ; If NO JW windows exist at all, JW Library has been closed
    ; completely. Reset the session flag so the focus-grab fires
    ; again the next time JW Library is opened.
    if (!foundMain && !foundMedia)
        HasSeenMediaWindowThisSession := false
}


; Moves the media window to the target monitor (SecMonLeft/Top) and
; re-maximizes it there if it's currently on a different monitor.
; Called when MediaHwnd is valid and maximized but not on the right
; monitor - e.g. the user changed the target monitor in the tray menu,
; or JW Library opened the media window on its default monitor
; which differs from the user's selected target.
; Returns true if a move was performed, false if already on the right
; monitor or if the window couldn't be moved.
RestoreMoveAndMaximize(hwnd, restoreSleepMs, moveSleepMs) {
    global SecMonLeft, SecMonTop

    ; Restore first so the window can be moved.
    if (WinGetMinMax("ahk_id " . hwnd) != 0)
        WinRestore("ahk_id " . hwnd)

    Sleep restoreSleepMs

    ; Place it inside the target monitor's bounds.
    WinMove(SecMonLeft + 100, SecMonTop + 100, 900, 600, "ahk_id " . hwnd)

    Sleep moveSleepMs

    ; Maximize on the target monitor.
    WinMaximize("ahk_id " . hwnd)
}

ApplyMoveToTargetMonitor(hwnd) {
    global MediaMonitorNum

    currentMonNum := GetMonitorNumForWindow(hwnd)

    ; Already on the right monitor - nothing to do.
    if (currentMonNum = MediaMonitorNum)
        return false

    prevHwnd := WinExist("A")

    RestoreMoveAndMaximize(hwnd, 150, 150)

    ; Restore focus to whoever had it before.
    if (prevHwnd && WinExist("ahk_id " . prevHwnd))
        try WinActivate("ahk_id " . prevHwnd)

    return true
}

; ── Fix routines ─────────────────────────────────────────────

; Double-click fix for the Exclusive Fullscreen state (pre-click, invisible).
; Takes the hwnd that was ALREADY identified by
; DetectExclusiveFSHwnd() before this was called - that
; identity is trusted directly throughout, by ahk_id, never
; re-derived from content after the click. Content/Visible Text
; is only ever used for the SINGLE initial identification, done
; by the caller before this function runs.
ApplyFullscreenFix(hwnd, clickX, clickY) {
    global MEDIA_SETTLE_MS
    global MainHwnd, MediaHwnd, HasSeenMediaWindowThisSession

    prevHwnd := WinExist("A")

    LockMouse()

    try {
        Sleep MEDIA_SETTLE_MS

        ; Re-verify the same hwnd is still the one sitting there
        ; right before clicking (cheap safety check - the window
        ; itself doesn't change identity, just confirming
        ; it hasn't closed/changed in the settle delay).
        if !WinExist("ahk_id " . hwnd)
            return false

        CoordMode "Mouse", "Screen"
        MouseMove clickX, clickY, 0
        Sleep 150
        Click clickX, clickY, 2

        ; NOTE: testing showed WinGetMinMax often stays at 0 even
        ; after the click successfully lands - it doesn't reliably
        ; flip on its own. The subsequent WinRestore -> WinMove ->
        ; WinMaximize sequence runs unconditionally regardless.
        ; A short fixed delay is enough for the click to register.
        if !WinExist("ahk_id " . hwnd)
            return false

        Sleep 300

        RestoreMoveAndMaximize(hwnd, 200, 200)

        ; hwnd is now confirmed as the working media window.
        ; Mark the session so the one-time focus-grab in
        ; DiscoverWindowIdentities() doesn't fire again.
        MediaHwnd := hwnd
        HasSeenMediaWindowThisSession := true

        return true
    }
    finally {
        UnlockMouse()
        if (prevHwnd && WinExist("ahk_id " . prevHwnd))
            try WinActivate("ahk_id " . prevHwnd)
    }
}

; Normal maximize/restore for an already-enumerable media window
; that's simply minimized or not maximized. Uses ShowWindow
; directly so it never steals focus from whatever the user is
; doing. NEVER called with MainHwnd - only ever MediaHwnd.
ApplyNormalMaximize(hwnd) {
    prevHwnd := WinExist("A")
    try {
        ; SW_SHOWMAXIMIZED is used instead of WinMaximize because it
        ; does not activate the window or steal focus from whatever the
        ; user is currently doing.
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 3)  ; SW_SHOWMAXIMIZED
    }
    if (prevHwnd && WinExist("ahk_id " . prevHwnd))
        try WinActivate("ahk_id " . prevHwnd)
}


; Execute only when launched with:
;   JWMediaFix.exe --Launch JW

if (A_Args.Length >= 2
    && A_Args[1] = "--Launch"
    && A_Args[2] = "JW") {

    WaitForInteractiveDesktop()
}


; ── Wait for the interactive desktop before launching JW Library ──


WaitForInteractiveDesktop() {
    Loop {
        ; Wait until Explorer has started.
        if !ProcessExist("explorer.exe") {
            Sleep 200
            continue
        }

        ; Wait until the taskbar has been created.
        if !WinExist("ahk_class Shell_TrayWnd") {
            Sleep 200
            continue
        }

        ; Wait until Explorer owns the foreground window, indicating
        ; that the user is on the interactive desktop rather than a
        ; logon, lock, or intermediate shell screen.
        try {
            hwnd := WinExist("A")
            pid := WinGetPID(hwnd)

            if (ProcessGetName(pid) != "explorer.exe") {
                Sleep 200
                continue
            }
        }
        catch {
            Sleep 200
            continue
        }

        ; The desktop is now interactive.

        ; Launch JW Library only if it is not already running.
        ; This prevents opening multiple instances if the application was
        ; started manually or by another part of the script.
        if !WinExist("JW Library") {
            Run "shell:AppsFolder\WatchtowerBibleandTractSo.45909CDBADF3C_5rz59y55nfz3e!App"
        }

        return
    }
}


; ── WATCH LOOP ────────────────────────────────────────────────
; Runs forever. Every tick:
;   1. Check for display config changes (throttled to ~3s).
;   2. Stamp the media-window-last-seen timestamp if MediaHwnd
;      currently points to a real window.
;   3. On a JW Library fresh launch, give the main JW window  
;      focus while waiting for the media window to appear.
;   4. Check for the Exclusive Fullscreen state on the target monitor
;      and every other non-primary monitor.
;   5. If MediaHwnd is known and valid, check it is:
;      a. On the correct target monitor (move it if not).
;      b. Maximized (fix it if not).
;   6. If MediaHwnd is unknown, run content-based discovery.

Loop {
    ; Lightweight periodic check (throttled to MONITOR_CHECK_INTERVAL_MS)
    ; for display changes: resolution, monitor count, primary display
    ; switch, or the main JW window moving onto the media monitor.
    CheckForMonitorChanges()

    ; Stamp the timestamp whenever the media window is confirmed alive.
    ; DiscoverWindowIdentities() checks this to avoid a spurious focus-grab
    ; on the main window when the media window is simply in a brief
    ; enumeration gap rather than genuinely absent.
    if (MediaHwnd && WinExist("ahk_id " . MediaHwnd))
        LastMediaWindowSeenTick := A_TickCount

    ; ── One-time main-window focus on fresh JW launch ────────────
    ; This runs at script startup and again every time JW Library
    ; is fully closed and relaunched (either case leaves
    ; HasSeenMediaWindowThisSession, MainHwnd, and MediaHwnd all
    ; unset). If JW Library's media window is already fixed and in
    ; place by the check time, mark the session as seen right
    ; away so the focus-grab below never fires. Check this by
    ; looking for any JW Library window sitting on or near the
    ; secondary/target monitor - not by content (IsMediaWindowByContent),
    ; since the media window's visible text is only "CoreInput"
    ; while Exclusive, and may say something else once maximized.
    if (!HasSeenMediaWindowThisSession && !MainHwnd && !MediaHwnd) {
        ids := WinGetList("JW Library")
        for id in ids {
            if !IsJWWindow(id)
                continue
            try {
                WinGetPos &wx, &wy, , , "ahk_id " . id
                ; If any JW window is on or near the target monitor,
                ; the media window is already fixed and in place.
                if (wx >= SecMonLeft - 100 && wx < SecMonRight) {
                    HasSeenMediaWindowThisSession := true
                    MediaHwnd := id
                    break
                }
            }
        }
    }

    ; Populate MainHwnd before the focus-grab check. Only runs when
    ; the media window hasn't been seen yet (genuine fresh launch).
    if (!MainHwnd && !HasSeenMediaWindowThisSession) {
        ids := WinGetList("JW Library")
        for id in ids {
            if IsJWWindow(id) && IsMainWindowByContent(id) {
                MainHwnd := id
                break
            }
        }
    }

    ; Give the main window focus once while waiting for the media
    ; window to appear after a genuine fresh launch. All guards
    ; must pass: session not yet complete, main window exists,
    ; media window not yet known, not recently seen.
    if (
        !HasSeenMediaWindowThisSession
        && MainHwnd
        && WinExist("ahk_id " . MainHwnd)
        && !MediaHwnd
        && (A_TickCount - LastMediaWindowSeenTick) >= MEDIA_RECENT_DETECTION_MS
    ) {
        try WinActivate("ahk_id " . MainHwnd)
    }

    ; ── Check for the Exclusive Fullscreen state ────────────────────
    ; Probes the user's selected target monitor first, then every
    ; other non-primary monitor, since JW Library may open its media
    ; window on a different monitor than the user's chosen target.
    ExclusiveFS := DetectExclusiveFSHwnd()

    if ExclusiveFS {
        ; Found a Exclusive Fullscreen window. Reset identities and apply the fix.
        ; Note: HasSeenMediaWindowThisSession is NOT set here - it's
        ; only set once the media window is confirmed working (inside
        ; DiscoverWindowIdentities when MediaHwnd is successfully
        ; found, or inside ApplyFullscreenFix when the fix succeeds).
        ; Setting it here would permanently suppress the one-time
        ; main-window focus-grab even on a genuine fresh launch.
        MainHwnd := 0
        MediaHwnd := 0

        ApplyFullscreenFix(
            ExclusiveFS.hwnd,
            ExclusiveFS.clickX,
            ExclusiveFS.clickY
        )
        
        Sleep CHECK_INTERVAL_MS
        continue
    }

    ; ── Ensure MediaHwnd is known ────────────────────────────────
    if !(MediaHwnd && WinExist("ahk_id " . MediaHwnd)) {
        ; Unknown or closed - reset and try content-based discovery.
        MainHwnd  := 0
        MediaHwnd := 0
        DiscoverWindowIdentities()
        Sleep CHECK_INTERVAL_MS
        continue
    }

    ; ── MediaHwnd is valid - check its state ────────────────────
    minMax := WinGetMinMax("ahk_id " . MediaHwnd)

    if (minMax != 1) {
        ; Minimized or windowed but not maximized -> maximize it
        ; without stealing focus from the user.
        ApplyNormalMaximize(MediaHwnd)
    }
    else {
        ; Maximized -> verify it's on the correct target monitor.
        ; Moves it if the user changed the target or JW Library
        ; opened it on a different monitor than the target.
        ApplyMoveToTargetMonitor(MediaHwnd)
    }

    Sleep CHECK_INTERVAL_MS
}