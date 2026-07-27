local SCRIPT_INFO = {
    NAME = "Script Launcher",
    VERSION = "1.0.0",
    MIN_RESOLVE = "20.0",
}
-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[

    Script Launcher

    Launches any installed Resolve script from a Stream Deck key. One
    installed launcher serves unlimited buttons: each button passes a
    script slug, and the CLI mode resolves it against the Scripts folder
    at press time, then starts the target in its own fuscript process.

    Features:
        - Enumerates every .lua under the Fusion Scripts root (Utility,
          Comp, Edit and their subfolders) into one dropdown
        - Setup UI installs the launcher in .bin/ next to this script and
          builds the Stream Deck command for you (Copy Command, Test)
        - Commands store only "<launcher> <slug>" - no absolute target
          paths - so buttons survive reinstalls, scripts moving between
          folders, and (on macOS, where the install path has no username)
          machine moves; a fresh machine only needs this window opened
          once to regenerate the launcher
        - On Windows, Stream Deck's Open action cannot pass arguments, so
          Copy Command writes a per-slug .vbs with the slug baked in and
          copies just that file's path
        - CLI mode failures pop a native alert (even with Resolve closed)
          and are logged to .data/script_launcher.log; launched scripts
          write to .data/script_launcher_target.log
          (externally launched scripts can't print to Resolve's console,
          so their output is written to these log files)

    Usage:
        1. Run from Workspace > Scripts with Resolve open to launch the
           setup dialog
        2. Pick a script, Copy Command, then paste into a Stream Deck
           System: Open action (macOS: a full command; Windows: a baked
           .vbs path)
        3. Generated launchers invoke the CLI mode, e.g.
           script-launcher.sh markers-to-stills

--]]

local utils = require("ResolveKit")
local STYLES = utils.STYLES

-- ============================================================================
-- CONFIG
-- ============================================================================

local CONFIG = {
    DIALOG_WIDTH = 420,
    DIALOG_FALLBACK_HEIGHT = 320,  -- only used if fitDialogHeight fails
    MAX_WALK_DEPTH = 12,
}

-- Settings key for persisting the last-selected script
local SETTINGS_KEY = "scriptLauncher"

-- ============================================================================
-- SETTINGS
-- ============================================================================

local function loadPrefs()
    local settings = utils.loadSettings() or {}
    return settings[SETTINGS_KEY] or {}
end

local function savePrefs(prefs)
    local settings = utils.loadSettings() or {}
    settings[SETTINGS_KEY] = prefs
    utils.saveSettings(settings)
end

-- ============================================================================
-- PLATFORM
-- All OS-specific paths and launcher generation live here, self-contained:
--   macOS:   one executable .sh (Open needs the extension to run it)
--   Windows: .vbs wrappers - each sets LUA_PATH/EDITORSCRIPTS_CLI in its
--            process env and runs fuscript directly, hidden. The Open
--            action cannot pass arguments (the whole field is treated as
--            one filename), so every button gets a baked .vbs with its
--            slug hard-coded; the generic arg-forwarding .vbs serves
--            cmd/manual use. Never shell-redirect launcher output to the
--            resolver log: cmd's exclusive redirect lock serializes
--            presses - the CLI tees its own log instead. The target log's
--            exclusive handle is kept ON PURPOSE: it makes launched
--            scripts single-instance on Windows.
-- Caveat: the Windows install path lives under per-user %APPDATA%, so the
-- alongside-the-script layout is not cross-machine portable there.
-- ============================================================================

local FUSCRIPT_MAC = "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript"

-- FuPLATFORM_* globals (behind utils.IS_*) are absent under bare fuscript -
-- the launcher path - so fall back to sniffing the filesystem.
local function detectOS()
    if utils.IS_MACOS then return "mac" end
    if utils.IS_WINDOWS then return "windows" end
    if utils.IS_LINUX then return "linux" end
    if package.config:sub(1, 1) == "\\" then return "windows" end
    if utils.fileExists(FUSCRIPT_MAC) then return "mac" end
    return "unknown"
end

