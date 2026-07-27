-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[
    media.lua - Media pool and render operations for DaVinci Resolve

    Part of ResolveKit - A comprehensive toolkit for DaVinci Resolve scripting

    This module provides:
    - Bin/folder operations in the Media Pool
    - Media item search and management
    - Render settings calculations
--]]

local Media = {}

-- ============================================================================
-- BIN/FOLDER OPERATIONS
-- ============================================================================

-- First direct child of folder with this name, or nil. Deliberately does NOT
-- search deeper: get-or-create semantics must never adopt a same-named bin
-- from an unrelated nested branch (and Resolve does not enforce unique bin
-- names, so first-match among siblings is the deterministic choice)
local function findChildBin(folder, targetName)
    for _, subFolder in ipairs(folder:GetSubFolderList()) do
        if subFolder:GetName() == targetName then
            return subFolder
        end
    end
    return nil
end

-- Get or create a bin as a DIRECT CHILD of parentFolder (nil = current folder);
-- never searches deeper. The current folder view is unchanged on return.
-- Returns: bin object, error message
function Media.getBin(mediaPool, binName, parentFolder)
    if not binName or binName == "" then
        return nil, "Bin name not provided"
    end

    -- Save the current folder view before any operations
    local originalFolder = mediaPool:GetCurrentFolder()

    -- Use current folder if no parent specified
    local targetFolder = parentFolder or originalFolder

    if not targetFolder then
        return nil, "Could not access target folder"
    end

    -- Try to find an existing direct child first
    local existingBin = findChildBin(targetFolder, binName)

    if existingBin then
        return existingBin, nil
    end

    -- Create new bin (this will automatically switch the view to the new folder)
    local newBin = mediaPool:AddSubFolder(targetFolder, binName)
    if not newBin then
        -- A failed AddSubFolder should not have moved the view, but restore
        -- defensively so both exit paths uphold the unchanged-view contract
        if originalFolder then
            mediaPool:SetCurrentFolder(originalFolder)
        end
        return nil, "Could not create bin: " .. binName
    end

    -- Restore the original folder view to keep the user where they were
    if originalFolder then
        mediaPool:SetCurrentFolder(originalFolder)
    end

    return newBin, nil
end

-- Recursively collect media pool clips under a folder
-- Parameters:
--   folder: Starting folder (typically mediaPool:GetRootFolder())
--   filterFn: Optional function(clip) -> boolean; only matching clips are kept
-- Returns: Array of MediaPoolItem objects
function Media.collectClips(folder, filterFn, results)
    results = results or {}

    if not folder then
        return results
    end

    local clips = folder:GetClipList()
    if clips then
        for _, clip in ipairs(clips) do
            if not filterFn or filterFn(clip) then
                results[#results + 1] = clip
            end
        end
    end

    local subFolders = folder:GetSubFolderList()
    if subFolders then
        for _, subFolder in ipairs(subFolders) do
            Media.collectClips(subFolder, filterFn, results)
        end
    end

    return results
end

-- Build a clip name -> MediaPoolItem cache for O(1) lookups
-- Use this when you need to find multiple media pool items in a single script run
-- Parameters:
--   mediaPool: MediaPool object
--   currentBin: Optional starting bin (defaults to root folder)
--   cache: Optional existing cache table to extend
-- Returns: Table mapping clip names to MediaPoolItem objects
function Media.buildMediaPoolCache(mediaPool, currentBin, cache)
    cache = cache or {}
    currentBin = currentBin or mediaPool:GetRootFolder()

    if not currentBin then
        return cache
    end

    local clips = currentBin:GetClipList()
    if clips then
        for _, clip in ipairs(clips) do
            cache[clip:GetName()] = clip
        end
    end

    local subFolders = currentBin:GetSubFolderList()
    if subFolders then
        for _, folder in ipairs(subFolders) do
            Media.buildMediaPoolCache(mediaPool, folder, cache)
        end
    end

    return cache
end

-- Find a media pool item by name (searches recursively through bins)
-- Parameters:
--   mediaPool: MediaPool object
--   itemName: Name of the item to find
--   currentBin: Optional starting bin (defaults to root folder)
-- Returns: MediaPoolItem object or nil
function Media.findMediaPoolItem(mediaPool, itemName, currentBin)
    if not itemName then
        return nil
    end

    currentBin = currentBin or mediaPool:GetRootFolder()

    if not currentBin then
        return nil
    end

    -- Check clips in current bin
    local clips = currentBin:GetClipList()
    if clips then
        for _, clip in ipairs(clips) do
            if clip:GetName() == itemName then
                return clip
            end
        end
    end

    -- Check subfolders recursively
    local subFolders = currentBin:GetSubFolderList()
    if subFolders then
        for _, folder in ipairs(subFolders) do
            local result = Media.findMediaPoolItem(mediaPool, itemName, folder)
            if result then
                return result
            end
        end
    end

    return nil
end

-- ============================================================================
-- RENDER SETTINGS
-- ============================================================================

-- Calculate video bitrate in Kb/s to target a specific file size in MB
-- Parameters:
--   limitMB: Target file size in megabytes
--   durationSeconds: Duration of the video in seconds
--   minKbps: Minimum allowed video bitrate (default: 200)
--   maxKbps: Maximum allowed video bitrate (default: 50000)
--   audioBitrate: Audio bitrate in Kbps to subtract from total budget (default: 0)
-- Returns: Video bitrate in Kbps, or nil if invalid duration
function Media.calculateBitrateForFileSize(limitMB, durationSeconds, minKbps, maxKbps, audioBitrate)
    if durationSeconds <= 0 then
        return nil
    end

    minKbps = minKbps or 200
    maxKbps = maxKbps or 50000
    audioBitrate = audioBitrate or 0

    local bytes_per_mb = 1024 * 1024
    local bits_per_byte = 8

    -- Calculate total bitrate budget with a safety margin (multiply by 0.95 to stay under limit)
    -- This accounts for container overhead and encoding variance
    local total_bitrate_kbps = ((limitMB * bytes_per_mb * bits_per_byte) / durationSeconds / 1000) * 0.95

    -- Subtract audio bitrate from total budget to get video bitrate
    local video_bitrate_kbps = math.floor(total_bitrate_kbps - audioBitrate)

    -- Ensure video bitrate is not negative
    if video_bitrate_kbps < 0 then
        video_bitrate_kbps = 0
    end

    -- Clamp to safe range
    if video_bitrate_kbps < minKbps then
        video_bitrate_kbps = minKbps
    end
    if video_bitrate_kbps > maxKbps then
        video_bitrate_kbps = maxKbps
    end

    return video_bitrate_kbps
end


-- ============================================================================
-- RETURN MODULE
-- ============================================================================

return Media
