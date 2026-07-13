<div align="center">

# Leitostrap AHK

**Lightweight Roblox FFlag injector built entirely in AutoHotkey v2.**

Zero Python. Zero dependencies. Just AHK.

[Latest Release](https://github.com/Leitostrap/Leitostrap/releases/latest) · [Discord](https://discord.gg/Fgec4NtHnu) · [Offsets](https://offsets.imtheo.lol/fflags.hpp)

</div>

---

## What is this

Leitostrap AHK is a standalone FFlag injector written in pure AutoHotkey v2. No Python runtime, no PyInstaller, no extra frameworks. It injects Roblox FastFlags directly into process memory using Windows Native API calls.

---

## Features

### Injection Engine

- **NtWriteVirtualMemory** — Direct memory writes via ntdll.dll. No VirtualProtectEx, no NtFlushInstructionCache
- **NtSuspendProcess / NtResumeProcess** — Process is frozen during injection to prevent race conditions and crashes
- **NtFlushInstructionCache** — Flushes instruction cache after writing 4+ byte values
- **FFlagLimiter** — 60+ flag-specific safety limits that auto-clamp dangerous int/float values to prevent Roblox crashes
- **Persistent Reapply** — Optional timer (500-3000ms) that re-applies flags if Roblox reverts them. Off by default, configurable in Settings
- **Prefix Stripping** — Automatically strips common FFlag prefixes (DFString, FInt, DFFlag, etc.) for clean key matching

### FFlag Editor

- Write or paste JSON directly into the editor
- **Import** — Load JSON files from disk
- **Export** — Save editor contents to JSON
- **Clear** — Reset the editor
- Automatic prefix detection and type inference (bool, int, float, string)

### Offset Database

- Live download from `imtheo.lol/Offsets/FFlags.hpp`
- Click any flag in the database to add it to the editor
- Search/filter by flag name
- **Add All Filtered** — Bulk add all matching flags
- Auto-classifies flags as INT, BOOL, or STR based on name patterns

### Injection Monitor

- Real-time stats: Applied, Failed, Reapplied, Active Flags
- Injection details panel showing method, persistence status, and last inject time
- Scrollable log with timestamps and color-coded entries

### Settings

- **Reapply Toggle** — Enable/disable flag re-application with custom interval (500-3000ms)
- **Value Limiter Toggle** — Enable/disable automatic value clamping
- Version info, engine type, offset count, and status display

---

## UI

- **Black & white theme** — Pure #111/#0d0d0d background, white text, no colored accents
- **Custom scrollbars** — Styled track, thumb, and hover states
- **SVG icons** — Clean line icons for every button and sidebar element
- **Sidebar navigation** — 4 sections: Editor, Database, Injection, Settings
- **Compact layout** — Tight spacing optimized for a 900x650 window
- **Toast notifications** — Non-intrusive feedback messages
- **Draggable titlebar** — Click and drag anywhere on the top bar
- **Live status bar** — Green/red dot with connection status and flag count

---

## How it works

1. Script starts and begins monitoring for `RobloxPlayerBeta.exe`
2. When Roblox is detected, the process handle is opened and the module base address is found
3. FFlag offsets are downloaded from the online database
4. You write your FFlag JSON in the editor (or import a file)
5. Click **Apply** — the script:
   - Parses the JSON and validates each flag through FFlagLimiter
   - Suspends the Roblox process
   - Writes each flag value to `base + offset` using NtWriteVirtualMemory
   - Flushes instruction cache for each write
   - Resumes the process
6. If Reapply is enabled, a timer re-checks and re-applies flags at the configured interval

---

## Requirements

- Windows 10/11
- AutoHotkey v2.0 (to run from source)
- Roblox installed

---

## Usage

1. Download `Leitostrap.ahk` from releases
2. Double-click to run (requires AutoHotkey v2.0)
3. Wait for Roblox to be detected (green dot in status bar)
4. Enter your FFlag JSON in the editor
5. Click **Apply**

---

<div align="center">

Made by Leitostrap

</div>
