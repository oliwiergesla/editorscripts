-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[
    core.lua - Core DaVinci Resolve initialization and console utilities

    Part of ResolveKit - A comprehensive toolkit for DaVinci Resolve scripting

    This module provides:
    - Resolve API connection and initialization
    - Project and media pool access
    - Console output utilities for formatted printing
    - Platform detection and cross-platform utilities
--]]

local Core = {}

-- ============================================================================
-- PLATFORM DETECTION
-- ============================================================================

-- Detect platform using Fusion's built-in FuPLATFORM_* globals
-- These are always available in DaVinci Resolve's Lua environment
Core.IS_WINDOWS = FuPLATFORM_WINDOWS or false
Core.IS_MACOS = FuPLATFORM_MAC or false
Core.IS_LINUX = FuPLATFORM_LINUX or false

-- Path separator
Core.PATH_SEP = Core.IS_WINDOWS and '\\' or '/'

-- ============================================================================
-- MODIFIER KEY CODES
-- ============================================================================

-- Key codes for modifier keys (Qt-based, used by Fusion UIManager)
-- Note: On macOS, Command key reports as Control (0x1000021) in Fusion
Core.KEY_CODES = {
    CMD = 0x1000021,     -- 16777249 (Command on Mac maps to Control in Fusion)
    SHIFT = 0x1000020,   -- 16777248
    CTRL = 0x1000021,    -- 16777249 (Control key - same as CMD on Mac)
    OPT = 0x1000023,     -- 16777251 (Option/Alt key)
    ALT = 0x1000023,     -- 16777251 (Alias for OPT - Windows terminology)
    META = 0x1000022,    -- 16777250 (Meta/Windows key - may not fire on Mac)
}

-- ============================================================================
-- RESOLVE THEME DETECTION
-- ============================================================================

local cachedTheme = nil

