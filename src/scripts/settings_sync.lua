local SCRIPT_INFO = {
    NAME = "Settings Sync",
    VERSION = "1.0.3",
    MIN_RESOLVE = "20.0",
}

-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[

    Settings Sync

    Copy timeline settings from a source timeline and apply them to multiple
    target timelines to standardize resolution, color management, and more.

    Features:
        - Copy ALL settings from the selected timeline in one click
        - Choose what to apply afterwards: All Properties, Color, or Resolution
        - Source card shows the copied timeline's resolution, fps & color space
        - Handles useCustomSettings flag correctly in both directions
        - Filters out frame rate keys (cannot be changed via scripting API)
        - Reports per-timeline success, warnings, and failures

    Usage:
        1. Run the script to open the Settings Sync window
        2. Select the source timeline in the Media Pool and click "Copy Selected"
        3. Pick what to sync: All Properties, Color, or Resolution
        4. Select one or more target timelines in the Media Pool
        5. Click "Apply to Selected" to apply the copied settings

--]]

local utils = require("ResolveKit")
local STYLES, COLORS = utils.STYLES, utils.COLORS

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

local CONFIG = {
    DIALOG_WIDTH = 420,
    DIALOG_FALLBACK_HEIGHT = 480,  -- only used if fitDialogHeight fails
}

-- ============================================================================
-- MODULE-LEVEL STORAGE
-- ============================================================================

local copiedSettings = nil
local sourceTimelineName = nil
local sourceMeta = nil
local sourceSeparateColorSpace = false
local syncMode = "all" -- "all", "color", or "resolution"

-- Output color keys that cannot be written when "separate color space and gamma" is active
local OUTPUT_COLOR_KEYS = {
    colorSpaceOutput = true,
    colorSpaceOutputGamma = true,
}

-- Key sets for the selective sync modes
local COLOR_KEYS = {
    "separateColorSpaceAndGamma",
    "colorScienceMode",
    "colorSpaceTimeline",
    "colorSpaceTimelineGamma",
    "colorSpaceOutput",
    "colorSpaceOutputGamma",
}

local RESOLUTION_KEYS = {
    "timelineResolutionWidth",
    "timelineResolutionHeight",
}

local SYNC_CAPTIONS = {
    all        = "Copies resolution, color management & all timeline settings.",
    color      = "Copies color science, timeline & output color space settings.",
    resolution = "Copies timeline resolution (width & height) only.",
}

-- ============================================================================
-- SETTINGS OPERATIONS
-- ============================================================================

-- Check if a setting key is a frame rate key that should be excluded
local function isFrameRateKey(key)
    return string.find(key, "FrameRate") ~= nil
end

-- Readable names for colorScienceMode values
local COLOR_SCIENCE_LABELS = {
    davinciYRGB               = "DaVinci YRGB",
    davinciYRGBColorManaged   = "DaVinci YRGB Color Managed",
    davinciYRGBColorManagedv2 = "DaVinci YRGB Color Managed",
    aces                      = "ACES",
    acescc                    = "ACEScc",
    acescct                   = "ACEScct",
}

-- Build the "1920x1080 . DaVinci YRGB . Rec.709 Scene" metadata line for the
-- source card from the full settings table. Frame rate is deliberately absent
-- (it's outside the sync scope - timelines with content can't change it).
-- Timeline/output color space only show under DaVinci YRGB: in color-managed
-- and ACES modes Resolve manages the working space itself and the
-- colorSpaceTimeline setting is a stale leftover.
local function buildSourceMeta(allSettings)
    local parts = {}

    local w = allSettings["timelineResolutionWidth"]
    local h = allSettings["timelineResolutionHeight"]
    if w and h and tostring(w) ~= "" and tostring(h) ~= "" then
        table.insert(parts, tostring(w) .. "×" .. tostring(h))
    end

    local science = tostring(allSettings["colorScienceMode"] or "")
    if science ~= "" then
        table.insert(parts, COLOR_SCIENCE_LABELS[science] or science)
    end

    if science == "davinciYRGB" then
        local timelineSpace = tostring(allSettings["colorSpaceTimeline"] or "")
        if timelineSpace ~= "" then
            table.insert(parts, timelineSpace)
        end
        local outputSpace = tostring(allSettings["colorSpaceOutput"] or "")
        if outputSpace ~= "" and outputSpace ~= timelineSpace then
            table.insert(parts, outputSpace)
        end
    end

    return table.concat(parts, " · ")
