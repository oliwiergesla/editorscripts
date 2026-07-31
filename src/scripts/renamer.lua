local SCRIPT_INFO = {
    NAME = "Renamer",
    VERSION = "1.0.3",
    MIN_RESOLVE = "20.0",
}
-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[

    Renamer

    Batch rename media pool items (timelines or clips).

    Features:
        - Mode selector: Switch between Timelines and Clips
        - Replace Text: Find and replace text in item names
        - Add Text: Add prefix or suffix to names
        - Format: Use patterns with {token} placeholders:
            - {name}: Original item name
            - {counter} / {index}: Zero-padded or plain sequential number
            - {date}: Item creation date (YYYY-MM-DD)
            - {resolution} / {framerate}: Clip/timeline metadata
            - Clips only: {extension}
        - Clone mode: Duplicate timelines with new names (Timelines mode only)

    Usage:
        1. Select items in the Media Pool
        2. Run this script
        3. Choose mode (Timelines or Clips)
        4. Choose rename operation
        5. Configure options
        6. Click Rename to apply

--]]

local utils = require("ResolveKit")
local STYLES, COLORS = utils.STYLES, utils.COLORS

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

local CONFIG = {
    DIALOG_WIDTH = 420,

    -- Window height configuration (modular)
    DIALOG_FALLBACK_HEIGHT = 550,        -- only used if fitDialogHeight fails (old max height)

    -- Preview truncation
    PREVIEW_MAX_LENGTH = 50,

    -- Default format pattern
    DEFAULT_PATTERN = "{name}_{counter}",

    -- Available operations per mode ("Set to Filename" is clips-only)
    OPERATIONS = {
        Clips = {"Replace Text", "Add Text", "Format", "Set to Filename"},
        Timelines = {"Replace Text", "Add Text", "Format"},
    },
}

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Rename selected clips to their original filename (from file path)
-- @param mediaPool - The media pool object
-- @return table { success: number, failed: number, skipped: number, errors: table }
--         or nil, errorMessage if no clips selected
local function renameClipsToOriginalFilename(mediaPool)
    local selectedClips = mediaPool:GetSelectedClips()
    if not selectedClips or #selectedClips == 0 then
        return nil, "No clips selected in the Media Pool"
    end

    local results = {
        success = 0,
        failed = 0,
        skipped = 0,
        errors = {}
    }

    for _, clip in ipairs(selectedClips) do
        local clipType = clip:GetClipProperty("Type")

        -- Skip timelines
        if clipType == "Timeline" then
            results.skipped = results.skipped + 1
        else
            local filePath = clip:GetClipProperty("File Path") or ""

            -- Skip generated media (no file path)
            if filePath == "" then
                results.skipped = results.skipped + 1
            else
                -- Extract filename from path
                local filename = utils.getFilename(filePath)

                if not filename or filename == "" then
                    results.skipped = results.skipped + 1
                else
                    local currentName = clip:GetName()

                    -- Skip if already has correct name
                    if currentName == filename then
                        results.skipped = results.skipped + 1
                    else
                        local success = clip:SetName(filename)
                        if success then
                            results.success = results.success + 1
                        else
                            results.failed = results.failed + 1
                            table.insert(results.errors, {
                                oldName = currentName,
                                targetName = filename,
                                error = "SetName failed"
                            })
                        end
                    end
                end
            end
        end
    end

    return results
end

-- ============================================================================
-- UNDO DATA PERSISTENCE
-- ============================================================================

-- Get path to undo data file (in the hidden .data folder next to the script)
local function getUndoFilePath()
    local dataDir = utils.getDataDir()
    if not dataDir then return nil end
    return utils.joinPath(dataDir, "renamer_undo.json")
end

-- Save undo data to file
local function saveUndoData(data)
    local path = getUndoFilePath()
    if not path then return false end
    return utils.writeJSONFile(path, data)
end

-- Load undo data from file (nil when no undo file exists)
local function loadUndoData()
    local path = getUndoFilePath()
    if not path then return nil end
    return utils.readJSONFile(path)
end

-- Clear undo data file
local function clearUndoData()
    local path = getUndoFilePath()
    if path then
        os.remove(path)
    end
end


-- ============================================================================
-- SELECTION HANDLING
-- ============================================================================

-- Month-name lookup for parsing Resolve's "Date Created" clip property
local MONTH_NUMBERS = {
    Jan = "01", Feb = "02", Mar = "03", Apr = "04", May = "05", Jun = "06",
    Jul = "07", Aug = "08", Sep = "09", Oct = "10", Nov = "11", Dec = "12"
}

-- Parse a "Date Created" clip property value into YYYY-MM-DD. Resolve
-- formats this differently across versions/locales, so handle ISO-like
-- ("2024-03-16 14:53:22"), US-style ("Sat Mar 16 2024") and day-first
-- ("16 Mar 2024") forms. Returns nil if missing/unrecognized.
local function parseDateCreated(raw)
    if not raw or raw == "" then return nil end

    local y, m, d = raw:match("(%d%d%d%d)[%-/](%d%d?)[%-/](%d%d?)")
    if y then
        return string.format("%04d-%02d-%02d", tonumber(y), tonumber(m), tonumber(d))
    end

    local mon, day, year = raw:match("(%a%a%a)%s+(%d%d?)%s+(%d%d%d%d)")
    if mon and MONTH_NUMBERS[mon] then
        return string.format("%s-%s-%02d", year, MONTH_NUMBERS[mon], tonumber(day))
    end

    local day2, mon2, year2 = raw:match("(%d%d?)%s+(%a%a%a)%s+(%d%d%d%d)")
    if mon2 and MONTH_NUMBERS[mon2] then
        return string.format("%s-%s-%02d", year2, MONTH_NUMBERS[mon2], tonumber(day2))
    end

    return nil
