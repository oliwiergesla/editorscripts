local SCRIPT_INFO = {
    NAME = "Markers to Stills",
    VERSION = "1.0.3",
    MIN_RESOLVE = "20.0",
}

-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[

    Markers to Stills

    Batch exports still frames at marker positions from selected timelines,
    to disk or to the current Color page gallery album.

    Features:
        - Filters timeline and clip markers by color, with deduplication
        - Exports PNG, JPEG, TIFF, DPX, or EXR (JPEG quality control on macOS)
        - Customizable filename patterns with tokens
        - Per-timeline subfolders and progress window for batch runs

    Usage:
        1. Select one or more timelines in the Media Pool
        2. Run the script from Workspace -> Scripts
        3. Choose marker source, color filter, and export format
        4. Expand "Options" to configure filename pattern and settings
        5. Click "Export" (choose output directory) or "Add to Gallery"

--]]

local utils = require("ResolveKit")
local STYLES, COLORS = utils.STYLES, utils.COLORS

-- Modifier key state tracking (updated by KeyPress/KeyRelease events)
-- utils.KEY_CODES comes from the platform module
local modifiers = {
    cmd = false,
    shift = false,
}

local CONFIG = {
    MARKER_SOURCES = {
        "Timeline Markers",
        "Clip Markers",
        "Both"
    },

    -- Marker palette in Resolve's menu order (markers/flags use a different palette than clip colors — no Orange here)
    MARKER_COLORS = {
        "All Colors",
        "Blue", "Cyan", "Green", "Yellow", "Red", "Pink", "Purple", "Fuchsia",
        "Rose", "Lavender", "Sky", "Mint", "Lemon", "Sand", "Cocoa", "Cream"
    },

    EXPORT_FORMATS = {
        "PNG",
        "JPEG",
        "TIFF",
        "DPX",
        "EXR"
    },

    DEFAULT_PATTERN = "{timeline}_{frame}",
    DEFAULT_JPEG_QUALITY = 85,
    DIALOG_WIDTH = 420,

    DIALOG_FALLBACK_HEIGHT = 440,       -- only used if fitDialogHeight fails

    -- Preview truncation
    PREVIEW_MAX_LENGTH = 60,            -- Max chars for filename preview (excluding "→ " prefix)
}


-- Settings key for persisting user preferences
local SETTINGS_KEY = "exportStillsFromMarkers"

-- ============================================================================
-- SETTINGS AND USER DEFAULTS
-- ============================================================================

-- Get script's hardcoded defaults
local function getScriptDefaults()
    return {
        sourceIndex = 0,
        colorIndex = 0,
        formatIndex = 0,
        pattern = CONFIG.DEFAULT_PATTERN,
        createSubfolders = true,
        overwrite = false,
        openFolderAfterExport = true,
        jpegQuality = CONFIG.DEFAULT_JPEG_QUALITY
    }
end

-- Load saved preferences for this script
-- Returns: { current = {...}, userDefaults = {...} or nil }
local function loadPreferences()
    local settings = utils.loadSettings() or {}
    local scriptPrefs = settings[SETTINGS_KEY] or {}

    -- Handle migration from old flat structure to new nested structure
    if scriptPrefs.sourceIndex ~= nil and scriptPrefs.current == nil then
        -- Old format: migrate to new format
        return {
            current = scriptPrefs,
            userDefaults = nil
        }
    end

    return {
        current = scriptPrefs.current or {},
        userDefaults = scriptPrefs.userDefaults  -- nil if not set
    }
end

-- Save current preferences
local function savePreferences(currentPrefs)
    local settings = utils.loadSettings() or {}
    local existing = settings[SETTINGS_KEY] or {}

    -- Preserve userDefaults when saving current prefs
    settings[SETTINGS_KEY] = {
        current = currentPrefs,
        userDefaults = existing.userDefaults
    }
    utils.saveSettings(settings)
end

-- Get effective defaults (user defaults if set, otherwise script defaults)
local function getEffectiveDefaults()
    local prefs = loadPreferences()
    if prefs.userDefaults then
        return prefs.userDefaults
    end
    return getScriptDefaults()
end

-- Save current UI state as user defaults
local function saveAsUserDefaults(currentPrefs)
    local settings = utils.loadSettings() or {}
    local existing = settings[SETTINGS_KEY] or {}

    settings[SETTINGS_KEY] = {
        current = existing.current or currentPrefs,
        userDefaults = currentPrefs
    }
    utils.saveSettings(settings)
    utils.printSuccess("Current settings saved as your defaults")
end

-- Clear user defaults (revert to script defaults)
local function clearUserDefaults()
    local settings = utils.loadSettings() or {}
    if settings[SETTINGS_KEY] then
        settings[SETTINGS_KEY].userDefaults = nil
        utils.saveSettings(settings)
    end
    utils.printSuccess("Custom defaults cleared - using script defaults")
end

-- Both halves of the settings toggle row share borders and hover color so
-- the divider lines run continuously and the two parts read as one control;
-- they differ only in text color/alignment/size
local function settingsRowStyle(color, align, fontSize)
    return [[
    QPushButton {
        background-color: transparent;
        border-top: 1px solid ]] .. COLORS.divider .. [[;
        border-bottom: 1px solid ]] .. COLORS.divider .. [[;
        border-left: none;
        border-right: none;
        padding: 4px 0px;
        color: ]] .. color .. [[;
        text-align: ]] .. align .. [[;
        font-size: ]] .. fontSize .. [[px;
    }
    QPushButton:hover {
        color: ]] .. COLORS.textHover .. [[;
    }
    QPushButton:pressed {
        color: ]] .. COLORS.textSubtle .. [[;
    }
]]
end

