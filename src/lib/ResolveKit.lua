-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[
    ResolveKit - A comprehensive toolkit for DaVinci Resolve scripting

    Usage:
        local kit = require("ResolveKit")
        -- or for backward compatibility feel:
        local utils = require("ResolveKit")

    Modules:
        - core: Resolve initialization, console output, platform detection
        - timeline: Timeline operations and clip management
        - ui: User interface dialogs and progress windows
        - filesystem: File operations, JSON, and settings
        - media: Media pool bins and render calculations
        - docgen/: self-contained, Resolve-independent document writers
          (binwriter, jpeginfo, zipwriter, xlsxwriter, pdfwriter)
--]]

-- ============================================================================
-- IMPORT MODULES
-- ============================================================================

local Core = require("modules.core")
local Timeline = require("modules.timeline")
local UI = require("modules.ui")
local FileSystem = require("modules.filesystem")
local Media = require("modules.media")
local XlsxWriter = require("modules.docgen.xlsxwriter")
local PdfWriter = require("modules.docgen.pdfwriter")

-- ============================================================================
-- DEPENDENCY INJECTION
-- ============================================================================

-- Compose the theme resolver: user_preferences.json may force a theme
-- ({"appearance":{"theme":"gray"|"blue"}}) - the manual override for
-- platforms where the config.user.xml location differs - otherwise detect
-- from Resolve's config. Composed here so core/ui/filesystem stay decoupled.
local function resolveTheme()
    -- Best-effort manual override; a settings failure must NOT mask detection.
    local ok, t = pcall(function()
        local s = FileSystem.loadSettings()
        return s and s.appearance and s.appearance.theme
    end)
    if ok and (t == "gray" or t == "blue") then return t end
    -- Reliable path: read Resolve's config (itself fail-safe to "gray").
    return Core.getResolveTheme()
end

-- UI module needs the openURL function and the composed theme resolver
UI._injectDependencies(Core.openURL, resolveTheme)

-- ============================================================================
-- CREATE FACADE
-- ============================================================================

local ResolveKit = {}

-- ============================================================================
-- CORE FUNCTIONS (from core.lua)
-- ============================================================================

-- Resolve Connection & Initialization
ResolveKit.initialize = Core.initialize
ResolveKit.getResolveVersion = Core.getResolveVersion

-- Wraps Core.initializeWithUI to surface failures on screen: console output
-- is invisible when a script is launched from the Scripts menu, so a failed
-- init (version gate, no project open, lost connection) also shows an error
-- dialog. Pass the script's SCRIPT_INFO table (NAME titles the dialog,
-- MIN_RESOLVE is the version pin); a bare "major.minor" string also works.
-- Console-only initialize() deliberately stays silent - headless flows
-- (StreamDeck) handle their own alerts.
function ResolveKit.initializeWithUI(scriptInfo)
    local ctx, err = Core.initializeWithUI(scriptInfo)
    if ctx then
        return ctx, nil
    end

    -- Version-gate failures headline the action; everything else headlines
    -- the script name.
    local title
    if Core.isVersionGateError(err) then
        title = "Please Update Resolve"
    else
        title = type(scriptInfo) == "table" and scriptInfo.NAME or nil
    end
    -- Display copy only: tie "or newer" together with a non-breaking space
    -- (UTF-8 \194\160) so WordWrap never splits it mid-phrase. The returned
    -- err stays plain ASCII for console output.
    local displayErr = err:gsub("or newer", "or\194\160newer")
    -- Best-effort: build a standalone UI context for the dialog (the failed
    -- init may not have gotten that far, e.g. the version gate fires before
    -- Fusion is requested). Never mask the original error.
    local shown = pcall(function()
        local resolve = Core.getResolve()
        local fusion = resolve and resolve:Fusion()
        local ui = fusion and fusion.UIManager
        local dispatcher = ui and bmd.UIDispatcher(ui)
        assert(dispatcher, "no UI dispatcher")
        UI.showErrorDialog(ui, dispatcher, displayErr, title)
    end)
    if not shown then
        pcall(Core.showSystemAlert, title or "EditorScripts", err)
    end

    return nil, err
end

