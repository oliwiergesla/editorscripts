local SCRIPT_INFO = {
    NAME = "Open EditorScripts Folder",
    VERSION = "1.0.0",
}
-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[
    Opens the EditorScripts install folder in the system file browser
    (Finder / Explorer / xdg-open).

    Installed by every EditorScripts installer into:
        .../Fusion/Scripts/Utility/EditorScripts/Tools/

    Standalone on purpose: no ResolveKit, no require. This file is embedded
    into every installer, so it must stay small and dependency-free.
--]]

-- Levels above this file's directory: Tools -> EditorScripts
local LEVELS_UP = 1

local function dirname(path)
    return path:match("^(.*)[/\\][^/\\]+[/\\]?$")
end

local function pathExists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function getOwnDir()
    -- The closure keeps debug.getinfo's level 1 inside this chunk; calling it
    -- directly through pcall would report pcall's C frame ("=[C]") instead
    local ok, source = pcall(function()
        return debug.getinfo(1, "S").source
    end)
    if ok and type(source) == "string" and source:sub(1, 1) == "@" then
        return dirname(source:sub(2))
    end
    return nil
end

local function getTargetPath()
    -- Primary: derive from this file's own location
    local dir = getOwnDir()
    if dir then
        for _ = 1, LEVELS_UP do
            local parent = dirname(dir)
            if not parent or parent == "" then
                dir = nil
                break
            end
            dir = parent
        end
        if dir then
            return dir
        end
    end

    -- Fallback: Fusion PathMap
    if fusion and fusion.MapPath then
        local mapped = fusion:MapPath("Scripts:/Utility/")
        if mapped and mapped ~= "" and mapped ~= "Scripts:/Utility/" then
            return mapped .. "EditorScripts"
        end
    end

    -- Fallback: known platform paths (FuPLATFORM_* may be undefined in the
    -- Resolve script-menu environment, so detect via path separator / probe)
    if package.config:sub(1, 1) == "\\" then
        local programData = os.getenv("PROGRAMDATA")
        if programData then
            return programData .. "\\Blackmagic Design\\DaVinci Resolve\\Fusion\\Scripts\\Utility\\EditorScripts"
        end
        return nil
    end
    local macPath = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/EditorScripts"
    if pathExists(macPath) then
        return macPath
    end
    return "/var/BlackmagicDesign/DaVinci Resolve/Fusion/Scripts/Utility/EditorScripts"
end

local function openFolder(path)
    if bmd and bmd.openfileexternal then
        bmd.openfileexternal("Open", path)
        return
    end
    if package.config:sub(1, 1) == "\\" then
        os.execute(string.format('explorer "%s"', path:gsub("/", "\\")))
    elseif pathExists("/System/Library/CoreServices/SystemVersion.plist") then
        os.execute(string.format('open "%s"', path))
    else
        os.execute(string.format('xdg-open "%s" &', path))
    end
end

local target = getTargetPath()
if target then
    openFolder(target)
else
    print("[" .. SCRIPT_INFO.NAME .. "] Could not locate the EditorScripts folder.")
end