local function findFuscriptWindows()
    local candidates = {
        (os.getenv("PROGRAMFILES") or "C:\\Program Files")
            .. "\\Blackmagic Design\\DaVinci Resolve\\fuscript.exe",
        "C:\\Program Files\\Blackmagic Design\\DaVinci Resolve\\fuscript.exe",
    }
    for _, candidate in ipairs(candidates) do
        if utils.fileExists(candidate) then
            return candidate
        end
    end
    return nil
end

-- Resolve this script's own file path (utils.getScriptPath walks the call
-- stack for the outermost main chunk: in dist builds everything is bundled
-- into the one installed file; in dev it resolves to this file in
-- src/scripts/). Falls back to the canonical install FILENAMES below, which
-- the lib's dir-only fallback can't provide.
local function getOwnScriptPath(osName)
    local path = utils.getScriptPath()
    if path then
        return path, nil
    end

    local candidates = {}
    if osName == "mac" then
        candidates = {
            "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/EditorScripts/" .. SCRIPT_INFO.NAME .. ".lua",
            "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/scripts/script_launcher.lua",
        }
    elseif osName == "windows" then
        local appdata = os.getenv("APPDATA")
        if appdata then
            candidates = {
                appdata .. "\\Blackmagic Design\\DaVinci Resolve\\Support\\Fusion\\Scripts\\Utility\\EditorScripts\\"
                    .. SCRIPT_INFO.NAME .. ".lua",
            }
        end
    end
    for _, candidate in ipairs(candidates) do
        if utils.fileExists(candidate) then
            return candidate, nil
        end
    end
    return nil, "Could not locate this script on disk. Reinstall it, then rerun from Workspace > Scripts."
end

local function buildMacPlatform(scriptPath)
    local scriptDir = scriptPath:match("^(.*)/[^/]+$") or "."
    local dataDir = scriptDir .. "/.data"
    local logPath = dataDir .. "/script_launcher.log"
    local targetLogPath = dataDir .. "/script_launcher_target.log"
    return {
        scriptPath = scriptPath,
        binDir = scriptDir .. "/.bin",
        dataDir = dataDir,
        -- Stream Deck's Open action launches via LaunchServices, which needs
        -- the .sh extension to run the file - extensionless executables fail
        launcherName = "script-launcher.sh",
        logPath = logPath,
        targetLogPath = targetLogPath,
        -- No log redirect here: the CLI tees its own output to the log
        -- from Lua (see openCliLog), keeping both platforms identical.
        buildLauncherContent = function(targetScriptPath)
            return table.concat({
                "#!/bin/bash",
                "# Generated by " .. SCRIPT_INFO.NAME .. " v" .. SCRIPT_INFO.VERSION
                    .. " - do not edit; rerun the script from Resolve's menu to regenerate.",
                'export LUA_PATH="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Modules/Lua/?.lua;;"',
                "export EDITORSCRIPTS_CLI=1",
                string.format('exec "%s" "%s" "$@" >/dev/null 2>&1', FUSCRIPT_MAC, targetScriptPath),
                "",
            }, "\n")
        end,
        makeExecutable = function(path)
            os.execute(string.format('chmod +x "%s"', path))
        end,
        -- Start the target in its own fuscript process; nohup + & so this
        -- short-lived resolver can exit while the target keeps running.
        -- LUA_PATH is inherited from the launcher's export above. Returns
        -- true when the spawn command succeeded. Unlike Windows, POSIX does
        -- not lock the target log, so second instances DO launch here.
        spawnDetached = function(targetPath)
            local code = os.execute(string.format('nohup "%s" "%s" > "%s" 2>&1 &',
                FUSCRIPT_MAC, targetPath, targetLogPath))
            return code == 0
        end,
        -- Run the installed launcher exactly as a Stream Deck press would
        runLauncher = function(launcherPath, slug)
            os.execute(string.format('"%s" %s > /dev/null 2>&1 &', launcherPath, slug))
        end,
    }
end

