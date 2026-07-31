local SCRIPT_INFO = {
    NAME = "Reframe",
    VERSION = "1.1.0",
    MIN_RESOLVE = "20.0",
}

-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[

    Reframe

    Duplicates selected timelines with custom resolution and smart renaming.

    Features:
        - Duplicates selected timelines at a new resolution
        - Resolve-style resolution picker with standard and vertical preset lists
        - Custom width/height entry (editing the fields switches to Custom)
        - Auto-detects trailing resolution/version suffixes in the name and
          rebuilds them (optional; when off the name is left untouched and the
          new resolution is appended)
        - Optionally resets the version suffix to V1; when off the existing
          version suffix is kept
        - Pre-flight collision check: existing target names get a warning
          offering the next available version; cancel creates nothing
        - Optionally removes disabled clips from the duplicated timelines
          (off by default)

    Usage:
        1. Select one or more timelines in the Media Pool
        2. Run this script
        3. Pick a preset or enter a custom width/height
        4. Click Create Timelines

--]]

local utils = require("ResolveKit")
local STYLES, COLORS = utils.STYLES, utils.COLORS

-- Muted caption style for the "For [W] x [H] processing" row
local GREY_LABEL = "QLabel { color: " .. COLORS.textMuted .. "; }"

-- Resolution presets mirroring Resolve's own timeline-settings dropdown.
-- SEP marks a group divider (rendered via InsertSeparator when the widget
-- supports it); CUSTOM is the trailing "Custom" entry selected whenever the
-- width/height fields are edited by hand.
local SEP = {}
local CUSTOM = {}

local function res(w, h, label)
    return {width = tostring(w), height = tostring(h), label = label}
end

-- Display string exactly as Resolve renders it: "<W> x <H> <Label>",
-- label omitted entirely when the preset has none
local function presetDisplayName(entry)
    local s = entry.width .. " x " .. entry.height
    if entry.label then
        s = s .. " " .. entry.label
    end
    return s
end

local STANDARD_PRESETS = {
    res(720, 480, "NTSC DV 16:9"),
    res(720, 480, "NTSC DV"),
    res(720, 486, "NTSC 16:9"),
    res(720, 486, "NTSC"),
    res(720, 576, "PAL 16:9"),
    res(720, 576, "PAL"),
    res(720, 720, "HD 720P Square"),
    res(1280, 720, "HD 720P"),
    res(1080, 1080, "HD Square"),
    res(1280, 1080, "HD 1280"),
    res(1920, 1080, "HD"),
    res(2160, 2160, "Ultra HD Square"),
    res(3840, 2160, "Ultra HD"),
    res(7680, 4320, "8K Ultra HD"),
    SEP,
    res(1828, 1332, "Academy"),
    res(1828, 1556, "Scope"),
    res(1998, 1080, "DCI Flat 1.85"),
    res(2048, 858, "DCI Scope 2.39"),
    res(2048, 1080, "DCI"),
    res(2048, 1152, "2K 16:9"),
    res(2048, 1556, "Full Aperture"),
    res(3072, 2048, "VistaVision"),
    res(3654, 2664, "Academy"),
    res(3656, 3112, "Scope"),
    res(3996, 2160, "DCI Flat 1.85"),
    res(4096, 1716, "DCI Scope 2.39"),
    res(4096, 2160, "DCI"),
    res(4096, 3112, "Full Aperture"),
    res(8192, 4320, "DCI"),
    SEP,
    res(4080, 3600, "Immersive"),
    res(8160, 7200, "Immersive"),
    SEP,
    CUSTOM,
}

local VERTICAL_PRESETS = {
    res(720, 720, "HD 720P Square"),
    res(720, 1280, "HD 720P"),
    res(1080, 1080, "HD Square"),
    res(1080, 1920, "HD"),
    res(2160, 2160, "Ultra HD Square"),
    res(2160, 3840, "Ultra HD"),
    res(4320, 7680, "8K Ultra HD"),
    SEP,
    res(864, 1080),
    res(1080, 1350),
    SEP,
    CUSTOM,
}

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

