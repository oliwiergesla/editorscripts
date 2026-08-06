# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, Codex, Cursor, and others) working with code in this repository. `CLAUDE.md` is a symlink to this file.

## Overview

This is a collection of Lua scripts for DaVinci Resolve 20 that automate timeline operations, media management, and rendering workflows. Scripts are accessed within Resolve via `Workspace → Scripts`.

## Documentation Resources

### Official API Documentation (shipped with Resolve — authoritative, always current)
Every Resolve install ships the current API docs locally; prefer these over any website for API questions:
- **macOS:** `/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/README.txt` (full API reference) and `CHANGELOG.txt` (API changes per Resolve version — useful for `MIN_RESOLVE` pins)
- **Windows:** `%PROGRAMDATA%\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting\` (same files)
- Gitignored snapshots may exist at `.claude-docs/official-resolveapi-readme.txt` / `-changelog.txt` — convenient to read, but refresh them by re-copying after Resolve updates before trusting them over the shipped files.
- Official example scripts live in `Examples/` next to the README — occasionally useful for API usage the docs describe tersely (their code style predates this repo's conventions; don't pattern-match from them).

### External API Documentation
- **Resolve Developer Documentation** (a few versions behind — prefer the shipped README above for API questions): https://resolvedevdoc.readthedocs.io/en/latest/index.html
- **UI Elements pages** — the ONLY documentation of the Fusion UIManager (not covered by the official README):
  - **Functions:** https://resolvedevdoc.readthedocs.io/en/latest/UI_elements_func.html
  - **Attributes:** https://resolvedevdoc.readthedocs.io/en/latest/UI_elements_attrb.html
  - **Events:** https://resolvedevdoc.readthedocs.io/en/latest/UI_elements_events.html

### Project Structure
```
editorscripts/
├── .claude/                     # Claude configuration
├── assets/                      # README and docs images
├── build.sh                     # Build pipeline (bundle + minify + installer)
├── docs/                        # Per-script user documentation pages
├── src/
│   ├── installer/              # Standalone installer template (no ResolveKit dependency)
│   │   └── tools/             # Utility tools embedded into every installer (dependency-free)
│   ├── lib/
│   │   ├── ResolveKit.lua     # Main utility library (facade)
│   │   └── modules/           # core, timeline, ui, filesystem, media, platform
│   └── scripts/                # Production scripts (snake_case, flat)
├── tools/                       # Build helpers and dev utilities
└── dist/                        # Built scripts (per-script folders with installer)
```

## Naming Conventions

### Files
- **Scripts** (`src/scripts/`): `snake_case.lua` (e.g., `markers_to_stills.lua`)
- **Main libraries** (`src/lib/`): PascalCase (e.g., `ResolveKit.lua`)
- **Modules** (`src/lib/modules/`): lowercase (e.g., `timeline.lua`, `ui.lua`)
- **Special characters**: Use `Plus`/`Minus` instead of `+`/`-` in filenames

### Code Style
- **Functions & variables**: camelCase (`getSelectedTimelines`, `timelineName`)
- **Constants/config**: UPPER_SNAKE_CASE (`CONFIG`, `DELETE_VIDEO_CLIPS`)
- **Module tables**: PascalCase (`local Core = {}`, `local Timeline = {}`)

## Core Architecture

**ResolveKit.lua** is the foundational library that all scripts import. Read its facade and modules for full API details.

### Standard Script Structure

Every script follows this pattern:
```lua
-- 1. SCRIPT_INFO (always the very first line, no comment needed)
local SCRIPT_INFO = {
    NAME = "My Script",
    VERSION = "0.1.0",
    MIN_RESOLVE = "20.0",
}

-- 2. Header comment block with description and usage
--[[ ... --]]

-- 3. Import ResolveKit
local utils = require("ResolveKit")

-- 4. CONFIG table with constants (if needed)
local CONFIG = { ... }

-- 5. Helper functions (script-specific logic)
local function processTimeline() ... end

