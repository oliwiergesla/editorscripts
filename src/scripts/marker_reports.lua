local SCRIPT_INFO = {
    NAME = "Marker Reports",
    VERSION = "1.0.1",
    MIN_RESOLVE = "20.0",
}

-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[

    Marker Reports

    Exports a PDF and/or Excel (.xlsx) marker report per selected timeline,
    listing every marker with its timecodes, name, note, and color.

    Features:
        - One report set per selected timeline, named after the timeline
        - Filters timeline and clip markers by color, with deduplication
        - Embedded frame thumbnails per marker, or fast text-only reports
        - Progress window with Cancel for batch runs

    Usage:
        1. Select one or more timelines in the Media Pool
        2. Run the script from Workspace -> Scripts
        3. Choose marker source, color filter, export format, and report style
        4. Click "Export Report" and choose an output directory

--]]

local utils = require("ResolveKit")
local STYLES = utils.STYLES

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
        "PDF + Excel",
        "PDF Only",
        "Excel Only"
    },

    REPORT_STYLES = {
        "With Thumbnails (Slower)",
        "Text Only (Faster)"
    },

    REPORT_THUMB_PX = 640,              -- macOS sips downscale long-edge for embedded JPEGs
    DIALOG_WIDTH = 420,
    DIALOG_FALLBACK_HEIGHT = 320,       -- only used if fitDialogHeight fails
}


-- Settings key for persisting user preferences
local SETTINGS_KEY = "markerReports"

-- ============================================================================
-- SETTINGS
-- ============================================================================

-- Load saved preferences for this script (flat table of combo indices)
local function loadPrefs()
    local settings = utils.loadSettings() or {}
    return settings[SETTINGS_KEY] or {}
end

-- Save preferences for this script
local function savePrefs(prefs)
    local settings = utils.loadSettings() or {}
    settings[SETTINGS_KEY] = prefs
    utils.saveSettings(settings)
end

-- ============================================================================
-- MARKER COLLECTION
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

-- Collect, filter, dedup, and sort the markers for one timeline. Read-only API
-- calls throughout - never needs the timeline to be current.
-- Returns a frame-sorted list of { frame, info, clipName, isClipMarker } with
-- frames relative to the timeline start.
local function collectMarkersForTimeline(timeline, source, color)
    local result = {}
    local seenFrames = {}  -- For deduplication

    -- Get startFrame early for normalizing clip marker frames
    local startFrame = timeline:GetStartFrame() or 0

    -- Collect timeline markers
    if source ~= "Clip Markers" then
        local markers = timeline:GetMarkers()
        if markers then
            for frameNum, markerInfo in pairs(markers) do
                if color == "All Colors" or markerInfo.color == color then
                    table.insert(result, {
                        frame = frameNum,
                        info = markerInfo,
                        isClipMarker = false
                    })
                    seenFrames[frameNum] = true
                end
            end
        end
    end

    -- Collect clip markers
    if source ~= "Timeline Markers" then
        local clipMarkers = getClipMarkersFromTimeline(timeline, color)
        for _, markerData in ipairs(clipMarkers) do
            -- Clip markers return absolute frames; normalize to relative (same
            -- basis as timeline markers) and skip frames we already have
            local normalizedFrame = markerData.frame - startFrame
            if not seenFrames[normalizedFrame] then
                table.insert(result, {
                    frame = normalizedFrame,
                    info = markerData.info,
                    clipName = markerData.clipName,
                    isClipMarker = true
                })
                seenFrames[normalizedFrame] = true
            end
        end
    end

    table.sort(result, function(a, b) return a.frame < b.frame end)
    return result
end

-- ============================================================================
-- REPORT GENERATION
-- ============================================================================

