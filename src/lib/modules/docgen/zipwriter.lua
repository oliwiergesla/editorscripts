-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[
    zipwriter.lua - Minimal stored-mode (uncompressed) ZIP writer

    Part of ResolveKit - A comprehensive toolkit for DaVinci Resolve scripting

    An .xlsx file is a ZIP archive of XML parts. This writer emits ZIP archives
    using storage method 0 (no compression) so we avoid implementing DEFLATE in
    pure Lua. Stored entries are accepted by Excel, Numbers, LibreOffice and all
    OS unzip tools.

    Usage:
        local zip = ZipWriter.new()
        zip:add("path/in/zip.xml", dataString)
        local bytes, err = zip:build()
--]]

local BinWriter = require("modules.docgen.binwriter")

local ZipWriter = {}
ZipWriter.__index = ZipWriter

-- Fixed DOS timestamp (1980-01-01 00:00:00) for deterministic, reproducible
-- archives. DOS date = year-1980 (0) << 9 | month(1) << 5 | day(1) = 0x0021.
local DOS_TIME = 0x0000
local DOS_DATE = 0x0021

local SIG_LOCAL = 0x04034b50
local SIG_CENTRAL = 0x02014b50
local SIG_EOCD = 0x06054b50

function ZipWriter.new()
    return setmetatable({ entries = {} }, ZipWriter)
end

-- Add a file entry. `name` uses forward slashes; `data` is a binary string.
function ZipWriter:add(name, data)
    self.entries[#self.entries + 1] = {
        name = name,
        data = data or "",
        crc = BinWriter.crc32(data or ""),
        size = #(data or ""),
    }
end

-- Serialize the archive. Returns the full .zip byte string, nil.
function ZipWriter:build()
    local u16, u32 = BinWriter.u16le, BinWriter.u32le
    local out = {}            -- local headers + data, accumulated in order
    local central = {}        -- central directory records
    local offset = 0          -- running byte offset of the next local header

    for _, e in ipairs(self.entries) do
        local nameLen = #e.name

        -- Local file header
        local localHeader = table.concat({
            u32(SIG_LOCAL),
            u16(20),          -- version needed to extract
            u16(0),           -- general purpose bit flag
            u16(0),           -- compression method: 0 = stored
            u16(DOS_TIME),
            u16(DOS_DATE),
            u32(e.crc),
            u32(e.size),      -- compressed size (== uncompressed for stored)
            u32(e.size),      -- uncompressed size
            u16(nameLen),
            u16(0),           -- extra field length
            e.name,
        })

        out[#out + 1] = localHeader
        out[#out + 1] = e.data

        -- Central directory record (mirrors local header + offset/attrs)
        central[#central + 1] = table.concat({
            u32(SIG_CENTRAL),
            u16(20),          -- version made by
            u16(20),          -- version needed to extract
            u16(0),           -- flags
            u16(0),           -- method: stored
            u16(DOS_TIME),
            u16(DOS_DATE),
            u32(e.crc),
            u32(e.size),
            u32(e.size),
            u16(nameLen),
            u16(0),           -- extra field length
            u16(0),           -- file comment length
            u16(0),           -- disk number start
            u16(0),           -- internal file attributes
            u32(0),           -- external file attributes
            u32(offset),      -- relative offset of local header
            e.name,
        })

        offset = offset + #localHeader + e.size
    end

    local centralStr = table.concat(central)
    local count = #self.entries

    -- End of central directory record
    local eocd = table.concat({
        u32(SIG_EOCD),
        u16(0),               -- number of this disk
        u16(0),               -- disk with start of central directory
        u16(count),           -- entries on this disk
        u16(count),           -- total entries
        u32(#centralStr),     -- central directory size
        u32(offset),          -- central directory offset (== size of local section)
        u16(0),               -- comment length
    })

    return table.concat(out) .. centralStr .. eocd, nil
end

return ZipWriter