-- 6. Main execution block
utils.printHeader(SCRIPT_INFO.NAME .. " v" .. SCRIPT_INFO.VERSION)
local ctx, err = utils.initializeWithUI(SCRIPT_INFO)  -- or utils.initialize(false, SCRIPT_INFO) for console-only
if not ctx then
    utils.printError(err)
    return
end
-- Extract ctx.resolve, ctx.project, ctx.mediaPool, ctx.ui, ctx.dispatcher
```

**SCRIPT_INFO** must be the first line of every script with `NAME`, `VERSION`, and `MIN_RESOLVE` only. New scripts always start at `VERSION = "0.1.0"`. `MIN_RESOLVE` is the minimum Resolve version the script's API calls require ("major.minor" string), enforced at launch: pass the whole `SCRIPT_INFO` table as the last argument to `initialize()`/`initializeWithUI()` (a bare pin string also works; omitting it falls back to `Core.DEFAULT_MIN_RESOLVE`). New scripts start at the current support floor (`"20.0"`) and raise the pin when adopting an API introduced in a newer Resolve. Raising the pin is a **hard block** — every user below it loses the script entirely. For an *optional* improvement (a faster path, a nicer affordance) prefer runtime feature detection and keep the pin where it is; see `Timeline.getTimelineLookup` in `timeline.lua` for the pattern, and `stepLoopSupported` in `ui.lua` for the memoized-probe precedent. Reserve a pin raise for APIs the script genuinely cannot work without. On any init failure, `initializeWithUI` also shows an on-screen error dialog titled with `SCRIPT_INFO.NAME` (console-only `initialize()` deliberately stays silent for headless/StreamDeck flows) — scripts still `printError(err)` and return as usual.

**Window titles** must always use `SCRIPT_INFO.NAME`. **Console headers** (`printHeader`) must always use `SCRIPT_INFO.NAME .. " v" .. SCRIPT_INFO.VERSION`.

### Error Handling Convention

Functions return `value, nil` on success and `nil, "error message"` on failure. Always nil-check with early return.

### Script Data Files

All runtime files a script generates (settings, state, undo data, logs, launchers) go in hidden folders **next to the script itself** — never in `$HOME`:
- `.data/` for state/settings/logs — get the path via `utils.getDataDir()` (create with `utils.createDirectory` before writing)
- `.bin/` for generated shell launchers (StreamDeck scripts)

Rationale: uninstalling = deleting one folder. Installs are per-user on both platforms (Resolve maps `Scripts:/` to `~/Library` on macOS and `%APPDATA%` on Windows), so StreamDeck commands that embed install paths must be re-copied per machine/account. The dot prefix keeps the folders out of Resolve's Scripts menu (which builds submenus from subfolders) and Finder. Name files with a script-specific prefix (e.g. `renamer_undo.json`, `node_toggle.log`) since all installed scripts share one `.data` folder. User-directed output files (exports, stills) go wherever the user chooses — this convention is only for internal bookkeeping.

## DaVinci Resolve API Patterns

### Object Hierarchy
```lua
Resolve()
  → resolve
    → GetProjectManager() → projectManager
      → GetCurrentProject() → project
        → GetMediaPool() → mediaPool
        → GetCurrentTimeline() → timeline
        → GetTimelineCount(), GetTimelineByIndex(i)
    → Fusion() → fusion  -- Required for UI dialogs only