-- Detect Resolve's UI theme by reading config.user.xml.
-- Returns "gray" or "blue" (single return - the value,err convention does NOT
-- apply here; this never fails). Mapping (confirmed against Resolve's own behaviour):
-- IsGrayUserInterfaceEnabled true = gray/classic; false or key absent in a
-- readable file = blue (Resolve only writes the key when gray is enabled);
-- file missing/unreadable = "gray" (safe: all legacy styling is gray-tuned).
-- Theme switches require a Resolve restart, so one cached read per run is
-- always accurate.
-- NOTE: deliberately duplicated as detectResolveTheme() in
-- src/installer/installer_template.lua (dependency-free) - keep both in sync.
function Core.getResolveTheme()
    if cachedTheme then return cachedTheme end
    cachedTheme = "gray"

    local path
    if Core.IS_MACOS then
        local home = os.getenv("HOME")
        path = home and (home .. "/Library/Preferences/Blackmagic Design/DaVinci Resolve/config.user.xml")
    elseif Core.IS_WINDOWS then
        local appData = os.getenv("APPDATA")  -- documented Resolve preferences location (best-effort)
        path = appData and (appData .. "\\Blackmagic Design\\DaVinci Resolve\\Preferences\\config.user.xml")
    else
        local home = os.getenv("HOME")        -- documented Resolve preferences location (best-effort)
        path = home and (home .. "/.local/share/DaVinciResolve/configs/config.user.xml")
    end
    if not path then return cachedTheme end

    local f = io.open(path, "r")
    if not f then return cachedTheme end
    local content = f:read("*all")
    f:close()
    if not content then return cachedTheme end

    local v = content:match("<IsGrayUserInterfaceEnabled>%s*(%a+)%s*</IsGrayUserInterfaceEnabled>")
    cachedTheme = (v == "true") and "gray" or "blue"
    return cachedTheme
end

-- ============================================================================
-- RESOLVE CONNECTION & INITIALIZATION
-- ============================================================================

-- Minimum Resolve version enforced when a script does not pass its own
-- SCRIPT_INFO.MIN_RESOLVE pin to initialize()/initializeWithUI()
Core.DEFAULT_MIN_RESOLVE = "20.0"

-- Get Resolve instance
function Core.getResolve()
    local resolve = Resolve()

    if not resolve then
        return nil, "Resolve instance not available"
    end

    if type(resolve) == "function" then
        resolve = resolve()
    end

    return resolve
end

-- Get the running Resolve version
-- Returns: {major, minor, patch, build, suffix} or nil, errorMessage
-- Both API calls are pcall-guarded: on old Resolve builds a missing method
-- raises (it does not return nil), and GetVersion has existed since Resolve
-- 18 - so total absence alone proves a far older install.
function Core.getResolveVersion(resolve)
    if not resolve then
        return nil, "Resolve instance not available"
    end

    local ok, v = pcall(function() return resolve:GetVersion() end)
    if ok and type(v) == "table" then
        local major = tonumber(v[1] or v.major)
        if major then
            return {
                major = major,
                minor = tonumber(v[2] or v.minor) or 0,
                patch = tonumber(v[3] or v.patch) or 0,
                build = tonumber(v[4] or v.build) or 0,
                suffix = tostring(v[5] or v.suffix or ""),
            }, nil
        end
    end

    -- Fallback: parse GetVersionString (e.g. "18.6.2b Build 5")
    local okStr, s = pcall(function() return resolve:GetVersionString() end)
    if okStr and type(s) == "string" then
        local major, minor, patch = s:match("^(%d+)%.(%d+)%.?(%d*)")
        if major then
            return {
                major = tonumber(major),
                minor = tonumber(minor) or 0,
                patch = tonumber(patch) or 0,
                build = 0,
                suffix = "",
            }, nil
        end
    end

    return nil, "Resolve version could not be detected"
end

-- Check the running Resolve against a minimum version pin ("20.0", "21.0.4"),
-- falling back to Core.DEFAULT_MIN_RESOLVE when minVersion is nil or malformed.
-- Compares major.minor.patch (patch matters: Resolve ships APIs in patch
-- releases); omitted components default to 0, build/beta suffix ignored.
--
-- Returns: true, nil when sufficient, or nil, errorMessage
function Core.checkResolveVersion(resolve, minVersion)
    local minMajor, minMinor, minPatch = tostring(minVersion or ""):match("^(%d+)%.?(%d*)%.?(%d*)")
    if not minMajor then
        minMajor, minMinor, minPatch = Core.DEFAULT_MIN_RESOLVE:match("^(%d+)%.?(%d*)%.?(%d*)")
    end
    -- Label the pin the way it was written: a two-part pin must still read
    -- "20.0", not "20.0.0".
    local pinHadPatch = (minPatch ~= nil and minPatch ~= "")
    minMajor = tonumber(minMajor)
    minMinor = tonumber(minMinor) or 0
    minPatch = tonumber(minPatch) or 0
    local minLabel = minMajor .. "." .. minMinor
    if pinHadPatch then
        minLabel = minLabel .. "." .. minPatch
    end

    local v = Core.getResolveVersion(resolve)
    if not v then
        return nil, "This script requires DaVinci Resolve " .. minLabel ..
            " or newer. Your Resolve version could not be detected, which " ..
            "indicates a much older version."
    end

    if v.major > minMajor
        or (v.major == minMajor and v.minor > minMinor)
        or (v.major == minMajor and v.minor == minMinor and v.patch >= minPatch) then
        return true, nil
    end

    return nil, "This script requires DaVinci Resolve " .. minLabel ..
        " or newer (detected " .. v.major .. "." .. v.minor .. "." .. v.patch .. ")."
end

-- True when err came from checkResolveVersion. Lets the facade title the
-- error dialog "Please Update Resolve" for version-gate failures without
-- extra plumbing through the value,err convention.
function Core.isVersionGateError(err)
    return type(err) == "string"
        and err:find("requires DaVinci Resolve", 1, true) ~= nil
end

-- Get current project
function Core.getCurrentProject(resolve)
    if not resolve then
        return nil, "Resolve instance not available"
    end

    local projectManager = resolve:GetProjectManager()
    if not projectManager then
        return nil, "Could not access Project Manager"
    end

    local project = projectManager:GetCurrentProject()
    if not project then
        return nil, "No project is currently open"
    end

    return project, nil
end

-- Get media pool from project
function Core.getMediaPool(project)
    if not project then
        return nil, "Project not available"
    end

    local mediaPool = project:GetMediaPool()
    if not mediaPool then
        return nil, "Could not access Media Pool"
    end

    return mediaPool, nil
end

-- Initialize Resolve with full error checking
-- minResolveVersion: optional version pin - either the script's SCRIPT_INFO
-- table (its MIN_RESOLVE field is used) or a bare "major.minor" string;
-- nil falls back to Core.DEFAULT_MIN_RESOLVE
-- Returns: resolve, project, mediaPool, fusion (or nil, errorMessage)
function Core.initialize(needFusion, minResolveVersion)
    if type(minResolveVersion) == "table" then
        minResolveVersion = minResolveVersion.MIN_RESOLVE
    end

    local resolve = Core.getResolve()
    if not resolve then
        return nil, "Could not connect to DaVinci Resolve. Make sure it is running."
    end

    -- Version gate before the project check: on an outdated Resolve the
    -- "update Resolve" message must win over "no project open"
    local verOk, verErr = Core.checkResolveVersion(resolve, minResolveVersion)
    if not verOk then
        return nil, verErr
    end

    local project, err = Core.getCurrentProject(resolve)
    if not project then
        return nil, err
    end

    local mediaPool, err = Core.getMediaPool(project)
    if not mediaPool then
        return nil, err
    end

    local fusion = nil
    if needFusion then
        fusion = resolve:Fusion()
        if not fusion then
            return nil, "Could not access Fusion"
        end
    end

    return resolve, project, mediaPool, fusion
end

-- Initialize Resolve with UI components (Fusion UIManager and Dispatcher)
-- minResolveVersion: optional version pin - SCRIPT_INFO table or
-- "major.minor" string (see Core.initialize)
-- Returns: context table or nil, error message
-- Context table contains: {resolve, project, mediaPool, fusion, ui, dispatcher}
function Core.initializeWithUI(minResolveVersion)
    local resolve, project, mediaPool, fusion = Core.initialize(true, minResolveVersion)
    if not resolve then
        -- initialize returns (nil, err) on failure, so the real message
        -- lands in the 'project' slot - propagate it
        return nil, project or "Could not initialize Resolve"
    end

    if not fusion then
        return nil, "Fusion not available"
    end

    local ui = fusion.UIManager
    if not ui then
        return nil, "Could not access UIManager"
    end

    -- bmd is a global provided by Resolve/Fusion runtime
    local dispatcher = bmd.UIDispatcher(ui)
    if not dispatcher then
        return nil, "Could not create UI dispatcher"
    end

    return {
        resolve = resolve,
        project = project,
        mediaPool = mediaPool,
        fusion = fusion,
        ui = ui,
        dispatcher = dispatcher
    }, nil
end

-- ============================================================================
-- PRINTING UTILITIES
-- ============================================================================

-- Cache commonly used separator strings to avoid repeated string.rep calls
local separatorCache = {}

-- Print a separator line
-- Caches separator strings to avoid repeated string.rep() calls
function Core.printSeparator(char, length)
    char = char or "="
    length = length or 70

    local cacheKey = char .. "_" .. length
    if not separatorCache[cacheKey] then
        separatorCache[cacheKey] = string.rep(char, length)
    end

    print(separatorCache[cacheKey])
end

-- Print a formatted header
function Core.printHeader(text)
    Core.printSeparator("=", 70)
    print(text)
    Core.printSeparator("=", 70)
end

-- Print a section divider
function Core.printSection(text)
    print()
    Core.printSeparator("-", 70)
    print(text)
    Core.printSeparator("-", 70)
end

-- Status tags for CLI/console output. Single source of truth so per-item batch
-- lines and the print helpers below share one consistent, ASCII-only convention
-- that renders identically across macOS/Windows/Linux terminals.
Core.STATUS = {
    OK = "[OK]",
    ERROR = "[ERROR]",
    WARN = "[WARN]",
    INFO = "[INFO]",
    SKIP = "[SKIP]",
}

-- Print success message
function Core.printSuccess(message)
    print(Core.STATUS.OK .. " " .. message)
end

-- Print error message
function Core.printError(message)
    print(Core.STATUS.ERROR .. " " .. message)
end

-- Print warning message
function Core.printWarning(message)
    print(Core.STATUS.WARN .. " " .. message)
end

-- Format an aligned, indented per-item status line for batch output.
-- tag: "OK"|"ERROR"|"WARN"|"INFO"|"SKIP" (key into Core.STATUS); msg: detail text.
-- Pads the tag so every message starts at the same column (widest is "[ERROR]"),
-- so callers never hand-roll the spacing. Returns the string (no trailing newline)
-- so it can be passed to progress.update() or printed directly.
function Core.statusLine(tag, msg)
    local t = Core.STATUS[tag] or ("[" .. tostring(tag) .. "]")
    return "  " .. t .. string.rep(" ", math.max(1, 8 - #t)) .. (msg or "")
end

-- Print an aligned per-item status line (convenience wrapper over statusLine).
function Core.printStatus(tag, msg)
    print(Core.statusLine(tag, msg))
end

-- ============================================================================
-- CROSS-PLATFORM UTILITIES
-- ============================================================================

-- Cross-platform sleep function using Fusion's native bmd.wait()
-- More efficient than busy-wait - suspends execution without CPU usage
function Core.sleep(seconds)
    bmd.wait(seconds)
end

-- Open URL in default browser (cross-platform)
-- Prefers Fusion's native bmd.openfileexternal: shell-free, so no console
-- window flashes on Windows. os.execute branches remain as fallback.
function Core.openURL(url)
    if bmd and bmd.openfileexternal then
        bmd.openfileexternal("Open", url)
        return
    end
    if Core.IS_WINDOWS then
        os.execute('start "" "' .. url .. '"')
    elseif Core.IS_MACOS then
        os.execute('open "' .. url .. '"')
    else
        -- Linux: use xdg-open
        os.execute('xdg-open "' .. url .. '" 2>/dev/null &')
    end
end

-- Open folder in system file browser
-- path: Directory path to open
-- Prefers Fusion's native bmd.openfileexternal (see openURL note).
function Core.openFolder(path)
    if bmd and bmd.openfileexternal then
        bmd.openfileexternal("Open", path)
        return
    end
    if Core.IS_MACOS then
        os.execute(string.format('open "%s"', path))
    elseif Core.IS_LINUX then
        os.execute(string.format('xdg-open "%s" &', path))
    else
        -- Windows: use explorer, convert path separators
        local winPath = path:gsub("/", "\\")
        os.execute(string.format('explorer "%s"', winPath))
    end
end

-- Copy text to the system clipboard
-- Returns: true, nil on success / nil, error message on failure
function Core.copyToClipboard(text)
    -- Prefers Fusion's native bmd.setclipboard: shell-free, so no console
    -- window flashes on Windows (clip.exe is a console app). The io.popen
    -- branches remain as fallback for environments where bmd is absent.
    if bmd and bmd.setclipboard then
        bmd.setclipboard(text)
        return true, nil
    end

    local command
    if Core.IS_WINDOWS then
        command = "clip"
    elseif Core.IS_LINUX then
        command = "xclip -selection clipboard 2>/dev/null"
    else
        -- Default to pbcopy: FuPLATFORM_* globals are absent under bare
        -- fuscript, so an undetected platform is most likely still macOS
        command = "pbcopy"
    end

    local pipe = io.popen(command, "w")
    if not pipe then
        return nil, "Could not run clipboard command: " .. command
    end
    pipe:write(text)
    pipe:close()
    return true, nil
end

-- Show a native OS alert dialog, independent of Resolve's UI
-- Works in headless fuscript runs (e.g. StreamDeck) and even when Resolve
-- itself is closed - situations where Fusion UIManager dialogs are unavailable.
-- Fire-and-forget: detached so the script never blocks on dismissal.
function Core.showSystemAlert(title, message)
    if Core.IS_WINDOWS or Core.IS_LINUX then
        -- macOS only: headless flows on Windows/Linux report through the console log instead
        return
    end

    local function escape(s)
        local out = tostring(s)
        out = out:gsub("\\", "\\\\")   -- AppleScript string escapes
        out = out:gsub('"', '\\"')
        out = out:gsub("\n", "\\n")
        out = out:gsub("'", "'\\''")   -- shell single-quote escape
        return out
    end

    os.execute(string.format(
        "osascript -e 'display alert \"%s\" message \"%s\"' >/dev/null 2>&1 &",
        escape(title), escape(message)
    ))
end

-- ============================================================================
-- STRING UTILITIES
-- ============================================================================

-- Quote a string for POSIX shells. Single quotes neutralize all
-- metacharacters; embedded single quotes become '\'' so user-derived values
-- (marker/timeline names) containing backticks or $() can't inject commands.
function Core.shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Substitute {token} placeholders (token names: %w+ only) from a map.
-- Single gsub pass with a function replacement, so '%' in values is literal
-- (no backreference injection) and substituted values are never re-scanned.
-- Unknown tokens are left untouched.
function Core.applyTokens(pattern, map)
    return (pattern:gsub("{(%w+)}", function(token)
        local value = map[token]
        if value == nil then return nil end
        return tostring(value)
    end))
end

-- Byte length of the UTF-8 sequence starting at lead byte b. Invalid lead
-- bytes (including stray continuation bytes) count as single-byte characters
-- so malformed input degrades gracefully instead of erroring - clip and file
-- names are not guaranteed valid UTF-8, especially from legacy Windows media
local function utf8CharBytes(b)
    if b >= 0xF0 then return 4
    elseif b >= 0xE0 then return 3
    elseif b >= 0xC0 then return 2
    else return 1 end
end

-- Number of UTF-8 characters in s (#s counts bytes, not characters)
local function utf8Len(s)
    local i, n, len = 1, 0, #s
    while i <= len do
        i = i + utf8CharBytes(s:byte(i))
        n = n + 1
    end
    return n
end

-- Prefix of s containing at most maxChars whole characters - never cuts
-- inside a multi-byte sequence the way s:sub(1, n) can
local function utf8Prefix(s, maxChars)
    local i, n, len = 1, 0, #s
    while i <= len and n < maxChars do
        i = i + utf8CharBytes(s:byte(i))
        n = n + 1
    end
    return s:sub(1, i - 1)
end

-- Truncate string with ellipsis for preview display
-- Options:
--   text: string to truncate
--   maxLength: maximum length in characters, not bytes (default 50)
--   preserveExtension: if true, keeps file extension visible (default false)
-- Returns: truncated string with "..." if needed
function Core.truncatePreview(text, maxLength, preserveExtension)
    maxLength = maxLength or 50
    if utf8Len(text) <= maxLength then
        return text
    end

    if preserveExtension then
        -- Find extension (last dot)
        local ext = text:match("%.([^%.]+)$") or ""
        local extWithDot = ext ~= "" and ("." .. ext) or ""
        -- Reserve space for "..." and extension
        local available = maxLength - 3 - utf8Len(extWithDot)
        if available < 10 then available = 10 end
        return utf8Prefix(text, available) .. "..." .. extWithDot
    else
        local available = maxLength - 3
        if available < 10 then available = 10 end
        return utf8Prefix(text, available) .. "..."
    end
end

-- Format frame count to timecode
-- Supports drop-frame timecode for 29.97 and 59.94 fps when isDropFrame is true
-- Drop-frame skips frames 0 and 1 at start of each minute, except every 10th minute
function Core.formatTimecode(frameCount, frameRate, isDropFrame)
    -- SMPTE timecode counts at the nominal integer rate: NDF labels 23.976
    -- material as 24, DF re-labels 29.97/59.94 against 30/60. Dividing by the
    -- fractional rate drifts ~3.6s per hour
    local rate = math.floor((frameRate or 24) + 0.5)
    if rate <= 0 then rate = 24 end

    if isDropFrame then
        -- 29.97df drops 2 frame numbers per minute, 59.94df drops 4
        -- (except every 10th minute)
        local dropFrames = 0
        if rate == 30 then
            dropFrames = 2
        elseif rate == 60 then
            dropFrames = 4
        end

        if dropFrames > 0 then
            local framesPerMinute = rate * 60 - dropFrames                -- 1798 / 3596
            local framesPer10Minutes = framesPerMinute * 10 + dropFrames  -- 17982 / 35964
            local tenMinBlocks = math.floor(frameCount / framesPer10Minutes)
            local remainder = frameCount % framesPer10Minutes

            -- Add back the skipped frame numbers so the nominal-rate math
            -- below lands on the drop-frame label (canonical SMPTE formula)
            local additionalFrames = 0
            if remainder > dropFrames then
                additionalFrames = dropFrames * math.floor((remainder - dropFrames) / framesPerMinute)
            end
            frameCount = frameCount + 9 * dropFrames * tenMinBlocks + additionalFrames
        end
    end

    -- Standard timecode calculation (integer math is exact; float division
    -- could land a hair under a boundary and floor to the wrong second)
    local frames = frameCount % rate
    local totalSeconds = math.floor(frameCount / rate)
    local hours = math.floor(totalSeconds / 3600)
    local mins = math.floor((totalSeconds % 3600) / 60)
    local secs = totalSeconds % 60

    -- Use semicolon separator for drop-frame timecode (industry standard)
    if isDropFrame then
        return string.format("%02d:%02d:%02d;%02d", hours, mins, secs, frames)
    else
        return string.format("%02d:%02d:%02d:%02d", hours, mins, secs, frames)
    end
end

-- ============================================================================
-- RETURN MODULE
-- ============================================================================

return Core