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

-- Size of a file in bytes, or nil when it cannot be opened
local function getFileSize(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local size = file:seek("end")
    file:close()
    return size
end

-- Copy file from source to destination (for cross-device moves)
-- Chunked so multi-GB media files never get loaded into memory whole.
-- Succeeds only when the destination holds every byte of the source. A read
-- error, a failed final flush or a size mismatch fails the copy and removes
-- the partial destination: moveFile deletes the source on the strength of
-- this result, and a truncated file must never be left under the final name.
function FileSystem.copyFile(source, dest)
    -- Opening the destination truncates it, which would empty the source
    if source == dest then
        return false, "Source and destination are the same file"
    end

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
    local bytesCopied = 0
    local failure = nil

    while true do
        -- read() returns nil at end of file AND on a read error; only the
        -- error comes with a message
        local chunk, readErr = sourceFile:read(chunkSize)
        if not chunk then
            if readErr then
                failure = "Could not read source file: " .. tostring(readErr)
            end
            break
        end

        local writeSuccess, writeErr = destFile:write(chunk)
        if not writeSuccess then
            failure = "Could not write to destination file: " .. tostring(writeErr)
            break
        end
        bytesCopied = bytesCopied + #chunk

        if #chunk < chunkSize then
            break  -- Last (short) chunk
        end
    end

    local sourceSize = sourceFile:seek("end")
    sourceFile:close()

    -- close() flushes the last buffered bytes, so it can fail where write()
    -- reported success (full or disconnected volume)
    local closeSuccess, closeErr = destFile:close()
    if not failure and not closeSuccess then
        failure = "Could not finish writing destination file: " .. tostring(closeErr)
    end

    if not failure and sourceSize ~= bytesCopied then
        failure = "Copy is incomplete: read " .. bytesCopied .. " of "
            .. tostring(sourceSize) .. " bytes"
    end
    if not failure then
        local destSize = getFileSize(dest)
        if destSize ~= bytesCopied then
            failure = "Copy is incomplete: destination holds " .. tostring(destSize)
                .. " of " .. bytesCopied .. " bytes"
        end
    end

    if failure then
        os.remove(dest)
        return false, failure
    end

    return true
end

-- errno EXDEV: rename() cannot cross volumes (18 on macOS and Linux)
local ERRNO_CROSS_DEVICE = 18

-- Move file (handles cross-device moves)
function FileSystem.moveFile(source, dest)
    -- Try simple rename first (works for same device)
    local success, err, code = os.rename(source, dest)

    if success then
        return true, nil
    end

    -- A rename across volumes needs copy + delete. Detected by error code;
    -- the message match stays for runtimes that do not return one.
    local crossDevice = code == ERRNO_CROSS_DEVICE
        or (err and (err:match("Cross%-device link") or err:match("Invalid cross%-device link")))
    if not crossDevice then
        return false, err
    end

    -- copyFile succeeds only once the destination holds every byte, so the
    -- original is safe to delete after it
    local copySuccess, copyErr = FileSystem.copyFile(source, dest)
    if not copySuccess then
        return false, "Copy failed: " .. (copyErr or "unknown error")
    end

    local deleteSuccess = os.remove(source)
    if not deleteSuccess then
        return false, "File copied but original could not be deleted"
    end

    return true, nil
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

-- Tables nested deeper than this are not followed (the encoder writes null,
-- the decoder returns an error), so neither can overflow the Lua stack
local JSON_MAX_DEPTH = 200

-- Lookup table for JSON string escaping (single-pass optimization): the short
-- forms JSON defines, \u00XX for every other control character and for DEL
local jsonEscapeChars = {
    ['\\'] = '\\\\',
    ['"'] = '\\"',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t'
}
for byte = 0, 31 do
    local char = string.char(byte)
    if not jsonEscapeChars[char] then
        jsonEscapeChars[char] = string.format("\\u%04x", byte)
    end
end
jsonEscapeChars[string.char(127)] = "\\u007f"

-- %c covers 0x00-0x1F and 0x7F. A literal "\0" inside a pattern is rejected
-- by Resolve's LuaJIT ("malformed pattern"), so the class is spelled this way.
local function encodeJSONString(text)
    return '"' .. text:gsub('[%c"\\]', jsonEscapeChars) .. '"'
end

-- JSON has no nan or infinity: both are written as null. 14 significant
-- digits keep the output short; 17 are used only when 14 would not read back
-- to the same number.
local function encodeJSONNumber(number)
    if number ~= number or number == math.huge or number == -math.huge then
        return "null"
    end
    local text = string.format("%.14g", number)
    if tonumber(text) ~= number then
        text = string.format("%.17g", number)
    end
    return text
end

-- JSON encoder for Lua values. Never raises.
-- Supports: strings, numbers, booleans, nil, tables (as objects or arrays)
--   - A table is an array only when its keys are exactly 1..n. An empty table
--     is written as [].
--   - Any other table is an object. Number keys are written as string keys
--     ({[10] = "a"} becomes {"10": "a"}); keys of other types are skipped.
--     Keys are sorted, so the same data always produces the same text.
--   - nan, infinity, functions, userdata and a table that contains itself are
--     written as null.
-- Callers pass the value only; indent and path are for the recursion.
local function encodeJSON(value, indent, path)
    indent = indent or 0
    local valueType = type(value)

    if valueType == "nil" then
        return "null"
    elseif valueType == "boolean" then
        return value and "true" or "false"
    elseif valueType == "number" then
        return encodeJSONNumber(value)
    elseif valueType == "string" then
        return encodeJSONString(value)
    elseif valueType ~= "table" then
        return "null"
    end

    path = path or {}
    if path[value] or indent >= JSON_MAX_DEPTH then
        return "null"
    end

    -- Positive integer keys only, and the largest equals the key count: the
    -- keys are then exactly 1..count, in whatever order pairs() visits them
    local count, maxKey, isArray = 0, 0, true
    for k in pairs(value) do
        count = count + 1
        if type(k) == "number" and k >= 1 and k % 1 == 0 then
            if k > maxKey then
                maxKey = k
            end
        else
            isArray = false
        end
    end
    isArray = isArray and maxKey == count

    if count == 0 then
        return "[]"
    end

    local indentStr = string.rep("  ", indent)
    local childIndent = indentStr .. "  "
    local parts = {}
    path[value] = true

    if isArray then
        for i = 1, count do
            parts[i] = childIndent .. encodeJSON(value[i], indent + 1, path)
        end
        path[value] = nil
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indentStr .. "]"
    end

    -- Object: map each key's JSON text back to the key. If a number key and a
    -- string key collide ({[1] = ..., ["1"] = ...}), the string key wins.
    local keyByText, texts = {}, {}
    for k in pairs(value) do
        local keyType = type(k)
        local text = nil
        if keyType == "string" then
            text = k
        elseif keyType == "number" and k == k and k ~= math.huge and k ~= -math.huge then
            text = encodeJSONNumber(k)
        end
        if text then
            if keyByText[text] == nil then
                texts[#texts + 1] = text
                keyByText[text] = k
            elseif keyType == "string" then
                keyByText[text] = k
            end
        end
    end

    -- Number keys first, in numeric order, then string keys in byte order
    table.sort(texts, function(a, b)
        local keyA, keyB = keyByText[a], keyByText[b]
        local numA, numB = type(keyA) == "number", type(keyB) == "number"
        if numA and numB then
            return keyA < keyB
        elseif numA ~= numB then
            return numA
        end
        return a < b
    end)

    for i, text in ipairs(texts) do
        parts[i] = childIndent .. encodeJSONString(text) .. ": "
            .. encodeJSON(value[keyByText[text]], indent + 1, path)
    end
    path[value] = nil

    if #parts == 0 then
        return "{}"
    end

    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indentStr .. "}"
end

-- Escapes with a meaning of their own. Every other escaped character stands
-- for itself, which covers \" \\ \/ and tolerates unknown escapes.
local jsonUnescapeChars = {
    b = '\b',
    f = '\f',
    n = '\n',
    r = '\r',
    t = '\t'
}

-- Bare words the decoder accepts. Non-finite numbers have no JSON form, but
-- Python writes NaN / Infinity and this encoder used to write nan / inf: all
-- of them read as null so one such value does not fail the whole text.
local jsonBooleanWords = { ["true"] = true, ["false"] = false }
local jsonNullWords = {
    ["null"] = true,
    ["NaN"] = true, ["Infinity"] = true, ["-Infinity"] = true,
    ["nan"] = true, ["-nan"] = true, ["inf"] = true, ["-inf"] = true
}

-- Encode one Unicode code point (0 to 0x10FFFF) as UTF-8
local function utf8FromCodepoint(codepoint)
    local floor = math.floor
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(0xC0 + floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
    elseif codepoint < 0x10000 then
        return string.char(0xE0 + floor(codepoint / 0x1000),
            0x80 + floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
    end
    return string.char(0xF0 + floor(codepoint / 0x40000),
        0x80 + floor(codepoint / 0x1000) % 0x40,
        0x80 + floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
end

-- JSON decoder for Lua
-- Supports: strings, numbers, booleans, null, objects, arrays
-- Returns: value, or nil, error (the error names the byte position)
--   - null becomes nil: an object key with a null value is absent, and a null
--     inside an array is dropped, so the items after it move down one place.
--   - \uXXXX escapes become UTF-8 (surrogate pairs are combined, a surrogate
--     on its own becomes U+FFFD). A leading UTF-8 byte order mark is skipped.
--   - Lenient where older files need it: raw control characters inside
--     strings and unknown escapes are accepted.
--   - Strict otherwise: malformed numbers, unknown words, nesting deeper than
--     JSON_MAX_DEPTH and anything but whitespace after the value are errors.
local function decodeJSON(jsonStr)
    if jsonStr == nil or jsonStr == "" then
        return nil, "Empty JSON string"
    end
    if type(jsonStr) ~= "string" then
        return nil, "Expected a JSON string, got " .. type(jsonStr)
    end

    local len = #jsonStr
    local pos = 1
    local depth = 0

    local b1, b2, b3 = jsonStr:byte(1, 3)
    if b1 == 0xEF and b2 == 0xBB and b3 == 0xBF then
        pos = 4
    elseif (b1 == 0xFF and b2 == 0xFE) or (b1 == 0xFE and b2 == 0xFF) then
        return nil, "JSON text is UTF-16 encoded, expected UTF-8"
    end

    local function fail(message, at)
        return nil, message .. " at byte " .. (at or pos)
    end

    local function skipWhitespace()
        pos = jsonStr:find("[^ \t\r\n]", pos) or len + 1
    end

    -- Parse the string whose opening quote is at pos. Jumps from one quote or
    -- backslash to the next and joins the runs in between once at the end.
    local function parseString()
        local openPos = pos
        local start = pos + 1
        local parts, count = nil, 0

        while true do
            local stop = jsonStr:find('["\\]', start)
            if not stop then
                return fail("Unterminated string", openPos)
            end

            if jsonStr:sub(stop, stop) == '"' then
                local run = jsonStr:sub(start, stop - 1)
                pos = stop + 1
                if not parts then
                    return run
                end
                parts[count + 1] = run
                return table.concat(parts)
            end

            -- Backslash: keep the run before it, then decode the escape
            parts = parts or {}
            count = count + 1
            parts[count] = jsonStr:sub(start, stop - 1)

            local escapeChar = jsonStr:sub(stop + 1, stop + 1)
            if escapeChar == "" then
                return fail("Unterminated string", openPos)
            end

            count = count + 1
            if escapeChar == "u" then
                local hex = jsonStr:match("^%x%x%x%x", stop + 2)
                if not hex then
                    return fail("Invalid \\u escape", stop)
                end
                local codepoint = tonumber(hex, 16)
                start = stop + 6

                if codepoint >= 0xD800 and codepoint <= 0xDBFF then
                    -- High surrogate: only valid with a low surrogate after it
                    local lowHex = jsonStr:match("^\\u(%x%x%x%x)", start)
                    local low = lowHex and tonumber(lowHex, 16)
                    if low and low >= 0xDC00 and low <= 0xDFFF then
                        codepoint = 0x10000 + (codepoint - 0xD800) * 0x400 + (low - 0xDC00)
                        start = start + 6
                    else
                        codepoint = 0xFFFD
                    end
                elseif codepoint >= 0xDC00 and codepoint <= 0xDFFF then
                    codepoint = 0xFFFD
                end

                parts[count] = utf8FromCodepoint(codepoint)
            else
                parts[count] = jsonUnescapeChars[escapeChar] or escapeChar
                start = stop + 2
            end
        end
    end

    local function parseValue()
        skipWhitespace()

        if pos > len then
            return fail("Unexpected end of JSON")
        end

        local char = jsonStr:sub(pos, pos)

        -- string
        if char == '"' then
            return parseString()
        end

        -- true, false, null and the non-finite number words
        local word = jsonStr:match("^-?%a+", pos)
        if word then
            local booleanValue = jsonBooleanWords[word]
            if booleanValue ~= nil then
                pos = pos + #word
                return booleanValue
            end
            if jsonNullWords[word] then
                pos = pos + #word
                return nil
            end
            return fail("Unexpected word '" .. word:sub(1, 20) .. "'")
        end

        -- number
        if char == '-' or (char >= '0' and char <= '9') then
            local numStr = jsonStr:match("^-?%d[%d%.eE+-]*", pos)
            local number = numStr and tonumber(numStr)
            if not number then
                return fail("Invalid number")
            end
            pos = pos + #numStr
            return number
        end

        -- object
        if char == '{' then
            if depth >= JSON_MAX_DEPTH then
                return fail("Nesting too deep")
            end
            depth = depth + 1
            pos = pos + 1
            local obj = {}

            skipWhitespace()
            if jsonStr:sub(pos, pos) == '}' then
                pos = pos + 1
                depth = depth - 1
                return obj
            end

            while true do
                skipWhitespace()

                -- Parse key (must be string)
                if jsonStr:sub(pos, pos) ~= '"' then
                    return fail("Expected string key in object")
                end

                local key, keyErr = parseString()
                if keyErr then
                    return nil, keyErr
                end

                skipWhitespace()

                -- Expect colon
                if jsonStr:sub(pos, pos) ~= ':' then
                    return fail("Expected ':' after object key")
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
                    depth = depth - 1
                    return obj
                elseif char == ',' then
                    pos = pos + 1
                else
                    return fail("Expected ',' or '}' in object")
                end
            end
        end

        -- array
        if char == '[' then
            if depth >= JSON_MAX_DEPTH then
                return fail("Nesting too deep")
            end
            depth = depth + 1
            pos = pos + 1
            local arr = {}
            local count = 0

            skipWhitespace()
            if jsonStr:sub(pos, pos) == ']' then
                pos = pos + 1
                depth = depth - 1
                return arr
            end

            while true do
                local value, err = parseValue()
                if err then
                    return nil, err
                end

                -- A null item is dropped (see the function comment)
                if value ~= nil then
                    count = count + 1
                    arr[count] = value
                end

                skipWhitespace()

                char = jsonStr:sub(pos, pos)
                if char == ']' then
                    pos = pos + 1
                    depth = depth - 1
                    return arr
                elseif char == ',' then
                    pos = pos + 1
                else
                    return fail("Expected ',' or ']' in array")
                end
            end
        end

        return fail("Unexpected character")
    end

    local value, err = parseValue()
    if err then
        return nil, err
    end

    skipWhitespace()
    if pos <= len then
        return fail("Unexpected trailing characters")
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

-- Standard base64 alphabet: byte -> 6-bit value ("=" padding has no entry)
local BASE64_VALUES = {}
do
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, #alphabet do
        BASE64_VALUES[alphabet:byte(i)] = i - 1
    end
end

-- Decode a base64 string to raw bytes (plain arithmetic, no bit library).
-- Returns: bytes, nil on success or nil, error on failure
local function decodeBase64(text)
    local out = {}
    for i = 1, #text, 4 do
        local a, b, c, d = text:byte(i, i + 3)
        local va, vb = BASE64_VALUES[a], BASE64_VALUES[b]
        local vc, vd = BASE64_VALUES[c], BASE64_VALUES[d]
        if not va or not vb then
            return nil, "Invalid base64 data"
        end
        local n = va * 262144 + vb * 4096 + (vc or 0) * 64 + (vd or 0)
        local bytes = string.char(math.floor(n / 65536), math.floor(n / 256) % 256, n % 256)
        out[#out + 1] = bytes:sub(1, vd and 3 or (vc and 2 or 1))
    end
    return table.concat(out), nil
end

-- Write a file embedded in the code as base64 (e.g. an image a stylesheet has
-- to load from disk) into the script's data directory. The file is left alone
-- when it already holds the same bytes.
-- Returns: path, nil on success or nil, error on failure
function FileSystem.writeEmbeddedFile(filename, base64)
    local dataDir, dirErr = FileSystem.getDataDir()
    if not dataDir then
        return nil, dirErr
    end
    local bytes, decodeErr = decodeBase64(base64)
    if not bytes then
        return nil, decodeErr
    end
    local path = FileSystem.joinPath(dataDir, filename)

    local existing = io.open(path, "rb")
    if existing then
        local current = existing:read("*a")
        existing:close()
        if current == bytes then
            return path, nil
        end
    end

    if not FileSystem.createDirectory(dataDir) then
        return nil, "Could not create data directory: " .. dataDir
    end
    local file, openErr = io.open(path, "wb")
    if not file then
        return nil, "Could not write " .. path .. ": " .. tostring(openErr)
    end
    file:write(bytes)
    file:close()
    return path, nil
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