-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[
    filesystem.lua - File system operations, JSON, and settings management

    Part of ResolveKit - A comprehensive toolkit for DaVinci Resolve scripting

    This module provides:
    - File and directory operations
    - JSON encoding/decoding
    - Settings management
--]]

local FileSystem = {}

-- ============================================================================
-- FILE SYSTEM OPERATIONS
-- ============================================================================

-- Sanitize filename to remove illegal characters
function FileSystem.sanitizeFilename(name)
    -- Replace illegal path characters with underscore
    local sanitized = name:gsub('[<>:"/\\|?*]', '_')
    return sanitized
end

-- Check if file exists using Fusion's native bmd.fileexists()
function FileSystem.fileExists(path)
    return bmd.fileexists(path)
end

-- Create directory using Fusion's native bmd functions
-- Supports nested path creation (like mkdir -p)
function FileSystem.createDirectory(path)
    if bmd.direxists(path) then
        return true
    end
    return bmd.createdir(path)
end

-- Check if directory exists using Fusion's native bmd.direxists()
function FileSystem.directoryExists(path)
    return bmd.direxists(path)
end

-- Join two path segments with the platform separator (trims stray separators
-- at the joint). Uses package.config rather than FuPLATFORM_* globals so it
-- also works under bare fuscript, where those globals are absent.
function FileSystem.joinPath(a, b)
    local sep = package.config:sub(1, 1)
    return (a:gsub("[/\\]+$", "")) .. sep .. (b:gsub("^[/\\]+", ""))
end

-- Extract filename from full path
function FileSystem.getFilename(path)
    return path:match("([^/\\]+)$")
end

-- Extract file extension from path (preserves original case)
function FileSystem.getExtension(path)
    if not path or path == "" then return "" end
    local ext = path:match("%.([^%.]+)$")
    return ext or ""
end

-- Generate a unique filename if there's a conflict
function FileSystem.getUniqueFilePath(destDir, filename)
    local basePath = FileSystem.joinPath(destDir, filename)

    if not FileSystem.fileExists(basePath) then
        return basePath, filename
    end

    -- Extract name and extension
    local name, ext = filename:match("^(.+)(%.[^%.]+)$")
    if not name then
        name = filename
        ext = ""
    end

    -- Try appending _1, _2, etc.
    local counter = 1
    while counter <= 1000 do
        local newFilename = name .. "_" .. counter .. ext
        local newPath = FileSystem.joinPath(destDir, newFilename)

        if not FileSystem.fileExists(newPath) then
            return newPath, newFilename
        end

        counter = counter + 1
    end

    return nil, nil
end

-- Copy file from source to destination (for cross-device moves)
-- Chunked so multi-GB media files never get loaded into memory whole
function FileSystem.copyFile(source, dest)
    local sourceFile = io.open(source, "rb")
    if not sourceFile then
        return false, "Could not open source file"
    end

    local destFile = io.open(dest, "wb")
    if not destFile then
        sourceFile:close()
        return false, "Could not create destination file"
    end

    local chunkSize = 16 * 1024 * 1024  -- 16 MB
    while true do
        local chunk = sourceFile:read(chunkSize)
        if not chunk then
            break  -- End of file
        end

        local writeSuccess, writeErr = destFile:write(chunk)
        if not writeSuccess then
            sourceFile:close()
            destFile:close()
            return false, "Could not write to destination file: " .. tostring(writeErr)
        end

        if #chunk < chunkSize then
            break  -- Last (short) chunk
        end
    end

    sourceFile:close()
    destFile:close()

    return true
end

-- Move file (handles cross-device moves)
function FileSystem.moveFile(source, dest)
    -- Try simple rename first (works for same device)
    local success, err = os.rename(source, dest)

    if success then
        return true, nil
    end

    -- If rename failed due to cross-device link, do copy + delete
    if err and (err:match("Cross%-device link") or err:match("Invalid cross%-device link")) then
        -- Copy the file
        local copySuccess, copyErr = FileSystem.copyFile(source, dest)
        if not copySuccess then
            return false, "Copy failed: " .. (copyErr or "unknown error")
        end

        -- Verify the copy was successful by checking file exists
        if not FileSystem.fileExists(dest) then
            return false, "Copy verification failed"
        end

        -- Delete the original file
        local deleteSuccess = os.remove(source)
        if not deleteSuccess then
            return false, "File copied but original could not be deleted"
        end

        return true, nil
    end

    -- Some other error occurred
    return false, err
end

-- ============================================================================
-- DIRECTORY ENUMERATION
-- ============================================================================

