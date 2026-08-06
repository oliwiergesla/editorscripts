local SCRIPT_INFO = {
    NAME = "Auto In Out",
    VERSION = "1.0.4",
    MIN_RESOLVE = "20.0",
}

-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[

    Auto In Out

    Manage timeline In/Out points with options to clear or auto-set based on
    last enabled clips.

    Features:
        - Clear In/Out points on selected timelines
        - Auto-set In/Out points based on the last enabled clip
        - Choose which clip type drives the Out point: video, audio, or any

    Usage:
        1. Run this script
        2. Select one or more timelines in the Media Pool
        3. Choose operation: clear, or set by video, audio, or any clip type

--]]

local utils = require("ResolveKit")
local STYLES, COLORS = utils.STYLES, utils.COLORS

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

local CONFIG = {
    -- Dialog window dimensions
    DIALOG_WIDTH = 420,
    DIALOG_FALLBACK_HEIGHT = 280,  -- only used if fitDialogHeight fails

    -- Operation modes
    MODES = {
        CLEAR = 1,
        AUTO_VIDEO = 2,
        AUTO_AUDIO = 3,
        AUTO_ANY = 4
    }
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

-- ============================================================================
-- CLIP DETECTION
-- ============================================================================

-- Get the last frame of the last ENABLED clip (audio or video)
local function getLastEnabledClipFrame(timeline)
    if not timeline then
        return nil, 0, nil
    end

    local videoLastFrame, videoCount = utils.getLastEnabledFrame(timeline, "video")
    local audioLastFrame, audioCount = utils.getLastEnabledFrame(timeline, "audio")

    local totalCount = videoCount + audioCount

    -- Return whichever is later (or the only one that exists)
    if not videoLastFrame and not audioLastFrame then
        return nil, 0, nil
    elseif not videoLastFrame then
        return audioLastFrame, totalCount, "audio"
    elseif not audioLastFrame then
        return videoLastFrame, totalCount, "video"
    else
        -- Both exist, return the later one
        if videoLastFrame >= audioLastFrame then
            return videoLastFrame, totalCount, "video"
        else
            return audioLastFrame, totalCount, "audio"
        end
    end
end

-- ============================================================================
-- TIMELINE OPERATIONS
-- ============================================================================

-- Clear In/Out marks on timeline
local function clearTimelineInOut(project, timeline)
    if not project or not timeline then
        return false, "Invalid project or timeline"
    end

    -- ClearMarkInOut may work without switching the current timeline;
    -- fall back to switching only if it fails
    local success = timeline:ClearMarkInOut("all")

    if not success then
        -- Fallback: Try setting as current timeline first
        local setSuccess, err = utils.setCurrentTimeline(project, timeline)
        if not setSuccess then
            return false, err
        end

        success = timeline:ClearMarkInOut("all")
        if not success then
            return false, "Could not clear timeline In/Out marks"
        end
    end

    return true, nil
end

-- Set In/Out marks on timeline (with cached timeline start)
local function setTimelineInOut(project, timeline, inFrame, outFrame, timelineStart)
    if not project or not timeline then
        return false, "Invalid project or timeline"
    end

    -- Use cached timeline start if provided, otherwise fetch it
    timelineStart = timelineStart or timeline:GetStartFrame()

    -- Convert to timeline-relative frames
    local relativeIn = inFrame - timelineStart
    local relativeOut = outFrame - timelineStart

    -- Try relative frames first
    local success = timeline:SetMarkInOut(relativeIn, relativeOut, "all")

    if not success then
        -- Fallback: Try absolute frames
        success = timeline:SetMarkInOut(inFrame, outFrame, "all")
    end

    if not success then
        -- Final fallback: Set as current timeline and try again
        local setSuccess, err = utils.setCurrentTimeline(project, timeline)
        if setSuccess then
            success = timeline:SetMarkInOut(relativeIn, relativeOut, "all") or
                     timeline:SetMarkInOut(inFrame, outFrame, "all")
        end
    end

    if not success then
        return false, "Could not set timeline In/Out marks"
    end

    return true, nil
end

-- ============================================================================
-- DIALOG BUILDER
-- ============================================================================

local function buildSelectionDialog(ui, dispatcher)
    -- Create dialog window (don't use Geometry for auto-centering)
    local dialog = dispatcher:AddWindow({
        ID = "InOutUtilityDialog",
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

                -- Set Based on Last Enabled Clip (full width, primary)
                ui:Button{
                    ID = 'AnyButton',
                    Text = "Set Based on Last Enabled Clip",
                    MinimumSize = {330, 45},
                    Font = ui:Font{ PixelSize = 12 },
                    StyleSheet = STYLES.BUTTON_PRIMARY
                },

                ui:VGap(3),

                -- Video and Audio buttons (side by side)
                ui:HGroup{
                    Weight = 0,
                    ui:Button{
                        ID = 'VideoButton',
                        Text = "Set Based on Video",
                        MinimumSize = {160, 45},
                        Font = ui:Font{ PixelSize = 12 },
                        StyleSheet = STYLES.BUTTON_SECONDARY
                    },
                    ui:HGap(3),
                    ui:Button{
                        ID = 'AudioButton',
                        Text = "Set Based on Audio",
                        MinimumSize = {160, 45},
                        Font = ui:Font{ PixelSize = 12 },
                        StyleSheet = STYLES.BUTTON_SECONDARY
                    },
                },

                ui:VGap(3),

                -- Clear All button (reset style)
                ui:Button{
                    ID = 'ClearButton',
                    Text = "Clear All In/Out Points",
                    MinimumSize = {330, 45},
                    Font = ui:Font{ PixelSize = 12 },
                    StyleSheet = STYLES.BUTTON_TERTIARY
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
    })

    utils.applyDialogPlatformAttributes(dialog)

    -- Auto-size height to content; set before Show so auto-centering still works
    if not utils.fitDialogHeight(dialog, CONFIG.DIALOG_WIDTH) then
        dialog:Resize({CONFIG.DIALOG_WIDTH, CONFIG.DIALOG_FALLBACK_HEIGHT})
    end

    utils.attachFooterHandler(dialog)

    return dialog
end

-- ============================================================================
-- UNIFIED PROCESSING FUNCTION
-- ============================================================================

local function processTimelines(selectedTimelines, project, ui, dispatcher, mode)
    -- Determine operation details based on mode
    local operation = {
        [CONFIG.MODES.CLEAR] = {
            title = "Clearing Timeline In/Out Points",
            sectionTitle = "CLEARING IN/OUT MARKS",
            trackType = nil,
            isClear = true
        },
        [CONFIG.MODES.AUTO_VIDEO] = {
            title = "Setting In/Out Points (Based on Video)",
            sectionTitle = "SETTING IN/OUT MARKS (VIDEO)",
            trackType = "video",
            isClear = false
        },
        [CONFIG.MODES.AUTO_AUDIO] = {
            title = "Setting In/Out Points (Based on Audio)",
            sectionTitle = "SETTING IN/OUT MARKS (AUDIO)",
            trackType = "audio",
            isClear = false
        },
        [CONFIG.MODES.AUTO_ANY] = {
            title = "Setting In/Out Points (Based on Last Enabled Clip)",
            sectionTitle = "SETTING IN/OUT MARKS (ANY CLIP)",
            trackType = "any",
            isClear = false
        }
    }

    local opInfo = operation[mode]
    if not opInfo then
        return 0, 0, 0
    end

    -- Create progress window
    local progress = utils.createProgressWindow(ui, dispatcher, {
        title = opInfo.title,
        totalItems = #selectedTimelines
    })

    if progress then
        progress.show()
        progress.update(0, "Starting...", "Starting batch processing...")
    end

    local successCount = 0
    local failedCount = 0
    local skippedCount = 0

    -- Process each timeline
    for i, timelineInfo in ipairs(selectedTimelines) do
        local timeline = timelineInfo.timeline
        local timelineName = timelineInfo.name

        if progress then
            progress.update(i, timelineName,
                string.format('[%d/%d] %s', i, #selectedTimelines, timelineName))
        end

        print(string.format('\n[%d/%d] %s', i, #selectedTimelines, timelineName))

        if not timeline then
            utils.printError("Could not find timeline object")
            if progress then
                progress.update(i, timelineName, utils.statusLine("ERROR", "Could not find timeline object"))
            end
            failedCount = failedCount + 1
            goto continue
        end

        local success, err

        if opInfo.isClear then
            -- Clear operation
            success, err = clearTimelineInOut(project, timeline)

            if success then
                utils.printSuccess("In/Out marks cleared")
                if progress then
                    progress.update(i, timelineName, utils.statusLine("OK", "Marks cleared"))
                end
                successCount = successCount + 1
            else
                utils.printError(err or "Unknown error")
                if progress then
                    progress.update(i, timelineName, utils.statusLine("ERROR", err or 'Unknown error'))
                end
                failedCount = failedCount + 1
            end
        else
            -- Auto-set operation
            local lastFrame, enabledCount, clipType

            -- Cache timeline start frame for this timeline
            local timelineStart = timeline:GetStartFrame()

            if opInfo.trackType == "any" then
                lastFrame, enabledCount, clipType = getLastEnabledClipFrame(timeline)
            else
                lastFrame, enabledCount = utils.getLastEnabledFrame(timeline, opInfo.trackType)
                clipType = opInfo.trackType
            end

            if not lastFrame then
                if enabledCount == 0 then
                    local clipTypeText = opInfo.trackType == "any" and "" or (opInfo.trackType .. " ")
                    utils.printWarning(string.format("No enabled %sclips found", clipTypeText))
                    print(string.format("  Action: Skipping (no %scontent to set Out point)", clipTypeText))
                    if progress then
                        progress.update(i, timelineName,
                            utils.statusLine("SKIP", string.format('No enabled %sclips', clipTypeText)))
                    end
                    skippedCount = skippedCount + 1
                else
                    utils.printError("Could not determine last enabled frame")
                    if progress then
                        progress.update(i, timelineName, utils.statusLine("ERROR", "Could not determine last frame"))
                    end
                    failedCount = failedCount + 1
                end
                goto continue
            end

            if opInfo.trackType == "any" then
                print(string.format("  Enabled clips: %d (last: %s)", enabledCount, clipType))
            else
                print(string.format("  Enabled %s clips: %d", clipType, enabledCount))
            end
            print(string.format("  Last enabled frame: %d", lastFrame))

            -- Set In/Out points using cached timeline start
            local inFrame = timelineStart
            local outFrame = lastFrame

            success, err = setTimelineInOut(project, timeline, inFrame, outFrame, timelineStart)

            if success then
                local duration = outFrame - inFrame + 1
                utils.printSuccess("In/Out marks set")
                print(string.format("    Duration: %d frames", duration))

                local progressMsg
                if opInfo.trackType == "any" then
                    progressMsg = utils.statusLine("OK", string.format('Duration %d frames (%s)', duration, clipType))
                else
                    progressMsg = utils.statusLine("OK", string.format('Duration %d frames', duration))
                end

                if progress then
                    progress.update(i, timelineName, progressMsg)
                end
                successCount = successCount + 1
            else
                utils.printError(err or "Unknown error")
                if progress then
                    progress.update(i, timelineName, utils.statusLine("ERROR", err or 'Unknown error'))
                end
                failedCount = failedCount + 1
            end
        end

        ::continue::
    end

    if progress then
        local completeMsg
        if opInfo.isClear then
            completeMsg = string.format('Complete: %d succeeded, %d failed',
                successCount, failedCount)
        else
            completeMsg = string.format('Complete: %d succeeded, %d skipped, %d failed',
                successCount, skippedCount, failedCount)
        end

        progress.update(#selectedTimelines, 'Complete!', completeMsg, true)
        utils.sleep(1)
        progress.hide()
    end

    return successCount, skippedCount, failedCount
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

local operationNames = {
    [CONFIG.MODES.CLEAR] = "Clear In/Out Points",
    [CONFIG.MODES.AUTO_VIDEO] = "Set Based on Video",
    [CONFIG.MODES.AUTO_AUDIO] = "Set Based on Audio",
    [CONFIG.MODES.AUTO_ANY] = "Set Based on Last Enabled Clip"
}

-- Build dialog once; it stays open while operations run (progress window opens on top)
local dialog = buildSelectionDialog(ui, dispatcher)

-- Run one operation from a button handler; the main dialog stays visible
local function runOperation(selectedMode)
    local operationName = operationNames[selectedMode]

    print()
    utils.printSection(string.upper(operationName))

    -- Check selection directly in handler (dialogs only work from here)
    local selectedTimelines = utils.requireSelectedTimelines(project, mediaPool, ui, dispatcher)
    if not selectedTimelines then
        return
    end

    utils.printSuccess("Found " .. #selectedTimelines .. " selected timeline(s)")

    -- Process timelines
    print(string.format("\nProcessing %d timeline(s)...", #selectedTimelines))

    local successCount, skippedCount, failedCount = processTimelines(
        selectedTimelines, project, ui, dispatcher, selectedMode
    )

    -- Summary
    print("\n")
    utils.printHeader("Summary")
    print("Operation:              " .. operationName)
    print("Successfully processed: " .. successCount .. " timeline(s)")
    if skippedCount > 0 then
        print("Skipped (no content):   " .. skippedCount .. " timeline(s)")
    end
    print("Failed:                 " .. failedCount .. " timeline(s)")

    if successCount > 0 then
        print()
        if selectedMode == CONFIG.MODES.CLEAR then
            utils.printSuccess("Timeline In/Out marks have been cleared.")
        elseif selectedMode == CONFIG.MODES.AUTO_ANY then
            utils.printSuccess("Timeline In/Out marks set based on last enabled clips (audio or video).")
        else
            local clipType = selectedMode == CONFIG.MODES.AUTO_AUDIO and "audio" or "video"
            utils.printSuccess(string.format("Timeline In/Out marks set based on last enabled %s clips.", clipType))
        end
    end

    if skippedCount > 0 then
        if selectedMode == CONFIG.MODES.AUTO_ANY then
            utils.printWarning("Some timelines had no enabled clips.")
        else
            local clipType = selectedMode == CONFIG.MODES.AUTO_AUDIO and "audio" or "video"
            utils.printWarning(string.format("Some timelines had no enabled %s clips.", clipType))
        end
    end

    if failedCount > 0 then
        utils.printWarning("Some timelines encountered errors.")
    end
end

-- Event handlers (processing runs here so the dialog stays open;
-- runWithDialogBusy greys the dialog and drops clicks while it runs)
function dialog.On.AnyButton.Clicked()
    utils.runWithDialogBusy(dialog, runOperation, CONFIG.MODES.AUTO_ANY)
end

function dialog.On.VideoButton.Clicked()
    utils.runWithDialogBusy(dialog, runOperation, CONFIG.MODES.AUTO_VIDEO)
end

function dialog.On.AudioButton.Clicked()
    utils.runWithDialogBusy(dialog, runOperation, CONFIG.MODES.AUTO_AUDIO)
end

function dialog.On.ClearButton.Clicked()
    utils.runWithDialogBusy(dialog, runOperation, CONFIG.MODES.CLEAR)
end

function dialog.On.InOutUtilityDialog.Close()
    dispatcher:ExitLoop()
end

-- Show dialog and run event loop
dialog:RecalcLayout()
utils.centerDialogOnScreen(dialog, ui, dispatcher)
dialog:Show()
dispatcher:RunLoop()
dialog:Hide()

print("\n")
utils.printSeparator("=", 70)
print("Script completed.")
utils.printSeparator("=", 70)
print()