end

-- Build a uniqueId -> Timeline lookup for matching media pool items to timelines
local function buildTimelineLookup(project)
    local timelinesByUniqueId = {}
    local timelineCount = project:GetTimelineCount()
    for i = 1, timelineCount do
        local timeline = project:GetTimelineByIndex(i)
        if timeline then
            local mpItem = timeline:GetMediaPoolItem()
            if mpItem then
                local uniqueId = mpItem:GetUniqueId()
                if uniqueId then
                    timelinesByUniqueId[uniqueId] = timeline
                end
            end
        end
    end
    return timelinesByUniqueId
end

-- Record table for a selected timeline item
-- props: the item's full property dict from clip:GetClipProperty()
local function makeTimelineRecord(clip, timelineLookup, props)
    return {
        name = clip:GetName(),
        clipItem = clip,
        timeline = timelineLookup[clip:GetUniqueId()],
        dateCreated = parseDateCreated(props["Date Created"]),
        type = "Timeline"
    }
end

-- Record table for a selected non-timeline clip
-- props: the clip's full property dict from clip:GetClipProperty() -- one
-- snapshot beats the 5 per-key reads a record needs (break-even is ~3 keys,
-- see AGENTS.md "Full-Dict Property Reads")
local function makeClipRecord(clip, props)
    local filePath = props["File Path"] or ""
    return {
        name = clip:GetName(),
        clipItem = clip,
        filePath = filePath,
        extension = utils.getExtension(filePath),
        dateCreated = parseDateCreated(props["Date Created"]),
        resolution = props["Resolution"] or "",
        framerate = props["FPS"] or "",
        type = props["Type"] or "Clip"
    }
end

-- Split selected media pool items into timelines and clips
local function splitSelectedItems(project, mediaPool)
    local selectedClips = mediaPool:GetSelectedClips()
    if not selectedClips or #selectedClips == 0 then
        return nil, nil, "No items selected in the Media Pool"
    end

    local timelineLookup = buildTimelineLookup(project)

    local timelines = {}
    local clips = {}

    for _, clip in ipairs(selectedClips) do
        local props = clip:GetClipProperty() or {}
        if props["Type"] == "Timeline" then
            table.insert(timelines, makeTimelineRecord(clip, timelineLookup, props))
        else
            table.insert(clips, makeClipRecord(clip, props))
        end
    end

    return timelines, clips, nil
end

-- ============================================================================
-- RENAME OPERATIONS
-- ============================================================================

-- Replace Text operation
local function replaceText(name, findText, replaceWith)
    if findText == "" then
        return name
    end
    local escaped = findText:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    -- Escape % in the replacement so user input like "50%" isn't treated as a backreference
    local safeReplaceWith = replaceWith:gsub("%%", "%%%%")
    return name:gsub(escaped, safeReplaceWith)
end

-- Add Text operation
local function addText(name, textToAdd, position)
    if position == "before" then
        return textToAdd .. name
    else
        return name .. textToAdd
    end
end

-- Format operation with token replacement (applyTokens is a single pass, so
-- '%' or literal '{token}' text inside clip names comes through unchanged)
local function formatName(name, formatString, index, totalCount, metadata)
    -- Calculate padding for counter
    local maxDigits = string.len(tostring(totalCount))

    local tokens = {
        name = name or "",
        counter = string.format("%0" .. maxDigits .. "d", index),
        index = tostring(index),
        -- Creation date of the item being renamed; today's date only as fallback
        date = (metadata and metadata.dateCreated) or os.date("%Y-%m-%d"),
    }

    -- Mode-specific tokens (left untouched in the pattern when absent)
    if metadata then
        tokens.resolution = metadata.resolution or ""
        tokens.framerate = metadata.framerate or ""
        tokens.extension = metadata.extension or ""
    end

    return utils.applyTokens(formatString, tokens)
end

-- Apply rename operation
local function applyRenameOperation(name, operation, params, index, totalCount, metadata)
    if operation == "Replace Text" then
        return replaceText(name, params.findText or "", params.replaceWith or "")
    elseif operation == "Add Text" then
        return addText(name, params.textToAdd or "", params.position or "after")
    elseif operation == "Format" then
        return formatName(name, params.formatString or CONFIG.DEFAULT_PATTERN, index, totalCount, metadata)
    end
    return name
end

-- ============================================================================
-- CONFLICT DETECTION (Timelines only)
-- ============================================================================

local function getExistingTimelineNames(project)
    local names = {}
    local count = project:GetTimelineCount()
    for i = 1, count do
        local timeline = project:GetTimelineByIndex(i)
        if timeline then
            names[timeline:GetName()] = true
        end
    end
    return names
end