-- Render a JPEG for the marker at `timecode` into the hidden temp dir, for
-- embedding in the report. The timeline must already be current (this parks the
-- playhead at the marker). On macOS the JPEG is downscaled with sips to keep
-- report file sizes reasonable. Returns the temp JPEG path, or nil on failure
-- (thumbnails are best-effort and never fatal).
local function makeThumbnailJpeg(ctx, timeline, timecode, tmpDir, tlIdx, idx)
    local jpgPath = tmpDir .. utils.PATH_SEP .. string.format("t%02d_r%05d.jpg", tlIdx, idx)

    timeline:SetCurrentTimecode(timecode)
    if not ctx.project:ExportCurrentFrameAsStill(jpgPath) then return nil end

    -- Downscale (macOS only) - best-effort; embed full-res if it fails or off-platform.
    if utils.IS_MACOS then
        os.execute(string.format("sips -Z %d %s >/dev/null 2>&1",
            CONFIG.REPORT_THUMB_PX, utils.shellQuote(jpgPath)))
    end

    return jpgPath
end

-- Build and write the report file(s) for one timeline. `meta` is the document
-- header { project, sequence, date }; `rows` is a list of { jpegPath, startTC,
-- endTC, duration, name, note, color }; `formats` is { pdf = bool, xlsx = bool }.
-- Text-only reports (withThumbs false) drop the image column entirely. Returns
-- the count of report files written. Wrapped by the caller in pcall; a failure
-- here must not abort the batch.
local function writeReports(meta, destDir, rows, formats, withThumbs)
    local writerOpts = { includeImage = withThumbs }
    local writers = {}
    if formats.xlsx then
        writers[#writers + 1] = { writer = utils.newXlsxWriter(writerOpts), ext = ".xlsx" }
    end
    if formats.pdf then
        writers[#writers + 1] = { writer = utils.newPdfWriter(writerOpts), ext = ".pdf" }
    end

    for _, w in ipairs(writers) do
        w.writer:setMeta(meta)
    end

    for _, r in ipairs(rows) do
        local bytes
        if withThumbs and r.jpegPath then
            local f = io.open(r.jpegPath, "rb")
            if f then
                bytes = f:read("*all")
                f:close()
            end
        end
        local rowData = {
            jpegBytes = bytes,
            startTC = r.startTC,
            endTC = r.endTC,
            duration = r.duration,
            name = r.name,
            note = r.note,
            color = r.color,
        }
        for _, w in ipairs(writers) do
            w.writer:addRow(rowData)
        end
    end

    local base = utils.sanitizeFilename(meta.sequence or "Markers")
    local written = 0

    for _, w in ipairs(writers) do
        local bytes = w.writer:build()
        if bytes then
            local path = utils.getUniqueFilePath(destDir, base .. w.ext)
            if path then
                local f = io.open(path, "wb")
                if f then
                    f:write(bytes)
                    f:close()
                    written = written + 1
                    print(string.format("  Report: %s", path))
                end
            end
        end
    end

    return written
end

-- Remove the hidden temp dir and the thumbnail JPEGs we created in it (best-effort).
local function cleanupReportTmp(tmpDir, rows)
    for _, r in ipairs(rows) do
        if r.jpegPath then os.remove(r.jpegPath) end
    end
    os.remove(tmpDir)  -- succeeds only if now empty; harmless if it lingers
end

-- Process each selected timeline: collect markers, build rows, write reports
local function processTimelines(ctx, timelines, outputPath, options)
    local ui = ctx.ui
    local dispatcher = ctx.dispatcher

    -- Count markers per timeline
    local markerList = {}
    local totalMarkers = 0

    utils.printHeader("Collecting Markers")
    print(string.format("  Marker source: %s", options.source))

    for _, timelineInfo in ipairs(timelines) do
        local markers = collectMarkersForTimeline(timelineInfo.timeline, options.source, options.color)
        if #markers > 0 then
            table.insert(markerList, {
                timeline = timelineInfo,
                markers = markers
            })
            totalMarkers = totalMarkers + #markers
            print(string.format("  %s: %d marker(s)", timelineInfo.name, #markers))
        else
            utils.printStatus("SKIP", timelineInfo.name .. ": no matching markers")
        end
    end

    if totalMarkers == 0 then
        local msg = options.color == "All Colors" and "No markers found" or
                    string.format("No %s markers found", options.color)
        utils.printError(msg .. " in selected timelines")
        return false, false
    end

    local totalTimelines = #markerList
    print(string.format("Found %d marker(s) across %d timeline(s)", totalMarkers, totalTimelines))

    if options.withThumbs and not utils.IS_MACOS then
        utils.printStatus("INFO", "Thumbnails embed at full resolution (downscale is macOS-only)")
    end

    -- Progress window (one tick per timeline; per-marker updates refresh the
    -- status text and pump the event loop so Cancel stays responsive)
    local progress = utils.createProgressWindow(ui, dispatcher, {
        title = "Exporting Marker Reports",
        totalItems = totalTimelines,
        cancellable = true,
    })

    if progress then
        progress.show()
        progress.update(0, "Starting...", "Starting report export...")
    end

    utils.printSeparator("=", 70)
    utils.printHeader("Exporting Marker Reports")

    local attemptedMarkers = 0
    local markersIncluded = 0
    local reportFilesWritten = 0
    local failedTimelines = 0
    local lastFinalized = 0

    for tIdx, entry in ipairs(markerList) do
        if progress and progress.isCancelled() then break end

        local timeline = entry.timeline.timeline
        local timelineName = entry.timeline.name

        -- Cache per-timeline settings to avoid repeated API calls
        local frameRate = tonumber(timeline:GetSetting("timelineFrameRate")) or 24
        local isDropFrame = timeline:GetSetting("timelineDropFrameTimecode") == "1"
        local startFrame = timeline:GetStartFrame() or 0

        print(string.format("\n[Timeline: %s]%s", timelineName, isDropFrame and " (drop-frame)" or ""))

        -- Thumbnails need the timeline current so the playhead can be parked at
        -- each marker; text-only mode never switches timelines (much faster)
        local tmpDir = nil
        local renderThumbs = false
        if options.withThumbs then
            if utils.setCurrentTimeline(ctx.project, timeline) then
                renderThumbs = true
                tmpDir = outputPath .. utils.PATH_SEP .. ".report_tmp"
                utils.createDirectory(tmpDir)
            else
                utils.printWarning("Could not set timeline as current - report will have no thumbnails")
            end
        end

        -- Build one report row per marker. Break BEFORE the increment so
        -- attemptedMarkers stays "markers attempted"; a cancel falls through to
        -- the report write + tmp cleanup below so the timeline still finalizes
        -- with the rows collected so far.
        local rows = {}
        for _, markerData in ipairs(entry.markers) do
            if progress and progress.isCancelled() then break end
            attemptedMarkers = attemptedMarkers + 1

            local frame = markerData.frame
            local info = markerData.info

            -- Markers carry a frame duration (defaults to 1). Derive
            -- Start/End/Duration timecodes from it.
            local duration = tonumber(info.duration) or 1
            local absoluteFrame = frame + startFrame
            local startTC = utils.formatTimecode(absoluteFrame, frameRate, isDropFrame)
            local endTC = utils.formatTimecode(absoluteFrame + duration, frameRate, isDropFrame)
            local durationTC = utils.formatTimecode(duration, frameRate, isDropFrame)

            if progress then
                progress.update(tIdx - 1, info.name or "Marker",
                    string.format('[%d/%d] %s - Frame %d', tIdx, totalTimelines, timelineName, frame))
            end

            local jpegPath = nil
            if renderThumbs then
                jpegPath = makeThumbnailJpeg(ctx, timeline, startTC, tmpDir, tIdx, #rows + 1)
                if not jpegPath then
                    utils.printStatus("WARN", string.format("Frame %d: thumbnail render failed - row embeds no image", frame))
                end
            end

            rows[#rows + 1] = {
                jpegPath = jpegPath,
                startTC = startTC,
                endTC = endTC,
                duration = durationTC,
                name = info.name or "",
                note = info.note or "",
                color = info.color or "",
            }
        end

        -- Write this timeline's reports (best-effort: never abort the batch)
        if #rows > 0 then
            if progress then
                progress.update(tIdx - 1, "Report",
                    string.format('[%d/%d] %s - writing report file(s)...', tIdx, totalTimelines, timelineName))
            end
            local meta = {
                project = ctx.project:GetName() or "",
                sequence = timelineName,
                date = os.date("%Y-%m-%d"),
            }
            local ok, resultOrErr = pcall(writeReports, meta, outputPath, rows,
                options.formats, options.withThumbs)
            if ok then
                reportFilesWritten = reportFilesWritten + (resultOrErr or 0)
                markersIncluded = markersIncluded + #rows
            else
                failedTimelines = failedTimelines + 1
                utils.printWarning(string.format("Report generation failed for %s: %s",
                    timelineName, tostring(resultOrErr)))
            end
        end

        if tmpDir then
            cleanupReportTmp(tmpDir, rows)
        end

        lastFinalized = tIdx

        if progress then
            progress.update(tIdx, timelineName,
                string.format('[%d/%d] %s - done', tIdx, totalTimelines, timelineName))
        end
    end

    -- A cancel that lands after the last marker was already processed is
    -- not a cancellation - the work finished
    local wasCancelled = progress ~= nil and progress.isCancelled()
                         and attemptedMarkers < totalMarkers

    -- Final progress update
    if progress then
        local finalMsg
        if wasCancelled then
            finalMsg = string.format("Cancelled - wrote %d report file(s)", reportFilesWritten)
        elseif failedTimelines == 0 then
            finalMsg = string.format("Complete! Wrote %d report file(s)", reportFilesWritten)
        else
            finalMsg = string.format("Complete! Wrote %d file(s) | %d timeline(s) failed",
                reportFilesWritten, failedTimelines)
        end

        progress.update(wasCancelled and lastFinalized or totalTimelines,
                        wasCancelled and 'Cancelled' or 'Complete!', finalMsg, true)

        -- Keep window open briefly
        utils.sleep(1)

        progress.hide()
    end

    -- Print summary
    utils.printSeparator("=", 70)
    utils.printHeader("Report Summary")
    if wasCancelled then
        utils.printWarning(string.format("Cancelled by user - processed %d of %d timeline(s)",
            lastFinalized, totalTimelines))
    end
    print(string.format("  Timelines processed: %d of %d", lastFinalized, totalTimelines))
    print(string.format("  Markers included: %d", markersIncluded))
    print(string.format("  Report files written: %d", reportFilesWritten))
    print(string.format("  Output directory: %s", outputPath))

    return reportFilesWritten > 0, wasCancelled
end

-- ============================================================================
-- OPTIONS DIALOG
-- ============================================================================

-- Show options dialog
-- savedPrefs: optional table of saved preferences to restore
local function showOptionsDialog(ui, dispatcher, savedPrefs, runExport)
    savedPrefs = savedPrefs or {}

    local dialog = dispatcher:AddWindow({
        ID = 'MarkerReportsDialog',
        WindowTitle = SCRIPT_INFO.NAME,
        WindowFlags = utils.getDialogFlags(),
        StyleSheet = STYLES.WINDOW,
        Events = {
            Close = true,
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

                -- Export format selection (which report files to write)
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

                ui:VGap(3),

                -- Report style selection (thumbnails vs text-only)
                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Text = "Report Style:",
                        Font = ui:Font{PixelSize = 12},
                        MinimumSize = {110, 20},
                    },
                    ui:ComboBox{
                        ID = "StyleCombo",
                        MinimumSize = {220, 33},
                    },
                },

                ui:VGap(16),

                -- Export button (full width)
                ui:HGroup{
                    Weight = 0,
                    ui:Button{
                        ID = "ExportButton",
                        Text = "Export Report",
                        MinimumSize = {325, 45},
                        Font = ui:Font{ PixelSize = 12 },
                        StyleSheet = STYLES.BUTTON_PRIMARY
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
    local styleCombo = dialog:Find("StyleCombo")

    -- Populate combo boxes
    sourceCombo:AddItems(CONFIG.MARKER_SOURCES)
    colorCombo:AddItems(CONFIG.MARKER_COLORS)
    formatCombo:AddItems(CONFIG.EXPORT_FORMATS)
    styleCombo:AddItems(CONFIG.REPORT_STYLES)

    -- Apply saved preferences or use defaults
    sourceCombo.CurrentIndex = savedPrefs.sourceIndex or 0
    colorCombo.CurrentIndex = savedPrefs.colorIndex or 0
    formatCombo.CurrentIndex = savedPrefs.formatIndex or 0
    styleCombo.CurrentIndex = savedPrefs.styleIndex or 0

    -- Helper to get current UI state as preferences
    local function getCurrentPrefs()
        return {
            sourceIndex = sourceCombo.CurrentIndex,
            colorIndex = colorCombo.CurrentIndex,
            formatIndex = formatCombo.CurrentIndex,
            styleIndex = styleCombo.CurrentIndex,
        }
    end

    -- Helper to collect the current export options from the UI
    local function collectOptions()
        local formatIndex = formatCombo.CurrentIndex  -- 0 = both, 1 = PDF only, 2 = Excel only
        return {
            source = CONFIG.MARKER_SOURCES[sourceCombo.CurrentIndex + 1],
            color = CONFIG.MARKER_COLORS[colorCombo.CurrentIndex + 1],
            formatLabel = CONFIG.EXPORT_FORMATS[formatIndex + 1],
            formats = {
                pdf = formatIndex ~= 2,
                xlsx = formatIndex ~= 1,
            },
            styleLabel = CONFIG.REPORT_STYLES[styleCombo.CurrentIndex + 1],
            withThumbs = styleCombo.CurrentIndex == 0,
            -- Include UI state for preference persistence
            prefs = getCurrentPrefs()
        }
    end

    -- Export button handler (processing runs here so the dialog stays open;
    -- runWithDialogBusy greys the dialog and drops clicks while it runs)
    function dialog.On.ExportButton.Clicked(ev)
        utils.runWithDialogBusy(dialog, runExport, collectOptions())
    end

    function dialog.On.MarkerReportsDialog.Close(ev)
        -- Save current settings before closing
        savePrefs(getCurrentPrefs())
        dispatcher:ExitLoop()
    end

    utils.attachFooterHandler(dialog)

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

utils.printSuccess("Connected to DaVinci Resolve")
local projectName = project:GetName()
utils.printSuccess("Project: " .. (projectName or "Unknown"))

-- Load saved preferences
local savedPrefs = loadPrefs()

-- Run one export from the dialog's button handler; the options dialog stays
-- open while the progress window is up and processing runs
local function runExport(options)
    -- Save preferences immediately (before any validation)
    -- This ensures settings persist even if no timeline is selected
    savedPrefs = options.prefs
    savePrefs(savedPrefs)

    -- Check for selected timelines BEFORE showing directory picker
    utils.printSection("FINDING SELECTED TIMELINES")
    local selectedTimelines = utils.requireSelectedTimelines(project, mediaPool, ui, dispatcher)
    if not selectedTimelines then
        -- Preferences already saved; user can adjust selection and try again
        return
    end

    utils.printSuccess("Found " .. #selectedTimelines .. " selected timeline(s)")

    -- Get output directory
    local outputPath, dirErr = utils.promptForOutputDirectory(ctx.fusion)
    if not outputPath then
        utils.printError(dirErr or "No directory selected")
        return
    end

    print("\nSelected options:")
    print(string.format("  Marker source: %s", options.source))
    print(string.format("  Marker color: %s", options.color))
    print(string.format("  Export format: %s", options.formatLabel))
    print(string.format("  Report style: %s", options.styleLabel))
    print(string.format("  Output directory: %s", outputPath))

    local success, wasCancelled = processTimelines(ctx, selectedTimelines, outputPath, options)

    utils.printSeparator("=", 70)

    if success then
        if wasCancelled then
            utils.printWarning("Cancelled - partial report set kept on disk")
        else
            utils.printSuccess("Marker report export completed successfully!")
        end
    elseif wasCancelled then
        utils.printWarning("Cancelled before any reports were written")
    else
        utils.printError("No reports were written")
    end
end

-- Show options dialog; exports run from its button handler, and the
-- dialog stays open until the user closes it
utils.printSection("SELECT OPTIONS")
showOptionsDialog(ui, dispatcher, savedPrefs, runExport)
print("\nDialog closed by user.")

print("\n")
utils.printSeparator("=", 70)
print("Script completed.")
utils.printSeparator("=", 70)
print()