local CONFIG = {
    DIALOG_WIDTH = 420,
    DIALOG_FALLBACK_HEIGHT = 340,  -- only used if fitDialogHeight fails
}

-- ============================================================================
-- RESOLUTION PICKER HELPERS
-- ============================================================================

-- Rebuilds the combo from a preset list. Returns an index map:
--   entries[i] (0-based combo index) -> preset table | SEP | CUSTOM
--   count        total combo item count (including separator slots)
--   customIndex  combo index of the "Custom" entry
-- InsertSeparator is documented but unproven in this binding, so it is
-- feature-detected per call: a separator only gets an index slot in the map
-- if combo:Count() actually grew. Without support the list is simply flat.
local function populateResolutionCombo(combo, presets)
    combo:Clear()
    local model = {entries = {}, count = 0, customIndex = nil}
    for _, entry in ipairs(presets) do
        if entry == SEP then
            local before = combo:Count()
            pcall(function() combo:InsertSeparator(model.count) end)
            if combo:Count() > before then
                model.entries[model.count] = SEP
                model.count = model.count + 1
            end
        else
            combo:AddItem(entry == CUSTOM and "Custom" or presetDisplayName(entry))
            if entry == CUSTOM then
                model.customIndex = model.count
            end
            model.entries[model.count] = entry
            model.count = model.count + 1
        end
    end
    return model
end

-- First preset (ascending combo index) matching the given W/H strings;
-- duplicate W/H pairs in the standard list resolve to the first occurrence
local function findPresetIndex(model, width, height)
    for i = 0, model.count - 1 do
        local e = model.entries[i]
        if e ~= SEP and e ~= CUSTOM and e.width == width and e.height == height then
            return i
        end
    end
    return nil
end

local function validateDimension(raw, name)
    local text = (raw or ""):match("^%s*(.-)%s*$")
    if not text:match("^%d+$") then
        return nil, name .. " must be a whole number."
    end
    local n = tonumber(text)
    if n < 16 or n > 32768 then
        return nil, name .. " must be between 16 and 32768."
    end
    return text
end

-- ============================================================================
-- RESOLUTION DIALOG
-- ============================================================================

