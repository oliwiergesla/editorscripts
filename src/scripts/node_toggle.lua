local SCRIPT_INFO = {
    NAME = "Node Toggle",
    VERSION = "1.0.4",
    MIN_RESOLVE = "20.0",
}
-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[

    Node Toggle

    Toggles a single node on/off in Resolve's color node graphs. Designed
    for Stream Deck: one installed command serves unlimited buttons.

    Features:
        - Targets the clip, preclip, postclip, or timeline node graph;
          'all' or a comma-separated list toggles several graphs at once
        - Setup UI installs a launcher in .bin/ next to this script and
          builds the Stream Deck command for you (Copy Command, Test)
        - macOS commands embed this script's absolute install path; Resolve
          maps Scripts:/ to the per-user Library folder, so re-copy
          commands when moving to another Mac or user account
        - On Windows, Stream Deck's Open action cannot pass arguments, so
          Copy Command writes a per-button .vbs with the args baked in and
          copies just that file's path
        - CLI mode failures pop a native alert (even with Resolve closed)
          and are logged to .data/node_toggle.log
        - On/off state is tracked in .data/node_toggle_state.json (the API
          has no GetNodeEnabled); nodes are assumed enabled on first use

    Usage:
        1. Run from Workspace > Scripts with Resolve open to launch the
           setup dialog
        2. Pick a location, choose name or index lookup, type the node,
           then Copy Command and paste into a Stream Deck System: Open
           action (macOS: a full command; Windows: a baked .vbs path)
        3. Generated launchers invoke the CLI mode, e.g.
           node-toggle.sh postclip DCTL 1 (flags documented in the CLI usage text)

--]]

local utils = require("ResolveKit")
local STYLES, COLORS = utils.STYLES, utils.COLORS

-- ============================================================================
-- CONFIG
-- ============================================================================

local CONFIG = {
    DIALOG_WIDTH = 420,
    -- Hand-tuned so the footer spacing matches renamer.lua; surplus
    -- height stretches the buttons, not the 28px gap above the footer
    DIALOG_FALLBACK_HEIGHT = 380,  -- only used if fitDialogHeight fails
    POSITIONS = { "clip", "preclip", "postclip", "timeline" },
    -- Location dropdown options; value is what the generated command uses
    LOCATIONS = {
        { label = "Everywhere", value = "all" },
        { label = "Clip", value = "clip" },
        { label = "Pre-clip", value = "preclip" },
        { label = "Post-clip", value = "postclip" },
        { label = "Timeline", value = "timeline" },
    },
}

-- ============================================================================
-- PLATFORM
-- All OS-specific paths and launcher generation live here, self-contained:
--   macOS:   one executable .sh (Open needs the extension to run it)
--   Windows: .vbs wrappers - each sets LUA_PATH/EDITORSCRIPTS_CLI in its
--            process env and runs fuscript directly, hidden. The Open
--            action cannot pass arguments (the whole field is treated as
--            one filename), so every button gets a baked .vbs with its
--            args hard-coded; the generic arg-forwarding .vbs serves
--            cmd/manual use. Never shell-redirect launcher output to the
--            log: cmd's exclusive redirect lock serializes presses - the
--            CLI tees its own log instead.
-- Caveat: installs land in per-user folders on both platforms (macOS maps
-- Scripts:/ to ~/Library; Windows uses %APPDATA%), so the
-- alongside-the-script layout is not cross-machine portable.
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
            -- Resolve maps Scripts:/ to the per-user Library folder on macOS,
            -- so suite installs land there rather than in system /Library
            (os.getenv("HOME") or "") .. "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/EditorScripts/" .. SCRIPT_INFO.NAME .. ".lua",
            "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/scripts/node_toggle.lua",
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
    local logPath = dataDir .. "/node_toggle.log"
    return {
        scriptPath = scriptPath,
        binDir = scriptDir .. "/.bin",
        dataDir = dataDir,
        -- Stream Deck's Open action launches via LaunchServices, which needs
        -- the .sh extension to run the file - extensionless executables fail
        launcherName = "node-toggle.sh",
        statePath = dataDir .. "/node_toggle_state.json",
        logPath = logPath,
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
    }
end

