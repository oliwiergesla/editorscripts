-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[
    binwriter.lua - Low-level binary byte assembly and CRC32

    Part of ResolveKit - A comprehensive toolkit for DaVinci Resolve scripting

    This module provides the byte-level primitives needed by the report writers
    (zipwriter/xlsxwriter/pdfwriter):
    - Little-endian integer packing (string.char based; string.pack is absent in
      Resolve's Lua 5.1 / LuaJIT 2.1 runtime)
    - Big-endian integer reading (for parsing JPEG markers)
    - CRC32 (table-driven, required by the ZIP container that .xlsx is built on)

    Runtime: DaVinci Resolve's Fusion Lua = Lua 5.1 / LuaJIT 2.1 with the `bit`
    library available (bit.band/bor/bxor/lshift/rshift). No string.pack.
--]]

local bit = bit  -- LuaJIT bit library (confirmed available in Resolve's runtime)

local BinWriter = {}

-- ============================================================================
-- LITTLE-ENDIAN PACKING (write)
-- ============================================================================

-- Pack a number as a 2-byte little-endian string.
-- bit.band normalizes floats / signed-32 bit results to unsigned bytes.
function BinWriter.u16le(n)
    return string.char(
        bit.band(n, 0xFF),
        bit.band(bit.rshift(n, 8), 0xFF)
    )
end

-- Pack a number as a 4-byte little-endian string.
function BinWriter.u32le(n)
    return string.char(
        bit.band(n, 0xFF),
        bit.band(bit.rshift(n, 8), 0xFF),
        bit.band(bit.rshift(n, 16), 0xFF),
        bit.band(bit.rshift(n, 24), 0xFF)
    )
end

-- ============================================================================
-- BIG-ENDIAN READING (read)
-- ============================================================================

-- Read a 2-byte big-endian unsigned integer from string `s` starting at `pos`
-- (1-based). Used to walk JPEG segment lengths and SOF fields.
function BinWriter.u16be(s, pos)
    local a, b = string.byte(s, pos, pos + 1)
    return a * 256 + b
end

-- ============================================================================
-- CRC32
-- ============================================================================

-- Polynomial table (reflected 0xEDB88320), built once on first use.
local crcTable

local function buildCrcTable()
    local t = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if bit.band(c, 1) == 1 then
                c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
            else
                c = bit.rshift(c, 1)
            end
        end
        t[i] = c
    end
    return t
end

-- Compute the CRC32 of a (binary) string. Returns a 32-bit value; consumers
-- should serialize it with BinWriter.u32le (which masks each byte, so the
-- signedness of the LuaJIT bit result does not matter).
function BinWriter.crc32(s)
    if not crcTable then
        crcTable = buildCrcTable()
    end

    local crc = 0xFFFFFFFF
    for i = 1, #s do
        local byte = string.byte(s, i)
        crc = bit.bxor(bit.rshift(crc, 8), crcTable[bit.band(bit.bxor(crc, byte), 0xFF)])
    end
    return bit.bxor(crc, 0xFFFFFFFF)
end

return BinWriter
