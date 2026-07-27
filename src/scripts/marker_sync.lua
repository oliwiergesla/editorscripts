local SCRIPT_INFO = {
    NAME = "Marker Sync",
    VERSION = "1.0.0",
    MIN_RESOLVE = "20.0",
}

-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[

    Marker Sync

    Synchronize markers between timelines with advanced options for conflict resolution
    and frame rate conversion.

    Features:
        - Copy all markers from a single source timeline
        - Paste or overwrite markers to multiple destination timelines
        - Handle frame rate differences between timelines
        - Resolve marker conflicts at the same frame position

    Usage:
        1. Run the script to open the persistent Marker Sync window
        2. Select a single timeline in the Media Pool
        3. Click "Copy Markers" to copy all markers from that timeline
        4. Select one or more destination timelines
        5. Choose conflict resolution and frame rate conversion options
        6. Click "Paste Markers" to add or "Overwrite Markers" to replace

--]]

local utils = require("ResolveKit")
local STYLES, COLORS = utils.STYLES, utils.COLORS

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

local CONFIG = {
    -- Dialog window dimensions
    DIALOG_WIDTH = 420,
    DIALOG_FALLBACK_HEIGHT = 330,  -- only used if fitDialogHeight fails

    -- Conflict resolution modes
    CONFLICT_MODES = {
        "Skip existing markers",
        "Overwrite existing"
    },

    -- Frame rate conversion modes
    FRAME_CONVERSION = {
        "Preserve time position",
        "Keep frame numbers"
    }
}


-- ============================================================================
-- MODULE-LEVEL STORAGE
-- ============================================================================

-- Store copied markers between operations
local copiedMarkers = nil
local sourceFrameRate = nil
local sourceTimelineStart = nil

-- Session statistics
local sessionStats = {
    copiesPerformed = 0,
    timelinesProcessed = 0,
    markersAdded = 0,
    markersSkipped = 0,
    markersOverwritten = 0,
    markersDeleted = 0
}

-- ============================================================================
-- FRAME RATE CONVERSION
-- ============================================================================

-- Convert frame number between different frame rates
local function convertFrame(sourceFrame, sourceFPS, destFPS, conversionMode, sourceStart, destStart)
    -- If frame rates are the same, just adjust for timeline start difference
    if sourceFPS == destFPS then
        -- Convert from source timeline space to destination timeline space
        local absoluteFrame = sourceFrame - sourceStart
        return destStart + absoluteFrame
    end

    if conversionMode == "TIME" then
        -- Convert by preserving time position
        -- First convert to absolute frame (from timeline start)
        local relativeFrame = sourceFrame - sourceStart
        -- Convert to time in seconds
        local timeInSeconds = relativeFrame / sourceFPS
        -- Convert back to destination frame rate
        local destRelativeFrame = math.floor(timeInSeconds * destFPS + 0.5)
        -- Add destination timeline start
        return destStart + destRelativeFrame
    else
        -- Keep same frame numbers (relative to timeline start)
        local relativeFrame = sourceFrame - sourceStart
        return destStart + relativeFrame
    end
end

-- ============================================================================
-- MARKER OPERATIONS
-- ============================================================================

-- Delete all markers from a timeline in one call
local function deleteAllMarkers(timeline)
    timeline:DeleteMarkersByColor("All")
end

