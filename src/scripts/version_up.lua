local SCRIPT_INFO = {
    NAME = "Version Up",
    VERSION = "1.1.0",
    MIN_RESOLVE = "20.0",
}

-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[

    Version Up

    Duplicates selected timelines with an incremented version number and
    files the originals into a "Versions" bin.

    Features:
        - Preserves the existing version format: _V1, -v1, (v1), [V1],
          _version1, and zero-padded variants (V01 -> V02, V001 -> V002)
        - Preserves the token's position in the name (suffix or middle)
        - Bumps the RIGHTMOST version token when a name contains several
          (e.g. "Client_V1 Masters_V3 copy" -> "Client_V1 Masters_V4 copy")
        - Adds _V02 at the end when no version is found
        - Warns when the bumped name is already taken and offers the next
          available version (collision-free runs stay silent)
        - Files originals into a "Versions" bin

    Usage:
        1. Select one or more timelines in the Media Pool
        2. Run this script (or trigger via keyboard shortcut)
        3. New versions remain in the current location; originals move to
           the "Versions" bin

--]]

local utils = require("ResolveKit")

-- ============================================================================
-- VERSION PATTERN DEFINITIONS
-- ============================================================================

-- Define all supported version patterns with their properties
-- Every pattern is scanned across the whole name and the rightmost match
-- wins, so list order does not encode priority (see detectVersionInfo)
local VERSION_PATTERNS = {
    -- Versions at the beginning (prefix position)
    {pattern = "^[Vv](%d+) ", prefix = "V", suffix = " ", position = "prefix"},
    {pattern = "^[Vv](%d+)_", prefix = "V", suffix = "_", position = "prefix"},
    {pattern = "^[Vv](%d+)%-", prefix = "V", suffix = "-", position = "prefix"},
    {pattern = "^version(%d+) ", prefix = "version", suffix = " ", position = "prefix", preserveCase = false},
    {pattern = "^Version(%d+) ", prefix = "Version", suffix = " ", position = "prefix", preserveCase = false},

    -- Underscore with V/v (most common)
    {pattern = "_[Vv](%d+)$", prefix = "_V", position = "suffix"},
    {pattern = "_[Vv](%d+)_", prefix = "_V", position = "middle"},
    {pattern = "_[Vv](%d+) ", prefix = "_V", position = "middle"},

    -- Dash with V/v
    {pattern = "%-[Vv](%d+)$", prefix = "-V", position = "suffix"},
    {pattern = "%-[Vv](%d+)%-", prefix = "-V", position = "middle"},
    {pattern = "%-[Vv](%d+) ", prefix = "-V", position = "middle"},

    -- Underscore with "version" word
    {pattern = "_version(%d+)$", prefix = "_version", position = "suffix", preserveCase = false},
    {pattern = "_Version(%d+)$", prefix = "_Version", position = "suffix", preserveCase = false},
    {pattern = "_VERSION(%d+)$", prefix = "_VERSION", position = "suffix", preserveCase = false},
    {pattern = "_version(%d+)_", prefix = "_version", position = "middle", preserveCase = false},
    {pattern = "_Version(%d+)_", prefix = "_Version", position = "middle", preserveCase = false},
    {pattern = "_version(%d+) ", prefix = "_version", position = "middle", preserveCase = false},
    {pattern = "_Version(%d+) ", prefix = "_Version", position = "middle", preserveCase = false},

    -- Parentheses versions
    {pattern = "%(v(%d+)%)$", prefix = "(v", suffix = ")", position = "suffix"},
    {pattern = "%(V(%d+)%)$", prefix = "(V", suffix = ")", position = "suffix"},
    {pattern = "%(version(%d+)%)$", prefix = "(version", suffix = ")", position = "suffix"},
    {pattern = "%(Version(%d+)%)$", prefix = "(Version", suffix = ")", position = "suffix"},

    -- Square brackets
    {pattern = "%[v(%d+)%]$", prefix = "[v", suffix = "]", position = "suffix"},
    {pattern = "%[V(%d+)%]$", prefix = "[V", suffix = "]", position = "suffix"},
    {pattern = "%[version(%d+)%]$", prefix = "[version", suffix = "]", position = "suffix"},
    {pattern = "%[Version(%d+)%]$", prefix = "[Version", suffix = "]", position = "suffix"},

    -- Curly braces
    {pattern = "{v(%d+)}$", prefix = "{v", suffix = "}", position = "suffix"},
    {pattern = "{V(%d+)}$", prefix = "{V", suffix = "}", position = "suffix"},

    -- Space separated (less common, but supported)
    {pattern = " [Vv](%d+)$", prefix = " V", position = "suffix"},
    {pattern = " version(%d+)$", prefix = " version", position = "suffix", preserveCase = false},
    {pattern = " Version(%d+)$", prefix = " Version", position = "suffix", preserveCase = false},

    -- Dot notation
    {pattern = "%.[Vv](%d+)$", prefix = ".V", position = "suffix"},
    {pattern = "%.version(%d+)$", prefix = ".version", position = "suffix", preserveCase = false},

    -- Direct version at end (without separator)
    {pattern = "[Vv](%d+)$", prefix = "V", position = "suffix", needsWordBoundary = true},
    {pattern = "version(%d+)$", prefix = "version", position = "suffix", needsWordBoundary = true},
}