local function checkForConflicts(previews, existingNames, isCloneMode, selectedNames)
    local conflicts = {}
    local newNamesInBatch = {}

    for _, preview in ipairs(previews) do
        local hasConflict = false
        local conflictReason = nil

        if preview.oldName == preview.newName then
            -- No change, no conflict
        else
            -- Check for duplicate within the batch
            if newNamesInBatch[preview.newName] then
                hasConflict = true
                conflictReason = "Duplicate in selection"
            else
                if isCloneMode then
                    if existingNames[preview.newName] then
                        hasConflict = true
                        conflictReason = "Name already exists"
                    end
                else
                    if existingNames[preview.newName] and not selectedNames[preview.newName] then
                        hasConflict = true
                        conflictReason = "Name already exists"
                    end
                end
            end

            if preview.newName ~= "" then
                newNamesInBatch[preview.newName] = true
            end
        end

        preview.hasConflict = hasConflict
        preview.conflictReason = conflictReason

        if hasConflict then
            table.insert(conflicts, preview)
        end
    end

    return conflicts
end

-- Get all clip names from media pool (recursively)
local function getAllClipNames(mediaPool)
    local clips = utils.collectClips(mediaPool:GetRootFolder(), function(clip)
        return clip:GetClipProperty("Type") ~= "Timeline"
    end)

    local names = {}
    for _, clip in ipairs(clips) do
        local name = clip:GetName()
        if name then
            names[name] = true
        end
    end

    return names
end

-- Check whether any preview's new name collides within the batch or with an
-- existing clip outside the selection. Returns true when a collision exists.
local function checkClipDuplicates(previews, existingNames, selectedNames)
    local newNamesInBatch = {}
    local hasDuplicates = false

    for _, preview in ipairs(previews) do
        if preview.oldName ~= preview.newName then
            -- Duplicate within the batch, or against existing clips outside the selection
            if newNamesInBatch[preview.newName]
                or (existingNames[preview.newName] and not selectedNames[preview.newName]) then
                hasDuplicates = true
            end

            if preview.newName ~= "" then
                newNamesInBatch[preview.newName] = true
            end
        end
    end

    return hasDuplicates
end

-- Show warning dialog for clip duplicates, returns true if user wants to continue
local function showClipDuplicateWarning(ui, disp)
    return utils.showStatusDialog(ui, disp, {
        icon = 'warning',
        title = 'Duplicate Clip Names',
        message = "One or more clips already exist with the new name.",
        buttons = {
            { id = 'ContinueBtn', text = 'Continue Anyway', value = true,  style = 'primary' },
            { id = 'CancelBtn',   text = 'Cancel',          value = false, style = 'secondary' },
        },
    })
end

-- ============================================================================
-- PREVIEW GENERATION
-- ============================================================================