local SETTINGS_TOGGLE_STYLE = settingsRowStyle(COLORS.textDim, "left", 12)
local SETTINGS_HINT_STYLE = settingsRowStyle(COLORS.textMuted, "right", 10)

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Get clip markers from all clips on the timeline
-- Returns markers that are within the visible portion of each clip, with frame positions
-- converted to absolute timeline frames
local function getClipMarkersFromTimeline(timeline, colorFilter)
    local clipMarkers = {}
    local trackCount = timeline:GetTrackCount("video")

    for trackIdx = 1, trackCount do
        local clips = timeline:GetItemListInTrack("video", trackIdx)
        if clips then
            for _, timelineItem in ipairs(clips) do
                local markers = timelineItem:GetMarkers()
                if markers and next(markers) then
                    -- Cache clip properties (avoid repeated API calls per marker)
                    local clipStart = timelineItem:GetStart()
                    local sourceInPoint = timelineItem:GetLeftOffset()
                    local clipDuration = timelineItem:GetDuration()
                    local clipName = timelineItem:GetName() or "Clip"

                    -- Some item types (e.g. generators/titles) return nil source
                    -- geometry; their markers can't be mapped to timeline frames
                    if clipStart and sourceInPoint and clipDuration then
                        local sourceOutPoint = sourceInPoint + clipDuration

                        for markerFrame, markerInfo in pairs(markers) do
                            -- Filter by color and visibility
                            local isVisible = markerFrame >= sourceInPoint and markerFrame < sourceOutPoint
                            local colorMatch = colorFilter == "All Colors" or markerInfo.color == colorFilter

                            if isVisible and colorMatch then
                                -- Convert source frame to timeline frame
                                local timelineFrame = clipStart + (markerFrame - sourceInPoint)
                                table.insert(clipMarkers, {
                                    frame = timelineFrame,
                                    info = markerInfo,
                                    clipName = clipName,
                                    isClipMarker = true
                                })
                            end
                        end
                    else
                        utils.printStatus("WARN", clipName .. ": clip markers skipped (item has no source offset)")
                    end
                end
            end
        end
    end

    return clipMarkers
end

local function generateFilename(pattern, timelineName, markerName, frameNum, markerColor, timecode, isClipMarker)
    -- applyTokens does one substitution pass, so '%' or '{token}' text inside
    -- marker/timeline names is emitted literally instead of corrupting output
    local filename = utils.applyTokens(pattern, {
        timeline = timelineName or "timeline",
        marker = markerName or "marker",
        frame = tostring(frameNum),
        color = markerColor or "",
        source = isClipMarker and "clip" or "timeline",
        timecode = timecode and timecode:gsub(":", "-") or string.format("F%d", frameNum),
    })

    return utils.sanitizeFilename(filename)
end

-- Compress JPEG using macOS sips tool
-- Returns true on success, false and error message on failure
local function compressJpegWithSips(filePath, quality)
    -- sips overwrites the file in place when input and output are the same
    local cmd = string.format('sips -s formatOptions %d %s 2>/dev/null', quality, utils.shellQuote(filePath))
    local result = os.execute(cmd)

    if result == 0 or result == true then
        return true
    else
        return false, "sips compression failed"
    end
end