end

-- Copy ALL settings from the selected timeline (mode filtering happens at
-- apply time, driven by the What to Sync selection)
local function copySelectedTimelineSettings(project, mediaPool, ui, dispatcher)
    local selected = utils.requireSelectedTimelines(project, mediaPool, ui, dispatcher,
        "No timeline selected.\nSelect a single timeline to copy settings from.")
    if not selected then return nil end

    if #selected > 1 then
        utils.printError("Select only ONE timeline to copy from.")
        utils.showErrorDialog(ui, dispatcher,
            "Select only one timeline to copy settings from.",
            "Too Many Selected")
        return nil
    end

    local timeline = selected[1].timeline
    local timelineName = selected[1].name

    -- Get all settings as key-value table
    local allSettings = timeline:GetSetting()
    if not allSettings then
        utils.printError("Failed to read settings from timeline: " .. timelineName)
        utils.showErrorDialog(ui, dispatcher,
            "Failed to read settings from the selected timeline.",
            "Copy Failed")
        return nil
    end

    -- Add hidden useCustomSettings key
    local useCustom = timeline:GetSetting("useCustomSettings")
    if useCustom then
        allSettings["useCustomSettings"] = useCustom
    end

    -- Copy everything, filtering frame rate keys (cannot be set via the API)
    local settings = {}
    local settingCount = 0
    local filteredCount = 0
    for key, value in pairs(allSettings) do
        if isFrameRateKey(key) then
            filteredCount = filteredCount + 1
        else
            settings[key] = value
            settingCount = settingCount + 1
        end
    end

    -- Store in module state
    copiedSettings = settings
    sourceTimelineName = timelineName
    sourceMeta = buildSourceMeta(allSettings)
    sourceSeparateColorSpace = (allSettings["separateColorSpaceAndGamma"] == "1")

    utils.printSuccess(string.format("Copied %d settings from: %s",
        settingCount, timelineName))
    if sourceMeta ~= "" then
        print("  " .. sourceMeta)
    end
    if filteredCount > 0 then
        utils.printSuccess(string.format("(filtered %d frame rate keys)", filteredCount))
    end

    -- Warn about output color space limitation (relevant for All/Color sync)
    if sourceSeparateColorSpace then
        utils.printWarning("Source uses separate color space and gamma - output color space/gamma cannot be copied (Resolve API limitation)")
        utils.showWarningDialog(ui, dispatcher,
            "The source timeline uses separate color space and gamma.\n\n"
            .. "Due to a Resolve API limitation, output color space and output gamma "
            .. "cannot be applied when syncing All Properties or Color.\n\n"
            .. "Timeline color space and gamma will copy correctly.\n"
            .. "All other settings will copy correctly.",
            "API Limitation")
    end

    return settings
end

-- Build the key-value set to write, filtered by the current sync mode
local function buildApplySet()
    if syncMode == "all" then
        return copiedSettings
    end
    local keys = (syncMode == "color") and COLOR_KEYS or RESOLUTION_KEYS
    local set = {}
    for _, key in ipairs(keys) do
        if copiedSettings[key] ~= nil then
            set[key] = copiedSettings[key]
        end
    end
    return set
end