-- Process markers for a single timeline
local function processTimelineMarkers(timeline, sourceMarkers, overwriteMode, conflictMode, frameConversion,
                                     srcFrameRate, srcStart)
    local destFrameRate = timeline:GetSetting("timelineFrameRate")
    local destStart = timeline:GetStartFrame()

    local stats = {
        added = 0,
        skipped = 0,
        overwritten = 0,
        deleted = 0,
        errors = 0
    }

    -- Clear existing markers if overwrite mode
    if overwriteMode then
        local existingMarkers = timeline:GetMarkers()
        stats.deleted = utils.countMarkers(existingMarkers)
        deleteAllMarkers(timeline)
    end

    -- Get existing markers for conflict checking
    local existingMarkers = {}
    if not overwriteMode then
        existingMarkers = timeline:GetMarkers() or {}
    end

    -- Process each source marker
    for sourceFrame, markerData in pairs(sourceMarkers) do
        -- Convert frame number
        local destFrame = convertFrame(sourceFrame, srcFrameRate, destFrameRate,
                                      frameConversion, srcStart, destStart)

        -- Check for conflict
        local hasConflict = existingMarkers[destFrame] ~= nil

        if hasConflict and not overwriteMode then
            if conflictMode == "SKIP" then
                stats.skipped = stats.skipped + 1
                goto continue
            elseif conflictMode == "OVERWRITE" then
                -- Delete existing marker first
                timeline:DeleteMarkerAtFrame(destFrame)
                stats.overwritten = stats.overwritten + 1
            end
        end

        -- Add the marker. AddMarker rejects by RETURNING false (occupied
        -- frame, empty name), not by erroring - check both
        local okCall, added = pcall(function()
            return timeline:AddMarker(
                destFrame,
                markerData.color or "Red",
                markerData.name or "",
                markerData.note or "",
                markerData.duration or 1,
                markerData.customData or ""
            )
        end)

        if okCall and added then
            stats.added = stats.added + 1
        else
            stats.errors = stats.errors + 1
        end

        ::continue::
    end

    return stats
end

-- ============================================================================
-- COPY MARKERS FUNCTION
-- ============================================================================

local function copyMarkersFromSelection(project, mediaPool, ui, dispatcher)
    -- Refresh selection
    local selected = utils.requireSelectedTimelines(project, mediaPool, ui, dispatcher,
        "No timeline selected.\nSelect a single timeline to copy markers from.")
    if not selected then
        return nil, 0
    end

    -- Validate single selection
    if #selected > 1 then
        utils.printError("Error: Select only ONE timeline to copy from")
        return nil, #selected
    end

    local timeline = selected[1].timeline
    local timelineName = selected[1].name

    -- Get markers from timeline
    local markers = timeline:GetMarkers()

    -- Check if timeline has markers
    if not markers or next(markers) == nil then
        utils.printError("Error: Timeline has no markers")
        return nil, #selected
    end

    local markerCount = utils.countMarkers(markers)

    -- Store in module variables
    copiedMarkers = markers
    sourceFrameRate = timeline:GetSetting("timelineFrameRate")
    sourceTimelineStart = timeline:GetStartFrame()

    -- Update session stats
    sessionStats.copiesPerformed = sessionStats.copiesPerformed + 1

    -- Console output
    utils.printSuccess(string.format("Copied %d markers from: %s", markerCount, timelineName))

    return selected, #selected
end

-- ============================================================================
-- PASTE/OVERWRITE MARKERS FUNCTION
-- ============================================================================

