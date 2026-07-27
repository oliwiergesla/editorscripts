-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[
    jpeginfo.lua - Parse dimensions / color info from JPEG bytes

    Part of ResolveKit - A comprehensive toolkit for DaVinci Resolve scripting

    Both report writers embed raw JPEG bytes (PDF /DCTDecode XObjects,
    xlsx xl/media). They must declare the image's true width/height/components,
    which live in the JPEG's Start-Of-Frame (SOF) marker. This module walks the
    JPEG marker structure to extract them without decoding pixel data.
--]]

local BinWriter = require("modules.docgen.binwriter")

local JpegInfo = {}

-- SOF markers carry frame geometry. The range 0xC0..0xCF is "SOFn" EXCEPT:
--   0xC4 = DHT (Huffman tables), 0xC8 = JPG extension, 0xCC = DAC (arithmetic)
-- which are not frame headers and must be skipped like any other segment.
local NON_SOF = {
    [0xC4] = true,
    [0xC8] = true,
    [0xCC] = true,
}

-- Map JPEG component count to a PDF/OOXML color space name.
local function colorSpaceFor(components)
    if components == 1 then
        return "/DeviceGray"
    elseif components == 3 then
        return "/DeviceRGB"
    elseif components == 4 then
        return "/DeviceCMYK"
    end
    return nil
end

-- Parse a JPEG (binary string) and return geometry.
-- Returns: { width, height, bits, components, colorSpace }, nil
--      or: nil, "error message"
function JpegInfo.parse(bytes)
    if not bytes or #bytes < 4 then
        return nil, "JPEG data too short"
    end

    -- SOI marker
    if string.byte(bytes, 1) ~= 0xFF or string.byte(bytes, 2) ~= 0xD8 then
        return nil, "not a JPEG (missing SOI marker)"
    end

    local pos = 3
    local len = #bytes

    while pos < len do
        -- Each marker starts with 0xFF; fill bytes (0xFF padding) are skipped.
        if string.byte(bytes, pos) ~= 0xFF then
            return nil, "invalid JPEG marker structure"
        end

        local marker = string.byte(bytes, pos + 1)
        pos = pos + 2

        -- Standalone markers without a length payload (RSTn, SOI, EOI, TEM).
        if marker == 0xD8 or marker == 0xD9 or marker == 0x01
            or (marker >= 0xD0 and marker <= 0xD7) then
            -- no segment length; continue scanning
        else
            if pos + 1 > len then
                return nil, "truncated JPEG segment"
            end
            local segLen = BinWriter.u16be(bytes, pos)

            -- Is this an SOF (frame header) marker?
            if marker >= 0xC0 and marker <= 0xCF and not NON_SOF[marker] then
                -- Segment payload: precision(1) height(2 BE) width(2 BE) components(1)
                local bits = string.byte(bytes, pos + 2)
                local height = BinWriter.u16be(bytes, pos + 3)
                local width = BinWriter.u16be(bytes, pos + 5)
                local components = string.byte(bytes, pos + 7)
                local colorSpace = colorSpaceFor(components)
                if not colorSpace then
                    return nil, string.format("unsupported JPEG component count: %d",
                        components or -1)
                end
                return {
                    width = width,
                    height = height,
                    bits = bits,
                    components = components,
                    colorSpace = colorSpace,
                }, nil
            end

            -- Not an SOF: skip the whole segment (length includes the 2 length bytes).
            pos = pos + segLen
        end
    end

    return nil, "no SOF marker found in JPEG"
end

return JpegInfo