-- Printing Utilities
ResolveKit.printSeparator = Core.printSeparator
ResolveKit.printHeader = Core.printHeader
ResolveKit.printSection = Core.printSection
ResolveKit.printSuccess = Core.printSuccess
ResolveKit.printError = Core.printError
ResolveKit.printWarning = Core.printWarning
ResolveKit.STATUS = Core.STATUS
ResolveKit.statusLine = Core.statusLine
ResolveKit.printStatus = Core.printStatus

-- String Utilities
ResolveKit.truncatePreview = Core.truncatePreview
ResolveKit.formatTimecode = Core.formatTimecode
ResolveKit.shellQuote = Core.shellQuote
ResolveKit.applyTokens = Core.applyTokens

-- Cross-Platform Utilities
ResolveKit.sleep = Core.sleep
ResolveKit.openURL = Core.openURL
ResolveKit.openFolder = Core.openFolder
ResolveKit.copyToClipboard = Core.copyToClipboard
ResolveKit.showSystemAlert = Core.showSystemAlert

-- Platform Detection
ResolveKit.IS_WINDOWS = Core.IS_WINDOWS
ResolveKit.IS_MACOS = Core.IS_MACOS
ResolveKit.IS_LINUX = Core.IS_LINUX
ResolveKit.PATH_SEP = Core.PATH_SEP
ResolveKit.getResolveTheme = Core.getResolveTheme

-- Modifier Key Codes (for Fusion UIManager)
ResolveKit.KEY_CODES = Core.KEY_CODES

-- ============================================================================
-- TIMELINE FUNCTIONS (from timeline.lua)
-- ============================================================================

-- Timeline Functions
ResolveKit.getSelectedTimelines = Timeline.getSelectedTimelines
ResolveKit.getTimelineDuration = Timeline.getTimelineDuration
ResolveKit.setCurrentTimeline = Timeline.setCurrentTimeline
ResolveKit.getTimelineResolution = Timeline.getTimelineResolution
ResolveKit.setTimelineFlag = Timeline.setTimelineFlag
ResolveKit.getAllTimelines = Timeline.getAllTimelines
ResolveKit.getTimelineNameSet = Timeline.getTimelineNameSet

-- Marker Operations
ResolveKit.countMarkers = Timeline.countMarkers

-- Timeline Name Manipulation
ResolveKit.extractResolutionFromTimelineName = Timeline.extractResolutionFromTimelineName
ResolveKit.removeVersionSuffix = Timeline.removeVersionSuffix
ResolveKit.modifyTimelineName = Timeline.modifyTimelineName
ResolveKit.timelineNameContains = Timeline.timelineNameContains

-- Track Operations
ResolveKit.getTrackCount = Timeline.getTrackCount
ResolveKit.isTrackEmpty = Timeline.isTrackEmpty
ResolveKit.deleteEmptyVideoTracks = Timeline.deleteEmptyVideoTracks
ResolveKit.deleteAllTracksExcept = Timeline.deleteAllTracksExcept

-- Clip Operations
ResolveKit.findDisabledClips = Timeline.findDisabledClips
ResolveKit.deleteDisabledClips = Timeline.deleteDisabledClips
ResolveKit.getLastEnabledFrame = Timeline.getLastEnabledFrame
ResolveKit.findClipsByNames = Timeline.findClipsByNames
ResolveKit.replaceClip = Timeline.replaceClip

-- Timeline Settings Operations
ResolveKit.enableCustomTimelineSettings = Timeline.enableCustomTimelineSettings

-- ============================================================================
-- UI FUNCTIONS (from ui.lua)
-- ============================================================================

-- UI Functions
ResolveKit.promptForOutputDirectory = UI.promptForOutputDirectory

-- Platform Window Flags
ResolveKit.getDialogFlags = UI.getDialogFlags
ResolveKit.applyDialogPlatformAttributes = UI.applyDialogPlatformAttributes

-- Explicit Dialog Centering
ResolveKit.centerDialogOnScreen = UI.centerDialogOnScreen

-- Dialog Builders
ResolveKit.showStatusDialog = UI.showStatusDialog
ResolveKit.showSuccessDialog = UI.showSuccessDialog
ResolveKit.showErrorDialog = UI.showErrorDialog
ResolveKit.showWarningDialog = UI.showWarningDialog

-- Progress Window
ResolveKit.createProgressWindow = UI.createProgressWindow

-- Dialog Busy State
ResolveKit.runWithDialogBusy = UI.runWithDialogBusy

