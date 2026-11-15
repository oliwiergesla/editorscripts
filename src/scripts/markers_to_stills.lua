local SCRIPT_INFO = {
    NAME = "Markers to Stills",
    VERSION = "1.1.0",
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
        - Exports PNG, JPEG, TIFF, or DPX, with JPEG quality control
          (on Windows from Resolve 21.2)
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
        "DPX"
    },

    DEFAULT_PATTERN = "{timeline}_{frame}",
    DEFAULT_JPEG_QUALITY = 85,
    DIALOG_WIDTH = 420,

    DIALOG_FALLBACK_HEIGHT = 440,       -- only used if fitDialogHeight fails

    -- Preview truncation
    PREVIEW_MAX_LENGTH = 60,            -- Max chars for filename preview (excluding "→ " prefix)
}


-- File extension written for each export format
local FORMAT_EXTENSIONS = {
    PNG = "png",
    JPEG = "jpg",
    TIFF = "tif",
    DPX = "dpx"
}

-- Settings key for persisting user preferences
local SETTINGS_KEY = "exportStillsFromMarkers"

-- Settings store the export format by NAME (prefs.format), so EXPORT_FORMATS
-- can be reordered or extended without changing what a saved choice means.
-- Settings written before that hold a position instead (prefs.formatIndex);
-- this is the list those positions refer to. Frozen: never edit it.
local LEGACY_FORMAT_ORDER = { "PNG", "JPEG", "TIFF", "DPX", "EXR" }

-- Resolve 21.2+: Timeline:ExportFrame renders a still in one call, with a JPEG
-- quality - no playhead move, no sips. Set once after init. A version compare,
-- not a method probe: the method exists from 21.1.2 but its quality option
-- only from 21.2, and option keys cannot be probed.
--
-- PHASE-OUT: once MIN_RESOLVE reaches 21.2, delete this flag (always true),
-- jpegQualityAvailable (always true), compressJpegWithSips with its
-- compression-failure plumbing, and the playhead branch of exportStillAtFrame.
-- Gallery stills keep stepping the playhead (GrabStill takes no frame).
local exportFrameSupported = false

-- True when a JPEG quality can be applied: by ExportFrame, or by sips on macOS
local jpegQualityAvailable = utils.IS_MACOS

-- ============================================================================
-- SETTINGS AND USER DEFAULTS
-- ============================================================================

