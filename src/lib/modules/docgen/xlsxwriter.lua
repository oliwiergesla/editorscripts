-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[
    xlsxwriter.lua - Minimal OOXML (.xlsx) writer: marker-report table

    Part of ResolveKit - A comprehensive toolkit for DaVinci Resolve scripting

    Produces a single-sheet workbook that mirrors the PDF report: a Project /
    Sequence / Date header block, a bordered 7-column table (Still thumbnail,
    Start/End timecode, Duration, Name, Note, Color) with a shaded header row and
    alternating row tint. Thumbnails embed as xl/media JPEG parts anchored over
    column A. The OOXML package is assembled as XML strings and zipped (stored
    mode) via zipwriter.

    Usage:
        local w = XlsxWriter.new()
        w:setMeta{ project = "...", sequence = "...", date = "2024-07-26" }
        w:addRow{ jpegBytes = bytes, startTC = "...", endTC = "...",
                  duration = "...", name = "...", note = "...", color = "Red" }
        local bytes, err = w:build()

    Pass XlsxWriter.new{ includeImage = false } for a text-only report: the
    Still column is dropped, no drawings are anchored, and rows keep Excel's
    default height (wrapText auto-fit).
--]]

local ZipWriter = require("modules.docgen.zipwriter")
local JpegInfo = require("modules.docgen.jpeginfo")

local XlsxWriter = {}
XlsxWriter.__index = XlsxWriter

-- ============================================================================
-- LAYOUT CONSTANTS
-- ============================================================================

local EMU_PER_PX = 9525
local PT_PER_PX = 0.75
local THUMB_MAX_W = 240
local THUMB_MAX_H = 135
local CELL_PAD_PX = 2

local HEADER_ROWS = 5   -- rows 1-3 = meta, row 4 = blank, row 5 = column headers; data from row 6

-- Columns A..G. `image` is the thumbnail column; `wrap` flags wrapped text cells.
local COLUMNS = {
    { key = "image",    header = "Still",          width = 34 },
    { key = "startTC",  header = "Start Timecode", width = 15 },
    { key = "endTC",    header = "End Timecode",   width = 15 },
    { key = "duration", header = "Duration",       width = 12 },
    { key = "name",     header = "Name",           width = 22, wrap = true },
    { key = "note",     header = "Note",           width = 50, wrap = true },
    { key = "color",    header = "Color",          width = 12 },
}

-- Text-only layout (columns A..F): no Still column, wider wrapped columns.
local COLUMNS_TEXT = {
    { key = "startTC",  header = "Start Timecode", width = 15 },
    { key = "endTC",    header = "End Timecode",   width = 15 },
    { key = "duration", header = "Duration",       width = 12 },
    { key = "name",     header = "Name",           width = 30, wrap = true },
    { key = "note",     header = "Note",           width = 60, wrap = true },
    { key = "color",    header = "Color",          width = 12 },
}

-- cellXfs style indices (order must match the <cellXfs> block below)
local S_DEFAULT   = 0
local S_METALABEL = 1   -- bold (Project/Sequence/Date labels)
local S_COLHEADER = 2   -- bold + gray fill + border + centered
local S_DATA      = 3   -- border + vertical top
local S_DATA_WRAP = 4   -- border + vertical top + wrap
local S_DATA_ALT  = 5   -- + alternating fill
local S_DATA_ALTW = 6   -- + alternating fill + wrap

-- ============================================================================
-- XML HELPERS
-- ============================================================================

local function xmlEscape(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
    return s
end

local function colLetter(n)
    local s = ""
    while n > 0 do
        local r = (n - 1) % 26
        s = string.char(65 + r) .. s
        n = math.floor((n - 1) / 26)
    end
    return s
end

local function strCell(ref, style, text)
    return string.format('<c r="%s" s="%d" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>',
        ref, style, xmlEscape(text))
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

function XlsxWriter.new(opts)
    opts = opts or {}
    local self = setmetatable({ rows = {}, meta = {} }, XlsxWriter)
    self.includeImage = opts.includeImage ~= false
    self.columns = self.includeImage and COLUMNS or COLUMNS_TEXT
    return self
end

function XlsxWriter:setMeta(meta)
    self.meta = meta or {}
end

function XlsxWriter:addRow(row)
    self.rows[#self.rows + 1] = row or {}
end

-- ============================================================================
-- STATIC PACKAGE PARTS
-- ============================================================================

local CONTENT_TYPES = [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Default Extension="jpeg" ContentType="image/jpeg"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
<Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>
</Types>]]

local ROOT_RELS = [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>]]

local WORKBOOK = [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="Markers" sheetId="1" r:id="rId1"/></sheets>
</workbook>]]

local WORKBOOK_RELS = [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>]]

-- Fonts, fills, borders, and the cellXfs referenced by S_* constants above.
local STYLES = [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
<fills count="4">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFDDDDDD"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFF4F6F8"/></patternFill></fill>
</fills>
<borders count="2">
<border><left/><right/><top/><bottom/><diagonal/></border>
<border><left style="thin"><color rgb="FF999999"/></left><right style="thin"><color rgb="FF999999"/></right><top style="thin"><color rgb="FF999999"/></top><bottom style="thin"><color rgb="FF999999"/></bottom><diagonal/></border>
</borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="7">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="top"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top"/></xf>
<xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>]]

local SHEET_RELS = [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rIdDr1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/>
</Relationships>]]

-- ============================================================================
-- BUILD
-- ============================================================================