-- ============================================================================
-- VERSION DETECTION AND MANIPULATION
-- ============================================================================

-- Detect version information from timeline name.
-- Every pattern is scanned across the whole name and the RIGHTMOST version
-- token wins (e.g. "Client_V1 Masters_V3 copy" bumps V3, not V1) - people
-- read the last marker as the live version. Of candidates ending at the same
-- position, the longest match is kept so "_V2" beats the bare "V2" inside it.
local function detectVersionInfo(timelineName)
    local best = nil

    for _, vp in ipairs(VERSION_PATTERNS) do
        local anchored = vp.pattern:sub(1, 1) == "^"
        local searchStart = 1

        while true do
            local startPos, endPos, version = timelineName:find(vp.pattern, searchStart)
            if not startPos then
                break
            end

            -- Word boundary check: allows TimelineV1 but not Timeline1v1
            local valid = true
            if vp.needsWordBoundary and startPos > 1 then
                local charBefore = timelineName:sub(startPos - 1, startPos - 1)
                -- If the character before is a digit, skip this match
                if charBefore:match("%d") then
                    valid = false
                end
                -- For "version" word patterns, ensure word boundary
                if vp.prefix:lower():match("version") and charBefore:match("%w") then
                    valid = false
                end
            end

            if valid and (not best
                or endPos > best.endPos
                or (endPos == best.endPos and startPos < best.startPos)) then
                best = {vp = vp, version = version, startPos = startPos, endPos = endPos}
            end

            -- '^' patterns can only ever match at the start of the name
            if anchored then
                break
            end
            searchStart = startPos + 1
        end
    end

    if not best then
        return nil -- No version found
    end

    local vp = best.vp
    local version = best.version

    -- Detect original case if needed
    local originalPrefix = vp.prefix
    if vp.preserveCase ~= false and vp.pattern:match("%[Vv%]") then
        -- For patterns with [Vv], check which case the name actually used
        local prefixLen = #vp.prefix - 1  -- -1 because prefix includes the V
        local vChar = timelineName:sub(best.startPos + prefixLen, best.startPos + prefixLen)
        if vChar == "v" then
            originalPrefix = originalPrefix:gsub("V", "v")
        elseif vChar == "V" then
            originalPrefix = originalPrefix:gsub("v", "V")
        end
    end

    -- Middle patterns match one trailing separator (_, - or space) that must
    -- survive the replacement; suffix/prefix matches are replaced whole
    local replaceEnd = best.endPos
    if vp.position == "middle" then
        replaceEnd = replaceEnd - 1
    end

    return {
        number = tonumber(version),
        digits = #version,  -- Preserve padding
        pattern = vp,
        prefix = originalPrefix,
        suffix = vp.suffix or "",
        position = vp.position,
        replaceStart = best.startPos,
        replaceEnd = replaceEnd
    }
end

