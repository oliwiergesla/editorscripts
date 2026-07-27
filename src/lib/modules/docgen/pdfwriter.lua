-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Oliwier Gesla / EditorScripts

--[[
    pdfwriter.lua - Minimal PDF 1.4 writer: polished marker-report table

    Part of ResolveKit - A comprehensive toolkit for DaVinci Resolve scripting

    Renders a professional QC-style report: a document header (Project / Sequence /
    Date), a bordered table with one row per marker (Frame thumbnail, Start/End
    timecode, Duration, Name, Note, Color), alternating row shading, and a
    "Page N of M" footer. JPEG thumbnails embed directly as /DCTDecode image
    XObjects (no decode/re-encode); text uses the built-in Helvetica fonts. Output
    is paginated with an exact byte-offset cross-reference table.

    Usage:
        local p = PdfWriter.new()
        p:setMeta{ project = "...", sequence = "...", date = "2024-07-26" }
        p:addRow{ jpegBytes = bytes, startTC = "...", endTC = "...",
                  duration = "...", name = "...", note = "...", color = "Red" }
        local bytes, err = p:build()

    Pass PdfWriter.new{ includeImage = false } for a text-only report: the Frame
    thumbnail column is dropped and its width redistributed across the text
    columns (rows stay compact at text height).
--]]

local JpegInfo = require("modules.docgen.jpeginfo")

local PdfWriter = {}
PdfWriter.__index = PdfWriter

-- ============================================================================
-- HELVETICA AFM WIDTHS (units / 1000 em) for ASCII 32..126
-- Used for word-wrap and centering so text never overflows cell borders.
-- ============================================================================

local HELV_W = {
    [32]=278,[33]=278,[34]=355,[35]=556,[36]=556,[37]=889,[38]=667,[39]=191,
    [40]=333,[41]=333,[42]=389,[43]=584,[44]=278,[45]=333,[46]=278,[47]=278,
    [48]=556,[49]=556,[50]=556,[51]=556,[52]=556,[53]=556,[54]=556,[55]=556,
    [56]=556,[57]=556,[58]=278,[59]=278,[60]=584,[61]=584,[62]=584,[63]=556,
    [64]=1015,[65]=667,[66]=667,[67]=722,[68]=722,[69]=667,[70]=611,[71]=778,
    [72]=722,[73]=278,[74]=500,[75]=667,[76]=556,[77]=833,[78]=722,[79]=778,
    [80]=667,[81]=778,[82]=722,[83]=667,[84]=611,[85]=722,[86]=667,[87]=944,
    [88]=667,[89]=667,[90]=611,[91]=278,[92]=278,[93]=278,[94]=469,[95]=556,
    [96]=333,[97]=556,[98]=556,[99]=500,[100]=556,[101]=556,[102]=278,[103]=556,
    [104]=556,[105]=222,[106]=222,[107]=500,[108]=222,[109]=833,[110]=556,[111]=556,
    [112]=556,[113]=556,[114]=333,[115]=500,[116]=278,[117]=556,[118]=500,[119]=722,
    [120]=500,[121]=500,[122]=500,[123]=334,[124]=260,[125]=334,[126]=584,
}

local function stringWidth(s, size)
    local w = 0
    for i = 1, #s do
        w = w + (HELV_W[string.byte(s, i)] or 556)
    end
    return w * size / 1000
end

-- ============================================================================
-- LAYOUT DEFAULTS (landscape US Letter, points)
-- ============================================================================

local DEFAULTS = {
    pageW = 792,
    pageH = 612,
    margin = 36,
    fontSize = 9,
    leading = 11,
    labelSize = 11,        -- Project/Sequence/Date header
    colHeaderH = 24,
    cellPadX = 4,
    cellPadV = 5,
    thumbMaxH = 88,        -- cap thumbnail height so rows stay compact
    footerSize = 8,
}

-- Column model: image column first, then text columns.
-- Both sets sum to the usable table width (pageW - 2*margin = 720pt).
local COLUMNS = {
    { key = "image",    header = "Frame",          width = 150 },
    { key = "startTC",  header = "Start Timecode", width = 80 },
    { key = "endTC",    header = "End Timecode",   width = 80 },
    { key = "duration", header = "Duration",       width = 75 },
    { key = "name",     header = "Name",           width = 95,  wrap = true },
    { key = "note",     header = "Note",           width = 175, wrap = true },
    { key = "color",    header = "Color",          width = 65 },
}