-- Get script's hardcoded defaults
local function getScriptDefaults()
    return {
        sourceIndex = 0,
        colorIndex = 0,
        format = CONFIG.EXPORT_FORMATS[1],
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

-- Compress JPEG using macOS sips tool (playhead path only - before Resolve 21.2)
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

                -- JPEG Quality slider - hidden until JPEG is selected, and only
                -- ever shown when a quality can be applied (jpegQualityAvailable)
                ui:VGroup{
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
                },

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

    local qualityContainer = dialog:Find("QualityContainer")
    local qualitySlider = dialog:Find("QualitySlider")
    local qualityLabel = dialog:Find("QualityLabel")

    -- Populate combo boxes
    sourceCombo:AddItems(CONFIG.MARKER_SOURCES)
    colorCombo:AddItems(CONFIG.MARKER_COLORS)
    formatCombo:AddItems(CONFIG.EXPORT_FORMATS)

    -- Combo position of the format saved in a prefs table (see
    -- LEGACY_FORMAT_ORDER). A format that is missing or no longer offered
    -- selects the first entry.
    local function savedFormatIndex(prefs)
        local name = prefs.format
        if name == nil and type(prefs.formatIndex) == "number" then
            name = LEGACY_FORMAT_ORDER[prefs.formatIndex + 1]
        end
        for i, format in ipairs(CONFIG.EXPORT_FORMATS) do
            if format == name then return i - 1 end
        end
        return 0
    end

    -- Apply saved preferences or use defaults
    sourceCombo.CurrentIndex = savedPrefs.sourceIndex or 0
    colorCombo.CurrentIndex = savedPrefs.colorIndex or 0
    formatCombo.CurrentIndex = savedFormatIndex(savedPrefs)
    patternEdit.Text = savedPrefs.pattern or CONFIG.DEFAULT_PATTERN
    subfolderCheck.Checked = savedPrefs.createSubfolders ~= false  -- Default true
    overwriteCheck.Checked = savedPrefs.overwrite == true  -- Default false
    openFolderCheck.Checked = savedPrefs.openFolderAfterExport ~= false  -- Default true
    qualitySlider.Value = savedPrefs.jpegQuality or CONFIG.DEFAULT_JPEG_QUALITY
    qualityLabel.Text = tostring(qualitySlider.Value)

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
        local format = CONFIG.EXPORT_FORMATS[formatCombo.CurrentIndex + 1]
        local shouldShow = format == "JPEG" and jpegQualityAvailable

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
        local fullPreview = string.format("%s.%s", example, FORMAT_EXTENSIONS[format])
        local displayPreview = utils.truncatePreview(fullPreview, CONFIG.PREVIEW_MAX_LENGTH, true)
        previewLabel.Text = "→ " .. displayPreview
    end

    -- Helper to apply defaults to UI elements
    local function applyDefaults(defaults)
        sourceCombo.CurrentIndex = defaults.sourceIndex or 0
        colorCombo.CurrentIndex = defaults.colorIndex or 0
        formatCombo.CurrentIndex = savedFormatIndex(defaults)
        patternEdit.Text = defaults.pattern or CONFIG.DEFAULT_PATTERN
        subfolderCheck.Checked = defaults.createSubfolders ~= false
        overwriteCheck.Checked = defaults.overwrite == true
        openFolderCheck.Checked = defaults.openFolderAfterExport ~= false
        qualitySlider.Value = defaults.jpegQuality or CONFIG.DEFAULT_JPEG_QUALITY
        qualityLabel.Text = tostring(defaults.jpegQuality or CONFIG.DEFAULT_JPEG_QUALITY)
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

    function dialog.On.QualitySlider.ValueChanged(ev)
        qualityLabel.Text = tostring(qualitySlider.Value)
        updateSummary()
    end

    -- SliderMoved fires continuously while dragging
    function dialog.On.QualitySlider.SliderMoved(ev)
        qualityLabel.Text = tostring(qualitySlider.Value)
        updateSummary()
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
            format = CONFIG.EXPORT_FORMATS[formatCombo.CurrentIndex + 1],
            pattern = pattern,
            createSubfolders = subfolderCheck.Checked,
            overwrite = overwriteCheck.Checked,
            openFolderAfterExport = openFolderCheck.Checked,
            jpegQuality = qualitySlider.Value
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
            jpegQuality = qualitySlider.Value,
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
    utils.prewarmDialogSections(dialog, {settingsContainer, qualityContainer})

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

-- Export one still to disk. frameNum is the 0-based offset from the timeline
-- start (the basis marker frame ids use); timecode is that same position.
-- directExport renders the frame with Timeline:ExportFrame, without touching
-- the playhead; otherwise the still is taken at the playhead. Either way the
-- timeline must already be current: ExportFrame returns success with a BLACK
-- frame for a timeline that has not been opened since the project was loaded
-- (Resolve 21.2, measured November 2026).
-- Returns true, outputPath, jpegUncompressed - or false, errorMessage
local function exportStillAtFrame(ctx, timeline, frameNum, timecode, outputDir, options, filename, directExport)
    local extension = FORMAT_EXTENSIONS[options.format] or "png"

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

    if directExport then
        local result = timeline:ExportFrame(frameNum, {
            outputType = "file",
            filePath = outputPath,
            quality = options.format == "JPEG" and options.jpegQuality or nil,
        })
        if type(result) ~= "table" or not result.success then
            return false, "ExportFrame failed: " .. tostring(type(result) == "table" and result.error or "no result")
        end
        return true, outputPath, false
    end

    -- Playhead path: park the playhead on the frame, then export what it shows
    if not timeline:SetCurrentTimecode(timecode) then
        return false, string.format("Failed to set playhead to frame %d (timecode %s)", frameNum, timecode)
    end

    if not ctx.project:ExportCurrentFrameAsStill(outputPath) then
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

    -- Resolve 21.2+ writes every disk still with ExportFrame (output verified
    -- pixel-identical to the playhead path in all four formats). Playheads are
    -- left alone, so the user is put back on the timeline they started on
    -- after the batch. PNG is the slow one: ExportFrame compresses it where
    -- the playhead path writes it uncompressed - at 3840x2160 files are ~3x
    -- smaller and take 2.1 s against 0.5 s (measured November 2026, macOS).
    local directExport = not isGalleryMode and exportFrameSupported
    local originalTimeline = directExport and ctx.project:GetCurrentTimeline() or nil

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

    if not isGalleryMode then
        print("  Export method: " .. (directExport
            and "direct render (playheads stay put)"
            or "playhead (stepped to every marker)"))
    end

    -- Print JPEG quality info if applicable (disk export only)
    if not isGalleryMode and jpegQualityAvailable and options.format == "JPEG" then
        if directExport then
            print(string.format("  JPEG quality: %d", options.jpegQuality))
        elseif options.jpegQuality < 100 then
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

        -- Every path needs the timeline current - direct exports included
        -- (see exportStillAtFrame: an unopened timeline renders black)
        if not utils.setCurrentTimeline(ctx.project, timeline) then
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
                local success, errOrPath, jpegUncompressed = exportStillAtFrame(ctx, timeline, frame, timecode, exportDir, options, filename, directExport)

                if success then
                    exportCount = exportCount + 1
                    if jpegUncompressed then compressionFailures = compressionFailures + 1 end
                    print(string.format("  Frame %d (%s): %s", frame, sourceLabel,
                                      errOrPath:sub(#exportDir + #utils.PATH_SEP + 1)))

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

    if originalTimeline then
        utils.setCurrentTimeline(ctx.project, originalTimeline)
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

local resolveVersion = utils.getResolveVersion(ctx.resolve)
exportFrameSupported = resolveVersion ~= nil
    and (resolveVersion.major > 21 or (resolveVersion.major == 21 and resolveVersion.minor >= 2))
jpegQualityAvailable = exportFrameSupported or utils.IS_MACOS

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
        if jpegQualityAvailable and options.format == "JPEG" then
            print(string.format("  JPEG quality: %d%s", options.jpegQuality,
                  (options.jpegQuality == 100 and not exportFrameSupported) and " (no compression)" or ""))
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