local function thumbSize(jpegBytes)
    local info = jpegBytes and JpegInfo.parse(jpegBytes) or nil
    local w = info and info.width or THUMB_MAX_W
    local h = info and info.height or THUMB_MAX_H
    local scale = math.min(THUMB_MAX_W / w, THUMB_MAX_H / h)
    if scale > 1 then scale = 1 end
    return math.floor(w * scale + 0.5), math.floor(h * scale + 0.5)
end

function XlsxWriter:build()
    local sheetRows = {}
    local anchors = {}
    local drawingRels = {}
    local zip = ZipWriter.new()

    -- ---- Metadata header rows (1-3), blank (4), column headers (5) ----
    local function metaRow(r, label, value)
        sheetRows[#sheetRows + 1] = string.format('<row r="%d">%s%s</row>', r,
            strCell("A" .. r, S_METALABEL, label),
            strCell("B" .. r, S_DEFAULT, value or ""))
    end
    metaRow(1, "Project:", self.meta.project)
    metaRow(2, "Sequence:", self.meta.sequence)
    metaRow(3, "Date:", self.meta.date)
    sheetRows[#sheetRows + 1] = '<row r="4"/>'

    do
        local cells = {}
        for c = 1, #self.columns do
            cells[#cells + 1] = strCell(colLetter(c) .. "5", S_COLHEADER, self.columns[c].header)
        end
        sheetRows[#sheetRows + 1] = '<row r="5">' .. table.concat(cells) .. '</row>'
    end

    -- ---- Data rows (sheet row = HEADER_ROWS + i; anchor row index = that - 1) ----
    for i, row in ipairs(self.rows) do
        local sheetRow = HEADER_ROWS + i
        local alt = (i % 2 == 0)
        local sNormal = alt and S_DATA_ALT or S_DATA
        local sWrap = alt and S_DATA_ALTW or S_DATA_WRAP

        local cells = {}
        for c, col in ipairs(self.columns) do
            local style = col.wrap and sWrap or sNormal
            -- image floats over its cell; keep an empty bordered cell under it
            local v = (col.key == "image") and "" or row[col.key]
            cells[#cells + 1] = strCell(colLetter(c) .. sheetRow, style, v)
        end

        local drawW, drawH = 0, 0
        if self.includeImage then
            drawW, drawH = thumbSize(row.jpegBytes)
            local rowHeightPt = drawH * PT_PER_PX + CELL_PAD_PX * 2
            sheetRows[#sheetRows + 1] = string.format(
                '<row r="%d" ht="%.2f" customHeight="1">%s</row>',
                sheetRow, rowHeightPt, table.concat(cells))
        else
            -- default row height; wrapText auto-fits
            sheetRows[#sheetRows + 1] = string.format(
                '<row r="%d">%s</row>', sheetRow, table.concat(cells))
        end

        if self.includeImage and row.jpegBytes and #row.jpegBytes > 0 then
            local imgN = #drawingRels + 1
            local rid = "rId" .. imgN
            zip:add("xl/media/image" .. imgN .. ".jpeg", row.jpegBytes)
            drawingRels[#drawingRels + 1] = string.format(
                '<Relationship Id="%s" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image%d.jpeg"/>',
                rid, imgN)

            local cx = drawW * EMU_PER_PX
            local cy = drawH * EMU_PER_PX
            local off = CELL_PAD_PX * EMU_PER_PX
            local anchorRow = sheetRow - 1  -- 0-based
            anchors[#anchors + 1] = string.format(
                '<xdr:oneCellAnchor>'
                .. '<xdr:from><xdr:col>0</xdr:col><xdr:colOff>%d</xdr:colOff><xdr:row>%d</xdr:row><xdr:rowOff>%d</xdr:rowOff></xdr:from>'
                .. '<xdr:ext cx="%d" cy="%d"/>'
                .. '<xdr:pic><xdr:nvPicPr><xdr:cNvPr id="%d" name="Still %d"/><xdr:cNvPicPr/></xdr:nvPicPr>'
                .. '<xdr:blipFill><a:blip xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:embed="%s"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>'
                .. '<xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="%d" cy="%d"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr>'
                .. '</xdr:pic><xdr:clientData/></xdr:oneCellAnchor>',
                off, anchorRow, off, cx, cy, imgN, imgN, rid, cx, cy)
        end
    end

    -- <cols>
    local cols = {}
    for c = 1, #self.columns do
        cols[#cols + 1] = string.format('<col min="%d" max="%d" width="%d" customWidth="1"/>',
            c, c, self.columns[c].width)
    end

    local sheetXml = table.concat({
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
        '<cols>', table.concat(cols), '</cols>',
        '<sheetData>', table.concat(sheetRows), '</sheetData>',
        '<drawing r:id="rIdDr1"/>',
        '</worksheet>',
    })

    local drawingXml = table.concat({
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">',
        table.concat(anchors),
        '</xdr:wsDr>',
    })

    local drawingRelsXml = table.concat({
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
        table.concat(drawingRels),
        '</Relationships>',
    })

    zip:add("[Content_Types].xml", CONTENT_TYPES)
    zip:add("_rels/.rels", ROOT_RELS)
    zip:add("xl/workbook.xml", WORKBOOK)
    zip:add("xl/_rels/workbook.xml.rels", WORKBOOK_RELS)
    zip:add("xl/styles.xml", STYLES)
    zip:add("xl/worksheets/sheet1.xml", sheetXml)
    zip:add("xl/worksheets/_rels/sheet1.xml.rels", SHEET_RELS)
    zip:add("xl/drawings/drawing1.xml", drawingXml)
    zip:add("xl/drawings/_rels/drawing1.xml.rels", drawingRelsXml)

    return zip:build()
end

return XlsxWriter