local function generateTimelinesPreview(timelines, operation, params)
    local previews = {}
    for i, timelineInfo in ipairs(timelines) do
        local oldName = timelineInfo.name
        local timeline = timelineInfo.timeline

        -- Get metadata from timeline
        local metadata = { resolution = "", framerate = "", dateCreated = timelineInfo.dateCreated }
        if timeline then
            local width = timeline:GetSetting("timelineResolutionWidth")
            local height = timeline:GetSetting("timelineResolutionHeight")
            local fps = timeline:GetSetting("timelineFrameRate")
            if width and height then
                metadata.resolution = width .. "x" .. height
            end
            if fps then
                metadata.framerate = fps .. "fps"
            end
        end

        local newName = applyRenameOperation(oldName, operation, params, i, #timelines, metadata)

        table.insert(previews, {
            clipItem = timelineInfo.clipItem,
            timeline = timeline,
            oldName = oldName,
            newName = newName,
            metadata = metadata,
            hasConflict = false,
            conflictReason = nil
        })
    end
    return previews
end

local function generateClipsPreview(clips, operation, params)
    local previews = {}
    for i, clip in ipairs(clips) do
        local oldName = clip.name

        local metadata = {
            extension = clip.extension or "",
            resolution = clip.resolution or "",
            framerate = clip.framerate or "",
            dateCreated = clip.dateCreated
        }
        local newName = applyRenameOperation(oldName, operation, params, i, #clips, metadata)

        table.insert(previews, {
            clipItem = clip.clipItem,
            oldName = oldName,
            newName = newName,
            metadata = metadata,
            hasConflict = false,
            conflictReason = nil
        })
    end
    return previews
end

-- ============================================================================
-- UI HELPERS
-- ============================================================================

local function updateUIVisibility(win, itm, operation, extraSections)
    local sections = {
        {element = itm.ReplaceTextGroup, hidden = (operation ~= "Replace Text")},
        {element = itm.AddTextGroup, hidden = (operation ~= "Add Text")},
        {element = itm.FormatGroup, hidden = (operation ~= "Format")},
        -- "Set to Filename" hides all input groups (no additional UI needed)
    }
    for _, s in ipairs(extraSections or {}) do
        table.insert(sections, s)
    end

    if not utils.toggleDialogSections(win, CONFIG.DIALOG_WIDTH, sections) then
        win:Resize({CONFIG.DIALOG_WIDTH, CONFIG.DIALOG_FALLBACK_HEIGHT})
        win:RecalcLayout()
    end
end

local function getParamsFromUI(itm, operation)
    local params = {}

    if operation == "Replace Text" then
        params.findText = itm.FindText.Text
        params.replaceWith = itm.ReplaceWith.Text
    elseif operation == "Add Text" then
        params.textToAdd = itm.TextToAdd.Text
        params.position = (itm.AddPosition.CurrentIndex == 0) and "after" or "before"
    elseif operation == "Format" then
        params.formatString = itm.FormatString.Text
        if params.formatString == "" then
            params.formatString = CONFIG.DEFAULT_PATTERN
        end
    end

    return params
end

-- ============================================================================
-- UI CREATION
-- ============================================================================

local function createRenameDialog(ui, disp)
    local dialog = disp:AddWindow({
        ID = "BatchRenameWin",
        WindowTitle = SCRIPT_INFO.NAME,
        WindowFlags = utils.getDialogFlags(),
        StyleSheet = STYLES.WINDOW,
        Events = {
            Close = true,
        },
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

                ui:VGap(24),

                -- Mode Toggle Buttons
                ui:HGroup{
                    Weight = 0,
                    Spacing = 0,
                    ui:Button{
                        ID = "ClipsToggle",
                        Text = "Clips",
                        Weight = 1,
                        MinimumSize = {162, 40},
                        StyleSheet = STYLES.TOGGLE_ACTIVE,
                    },

                    ui:HGap(6),

                    ui:Button{
                        ID = "TimelinesToggle",
                        Text = "Timelines",
                        Weight = 1,
                        MinimumSize = {162, 40},
                        StyleSheet = STYLES.TOGGLE_INACTIVE,
                    },
                },

                ui:VGap(28),

                -- Operation Type Selection
                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Text = "Operation:",
                        Font = ui:Font{PixelSize = 12},
                        MinimumSize = {110, 20},
                    },
                    ui:ComboBox{
                        ID = "OperationType",
                        MinimumSize = {220, 33},
                    },
                },

                ui:VGap(9),

                -- Replace Text UI
                ui:VGroup{
                    ID = "ReplaceTextGroup",
                    Weight = 0,

                    ui:HGroup{
                        Weight = 0,
                        ui:Label{
                            Text = "Find:",
                            Font = ui:Font{PixelSize = 12},
                            MinimumSize = {110, 20},
                        },
                        ui:LineEdit{
                            ID = "FindText",
                            MinimumSize = {220, 38},
                            PlaceholderText = "Text to find",
                            StyleSheet = STYLES.INPUT,
                        },
                    },
                    ui:VGap(3),
                    ui:HGroup{
                        Weight = 0,
                        ui:Label{
                            Text = "Replace with:",
                            Font = ui:Font{PixelSize = 12},
                            MinimumSize = {110, 20},
                        },
                        ui:LineEdit{
                            ID = "ReplaceWith",
                            MinimumSize = {220, 38},
                            PlaceholderText = "Replacement text",
                            StyleSheet = STYLES.INPUT,
                        },
                    },
                },

                -- Add Text UI
                ui:VGroup{
                    ID = "AddTextGroup",
                    Weight = 0,
                    Hidden = true,

                    ui:HGroup{
                        Weight = 0,
                        ui:Label{
                            Text = "Text:",
                            Font = ui:Font{PixelSize = 12},
                            MinimumSize = {110, 20},
                        },
                        ui:LineEdit{
                            ID = "TextToAdd",
                            MinimumSize = {220, 38},
                            PlaceholderText = "Text to add",
                            StyleSheet = STYLES.INPUT,
                        },
                    },
                    ui:VGap(3),
                    ui:HGroup{
                        Weight = 0,
                        ui:Label{
                            Text = "Position:",
                            Font = ui:Font{PixelSize = 12},
                            MinimumSize = {110, 20},
                        },
                        ui:ComboBox{
                            ID = "AddPosition",
                            MinimumSize = {220, 33},
                        },
                    },
                },

                -- Format UI
                ui:VGroup{
                    ID = "FormatGroup",
                    Weight = 0,
                    Hidden = true,

                    ui:Label{
                        Text = "Format:",
                        Font = ui:Font{PixelSize = 12},
                        Weight = 0,
                    },

                    ui:VGap(3),

                    ui:LineEdit{
                        ID = "FormatString",
                        Text = CONFIG.DEFAULT_PATTERN,
                        PlaceholderText = "e.g., {name}_{counter}",
                        MinimumSize = {330, 38},
                        StyleSheet = STYLES.INPUT,
                        Weight = 0,
                    },

                    -- Common token buttons (row 1)
                    ui:HGroup{
                        ID = "CommonTokensRow",
                        Weight = 0,
                        Spacing = 4,
                        ui:Button{
                            ID = "TokenName",
                            Text = "name",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                        ui:Button{
                            ID = "TokenCounter",
                            Text = "counter",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                        ui:Button{
                            ID = "TokenIndex",
                            Text = "index",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                        ui:Button{
                            ID = "TokenDate",
                            Text = "date",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                    },

                    -- Timeline-specific tokens (row 2)
                    ui:HGroup{
                        ID = "TimelineTokensRow",
                        Weight = 0,
                        Spacing = 4,
                        Hidden = true,  -- Hidden by default (Clips mode is default)
                        ui:Button{
                            ID = "TokenResolution",
                            Text = "resolution",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                        ui:Button{
                            ID = "TokenFramerate",
                            Text = "framerate",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                    },

                    -- Clip-specific tokens (row 2 alternative)
                    ui:HGroup{
                        ID = "ClipTokensRow",
                        Weight = 0,
                        Spacing = 4,
                        -- Visible by default (Clips mode is default)
                        ui:Button{
                            ID = "TokenClipResolution",
                            Text = "resolution",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                        ui:Button{
                            ID = "TokenClipFramerate",
                            Text = "framerate",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                        ui:Button{
                            ID = "TokenExtension",
                            Text = "extension",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                    },

                    -- Format preview
                    ui:Label{
                        ID = "FormatPreview",
                        Text = "",
                        Font = ui:Font{PixelSize = 11},
                        StyleSheet = "color: " .. COLORS.textHint .. "; padding-top: 2px;",
                        Weight = 0,
                    },
                },

                ui:VGap(16),

                -- Clone checkbox (Timelines only)
                ui:CheckBox{
                    ID = "CloneCheckbox",
                    Text = "Clone with new name (keep originals)",
                    Font = ui:Font{PixelSize = 11},
                    Checked = false,
                    Hidden = true,  -- Hidden by default (Clips mode is default)
                },

                ui:VGap(8),

                -- Rename button
                ui:Button{
                    ID = "ActionButton",
                    Text = "Rename",
                    MinimumSize = {330, 45},
                    Font = ui:Font{PixelSize = 12},
                    StyleSheet = STYLES.BUTTON_PRIMARY,
                },

                -- Undo button (hidden by default, shown when undo data exists)
                ui:Button{
                    ID = "UndoButton",
                    Text = "Undo",
                    MinimumSize = {330, 45},
                    Font = ui:Font{PixelSize = 12},
                    StyleSheet = STYLES.BUTTON_TERTIARY_SPACED,
                    Hidden = true,
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

    -- Get UI elements
    local itm = dialog:GetItems()

    -- Setup operation type combo (Clips mode includes "Set to Filename")
    itm.OperationType:AddItems(CONFIG.OPERATIONS.Clips)
    itm.OperationType.CurrentIndex = 0

    -- Setup position combo for Add Text
    itm.AddPosition:AddItems({"after name", "before name"})
    itm.AddPosition.CurrentIndex = 0

    return dialog, itm
end

-- ============================================================================
-- APPLY CHANGES
-- ============================================================================

-- Apply previews for either mode: timelines (rename or clone) and clips
-- (rename). Clip previews always carry clipItem and hasConflict = false.
local function applyChanges(previews, isCloneMode)
    local successCount = 0
    local skipCount = 0
    local failCount = 0
    local errors = {}

    for i, preview in ipairs(previews) do
        if preview.oldName == preview.newName then
            skipCount = skipCount + 1
            print(string.format("  [%d/%d] Skipped (no change): %s", i, #previews, preview.oldName))
        elseif preview.hasConflict then
            failCount = failCount + 1
            print(string.format("  [%d/%d] Skipped (conflict): %s -> %s", i, #previews, preview.oldName, preview.newName))
        else
            local success = false
            local errorMsg = nil

            if isCloneMode then
                if not preview.timeline then
                    errorMsg = "Timeline object not found in project"
                else
                    local newTimeline = preview.timeline:DuplicateTimeline(preview.newName)
                    if newTimeline then
                        success = true
                        print(string.format("  [%d/%d] Cloned: %s -> %s", i, #previews, preview.oldName, preview.newName))
                    else
                        errorMsg = "DuplicateTimeline failed"
                    end
                end
            else
                success = preview.clipItem:SetName(preview.newName)
                if success then
                    print(string.format("  [%d/%d] Renamed: %s -> %s", i, #previews, preview.oldName, preview.newName))
                else
                    errorMsg = "SetName failed"
                end
            end

            if success then
                successCount = successCount + 1
            else
                failCount = failCount + 1
                table.insert(errors, {
                    oldName = preview.oldName,
                    newName = preview.newName,
                    error = errorMsg
                })
                print(string.format("  [%d/%d] FAILED: %s -> %s (%s)", i, #previews, preview.oldName, preview.newName, errorMsg))
            end
        end
    end

    return successCount, skipCount, failCount, errors
end

-- ============================================================================
-- MAIN SCRIPT
-- ============================================================================

local function main()
    -- Initialize Resolve with UI
    local ctx, err = utils.initializeWithUI(SCRIPT_INFO)
    if not ctx then
        print("ERROR: " .. (err or "Could not initialize Resolve"))
        return
    end

    local project = ctx.project
    local mediaPool = ctx.mediaPool
    local ui = ctx.ui
    local dispatcher = ctx.dispatcher

    utils.printHeader(SCRIPT_INFO.NAME .. " v" .. SCRIPT_INFO.VERSION)
    print()

    -- Create dialog
    local dialog, itm = createRenameDialog(ui, dispatcher)

    -- State (Clips is default mode)
    local currentMode = "Clips"
    local currentOperation = "Replace Text"
    local isCloneMode = false

    -- Undo state
    local undoData = nil      -- Stores {mode, items: [{uniqueId, originalName}]}
    local canUndo = false     -- Tracks if undo is available

    -- Helper to show/hide undo button and resize window accordingly
    local function setUndoVisible(visible)
        canUndo = visible
        updateUIVisibility(dialog, itm, currentOperation, {
            {element = itm.UndoButton, hidden = not visible},
        })
    end

    -- Get first selected item for preview and count of matching items (fetches
    -- fresh from media pool). Deliberately lazy - this runs per keystroke, so
    -- only the first matching record is materialized while the rest are counted
    local function getFirstSelectedItemForPreview()
        local selectedClips = mediaPool:GetSelectedClips()
        if not selectedClips or #selectedClips == 0 then
            return nil, 0
        end

        local timelineLookup = (currentMode == "Timelines") and buildTimelineLookup(project) or nil

        -- Find first matching item and count all matching items
        local firstItem = nil
        local matchCount = 0

        -- Counting only needs "Type", so the loop stays on the cheap per-key
        -- read; the full dict is fetched once, for the record that is built
        for _, clip in ipairs(selectedClips) do
            local clipType = clip:GetClipProperty("Type")

            if currentMode == "Timelines" and clipType == "Timeline" then
                matchCount = matchCount + 1
                if not firstItem then
                    firstItem = makeTimelineRecord(clip, timelineLookup, clip:GetClipProperty() or {})
                end
            elseif currentMode == "Clips" and clipType ~= "Timeline" then
                matchCount = matchCount + 1
                if not firstItem then
                    firstItem = makeClipRecord(clip, clip:GetClipProperty() or {})
                end
            end
        end

        return firstItem, matchCount
    end

    -- Update mode-specific UI
    local function updateModeUI()
        local isTimelinesMode = (currentMode == "Timelines")

        if not isTimelinesMode then
            itm.CloneCheckbox.Checked = false
            isCloneMode = false
        end

        -- Clone checkbox and mode-specific tokens toggle with the window refit
        updateUIVisibility(dialog, itm, currentOperation, {
            {element = itm.CloneCheckbox, hidden = not isTimelinesMode},
            {element = itm.TimelineTokensRow, hidden = not isTimelinesMode},
            {element = itm.ClipTokensRow, hidden = isTimelinesMode},
        })
    end

    -- Update format preview
    local function updateFormatPreview()
        if currentOperation == "Format" then
            local item, itemCount = getFirstSelectedItemForPreview()
            if item then
                local params = getParamsFromUI(itm, "Format")

                local metadata = { dateCreated = item.dateCreated }
                if currentMode == "Timelines" and item.timeline then
                    local width = item.timeline:GetSetting("timelineResolutionWidth")
                    local height = item.timeline:GetSetting("timelineResolutionHeight")
                    local fps = item.timeline:GetSetting("timelineFrameRate")
                    if width and height then
                        metadata.resolution = width .. "x" .. height
                    end
                    if fps then
                        metadata.framerate = fps .. "fps"
                    end
                else
                    metadata.extension = item.extension or ""
                    metadata.resolution = item.resolution or ""
                    metadata.framerate = item.framerate or ""
                end

                local totalCount = (itemCount > 0) and itemCount or 1
                local example = applyRenameOperation(item.name, "Format", params, 1, totalCount, metadata)
                local displayPreview = utils.truncatePreview(example, CONFIG.PREVIEW_MAX_LENGTH)
                itm.FormatPreview.Text = "-> " .. displayPreview
            else
                itm.FormatPreview.Text = ""
            end
        end
    end

    -- Helper to insert token at the cursor position in the format field
    local function insertToken(token)
        itm.FormatString:Insert("{" .. token .. "}")
        updateFormatPreview()
    end

    -- Helper to update toggle button styles
    local function updateToggleStyles()
        if currentMode == "Clips" then
            itm.ClipsToggle.StyleSheet = STYLES.TOGGLE_ACTIVE
            itm.TimelinesToggle.StyleSheet = STYLES.TOGGLE_INACTIVE
        else
            itm.ClipsToggle.StyleSheet = STYLES.TOGGLE_INACTIVE
            itm.TimelinesToggle.StyleSheet = STYLES.TOGGLE_ACTIVE
        end
    end

    -- Helper to switch mode
    local function switchMode(newMode)
        if currentMode == newMode then return end

        local oldMode = currentMode
        currentMode = newMode

        -- If switching to Timelines and "Set to Filename" is selected, switch to "Replace Text"
        if newMode == "Timelines" and currentOperation == "Set to Filename" then
            currentOperation = "Replace Text"
            -- Update operation dropdown for Timelines mode (no "Set to Filename")
            itm.OperationType:Clear()
            itm.OperationType:AddItems(CONFIG.OPERATIONS.Timelines)
            itm.OperationType.CurrentIndex = 0
        elseif newMode == "Clips" and oldMode == "Timelines" then
            -- Update operation dropdown for Clips mode (includes "Set to Filename")
            local currentIndex = itm.OperationType.CurrentIndex
            itm.OperationType:Clear()
            itm.OperationType:AddItems(CONFIG.OPERATIONS.Clips)
            itm.OperationType.CurrentIndex = currentIndex
        end

        -- Clear undo if mode changed (undo data is mode-specific)
        if undoData and undoData.mode ~= currentMode then
            undoData = nil
            setUndoVisible(false)
        end

        updateToggleStyles()
        updateModeUI()
        updateFormatPreview()
    end

    -- Event handlers for toggle buttons
    function dialog.On.ClipsToggle.Clicked(ev)
        switchMode("Clips")
    end

    function dialog.On.TimelinesToggle.Clicked(ev)
        switchMode("Timelines")
    end

    function dialog.On.CloneCheckbox.Clicked(ev)
        isCloneMode = itm.CloneCheckbox.Checked
    end

    function dialog.On.OperationType.CurrentIndexChanged(ev)
        local newOperation = CONFIG.OPERATIONS[currentMode][ev.Index + 1]
        -- Mode switches rebuild this combo programmatically (Clear/AddItems/
        -- CurrentIndex), which echoes this event with an invalid index and then
        -- with the restored one; reacting to those hides and re-shows the
        -- operation fields for a frame. Only genuine operation changes proceed.
        if not newOperation or newOperation == currentOperation then
            return
        end
        currentOperation = newOperation
        updateUIVisibility(dialog, itm, currentOperation)
        updateFormatPreview()
    end

    -- Token button handlers
    function dialog.On.TokenName.Clicked(ev) insertToken("name") end
    function dialog.On.TokenCounter.Clicked(ev) insertToken("counter") end
    function dialog.On.TokenIndex.Clicked(ev) insertToken("index") end
    function dialog.On.TokenDate.Clicked(ev) insertToken("date") end
    function dialog.On.TokenResolution.Clicked(ev) insertToken("resolution") end
    function dialog.On.TokenFramerate.Clicked(ev) insertToken("framerate") end
    function dialog.On.TokenExtension.Clicked(ev) insertToken("extension") end
    function dialog.On.TokenClipResolution.Clicked(ev) insertToken("resolution") end
    function dialog.On.TokenClipFramerate.Clicked(ev) insertToken("framerate") end

    function dialog.On.FormatString.TextChanged(ev)
        updateFormatPreview()
    end

    utils.attachFooterHandler(dialog)

    -- Operation body (run via runWithDialogBusy so the dialog greys out and
    -- drops clicks while the Resolve API work runs)
    local function doAction()
        -- Special handling for "Set to Filename" operation
        if currentOperation == "Set to Filename" then
            utils.printSection("Setting Clips to Original Filename")

            local results, setFilenameErr = renameClipsToOriginalFilename(mediaPool)
            if not results then
                print("Error: " .. (setFilenameErr or "Unknown error"))
                return
            end

            -- Note: Undo is not available for "Set to Filename" operation
            -- because we don't track original names before this operation

            -- Print summary
            utils.printSeparator()
            if results.success > 0 then
                print(string.format("Successfully renamed: %d clip(s)", results.success))
            end
            if results.skipped > 0 then
                print(string.format("Skipped: %d item(s)", results.skipped))
            end
            if results.failed > 0 then
                print(string.format("Failed: %d clip(s)", results.failed))
                if #results.errors > 0 then
                    print("\nErrors:")
                    for _, e in ipairs(results.errors) do
                        print(string.format("  %s -> %s: %s", e.oldName, e.targetName, e.error))
                    end
                end
            end
            print()
            return
        end

        -- Collect fresh selection from media pool
        local timelines, clips, selectionErr = splitSelectedItems(project, mediaPool)

        if selectionErr then
            print("Error: " .. selectionErr)
            return
        end

        local items
        local itemTypeName
        if currentMode == "Timelines" then
            items = timelines
            itemTypeName = "timeline"
        else
            items = clips
            itemTypeName = "clip"
        end

        if not items or #items == 0 then
            print(string.format("No %ss selected. Please select %ss in the Media Pool.", itemTypeName, itemTypeName))
            return
        end

        local params = getParamsFromUI(itm, currentOperation)
        local previews

        if currentMode == "Timelines" then
            -- Get existing timeline names for conflict detection
            local existingTimelineNames = getExistingTimelineNames(project)
            local selectedTimelineNames = {}
            for _, timelineInfo in ipairs(timelines) do
                selectedTimelineNames[timelineInfo.name] = true
            end

            previews = generateTimelinesPreview(timelines, currentOperation, params)
            local conflicts = checkForConflicts(previews, existingTimelineNames, isCloneMode, selectedTimelineNames)

            -- Block operation if any timeline conflicts exist
            if #conflicts > 0 then
                print()
                utils.printError("Cannot rename - the new names would collide:")
                for _, conflict in ipairs(conflicts) do
                    local detail
                    if conflict.conflictReason == "Name already exists" then
                        detail = "a timeline with this name already exists in the project"
                    elseif conflict.conflictReason == "Duplicate in selection" then
                        detail = "two or more selected timelines would share this name"
                    else
                        detail = conflict.conflictReason or "name conflict"
                    end
                    print(string.format("  %s -> %s  (%s)", conflict.oldName, conflict.newName, detail))
                end
                print("\nFix: adjust the rename pattern or deselect the conflicting timelines, then try again.")
                return
            end
        else
            previews = generateClipsPreview(clips, currentOperation, params)

            -- Get existing clip names for duplicate detection
            local existingClipNames = getAllClipNames(mediaPool)
            local selectedClipNames = {}
            for _, clip in ipairs(clips) do
                selectedClipNames[clip.name] = true
            end

            -- Check for duplicate clip names
            if checkClipDuplicates(previews, existingClipNames, selectedClipNames) then
                local shouldContinue = showClipDuplicateWarning(ui, dispatcher)
                if not shouldContinue then
                    print("Operation cancelled by user.")
                    return
                end
            end
        end

        -- Count actual changes
        local changeCount = 0
        for _, p in ipairs(previews) do
            if p.oldName ~= p.newName and not p.hasConflict then
                changeCount = changeCount + 1
            end
        end

        if changeCount == 0 then
            print("No changes to apply.")
            return
        end

        local action = (currentMode == "Timelines" and isCloneMode) and "Cloning" or "Renaming"
        local itemType = currentMode == "Timelines" and "Timelines" or "Clips"
        utils.printSection(action .. " " .. itemType)

        -- Collect undo data before renaming (not for clone operations)
        local undoItems = {}
        if not isCloneMode then
            for _, preview in ipairs(previews) do
                if preview.oldName ~= preview.newName and not preview.hasConflict then
                    table.insert(undoItems, {
                        uniqueId = preview.clipItem:GetUniqueId(),
                        originalName = preview.oldName
                    })
                end
            end
        end

        local successCount, skipCount, failCount, errors =
            applyChanges(previews, currentMode == "Timelines" and isCloneMode)

        -- Save undo data and show button (only for rename, not clone)
        if successCount > 0 and not isCloneMode and #undoItems > 0 then
            undoData = { mode = currentMode, items = undoItems }
            saveUndoData(undoData)
            setUndoVisible(true)
        end

        -- Print summary
        utils.printSeparator()
        local actionPast = (currentMode == "Timelines" and isCloneMode) and "cloned" or "renamed"
        if successCount > 0 then
            print(string.format("Successfully %s: %d %s(s)", actionPast, successCount, itemTypeName))
        end
        if skipCount > 0 then
            print(string.format("Skipped: %d %s(s)", skipCount, itemTypeName))
        end
        if failCount > 0 then
            print(string.format("Failed: %d %s(s)", failCount, itemTypeName))
            if #errors > 0 then
                print("\nErrors:")
                for _, e in ipairs(errors) do
                    print(string.format("  %s -> %s: %s", e.oldName, e.newName, e.error))
                end
            end
        end
        print()
    end

    local function doUndo()
        if not canUndo or not undoData or not undoData.items then return end

        utils.printSection("Undoing Rename")

        local restoredCount = 0
        local failCount = 0

        -- Build lookup for finding items by unique ID
        -- Scan all clips in media pool (since selection may have changed)
        local clipsByUniqueId = {}
        for _, clip in ipairs(utils.collectClips(mediaPool:GetRootFolder())) do
            local uid = clip:GetUniqueId()
            if uid then clipsByUniqueId[uid] = clip end
        end

        for _, item in ipairs(undoData.items) do
            local clip = clipsByUniqueId[item.uniqueId]
            if clip then
                local currentName = clip:GetName()
                local success = clip:SetName(item.originalName)
                if success then
                    restoredCount = restoredCount + 1
                    print(string.format("  Restored: %s -> %s", currentName, item.originalName))
                else
                    failCount = failCount + 1
                    print(string.format("  FAILED: Could not restore %s", item.originalName))
                end
            else
                failCount = failCount + 1
                print(string.format("  FAILED: Item not found (ID: %s)", item.uniqueId))
            end
        end

        -- Print summary
        utils.printSeparator()
        print(string.format("Restored: %d item(s)", restoredCount))
        if failCount > 0 then
            print(string.format("Failed: %d item(s)", failCount))
        end

        -- Hide undo button and clear data
        clearUndoData()
        undoData = nil
        setUndoVisible(false)
        print()
    end

    function dialog.On.ActionButton.Clicked(ev)
        utils.runWithDialogBusy(dialog, doAction)
    end

    function dialog.On.UndoButton.Clicked(ev)
        utils.runWithDialogBusy(dialog, doUndo)
    end

    function dialog.On.BatchRenameWin.Close(ev)
        dispatcher:ExitLoop()
    end

    -- Pre-lay-out hidden sections while the window is still hidden so their
    -- first reveal doesn't paint a frame at unpositioned coordinates
    utils.prewarmDialogSections(dialog, {
        itm.AddTextGroup,
        itm.FormatGroup,
        itm.UndoButton,
        itm.CloneCheckbox,
        itm.TimelineTokensRow,
        itm.ClipTokensRow,
    })

    -- Initial UI setup
    updateModeUI()

    -- Check for existing undo data from previous session
    undoData = loadUndoData()
    if undoData and undoData.mode == currentMode and undoData.items and #undoData.items > 0 then
        setUndoVisible(true)
    else
        undoData = nil
        -- canUndo is already false, button is already hidden
    end

    -- Show dialog
    dialog:RecalcLayout()
    utils.centerDialogOnScreen(dialog, ui, dispatcher)
    dialog:Show()
    dispatcher:RunLoop()
    clearUndoData()
    dialog:Hide()

    utils.printSeparator()
    print("Script completed!")
end

-- Run main function
main()