-- List one directory level. Primary backend is bmd.readdir (shell-free; on
-- Windows io.popen can flash a console window). readdir takes a glob and
-- returns an array of { Name = ..., IsDir = ... } entries; the shape is
-- sanity-checked so an unexpected return falls through to the shell backend
-- instead of silently reading as an empty directory.
-- Returns: array of { name, isDir } or nil when the backend is unusable.
local function readDirNative(dir)
    if not (bmd and type(bmd.readdir) == "function") then
        return nil
    end
    local ok, result = pcall(bmd.readdir, dir:gsub("[/\\]+$", "") .. "/*")
    if not ok or type(result) ~= "table" then
        return nil
    end
    local entries = {}
    for _, entry in ipairs(result) do
        if type(entry) == "table" and type(entry.Name) == "string" then
            entries[#entries + 1] = {
                name = entry.Name:gsub("[/\\]+$", ""),
                isDir = entry.IsDir and true or false,
            }
        end
    end
    if #result > 0 and #entries == 0 then
        return nil  -- non-empty result in an unknown shape: use the fallback
    end
    return entries
end

-- Shell fallback for readDirNative. macOS/Linux: `ls -1p` (trailing slash
-- marks directories). Windows: two `dir /b` calls (dirs then files).
-- Returns: array of { name, isDir } or nil on failure.
local function readDirShell(dir)
    local entries = {}
    if package.config:sub(1, 1) == "\\" then
        local listings = {
            { flags = "/b /ad", isDir = true },
            { flags = "/b /a-d", isDir = false },
        }
        for _, listing in ipairs(listings) do
            local pipe = io.popen(string.format('dir %s "%s" 2>nul', listing.flags, dir))
            if not pipe then
                return nil
            end
            for line in pipe:lines() do
                if line ~= "" then
                    entries[#entries + 1] = { name = line, isDir = listing.isDir }
                end
            end
            pipe:close()
        end
    else
        local pipe = io.popen(string.format("ls -1p '%s' 2>/dev/null", dir:gsub("'", "'\\''")))
        if not pipe then
            return nil
        end
        for line in pipe:lines() do
            if line ~= "" then
                local name = line:gsub("/$", "")
                entries[#entries + 1] = { name = name, isDir = line:sub(-1) == "/" }
            end
        end
        pipe:close()
    end
    return entries
end

-- Walk a directory tree and collect files.
-- opts:
--   recursive   (default true)  - descend into subdirectories
--   extension   (default nil)   - case-insensitive extension filter, no dot
--   skipDotDirs (default true)  - skip dot-prefixed entries (.bin, .data,
--                                 .git, .DS_Store) at every level
--   maxDepth    (default 12)    - recursion guard against symlink cycles
-- Returns: entries, nil on success or nil, error on failure. Each entry is
-- { path, relativePath, name }; relativePath is "/"-joined on all platforms.
-- Unreadable subdirectories are skipped; only a top-level failure errors.
-- Callers sort the result themselves.
function FileSystem.walkDirectory(dir, opts)
    opts = opts or {}
    local recursive = opts.recursive ~= false
    local skipDotDirs = opts.skipDotDirs ~= false
    local maxDepth = opts.maxDepth or 12
    local extension = opts.extension and opts.extension:lower() or nil

    if not FileSystem.directoryExists(dir) then
        return nil, "Directory not found: " .. tostring(dir)
    end

    local results = {}

    local function visit(currentDir, relPrefix, depth)
        local entries = readDirNative(currentDir) or readDirShell(currentDir)
        if not entries then
            return depth == 1 and false or true
        end
        for _, entry in ipairs(entries) do
            local name = entry.name
            local skip = name == "." or name == ".."
                or (skipDotDirs and name:sub(1, 1) == ".")
            if not skip then
                local rel = relPrefix == "" and name or (relPrefix .. "/" .. name)
                if entry.isDir then
                    if recursive and depth < maxDepth then
                        visit(FileSystem.joinPath(currentDir, name), rel, depth + 1)
                    end
                elseif not extension or FileSystem.getExtension(name):lower() == extension then
                    results[#results + 1] = {
                        path = FileSystem.joinPath(currentDir, name),
                        relativePath = rel,
                        name = name,
                    }
                end
            end
        end
        return true
    end

    if not visit(dir, "", 1) then
        return nil, "Could not list directory: " .. dir
    end
    return results, nil
end

-- ============================================================================
-- JSON UTILITIES
-- ============================================================================

-- Lookup table for JSON string escaping (single-pass optimization)
local jsonEscapeChars = {
    ['\\'] = '\\\\',
    ['"'] = '\\"',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t'
}

-- Simple JSON encoder for Lua tables
-- Supports: strings, numbers, booleans, nil, tables (as objects or arrays)
local function encodeJSON(value, indent)
    indent = indent or 0
    local indentStr = string.rep("  ", indent)
    local valueType = type(value)

    if valueType == "nil" then
        return "null"
    elseif valueType == "boolean" then
        return value and "true" or "false"
    elseif valueType == "number" then
        return tostring(value)
    elseif valueType == "string" then
        -- Escape special characters (single-pass using lookup table)
        local escaped = value:gsub('[\\"\n\r\t]', jsonEscapeChars)
        return '"' .. escaped .. '"'
    elseif valueType == "table" then
        -- Check if it's an array (consecutive integer keys starting at 1)
        local isArray = true
        local count = 0
        for k, v in pairs(value) do
            count = count + 1
            if type(k) ~= "number" or k ~= count then
                isArray = false
                break
            end
        end

        if isArray then
            -- Encode as JSON array
            if count == 0 then
                return "[]"
            end

            local parts = {}
            for i = 1, count do
                parts[#parts + 1] = indentStr .. "  " .. encodeJSON(value[i], indent + 1)
            end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indentStr .. "]"
        else
            -- Encode as JSON object
            local parts = {}
            for k, v in pairs(value) do
                if type(k) == "string" then
                    parts[#parts + 1] = indentStr .. "  " .. encodeJSON(k) .. ": " .. encodeJSON(v, indent + 1)
                end
            end

            if #parts == 0 then
                return "{}"
            end

            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indentStr .. "}"
        end
    else
        return "null"
    end
end

-- Simple JSON decoder for Lua
-- Supports: strings, numbers, booleans, null, objects, arrays
local function decodeJSON(jsonStr)
    if not jsonStr or jsonStr == "" then
        return nil, "Empty JSON string"
    end

    -- Remove whitespace
    local pos = 1

    local function skipWhitespace()
        while pos <= #jsonStr do
            local char = jsonStr:sub(pos, pos)
            if char ~= ' ' and char ~= '\t' and char ~= '\n' and char ~= '\r' then
                break
            end
            pos = pos + 1
        end
    end

    local function parseValue()
        skipWhitespace()

        if pos > #jsonStr then
            return nil, "Unexpected end of JSON"
        end

        local char = jsonStr:sub(pos, pos)

        -- null
        if jsonStr:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        end

        -- true
        if jsonStr:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        end

        -- false
        if jsonStr:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        end

        -- string
        if char == '"' then
            pos = pos + 1
            local value = ""

            while pos <= #jsonStr do
                char = jsonStr:sub(pos, pos)

                if char == '"' then
                    pos = pos + 1
                    return value
                elseif char == '\\' then
                    pos = pos + 1
                    local escapeChar = jsonStr:sub(pos, pos)
                    if escapeChar == 'n' then
                        value = value .. '\n'
                    elseif escapeChar == 'r' then
                        value = value .. '\r'
                    elseif escapeChar == 't' then
                        value = value .. '\t'
                    elseif escapeChar == '\\' then
                        value = value .. '\\'
                    elseif escapeChar == '"' then
                        value = value .. '"'
                    else
                        value = value .. escapeChar
                    end
                    pos = pos + 1
                else
                    value = value .. char
                    pos = pos + 1
                end
            end

            return nil, "Unterminated string"
        end

        -- number
        if char == '-' or (char >= '0' and char <= '9') then
            local startPos = pos

            if char == '-' then
                pos = pos + 1
            end

            while pos <= #jsonStr do
                char = jsonStr:sub(pos, pos)
                if (char >= '0' and char <= '9') or char == '.' or char == 'e' or char == 'E' or char == '+' or char == '-' then
                    pos = pos + 1
                else
                    break
                end
            end

            local numStr = jsonStr:sub(startPos, pos - 1)
            return tonumber(numStr)
        end

        -- object
        if char == '{' then
            pos = pos + 1
            local obj = {}

            skipWhitespace()
            if jsonStr:sub(pos, pos) == '}' then
                pos = pos + 1
                return obj
            end

            while true do
                skipWhitespace()

                -- Parse key (must be string)
                if jsonStr:sub(pos, pos) ~= '"' then
                    return nil, "Expected string key in object"
                end

                local key = parseValue()
                if not key then
                    return nil, "Invalid object key"
                end

                skipWhitespace()

                -- Expect colon
                if jsonStr:sub(pos, pos) ~= ':' then
                    return nil, "Expected ':' after object key"
                end
                pos = pos + 1

                -- Parse value
                local value, err = parseValue()
                if err then
                    return nil, err
                end

                obj[key] = value

                skipWhitespace()

                char = jsonStr:sub(pos, pos)
                if char == '}' then
                    pos = pos + 1
                    return obj
                elseif char == ',' then
                    pos = pos + 1
                else
                    return nil, "Expected ',' or '}' in object"
                end
            end
        end

        -- array
        if char == '[' then
            pos = pos + 1
            local arr = {}

            skipWhitespace()
            if jsonStr:sub(pos, pos) == ']' then
                pos = pos + 1
                return arr
            end

            while true do
                local value, err = parseValue()
                if err then
                    return nil, err
                end

                arr[#arr + 1] = value

                skipWhitespace()

                char = jsonStr:sub(pos, pos)
                if char == ']' then
                    pos = pos + 1
                    return arr
                elseif char == ',' then
                    pos = pos + 1
                else
                    return nil, "Expected ',' or ']' in array"
                end
            end
        end

        return nil, "Unexpected character: " .. char
    end

    local value, err = parseValue()
    if err then
        return nil, err
    end

    return value
end

-- Export JSON functions with module prefix
FileSystem.encodeJSON = encodeJSON
FileSystem.decodeJSON = decodeJSON

-- Read and JSON-decode a file
-- Returns: value, nil on success or nil, error (missing file, read or parse failure)
function FileSystem.readJSONFile(path)
    if not path or path == "" then
        return nil, "No file path provided"
    end

    local file = io.open(path, "r")
    if not file then
        return nil, "Could not open file: " .. path
    end

    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        return nil, "File is empty: " .. path
    end

    local value, err = decodeJSON(content)
    if value == nil then
        return nil, "Could not parse JSON in " .. path .. (err and (": " .. err) or "")
    end

    return value, nil
end

-- Encode data as JSON and write it to path, creating the parent directory if needed
-- Returns: true, nil on success or nil, error
function FileSystem.writeJSONFile(path, data)
    if not path or path == "" then
        return nil, "No file path provided"
    end
    if data == nil then
        return nil, "No data provided"
    end

    local parentDir = path:match("^(.*)[/\\][^/\\]+$")
    if parentDir and parentDir ~= "" and not FileSystem.directoryExists(parentDir) then
        if not FileSystem.createDirectory(parentDir) then
            return nil, "Could not create directory: " .. parentDir
        end
    end

    local file = io.open(path, "w")
    if not file then
        return nil, "Could not open file for writing: " .. path
    end

    local ok = file:write(encodeJSON(data))
    file:close()

    if not ok then
        return nil, "Could not write file: " .. path
    end

    return true, nil
end

-- ============================================================================
-- SCRIPT DIRECTORY & DATA DIRECTORY
-- All runtime files a script generates (settings, state, logs, launchers)
-- live in a hidden .data folder NEXT TO the script itself, never in $HOME.
-- Installed scripts share <EditorScripts>/.data; uninstalling = deleting one
-- folder. The dot prefix keeps the folder out of Resolve's Scripts menu
-- (which builds submenus from subfolders) and out of Finder.
-- ============================================================================

-- Canonical install locations, used only if the stack walk below fails
-- (mirrors the fallbacks in src/installer/installer_template.lua)
local INSTALLED_SCRIPTS_DIRS = {
    "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/EditorScripts",
    -- macOS: Resolve maps Scripts:/ to the per-user Library folder, so the
    -- installer writes there (verified via MapPath on macOS); the system
    -- /Library path above is kept for hand-installed copies.
    (os.getenv("HOME") or "") .. "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/EditorScripts",
    -- Windows: the Support\Fusion path is where Resolve actually installs user
    -- scripts (verified on Windows via MapPath); the remaining entries are
    -- retained as fallbacks for older install layouts.
    (os.getenv("APPDATA") or "") .. "\\Blackmagic Design\\DaVinci Resolve\\Support\\Fusion\\Scripts\\Utility\\EditorScripts",
    (os.getenv("APPDATA") or "") .. "\\Blackmagic Design\\DaVinci Resolve\\Fusion\\Scripts\\Utility\\EditorScripts",
    (os.getenv("PROGRAMDATA") or "") .. "\\Blackmagic Design\\DaVinci Resolve\\Fusion\\Scripts\\Utility\\EditorScripts",
    "/var/BlackmagicDesign/DaVinci Resolve/Fusion/Scripts/Utility/EditorScripts",
}

local cachedScriptPath = nil
local cachedScriptDir = nil

-- Get the file path of the RUNNING SCRIPT (not this module).
-- Walks the call stack for the outermost main chunk: in dev that is the
-- script file in src/scripts/, in dist builds everything is bundled into
-- one installed file, so any main chunk resolves to it. No install-dir
-- fallback here - that is a directory concept (see getScriptDir).
-- Returns: path, nil on success or nil, error on failure
function FileSystem.getScriptPath()
    if cachedScriptPath then
        return cachedScriptPath, nil
    end

    if debug and debug.getinfo then
        local mainSource = nil
        local level = 2
        while true do
            local info = debug.getinfo(level, "S")
            if not info then break end
            if info.what == "main" and type(info.source) == "string" then
                mainSource = info.source
            end
            level = level + 1
        end
        local path = mainSource and mainSource:match("^@(.+)$")
        if path and FileSystem.fileExists(path) then
            cachedScriptPath = path
            return cachedScriptPath, nil
        end
    end

    return nil, "Could not locate the running script file."
end

-- Get the directory of the RUNNING SCRIPT (not this module).
-- Derived from getScriptPath(); falls back to the canonical install
-- locations when the stack walk fails.
-- Returns: path, nil on success or nil, error on failure
function FileSystem.getScriptDir()
    if cachedScriptDir then
        return cachedScriptDir, nil
    end

    local path = FileSystem.getScriptPath()
    local dir = path and path:match("^(.*)[/\\][^/\\]+$")
    if dir then
        cachedScriptDir = dir
        return cachedScriptDir, nil
    end

    for _, fallbackDir in ipairs(INSTALLED_SCRIPTS_DIRS) do
        if FileSystem.directoryExists(fallbackDir) then
            cachedScriptDir = fallbackDir
            return cachedScriptDir, nil
        end
    end

    return nil, "Could not locate the running script's folder."
end

-- Get the hidden data directory next to the running script (not created here;
-- callers create it via createDirectory before writing).
-- Returns: path, nil on success or nil, error on failure
function FileSystem.getDataDir()
    local scriptDir, err = FileSystem.getScriptDir()
    if not scriptDir then
        return nil, err
    end
    return FileSystem.joinPath(scriptDir, ".data"), nil
end

-- ============================================================================
-- SETTINGS MANAGEMENT
-- ============================================================================

-- Get the path to the user settings file
local function getUserSettingsPath()
    local dataDir, err = FileSystem.getDataDir()
    if not dataDir then
        return nil, err
    end
    return FileSystem.joinPath(dataDir, "user_preferences.json"), nil
end

-- Get hardcoded default settings (no external file needed)
local function getDefaultSettings()
    return {}
end

-- Deep merge two tables (userSettings overwrites defaultSettings)
local function mergeTables(defaults, overrides)
    if not defaults then return overrides or {} end
    if not overrides then return defaults end

    local result = {}

    -- Copy all values from defaults
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            result[k] = mergeTables(v, nil)  -- Deep copy
        else
            result[k] = v
        end
    end

    -- Override with user settings
    for k, v in pairs(overrides) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = mergeTables(result[k], v)  -- Recursive merge
        else
            result[k] = v
        end
    end

    return result
end

-- Load settings from JSON file
-- Returns: settings table or nil, error
function FileSystem.loadSettings()
    -- Get hardcoded defaults
    local defaults = getDefaultSettings()

    -- Try to load user settings
    local userPath = getUserSettingsPath()

    if not userPath then
        -- If we can't locate the script's data folder, just use defaults
        return defaults, nil
    end

    local userFile = io.open(userPath, "r")

    if userFile then
        local content = userFile:read("*all")
        userFile:close()

        local userSettings, err = decodeJSON(content)
        if userSettings then
            -- Merge user settings over defaults
            return mergeTables(defaults, userSettings), nil
        end
        -- If user settings are corrupted, just use defaults
    end

    -- No user settings or failed to load, return defaults
    return defaults, nil
end

-- Save settings to user preferences file
-- Returns: success, error
function FileSystem.saveSettings(settings)
    if not settings then
        return false, "No settings provided"
    end

    -- Ensure the data directory exists
    local dataDir, dirErr = FileSystem.getDataDir()
    if not dataDir then
        return false, dirErr
    end
    FileSystem.createDirectory(dataDir)

    -- Encode to JSON (encodeJSON always returns a string)
    local jsonStr = encodeJSON(settings)

    -- Write to file
    local userPath = getUserSettingsPath()
    local file = io.open(userPath, "w")

    if not file then
        return false, "Could not open settings file for writing: " .. userPath
    end

    local success = file:write(jsonStr)
    file:close()

    if not success then
        return false, "Failed to write settings to file"
    end

    return true, nil
end

-- ============================================================================
-- RETURN MODULE
-- ============================================================================

return FileSystem