-- Apply the copied settings (filtered by sync mode) to all selected target timelines
local function applySettingsToTimelines(project, mediaPool, ui, dispatcher)
    if not copiedSettings then
        utils.printError("No settings copied.")
        utils.showErrorDialog(ui, dispatcher,
            "No settings have been copied yet.\nCopy a timeline first.",
            "No Settings Copied")
        return nil
    end

    local selected = utils.requireSelectedTimelines(project, mediaPool, ui, dispatcher,
        "No timelines selected.\nSelect one or more timelines to apply settings to.")
    if not selected then return nil end

    local applySet = buildApplySet()

    -- Default to "1" (custom) if useCustomSettings wasn't captured during copy.
    -- Inherit-from-project only makes sense when syncing everything; for the
    -- selective modes we always write explicit values onto the targets.
    local sourceUseCustom = copiedSettings["useCustomSettings"] or "1"
    local inheritProject = (syncMode == "all" and sourceUseCustom == "0")

    -- Track results per timeline
    local results = {}
    local totalWarnings = 0
    local allFailedKeys = {}

    -- Create progress window
    local progress = utils.createProgressWindow(ui, dispatcher, {
        title = "Applying Timeline Settings",
        totalItems = #selected
    })

    if progress then
        progress.show()
    end

    for i, timelineInfo in ipairs(selected) do
        local timeline = timelineInfo.timeline
        local timelineName = timelineInfo.name

        if progress then
            progress.update(i, timelineName, string.format('[%d/%d] Applying settings...', i, #selected))
        end
        utils.printSection(string.format("[%d/%d] %s", i, #selected, timelineName))

        local failedKeys = {}
        local appliedCount = 0
        local skippedCount = 0

        if inheritProject then
            -- Source uses project settings - just disable custom settings on target
            local targetUseCustom = timeline:GetSetting("useCustomSettings")
            if targetUseCustom ~= "0" then
                local ok = timeline:SetSetting("useCustomSettings", "0")
                if not ok then
                    table.insert(failedKeys, "useCustomSettings")
                else
                    appliedCount = 1
                    utils.printSuccess("Set to inherit project settings")
                end
            else
                utils.printSuccess("Already inherits project settings")
            end
        else
            -- Write explicit values - enable custom settings first
            local targetUseCustom = timeline:GetSetting("useCustomSettings")
            if targetUseCustom ~= "1" then
                local ok = timeline:SetSetting("useCustomSettings", "1")
                if not ok then
                    table.insert(failedKeys, "useCustomSettings")
                    -- Can't proceed - all SetSetting calls will fail while useCustomSettings is "0"
                    utils.printError("Failed to enable custom settings - skipping this timeline")
                    results[i] = { name = timelineName, applied = 0, failed = failedKeys, skipped = true }
                    totalWarnings = totalWarnings + 1
                    goto continue
                end
            end

            -- Apply separateColorSpaceAndGamma first so dependent color keys
            -- are written in the correct mode
            local separateKey = "separateColorSpaceAndGamma"
            if applySet[separateKey] then
                local ok = timeline:SetSetting(separateKey, applySet[separateKey])
                if ok then
                    appliedCount = appliedCount + 1
                else
                    table.insert(failedKeys, separateKey)
                end
            end

            -- Apply remaining settings (except keys already handled above)
            for key, value in pairs(applySet) do
                if key ~= "useCustomSettings" and key ~= separateKey then
                    -- Skip output color keys when separate color space mode is active
                    -- (Resolve API refuses writes to these in that mode)
                    if sourceSeparateColorSpace and OUTPUT_COLOR_KEYS[key] then
                        skippedCount = skippedCount + 1
                        utils.printWarning(string.format("  Skipped %s (API limitation)", key))
                    else
                        local ok = timeline:SetSetting(key, value)
                        if ok then
                            appliedCount = appliedCount + 1
                        else
                            table.insert(failedKeys, key)
                        end
                    end
                end
            end

            local statusParts = { string.format("Applied %d settings", appliedCount) }
            if skippedCount > 0 then
                table.insert(statusParts, string.format("%d skipped", skippedCount))
            end
            if #failedKeys > 0 then
                table.insert(statusParts, string.format("%d failed (%s)", #failedKeys, table.concat(failedKeys, ", ")))
                utils.printWarning(table.concat(statusParts, ", "))
            else
                utils.printSuccess(table.concat(statusParts, ", "))
            end
        end

        results[i] = { name = timelineName, applied = appliedCount, failed = failedKeys }

        if #failedKeys > 0 then
            totalWarnings = totalWarnings + 1
            for _, key in ipairs(failedKeys) do
                allFailedKeys[key] = (allFailedKeys[key] or 0) + 1
            end
        end

        ::continue::
    end

    -- Complete progress
    if progress then
        local completeMsg = string.format("Complete! %d timeline(s) processed", #selected)
        progress.update(#selected, "Complete!", completeMsg, true)
        utils.sleep(2)
        progress.hide()
    end

    -- Print summary to console
    print("")
    local modeLabel = syncMode == "color" and "color settings"
        or (syncMode == "resolution" and "resolution" or "settings")
    utils.printSuccess(string.format("Applied %s from \"%s\" to %d timeline(s).",
        modeLabel, sourceTimelineName, #selected))
    if totalWarnings > 0 then
        utils.printWarning(string.format("%d timeline(s) had warnings.", totalWarnings))
        for key, count in pairs(allFailedKeys) do
            utils.printWarning(string.format("  %s (failed on %d timeline%s)",
                key, count, count > 1 and "s" or ""))
        end
    end

    return results
end

-- ============================================================================
-- BUILD UI DIALOG
-- ============================================================================

local SOURCE_CARD_STYLE = [[
    QLabel {
        background-color: ]] .. COLORS.btn2Bg .. [[;
        border: 1px solid ]] .. COLORS.btn2Border .. [[;
        border-radius: 6px;
        padding: 12px 14px;
    }
]]

local SECTION_HEADER_STYLE = "color: " .. COLORS.textSubtle .. ";"

-- Segmented toggle: the shared TOGGLE styles use 16px side padding, which
-- clips the labels at a third of this dialog's width - tighten it
local SEGMENT_PADDING = "QPushButton { padding: 8px 4px; }"
local SEGMENT_ACTIVE = STYLES.TOGGLE_ACTIVE .. SEGMENT_PADDING
local SEGMENT_INACTIVE = STYLES.TOGGLE_INACTIVE .. SEGMENT_PADDING

local function escapeHtml(text)
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Two-line rich text for the source card: timeline name over metadata
local function sourceCardHtml(title, subtitle, hasSource)
    local titleColor = hasSource and COLORS.textPrimary or COLORS.textDim
    return string.format(
        '<span style="font-size:14px; color:%s;">%s</span><br/>'
        .. '<span style="font-size:11px; color:%s;">%s</span>',
        titleColor, escapeHtml(title), COLORS.textHint, escapeHtml(subtitle))
end

local function buildDialog(ui, dispatcher)
    local dialog = dispatcher:AddWindow({
        ID = "SettingsSyncDialog",
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
            ui:HGap(28),

            ui:VGroup{
                ID = 'root',

                ui:VGap(28),

                -- Source Timeline section
                ui:Label{
                    Text = "Source Timeline",
                    Font = ui:Font{ PixelSize = 12 },
                    StyleSheet = SECTION_HEADER_STYLE,
                    Weight = 0,
                },

                ui:VGap(8),

                -- Source timeline card: name + resolution/fps/color space
                ui:Label{
                    ID = "SourceCard",
                    Text = sourceCardHtml("No timeline copied", "Copy a timeline to begin", false),
                    WordWrap = true,
                    MinimumSize = {330, 62},
                    StyleSheet = SOURCE_CARD_STYLE,
                    Weight = 0,
                },

                ui:VGap(8),

                -- Copy button ("Copy Selected" until a source exists, then "Recopy")
                ui:Button{
                    ID = "CopyButton",
                    Text = "Copy Selected",
                    MinimumSize = {330, 45},
                    Font = ui:Font{ PixelSize = 13 },
                    StyleSheet = STYLES.BUTTON_SECONDARY,
                    Weight = 0,
                },

                ui:VGap(24),

                -- What to Sync section
                ui:Label{
                    Text = "What to Sync",
                    Font = ui:Font{ PixelSize = 12 },
                    StyleSheet = SECTION_HEADER_STYLE,
                    Weight = 0,
                },

                ui:VGap(8),

                -- Sync mode segmented toggle
                ui:HGroup{
                    Weight = 0,
                    Spacing = 0,

                    ui:Button{
                        ID = "SyncAllToggle",
                        Text = "All Properties",
                        Weight = 1,
                        MinimumSize = {106, 42},
                        Font = ui:Font{ PixelSize = 12 },
                        StyleSheet = SEGMENT_ACTIVE,
                    },

                    ui:HGap(6),

                    ui:Button{
                        ID = "SyncColorToggle",
                        Text = "Color",
                        Weight = 1,
                        MinimumSize = {106, 42},
                        Font = ui:Font{ PixelSize = 12 },
                        StyleSheet = SEGMENT_INACTIVE,
                    },

                    ui:HGap(6),

                    ui:Button{
                        ID = "SyncResolutionToggle",
                        Text = "Resolution",
                        Weight = 1,
                        MinimumSize = {106, 42},
                        Font = ui:Font{ PixelSize = 12 },
                        StyleSheet = SEGMENT_INACTIVE,
                    },
                },

                ui:VGap(8),

                -- Caption describing the selected sync mode
                ui:Label{
                    ID = "SyncCaption",
                    Text = SYNC_CAPTIONS.all,
                    WordWrap = true,
                    Font = ui:Font{ PixelSize = 11 },
                    StyleSheet = "color: " .. COLORS.textHint .. ";",
                    Weight = 0,
                },

                ui:VGap(20),

                -- Apply button
                ui:Button{
                    ID = "ApplyButton",
                    Text = "Apply to Selected",
                    MinimumSize = {330, 45},
                    Font = ui:Font{ PixelSize = 13 },
                    Enabled = false,
                    StyleSheet = STYLES.BUTTON_DISABLED,
                    Weight = 0,
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

    local sourceCard = dialog:Find("SourceCard")
    local copyButton = dialog:Find("CopyButton")
    local applyButton = dialog:Find("ApplyButton")
    local syncCaption = dialog:Find("SyncCaption")
    local toggles = {
        all        = dialog:Find("SyncAllToggle"),
        color      = dialog:Find("SyncColorToggle"),
        resolution = dialog:Find("SyncResolutionToggle"),
    }

    utils.attachFooterHandler(dialog)

    return {
        dialog = dialog,
        setSource = function(name, meta)
            sourceCard.Text = sourceCardHtml(name, meta ~= "" and meta or "Timeline settings copied", true)
            copyButton.Text = "Recopy"
            applyButton.Enabled = true
            applyButton.StyleSheet = STYLES.BUTTON_PRIMARY
            -- A long metadata line word-wraps inside the card; refit the
            -- window height so the extra line grows the card instead of
            -- being clipped (resize in place - never re-center)
            utils.fitDialogHeight(dialog, CONFIG.DIALOG_WIDTH)
        end,
        setSyncMode = function(mode)
            syncMode = mode
            for m, button in pairs(toggles) do
                button.StyleSheet = (m == mode) and SEGMENT_ACTIVE or SEGMENT_INACTIVE
            end
            syncCaption.Text = SYNC_CAPTIONS[mode]
        end,
    }
end

-- ============================================================================
-- MAIN SCRIPT
-- ============================================================================

print("\n")
utils.printHeader(SCRIPT_INFO.NAME .. " v" .. SCRIPT_INFO.VERSION)

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

-- Build dialog
local dialogResult = buildDialog(ui, dispatcher)
local dialog = dialogResult.dialog

-- Event handlers
local function handleCopy()
    utils.printSection("COPY TIMELINE SETTINGS")

    local settings = copySelectedTimelineSettings(project, mediaPool, ui, dispatcher)
    if settings then
        dialogResult.setSource(sourceTimelineName, sourceMeta)
    end
end

local function doApply()
    utils.printSection("APPLY SETTINGS")

    applySettingsToTimelines(project, mediaPool, ui, dispatcher)
end

-- Copy/Apply run via runWithDialogBusy: the dialog greys out and drops
-- clicks while the Resolve API work runs
function dialog.On.CopyButton.Clicked()
    utils.runWithDialogBusy(dialog, handleCopy)
end

function dialog.On.ApplyButton.Clicked()
    utils.runWithDialogBusy(dialog, doApply)
end

-- Sync mode toggles are instant UI-only handlers - no busy wrap
function dialog.On.SyncAllToggle.Clicked()
    dialogResult.setSyncMode("all")
end

function dialog.On.SyncColorToggle.Clicked()
    dialogResult.setSyncMode("color")
end

function dialog.On.SyncResolutionToggle.Clicked()
    dialogResult.setSyncMode("resolution")
end

function dialog.On.SettingsSyncDialog.Close()
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