-- Function to build the resolution selection dialog
local function buildResolutionDialog(ui, dispatcher)
    if not ui or not dispatcher then
        return nil, "UI not available"
    end

    -- Create dialog window
    local dialog = dispatcher:AddWindow({
        ID = 'ResolutionSelector',
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

                -- Resolution dropdown
                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Text = "Resolution:",
                        Font = ui:Font{PixelSize = 12},
                        MinimumSize = {110, 20},
                        Weight = 0,
                    },
                    ui:ComboBox{
                        ID = 'ResolutionCombo',
                        MinimumSize = {220, 33},
                        Weight = 1,
                    },
                },

                ui:VGap(8),

                -- "For [W] x [H] processing" row (mirrors Resolve's timeline
                -- settings), indented to align with the combo column
                ui:HGroup{
                    Weight = 0,
                    ui:HGap(110),
                    ui:Label{
                        Text = "For",
                        Font = ui:Font{PixelSize = 12},
                        StyleSheet = GREY_LABEL,
                        Weight = 0,
                    },
                    ui:LineEdit{
                        ID = 'WidthField',
                        Text = "1080",
                        MinimumSize = {70, 33},
                        Font = ui:Font{PixelSize = 12},
                        StyleSheet = STYLES.INPUT,
                        Weight = 0,
                    },
                    ui:Label{
                        Text = "x",
                        Font = ui:Font{PixelSize = 12},
                        StyleSheet = GREY_LABEL,
                        Weight = 0,
                    },
                    ui:LineEdit{
                        ID = 'HeightField',
                        Text = "1920",
                        MinimumSize = {70, 33},
                        Font = ui:Font{PixelSize = 12},
                        StyleSheet = STYLES.INPUT,
                        Weight = 0,
                    },
                    ui:Label{
                        Text = "processing",
                        Font = ui:Font{PixelSize = 12},
                        StyleSheet = GREY_LABEL,
                        Weight = 0,
                    },
                    ui:HGap(0, 1),  -- stretch keeps the row left-packed
                },

                ui:VGap(12),

                -- Vertical-list toggle, aligned with the combo column
                ui:HGroup{
                    Weight = 0,
                    ui:HGap(110),
                    ui:CheckBox{
                        ID = 'VerticalCheck',
                        Text = "Use vertical resolution",
                        Checked = true,
                        Font = ui:Font{PixelSize = 11},
                    },
                },

                ui:VGap(16),

                -- Options checkboxes
                ui:VGroup{
                    Weight = 0,
                    -- When off, the name is treated as opaque and the
                    -- version checkbox below is disabled
                    ui:CheckBox{
                        ID = 'AutoDetectCheck',
                        Text = "Auto-detect resolution and version in name",
                        Checked = true,
                        Font = ui:Font{PixelSize = 11},
                    },
                    ui:CheckBox{
                        ID = 'ResetVersionCheck',
                        Text = "Reset version to V1",
                        Checked = true,
                        Font = ui:Font{PixelSize = 11},
                    },
                    -- Off by default: deletion forces a current-timeline
                    -- switch per duplicate
                    ui:CheckBox{
                        ID = 'RemoveDisabledCheck',
                        Text = "Remove disabled clips",
                        Checked = false,
                        Font = ui:Font{PixelSize = 11},
                    },
                },

                ui:VGap(16),

                -- Create Timelines button (full width)
                ui:Button{
                    ID = 'OkButton',
                    Text = 'Create Timelines',
                    MinimumSize = {330, 45},
                    Font = ui:Font{PixelSize = 12},
                    StyleSheet = STYLES.BUTTON_PRIMARY,
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

    local itm = dialog:GetItems()

    utils.attachFooterHandler(dialog)

    -- Combo population and selection sync live in the main script
    return {
        dialog = dialog,
        items = itm,
    }
end


-- Function to process a single timeline with smart UI switching
local function processTimeline(project, timelineInfo, newName, targetResolution, removeDisabled)
    local timeline = timelineInfo.timeline
    local timelineName = timelineInfo.name

    if not timeline then
        return false, "Could not access timeline object", 0
    end

    print("\nProcessing timeline: " .. timelineName)
    print("  New name: " .. newName)

    -- Duplicate the timeline with the new name
    local duplicatedTimeline = timeline:DuplicateTimeline(newName)

    if not duplicatedTimeline then
        return false, "Failed to duplicate timeline (name may already be taken)", 0
    end

    -- Enable custom settings, preserving inherited project settings: a raw
    -- useCustomSettings flip resets color prefs on timelines that had
    -- "Use Project Settings" ticked
    local settingsStats, settingsErr = utils.enableCustomTimelineSettings(project, duplicatedTimeline)
    if not settingsStats then
        utils.printWarning("Could not enable custom settings for: " .. newName ..
            (settingsErr and (" (" .. settingsErr .. ")") or ""))
    else
        if settingsStats.wasInherited then
            local note = "  Preserved " .. settingsStats.preservedCount .. " inherited project setting(s)"
            if settingsStats.skippedCount > 0 then
                note = note .. " (" .. settingsStats.skippedCount .. " skipped, API limitation)"
            end
            print(note)
        end
        if #settingsStats.failedKeys > 0 then
            utils.printWarning("Could not restore " .. #settingsStats.failedKeys ..
                " setting(s) for " .. newName .. ": " .. table.concat(settingsStats.failedKeys, ", "))
        end
    end

    local widthSet = duplicatedTimeline:SetSetting("timelineResolutionWidth", targetResolution.width)
    local heightSet = duplicatedTimeline:SetSetting("timelineResolutionHeight", targetResolution.height)
    if not widthSet or not heightSet then
        utils.printWarning("Could not set resolution " .. targetResolution.width .. "x" ..
                           targetResolution.height .. " for: " .. newName ..
                           " (timeline was created; verify its settings)")
    end

    local clipsDeleted = 0

    if removeDisabled then
        -- Scan for disabled clips without switching the current timeline; only switch if needed
        local disabledClipsInfo, scanErr = utils.findDisabledClips(duplicatedTimeline, true, true)

        if disabledClipsInfo and disabledClipsInfo.totalCount > 0 then
            -- Disabled clips found - need to switch to UI to delete them
            print("  Found " .. disabledClipsInfo.totalCount .. " disabled clip(s) to remove")

            -- Set the duplicated timeline as current for deletion
            local setSuccess, setErr = utils.setCurrentTimeline(project, duplicatedTimeline)
            if not setSuccess then
                utils.printWarning("Could not set timeline as current for deletion: " .. (setErr or "Unknown error"))
                -- Continue anyway - timeline was created successfully even if clips weren't deleted
            else
                -- Now delete the disabled clips
                local deleteStats, deleteErr = utils.deleteDisabledClips(duplicatedTimeline, true, true)

                if deleteStats then
                    clipsDeleted = deleteStats.totalDeleted
                    if clipsDeleted > 0 then
                        print("  Removed " .. clipsDeleted .. " disabled clip(s) (" ..
                              deleteStats.videoDeleted .. " video, " .. deleteStats.audioDeleted .. " audio)")
                    end
                elseif deleteErr then
                    utils.printWarning("Could not delete disabled clips: " .. deleteErr)
                end
            end
        elseif disabledClipsInfo then
            -- No disabled clips found - no UI switch needed
            print("  No disabled clips to remove")
        elseif scanErr then
            utils.printWarning("Could not scan for disabled clips: " .. scanErr)
        end
    end

    utils.printSuccess("Created: " .. newName)
    return true, nil, clipsDeleted
end

-- ============================================================================
-- MAIN SCRIPT
-- ============================================================================

utils.printHeader(SCRIPT_INFO.NAME .. " v" .. SCRIPT_INFO.VERSION)

-- Initialize Resolve with UI
local ctx, err = utils.initializeWithUI(SCRIPT_INFO)
if not ctx then
    utils.printError(err)
    return
end

local project = ctx.project
local mediaPool = ctx.mediaPool
local ui = ctx.ui
local dispatcher = ctx.dispatcher

-- Build dialog once; it stays open while timelines are processed
-- (progress window opens on top)
local dialogResult, err = buildResolutionDialog(ui, dispatcher)
if not dialogResult then
    utils.printError(err or "UI not available")
    return
end

local dialog = dialogResult.dialog
local itm = dialogResult.items

-- ============================================================================
-- RESOLUTION PICKER SYNC
-- ============================================================================
-- Programmatic .Text/.CurrentIndex writes echo TextChanged/CurrentIndexChanged
-- (see renamer.lua's OperationType handler). Two-layer defense: a suppress flag
-- around every programmatic write, plus idempotent state-comparison guards in
-- each handler for echoes the dispatcher delivers after the flag clears.

local suppress = false   -- true while writing .Text/.CurrentIndex from code
local comboModel = nil   -- index map for the current combo contents

local function currentEntry()
    return comboModel and comboModel.entries[itm.ResolutionCombo.CurrentIndex]
end

local function setFields(w, h)
    suppress = true
    itm.WidthField.Text = w
    itm.HeightField.Text = h
    suppress = false
end

local function selectCustom()
    if not comboModel or itm.ResolutionCombo.CurrentIndex == comboModel.customIndex then
        return
    end
    suppress = true
    itm.ResolutionCombo.CurrentIndex = comboModel.customIndex
    suppress = false
end

-- Rebuild the list for the given orientation, then select the preset matching
-- w/h (first match wins) or Custom. Never touches the fields.
local function rebuildCombo(vertical, w, h)
    suppress = true
    comboModel = populateResolutionCombo(itm.ResolutionCombo,
        vertical and VERTICAL_PRESETS or STANDARD_PRESETS)
    itm.ResolutionCombo.CurrentIndex = findPresetIndex(comboModel, w, h)
        or comboModel.customIndex
    suppress = false
end

-- How many candidate names to probe before giving up
local MAX_NAME_PROBES = 1000

-- Smallest free candidate from makeName(n), n = startN upward
-- Returns: name, nil (or nil, error)
local function findNextAvailableName(makeName, startN, takenNames)
    for n = startN, startN + MAX_NAME_PROBES - 1 do
        local name = makeName(n)
        if not takenNames[name] then
            return name, nil
        end
    end
    return nil, string.format("No free name within %d tries", MAX_NAME_PROBES)
end

-- Compute the target name and collision-probe closure for one timeline.
-- Naming matrix:
--   auto-detect + reset    -> base_WxH_V1
--   auto-detect + no reset -> base_WxH + old version token (padding kept),
--                             or nothing when the name had none
--   no auto-detect         -> originalName_WxH (name treated as opaque)
local function buildOperation(timelineInfo, resolutionString, autoDetect, resetVersion)
    local op = {timeline = timelineInfo.timeline, name = timelineInfo.name}

    local stem, versionToken
    if autoDetect then
        local parsed = utils.parseTimelineName(timelineInfo.name)
        stem = parsed.base .. "_" .. resolutionString
        versionToken = resetVersion and "V1" or parsed.version
    else
        stem = timelineInfo.name .. "_" .. resolutionString
    end

    if versionToken then
        -- Probe upward from the token's own number, keeping case and padding
        local vChar, vDigits = versionToken:match("^([Vv])(%d+)$")
        local pad = #vDigits
        op.newName = stem .. "_" .. versionToken
        op.probeStart = tonumber(vDigits) + 1
        op.makeName = function(n)
            return stem .. "_" .. vChar .. string.format("%0" .. pad .. "d", n)
        end
    else
        -- No version component: the unversioned name counts as V1, probe _V2 up
        op.newName = stem
        op.probeStart = 2
        op.makeName = function(n) return stem .. "_V" .. n end
    end
    return op
end

-- Warn that target name(s) already exist. Returns true to redirect every
-- colliding timeline to its next available name, false to cancel the whole
-- batch (closing the window also cancels).
local function showCollisionDialog(ui, dispatcher, collisions)
    local lines
    if #collisions == 1 then
        lines = {
            string.format("%s already exists.", collisions[1].takenName),
            "",
            string.format("Next available name: %s", collisions[1].nextName),
        }
    else
        lines = {
            string.format("%d timeline names already exist.", #collisions),
            "",
            "Each will use its next available name.",
        }
    end

    return utils.showStatusDialog(ui, dispatcher, {
        icon = 'warning',
        title = 'Timeline Already Exists',
        message = table.concat(lines, "\n"),
        closeValue = false,
        buttons = {
            { id = 'CancelBtn', text = 'Cancel', value = false, style = 'secondary' },
            { id = 'UseNextBtn', text = 'Use Next Available Name', value = true, style = 'primary' },
        },
    })
end

-- Run one batch from the OK button handler; the main dialog stays visible
local function runCreate(selectedResolution, autoDetect, resetVersion, removeDisabled)
    local resolutionString = selectedResolution.width .. "x" .. selectedResolution.height

    -- Display selected settings
    local resetLabel = "N/A"
    if autoDetect then
        resetLabel = resetVersion and "V1" or "Keep existing"
    end
    print("\nSelected Resolution: " .. resolutionString)
    print("Auto-Detect Naming: " .. (autoDetect and "Yes" or "No"))
    print("Reset Version: " .. resetLabel)
    print("Remove Disabled Clips: " .. (removeDisabled and "Yes" or "No"))

    -- Get selected timelines from Media Pool (check directly in handler)
    local selectedTimelines = utils.requireSelectedTimelines(project, mediaPool, ui, dispatcher)
    if not selectedTimelines then
        return
    end

    local timelineCount = #selectedTimelines
    print("\nFound " .. timelineCount .. " selected timeline(s)")

    -- Compute all target names up front (no API mutations yet)
    local operations = {}
    for _, timelineInfo in ipairs(selectedTimelines) do
        table.insert(operations,
            buildOperation(timelineInfo, resolutionString, autoDetect, resetVersion))
    end

    -- Collision gate: Resolve refuses to create a timeline under a name that
    -- already exists, so DuplicateTimeline would fail with no visible error.
    -- Best-effort pre-flight; the duplicate-failed path below stays as the
    -- backstop for races and other failures.
    local takenNames, namesErr = utils.getTimelineNameSet(project)
    if not takenNames then
        utils.printError(namesErr or "Could not read timeline names")
        return
    end

    local collisions = {}
    for _, op in ipairs(operations) do
        if takenNames[op.newName] then
            local nextName, probeErr = findNextAvailableName(op.makeName, op.probeStart, takenNames)
            if not nextName then
                utils.printError(probeErr .. " for " .. op.name)
                utils.showErrorDialog(ui, dispatcher, probeErr, SCRIPT_INFO.NAME)
                return
            end
            op.takenName = op.newName
            op.nextName = nextName
            table.insert(collisions, op)
        end
        -- Claim both names so within-batch duplicates collide and probe past
        takenNames[op.newName] = true
        if op.nextName then
            takenNames[op.nextName] = true
        end
    end

    if #collisions > 0 then
        for _, op in ipairs(collisions) do
            utils.printStatus("WARN", string.format("%s already exists, next available is %s",
                op.takenName, op.nextName))
        end
        if not showCollisionDialog(ui, dispatcher, collisions) then
            utils.printWarning("Cancelled by user - no timelines were created")
            return
        end
        for _, op in ipairs(collisions) do
            op.newName = op.nextName
        end
    end

    utils.printSection("Processing Timelines")

    local successCount = 0
    local failedCount = 0
    local failedTimelines = {}
    local totalClipsDeleted = 0

    -- Create progress window
    local progress = utils.createProgressWindow(ui, dispatcher, {
        title = "Creating Resolution Versions",
        totalItems = timelineCount
    })
    if progress then
        progress.show()
    else
        utils.printWarning("Could not create progress window, continuing without it")
    end

    -- Process each operation
    for i, op in ipairs(operations) do
        -- Update progress window at start of iteration
        if progress then
            progress.update(i, op.name, string.format('[%d/%d] Processing: %s -> %s\n', i, timelineCount, op.name, op.newName))
        end

        local success, procErr, clipsDeleted = processTimeline(project, op, op.newName, selectedResolution, removeDisabled)

        if success then
            successCount = successCount + 1
            totalClipsDeleted = totalClipsDeleted + (clipsDeleted or 0)

            -- Update progress with success
            if progress then
                progress.update(i, op.newName, utils.statusLine("OK", string.format('Created: %s', op.newName)) .. '\n')
            end
        else
            failedCount = failedCount + 1
            local failReason = procErr or "could not duplicate the timeline or set its resolution"
            table.insert(failedTimelines, {
                name = op.name,
                error = failReason
            })
            utils.printError("Failed to process '" .. op.name .. "': " .. failReason)

            -- Update progress with failure
            if progress then
                progress.update(i, op.name, utils.statusLine("ERROR", failReason) .. '\n')
            end
        end
    end

    -- Final summary update
    if progress then
        local summaryMsg = string.format("Complete: %d created, %d failed", successCount, failedCount)
        progress.update(timelineCount, summaryMsg, string.format('Complete: %d/%d succeeded\n', successCount, timelineCount), true)
        utils.sleep(1)
        progress.hide()
    end

    -- Print summary to console
    utils.printHeader("Summary")
    print("Target Resolution: " .. selectedResolution.width .. "x" .. selectedResolution.height)
    print("Successfully processed: " .. successCount .. "/" .. timelineCount .. " timeline(s)")

    if totalClipsDeleted > 0 then
        print("Total disabled clips removed: " .. totalClipsDeleted)
    end

    if failedCount > 0 then
        utils.printWarning("Failed to process " .. failedCount .. " timeline(s):")
        for _, failed in ipairs(failedTimelines) do
            print("  - " .. failed.name .. " (" .. failed.error .. ")")
        end
    end
end

-- Event handlers (processing runs here so the dialog stays open;
-- runWithDialogBusy greys the dialog and drops clicks while it runs)
function dialog.On.ResolutionCombo.CurrentIndexChanged(ev)
    if suppress then return end
    local entry = currentEntry()
    if not entry or entry == SEP or entry == CUSTOM then
        return  -- rebuild echo, separator slot, or Custom (never overwrites fields)
    end
    if itm.WidthField.Text == entry.width and itm.HeightField.Text == entry.height then
        return  -- late echo of a programmatic sync; already consistent
    end
    setFields(entry.width, entry.height)
end

local function onFieldEdited()
    if suppress or not comboModel then return end
    local entry = currentEntry()
    if entry == CUSTOM then return end
    if entry and entry ~= SEP
        and entry.width == itm.WidthField.Text
        and entry.height == itm.HeightField.Text then
        return  -- fields match selection: echo of a preset fill
    end
    selectCustom()
end

function dialog.On.WidthField.TextChanged(ev) onFieldEdited() end
function dialog.On.HeightField.TextChanged(ev) onFieldEdited() end

function dialog.On.VerticalCheck.Clicked(ev)
    -- Resolve behavior: toggling swaps W/H, then reselects the matching
    -- preset in the swapped-in list (or Custom)
    local w, h = itm.WidthField.Text, itm.HeightField.Text
    setFields(h, w)
    rebuildCombo(itm.VerticalCheck.Checked, h, w)
end

function dialog.On.AutoDetectCheck.Clicked(ev)
    -- Version handling only applies when the name is understood
    itm.ResetVersionCheck.Enabled = itm.AutoDetectCheck.Checked
end

function dialog.On.OkButton.Clicked(ev)
    utils.runWithDialogBusy(dialog, function()
        local w, werr = validateDimension(itm.WidthField.Text, "Width")
        local h, herr = validateDimension(itm.HeightField.Text, "Height")
        if not w or not h then
            utils.showErrorDialog(ui, dispatcher, werr or herr, "Invalid Resolution")
            return
        end
        runCreate({width = w, height = h}, itm.AutoDetectCheck.Checked,
            itm.ResetVersionCheck.Checked, itm.RemoveDisabledCheck.Checked)
    end)
end

function dialog.On.ResolutionSelector.Close(ev)
    dispatcher:ExitLoop()
end

-- Initial state: vertical list with "1080 x 1920 HD" selected (the fields
-- and VerticalCheck already default to 1080/1920/checked declaratively)
rebuildCombo(true, "1080", "1920")

-- Show dialog and run event loop
dialog:RecalcLayout()
utils.centerDialogOnScreen(dialog, ui, dispatcher)
dialog:Show()
dispatcher:RunLoop()
dialog:Hide()

utils.printSeparator("=", 70)
print("Script completed!")