local function pasteMarkersToSelection(project, mediaPool, ui, dispatcher, overwriteMode,
                                      conflictSetting, frameConversionSetting)
    -- Check if markers have been copied
    if not copiedMarkers then
        utils.printError("Error: No markers copied. Copy markers first.")
        utils.showErrorDialog(ui, dispatcher,
            "No markers copied.\nCopy markers from a timeline first.",
            "No Markers Copied")
        return nil, 0
    end

    -- Refresh selection
    local selected = utils.requireSelectedTimelines(project, mediaPool, ui, dispatcher,
        "No timelines selected.\nSelect one or more timelines to paste markers to.")
    if not selected then
        return nil, 0
    end

    -- Determine conflict mode from setting (compare against first option in array)
    local conflictMode = conflictSetting == CONFIG.CONFLICT_MODES[1] and "SKIP" or "OVERWRITE"
    local frameConversion = frameConversionSetting == CONFIG.FRAME_CONVERSION[1] and "TIME" or "FRAME"

    local totalStats = {
        added = 0,
        skipped = 0,
        overwritten = 0,
        deleted = 0,
        errors = 0
    }

    -- Create progress window for batch operation
    local progress = utils.createProgressWindow(ui, dispatcher, {
        title = overwriteMode and "Overwriting Markers" or "Pasting Markers",
        totalItems = #selected
    })

    if progress then
        progress.show()

        for i, item in ipairs(selected) do
            local timeline = item.timeline
            local timelineName = item.name

            -- Update progress before processing
            progress.update(i, timelineName, string.format('[%d/%d] %s', i, #selected, timelineName))

            -- No UI switching needed - AddMarker, GetMarkers, and DeleteMarkerAtFrame
            -- all work directly on timeline objects without setCurrentTimeline

            -- Process the timeline
            local stats = processTimelineMarkers(
                timeline, copiedMarkers, overwriteMode, conflictMode, frameConversion,
                sourceFrameRate, sourceTimelineStart
            )

            -- Accumulate stats
            totalStats.added = totalStats.added + stats.added
            totalStats.skipped = totalStats.skipped + stats.skipped
            totalStats.overwritten = totalStats.overwritten + stats.overwritten
            totalStats.deleted = totalStats.deleted + stats.deleted
            totalStats.errors = totalStats.errors + stats.errors

            -- Update progress with result
            local resultMsg = utils.statusLine("OK", string.format('Added: %d | Skipped: %d | Errors: %d',
                                          stats.added, stats.skipped, stats.errors))
            progress.update(i, timelineName, resultMsg)
        end

        -- Final update
        local completeMsg = string.format('Complete: Added: %d | Skipped: %d | Errors: %d',
                                        totalStats.added, totalStats.skipped, totalStats.errors)
        progress.update(#selected, 'Complete!', completeMsg, true)
        utils.sleep(2)
        progress.hide()
    end

    -- Update session stats
    sessionStats.timelinesProcessed = sessionStats.timelinesProcessed + #selected
    sessionStats.markersAdded = sessionStats.markersAdded + totalStats.added
    sessionStats.markersSkipped = sessionStats.markersSkipped + totalStats.skipped
    sessionStats.markersOverwritten = sessionStats.markersOverwritten + totalStats.overwritten
    sessionStats.markersDeleted = sessionStats.markersDeleted + totalStats.deleted

    -- Console output
    local operation = overwriteMode and "Overwrote" or "Pasted"
    utils.printSuccess(string.format("%s markers to %d timeline(s)", operation, #selected))
    if overwriteMode then
        print(string.format("  Deleted: %d | Added: %d | Errors: %d",
                           totalStats.deleted, totalStats.added, totalStats.errors))
    else
        print(string.format("  Added: %d | Skipped: %d | Overwritten: %d | Errors: %d",
                           totalStats.added, totalStats.skipped, totalStats.overwritten, totalStats.errors))
    end

    return selected, #selected
end

-- ============================================================================
-- BUILD UI DIALOG
-- ============================================================================

local function buildMarkerSyncDialog(ui, dispatcher)
    -- Create dialog window (don't use Geometry for auto-centering)
    local dialog = dispatcher:AddWindow({
        ID = "MarkerSyncDialog",
        WindowTitle = SCRIPT_INFO.NAME,
        WindowFlags = utils.getDialogFlags(),
        StyleSheet = STYLES.WINDOW,
    }, ui:VGroup{
        ID = 'DialogContent',
        MinimumSize = {CONFIG.DIALOG_WIDTH, 0},
        MaximumSize = {CONFIG.DIALOG_WIDTH, 16777215},  -- width pinned, height auto (fitDialogHeight)
        Spacing = 0,

        ui:HGroup{
            ID = 'MainContent',
            Weight = 0,
            Spacing = 0,
            ui:HGap(28),  -- Left padding

            ui:VGroup{
                ID = 'root',

                ui:VGap(28),

                -- On Conflict dropdown
                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Text = "On Conflict:",
                        Font = ui:Font{PixelSize = 12},
                        MinimumSize = {110, 20},
                    },
                    ui:ComboBox{
                        ID = "ConflictCombo",
                        MinimumSize = {220, 33},
                    },
                },

                ui:VGap(3),

                -- Frame Rate Conversion dropdown
                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Text = "Frame Rate\nConversion:",
                        Font = ui:Font{PixelSize = 12},
                        MinimumSize = {110, 20},
                    },
                    ui:ComboBox{
                        ID = "FrameRateCombo",
                        MinimumSize = {220, 33},
                    },
                },

                ui:VGap(28),

                -- Copy Markers button (full width)
                ui:Button{
                    ID = "CopyButton",
                    Text = "Copy Markers",
                    MinimumSize = {330, 45},
                    Font = ui:Font{ PixelSize = 12 },
                    StyleSheet = STYLES.BUTTON_PRIMARY,
                },

                ui:VGap(3),

                -- Paste and Overwrite buttons (side by side)
                ui:HGroup{
                    Weight = 0,
                    ui:Button{
                        ID = "PasteButton",
                        Text = "Paste Markers",
                        MinimumSize = {160, 45},
                        Font = ui:Font{ PixelSize = 12 },
                        StyleSheet = STYLES.BUTTON_SECONDARY,
                    },
                    ui:HGap(3),
                    ui:Button{
                        ID = "OverwriteButton",
                        Text = "Overwrite Markers",
                        MinimumSize = {160, 45},
                        Font = ui:Font{ PixelSize = 12 },
                        StyleSheet = STYLES.BUTTON_SECONDARY,
                    },
                },

                ui:VGap(28),
            },  -- closes root VGroup

            ui:HGap(28),  -- Right padding
        },  -- closes MainContent HGroup

        ui:VGap(0, 1),  -- stretch absorbs surplus height, pins footer to bottom

        -- Footer
        utils.createFooter(ui, {
            scriptName = SCRIPT_INFO.NAME,
            version = SCRIPT_INFO.VERSION,
        }),
    })  -- closes DialogContent VGroup

    utils.applyDialogPlatformAttributes(dialog)

    -- Auto-size height to content; set before Show so auto-centering still works
    if not utils.fitDialogHeight(dialog, CONFIG.DIALOG_WIDTH) then
        dialog:Resize({CONFIG.DIALOG_WIDTH, CONFIG.DIALOG_FALLBACK_HEIGHT})
    end

    -- Get UI elements
    local conflictCombo = dialog:Find("ConflictCombo")
    local frameRateCombo = dialog:Find("FrameRateCombo")

    -- Populate combo boxes
    conflictCombo:AddItems(CONFIG.CONFLICT_MODES)
    conflictCombo.CurrentIndex = 0  -- Default to first option

    frameRateCombo:AddItems(CONFIG.FRAME_CONVERSION)
    frameRateCombo.CurrentIndex = 0  -- Default to first option

    utils.attachFooterHandler(dialog)

    -- Return dialog and getter functions for current settings
    return {
        dialog = dialog,
        getConflictSetting = function()
            return CONFIG.CONFLICT_MODES[conflictCombo.CurrentIndex + 1]
        end,
        getFrameRateSetting = function()
            return CONFIG.FRAME_CONVERSION[frameRateCombo.CurrentIndex + 1]
        end
    }
end

-- ============================================================================
-- MAIN SCRIPT
-- ============================================================================

print("\n")
utils.printHeader(SCRIPT_INFO.NAME .. " v" .. SCRIPT_INFO.VERSION)

-- Initialize Resolve with UI
local ctx, err = utils.initializeWithUI(SCRIPT_INFO)
if not ctx then
    utils.printError(err)
    utils.printSeparator("=", 70)
    print()
    return
end

local project = ctx.project
local mediaPool = ctx.mediaPool
local ui = ctx.ui
local dispatcher = ctx.dispatcher

utils.printSuccess("Connected to DaVinci Resolve")
utils.printSuccess("Project: " .. project:GetName())

-- Create dialog
local dialogResult = buildMarkerSyncDialog(ui, dispatcher)
local dialog = dialogResult.dialog

-- Operation bodies (run via runWithDialogBusy so the dialog greys out and
-- drops clicks while the Resolve API work runs)
local function doCopy()
    print()
    utils.printSeparator("-", 50)
    print("COPY MARKERS")

    -- Check selection directly in handler (dialogs only work from here)
    local selected = utils.requireSelectedTimelines(project, mediaPool, ui, dispatcher,
        "No timeline selected.\nSelect a single timeline to copy markers from.")
    if not selected then
        return
    end

    copyMarkersFromSelection(project, mediaPool, ui, dispatcher)
end

local function doPaste()
    print()
    utils.printSeparator("-", 50)
    print("PASTE MARKERS")

    -- Check if markers have been copied first (dialogs only work from handler)
    if not copiedMarkers then
        utils.printError("Error: No markers copied. Copy markers first.")
        utils.showErrorDialog(ui, dispatcher,
            "No markers copied.\nCopy markers from a timeline first.",
            "No Markers Copied")
        return
    end

    -- Check selection directly in handler
    local selected = utils.requireSelectedTimelines(project, mediaPool, ui, dispatcher,
        "No timelines selected.\nSelect one or more timelines to paste markers to.")
    if not selected then
        return
    end

    local conflictSetting = dialogResult.getConflictSetting()
    local frameRateSetting = dialogResult.getFrameRateSetting()
    pasteMarkersToSelection(project, mediaPool, ui, dispatcher, false,
                           conflictSetting, frameRateSetting)
end

local function doOverwrite()
    print()
    utils.printSeparator("-", 50)
    print("OVERWRITE MARKERS")

    -- Check if markers have been copied first
    if not copiedMarkers then
        utils.printError("Error: No markers copied. Copy markers first.")
        utils.showErrorDialog(ui, dispatcher,
            "No markers copied.\nCopy markers from a timeline first.",
            "No Markers Copied")
        return
    end

    local conflictSetting = dialogResult.getConflictSetting()
    local frameRateSetting = dialogResult.getFrameRateSetting()
    pasteMarkersToSelection(project, mediaPool, ui, dispatcher, true,
                           conflictSetting, frameRateSetting)
end

-- Event handlers
function dialog.On.CopyButton.Clicked()
    utils.runWithDialogBusy(dialog, doCopy)
end

function dialog.On.PasteButton.Clicked()
    utils.runWithDialogBusy(dialog, doPaste)
end

function dialog.On.OverwriteButton.Clicked()
    utils.runWithDialogBusy(dialog, doOverwrite)
end

function dialog.On.MarkerSyncDialog.Close()
    dispatcher:ExitLoop()
end

-- Show dialog and run event loop
dialog:RecalcLayout()
utils.centerDialogOnScreen(dialog, ui, dispatcher)
dialog:Show()
dispatcher:RunLoop()
dialog:Hide()

-- Final Summary
if sessionStats.copiesPerformed > 0 or sessionStats.timelinesProcessed > 0 then
    print("\n")
    utils.printHeader("Session Summary")
    print(string.format("Copy operations:        %d", sessionStats.copiesPerformed))
    print(string.format("Timelines processed:    %d", sessionStats.timelinesProcessed))
    print(string.format("Markers added:          %d", sessionStats.markersAdded))
    print(string.format("Markers skipped:        %d", sessionStats.markersSkipped))
    print(string.format("Markers overwritten:    %d", sessionStats.markersOverwritten))
end

print("\n")
utils.printSeparator("=", 70)
print("Script completed.")
utils.printSeparator("=", 70)
print()