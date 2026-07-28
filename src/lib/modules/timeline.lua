-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[
    timeline.lua - Timeline operations for DaVinci Resolve

    Part of ResolveKit - A comprehensive toolkit for DaVinci Resolve scripting

    This module provides:
    - Timeline selection and management
    - Timeline naming utilities
    - Track operations
    - Clip operations
--]]

local Timeline = {}

-- ============================================================================
-- TIMELINE FUNCTIONS
-- ============================================================================

-- Get all selected timeline items from the Media Pool
-- Returns: array of {name = string, timeline = timeline object, clipItem = clip object}, error message
function Timeline.getSelectedTimelines(project, mediaPool)

    -- Get selected clips from Media Pool
    local selectedClips = mediaPool:GetSelectedClips()

    if not selectedClips or #selectedClips == 0 then
        return nil, "No items selected in Media Pool"
    end

    -- Build lookup table: UniqueId -> Timeline (O(m) once, then O(1) lookups)
    -- This avoids O(n*m) iteration when multiple timelines are selected.
    local timelinesByUniqueId = {}
    local timelineCount = project:GetTimelineCount()
    for i = 1, timelineCount do
        local tl = project:GetTimelineByIndex(i)
        if tl then
            local mpItem = tl:GetMediaPoolItem()
            if mpItem then
                timelinesByUniqueId[mpItem:GetUniqueId()] = tl
            end
        end
    end

    -- Filter for timeline items only
    local timelines = {}
    local skippedCount = 0

    for _, clip in ipairs(selectedClips) do
        local clipType = clip:GetClipProperty("Type")

        if clipType == "Timeline" then
            local timelineName = clip:GetName()
            local clipUniqueId = clip:GetUniqueId()

            -- Direct O(1) lookup by UniqueId handles duplicate timeline names
            -- (which can occur when duplicating bins in Resolve's GUI)
            local timelineObject = timelinesByUniqueId[clipUniqueId]

            if timelineObject then
                table.insert(timelines, {
                    name = timelineName,
                    timeline = timelineObject,
                    clipItem = clip
                })
            else
                -- Skip rather than return a nil timeline that callers would crash on
                skippedCount = skippedCount + 1
                print("[WARN] Skipping '" .. timelineName .. "': no matching timeline object found in project")
            end
        end
    end

    if #timelines == 0 then
        if skippedCount > 0 then
            return nil, "Selected timelines could not be matched to any timeline in the project"
        end
        return nil, "No timelines selected (only non-timeline items found)"
    end

    return timelines, nil
end

-- Get timeline duration in seconds
function Timeline.getTimelineDuration(timeline)
    local startFrame = timeline:GetStartFrame()
    local endFrame = timeline:GetEndFrame()
    local frameRate = tonumber(timeline:GetSetting("timelineFrameRate"))

    if not startFrame or not endFrame or not frameRate or frameRate <= 0 then
        return nil, "Could not read timeline duration settings"
    end

    local durationFrames = endFrame - startFrame + 1
    return durationFrames / frameRate, nil
end

-- Set timeline as current (required for many operations)
function Timeline.setCurrentTimeline(project, timeline)
    if not project or not timeline then
        return false, "Invalid project or timeline"
    end

    local success = project:SetCurrentTimeline(timeline)
    if not success then
        return false, "Could not set timeline as current"
    end

    return true, nil
end

-- Get actual timeline resolution (reads from timeline settings, not name)
-- Returns: {width, height, string} or nil, error
function Timeline.getTimelineResolution(timeline)
    if not timeline then
        return nil, "Timeline not available"
    end

    local width = timeline:GetSetting("timelineResolutionWidth")
    local height = timeline:GetSetting("timelineResolutionHeight")

    if not width or not height then
        return nil, "Could not read timeline resolution settings"
    end

    return {
        width = tonumber(width),
        height = tonumber(height),
        string = width .. "x" .. height
    }, nil
end

-- Set flag color on timeline clip in Media Pool
-- flagColor: "Blue", "Cyan", "Green", "Yellow", "Red", "Pink", "Purple", "Fuchsia", "Rose", "Lavender", "Sky", "Mint", "Lemon", "Sand", "Cocoa", "Cream"
-- Returns: success, error
function Timeline.setTimelineFlag(clipItem, flagColor)
    if not clipItem then
        return false, "Clip item not available"
    end

    local success = clipItem:AddFlag(flagColor)
    if not success then
        return false, "Could not set flag color: " .. flagColor
    end

    return true, nil
end

-- Get all timelines in project
-- Returns: array of {timeline, name, index} or nil, error
function Timeline.getAllTimelines(project)
    local timelineCount = project:GetTimelineCount()
    local timelines = {}

    for i = 1, timelineCount do
        local timeline = project:GetTimelineByIndex(i)
        if timeline then
            table.insert(timelines, {
                timeline = timeline,
                name = timeline:GetName(),
                index = i
            })
        end
    end

    return timelines, nil
end

-- ============================================================================
-- MARKER OPERATIONS
-- ============================================================================

-- Count markers in a timeline's marker table
-- Parameters:
--   markers: The markers table from timeline:GetMarkers()
-- Returns: Number of markers (integer)
function Timeline.countMarkers(markers)
    if not markers then return 0 end
    local count = 0
    for _ in pairs(markers) do
        count = count + 1
    end
    return count
end

-- ============================================================================
-- TIMELINE NAME MANIPULATION
-- ============================================================================

-- Extract resolution from timeline name (e.g., "1080x1920", "3840x2160")
function Timeline.extractResolutionFromTimelineName(timelineName)
    return timelineName:match("(%d+x%d+)")
end

-- Remove version suffix from timeline name (e.g., "_V1", "_V2")
function Timeline.removeVersionSuffix(timelineName)
    return timelineName:gsub("_V%d+$", "")
end

-- Modify timeline name: remove version and resolution, add new ones
function Timeline.modifyTimelineName(originalName, newResolution, newVersion)
    local cleanName = originalName

    -- Remove all version suffixes (e.g., _V1, _V2, _V3)
    cleanName = cleanName:gsub("_V%d+", "")

    -- Remove all resolution suffixes (e.g., _1080x1920, _3840x2160)
    cleanName = cleanName:gsub("_%d+x%d+", "")

    local newName = cleanName

    if newResolution then
        newName = newName .. "_" .. newResolution
    end

    if newVersion then
        newName = newName .. "_" .. newVersion
    end

    return newName
end

-- Check if timeline name contains a specific pattern
function Timeline.timelineNameContains(timelineName, pattern)
    return timelineName:find(pattern) ~= nil
end

-- ============================================================================
-- TRACK OPERATIONS
-- ============================================================================

-- Get all tracks in timeline
function Timeline.getTrackCount(timeline, trackType)
    if not timeline then
        return 0
    end

    trackType = trackType or "video"
    return timeline:GetTrackCount(trackType) or 0
end

-- Check if a track is empty
function Timeline.isTrackEmpty(timeline, trackType, trackIndex)
    if not timeline then
        return true
    end

    trackType = trackType or "video"
    local items = timeline:GetItemListInTrack(trackType, trackIndex)

    return not items or #items == 0
end

-- Delete empty video tracks from a timeline
-- Parameters:
--   project: Project object
--   timeline: Timeline object
--   trackType: Track type to process (default: "video")
-- Returns: Number of tracks deleted, error message
function Timeline.deleteEmptyVideoTracks(project, timeline, trackType)
    if not timeline then
        return 0, "Timeline not available"
    end

    trackType = trackType or "video"
    local isTimelineCurrent = false
    local trackCount = Timeline.getTrackCount(timeline, trackType)
    local tracksDeleted = 0

    -- Check tracks from bottom to top (reverse order to avoid index shifting issues)
    for trackIndex = trackCount, 1, -1 do
        if Timeline.isTrackEmpty(timeline, trackType, trackIndex) then
            -- Try to delete track directly first
            local deleteSuccess = timeline:DeleteTrack(trackType, trackIndex)

            -- If direct deletion fails and we haven't set current yet, try with current timeline
            if not deleteSuccess and not isTimelineCurrent and project then
                local success, setErr = Timeline.setCurrentTimeline(project, timeline)
                if success then
                    isTimelineCurrent = true
                    -- Retry deletion with timeline as current
                    deleteSuccess = timeline:DeleteTrack(trackType, trackIndex)
                else
                    return tracksDeleted, setErr or "Could not set timeline as current"
                end
            end

            if deleteSuccess then
                tracksDeleted = tracksDeleted + 1
            end
        end
    end

    return tracksDeleted, nil
end

-- Delete all tracks except specified track index
-- Parameters:
--   project: Project object
--   timeline: Timeline object
--   trackType: Track type to process (default: "video")
--   keepTrackIndex: Track index to keep (default: 1)
-- Returns: Number of tracks deleted, error message
function Timeline.deleteAllTracksExcept(project, timeline, trackType, keepTrackIndex)
    if not timeline then
        return 0, "Timeline not available"
    end

    trackType = trackType or "video"
    keepTrackIndex = keepTrackIndex or 1
    local isTimelineCurrent = false
    local trackCount = Timeline.getTrackCount(timeline, trackType)
    local tracksDeleted = 0

    if trackCount <= 1 then
        return 0, nil  -- Nothing to delete
    end

    -- Delete from highest to lowest to avoid index shifting issues
    for trackIndex = trackCount, 1, -1 do
        -- Skip the track we want to keep
        if trackIndex ~= keepTrackIndex then
            -- Try to delete track directly first
            local deleteSuccess = timeline:DeleteTrack(trackType, trackIndex)

            -- If direct deletion fails and we haven't set current yet, try with current timeline
            if not deleteSuccess and not isTimelineCurrent and project then
                local success, setErr = Timeline.setCurrentTimeline(project, timeline)
                if success then
                    isTimelineCurrent = true
                    -- Retry deletion with timeline as current
                    deleteSuccess = timeline:DeleteTrack(trackType, trackIndex)
                else
                    return tracksDeleted, setErr or "Could not set timeline as current"
                end
            end

            if deleteSuccess then
                tracksDeleted = tracksDeleted + 1
            end
        end
    end

    return tracksDeleted, nil
end

-- ============================================================================
-- CLIP OPERATIONS
-- ============================================================================

-- Helper function to find disabled clips without deleting (no UI switch required)
local function collectDisabledClipsInTrack(timeline, trackType)
    local trackCount = timeline:GetTrackCount(trackType)
    if not trackCount or trackCount == 0 then
        return {}
    end

    -- Collect all disabled clips across all tracks of this type
    local disabledClips = {}

    for trackIndex = 1, trackCount do
        local items = timeline:GetItemListInTrack(trackType, trackIndex)

        if items then
            for _, item in ipairs(items) do
                if not item:GetClipEnabled() then
                    disabledClips[#disabledClips + 1] = item
                end
            end
        end
    end

    return disabledClips
end

-- Batch delete disabled clips in one API call
local function removeDisabledClips(timeline, trackType)
    -- Find disabled clips first
    local clipsToDelete = collectDisabledClipsInTrack(timeline, trackType)

    -- Delete all disabled clips in a single batch operation
    if #clipsToDelete > 0 then
        local success = timeline:DeleteClips(clipsToDelete)
        if success then
            return #clipsToDelete, 0
        else
            return 0, #clipsToDelete
        end
    end

    return 0, 0
end

-- Find all disabled clips in a timeline (without deleting)
-- Parameters:
--   timeline: Timeline object to process
--   includeVideo: (optional) Find disabled video clips (default: true)
--   includeAudio: (optional) Find disabled audio clips (default: true)
-- Returns: table with {videoClips = {...}, audioClips = {...}, totalCount = N}
function Timeline.findDisabledClips(timeline, includeVideo, includeAudio)
    if not timeline then
        return nil, "Timeline not available"
    end

    -- Default to processing both video and audio
    if includeVideo == nil then includeVideo = true end
    if includeAudio == nil then includeAudio = true end

    local result = {
        videoClips = {},
        audioClips = {},
        totalCount = 0
    }

    -- Find disabled video clips
    if includeVideo then
        result.videoClips = collectDisabledClipsInTrack(timeline, "video")
    end

    -- Find disabled audio clips
    if includeAudio then
        result.audioClips = collectDisabledClipsInTrack(timeline, "audio")
    end

    -- Calculate total
    result.totalCount = #result.videoClips + #result.audioClips

    return result, nil
end

-- Delete all disabled clips from a timeline
-- Parameters:
--   timeline: Timeline object to process
--   includeVideo: (optional) Delete disabled video clips (default: true)
--   includeAudio: (optional) Delete disabled audio clips (default: true)
-- Returns: table with statistics {videoDeleted, audioDeleted, totalDeleted, errors}, error message
function Timeline.deleteDisabledClips(timeline, includeVideo, includeAudio)
    if not timeline then
        return nil, "Timeline not available"
    end

    -- Default to processing both video and audio
    if includeVideo == nil then includeVideo = true end
    if includeAudio == nil then includeAudio = true end

    local stats = {
        videoDeleted = 0,
        audioDeleted = 0,
        totalDeleted = 0,
        errors = 0
    }

    -- Process video tracks (batch deletion)
    if includeVideo then
        local videoDeleted, videoErrors = removeDisabledClips(timeline, "video")
        stats.videoDeleted = videoDeleted
        stats.errors = stats.errors + videoErrors
    end

    -- Process audio tracks (batch deletion)
    if includeAudio then
        local audioDeleted, audioErrors = removeDisabledClips(timeline, "audio")
        stats.audioDeleted = audioDeleted
        stats.errors = stats.errors + audioErrors
    end

    -- Calculate total
    stats.totalDeleted = stats.videoDeleted + stats.audioDeleted

    return stats, nil
end

-- Get the last frame of the last ENABLED clip on tracks of the given type
-- Parameters:
--   timeline: Timeline object
--   trackType: "video" or "audio" (default: "video")
-- Returns: lastFrame (number or nil), enabledClipCount (number)
function Timeline.getLastEnabledFrame(timeline, trackType)
    if not timeline then
        return nil, 0
    end

    trackType = trackType or "video"
    local trackCount = timeline:GetTrackCount(trackType)

    if not trackCount or trackCount == 0 then
        return nil, 0
    end

    local maxEndFrame = nil
    local enabledClipCount = 0

    -- Scan all tracks of the requested type
    for trackIndex = 1, trackCount do
        local items = timeline:GetItemListInTrack(trackType, trackIndex)

        if items and #items > 0 then
            for _, item in ipairs(items) do
                -- Check if the item is enabled
                local isEnabled = item:GetClipEnabled()

                if isEnabled then
                    enabledClipCount = enabledClipCount + 1

                    -- Get the end frame of this clip
                    -- GetEnd() returns the frame AFTER the last frame of the clip
                    -- So we subtract 1 to get the actual last visible frame
                    local endFrame = item:GetEnd() - 1

                    -- Track the maximum end frame
                    if not maxEndFrame or endFrame > maxEndFrame then
                        maxEndFrame = endFrame
                    end
                end
            end
        end
    end

    return maxEndFrame, enabledClipCount
end

-- Find all clips with specific names on a timeline
-- Parameters:
--   timeline: Timeline object to search
--   targetNames: Array of clip names to find (e.g., {"Clip A", "Clip B"})
--   trackType: Track type to search (default: "video")
-- Returns: Array of clip info tables with {item, track, startFrame, endFrame, duration, sourceName}
function Timeline.findClipsByNames(timeline, targetNames, trackType)
    if not timeline or not targetNames then
        return {}
    end

    trackType = trackType or "video"
    local foundClips = {}
    local trackCount = timeline:GetTrackCount(trackType)

    if not trackCount or trackCount == 0 then
        return foundClips
    end

    -- Build O(1) lookup set from targetNames (avoids O(n) inner loop per clip)
    local nameSet = {}
    for _, name in ipairs(targetNames) do
        nameSet[name] = true
    end

    for trackIndex = 1, trackCount do
        local items = timeline:GetItemListInTrack(trackType, trackIndex)
        if items then
            for _, item in ipairs(items) do
                local clipName = item:GetName()
                if nameSet[clipName] then
                    table.insert(foundClips, {
                        item = item,
                        track = trackIndex,
                        startFrame = item:GetStart(),
                        endFrame = item:GetEnd(),
                        duration = item:GetDuration(),
                        sourceName = clipName
                    })
                end
            end
        end
    end

    return foundClips
end

-- Replace a clip on the timeline with another media pool item
-- Parameters:
--   project: Project object
--   timeline: Timeline object
--   mediaPool: MediaPool object
--   oldClipInfo: Clip info table from findClipsByNames (must have: item, track, startFrame, duration)
--   newMediaPoolItem: The new media pool item to insert
-- Returns: success (boolean), error message
function Timeline.replaceClip(project, timeline, mediaPool, oldClipInfo, newMediaPoolItem)
    if not project or not timeline or not mediaPool or not oldClipInfo or not newMediaPoolItem then
        return false, "Missing required parameters"
    end

    -- Set the timeline as current for DeleteClips to work
    local wasCurrentTimeline = project:GetCurrentTimeline() == timeline
    if not wasCurrentTimeline then
        local success, err = Timeline.setCurrentTimeline(project, timeline)
        if not success then
            return false, err or "Could not set timeline as current"
        end
    end

    -- Delete the old clip
    local success = timeline:DeleteClips({oldClipInfo.item})
    if not success then
        return false, "Failed to delete original clip"
    end

    -- Calculate the source duration we need
    local clipDuration = oldClipInfo.duration

    -- Prepare clip info for insertion
    local clipInfo = {
        mediaPoolItem = newMediaPoolItem,
        trackIndex = oldClipInfo.track,
        recordFrame = oldClipInfo.startFrame,
        startFrame = 0,
        endFrame = clipDuration
    }

    -- Add the new clip at the same position
    local addedClips = mediaPool:AppendToTimeline({clipInfo})

    if not addedClips or #addedClips == 0 then
        return false, "Failed to add replacement clip"
    end

    return true, nil
end

-- ============================================================================
-- TIMELINE SETTINGS OPERATIONS
-- ============================================================================

-- Output color keys the API refuses to write while "separate color space and
-- gamma" is active (same limitation settings_sync works around)
local OUTPUT_COLOR_KEYS = {
    colorSpaceOutput = true,
    colorSpaceOutputGamma = true,
}

-- Keys never restored by enableCustomTimelineSettings: resolution belongs to
-- callers; useCustomSettings is the flip itself
local RESTORE_SKIP_KEYS = {
    useCustomSettings = true,
    timelineResolutionWidth = true,
    timelineResolutionHeight = true,
}

-- Frame rate keys cannot be written via the scripting API
local function isFrameRateKey(key)
    return string.find(key, "FrameRate") ~= nil
end

-- Enable custom settings on a timeline, preserving inherited project settings.
-- A raw useCustomSettings flip resets color preferences (color science, color
-- spaces, ...) on timelines that had "Use Project Settings" ticked. While that
-- flag is "0" the timeline's effective settings ARE the project's, so this
-- snapshots project:GetSetting() before the flip and re-applies the values
-- afterwards. The timeline's own settings dict defines WHICH keys to restore
-- (the project dict has project-only keys a timeline won't accept); the
-- project dict supplies the values, falling back to the timeline dict for
-- timeline-only keys. Does not require the timeline to be current.
-- Parameters:
--   project: Project object (source of inherited values)
--   timeline: Timeline object to enable custom settings on
-- Returns: stats {wasInherited, preservedCount, skippedCount, failedKeys}, error
--   wasInherited false means the timeline already used custom settings and
--   nothing was written; skippedCount counts API-limitation skips only
function Timeline.enableCustomTimelineSettings(project, timeline)
    if not project or not timeline then
        return nil, "Invalid project or timeline"
    end

    local stats = {wasInherited = false, preservedCount = 0,
                   skippedCount = 0, failedKeys = {}}

    -- useCustomSettings is not in the no-arg settings dict; read it by key
    if timeline:GetSetting("useCustomSettings") == "1" then
        return stats, nil
    end
    stats.wasInherited = true

    -- Snapshot BEFORE the flip, while values are still project-inherited
    local timelineDict = timeline:GetSetting() or {}
    local projectDict = project:GetSetting() or {}

    -- Every other SetSetting call fails while useCustomSettings is "0"
    if not timeline:SetSetting("useCustomSettings", "1") then
        return nil, "Could not enable custom settings"
    end

    -- Timeline-key namespace, project-dict values
    local restore = {}
    for key, tlValue in pairs(timelineDict) do
        if not RESTORE_SKIP_KEYS[key] and not isFrameRateKey(key) then
            local value = projectDict[key]
            if value == nil then value = tlValue end
            restore[key] = value
        end
    end

    -- separateColorSpaceAndGamma must land first so dependent color keys are
    -- written in the right mode; its value gates the output-key skip below
    local separateValue = restore["separateColorSpaceAndGamma"]
    local separateOn = tostring(separateValue or "") == "1"
    if separateValue ~= nil then
        restore["separateColorSpaceAndGamma"] = nil
        if timeline:SetSetting("separateColorSpaceAndGamma", separateValue) then
            stats.preservedCount = stats.preservedCount + 1
        else
            table.insert(stats.failedKeys, "separateColorSpaceAndGamma")
        end
    end

    -- Blind re-writes are cheap (SetSetting same-value fast path); individual
    -- failures are collected, never fatal (some keys are context-gated)
    for key, value in pairs(restore) do
        if separateOn and OUTPUT_COLOR_KEYS[key] then
            stats.skippedCount = stats.skippedCount + 1
        elseif timeline:SetSetting(key, value) then
            stats.preservedCount = stats.preservedCount + 1
        else
            table.insert(stats.failedKeys, key)
        end
    end

    return stats, nil
end

-- ============================================================================
-- RETURN MODULE
-- ============================================================================

return Timeline