local function buildWindowsPlatform(scriptPath, fuscriptPath)
    local scriptDir = scriptPath:match("^(.*)[/\\][^/\\]+$") or "."
    local dataDir = utils.joinPath(scriptDir, ".data")
    local logPath = utils.joinPath(dataDir, "node_toggle.log")
    local binDir = utils.joinPath(scriptDir, ".bin")
    local platform = {
        scriptPath = scriptPath,
        binDir = binDir,
        dataDir = dataDir,
        launcherName = "node-toggle.vbs",
        statePath = utils.joinPath(dataDir, "node_toggle_state.json"),
        logPath = logPath,
        makeExecutable = function() end,
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
    -- Per-button variant with the args hard-coded (Stream Deck's Open action
    -- can't pass arguments on Windows - see the PLATFORM banner). Each arg
    -- lands in the command wrapped in its own quotes; literal quotes inside
    -- a VBS string are escaped by doubling.
    platform.buildBakedLauncherContent = function(argsList)
        local command = 'Chr(34) & "' .. fuscriptPath .. '" & Chr(34) & " " & Chr(34) & "' .. scriptPath .. '" & Chr(34)'
        for _, argument in ipairs(argsList) do
            command = command .. ' & " " & Chr(34) & "' .. argument:gsub('"', '""') .. '" & Chr(34)'
        end
        return table.concat({
            "' Generated by " .. SCRIPT_INFO.NAME .. " v" .. SCRIPT_INFO.VERSION
                .. " - runs: " .. table.concat(argsList, " ") .. " (no console window).",
            "' Do not edit; delete this file and re-copy from the Setup dialog to change it.",
            "Dim sdCmd",
            "sdCmd = " .. command,
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
-- STATE PERSISTENCE
-- The Resolve API cannot read a node's enabled state, so toggles are tracked
-- in a JSON file of stateKey -> boolean. Missing key = assumed enabled.
-- Toggling a node manually in Resolve's UI can drift the tracked state;
-- one extra button press resyncs it.
-- ============================================================================

local function readStates()
    -- Missing or corrupt file just means "no tracked state yet"
    local states = utils.readJSONFile(PLATFORM.statePath)
    if type(states) ~= "table" then return {} end
    return states
end

local function writeStates(states)
    return utils.writeJSONFile(PLATFORM.statePath, states)
end

-- ============================================================================
-- SELECTOR NORMALIZATION & CLI PARSING
-- Stream Deck's Open action tokenizes on spaces with unknown quoting rules,
-- so the CLI joins every argument after the position back into one selector.
-- Quotes (straight and macOS smart quotes) are stripped defensively.
-- ============================================================================

local QUOTE_CHARS = {
    '"', "'",
    "\226\128\156", "\226\128\157",  -- “ ” (UTF-8)
    "\226\128\152", "\226\128\153",  -- ‘ ’ (UTF-8)
}

local function stripQuotes(s)
    local changed = true
    while changed do
        changed = false
        for _, q in ipairs(QUOTE_CHARS) do
            if #s >= #q and s:sub(1, #q) == q then
                s = s:sub(#q + 1)
                changed = true
            end
            if #s >= #q and s:sub(-#q) == q then
                s = s:sub(1, #s - #q)
                changed = true
            end
        end
    end
    return s
end

local function normalizeWhitespace(s)
    local collapsed = s:gsub("%s+", " ")
    return collapsed:match("^%s*(.-)%s*$") or collapsed
end

local function normalizePosition(word)
    if type(word) ~= "string" then
        return nil, "No position specified."
    end
    local key = word:lower():gsub("[-_%s]", "")
    for _, position in ipairs(CONFIG.POSITIONS) do
        if key == position then
            return position, nil
        end
    end
    return nil, string.format(
        "Unknown position '%s'. Valid positions: all, clip, preclip, postclip, timeline.", word)
end

-- Parse a comma-separated position token into an ordered, deduped list.
-- 'all' expands to every position.
local function normalizePositions(word)
    if type(word) ~= "string" or word == "" then
        return nil, "No position specified."
    end
    local positions, seen = {}, {}
    local function add(position)
        if not seen[position] then
            seen[position] = true
            positions[#positions + 1] = position
        end
    end
    for part in word:gmatch("[^,]+") do
        if part:lower():gsub("[-_%s]", "") == "all" then
            for _, position in ipairs(CONFIG.POSITIONS) do
                add(position)
            end
        else
            local position, err = normalizePosition(part)
            if not position then
                return nil, err
            end
            add(position)
        end
    end
    if #positions == 0 then
        return nil, "No position specified."
    end
    return positions, nil
end

-- Parse a CLI argument list into {positions, selector, mode, index?}.
-- Selector rules: 'index:<n>' forces an index, 'name:<text>' forces a name
-- (the only way to target a node literally labelled "1"), a bare number is
-- an index, anything else is a name. Prefixes are stripped once only.
local function parseCliArgs(argv)
    local positions, posErr = normalizePositions(stripQuotes(argv[1] or ""))
    if not positions then
        return nil, posErr
    end

    local parts = {}
    for i = 2, #argv do
        parts[#parts + 1] = argv[i]
    end
    local selector = normalizeWhitespace(stripQuotes(table.concat(parts, " ")))
    if selector == "" then
        return nil, "No node specified. Usage: node-toggle <positions> <node name or index>"
    end

    local parsed = { positions = positions, selector = selector }
    local prefix, rest = selector:match("^(%a+):%s*(.*)$")
    prefix = prefix and prefix:lower() or nil

    if prefix == "index" then
        if not rest:match("^%d+$") or tonumber(rest) < 1 then
            return nil, "index: needs a whole number of 1 or higher, got: " .. rest
        end
        parsed.mode = "index"
        parsed.index = tonumber(rest)
        parsed.selector = rest
    elseif prefix == "name" then
        if rest == "" then
            return nil, "name: needs a node name after it."
        end
        parsed.mode = "name"
        parsed.selector = rest
    elseif selector:match("^%d+$") then
        parsed.mode = "index"
        parsed.index = tonumber(selector)
        if parsed.index < 1 then
            return nil, "Node index must be 1 or higher, got: " .. selector
        end
    else
        parsed.mode = "name"
    end
    return parsed, nil
end

-- ============================================================================
-- GRAPH RESOLUTION & TOGGLE CORE
-- Shared by CLI mode, the Setup UI node list, and the Test button.
-- ============================================================================

local function findColorGroupForClip(project, timeline, clipItem)
    local colorGroups = project:GetColorGroupsList()
    if not colorGroups or #colorGroups == 0 then
        return nil, "No color groups found in this project."
    end

    local clipStart = clipItem:GetStart()
    for _, group in ipairs(colorGroups) do
        local clipsInGroup = group:GetClipsInTimeline(timeline)
        if clipsInGroup then
            for _, clip in ipairs(clipsInGroup) do
                if clip:GetStart() == clipStart then
                    return group, nil
                end
            end
        end
    end

    return nil, "The selected clip is not assigned to any color group."
end

-- Stable identifier for per-clip state keys
local function clipScopeId(timeline, clipItem)
    local ok, uid = pcall(function() return clipItem:GetUniqueId() end)
    if ok and type(uid) == "string" and uid ~= "" then
        return uid
    end
    return timeline:GetName() .. "/" .. clipItem:GetName() .. "/" .. tostring(clipItem:GetStart())
end

-- Resolve a position word to its node graph.
-- Returns {graph, scopeId, clipItem}, nil on success / nil, error on failure.
-- clipItem may be nil for the timeline graph when no clip is selected.
local function resolveGraph(project, timeline, position)
    local currentItem = timeline:GetCurrentVideoItem()

    if position == "clip" then
        if not currentItem then
            return nil, "No clip is currently selected. Place the playhead on a clip."
        end
        local ok, graph = pcall(function() return currentItem:GetNodeGraph() end)
        if not ok or not graph then
            return nil, "Could not get the clip's node graph (requires Resolve 19+)."
        end
        return {
            graph = graph,
            scopeId = "clip=" .. clipScopeId(timeline, currentItem),
            clipItem = currentItem,
        }, nil
    end

    if position == "timeline" then
        local ok, graph = pcall(function() return timeline:GetNodeGraph() end)
        if not ok or not graph then
            return nil, "Could not get the timeline node graph (requires Resolve 19+)."
        end
        return {
            graph = graph,
            scopeId = "timeline=" .. timeline:GetName(),
            clipItem = currentItem,
        }, nil
    end

    -- preclip / postclip live on the color group of the selected clip
    if not currentItem then
        return nil, "No clip is currently selected. Place the playhead on a clip."
    end
    local group, err = findColorGroupForClip(project, timeline, currentItem)
    if not group then
        return nil, err
    end

    local graph
    if position == "preclip" then
        graph = group:GetPreClipNodeGraph()
    else
        graph = group:GetPostClipNodeGraph()
    end
    if not graph then
        return nil, string.format("Could not get the %s graph for color group '%s'.",
            position == "preclip" and "pre-clip" or "post-clip", group:GetName())
    end

    return {
        graph = graph,
        scopeId = "group=" .. group:GetName(),
        clipItem = currentItem,
    }, nil
end

local function findNodeIndex(graph, parsed)
    local numNodes = graph:GetNumNodes() or 0

    if parsed.mode == "index" then
        if parsed.index > numNodes then
            return nil, string.format("Node %d does not exist. This graph has %d node(s).",
                parsed.index, numNodes)
        end
        return parsed.index, nil
    end

    -- Name lookup: whitespace-normalized exact match, lowest index wins
    for i = 1, numNodes do
        local label = graph:GetNodeLabel(i)
        if label and normalizeWhitespace(label) == parsed.selector then
            return i, nil
        end
    end

    local labels = {}
    for i = 1, numNodes do
        local label = graph:GetNodeLabel(i) or ""
        labels[#labels + 1] = string.format("  %d: %s", i, label ~= "" and label or "(unlabelled)")
    end
    return nil, string.format(
        "No node labelled '%s' in this graph. Available nodes:\n%s",
        parsed.selector,
        #labels > 0 and table.concat(labels, "\n") or "  (none)")
end

-- Single-position keys keep the original "position|scopeId|tag" format so
-- state tracked by older commands survives; multi-position commands get one
-- combined key so all their targets flip together.
local function stateKey(positions, scopeIds, parsed)
    local lookupTag
    if parsed.mode == "name" then
        lookupTag = "name=" .. parsed.selector
    else
        lookupTag = "idx=" .. parsed.index
    end
    return table.concat(positions, ",") .. "|" .. table.concat(scopeIds, ",") .. "|" .. lookupTag
end

-- The Edit/Cut page viewer caches rendered output and doesn't pick up
-- scripted color changes; bouncing the clip-enabled flag forces a recompute.
-- The Color page has a live connection to the grade engine and needs nothing.
local function nudgeViewerRefresh(clipItem)
    clipItem:SetClipEnabled(false)
    clipItem:SetClipEnabled(true)
end

-- Toggle the target node in every requested position where it can be
-- found. Positions whose graph can't be resolved or that don't contain
-- the node are skipped (reported via the returned skipped list); the
-- toggle fails only when the node is found in no position at all.
-- Returns {newState, targets = {{position, nodeIndex, label}, ...},
-- skipped = {{position, reason}, ...}}, nil on success / nil, err on
-- failure.
local function toggleNode(resolve, project, timeline, parsed)
    local targets, scopeIds, foundPositions, skipped = {}, {}, {}, {}
    for _, position in ipairs(parsed.positions) do
        local target, err = resolveGraph(project, timeline, position)
        local nodeIndex, lookupErr
        if target then
            nodeIndex, lookupErr = findNodeIndex(target.graph, parsed)
        end
        if target and nodeIndex then
            target.position = position
            target.nodeIndex = nodeIndex
            targets[#targets + 1] = target
            scopeIds[#scopeIds + 1] = target.scopeId
            foundPositions[#foundPositions + 1] = position
        else
            skipped[#skipped + 1] = { position = position, reason = lookupErr or err }
        end
    end

    if #targets == 0 then
        if #skipped == 1 then
            return nil, skipped[1].reason
        end
        local lines = {}
        for _, s in ipairs(skipped) do
            lines[#lines + 1] = "[" .. s.position .. "] " .. s.reason
        end
        return nil, "Node not found in any requested position:\n" .. table.concat(lines, "\n")
    end

    -- Key on the positions actually toggled so a single-position command's
    -- state survives the node moving graphs (and matches pre-'all' keys)
    local key = stateKey(foundPositions, scopeIds, parsed)
    local states = readStates()
    local currentEnabled = states[key]
    if currentEnabled == nil then currentEnabled = true end  -- assume enabled on first use

    local newState = not currentEnabled
    for i, target in ipairs(targets) do
        if not target.graph:SetNodeEnabled(target.nodeIndex, newState) then
            -- Roll back the targets already flipped so the graphs stay in sync
            for j = 1, i - 1 do
                targets[j].graph:SetNodeEnabled(targets[j].nodeIndex, currentEnabled)
            end
            return nil, string.format("Failed to toggle node %d in the %s graph.",
                target.nodeIndex, target.position)
        end
    end

    states[key] = newState
    local written, writeErr = writeStates(states)
    if not written then
        utils.printWarning(writeErr)
    end

    local currentPage = resolve:GetCurrentPage()
    if (currentPage == "edit" or currentPage == "cut") and targets[1].clipItem then
        nudgeViewerRefresh(targets[1].clipItem)
    end

    local results = {}
    for _, target in ipairs(targets) do
        results[#results + 1] = {
            position = target.position,
            nodeIndex = target.nodeIndex,
            label = target.graph:GetNodeLabel(target.nodeIndex) or "",
        }
    end
    return { newState = newState, targets = results, skipped = skipped }, nil
end

-- One-line summary shared by CLI output and the Test button
local function formatToggleResult(result)
    local parts = {}
    for _, t in ipairs(result.targets) do
        parts[#parts + 1] = string.format("%s node %d (%s)",
            t.position, t.nodeIndex, t.label ~= "" and t.label or "unlabelled")
    end
    return table.concat(parts, ", ") .. ": " .. (result.newState and "ENABLED" or "DISABLED")
end

-- Console report of positions that were skipped (node absent / unresolvable)
local function reportSkipped(result)
    for _, s in ipairs(result.skipped) do
        print("Skipped " .. s.position .. ": " .. s.reason)
    end
end

-- ============================================================================
-- LAUNCHER MANAGEMENT
-- The Setup UI installs the launcher file(s) in the hidden .bin folder next
-- to this script. On macOS the copied command is the quoted launcher path
-- (the install path contains spaces) plus the args; on Windows it is just
-- the path of a per-button baked .vbs (see the PLATFORM banner). Stale
-- baked launchers are harmless tiny files - delete .bin and re-copy the
-- buttons you still use to clean up.
-- ============================================================================

-- The generic launcher entry point (.sh on macOS - the Stream Deck target
-- there; the arg-forwarding .vbs on Windows, for cmd/manual use - Stream
-- Deck buttons point at per-button baked .vbs files instead).
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

-- Space-free slug for baked launcher filenames
local function slugify(text)
    local slug = text:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if slug == "" then
        slug = "toggle"
    end
    return slug
end

-- Deterministic 4-hex-digit djb2 hash (no bit lib: values stay well under 2^53)
local function shortHash(text)
    local hash = 5381
    for i = 1, #text do
        hash = (hash * 33 + text:byte(i)) % 65536
    end
    return string.format("%04x", hash)
end

-- Filename for a baked per-button launcher. Distinct arg strings must never
-- share a filename (a collision would silently repoint an existing button),
-- so whenever slugification is lossy (case folded, punctuation collapsed)
-- the exact args are disambiguated with a short hash suffix.
local function bakedLauncherName(argsText)
    local slug = slugify(argsText)
    if argsText:gsub("%s+", "-") == slug then
        return "node-toggle-" .. slug .. ".vbs"
    end
    return "node-toggle-" .. slug .. "-" .. shortHash(argsText) .. ".vbs"
end

-- Write (or refresh) the baked .vbs for these args; returns its path - the
-- file a Windows Stream Deck "System: Open" action should point at.
local function ensureBakedLauncher(argsList)
    local path = utils.joinPath(PLATFORM.binDir, bakedLauncherName(table.concat(argsList, " ")))
    utils.createDirectory(PLATFORM.binDir)
    local _, err = writeFileIfChanged(path, PLATFORM.buildBakedLauncherContent(argsList))
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
  node-toggle.sh <positions> <node name or index>

Positions ('all' or a comma-separated list to target several graphs):
  all        Every graph below
  clip       Node graph of the selected clip
  preclip    Pre-clip graph of the clip's color group
  postclip   Post-clip graph of the clip's color group
  timeline   Timeline node graph

Examples:
  node-toggle.sh postclip DCTL 1
  node-toggle.sh all DCTL 1
  node-toggle.sh clip 3
  node-toggle.sh timeline Film Look
  node-toggle.sh clip,preclip node one
  node-toggle.sh clip name:2

The node is toggled in every requested graph where it is found; positions
where it doesn't exist are skipped. The toggle fails only if the node is
found nowhere.

Node names don't need quotes - everything after the position is the name.
A purely numeric value targets the node by index instead; use 'name:2' to
target a node literally labelled "2", or 'index:2' to force an index.

Run this script from Resolve (Workspace > Scripts) to open the setup window,
which installs the launcher and builds these commands for you.]]

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
    local parsed, parseErr = parseCliArgs(argv)
    if not parsed then
        cliFail(parseErr)
        printUsage()
        return
    end

    -- Timestamp delimits each invocation in the persistent log file, so a failed
    -- toggle can be correlated with the button press that caused it.
    print(string.format("[%s] Node Toggle", os.date("%Y-%m-%d %H:%M:%S")))
    print("Position(s): " .. table.concat(parsed.positions, ", "))
    print("Node: " .. parsed.selector .. " (" .. parsed.mode .. " lookup)")

    -- pcall: with Resolve closed the Resolve() global may not exist at all.
    -- On failure, initialize returns nil plus an error string in the second
    -- slot, so project holds the error message when resolve is nil.
    local initOk, resolve, project = pcall(utils.initialize, false, SCRIPT_INFO)
    if not initOk or not resolve then
        local message = "Could not connect to DaVinci Resolve. Make sure it is running."
        if initOk and type(project) == "string" then
            message = project
        end
        cliFail(message)
        return
    end

    local timeline = project:GetCurrentTimeline()
    if not timeline then
        cliFail("No timeline is currently open.")
        return
    end

    local result, err = toggleNode(resolve, project, timeline, parsed)
    if not result then
        cliFail(err)
        return
    end

    reportSkipped(result)
    utils.printSuccess(formatToggleResult(result))
end

-- CLI log, written from Lua rather than by shell redirection: cmd opens
-- redirect targets exclusively, so a shell-held log makes overlapping
-- Stream Deck presses die on a sharing violation before fuscript starts.
-- Lua's CRT append is share-mode - concurrent runs interleave instead of
-- colliding. Size-capped; if the log can't be opened, logging is skipped
-- entirely (it must never block the toggle).
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
-- The node name must be typed by hand: the Resolve API (checked against the
-- Resolve 20 scripting README) exposes neither the currently selected node
-- nor node colors (only TimelineItem.ResetAllNodeColors exists), so "use the
-- selected node" and "toggle all red nodes" are not possible.
-- ============================================================================

local function runSetupUI(ctx)
    local ui = ctx.ui
    local dispatcher = ctx.dispatcher

    local launcherStatus = ensureLauncher()
    print(launcherStatus.message)

    local dialog = dispatcher:AddWindow({
        ID = "NodeToggleDialog",
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
                        Text = "Location:",
                        Font = ui:Font{ PixelSize = 12 },
                        MinimumSize = {110, 20},
                    },
                    ui:ComboBox{
                        ID = "LocationCombo",
                        MinimumSize = {220, 33},
                    },
                },

                ui:VGap(3),

                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Text = "Selector:",
                        Font = ui:Font{ PixelSize = 12 },
                        MinimumSize = {110, 20},
                    },
                    ui:ComboBox{
                        ID = "ModeCombo",
                        MinimumSize = {220, 33},
                    },
                },

                ui:VGap(3),

                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        ID = "SelectorLabel",
                        Text = "Name:",
                        Font = ui:Font{ PixelSize = 12 },
                        MinimumSize = {110, 20},
                    },
                    ui:LineEdit{
                        ID = "SelectorField",
                        PlaceholderText = "Node name",
                        MinimumSize = {220, 38},
                        Font = ui:Font{ PixelSize = 12 },
                        StyleSheet = STYLES.INPUT,
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

    local locationCombo = dialog:Find("LocationCombo")
    local modeCombo = dialog:Find("ModeCombo")
    local selectorLabel = dialog:Find("SelectorLabel")
    local selectorField = dialog:Find("SelectorField")

    local locationLabels = {}
    for _, location in ipairs(CONFIG.LOCATIONS) do
        locationLabels[#locationLabels + 1] = location.label
    end
    locationCombo:AddItems(locationLabels)
    locationCombo.CurrentIndex = 0

    local LOOKUP_MODES = { "name", "index" }
    modeCombo:AddItems({ "Node Name", "Node Index" })
    modeCombo.CurrentIndex = 0

    local function selectedMode()
        return LOOKUP_MODES[modeCombo.CurrentIndex + 1] or "name"
    end

    local function selectedLocation()
        local location = CONFIG.LOCATIONS[locationCombo.CurrentIndex + 1]
        return location and location.value or "all"
    end

    -- Build the selector exactly as it will appear in the command. The CLI
    -- still parses text (Stream Deck commands are plain strings), so names
    -- it would misread as an index or prefix get an explicit name: prefix.
    local function buildSelector()
        local text = normalizeWhitespace(stripQuotes(selectorField.Text or ""))
        if text == "" then
            return nil, "Type a node " .. selectedMode() .. " first."
        end
        if selectedMode() == "index" then
            if not text:match("^%d+$") or tonumber(text) < 1 then
                return nil, "Index must be a whole number of 1 or higher."
            end
            return text, nil
        end
        if text:match("^%d+$") or text:lower():match("^name:") or text:lower():match("^index:") then
            return "name:" .. text, nil
        end
        return text, nil
    end

    local function buildCommand()
        local selector, err = buildSelector()
        if not selector then
            return nil, err
        end
        -- Windows: Stream Deck's Open action can't pass arguments, so the
        -- "command" is just the path of a .vbs with the args baked in,
        -- quoted - the Open field splits an unquoted path on spaces.
        if PLATFORM.buildBakedLauncherContent then
            if not launcherStatus.ok then
                return nil, launcherStatus.message
            end
            local bakedPath, bakedErr = ensureBakedLauncher({ selectedLocation(), selector })
            if not bakedPath then
                return nil, bakedErr
            end
            return '"' .. bakedPath .. '"', nil
        end
        -- The install path contains spaces, so the launcher path is quoted to
        -- keep Stream Deck's Open action from splitting it into arguments
        return '"' .. launcherStatus.path .. '" ' .. selectedLocation() .. " " .. selector, nil
    end

    function dialog.On.ModeCombo.CurrentIndexChanged(ev)
        if selectedMode() == "index" then
            selectorLabel.Text = "Index:"
            selectorField.PlaceholderText = "Node index (1, 2, ...)"
        else
            selectorLabel.Text = "Name:"
            selectorField.PlaceholderText = "Node name"
        end
    end

    function dialog.On.CopyButton.Clicked(ev)
        local command, err = buildCommand()
        if not command then
            utils.printError(err)
            return
        end
        local copied, copyErr = utils.copyToClipboard(command)
        if copied then
            print("Copied to clipboard: " .. command)
            if PLATFORM.buildBakedLauncherContent then
                print("In Stream Deck add a System > Open action and paste this file path.")
            else
                print("In Stream Deck add a System > Open action and paste this command.")
            end
        else
            utils.printError("Copy failed: " .. tostring(copyErr))
        end
    end

    -- Runs via runWithDialogBusy: the dialog greys out and drops clicks
    -- while the Resolve API work runs
    local function doTest()
        local selector, selErr = buildSelector()
        if not selector then
            utils.printError(selErr)
            return
        end

        -- Round-trip through the CLI parser so the test exercises exactly
        -- what the copied command will do
        local parsed, parseErr = parseCliArgs({ selectedLocation(), selector })
        if not parsed then
            utils.printError(parseErr)
            return
        end

        local timeline = ctx.project:GetCurrentTimeline()
        if not timeline then
            utils.printError("No timeline is currently open.")
            return
        end

        local result, err = toggleNode(ctx.resolve, ctx.project, timeline, parsed)
        if not result then
            utils.printError(err)
            return
        end

        reportSkipped(result)
        utils.printSuccess(formatToggleResult(result))
    end

    function dialog.On.TestButton.Clicked(ev)
        utils.runWithDialogBusy(dialog, doTest)
    end

    function dialog.On.NodeToggleDialog.Close(ev)
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
    -- process dies right after the toggle. Gated on the env marker that
    -- only the generated launchers set - it must never fire inside
    -- Resolve's script host, where os.exit would kill the host.
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