local function buildWindowsPlatform(scriptPath, fuscriptPath)
    local scriptDir = scriptPath:match("^(.*)[/\\][^/\\]+$") or "."
    local dataDir = utils.joinPath(scriptDir, ".data")
    local logPath = utils.joinPath(dataDir, "script_launcher.log")
    local targetLogPath = utils.joinPath(dataDir, "script_launcher_target.log")
    local binDir = utils.joinPath(scriptDir, ".bin")
    local platform = {
        scriptPath = scriptPath,
        binDir = binDir,
        dataDir = dataDir,
        launcherName = "script-launcher.vbs",
        logPath = logPath,
        targetLogPath = targetLogPath,
        makeExecutable = function() end,
        -- start /b: new process, no new window (the resolver already runs
        -- windowless via the .vbs); LUA_PATH/EDITORSCRIPTS_CLI are
        -- inherited from the resolver's own environment (set by the .vbs).
        -- The exclusive redirect handle on targetLogPath doubles as a
        -- deliberate single-instance latch: while a launched script is
        -- still open it holds the log, this spawn's redirect fails, and
        -- the target does not start. Returns true when the spawn command
        -- succeeded so the caller can say so instead of failing silently.
        spawnDetached = function(targetPath)
            local code = os.execute(string.format('start "" /b "%s" "%s" > "%s" 2>&1',
                fuscriptPath, targetPath, targetLogPath))
            return code == 0
        end,
        runLauncher = function(launcherPath, slug)
            os.execute(string.format('start "" "%s" %s', launcherPath, slug))
        end,
    }
    -- Shared .vbs tail: set the env in the wscript process (Run children
    -- inherit it) and launch fuscript directly, hidden - no cmd layer, so
    -- each press costs one process spawn and one AV scan less. The
    -- Lua-written log is the debug surface. NEVER add a shell redirect to
    -- a shared file anywhere in this chain: cmd opens redirect targets
    -- exclusively, which would make overlapping presses fail silently.
    local vbsRunTail = table.concat({
        "Dim sdShell, sdEnv",
        'Set sdShell = CreateObject("WScript.Shell")',
        'Set sdEnv = sdShell.Environment("PROCESS")',
        'sdEnv("LUA_PATH") = sdShell.ExpandEnvironmentStrings("%PROGRAMDATA%") & "\\Blackmagic Design\\DaVinci Resolve\\Fusion\\Modules\\Lua\\?.lua;;"',
        'sdEnv("EDITORSCRIPTS_CLI") = "1"',
        "sdShell.Run sdCmd, 0, False",
    }, "\r\n")
    platform.buildLauncherContent = function(targetScriptPath)
        return table.concat({
            "' Generated by " .. SCRIPT_INFO.NAME .. " v" .. SCRIPT_INFO.VERSION
                .. " - runs " .. SCRIPT_INFO.NAME .. " with no console window.",
            "' Do not edit; rerun the script from Resolve's menu to regenerate.",
            "Dim sdCmd, sdI",
            'sdCmd = Chr(34) & "' .. fuscriptPath .. '" & Chr(34) & " " & Chr(34) & "' .. targetScriptPath .. '" & Chr(34)',
            "For sdI = 0 To WScript.Arguments.Count - 1",
            '    sdCmd = sdCmd & " " & Chr(34) & WScript.Arguments(sdI) & Chr(34)',
            "Next",
            vbsRunTail,
            "",
        }, "\r\n")
    end
    -- Per-button variant with the slug hard-coded (Stream Deck's Open action
    -- can't pass arguments on Windows - see the PLATFORM banner). Slugs are
    -- filename- and quoting-safe by construction (lowercase alphanumerics
    -- and hyphens only), so the slug is embedded verbatim.
    platform.buildBakedLauncherContent = function(slug)
        return table.concat({
            "' Generated by " .. SCRIPT_INFO.NAME .. " v" .. SCRIPT_INFO.VERSION
                .. " - launches: " .. slug .. " (no console window).",
            "' Do not edit; delete this file and re-copy from the Setup dialog to change it.",
            "Dim sdCmd",
            'sdCmd = Chr(34) & "' .. fuscriptPath .. '" & Chr(34) & " " & Chr(34) & "' .. scriptPath .. '" & Chr(34) & " ' .. slug .. '"',
            vbsRunTail,
            "",
        }, "\r\n")
    end
    return platform
end

local PLATFORM = nil
local PLATFORM_ERR = nil
do
    local osName = detectOS()
    if osName ~= "mac" and osName ~= "windows" then
        PLATFORM_ERR = "This platform is not supported yet (macOS and Windows only)."
    else
        local scriptPath, pathErr = getOwnScriptPath(osName)
        if not scriptPath then
            PLATFORM_ERR = pathErr
        elseif osName == "mac" then
            PLATFORM = buildMacPlatform(scriptPath)
        else
            local fuscriptWin = findFuscriptWindows()
            if not fuscriptWin then
                PLATFORM_ERR = "Could not find fuscript.exe under Program Files\\Blackmagic Design\\DaVinci Resolve."
                    .. " Is DaVinci Resolve installed in the default location?"
            else
                PLATFORM = buildWindowsPlatform(scriptPath, fuscriptWin)
            end
        end
    end
end

-- ============================================================================
-- SCRIPT ENUMERATION
-- Labels are Scripts-root-relative ('Utility/EditorScripts/Markers to
-- Stills'); slugs are the space-free tokens the launcher command carries.
-- ============================================================================

-- Known per-OS Scripts roots, used when no live MapPath is available (CLI
-- mode may run before a Fusion handle exists) and as a safety net when it
-- is. Mirrors src/installer/tools/open_scripts_folder.lua; on Windows the
-- per-user Support tree is where Resolve actually installs user scripts.
local function fallbackScriptsRoots()
    local candidates = {}
    if package.config:sub(1, 1) == "\\" then
        local appdata = os.getenv("APPDATA")
        if appdata then
            candidates[#candidates + 1] = appdata .. "\\Blackmagic Design\\DaVinci Resolve\\Support\\Fusion\\Scripts"
        end
        local programData = os.getenv("PROGRAMDATA")
        if programData then
            candidates[#candidates + 1] = programData .. "\\Blackmagic Design\\DaVinci Resolve\\Fusion\\Scripts"
        end
    else
        candidates[#candidates + 1] = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts"
        candidates[#candidates + 1] = "/var/BlackmagicDesign/DaVinci Resolve/Fusion/Scripts"
    end
    return candidates
end

-- Collect the existing Scripts roots: live MapPath (authoritative, and can
-- pack several ';'-separated locations) merged with the known fallbacks -
-- the user and system trees can both hold scripts.
-- Returns: roots, nil on success or nil, error on failure
local function getScriptsRoots(fusion)
    local candidates = {}
    if fusion then
        local ok, mapped = pcall(function() return fusion:MapPath("Scripts:/") end)
        if ok and type(mapped) == "string" and mapped ~= "" and mapped ~= "Scripts:/" then
            for segment in mapped:gmatch("[^;]+") do
                candidates[#candidates + 1] = segment
            end
        end
    end
    for _, candidate in ipairs(fallbackScriptsRoots()) do
        candidates[#candidates + 1] = candidate
    end

    local roots, seen = {}, {}
    for _, candidate in ipairs(candidates) do
        local normalized = candidate:gsub("[/\\]+$", "")
        if normalized ~= "" and not seen[normalized] and utils.directoryExists(normalized) then
            seen[normalized] = true
            roots[#roots + 1] = normalized
        end
    end
    if #roots == 0 then
        return nil, "Could not locate the Fusion Scripts folder."
    end
    return roots, nil
end

-- Space-free slug for the Stream Deck command, so the launcher argument
-- never needs quoting
local function slugify(text)
    local slug = text:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if slug == "" then
        slug = "script"
    end
    return slug
end

local function splitLabel(label)
    local parts = {}
    for part in label:gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    return parts
end

-- Enumerate every .lua under the roots.
-- Returns: sorted array of { label, path, slug }, nil or nil, error.
-- Slugs are assigned deterministically over the whole sorted list, so the
-- setup UI and the CLI resolver always agree on the same machine. Basename
-- collisions escalate to parent folder components (first occurrence in sort
-- order keeps the short slug); if the installed set differs across machines
-- a colliding slug may need a re-copy there - the dropdown labels stay
-- unambiguous either way.
local function enumerateScripts(roots)
    local entries, seenLabels = {}, {}
    for _, root in ipairs(roots) do
        local files = utils.walkDirectory(root, {
            recursive = true,
            extension = "lua",
            skipDotDirs = true,
            maxDepth = CONFIG.MAX_WALK_DEPTH,
        })
        if files then
            for _, file in ipairs(files) do
                local label = file.relativePath:gsub("%.[Ll][Uu][Aa]$", "")
                if not seenLabels[label] then  -- first root wins (MapPath order)
                    seenLabels[label] = true
                    entries[#entries + 1] = { label = label, path = file.path }
                end
            end
        end
    end
    if #entries == 0 then
        return nil, "No .lua scripts found under: " .. table.concat(roots, ", ")
    end

    table.sort(entries, function(a, b)
        return a.label:lower() < b.label:lower()
    end)

    local taken = {}
    for _, entry in ipairs(entries) do
        local parts = splitLabel(entry.label)
        local slug = slugify(parts[#parts])
        local depth = 1
        while taken[slug] and depth < #parts do
            slug = slugify(table.concat(parts, " ", #parts - depth, #parts))
            depth = depth + 1
        end
        local base, suffix = slug, 2
        while taken[slug] do
            slug = base .. "-" .. suffix
            suffix = suffix + 1
        end
        taken[slug] = true
        entry.slug = slug
    end

    return entries, nil
end

local function findBySlug(entries, slug)
    for _, entry in ipairs(entries) do
        if entry.slug == slug then
            return entry
        end
    end
    return nil
end

-- ============================================================================
-- LAUNCHER MANAGEMENT
-- The Setup UI installs the launcher file(s) in the hidden .bin folder next
-- to this script. On macOS the copied command is the quoted launcher path
-- (the install path contains spaces) plus the slug; on Windows it is just
-- the path of a per-slug baked .vbs (see the PLATFORM banner). Stale baked
-- launchers are harmless tiny files - delete .bin and re-copy the buttons
-- you still use to clean up.
-- ============================================================================

-- The generic launcher entry point (.sh on macOS - the Stream Deck target
-- there; the arg-forwarding .vbs on Windows, for cmd/manual use - Stream
-- Deck buttons point at per-slug baked .vbs files instead).
local function launcherEntryPath()
    return utils.joinPath(PLATFORM.binDir, PLATFORM.launcherName)
end

-- Write content to path only when the existing bytes differ. Binary mode so
-- compares are byte-exact (the Windows launchers need CRLF preserved).
-- Returns true if written, false if already up to date, nil, error on failure.
local function writeFileIfChanged(path, content)
    local f = io.open(path, "rb")
    if f then
        local existing = f:read("*a")
        f:close()
        if existing == content then
            return false, nil
        end
    end
    local out = io.open(path, "wb")
    if not out then
        return nil, "Could not write launcher: " .. path
    end
    out:write(content)
    out:close()
    return true, nil
end

-- Install or refresh the launcher file(s). Returns {ok, path, message} where
-- path is the generic launcher entry point.
local function ensureLauncher()
    local files = {
        {
            path = utils.joinPath(PLATFORM.binDir, PLATFORM.launcherName),
            content = PLATFORM.buildLauncherContent(PLATFORM.scriptPath),
        },
    }

    local target = launcherEntryPath()

    utils.createDirectory(PLATFORM.binDir)
    utils.createDirectory(PLATFORM.dataDir)

    local anyWritten = false
    for _, file in ipairs(files) do
        local written, err = writeFileIfChanged(file.path, file.content)
        if err then
            return { ok = false, path = file.path, message = err }
        end
        anyWritten = anyWritten or written
    end
    if not anyWritten then
        return { ok = true, path = target, message = "Launcher up to date: " .. target }
    end
    PLATFORM.makeExecutable(utils.joinPath(PLATFORM.binDir, PLATFORM.launcherName))

    return { ok = true, path = target, message = "Launcher installed: " .. target }
end

-- Write (or refresh) the baked .vbs for this slug; returns its path - the
-- file a Windows Stream Deck "System: Open" action should point at.
local function ensureBakedLauncher(slug)
    local path = utils.joinPath(PLATFORM.binDir, "script-launcher-" .. slug .. ".vbs")
    utils.createDirectory(PLATFORM.binDir)
    local _, err = writeFileIfChanged(path, PLATFORM.buildBakedLauncherContent(slug))
    if err then
        return nil, err
    end
    return path, nil
end

-- ============================================================================
-- CLI MODE
-- ============================================================================

local USAGE = [[
Usage:
  script-launcher.sh <script-slug>

The slug names a script installed in the Fusion Scripts folder, e.g.
  script-launcher.sh markers-to-stills

The slug is resolved against the Scripts folder at press time, so commands
keep working after reinstalls and after scripts move between folders. The
launched script's output is written to .data/script_launcher_target.log.

Run this script from Resolve (Workspace > Scripts) to open the setup window,
which lists every installed script and builds these commands for you.]]

local function printUsage()
    print(USAGE)
end

-- Headless failures must be visible: log line + native alert dialog
-- (the alert works even when Resolve itself is closed)
local function cliFail(message)
    utils.printError(message)
    utils.showSystemAlert(SCRIPT_INFO.NAME, message)
end

local function runCliMain(argv)
    local slug = argv[1]

    -- Timestamp delimits each invocation in the persistent log file, so a
    -- failed launch can be correlated with the button press that caused it.
    print(string.format("[%s] %s", os.date("%Y-%m-%d %H:%M:%S"), SCRIPT_INFO.NAME))
    print("Requested script: " .. slug)

    if argv[2] ~= nil then
        cliFail("Expected a single script slug, got extra arguments.")
        printUsage()
        return
    end

    -- pcall: with Resolve closed the Resolve() global may not exist at all.
    -- On failure, initialize returns nil plus an error string in the second
    -- slot, so project holds the error message when resolve is nil. The
    -- target script needs a running Resolve anyway, so failing here gives
    -- one clear alert instead of a silent dead child process.
    local initOk, resolve, project = pcall(utils.initialize, false, SCRIPT_INFO)
    if not initOk or not resolve then
        local message = "Could not connect to DaVinci Resolve. Make sure it is running."
        if initOk and type(project) == "string" then
            message = project
        end
        cliFail(message)
        return
    end

    -- MapPath needs a Fusion handle; enumeration falls back to the known
    -- roots without one
    local fusion = nil
    local fusionOk, fusionHandle = pcall(function() return resolve:Fusion() end)
    if fusionOk then
        fusion = fusionHandle
    end

    local roots, rootsErr = getScriptsRoots(fusion)
    if not roots then
        cliFail(rootsErr)
        return
    end

    local entries, enumErr = enumerateScripts(roots)
    if not entries then
        cliFail(enumErr)
        return
    end

    local target = findBySlug(entries, slug)
    if not target then
        cliFail(string.format(
            "No installed script matches '%s'. Open %s from Workspace > Scripts and re-copy the command.",
            slug, SCRIPT_INFO.NAME))
        return
    end

    print("Launching: " .. target.label)
    print("Target output: " .. PLATFORM.targetLogPath)
    -- A fresh fuscript process, never dofile() in-process: this resolver's
    -- arg table would leak into targets that have their own CLI modes
    -- (node_toggle, this script itself)
    if not PLATFORM.spawnDetached(target.path) then
        -- On Windows the running target holds the target log exclusively,
        -- which acts as a single-instance latch (see spawnDetached)
        cliFail(string.format(
            "%s did not start - it may already be open (close its window to relaunch).",
            target.label))
        return
    end
    utils.printSuccess("Launched " .. target.label)
end

-- CLI log, written from Lua rather than by shell redirection: cmd opens
-- redirect targets exclusively, so a shell-held log makes overlapping
-- Stream Deck presses die on a sharing violation before fuscript starts.
-- Lua's CRT append is share-mode - concurrent runs interleave instead of
-- colliding. Size-capped; if the log can't be opened, logging is skipped
-- entirely (it must never block the launch).
local LOG_MAX_BYTES = 262144

local function openCliLog()
    local f = io.open(PLATFORM.logPath, "ab")
    if f and (f:seek("end") or 0) > LOG_MAX_BYTES then
        f:close()
        f = io.open(PLATFORM.logPath, "wb")
    end
    return f
end

-- Tee every print (all console helpers route through the global) into the
-- log for the duration of the CLI run, then restore and close.
local function runCli(argv)
    local logFile = openCliLog()
    local rawPrint = print
    if logFile then
        print = function(...)
            rawPrint(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[#parts + 1] = tostring(select(i, ...))
            end
            logFile:write(table.concat(parts, "\t"), "\n")
        end
    end
    local ok, err = pcall(runCliMain, argv)
    print = rawPrint
    if logFile then
        logFile:close()
    end
    if not ok then
        error(err, 0)
    end
end

-- ============================================================================
-- SETUP UI MODE
-- ============================================================================

local function runSetupUI(ctx)
    local ui = ctx.ui
    local dispatcher = ctx.dispatcher

    local roots, rootsErr = getScriptsRoots(ctx.fusion)
    if not roots then
        utils.printError(rootsErr)
        return
    end

    local entries, enumErr = enumerateScripts(roots)
    if not entries then
        utils.printError(enumErr)
        return
    end
    print(string.format("Found %d scripts under: %s", #entries, table.concat(roots, ", ")))

    -- Ensure the launcher on open: a fresh machine only needs this window
    -- opened once for existing Stream Deck buttons to work again
    local launcherStatus = ensureLauncher()
    print(launcherStatus.message)

    local dialog = dispatcher:AddWindow({
        ID = "ScriptLauncherDialog",
        WindowTitle = SCRIPT_INFO.NAME,
        WindowFlags = utils.getDialogFlags(),
        StyleSheet = STYLES.WINDOW,
    }, ui:VGroup{
        ID = "DialogContent",
        MinimumSize = {CONFIG.DIALOG_WIDTH, 0},
        MaximumSize = {CONFIG.DIALOG_WIDTH, 16777215},  -- width pinned, height auto (fitDialogHeight)
        Spacing = 0,

        ui:HGroup{
            ID = "MainContent",
            Weight = 0,
            Spacing = 0,
            ui:HGap(28),

            ui:VGroup{
                ID = "root",

                ui:VGap(28),

                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Text = "Script:",
                        Font = ui:Font{ PixelSize = 12 },
                        MinimumSize = {110, 20},
                    },
                    ui:ComboBox{
                        ID = "ScriptCombo",
                        MinimumSize = {220, 33},
                    },
                },

                ui:VGap(28),

                ui:Button{
                    ID = "CopyButton",
                    Text = "Copy Command",
                    MinimumSize = {160, 45},
                    Font = ui:Font{ PixelSize = 12 },
                    StyleSheet = STYLES.BUTTON_PRIMARY,
                },
                ui:Button{
                    ID = "TestButton",
                    Text = "Test",
                    MinimumSize = {160, 45},
                    Font = ui:Font{ PixelSize = 12 },
                    StyleSheet = STYLES.BUTTON_TERTIARY_SPACED,
                },

                ui:VGap(28),
            },

            ui:HGap(28),
        },

        ui:VGap(0, 1),  -- stretch absorbs surplus height, pins footer to bottom

        -- Footer
        utils.createFooter(ui, {
            scriptName = SCRIPT_INFO.NAME,
            version = SCRIPT_INFO.VERSION,
        }),
    })

    utils.applyDialogPlatformAttributes(dialog)

    -- Auto-size height to content; set before Show so auto-centering still works
    if not utils.fitDialogHeight(dialog, CONFIG.DIALOG_WIDTH) then
        dialog:Resize({CONFIG.DIALOG_WIDTH, CONFIG.DIALOG_FALLBACK_HEIGHT})
    end

    utils.attachFooterHandler(dialog)

    local scriptCombo = dialog:Find("ScriptCombo")

    local labels = {}
    for i, entry in ipairs(entries) do
        labels[i] = entry.label
    end
    scriptCombo:AddItems(labels)

    -- Preselect the last-used script, stored by label: labels are stable
    -- across reinstalls, indices are not
    scriptCombo.CurrentIndex = 0
    local prefs = loadPrefs()
    if prefs.lastLabel then
        for i, entry in ipairs(entries) do
            if entry.label == prefs.lastLabel then
                scriptCombo.CurrentIndex = i - 1  -- CurrentIndex is 0-based
                break
            end
        end
    end

    local function selectedEntry()
        return entries[scriptCombo.CurrentIndex + 1]
    end

    function dialog.On.CopyButton.Clicked(ev)
        local entry = selectedEntry()
        if not entry then
            utils.printError("Pick a script first.")
            return
        end
        local status = ensureLauncher()
        if not status.ok then
            utils.printError(status.message)
            return
        end
        local command
        -- Windows: Stream Deck's Open action can't pass arguments, so the
        -- "command" is just the path of a .vbs with the slug baked in,
        -- quoted - the Open field splits an unquoted path on spaces.
        if PLATFORM.buildBakedLauncherContent then
            local bakedPath, bakedErr = ensureBakedLauncher(entry.slug)
            if not bakedPath then
                utils.printError(bakedErr)
                return
            end
            command = '"' .. bakedPath .. '"'
        else
            command = '"' .. status.path .. '" ' .. entry.slug
        end
        local copied, copyErr = utils.copyToClipboard(command)
        if copied then
            print("Copied to clipboard: " .. command)
            if PLATFORM.buildBakedLauncherContent then
                print("In Stream Deck add a System > Open action and paste this file path.")
            else
                print("In Stream Deck add a System > Open action and paste this command.")
            end
            savePrefs({ lastLabel = entry.label })
        else
            utils.printError("Copy failed: " .. tostring(copyErr))
        end
    end

    -- Runs via runWithDialogBusy: executes the installed launcher file, so
    -- the test exercises exactly what a Stream Deck press will do
    local function doTest()
        local entry = selectedEntry()
        if not entry then
            utils.printError("Pick a script first.")
            return
        end
        local status = ensureLauncher()
        if not status.ok then
            utils.printError(status.message)
            return
        end
        PLATFORM.runLauncher(status.path, entry.slug)
        print("Test launched: " .. entry.label)
        print("Launcher log: " .. PLATFORM.logPath)
        print("Target output: " .. PLATFORM.targetLogPath)
    end

    function dialog.On.TestButton.Clicked(ev)
        utils.runWithDialogBusy(dialog, doTest)
    end

    function dialog.On.ScriptLauncherDialog.Close(ev)
        local entry = selectedEntry()
        if entry then
            savePrefs({ lastLabel = entry.label })
        end
        dispatcher:ExitLoop()
    end

    dialog:RecalcLayout()
    utils.centerDialogOnScreen(dialog, ui, dispatcher)
    dialog:Show()
    dispatcher:RunLoop()
    dialog:Hide()
end

-- ============================================================================
-- MAIN SCRIPT
-- ============================================================================

print("\n")
utils.printHeader(SCRIPT_INFO.NAME .. " v" .. SCRIPT_INFO.VERSION)

if not PLATFORM then
    utils.printError(PLATFORM_ERR or "This platform is not supported yet (macOS and Windows only).")
    return
end

-- fuscript passes CLI arguments via the standard global arg table (1-based)
if type(arg) == "table" and type(arg[1]) == "string" and arg[1] ~= "" then
    runCli(arg)
    -- Hard-exit to skip fuscript's ~1.5s connection/host teardown so the
    -- resolver dies right after spawning the target (which runs in its own
    -- detached fuscript process and is unaffected). Gated on the env
    -- marker that only the generated launchers set - it must never fire
    -- inside Resolve's script host, where os.exit would kill the host.
    if os.getenv("EDITORSCRIPTS_CLI") == "1" then
        os.exit(0)
    end
    return
end

local ctx, err = utils.initializeWithUI(SCRIPT_INFO)
if ctx then
    runSetupUI(ctx)
else
    -- Headless run with no arguments (or Resolve unavailable): show usage
    utils.printError(err or "Could not initialize Resolve UI.")
    printUsage()
end