-- Text-only layout: image column removed, its 150pt redistributed.
local COLUMNS_TEXT = {
    { key = "startTC",  header = "Start Timecode", width = 95 },
    { key = "endTC",    header = "End Timecode",   width = 95 },
    { key = "duration", header = "Duration",       width = 85 },
    { key = "name",     header = "Name",           width = 150, wrap = true },
    { key = "note",     header = "Note",           width = 220, wrap = true },
    { key = "color",    header = "Color",          width = 75 },
}

function PdfWriter.new(opts)
    opts = opts or {}
    local self = setmetatable({ rows = {}, meta = {} }, PdfWriter)
    for k, v in pairs(DEFAULTS) do
        self[k] = opts[k] or v
    end
    self.columns = (opts.includeImage == false) and COLUMNS_TEXT or COLUMNS
    return self
end

function PdfWriter:setMeta(meta)
    self.meta = meta or {}
end

function PdfWriter:addRow(row)
    self.rows[#self.rows + 1] = row or {}
end

-- ============================================================================
-- TEXT HELPERS
-- ============================================================================

local function pdfEscape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub("%(", "\\(")
    s = s:gsub("%)", "\\)")
    s = s:gsub("[%z\1-\31\128-\255]", function(c)
        return c == "\n" and "\n" or " "  -- newlines are handled by the wrapper; strip others
    end)
    return s
end

-- Greedy word-wrap to a pixel width, honoring explicit newlines. Long single
-- words are hard-broken so nothing overflows the column.
local function wrapText(s, maxW, size)
    local lines = {}
    s = tostring(s or "")
    for para in (s .. "\n"):gmatch("(.-)\n") do
        if para == "" then
            lines[#lines + 1] = ""
        else
            local cur = ""
            for word in para:gmatch("%S+") do
                local trial = (cur == "") and word or (cur .. " " .. word)
                if stringWidth(trial, size) <= maxW then
                    cur = trial
                elseif cur == "" then
                    -- single word longer than the column: hard-break it
                    local part = ""
                    for i = 1, #word do
                        local c = word:sub(i, i)
                        if part ~= "" and stringWidth(part .. c, size) > maxW then
                            lines[#lines + 1] = part
                            part = c
                        else
                            part = part .. c
                        end
                    end
                    cur = part
                else
                    lines[#lines + 1] = cur
                    cur = word
                end
            end
            lines[#lines + 1] = cur
        end
    end
    -- drop a single trailing empty produced by a trailing newline
    if #lines > 1 and lines[#lines] == "" then lines[#lines] = nil end
    if #lines == 0 then lines[1] = "" end
    return lines
end

-- ============================================================================
-- BUILD
-- ============================================================================

function PdfWriter:build()
    local objects = {}
    local nextNum = 5   -- 1=catalog, 2=pages, 3=Helvetica, 4=Helvetica-Bold
    local function alloc()
        local n = nextNum
        nextNum = nextNum + 1
        return n
    end

    -- Column x-boundaries (left edge of each column + final right edge)
    local columns = self.columns
    local bounds = { self.margin }
    for i = 1, #columns do
        bounds[i + 1] = bounds[i] + columns[i].width
    end
    local tableRight = bounds[#bounds]
    local colByKey = {}
    for i, c in ipairs(columns) do colByKey[c.key] = { x = bounds[i], w = c.width, def = c } end

    local fs, lead, padX, padV = self.fontSize, self.leading, self.cellPadX, self.cellPadV
    local imgCol = colByKey.image   -- nil in the text-only layout
    local thumbBoxW = imgCol and (imgCol.w - 2 * padX) or 0
    local thumbBoxH = self.thumbMaxH

    -- ---- Pre-compute every row's wrapped text + thumbnail size + height ----
    local rowInfos = {}
    for _, row in ipairs(self.rows) do
        local info = { row = row }
        info.nameLines = wrapText(row.name, colByKey.name.w - 2 * padX, fs)
        info.noteLines = wrapText(row.note, colByKey.note.w - 2 * padX, fs)

        local drawW, drawH = 0, 0
        if imgCol and row.jpegBytes and #row.jpegBytes > 0 then
            local j = JpegInfo.parse(row.jpegBytes)
            local w = j and j.width or thumbBoxW
            local h = j and j.height or thumbBoxH
            local scale = math.min(thumbBoxW / w, thumbBoxH / h)
            if scale > 1 then scale = 1 end
            drawW = w * scale
            drawH = h * scale
        end
        info.drawW, info.drawH = drawW, drawH

        local textLines = math.max(#info.nameLines, #info.noteLines, 1)
        info.rowH = math.max(drawH, textLines * lead, lead) + 2 * padV
        rowInfos[#rowInfos + 1] = info
    end

    -- ---- Paginate ----
    local headerBlockH = 3 * (self.labelSize + 5) + 14   -- Project/Sequence/Date block (page 1)
    local bottomLimit = self.margin + 18                 -- leave room for footer
    local pages = {}
    do
        local i = 1
        while i <= #rowInfos or #pages == 0 do
            local isFirst = (#pages == 0)
            local top = self.pageH - self.margin - (isFirst and headerBlockH or 0)
            top = top - self.colHeaderH
            local page = { isFirst = isFirst, top = top, rows = {} }
            local y = top
            while i <= #rowInfos do
                local rh = rowInfos[i].rowH
                if (y - rh) < bottomLimit and #page.rows > 0 then break end
                page.rows[#page.rows + 1] = rowInfos[i]
                y = y - rh
                i = i + 1
            end
            page.bottom = y
            pages[#pages + 1] = page
            if i > #rowInfos then break end
        end
    end
    local totalPages = #pages

    -- ---- Render each page ----
    local kids = {}
    for pageIdx, page in ipairs(pages) do
        local content = {}
        local xobjRefs = {}
        local function emit(s) content[#content + 1] = s end

        -- text(x, baseline, size, font("F1"/"F2"), str)
        local function text(x, y, size, font, str)
            emit(string.format("BT /%s %d Tf %.2f %.2f Td (%s) Tj ET",
                font, size, x, y, pdfEscape(str)))
        end
        local function fillRect(x, y, w, h, gray)
            emit(string.format("q %.3f g %.2f %.2f %.2f %.2f re f Q", gray, x, y, w, h))
        end
        local function line(x1, y1, x2, y2)
            emit(string.format("%.2f %.2f m %.2f %.2f l S", x1, y1, x2, y2))
        end

        -- stroke style for grid
        emit("0.5 w 0.6 G")

        -- Document header (page 1 only)
        if page.isFirst then
            local ls = self.labelSize
            local hy = self.pageH - self.margin - ls
            local function metaLine(label, value)
                text(self.margin, hy, ls, "F2", label)
                text(self.margin + 78, hy, ls, "F1", value or "")
                hy = hy - (ls + 5)
            end
            metaLine("Project:", self.meta.project)
            metaLine("Sequence:", self.meta.sequence)
            metaLine("Date:", self.meta.date)
        end

        -- Column header row
        local headerTop = page.top + self.colHeaderH
        fillRect(self.margin, page.top, tableRight - self.margin, self.colHeaderH, 0.86)
        local hBaseline = page.top + (self.colHeaderH - fs) / 2 + 1
        for _, c in ipairs(columns) do
            local cx = colByKey[c.key].x
            text(cx + padX, hBaseline, fs, "F2", c.header)
        end

        -- Data rows
        local hDividers = { headerTop, page.top }   -- horizontal lines (header top + header bottom)
        local rowTop = page.top
        for ri, info in ipairs(page.rows) do
            local row = info.row
            local rowH = info.rowH
            local rowBottom = rowTop - rowH

            -- alternating shading (light gray on every other data row)
            if ri % 2 == 0 then
                fillRect(self.margin, rowBottom, tableRight - self.margin, rowH, 0.96)
            end

            -- thumbnail (top-aligned in Frame column)
            if info.drawW > 0 then
                local imgNum = alloc()
                local data = row.jpegBytes
                local j = JpegInfo.parse(data)
                local cs = (j and j.colorSpace) or "/DeviceRGB"
                local bits = (j and j.bits) or 8
                local decode = (j and j.components == 4) and " /Decode [1 0 1 0 1 0 1 0]" or ""
                objects[imgNum] = string.format(
                    "<< /Type /XObject /Subtype /Image /Width %d /Height %d /BitsPerComponent %d /ColorSpace %s /Filter /DCTDecode%s /Length %d >>\nstream\n%s\nendstream",
                    j and j.width or 0, j and j.height or 0, bits, cs, decode, #data, data)
                local ix = imgCol.x + padX
                local iy = rowTop - padV - info.drawH
                emit(string.format("q %.2f 0 0 %.2f %.2f %.2f cm /Im%d Do Q",
                    info.drawW, info.drawH, ix, iy, imgNum))
                xobjRefs[#xobjRefs + 1] = string.format("/Im%d %d 0 R", imgNum, imgNum)
            end

            -- single-line cells, vertically centered
            local midBaseline = rowTop - rowH / 2 - fs * 0.33
            local function cell(key, str)
                local c = colByKey[key]
                text(c.x + padX, midBaseline, fs, "F1", str or "")
            end
            cell("startTC", row.startTC)
            cell("endTC", row.endTC)
            cell("duration", row.duration)
            cell("color", row.color)

            -- wrapped cells, top-aligned
            local function wrapped(key, lines)
                local c = colByKey[key]
                local ty = rowTop - padV - fs
                for _, ln in ipairs(lines) do
                    text(c.x + padX, ty, fs, "F1", ln)
                    ty = ty - lead
                end
            end
            wrapped("name", info.nameLines)
            wrapped("note", info.noteLines)

            rowTop = rowBottom
            hDividers[#hDividers + 1] = rowBottom
        end

        -- grid lines
        local tableBottom = rowTop
        for _, y in ipairs(hDividers) do
            line(self.margin, y, tableRight, y)
        end
        for i = 1, #bounds do
            line(bounds[i], headerTop, bounds[i], tableBottom)
        end

        -- footer: Page N of M (bottom-right)
        local footStr = string.format("Page %d of %d", pageIdx, totalPages)
        local fx = tableRight - stringWidth(footStr, self.footerSize)
        text(fx, self.margin - 12, self.footerSize, "F1", footStr)

        -- assemble page + content objects
        local stream = table.concat(content, "\n")
        local contentNum = alloc()
        objects[contentNum] = string.format("<< /Length %d >>\nstream\n%s\nendstream",
            #stream, stream)
        local pageNum = alloc()
        local xobjDict = "<< " .. table.concat(xobjRefs, " ") .. " >>"
        objects[pageNum] = string.format(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> /XObject %s >> /Contents %d 0 R >>",
            self.pageW, self.pageH, xobjDict, contentNum)
        kids[#kids + 1] = string.format("%d 0 R", pageNum)
    end

    -- ---- Fixed objects ----
    objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
    objects[2] = string.format("<< /Type /Pages /Kids [ %s ] /Count %d >>",
        table.concat(kids, " "), #pages)
    objects[3] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    objects[4] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"

    -- ---- Serialize with byte-offset xref ----
    local parts = {}
    local header = "%PDF-1.4\n%\226\227\207\211\n"
    parts[1] = header
    local pos = #header
    local offsets = {}
    for num = 1, nextNum - 1 do
        local objStr = string.format("%d 0 obj\n%s\nendobj\n", num, objects[num])
        offsets[num] = pos
        parts[#parts + 1] = objStr
        pos = pos + #objStr
    end

    local xrefStart = pos
    local xref = { string.format("xref\n0 %d\n0000000000 65535 f \n", nextNum) }
    for num = 1, nextNum - 1 do
        xref[#xref + 1] = string.format("%010d 00000 n \n", offsets[num])
    end
    parts[#parts + 1] = table.concat(xref)
    parts[#parts + 1] = string.format("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n",
        nextNum, xrefStart)

    return table.concat(parts), nil
end

return PdfWriter