-- Show options dialog
-- savedPrefs: optional table of saved preferences to restore
local function showOptionsDialog(ui, dispatcher, savedPrefs, runExport)
    savedPrefs = savedPrefs or {}

    -- Track collapsible section states
    local settingsExpanded = false  -- Always start collapsed: a section revealed before its first layout paints at unpositioned coordinates
    local jpegQualityVisible = false  -- Shown only when JPEG format selected

    -- Create dialog window with keyboard events enabled for modifier key detection
    local dialog = dispatcher:AddWindow({
        ID = 'ExportStillsDialog',
        WindowTitle = SCRIPT_INFO.NAME,
        WindowFlags = utils.getDialogFlags(),
        StyleSheet = STYLES.WINDOW,
        Events = {
            Close = true,
            KeyPress = true,
            KeyRelease = true,
        },
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

                -- Marker source selection
                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Text = "Marker Source:",
                        Font = ui:Font{PixelSize = 12},
                        MinimumSize = {110, 20},
                    },
                    ui:ComboBox{
                        ID = "SourceCombo",
                        MinimumSize = {220, 33},
                    },
                },

                ui:VGap(3),

                -- Marker color selection
                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Text = "Marker Color:",
                        Font = ui:Font{PixelSize = 12},
                        MinimumSize = {110, 20},
                    },
                    ui:ComboBox{
                        ID = "ColorCombo",
                        MinimumSize = {220, 33},
                    },
                },

                ui:VGap(3),

                -- Export format selection
                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Text = "Export Format:",
                        Font = ui:Font{PixelSize = 12},
                        MinimumSize = {110, 20},
                    },
                    ui:ComboBox{
                        ID = "FormatCombo",
                        MinimumSize = {220, 33},
                    },
                },

                ui:VGap(9),

                -- JPEG Quality slider (macOS only) - hidden until JPEG selected
                utils.IS_MACOS and ui:VGroup{
                    ID = "QualityContainer",
                    Weight = 0,
                    Hidden = true,  -- Start hidden, show when JPEG format selected

                    ui:HGroup{
                        Weight = 0,
                        ui:Label{
                            ID = "QualityLabelTitle",
                            Text = "JPEG Quality:",
                            Font = ui:Font{PixelSize = 12},
                            MinimumSize = {110, 20},
                        },
                        ui:HGroup{
                            MinimumSize = {220, 30},
                            MaximumSize = {220, 30},
                            Spacing = 10,
                            ui:Slider{
                                ID = "QualitySlider",
                                Minimum = 1,
                                Maximum = 100,
                                Value = CONFIG.DEFAULT_JPEG_QUALITY,
                                Orientation = "Horizontal",
                                MinimumSize = {185, 20},
                                StyleSheet = STYLES.SLIDER,
                                Tracking = true,
                            },
                            ui:Label{
                                ID = "QualityLabel",
                                Text = tostring(CONFIG.DEFAULT_JPEG_QUALITY),
                                Font = ui:Font{PixelSize = 12},
                                MinimumSize = {25, 20},
                            },
                        },
                    },

                    ui:VGap(9),  -- Spacing below quality row
                -- Placeholder must be a VGap: an HGap inside a VGroup caps the
                -- whole column's maximum width at 0 (Qt takes the min of child
                -- maximums on the cross axis), squeezing all content to its
                -- minimum width
                } or ui:VGap(0),

                ui:VGap(3),

                -- Settings toggle row (Options left, hint right; both toggle)
                ui:HGroup{
                    Weight = 0,
                    Spacing = 0,
                    ui:Button{
                        ID = "SettingsToggle",
                        Text = "Options",
                        Weight = 1,
                        MinimumSize = {220, 50},
                        StyleSheet = SETTINGS_TOGGLE_STYLE,
                        Flat = true,
                    },
                    ui:Button{
                        ID = "SettingsHint",
                        Text = "Click to expand",
                        Weight = 0,
                        MinimumSize = {110, 50},
                        StyleSheet = SETTINGS_HINT_STYLE,
                        Flat = true,
                    },
                },

                -- Collapsible settings container (filename + checkboxes)
                ui:VGroup{
                    ID = "SettingsContainer",
                    Weight = 0,
                    Hidden = not settingsExpanded,

                    ui:VGap(12),

                    -- Filename pattern label
                    ui:Label{
                        Text = "Filename:",
                        Font = ui:Font{PixelSize = 12},
                        Weight = 0,
                    },

                    ui:VGap(3),

                    -- Filename pattern input (full width)
                    ui:LineEdit{
                        ID = "PatternEdit",
                        Text = CONFIG.DEFAULT_PATTERN,
                        PlaceholderText = "e.g., {timeline}_{frame}",
                        MinimumSize = {330, 38},
                        StyleSheet = STYLES.INPUT,
                        Weight = 0,
                    },

                    -- Token buttons (single row)
                    ui:HGroup{
                        Weight = 0,
                        Spacing = 4,
                        ui:Button{
                            ID = "TokenTimeline",
                            Text = "timeline",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                        ui:Button{
                            ID = "TokenMarker",
                            Text = "marker",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                        ui:Button{
                            ID = "TokenFrame",
                            Text = "frame",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                        ui:Button{
                            ID = "TokenColor",
                            Text = "color",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                        ui:Button{
                            ID = "TokenTimecode",
                            Text = "timecode",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                        ui:Button{
                            ID = "TokenSource",
                            Text = "source",
                            StyleSheet = STYLES.BUTTON_TOKEN,
                        },
                    },

                    -- Filename preview (subtle subtext)
                    ui:Label{
                        ID = "PreviewLabel",
                        Text = "",
                        Font = ui:Font{PixelSize = 11},
                        StyleSheet = "color: " .. COLORS.textHint .. "; padding-top: 2px;",
                        Weight = 0,
                    },

                    ui:VGap(12),

                    -- Options checkboxes
                    ui:VGroup{
                        Weight = 0,
                        ui:CheckBox{
                            ID = "OpenFolderCheck",
                            Text = "Open folder after export",
                            Checked = true,
                            Font = ui:Font{PixelSize = 11},
                        },
                        ui:CheckBox{
                            ID = "SubfolderCheck",
                            Text = "Create subfolder for each timeline",
                            Checked = true,
                            Font = ui:Font{PixelSize = 11},
                        },
                        ui:CheckBox{
                            ID = "OverwriteCheck",
                            Text = "Overwrite existing files",
                            Checked = false,
                            Font = ui:Font{PixelSize = 11},
                        },
                    },
                    ui:VGap(3),
                },  -- closes SettingsContainer

                ui:VGap(16),

                -- Buttons: Top row (Export - full width)
                ui:HGroup{
                    Weight = 0,
                    ui:Button{
                        ID = "ExportButton",
                        Text = "Export",
                        MinimumSize = {325, 45},
                        Font = ui:Font{ PixelSize = 12 },
                        StyleSheet = STYLES.BUTTON_PRIMARY
                    },
                },

                ui:VGap(3),

                -- Buttons: Bottom row (Reset + Add to Gallery)
                ui:HGroup{
                    Weight = 0,
                    ui:Button{
                        ID = "ResetButton",
                        Text = "Reset",
                        MinimumSize = {155, 45},
                        Font = ui:Font{ PixelSize = 12 },
                        StyleSheet = STYLES.BUTTON_TERTIARY
                    },
                    ui:HGap(3),
                    ui:Button{
                        ID = "GalleryButton",
                        Text = "Add to Gallery",
                        MinimumSize = {155, 45},
                        Font = ui:Font{ PixelSize = 12 },
                        StyleSheet = STYLES.BUTTON_SECONDARY
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

    -- Get UI elements
    local sourceCombo = dialog:Find("SourceCombo")
    local colorCombo = dialog:Find("ColorCombo")
    local formatCombo = dialog:Find("FormatCombo")
    local patternEdit = dialog:Find("PatternEdit")
    local subfolderCheck = dialog:Find("SubfolderCheck")
    local overwriteCheck = dialog:Find("OverwriteCheck")
    local openFolderCheck = dialog:Find("OpenFolderCheck")
    local previewLabel = dialog:Find("PreviewLabel")
    local settingsHint = dialog:Find("SettingsHint")
    local settingsContainer = dialog:Find("SettingsContainer")
    local resetButton = dialog:Find("ResetButton")

    -- Quality elements only exist on macOS
    local qualityContainer, qualitySlider, qualityLabel
    if utils.IS_MACOS then
        qualityContainer = dialog:Find("QualityContainer")
        qualitySlider = dialog:Find("QualitySlider")
        qualityLabel = dialog:Find("QualityLabel")
    end

    -- Populate combo boxes
    sourceCombo:AddItems(CONFIG.MARKER_SOURCES)
    colorCombo:AddItems(CONFIG.MARKER_COLORS)
    formatCombo:AddItems(CONFIG.EXPORT_FORMATS)

    -- Apply saved preferences or use defaults
    sourceCombo.CurrentIndex = savedPrefs.sourceIndex or 0
    colorCombo.CurrentIndex = savedPrefs.colorIndex or 0
    formatCombo.CurrentIndex = savedPrefs.formatIndex or 0
    patternEdit.Text = savedPrefs.pattern or CONFIG.DEFAULT_PATTERN
    subfolderCheck.Checked = savedPrefs.createSubfolders ~= false  -- Default true
    overwriteCheck.Checked = savedPrefs.overwrite == true  -- Default false
    openFolderCheck.Checked = savedPrefs.openFolderAfterExport ~= false  -- Default true

    if utils.IS_MACOS and qualitySlider then
        qualitySlider.Value = savedPrefs.jpegQuality or CONFIG.DEFAULT_JPEG_QUALITY
        qualityLabel.Text = tostring(qualitySlider.Value)
    end

    -- ============================================================================
    -- MODIFIER KEY HANDLING
    -- ============================================================================

    -- Update Reset button text based on modifier key state
    local function updateResetButtonText()
        if modifiers.cmd and modifiers.shift then
            resetButton.Text = "Reset Defaults"
        elseif modifiers.cmd then
            resetButton.Text = "Set Default"
        else
            resetButton.Text = "Reset"
        end
    end

    -- KeyPress event handler - track when modifier keys are pressed
    function dialog.On.ExportStillsDialog.KeyPress(ev)
        if ev.Key == utils.KEY_CODES.CMD then
            modifiers.cmd = true
        elseif ev.Key == utils.KEY_CODES.SHIFT then
            modifiers.shift = true
        end
        updateResetButtonText()
    end

    -- KeyRelease event handler - track when modifier keys are released
    function dialog.On.ExportStillsDialog.KeyRelease(ev)
        if ev.Key == utils.KEY_CODES.CMD then
            modifiers.cmd = false
        elseif ev.Key == utils.KEY_CODES.SHIFT then
            modifiers.shift = false
        end
        updateResetButtonText()
    end

    -- Toggle settings visibility
    local function toggleSettings()
        settingsExpanded = not settingsExpanded
        settingsHint.Text = settingsExpanded and "" or "Click to expand"
        utils.toggleDialogSections(dialog, CONFIG.DIALOG_WIDTH, {
            {element = settingsContainer, hidden = not settingsExpanded},
        })
    end

    -- Update JPEG quality visibility and resize window
    local function updateQualityVisibility()
        if not utils.IS_MACOS then return end  -- Nothing to do on Windows/Linux

        local format = CONFIG.EXPORT_FORMATS[formatCombo.CurrentIndex + 1]
        local shouldShow = format == "JPEG"

        -- Only update if visibility changed
        if shouldShow ~= jpegQualityVisible then
            jpegQualityVisible = shouldShow
            utils.toggleDialogSections(dialog, CONFIG.DIALOG_WIDTH, {
                {element = qualityContainer, hidden = not shouldShow},
            })
        end
    end

    -- Update summary when selection changes
    local function updateSummary()
        local color = CONFIG.MARKER_COLORS[colorCombo.CurrentIndex + 1]
        local format = CONFIG.EXPORT_FORMATS[formatCombo.CurrentIndex + 1]
        local pattern = patternEdit.Text

        if pattern == "" then
            pattern = CONFIG.DEFAULT_PATTERN
        end

        local example = generateFilename(pattern, "TimelineName", "MarkerA", 1234, color, "01:02:03:14", false)
        local fullPreview = string.format("%s.%s", example, format:lower())
        local displayPreview = utils.truncatePreview(fullPreview, CONFIG.PREVIEW_MAX_LENGTH, true)
        previewLabel.Text = "→ " .. displayPreview
    end

    -- Helper to apply defaults to UI elements
    local function applyDefaults(defaults)
        sourceCombo.CurrentIndex = defaults.sourceIndex or 0
        colorCombo.CurrentIndex = defaults.colorIndex or 0
        formatCombo.CurrentIndex = defaults.formatIndex or 0
        patternEdit.Text = defaults.pattern or CONFIG.DEFAULT_PATTERN
        subfolderCheck.Checked = defaults.createSubfolders ~= false
        overwriteCheck.Checked = defaults.overwrite == true
        openFolderCheck.Checked = defaults.openFolderAfterExport ~= false
        if utils.IS_MACOS and qualitySlider then
            qualitySlider.Value = defaults.jpegQuality or CONFIG.DEFAULT_JPEG_QUALITY
            qualityLabel.Text = tostring(defaults.jpegQuality or CONFIG.DEFAULT_JPEG_QUALITY)
        end
        updateQualityVisibility()
        updateSummary()
    end

    -- Event handlers
    function dialog.On.SettingsToggle.Clicked(ev)
        toggleSettings()
    end

    function dialog.On.SettingsHint.Clicked(ev)
        toggleSettings()
    end

    function dialog.On.SourceCombo.CurrentIndexChanged(ev)
        updateSummary()
    end

    function dialog.On.ColorCombo.CurrentIndexChanged(ev)
        updateSummary()
    end

    function dialog.On.FormatCombo.CurrentIndexChanged(ev)
        updateQualityVisibility()
        updateSummary()
    end

    -- Slider events only exist on macOS (element doesn't exist on Windows/Linux)
    if utils.IS_MACOS then
        function dialog.On.QualitySlider.ValueChanged(ev)
            qualityLabel.Text = tostring(qualitySlider.Value)
            updateSummary()
        end

        -- SliderMoved fires continuously while dragging
        function dialog.On.QualitySlider.SliderMoved(ev)
            qualityLabel.Text = tostring(qualitySlider.Value)
            updateSummary()
        end
    end

    function dialog.On.PatternEdit.TextChanged(ev)
        updateSummary()
    end

    -- Helper function to insert token into pattern field at cursor position
    local function insertToken(token)
        patternEdit:Insert("{" .. token .. "}")
        updateSummary()
    end

    -- Token button handlers
    function dialog.On.TokenTimeline.Clicked(ev)
        insertToken("timeline")
    end

    function dialog.On.TokenMarker.Clicked(ev)
        insertToken("marker")
    end

    function dialog.On.TokenFrame.Clicked(ev)
        insertToken("frame")
    end

    function dialog.On.TokenColor.Clicked(ev)
        insertToken("color")
    end

    function dialog.On.TokenTimecode.Clicked(ev)
        insertToken("timecode")
    end

    function dialog.On.TokenSource.Clicked(ev)
        insertToken("source")
    end

    -- Helper to get current UI state as preferences
    local function getCurrentPrefs()
        local pattern = patternEdit.Text
        if pattern == "" then
            pattern = CONFIG.DEFAULT_PATTERN
        end
        return {
            sourceIndex = sourceCombo.CurrentIndex,
            colorIndex = colorCombo.CurrentIndex,
            formatIndex = formatCombo.CurrentIndex,
            pattern = pattern,
            createSubfolders = subfolderCheck.Checked,
            overwrite = overwriteCheck.Checked,
            openFolderAfterExport = openFolderCheck.Checked,
            jpegQuality = qualitySlider and qualitySlider.Value or CONFIG.DEFAULT_JPEG_QUALITY
        }
    end

    -- Reset button handler with modifier key support
    function dialog.On.ResetButton.Clicked(ev)
        if modifiers.cmd and modifiers.shift then
            -- Command+Shift: Clear user defaults, reset to script defaults
            clearUserDefaults()
            applyDefaults(getScriptDefaults())
        elseif modifiers.cmd then
            -- Command: Save current settings as user defaults
            saveAsUserDefaults(getCurrentPrefs())
        else
            -- Normal click: Reset to effective defaults (user or script)
            applyDefaults(getEffectiveDefaults())
            -- Save the reset state
            savePreferences(getCurrentPrefs())
        end
    end

    -- Helper to collect the current export options from the UI
    local function collectOptions()
        local pattern = patternEdit.Text
        if pattern == "" then
            pattern = CONFIG.DEFAULT_PATTERN
        end

        return {
            source = CONFIG.MARKER_SOURCES[sourceCombo.CurrentIndex + 1],
            color = CONFIG.MARKER_COLORS[colorCombo.CurrentIndex + 1],
            format = CONFIG.EXPORT_FORMATS[formatCombo.CurrentIndex + 1],
            pattern = pattern,
            createSubfolders = subfolderCheck.Checked,
            overwrite = overwriteCheck.Checked,
            openFolderAfterExport = openFolderCheck.Checked,
            jpegQuality = qualitySlider and qualitySlider.Value or CONFIG.DEFAULT_JPEG_QUALITY,
            -- Include UI state for preference persistence
            prefs = getCurrentPrefs()
        }
    end

    -- Processing steals focus mid-run, so a KeyRelease can go missing;
    -- clear modifier state after every export so Reset doesn't stick
    local function resetModifiers()
        modifiers.cmd = false
        modifiers.shift = false
        updateResetButtonText()
    end

    -- Gallery button handler (processing runs here so the dialog stays open;
    -- runWithDialogBusy greys the dialog and drops clicks while it runs)
    function dialog.On.GalleryButton.Clicked(ev)
        local options = collectOptions()
        options.outputMode = "gallery"
        utils.runWithDialogBusy(dialog, runExport, options)
        resetModifiers()
    end

    -- Export button handler (processing runs here so the dialog stays open)
    function dialog.On.ExportButton.Clicked(ev)
        utils.runWithDialogBusy(dialog, runExport, collectOptions())
        resetModifiers()
    end

    function dialog.On.ExportStillsDialog.Close(ev)
        -- Reset modifier state on close (in case window loses focus while key held)
        resetModifiers()
        -- Save current settings before closing
        savePreferences(getCurrentPrefs())
        dispatcher:ExitLoop()
    end

    utils.attachFooterHandler(dialog)

    -- Pre-lay-out collapsed sections while the window is still hidden so their
    -- first reveal doesn't paint a frame at unpositioned coordinates
    local prewarmList = {settingsContainer}
    if qualityContainer then table.insert(prewarmList, qualityContainer) end
    utils.prewarmDialogSections(dialog, prewarmList)

    -- Initial visibility and summary update
    updateQualityVisibility()
    updateSummary()

    -- Auto-size height to content, then center on Resolve's display before Show
    if not utils.fitDialogHeight(dialog, CONFIG.DIALOG_WIDTH) then
        dialog:Resize({CONFIG.DIALOG_WIDTH, CONFIG.DIALOG_FALLBACK_HEIGHT})
        dialog:RecalcLayout()
    end
    utils.centerDialogOnScreen(dialog, ui, dispatcher)
    dialog:Show()

    dispatcher:RunLoop()
    dialog:Hide()
end

-- Format extension map (cached at module level for O(1) lookup)
local FORMAT_EXTENSIONS = {
    PNG = "png",
    JPEG = "jpg",
    TIFF = "tif",
    DPX = "dpx",
    EXR = "exr"
}

-- Export still at specific frame using Project:ExportCurrentFrameAsStill API
-- Note: Timeline must already be set as current before calling this function
-- frameRate, isDropFrame, and startFrame are passed in (cached per timeline) to avoid repeated API calls
local function exportStillAtFrame(ctx, timeline, frameNum, frameRate, isDropFrame, startFrame, outputDir, options, filename)
    local project = ctx.project
    local extension = FORMAT_EXTENSIONS[options.format] or "png"

    -- Calculate absolute frame and convert to timecode
    -- All frames are now normalized to be relative, so always add startFrame
    -- Timelines in Resolve typically start at 01:00:00:00 (startFrame = 86400 at 24fps)
    local absoluteFrame = frameNum + startFrame
    local timecode = utils.formatTimecode(absoluteFrame, frameRate, isDropFrame)

    -- Set playhead position
    local success = timeline:SetCurrentTimecode(timecode)
    if not success then
        return false, string.format("Failed to set playhead to frame %d (timecode %s)", frameNum, timecode)
    end

    -- Build output path with extension
    local fullFilename = filename .. "." .. extension
    local outputPath = outputDir .. utils.PATH_SEP .. fullFilename

    -- Handle existing files if not overwriting
    if not options.overwrite then
        local counter = 1
        while utils.fileExists(outputPath) do
            fullFilename = filename .. "_" .. counter .. "." .. extension
            outputPath = outputDir .. utils.PATH_SEP .. fullFilename
            counter = counter + 1
        end
    end

    -- Export the still directly using Project:ExportCurrentFrameAsStill
    success = project:ExportCurrentFrameAsStill(outputPath)

    if not success then
        return false, "ExportCurrentFrameAsStill failed"
    end

    -- Apply JPEG compression on macOS if quality < 100
    local jpegUncompressed = false
    if utils.IS_MACOS and options.format == "JPEG" and options.jpegQuality < 100 then
        local compressSuccess, compressErr = compressJpegWithSips(outputPath, options.jpegQuality)
        if not compressSuccess then
            -- Don't fail the export - the file exists, just at full quality. Flag it so
            -- the caller can warn once in the summary instead of burying it per-frame.
            jpegUncompressed = true
            print(utils.statusLine("WARN", string.format("JPEG quality not applied to %s: %s", fullFilename, compressErr or "unknown error")))
        end
    end

    return true, outputPath, jpegUncompressed
end

-- Grab still to gallery at specific frame
-- Note: Timeline must already be set as current before calling this function
local function grabStillToGallery(timeline, timecode)
    timeline:SetCurrentTimecode(timecode)
    return timeline:GrabStill()
end

-- Process timelines and export stills
local function processTimelines(ctx, timelines, outputPath, options, gallery, album)
    local ui = ctx.ui
    local dispatcher = ctx.dispatcher
    local isGalleryMode = options.outputMode == "gallery"

    -- Count total markers to export
    local markerList = {}
    local totalMarkers = 0

    utils.printHeader("Collecting Markers")
    print(string.format("  Marker source: %s", options.source))

    for _, timelineInfo in ipairs(timelines) do
        local timeline = timelineInfo.timeline
        local timelineMarkers = {}
        local seenFrames = {}  -- For deduplication

        -- Get startFrame early for normalizing clip marker frames
        local startFrame = timeline:GetStartFrame() or 0

        -- Collect timeline markers
        if options.source ~= "Clip Markers" then
            local markers = timeline:GetMarkers()

            if markers then
                for frameNum, markerInfo in pairs(markers) do
                    -- Filter by color if specified
                    if options.color == "All Colors" or markerInfo.color == options.color then
                        table.insert(timelineMarkers, {
                            frame = frameNum,
                            info = markerInfo,
                            timeline = timelineInfo,
                            isClipMarker = false
                        })
                        seenFrames[frameNum] = true
                        totalMarkers = totalMarkers + 1
                    end
                end
            end
        end

        -- Collect clip markers
        if options.source ~= "Timeline Markers" then
            local clipMarkers = getClipMarkersFromTimeline(timeline, options.color)

            for _, markerData in ipairs(clipMarkers) do
                -- Normalize clip marker frame to be relative (same as timeline markers)
                -- Clip markers return absolute frames, subtract startFrame to normalize
                local normalizedFrame = markerData.frame - startFrame

                -- Deduplicate: skip if we already have a marker at this frame
                if not seenFrames[normalizedFrame] then
                    table.insert(timelineMarkers, {
                        frame = normalizedFrame,
                        info = markerData.info,
                        timeline = timelineInfo,
                        clipName = markerData.clipName,
                        isClipMarker = true
                    })
                    seenFrames[normalizedFrame] = true
                    totalMarkers = totalMarkers + 1
                end
            end
        end

        -- Sort markers by frame number
        table.sort(timelineMarkers, function(a, b) return a.frame < b.frame end)

        if #timelineMarkers > 0 then
            table.insert(markerList, {
                timeline = timelineInfo,
                markers = timelineMarkers
            })
            print(string.format("  %s: %d marker(s)", timelineInfo.name, #timelineMarkers))
        end
    end

    if totalMarkers == 0 then
        local msg = options.color == "All Colors" and "No markers found" or
                   string.format("No %s markers found", options.color)
        utils.printError(msg .. " in selected timelines")
        return false
    end

    print(string.format("Found %d marker(s) to %s across %d timeline(s)",
                         totalMarkers, isGalleryMode and "add to gallery" or "export", #markerList))

    -- Create progress window
    local progressTitle = isGalleryMode and "Adding Stills to Gallery" or "Exporting Stills to Disk"
    local progress = utils.createProgressWindow(ui, dispatcher, {
        title = progressTitle,
        totalItems = totalMarkers,
        cancellable = true,
    })

    if progress then
        progress.show()
        progress.update(0, "Starting...", "Starting batch " .. (isGalleryMode and "gallery add" or "export") .. "...")
    end

    -- Process each timeline's markers
    local exportCount = 0
    local errorCount = 0
    local compressionFailures = 0
    local currentMarker = 0

    utils.printSeparator("=", 70)
    utils.printHeader(isGalleryMode and "Adding Stills to Gallery" or "Exporting Stills")

    -- Print JPEG quality info if applicable (disk export only)
    if not isGalleryMode and utils.IS_MACOS and options.format == "JPEG" then
        if options.jpegQuality < 100 then
            print(string.format("  JPEG quality: %d (using sips compression)", options.jpegQuality))
        else
            print("  JPEG quality: 100 (no compression, using Resolve default)")
        end
    end

    for _, timelineInfo in ipairs(markerList) do
        -- Cancel check at the loop top, NOT after ::continue_timeline:: - a
        -- statement after that label would make the goto at the top of the
        -- body jump into the scope of the locals below (compile error). The
        -- goto path still lands here on the next iteration.
        if progress and progress.isCancelled() then break end

        local timeline = timelineInfo.timeline.timeline
        local timelineName = timelineInfo.timeline.name

        local tlSuccess = utils.setCurrentTimeline(ctx.project, timeline)
        if not tlSuccess then
            utils.printError("Failed to set timeline as current: " .. timelineName)
            goto continue_timeline
        end

        -- Cache per-timeline settings to avoid repeated API calls
        local frameRate = tonumber(timeline:GetSetting("timelineFrameRate")) or 24
        local isDropFrame = timeline:GetSetting("timelineDropFrameTimecode") == "1"
        local startFrame = timeline:GetStartFrame() or 0

        -- Per-timeline subfolder for stills when the option is enabled
        local exportDir = outputPath
        if not isGalleryMode and options.createSubfolders then
            local safeName = utils.sanitizeFilename(timelineName)
            exportDir = outputPath .. utils.PATH_SEP .. safeName
            utils.createDirectory(exportDir)
        end

        print(string.format("\n[Timeline: %s]%s", timelineName, isDropFrame and " (drop-frame)" or ""))

        for _, markerData in ipairs(timelineInfo.markers) do
            -- Break BEFORE the increment so currentMarker stays "markers attempted"
            if progress and progress.isCancelled() then break end
            currentMarker = currentMarker + 1
            local frame = markerData.frame
            local info = markerData.info
            local isClipMarker = markerData.isClipMarker
            local sourceLabel = isClipMarker and "clip" or "timeline"

            -- Calculate timecode using cached frame rate and drop-frame setting
            local absoluteFrame = frame + startFrame
            local timecode = utils.formatTimecode(absoluteFrame, frameRate, isDropFrame)

            -- Generate filename (used as label for gallery mode)
            local filename = generateFilename(
                options.pattern,
                timelineName,
                info.name or string.format("Frame_%d", frame),
                frame,
                info.color,
                timecode,
                isClipMarker
            )

            -- Update progress before operation
            if progress then
                local statusText = string.format('[%d/%d] %s - Frame %d (%s)',
                                               currentMarker, totalMarkers,
                                               timelineName, frame, sourceLabel)
                progress.update(currentMarker, info.name or "Marker", statusText)
            end

            if isGalleryMode then
                -- Gallery export path
                local still = grabStillToGallery(timeline, timecode)
                if still and album then
                    album:SetLabel(still, filename)
                    exportCount = exportCount + 1
                    print(string.format("  Frame %d (%s): %s", frame, sourceLabel, filename))

                    if progress then
                        progress.update(currentMarker, info.name or "Marker",
                                      string.format('  [%d/%d] %s - Frame %d (%s)',
                                                  currentMarker, totalMarkers,
                                                  timelineName, frame, sourceLabel))
                    end
                else
                    errorCount = errorCount + 1
                    utils.printError(string.format("  Frame %d (%s): Failed - GrabStill returned nil", frame, sourceLabel))

                    if progress then
                        progress.update(currentMarker, info.name or "Marker",
                                      string.format('  [%d/%d] Error: GrabStill failed', currentMarker, totalMarkers))
                    end
                end
            else
                -- Disk export path
                -- On success, errOrPath holds the actual still path; on failure, the error message.
                local success, errOrPath, jpegUncompressed = exportStillAtFrame(ctx, timeline, frame, frameRate, isDropFrame, startFrame, exportDir, options, filename)

                if success then
                    exportCount = exportCount + 1
                    if jpegUncompressed then compressionFailures = compressionFailures + 1 end
                    print(string.format("  Frame %d (%s): %s.%s",
                                      frame, sourceLabel, filename, options.format:lower()))

                    if progress then
                        progress.update(currentMarker, info.name or "Marker",
                                      string.format('  [%d/%d] %s - Frame %d (%s)',
                                                  currentMarker, totalMarkers,
                                                  timelineName, frame, sourceLabel))
                    end
                else
                    errorCount = errorCount + 1
                    utils.printError(string.format("  Frame %d (%s): Failed - %s", frame, sourceLabel, errOrPath))

                    if progress then
                        progress.update(currentMarker, info.name or "Marker",
                                      string.format('  [%d/%d] Error: %s', currentMarker, totalMarkers, errOrPath))
                    end
                end
            end
        end

        ::continue_timeline::
    end

    -- A cancel that lands after the last marker was already processed is
    -- not a cancellation - the work finished
    local wasCancelled = progress ~= nil and progress.isCancelled()
                         and currentMarker < totalMarkers

    -- Final progress update
    if progress then
        local actionWord = isGalleryMode and "Added" or "Exported"
        local finalMsg
        if wasCancelled then
            finalMsg = string.format("Cancelled - %s %d of %d still(s)",
                                     actionWord, exportCount, totalMarkers)
        elseif errorCount == 0 then
            finalMsg = string.format("Complete! %s %d still(s)", actionWord, exportCount)
        else
            finalMsg = string.format("Complete! %s: %d | Failed: %d", actionWord, exportCount, errorCount)
        end

        progress.update(wasCancelled and currentMarker or totalMarkers,
                        wasCancelled and 'Cancelled' or 'Complete!', finalMsg, true)

        -- Keep window open briefly
        utils.sleep(1)

        progress.hide()
    end

    -- Print summary
    utils.printSeparator("=", 70)
    utils.printHeader(isGalleryMode and "Gallery Summary" or "Export Summary")
    if wasCancelled then
        utils.printWarning(string.format("Cancelled by user - %s %d of %d marker(s)",
            isGalleryMode and "added" or "exported", exportCount, totalMarkers))
    end
    print(string.format("  Total markers processed: %d", totalMarkers))
    print(string.format("  Successfully %s: %d", isGalleryMode and "added" or "exported", exportCount))
    if errorCount > 0 then
        print(string.format("  Failed: %d", errorCount))
    end
    if isGalleryMode then
        local albumName = album and (gallery:GetAlbumName(album) or "current album") or "current album"
        print(string.format("  Gallery album: %s", albumName))
    else
        print(string.format("  Output directory: %s", outputPath))
    end
    if compressionFailures > 0 then
        utils.printWarning(string.format("%d JPEG(s) written at full quality (compression failed) - files may be larger than expected", compressionFailures))
    end

    return exportCount > 0, wasCancelled
end

-- ============================================================================
-- MAIN SCRIPT
-- ============================================================================

print("\n")
utils.printHeader(SCRIPT_INFO.NAME .. " v" .. SCRIPT_INFO.VERSION)

-- Print platform info
if utils.IS_MACOS then
    print("  Platform: macOS (JPEG quality control available)")
elseif utils.IS_LINUX then
    print("  Platform: Linux (JPEG uses default quality)")
else
    print("  Platform: Windows (JPEG uses default quality)")
end

-- Initialize with UI support
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
local projectName = project:GetName()
utils.printSuccess("Project: " .. (projectName or "Unknown"))

-- Load saved preferences (using new nested structure)
local prefsData = loadPreferences()
local savedPrefs = prefsData.current

-- Run one export from a dialog button handler; the options dialog stays open
-- while the progress window is up and processing runs
local function runExport(options)
    -- Save preferences immediately (before any validation)
    -- This ensures settings persist even if no timeline is selected
    savedPrefs = options.prefs
    savePreferences(savedPrefs)

    -- Check for selected timelines BEFORE showing directory picker
    utils.printSection("FINDING SELECTED TIMELINES")
    local selectedTimelines = utils.requireSelectedTimelines(project, mediaPool, ui, dispatcher)
    if not selectedTimelines then
        -- Preferences already saved; user can adjust selection and try again
        return
    end

    utils.printSuccess("Found " .. #selectedTimelines .. " selected timeline(s)")

    -- Handle gallery vs disk export
    local outputPath = nil
    local gallery, album = nil, nil

    if options.outputMode == "gallery" then
        -- Gallery mode: get gallery and current album
        gallery = project:GetGallery()
        if not gallery then
            utils.printError("Could not access Gallery. Make sure you're on the Color page.")
            return
        end

        album = gallery:GetCurrentStillAlbum()
        if not album then
            utils.printError("No gallery album selected. Select an album in the Color page Gallery.")
            return
        end

        local albumName = gallery:GetAlbumName(album) or "Unknown"
        utils.printSuccess("Target album: " .. albumName)
    else
        -- Disk export: get output directory
        local dirErr
        outputPath, dirErr = utils.promptForOutputDirectory(ctx.fusion)
        if not outputPath then
            utils.printError(dirErr or "No directory selected")
            return
        end
    end

    print(string.format("\nSelected options:"))
    print(string.format("  Marker source: %s", options.source))
    print(string.format("  Marker color: %s", options.color))
    if options.outputMode == "gallery" then
        print(string.format("  Output mode: Add to Gallery"))
        print(string.format("  Label pattern: %s", options.pattern))
    else
        print(string.format("  Output mode: Export to Disk"))
        print(string.format("  Export format: %s", options.format))
        if utils.IS_MACOS and options.format == "JPEG" then
            print(string.format("  JPEG quality: %d%s", options.jpegQuality,
                  options.jpegQuality == 100 and " (no compression)" or ""))
        end
        print(string.format("  Filename pattern: %s", options.pattern))
        print(string.format("  Create subfolders: %s", options.createSubfolders and "Yes" or "No"))
        print(string.format("  Overwrite existing: %s", options.overwrite and "Yes" or "No"))
        print(string.format("  Open folder after: %s", options.openFolderAfterExport and "Yes" or "No"))
        print(string.format("  Output directory: %s", outputPath))
    end

    -- Process timelines and export stills
    local success, wasCancelled = processTimelines(ctx, selectedTimelines, outputPath, options, gallery, album)

    utils.printSeparator("=", 70)

    if success then
        if options.outputMode == "gallery" then
            if wasCancelled then
                utils.printWarning("Cancelled - partial set added to gallery")
            else
                utils.printSuccess("Stills added to gallery successfully!")
            end
        else
            if wasCancelled then
                utils.printWarning("Cancelled - partial export kept on disk")
            else
                utils.printSuccess("Still export completed successfully!")
            end
            -- Open output folder if option enabled (also on cancel: the
            -- partial output is valid and worth showing)
            if options.openFolderAfterExport then
                utils.openFolder(outputPath)
            end
        end
    elseif wasCancelled then
        utils.printWarning("Cancelled before any stills were exported")
    else
        utils.printError("Operation completed with errors")
    end
end

-- Show options dialog; exports run from its button handlers, and the
-- dialog stays open until the user closes it
utils.printSection("SELECT OPTIONS")
showOptionsDialog(ui, dispatcher, savedPrefs, runExport)
print("\nDialog closed by user.")

print("\n")
utils.printSeparator("=", 70)
print("Script completed.")
utils.printSeparator("=", 70)
print()