-- UI Elements
ResolveKit.createFooter = UI.createFooter
ResolveKit.attachFooterHandler = UI.attachFooterHandler
ResolveKit.fitDialogHeight = UI.fitDialogHeight
ResolveKit.prewarmDialogSections = UI.prewarmDialogSections
ResolveKit.toggleDialogSections = UI.toggleDialogSections

-- Theming (eager: detection is cached and pcall-guarded, worst case "gray").
-- Scripts use `local STYLES, COLORS = utils.STYLES, utils.COLORS`.
ResolveKit.COLORS = UI.getColors()
ResolveKit.STYLES = UI.getStyles()
ResolveKit.getTheme = UI.getTheme   -- effective theme (after override)

-- ============================================================================
-- FILESYSTEM FUNCTIONS (from filesystem.lua)
-- ============================================================================

-- File System Operations
ResolveKit.sanitizeFilename = FileSystem.sanitizeFilename
ResolveKit.fileExists = FileSystem.fileExists
ResolveKit.directoryExists = FileSystem.directoryExists
ResolveKit.createDirectory = FileSystem.createDirectory
ResolveKit.getFilename = FileSystem.getFilename
ResolveKit.getExtension = FileSystem.getExtension
ResolveKit.joinPath = FileSystem.joinPath
ResolveKit.getUniqueFilePath = FileSystem.getUniqueFilePath
ResolveKit.copyFile = FileSystem.copyFile
ResolveKit.moveFile = FileSystem.moveFile
ResolveKit.walkDirectory = FileSystem.walkDirectory

-- JSON Utilities
ResolveKit.encodeJSON = FileSystem.encodeJSON
ResolveKit.decodeJSON = FileSystem.decodeJSON
ResolveKit.readJSONFile = FileSystem.readJSONFile
ResolveKit.writeJSONFile = FileSystem.writeJSONFile

-- Script & Data Directories
ResolveKit.getScriptPath = FileSystem.getScriptPath
ResolveKit.getScriptDir = FileSystem.getScriptDir
ResolveKit.getDataDir = FileSystem.getDataDir

-- Settings Management
ResolveKit.loadSettings = FileSystem.loadSettings
ResolveKit.saveSettings = FileSystem.saveSettings

-- ============================================================================
-- REPORT WRITERS (from xlsxwriter.lua, pdfwriter.lua)
-- ============================================================================

-- Pure-Lua document writers used by the marker-report feature. Each returns a
-- writer object with :addRow{...} and :build() -> bytes, err. binwriter,
-- zipwriter and jpeginfo are pulled in transitively as internal dependencies.
ResolveKit.newXlsxWriter = XlsxWriter.new
ResolveKit.newPdfWriter = PdfWriter.new

-- ============================================================================
-- MEDIA FUNCTIONS (from media.lua)
-- ============================================================================

-- Bin/Folder Operations
ResolveKit.getBin = Media.getBin
ResolveKit.collectClips = Media.collectClips
ResolveKit.buildMediaPoolCache = Media.buildMediaPoolCache
ResolveKit.findMediaPoolItem = Media.findMediaPoolItem

-- Render Settings
ResolveKit.calculateBitrateForFileSize = Media.calculateBitrateForFileSize

-- ============================================================================
-- COMPOSITE FUNCTIONS (bridge multiple modules)
-- ============================================================================

-- Get selected timelines with built-in error handling
-- Shows warning + error dialog if no timelines selected, returns nil
-- Parameters:
--   project, mediaPool: Resolve objects
--   ui, dispatcher: UI objects for error dialog
--   dialogMessage: (optional) Custom dialog body text
-- Returns: selectedTimelines array or nil
function ResolveKit.requireSelectedTimelines(project, mediaPool, ui, dispatcher, dialogMessage)
    local selectedTimelines, err = Timeline.getSelectedTimelines(project, mediaPool)

    if not selectedTimelines then
        Core.printWarning(err or "No timelines selected in Media Pool.")
        UI.showErrorDialog(ui, dispatcher,
            dialogMessage or "No timelines selected.\nSelect one or more timelines in the Media Pool.",
            "No Selection")
        return nil
    end

    return selectedTimelines
end

-- ============================================================================
-- RETURN MODULE
-- ============================================================================

return ResolveKit