-- Replace the detected version span with the new version number.
-- Positional, so other version-looking tokens in the name stay untouched
local function replaceVersion(timelineName, versionInfo, newVersionNum)
    -- Format new version with preserved padding
    local paddedVersion = string.format("%0" .. versionInfo.digits .. "d", newVersionNum)
    local newVersionString = versionInfo.prefix .. paddedVersion .. versionInfo.suffix

    return timelineName:sub(1, versionInfo.replaceStart - 1)
        .. newVersionString
        .. timelineName:sub(versionInfo.replaceEnd + 1)
end

-- Format a candidate name for an absolute version number. Generalizes the
-- no-token fallback so probing continues _V02, _V03, ... (the unversioned
-- original is treated as version 1)
local function buildVersionName(oldName, versionInfo, versionNum)
    if versionInfo then
        return replaceVersion(oldName, versionInfo, versionNum)
    end
    return oldName .. string.format("_V%02d", versionNum)
end

-- How many version numbers to probe before giving up
local MAX_VERSION_PROBES = 1000

-- Find the smallest free version strictly above the bumped one
-- Returns: {name, number}, nil (or nil, error)
local function findNextAvailableName(oldName, versionInfo, bumpedVersion, takenNames)
    for candidate = bumpedVersion + 1, bumpedVersion + MAX_VERSION_PROBES do
        local name = buildVersionName(oldName, versionInfo, candidate)
        if not takenNames[name] then
            return { name = name, number = candidate }, nil
        end
    end
    return nil, string.format("No free version number within %d tries", MAX_VERSION_PROBES)
end

-- ============================================================================
-- COLLISION WARNING DIALOG
-- ============================================================================