mediaPoolItem → GetTimeline() → timeline   -- Resolve 21.0.4+; nil if not a timeline
timeline      → GetMediaPoolItem() → mediaPoolItem   -- the reverse direction
```

### Media Pool Selection

Most batch scripts use `utils.getSelectedTimelines(project, mediaPool)` which returns a list of `{timeline, name, clipItem}` tables. See `timeline.lua` for the full API.

**Never resolve a Media Pool item to its Timeline by enumerating `GetTimelineByIndex`.** Use `utils.getSelectedTimelines`, or `utils.getTimelineLookup(project, forceLegacy, sampleItem)` when you need the mapping outside the selection flow. On Resolve 21.0.4+ it returns a direct `MediaPoolItem:GetTimeline()` call with no project scan; below that it falls back to an incremental UniqueId scan. Enumerating by hand costs ~0.29 ms per timeline in the project on *every* lookup (measured August 2026, macOS) and pointlessly re-pays that on installs that no longer need it. A lookup is valid for **one operation only** — never hold one across UI events or for a dialog's lifetime, or the legacy path will hand back timelines that have since been renamed or deleted.

### UI Rules (Fusion UIManager)

See `ui.lua` for complete dialog builder functions. Critical non-obvious rules:
- **Never use `Geometry` property** in `disp:AddWindow()` — omitting it enables auto-centering. Set the size after creation instead (footer dialogs: `utils.fitDialogHeight`; others: `win:Resize({w, h})`).
- **Window height must be defined before `win:Show()`** or auto-centering fails. Footer dialogs get it from `utils.fitDialogHeight(win, width)` (see Footer Rules); non-footer dialogs use an explicit `Resize`.
- **Always call `utils.centerDialogOnScreen(dialog, ui, dispatcher)` after the final size (fitDialogHeight/Resize) and immediately before `Show()`.** Implicit auto-centering computes a broken x when Resolve is on a *secondary* display for normal (framed) windows — measured July 2026 on macOS, Resolve 21; only frameless windows (e.g. the installer) auto-center correctly there. The helper uses a tiny frameless probe window as the screen-center oracle (`Show()` positions synchronously — `Pos()` is final before any `RunLoop` — but never paints without event-loop iterations, so the probe is invisible), then explicitly `Move`s the dialog to that center. An explicit pre-Show `Move` sticks; auto-centering does not override it. On any failure it silently falls back to auto-centering. **Never re-center a visible window** (resizing in place is fine, moving one under the user is not) — so `toggleDialogSections`/`fitDialogHeight` re-runs do NOT re-center.
- `win:Move({x,y})` and `win:Pos()` share one global Qt coordinate space (primary display top-left origin, y-down); pair with the frame-inclusive `win:Size()`.
- `FixedX`/`FixedY`/size-policy attributes are silently ignored (verified macOS + Windows, Resolve 21) — there is no policy-based auto-fit; measure and `Resize` instead
- `RecalcLayout()` can only GROW a shown window, never shrink it — to shrink after hiding a section, re-run `utils.fitDialogHeight`
- `win:Size()` includes the window frame (~+20px); element `Size()`/`Pos()` are client coordinates and are the reliable read-backs
- **Never put an `HGap` in a VGroup or a `VGap` in an HGroup** (e.g. as the `or` placeholder of a conditional element). A zero-size gap has maximum size 0 on its axis, and Qt caps a box layout's cross-axis maximum at the smallest child maximum — one axis-mismatched gap squeezes the entire group to its minimum width/height (bit markers_to_stills on Windows, where the `or` branch is taken)
- Use `Weight = 0` for fixed-height elements
- Always call `win:RecalcLayout()` before `win:Show()` to ensure correct rendering on first display
- Always call `win:Hide()` after `dispatcher:RunLoop()` for cleanup
- Must call `disp:ExitLoop()` to close dialog and resume script execution
- `ComboBox.CurrentIndex` is 0-based (set initial selection with `combo.CurrentIndex = 0`)
- **Token buttons** insert via the native `lineEdit:Insert("{" .. token .. "}")` — it lands at the cursor and replaces any selection. Never append to `.Text` by concatenation; that jumps the token to the end and resets the cursor.
- Common elements: `ComboBox`, `Tree` (multi-select with checkboxes), `TextEdit` (scrollable), `Label`, `Button`
- **Persistent dialogs run processing inside button handlers** (dialog stays open; progress window opens on top) — never ExitLoop-then-process-then-rebuild the dialog. Any handler that calls the Resolve API or opens a progress window/sub-dialog must run via `utils.runWithDialogBusy(dialog, fn, ...)`: it greys out the `DialogContent` group and drops clicks while the event loop is blocked (queued clicks on enabled-looking buttons would otherwise fire after processing), and always re-enables even if `fn` errors. Instant UI-only handlers (token inserts, section toggles, clipboard copy) stay unwrapped.

### Progress Window Rules

Use `utils.createProgressWindow()` for batch operations. See `ui.lua` for the full API. Key behavioral notes:
- Progress windows show **accumulated status**, not real-time visual updates (single-threaded Lua)
- Always include console output alongside progress window updates
- Use `progress.update()` before AND after each operation for clear status
- Set `isComplete = true` on final update; keep window visible ~2 seconds after completion
- **Cancellable batches**: pass `cancellable = true` and poll `progress.isCancelled()` at the top of the loop — `break`, then fall through to the script's normal finalization (partial results, temp cleanup, summary must still run). The Cancel click is delivered by an event pump inside `progress.update()` (`dispatcher:StepLoop(false)` — undocumented; feature-detected, silently degrades to no button). Pumping delivers ANY queued event, so dialog Close handlers must stay teardown-only (save prefs / ExitLoop), and Cancel/Close handlers must never call ExitLoop for the progress window or call `update()` reentrantly. Only opt in where stopping between items leaves consistent state; one-shot scripts (no RunLoop active) may also opt in — Mode B (pumping with no RunLoop active) was verified live on macOS, July 2026; Windows pending.

### Footer Rules

Use `utils.createFooter(ui, {scriptName, version})` and `utils.attachFooterHandler(dialog)`. Key constraints:
- Footer must be **outside** the padded content area (last element in the root VGroup, not inside HGroup padding) to span full width
- Footer must be preceded by `ui:VGap(0, 1)` as the second child of the dialog's root VGroup — the stretch absorbs any surplus window height so the footer stays pinned to the bottom
- Bottom-edge padding lives inside `createFooter` (`bottomGap`, structurally larger than the divider-to-text `textGap` so the two read as visually identical — label font boxes have more dead space above glyphs than below) — never add per-script gaps below the footer
- **Footer dialogs auto-size**: pin the root VGroup (ID must be `DialogContent`) to width only (`MinimumSize = {w, 0}`, `MaximumSize = {w, 16777215}` — never a fixed height) and call `utils.fitDialogHeight(dialog, CONFIG.DIALOG_WIDTH)` after `applyDialogPlatformAttributes` and BEFORE `Show()`; on `nil` fall back to `Resize` with `CONFIG.DIALOG_FALLBACK_HEIGHT`. Re-run it after any section's `Hidden` flip (it both grows and shrinks). Do not hand-tune window heights or write `calculateWindowHeight`-style pixel math.
- After fitting, `fitDialogHeight` locks `DialogContent` to `Min == Max` — this is what enforces the exact client width (width-only pinning alone lets windows open ~20px narrow) and makes dialogs non-user-resizable (required behavior). The lock is lifted and re-applied on every call.
- **Collapsible sections**: call `utils.prewarmDialogSections(win, {sections...})` BEFORE `Show()` — a never-laid-out widget paints its first visible frame at unpositioned coordinates. Toggle visibility via `utils.toggleDialogSections(win, width, {{element = ..., hidden = ...}})` instead of flipping `Hidden` + `fitDialogHeight` yourself: it predicts the target height and applies the flips + resize in one repaint (flip-then-measure paints one wrong-sized intermediate frame).

## Performance

### Batch API Calls
Always collect items then process in a single API call. Never call `timeline:DeleteClips({clip})` inside a loop — collect all clips first, then call `timeline:DeleteClips(allClips)` once.

### Mutating-Call UI Tick
Single mutating calls (`AddMarker`, `DeleteMarkerAtFrame`, per-item `DeleteClips`, changed-value `SetSetting`, `SetName`) block until Resolve's next UI refresh: ~16.6 ms median on a 60 Hz display, while the same calls' minimums are sub-ms — the wait is the tick, not the work. Per-item loops therefore cap at ~60 ops/sec; batch APIs pay the tick once (batch `DeleteClips` ~0.1 ms/item; `DeleteMarkersByColor("All")` clears any count in ~1 ms). This is the *why* behind the Batch API Calls rule. Measured July 2026 (macOS, Resolve 21, local project).

### Caching for Lookups
Build hash tables for O(1) access instead of repeated iteration — see `renamer.lua`'s `clipsByUniqueId` undo map. Scope the cache to one operation unless the keys are provably stable; caches held across UI events go stale when the user edits the project underneath them.

### Full-Dict Property Reads
`clip:GetClipProperty()` with no argument returns the full property dict (~260 keys) in one call; `GetMetadata()` and `GetSetting()` have the same no-arg form. Measured July 2026 (macOS, local project): a single-key read is ~0.08–0.15 ms, the full dict ~0.45 ms — **break-even at ~3 keys**. Reading **3+ properties from the same clip: take one no-arg snapshot and index it** (keys match the per-key names); at 1–2 properties keep per-key reads — they're faster. Exception: `GetMetadata()`'s no-arg dict costs the same as one single-key read (~0.1 ms) — snapshot at 2+ metadata keys, always. Keep the same `or ""` / nil fallbacks on dict lookups that a per-key read would need, and guard the snapshot itself (`GetClipProperty() or {}`).

### Batch AppendToTimeline
Batch `mediaPool:AppendToTimeline()` calls in groups of 100-200 clips (200 on macOS/Linux, 100 on Windows). Measured July 2026 (macOS): chunk size 25–400 makes little difference — per-clip cost is dominated by how full the timeline already is (~0.9 ms near-empty, ~4.3 ms at ~1150 items), so very large builds slow down as they grow regardless of chunking.

### `setCurrentTimeline()` Classification

**NEVER use `setCurrentTimeline()` unless absolutely necessary.** A switch costs ~130 ms (empty timeline) to ~190 ms (~1150 items) — as much as ~8 mutating calls or ~1300 batch-deleted clips (measured July 2026, macOS).

**DON'T require** `setCurrentTimeline`:
- `SetSetting()` / `GetSetting()`, `ClearMarkInOut()` / `SetMarkInOut()`
- `GetItemListInTrack()`, `GetTrackCount()`, `GetMarkers()`, `AddMarker()` / `DeleteMarkerAtFrame()` / `DeleteMarkersByColor()`
- `DuplicateTimeline()` — works on a non-current source, but see Timeline Lifecycle: the duplicate BECOMES the current timeline
- `AddTrack()` — works on non-current timelines and is ~30x faster there (0.3 ms vs 11.5 ms while current)
- Most read-only operations

**DO require**:
- `DeleteClips()` — silently no-ops and returns false on a non-current timeline. Optimize by checking for clips first, only switch UI if clips exist.
- `DeleteTrack()` — silently returns false on a non-current timeline
- Rendering operations, loading presets/templates, some color grading, viewer interactions

### General
- Never iterate all project timelines inside another loop
- Cache `string.rep()` results if generating same separators repeatedly
- Use `utils.sleep(n)` for cross-platform delays (not `os.execute('sleep n')`)
- `SetSetting()` has a built-in no-change fast path (same-value write ~0.17 ms vs ~19 ms for a real change) — never build manual diff-before-write for settings

## Timeline Naming Conventions

Scripts use pattern-based naming: resolution suffix (`_1080x1920`), version suffix (`_V1`), type markers (`_WEB_`, `_SOCIAL_`). Example: `MyVideo_WEB_1080x1920_V2`. See `timeline.lua` for name manipulation utilities.

## Common Pitfalls

### Timeline Clips
- Always check `GetClipEnabled()` — disabled clips should often be filtered
- `GetEnd()` returns the frame **AFTER** the last frame — subtract 1 for actual last visible frame

### Markers
- `AddMarker` rejects by **returning false**, never by erroring — a bare `pcall` wrapper reports success anyway; always check the return value
- Rejected: empty name, duration < 1, negative frames, occupied frames. Silently ACCEPTED: frames beyond the timeline end — clamp frames yourself or markers land invisibly past the end
- There is no batch add (~17 ms per marker, flat to 1000+); `DeleteMarkersByColor("All")` is the only bulk marker operation (~1 ms for any count)

### File Paths
- Always sanitize: `utils.sanitizeFilename(name)` replaces illegal characters
- Check uniqueness: `utils.getUniqueFilePath(dir, filename)` appends `_1`, `_2`, etc.
- Remove trailing slashes from directory paths before use

### Resolution Detection
- **DO NOT** parse resolution from timeline name — names can be outdated
- **DO** read from `timeline:GetSetting("timelineResolutionWidth")` / `"timelineResolutionHeight"`

### Media Pool Bins
- **DO NOT** resolve a bin by recursing the tree and taking the first name match — a same-named bin nested in an unrelated branch wins silently
- **DO** scope name lookups to direct children of a known parent (`GetSubFolderList()` scan, e.g. `utils.getBin`) and compare folders by `GetUniqueId()` — Resolve allows duplicate bin names, `AddSubFolder` does not enforce uniqueness, and there is no `GetParentFolder` to recover parentage after the fact

### UI Dialogs
- Fusion instance REQUIRED for UIManager — use `utils.initializeWithUI()`
- Modal dialogs block execution — design multi-step flows carefully

### `dofile()` Global Isolation
- Resolve's `dofile()` isolates global variables — globals set before `dofile()` are **not visible** inside the loaded file
- `rawget(_G, ...)` also fails
- **Use `package.<flag>`** instead to pass flags between scripts (e.g., `package._MY_MODULE_FLAG = true`)

## Testing New Scripts

1. Test with timelines of different resolutions (1080x1920, 3840x2160, 4096x2160)
2. Test with empty Media Pool selections (should show helpful error)
3. Test with offline media (if script touches media files)
4. Test file operations on different devices (cross-device move scenario)
5. Test with special characters in timeline/file names
6. Test with long file paths

## Adding New Scripts

1. Place in appropriate directory:
   - `src/scripts/` for production scripts (builds to dist/)
   - `sandbox/` for testing and experimenting
   - `personal/` for private scripts
   - `personal/archive/` for archived/deprecated scripts
   - `tools/` for build helpers and dev utilities
2. Follow standard script structure above (SCRIPT_INFO first line, `VERSION = "0.1.0"`)
3. Import ResolveKit: `local utils = require("ResolveKit")`

### Script Lifecycle
- **New script:** Start in `sandbox/`, move to `src/scripts/` when ready
- **Release:** Build from `src/scripts/` to `dist/` using `./build.sh`
- **Archived:** Move deprecated scripts to `personal/archive/`

### Version Bumps
Never bump `SCRIPT_INFO.VERSION` automatically. Versions are bumped manually when publishing for release.

## Build Pipeline

```bash
./build.sh                          # Build all scripts + the suite installer
./build.sh markers_to_stills      # Build only this script (by source filename, no .lua)
```

Pipeline: `luabundler` (bundle) → break the entry tail call → `luasrcdiet --basic` (minify) → prepend copyright → generate installer → `dist/`.

**The bundle's entry invocation must never be a tail call.** LuaJIT tail calls replace the caller's stack frame, so luabundler's closing `return __bundle_require("__root")` erases the main chunk from the call stack — which blinds ResolveKit's `getScriptPath()` stack walk in every bundled build while dev copies keep working. build.sh rewrites the footer to a local-then-return; keep that step intact when touching the pipeline.

Scripts are auto-discovered from `src/scripts/` and `personal/` (non-recursive); NAME and VERSION are extracted from the `SCRIPT_INFO` block in each file's first 10 lines. No registration needed.

Source files use `snake_case`. Dist artifacts are lowercase kebab-case (`kebab_name()` in build.sh: lowercased, spaces become hyphens, dots dropped, `+` becomes `plus`): the folder is the tool name only with NO version (`markers-to-stills/`); files are name-version-type — `markers-to-stills-v1.0.2.lua` and `markers-to-stills-v1.0.2-installer.lua` — each script keeping its own `SCRIPT_INFO.VERSION` (never unify versions across scripts). Display names with spaces are only written at install time (the embedded install `filename` keeps them — never kebab those), where they read cleanly in the Workspace menu. Resolve menu path: `Workspace > Scripts > EditorScripts > <Display Name>`.

**All-in-one installer:** A full `./build.sh` run also generates `dist/editorscripts/editorscripts-v<SUITE_VERSION>-installer.lua` (`SUITE_NAME`/`SUITE_VERSION` in build.sh) — one installer embedding every production script from `src/scripts/` (not `personal/`). This is the ONLY publicly distributed artifact (suite-only distribution; per-script installers are built for dev but not published). It opens with the classic Install/Cancel window plus a Custom Installation button that reveals per-script checkboxes with live status (Not installed / Update available / Up to date). Suite installs never downgrade: scripts whose installed `VERSION` literal is already >= the embedded one are skipped (single-script installers keep always-overwriting). `SUITE_VERSION` in build.sh is bumped manually when publishing. Filtered builds (`./build.sh <script>`) do NOT regenerate the suite — run a full build before publishing. Removing a script from `src/scripts/` drops it from future suites but never uninstalls installed copies. The template and both installer flavors share one file: `SCRIPTS` has one entry for single-script installers, many for the suite (`IS_SUITE` dispatch).

**Installer constraint:** Do NOT use ResolveKit in the installer template — it runs before the script is installed. The installer runs in the Fusion Console environment (`app`, `fusion`, `bmd` globals). See `src/installer/installer_template.lua` for details. The `{{SCRIPTS_TABLE}}` placeholder is filled by build.sh's `generate_scripts_fragment()` and embedded via `tools/embed_content.lua` with the `raw:` prefix (the fragment legitimately contains the `]=====]` long-string delimiter; script/tool payloads keep the delimiter safety check).

**Utility tools:** Scripts in `src/installer/tools/` are embedded into every installer and installed to `EditorScripts/Tools/` (shown as a `Tools` submenu in Resolve). They must be dependency-free (no ResolveKit, no `require` — they're minified but not bundled) and use display-name filenames on install. The installer version-compares against the installed file's `VERSION = "..."` literal and only writes when missing or newer (never downgrades). Register new tools in build.sh's `TOOL_SOURCES` and add a matching `{{TOOLn_*}}` entry to the template's `TOOLS` table.

## Extending ResolveKit

When adding new utility functions:
1. Add to the appropriate module in `lib/modules/` (read module headers for scope)
2. Export via the `ResolveKit.lua` facade
3. Follow conventions: `value, error` return pairs, section comments, inline docs

## Undocumented / Lesser-Known API Notes

### Marker/Flag vs Clip Color Palettes (different sets!)
Markers/flags and clip colors use two **different** 16-color palettes — never share one color list between them:
- **Marker & flag colors** (`AddMarker`, `GetMarkers`, `AddFlag`, `GetFlagList`), in Resolve's menu order: Blue, Cyan, Green, Yellow, Red, Pink, Purple, Fuchsia, Rose, Lavender, Sky, Mint, Lemon, Sand, Cocoa, Cream
- **Clip colors** (`SetClipColor`/`GetClipColor` on media pool and timeline items), in Resolve's menu order: Orange, Apricot, Yellow, Lime, Olive, Green, Teal, Navy, Blue, Purple, Violet, Pink, Tan, Beige, Brown, Chocolate
- Only Yellow, Green, Blue, Purple, Pink exist in both. Notably there is **no Orange marker/flag** and **no Red or Cyan clip color** — passing a name from the wrong palette silently fails or never matches when filtering.

### Framerate Setting Gotcha
`timeline:SetSetting("timelineFrameRate", value)` requires integer strings:
- 23.976 → `"23"`, 29.97 → `"29"`, 59.94 → `"59"`, 119.88 → `"119"`
- NTSC/drop-frame: 30→29, 60→59, 24→23

### Timeline Lifecycle (Create / Duplicate / Delete)
- `mediaPool:CreateEmptyTimeline(name)` (~80 ms) creates the timeline in the CURRENT media pool folder and switches the current timeline to it — save/restore both around scripted creation
- `DuplicateTimeline` works on a non-current source, **but the duplicate becomes the current timeline** — every call in a duplication loop embeds an implicit ~130–190 ms switch and leaves the user parked on the last duplicate; restore the saved current timeline after duplication batches
- `mediaPool:DeleteTimelines([timelines])` deletes in one batched call

### AppendToTimeline Extended Options
`mediaPool:AppendToTimeline()` supports precise placement:
```lua
{
    mediaPoolItem = item,
    startFrame = 0,
    endFrame = 100,
    trackIndex = 2,        -- target track number
    recordFrame = 500,     -- exact timeline position
    mediaType = 1          -- 1=Video, 2=Audio
}
```

### Cloud/Server Project Detection
`projectManager:GetCurrentDatabase()` returns a table with database info. If `IpAddress` field exists, it's a cloud/server project. Cloud projects need longer delays between API calls (~+2s).

### GetAudioMapping
`clip:GetAudioMapping()` returns a JSON string (not a table) with `track_mapping`. Parse with a JSON decoder to count audio tracks per media pool item.

### SRT Subtitle Import Workflow
1. Generate SRT file
2. `mediaPool:ImportMedia({srtPath})` to import
3. `timeline:AddTrack("subtitle")` to add subtitle track
4. Disable other subtitle tracks, enable new one
5. `mediaPool:AppendToTimeline({{mediaPoolItem=srtItem, startFrame=..., recordFrame=...}})` to place
6. `mediaPool:DeleteClips({srtItem})` to cleanup media pool

### Render Preset XML Round-Trip
`resolve:ImportRenderPreset(xmlFilePath)` imports a preset from XML (can write XML to a temp file and import programmatically); `resolve:ExportRenderPreset(presetName, folder)` exports one, writing `<PresetName>.xml` into the given FOLDER. There is no `GetRenderSettings()` — exporting and parsing the XML's `ExtraInfoMap` (`h264_datarate`, `h264_passes`, `aud_rate`) is the only way to read a preset's encode values.

### Render Settings Are Sticky Across Jobs
`SetRenderSettings` MERGES onto the project's current render settings: any key you don't pass keeps its last-set value for the next `AddRenderJob`, and `LoadRenderPreset` does NOT clear previously overridden keys — a batch mixing per-job overrides (`VideoQuality`, `MultiPassEncode`) must restate them on every job or they leak into later jobs. `EncodeBitrate` is not a supported key (use `VideoQuality`).

### ImportTimelineFromFile Options
`mediaPool:ImportTimelineFromFile(xmlPath, {timelineName = "name"})` accepts an options table.

### Resolve Heartbeat Check
`resolve:GetProductName()` returns nil if the Resolve connection is lost. Good heartbeat check for long-running scripts.

### Dialog Window Flags (platform-dependent)
On macOS, `Tool = true` + `SetAttribute('WA_MacAlwaysShowToolWindow', true)` keeps the window floating above Resolve (`Window = true` does NOT float there). On Windows/Linux, Tool windows get no taskbar entry and a non-standard frame (thin title bar, no minimize/maximize) — use a regular `Window = true` instead (no `WindowStaysOnTopHint`). Never hand-roll this: use `utils.getDialogFlags()` for `WindowFlags` and call `utils.applyDialogPlatformAttributes(dialog)` after `AddWindow`. The installer template has dependency-free copies (`dialogWindowFlags()` / `applyDialogPlatformAttributes()`) — keep them in sync with `ui.lua`.
