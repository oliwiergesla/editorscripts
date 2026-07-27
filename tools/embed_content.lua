local SCRIPT_INFO = {
    NAME = "Embed Content",
    VERSION = "0.1.0",
}
-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[
    embed_content.lua - Safely embed script content into installer template

    Called by build.sh to replace content placeholders (e.g. {{SCRIPT1_CONTENT}},
    {{TOOL1_CONTENT}}) in the installer template with the actual minified
    script content. Uses plain string find to avoid Lua pattern matching
    issues with special characters in the content.

    Pairs are processed in order against the accumulated output, so a pair may
    introduce placeholders that later pairs resolve (the SCRIPTS-table fragment
    contains {{SCRIPTn_CONTENT}} placeholders filled by subsequent pairs).

    A placeholder prefixed with "raw:" skips the long-string delimiter safety
    check for that pair only. This is for structural fragments that
    legitimately contain the ]=====] delimiter (e.g. {{SCRIPTS_TABLE}});
    script/tool payloads must keep the check.

    Usage:
        lua embed_content.lua <template_file> <output_file> <placeholder1> <content_file1> [<placeholder2> <content_file2> ...]
]]

-- ============================================================================
-- HELPERS
-- ============================================================================

local function readFile(path)
    local f = io.open(path, "r")
    if not f then
        io.stderr:write("ERROR: Could not open file: " .. path .. "\n")
        os.exit(1)
    end
    local content = f:read("*all")
    f:close()
    return content
end

local function writeFile(path, content)
    local f = io.open(path, "w")
    if not f then
        io.stderr:write("ERROR: Could not write to: " .. path .. "\n")
        os.exit(1)
    end
    f:write(content)
    f:close()
end

-- Plain string replacement (no pattern matching)
local function replaceExact(str, find, replace)
    local s, e = str:find(find, 1, true)
    if not s then
        io.stderr:write("ERROR: Placeholder '" .. find .. "' not found in template\n")
        os.exit(1)
    end
    return str:sub(1, s - 1) .. replace .. str:sub(e + 1)
end

-- ============================================================================
-- MAIN
-- ============================================================================

if #arg < 4 or #arg % 2 ~= 0 then
    io.stderr:write("Usage: lua embed_content.lua <template_file> <output_file> <placeholder1> <content_file1> [<placeholder2> <content_file2> ...]\n")
    os.exit(1)
end

local templatePath = arg[1]
local outputPath = arg[2]

local output = readFile(templatePath)
local delimiter = "]=====]"
local totalEmbedded = 0

for i = 3, #arg, 2 do
    local placeholder = arg[i]
    local content = readFile(arg[i + 1])

    -- "raw:" prefix marks a structural fragment that may contain the delimiter
    local isRaw = placeholder:sub(1, 4) == "raw:"
    if isRaw then
        placeholder = placeholder:sub(5)
    end

    -- Safety check: verify content doesn't contain the long string delimiter
    if not isRaw and content:find(delimiter, 1, true) then
        io.stderr:write("ERROR: Content for " .. placeholder .. " contains the long string delimiter " .. delimiter .. "\n")
        io.stderr:write("The content cannot be safely embedded in the installer template.\n")
        os.exit(1)
    end

    output = replaceExact(output, placeholder, content)
    totalEmbedded = totalEmbedded + #content
end

writeFile(outputPath, output)

local overhead = #output - totalEmbedded
io.write(string.format("  Embedded: %s (%d bytes, +%d bytes overhead)\n", outputPath, #output, overhead))