-- Warn that bumped name(s) already exist in the project. Returns true to
-- redirect every colliding timeline to its next available version, false to
-- cancel the whole batch (closing the window also cancels).
-- Copy stays deliberately minimal (name stated once, informal V token);
-- per-collision detail goes to the console instead.
local function showCollisionDialog(ui, dispatcher, collisions)
    local lines
    if #collisions == 1 then
        lines = {
            string.format("%s already exists.", collisions[1].takenName),
            "",
            string.format("Next available version: V%d", collisions[1].nextVersion),
        }
    else
        lines = {
            string.format("%d version names already exist.", #collisions),
            "",
            "Each will use its next available version.",
        }
    end

    return utils.showStatusDialog(ui, dispatcher, {
        icon = 'warning',
        title = 'Version Already Exists',
        message = table.concat(lines, "\n"),
        closeValue = false,
        buttons = {
            { id = 'CancelBtn', text = 'Cancel', value = false, style = 'secondary' },
            { id = 'UseNextBtn', text = 'Use Next Available Version', value = true, style = 'primary' },
        },
    })
end

-- ============================================================================
-- MAIN SCRIPT
-- ============================================================================

local function main()
    utils.printHeader(SCRIPT_INFO.NAME .. " v" .. SCRIPT_INFO.VERSION)

    -- Initialize with UI so selection errors can surface as a dialog
    -- (the main operation itself stays headless)
    local ctx, err = utils.initializeWithUI(SCRIPT_INFO)
    if not ctx then
        utils.printError(err or "Could not initialize Resolve")
        return
    end
    local project, mediaPool = ctx.project, ctx.mediaPool

    utils.printSuccess("Connected to Resolve")

    -- Get selected timelines (shows an error dialog when nothing is selected)
    local selectedTimelines = utils.requireSelectedTimelines(project, mediaPool, ctx.ui, ctx.dispatcher)
    if not selectedTimelines then
        return
    end

    print(string.format("\nFound %d timeline(s) selected", #selectedTimelines))

    -- Phase 1: pre-compute all operations (no API calls)
    local operations = {}
    for i, item in ipairs(selectedTimelines) do
        local versionInfo = detectVersionInfo(item.name)
        local bumpedVersion = versionInfo and (versionInfo.number + 1) or 2

        table.insert(operations, {
            index = i,
            timeline = item.timeline,
            originalClip = item.clipItem,
            oldName = item.name,
            newName = buildVersionName(item.name, versionInfo, bumpedVersion),
            bumpedVersion = bumpedVersion,
            versionInfo = versionInfo
        })
    end

    -- Collision gate: Resolve refuses to create a timeline under a name that
    -- already exists, so DuplicateTimeline would fail with no visible error.
    -- Best-effort pre-flight; Phase 2's duplicate-failed path stays as the
    -- backstop for races and other failures.
    local takenNames, namesErr = utils.getTimelineNameSet(project)
    if not takenNames then
        utils.printError(namesErr or "Could not read timeline names")
        return
    end

    local collisions = {}
    for _, op in ipairs(operations) do
        if takenNames[op.newName] then
            local nextInfo, probeErr = findNextAvailableName(
                op.oldName, op.versionInfo, op.bumpedVersion, takenNames)
            if not nextInfo then
                utils.printError(probeErr .. " for " .. op.oldName)
                utils.showErrorDialog(ctx.ui, ctx.dispatcher, probeErr, SCRIPT_INFO.NAME)
                return
            end
            op.takenName = op.newName
            op.nextName = nextInfo.name
            op.nextVersion = nextInfo.number
            table.insert(collisions, op)
        end
        -- Claim both names so within-batch duplicates collide and probe past
        takenNames[op.newName] = true
        if op.nextName then
            takenNames[op.nextName] = true
        end
    end

    if #collisions > 0 then
        utils.printWarning(string.format("%d name conflict(s) detected, asking user", #collisions))
        for _, op in ipairs(collisions) do
            utils.printStatus("WARN", string.format("%s already exists, next available is %s",
                op.takenName, op.nextName))
        end
        if not showCollisionDialog(ctx.ui, ctx.dispatcher, collisions) then
            utils.printWarning("Cancelled by user - no timelines were processed")
            return
        end
        for _, op in ipairs(collisions) do
            op.newName = op.nextName
        end
    end

    -- Get or create Versions bin (after the gate, so a cancel creates nothing)
    local versionsBin, binErr = utils.getBin(mediaPool, "Versions")
    if not versionsBin then
        utils.printError(binErr or "Could not access Versions bin")
        return
    end

    utils.printSuccess("Versions bin ready")

    -- Phase 2: execute operations (duplicate then move, for each timeline)
    utils.printSection("PROCESSING TIMELINES")
    local successCount = 0
    local failCount = 0
    local redirectCount = 0

    for i, op in ipairs(operations) do
        print(string.format("\n[%d/%d] Processing: %s", i, #operations, op.oldName))

        -- Log the detected format
        if op.versionInfo then
            print(string.format("  Detected format: %s%d%s (padding: %d digit%s)",
                op.versionInfo.prefix,
                op.versionInfo.number,
                op.versionInfo.suffix,
                op.versionInfo.digits,
                op.versionInfo.digits > 1 and "s" or ""))
        else
            print("  No version detected, will add _V02")
        end

        print(string.format("  New version: %s", op.newName))

        -- Duplicate the timeline
        if not op.timeline then
            utils.printError("  Timeline object not found in project, cannot duplicate")
            failCount = failCount + 1
            goto continue
        end

        local duplicatedTimeline = op.timeline:DuplicateTimeline(op.newName)
        if not duplicatedTimeline then
            utils.printError("  Failed to duplicate timeline")
            failCount = failCount + 1
            goto continue
        end

        utils.printStatus("OK", "Timeline duplicated")
        if op.takenName then
            redirectCount = redirectCount + 1
        end

        -- Move the original timeline to Versions bin immediately
        if op.originalClip and mediaPool then
            local moved = mediaPool:MoveClips({op.originalClip}, versionsBin)
            if moved then
                utils.printStatus("OK", "Original moved to Versions bin")
                successCount = successCount + 1
            else
                utils.printWarning("  Could not move original to Versions bin")
                failCount = failCount + 1
            end
        else
            utils.printWarning("  Could not find original clip item to move")
            failCount = failCount + 1
        end

        ::continue::
    end

    -- Print summary
    utils.printHeader("Summary")
    print(string.format("Successfully processed: %d", successCount))
    if redirectCount > 0 then
        print(string.format("Used next available version: %d", redirectCount))
    end
    if failCount > 0 then
        print(string.format("Failed: %d", failCount))
    end

    utils.printSuccess("Done!")
end

-- Run the script
main()
