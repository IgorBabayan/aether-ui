-- AetherUI / Buffs + Debuffs
-- Effect icons for the player (here) and the target (Target module, built on
-- the same lists and trackers exported below).
--
-- Player buffs:
--   columns : under the Stamina bar, left to right, next row below
--   pyramid : under the Magicka + Stamina row, left to right, next row below
--             (pyramid: under the companion bar while it is shown at its
--             default spot under the player bars)
--   default : screen bottom-left corner, bottom to top,
--             next column to the right
-- Player debuffs:
--   columns : above the Health bar, left to right, next row above
--   pyramid : above the Health bar, left to right, next row above
--   default : screen bottom-right corner, bottom to top,
--             next column to the left
-- "Per row" (one setting per list) sets how many icons fit in one line.
--
-- Drag and drop (unlock mode): every list can be dragged to its own spot.
-- The spot is the list's first-icon corner, so rows still grow the same way.
--   player lists : saved as a screen position
--   target lists : saved relative to the target bar, so they move with it
-- Reset position puts every list back on its layout spot.
--
-- Order: permanent effects first, then timed ones (soonest to expire first).
-- Every icon has a timer slot under it; temporary effects show their countdown
-- there. The slot is always reserved, so rows never shift as effects come and go.
--
-- Performance:
--   * one tracker per unit; one EVENT_EFFECT_CHANGED registration per tracker,
--     filtered natively to its unit; one GetUnitBuffInfo pass feeds both lists
--   * bursts of effect changes are coalesced into one rebuild (REBUILD_MS)
--   * icons are pooled and never destroyed; an icon keeps its slot, so icons
--     are re-anchored only when the layout or "per row" changes
--   * texture / text / hidden state are cached; the C side is touched only
--     when something actually changes
--   * one countdown poll per tracker, running only while a timed icon is on
--     screen, at TIMER_MS; text changes at most once per second per icon
--   * containers are children of their bar frame, so they share its HUD
--     fragment and the settings preview with no extra scene work
--   * a disabled list is skipped entirely; both disabled (or the tracker
--     suspended) = no events, no polls
--   * dragging adds nothing while locked: the drag frame is created on the
--     first unlock, and the drag poll (ResourceBars) runs only while held

local AUI = AetherUI
local EM = EVENT_MANAGER

local GetNumBuffs = GetNumBuffs
local GetUnitBuffInfo = GetUnitBuffInfo
local GetFrameTimeSeconds = GetFrameTimeSeconds
local BUFF = BUFF_EFFECT_TYPE_BUFF
local DEBUFF = BUFF_EFFECT_TYPE_DEBUFF
local sfmt = string.format
local mceil, mfloor = math.ceil, math.floor
local tsort = table.sort

local ICON_SIZE = 32
local ICON_GAP = 4
local TIME_H = 14            -- timer text slot under each icon
local STEP_X = ICON_SIZE + ICON_GAP
local STEP_Y = ICON_SIZE + TIME_H + ICON_GAP
local BAR_GAP = 8            -- space between a bar and the first icon row
local SCREEN_MARGIN = 12     -- default layout: distance from the screen corner
local MAX_ICONS = 60         -- hard cap per list, protects against effect floods
local REBUILD_MS = 100
local TIMER_MS = 250

local PER_ROW_MIN, PER_ROW_MAX, PER_ROW_DEFAULT = 1, 20, 8

-- Fill directions. Icon offset = base + pos * along + line * wrap,
-- measured from the container's anchor point.
--   vertical = icons of one line run up/down (a "row" is a column of icons)
local FLOWS = {
    rightDown = { point = TOPLEFT,     ax = STEP_X, ay = 0,       lx = 0,       ly = STEP_Y,  by = 0 },
    rightUp   = { point = BOTTOMLEFT,  ax = STEP_X, ay = 0,       lx = 0,       ly = -STEP_Y, by = -TIME_H },
    upRight   = { point = BOTTOMLEFT,  ax = 0,      ay = -STEP_Y, lx = STEP_X,  ly = 0,       by = -TIME_H, vertical = true },
    upLeft    = { point = BOTTOMRIGHT, ax = 0,      ay = -STEP_Y, lx = -STEP_X, ly = 0,       by = -TIME_H, vertical = true },
}

-- Player container placement per list and bar layout.
--   bar      = power type of the bar to attach to (nil = screen corner)
--   relPoint = point on that bar / GuiRoot; ox, oy = offset
local H, M, S = POWERTYPE_HEALTH, POWERTYPE_MAGICKA, POWERTYPE_STAMINA
local PLAYER_PLACEMENTS = {
    buffs = {
        columns = { flow = "rightDown", bar = S, relPoint = BOTTOMLEFT, ox = 0, oy = BAR_GAP },
        pyramid = { flow = "rightDown", bar = M, relPoint = BOTTOMLEFT, ox = 0, oy = BAR_GAP },
        default = { flow = "upRight", relPoint = BOTTOMLEFT, ox = SCREEN_MARGIN, oy = -SCREEN_MARGIN },
    },
    debuffs = {
        columns = { flow = "rightUp", bar = H, relPoint = TOPLEFT, ox = 0, oy = -BAR_GAP },
        pyramid = { flow = "rightUp", bar = H, relPoint = TOPLEFT, ox = 0, oy = -BAR_GAP },
        default = { flow = "upLeft", relPoint = BOTTOMRIGHT, ox = -SCREEN_MARGIN, oy = -SCREEN_MARGIN },
    },
}

-- Frame colors: bronze for buffs (matches the bars), dark red for debuffs.
local function RGB(hex)
    return { mfloor(hex / 0x10000) / 255, mfloor(hex / 0x100) % 0x100 / 255, hex % 0x100 / 255 }
end
local BEVELS = {
    buffs = { top = RGB(0x8E7752), bottom = RGB(0x2B2217) },
    debuffs = { top = RGB(0xA0382C), bottom = RGB(0x2E0E0A) },
}

-- Time text: "45", "12m", "2h". Changes at most once per second.
local function FormatTime(sec)
    if sec >= 3600 then return sfmt("%dh", mfloor(sec / 3600)) end
    if sec >= 60 then return sfmt("%dm", mfloor(sec / 60)) end
    return sfmt("%d", mceil(sec))
end

-- Sort: permanent before timed; timed by end time; then by ability id (stable).
local function CompareEntries(a, b)
    if a.timed ~= b.timed then return b.timed end
    if a.timed and a.ending ~= b.ending then return a.ending < b.ending end
    return a.abilityId < b.abilityId
end

local function SetGradient(tex, top, bottom)
    tex:SetColor(1, 1, 1, 1)
    tex:SetVertexColors(VERTEX_POINTS_TOPLEFT + VERTEX_POINTS_TOPRIGHT, top[1], top[2], top[3], 1)
    tex:SetVertexColors(VERTEX_POINTS_BOTTOMLEFT + VERTEX_POINTS_BOTTOMRIGHT, bottom[1], bottom[2], bottom[3], 1)
end

local function SetIconHidden(icon, hidden)
    if icon.hidden ~= hidden then
        icon.hidden = hidden
        icon.control:SetHidden(hidden)
    end
end

local function SetIconTime(icon, text)
    if icon.timeText ~= text then
        icon.timeText = text
        icon.time:SetText(text)
    end
end

-- Effect list (one per unit and effect type) ------------------------------------
local List = {}
List.__index = List
List.PER_ROW_MIN, List.PER_ROW_MAX, List.PER_ROW_DEFAULT = PER_ROW_MIN, PER_ROW_MAX, PER_ROW_DEFAULT

-- o.key    : saved vars key        o.cmd   : slash command (default: key)
-- o.label  : chat output           o.prefix: icon control names
-- o.bevel  : "buffs" | "debuffs" frame colors
-- o.dragLabel: name shown in unlock mode
local function NewList(o)
    return setmetatable({
        key = o.key,
        cmd = o.cmd or o.key,
        label = o.label,
        dragLabel = o.dragLabel or o.label,
        prefix = o.prefix,
        bevel = BEVELS[o.bevel],
        icons = {},
        entries = {},             -- reusable entry tables (no garbage per rebuild)
        order = {},               -- sorted references into entries
        count = 0,                -- entries collected in the current pass
        shown = 0,                -- icons currently visible
        timedFrom = 1,            -- icons timedFrom..shown have a countdown (timed sort last)
        unlocked = false,
    }, List)
end

-- Where on a rect a point sits, as -1 / 0 / +1 of the half size from the centre.
local POINT_SIGN = {
    [TOPLEFT] = { -1, -1 }, [TOPRIGHT] = { 1, -1 },
    [BOTTOMLEFT] = { -1, 1 }, [BOTTOMRIGHT] = { 1, 1 },
}

-- parent: control the icon container belongs to (shares its visibility).
-- dragRelTo: control a dragged spot is saved against (nil = the screen).
function List:Init(sv, parent, tracker, dragRelTo)
    local s = sv[self.key]
    if type(s) ~= "table" then s = {}; sv[self.key] = s end
    if s.enabled == nil then s.enabled = true end
    s.perRow = zo_clamp(zo_round(tonumber(s.perRow) or PER_ROW_DEFAULT), PER_ROW_MIN, PER_ROW_MAX)
    if type(s.point) ~= "table" or not (tonumber(s.point.x) and tonumber(s.point.y)) then s.point = nil end
    self.sv = s
    self.tracker = tracker
    self.dragRelTo = dragRelTo
    local c = WINDOW_MANAGER:CreateControl(self.prefix .. "Container", parent, CT_CONTROL)
    self.container = c
    c:SetHidden(not s.enabled)
    self.onDragSave = function(x, y) self:SaveDragged(x, y) end
    c:SetHandler("OnMouseDown", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then AUI.ResourceBars:BeginFreeDrag(c, 0, 0, self.onDragSave) end
    end)
    c:SetHandler("OnMouseUp", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then AUI.ResourceBars:EndDrag() end
    end)
end

function List:CreateIcon(index)
    local c = CreateControlFromVirtual(self.prefix .. index, self.container, "AetherUI_BuffIcon")
    SetGradient(c:GetNamedChild("Bevel"), self.bevel.top, self.bevel.bottom)
    local icon = {
        control = c,
        tex = c:GetNamedChild("Icon"),
        time = c:GetNamedChild("Time"),
        stack = c:GetNamedChild("Stack"),
        index = index,
        hidden = true,
        file = nil, timeText = nil, stackText = nil, ending = 0,
    }
    self.icons[index] = icon
    if self.flow then self:AnchorIcon(icon) end
    return icon
end

-- Slot -> position. Line = one row of "per row" icons along the flow.
-- A slot is the icon plus its timer text underneath.
function List:AnchorIcon(icon)
    local f = self.flow
    local i = icon.index - 1
    local perRow = self.sv.perRow
    local line, pos = mfloor(i / perRow), i % perRow
    local c = icon.control
    c:ClearAnchors()
    c:SetAnchor(f.point, self.container, f.point, pos * f.ax + line * f.lx, f.by + pos * f.ay + line * f.ly)
end

-- p = { flow, relPoint, ox, oy }; relTo = control to attach to (nil = GuiRoot).
-- A dragged spot (sv.point) wins over p. Not a hot path: load / layout change only.
function List:Place(p, relTo)
    self.placement, self.placeRelTo = p, relTo
    local flow = FLOWS[p.flow]
    if flow ~= self.flow then
        self.flow = flow
        self:Relayout()
    else
        self:UpdateContainerSize()
    end
    self:ApplyAnchor()
end

function List:ApplyAnchor()
    local p = self.placement
    if not p then return end
    local c, point = self.container, self.flow.point
    c:ClearAnchors()
    local spot = self.sv.point
    if spot then
        c:SetAnchor(point, self.dragRelTo or GuiRoot, TOPLEFT, spot.x, spot.y)
    else
        c:SetAnchor(point, self.placeRelTo or GuiRoot, p.relPoint, p.ox, p.oy)
    end
end

-- Drag ended with the container centred on (x, y): save its flow corner.
function List:SaveDragged(x, y)
    local w, h = self.container:GetDimensions()
    local sign = POINT_SIGN[self.flow.point]
    x, y = x + sign[1] * w / 2, y + sign[2] * h / 2
    local rel = self.dragRelTo
    if rel then x, y = x - rel:GetLeft(), y - rel:GetTop() end
    self.sv.point = { x = zo_round(x), y = zo_round(y) }
    self:ApplyAnchor()
end

function List:ResetPosition()
    if not self.sv or not self.sv.point then return end
    self.sv.point = nil
    self:ApplyAnchor()
end

-- Unlock mode: the list gets a drag frame at least one full row in size, so it
-- can be grabbed and placed even with no icons.
function List:SetUnlocked(unlocked)
    if not self.container or self.unlocked == unlocked then return end
    self.unlocked = unlocked
    local c = self.container
    if unlocked and not self.dragOverlay then
        local o = WINDOW_MANAGER:CreateControl(self.prefix .. "DragOverlay", c, CT_TEXTURE)
        o:SetColor(0.784, 0.643, 0.392, 0.18)
        o:SetAnchorFill(c)
        o:SetDrawLevel(0)
        local l = WINDOW_MANAGER:CreateControl(self.prefix .. "DragLabel", c, CT_LABEL)
        l:SetFont("ZoFontGameSmall")
        l:SetColor(0.91, 0.86, 0.75, 1)
        l:SetText(self.dragLabel)
        l:SetAnchor(CENTER, c, CENTER, 0, 0)
        l:SetDrawLevel(10)
        self.dragOverlay, self.dragText = o, l
    end
    if self.dragOverlay then
        self.dragOverlay:SetHidden(not unlocked)
        self.dragText:SetHidden(not unlocked)
    end
    c:SetMouseEnabled(unlocked)
    self:UpdateContainerSize()
end

function List:Relayout()
    if not self.flow then return end
    for _, icon in ipairs(self.icons) do self:AnchorIcon(icon) end
    self:UpdateContainerSize()
end

-- Container covers the visible icons (keeps hit tests and debugging honest).
function List:UpdateContainerSize()
    if not self.flow then return end
    local n, perRow = self.shown, self.sv.perRow
    local along = n < perRow and n or perRow
    local lines = n > 0 and mceil(n / perRow) or 0
    if self.unlocked then
        along = perRow
        if lines < 1 then lines = 1 end
    end
    local w, h
    if self.flow.vertical then
        w, h = lines * STEP_X, along * STEP_Y
    else
        w, h = along * STEP_X, lines * STEP_Y
    end
    self.container:SetDimensions(w > 0 and w - ICON_GAP or 1, h > 0 and h - ICON_GAP or 1)
end

-- Collect one effect during the shared scan.
function List:Add(started, ending, stacks, file, abilityId)
    local n = self.count + 1
    self.count = n
    local e = self.entries[n]
    if not e then e = {}; self.entries[n] = e end
    e.timed = ending > started
    e.ending = ending
    e.stacks = stacks or 0
    e.file = file
    e.abilityId = abilityId or 0
    self.order[n] = e
end

-- Push the collected effects to the icons. Returns true if any icon is timed.
function List:Commit(now)
    local order, n = self.order, self.count
    for i = n + 1, #order do order[i] = nil end
    if n > 1 then tsort(order, CompareEntries) end
    if n > MAX_ICONS then n = MAX_ICONS end

    local timedFrom = n + 1
    for i = 1, n do
        local e = order[i]
        local icon = self.icons[i] or self:CreateIcon(i)
        if icon.file ~= e.file then
            icon.file = e.file
            icon.tex:SetTexture(e.file)
        end
        local stackText = e.stacks > 1 and tostring(e.stacks) or ""
        if icon.stackText ~= stackText then
            icon.stackText = stackText
            icon.stack:SetText(stackText)
        end
        if e.timed then
            if i < timedFrom then timedFrom = i end
            icon.ending = e.ending
            local rem = e.ending - now
            SetIconTime(icon, rem > 0 and FormatTime(rem) or "")
        else
            icon.ending = 0
            SetIconTime(icon, "")
        end
        SetIconHidden(icon, false)
    end
    for i = n + 1, self.shown do
        SetIconHidden(self.icons[i], true)
    end

    local changedCount = n ~= self.shown
    self.shown = n
    self.timedFrom = timedFrom
    if changedCount then self:UpdateContainerSize() end
    return timedFrom <= n
end

function List:UpdateTimers(now)
    local icons = self.icons
    for i = self.timedFrom, self.shown do
        local icon = icons[i]
        local rem = icon.ending - now
        SetIconTime(icon, rem > 0 and FormatTime(rem) or "")
    end
end

-- Drop every icon (list turned off / tracker suspended).
function List:Clear()
    if self.shown == 0 then return end
    self.count = 0
    self:Commit(0)
end

-- Settings / slash commands ----------------------------------------------------
function List:SetEnabled(enabled)
    enabled = enabled and true or false
    if self.sv.enabled == enabled then return end
    self.sv.enabled = enabled
    self.container:SetHidden(not enabled)
    if not enabled then self:Clear() end
    self.tracker:ApplyEnabled()
end

-- Returns the applied value, or nil for non-numeric input.
function List:SetPerRow(count)
    count = tonumber(count)
    if not count then return nil end
    count = zo_clamp(zo_round(count), PER_ROW_MIN, PER_ROW_MAX)
    if self.sv.perRow ~= count then
        self.sv.perRow = count
        self:Relayout()
    end
    return count
end

function List:HandleCommand(cmd, rest)
    if cmd ~= self.cmd then return false end
    if rest == "on" or rest == "off" then
        self:SetEnabled(rest == "on")
        AUI:Print(self.label .. " " .. rest)
    else
        local n = self:SetPerRow(rest)
        if n then
            AUI:Print(self.label .. " per row: " .. n)
        else
            AUI:Print(sfmt("%s: %s, %d per row. /aether %s <on|off|%d-%d>", self.label,
                self.sv.enabled and "on" or "off", self.sv.perRow, self.cmd, PER_ROW_MIN, PER_ROW_MAX))
        end
    end
    return true
end

-- Tracker: events, scan and countdown for one unit ------------------------------
local Tracker = {}
Tracker.__index = Tracker

local function NewTracker(unitTag, name, buffs, debuffs)
    local t = setmetatable({
        unitTag = unitTag,
        name = name,
        rebuildName = name .. "Rebuild",
        timerName = name .. "Timer",
        buffs = buffs,
        debuffs = debuffs,
        registered = false,
        timerRunning = false,
        suspended = false,   -- owner switched off (target bar disabled)
    }, Tracker)
    t.onRebuild = function()
        EM:UnregisterForUpdate(t.rebuildName)
        t:Rebuild()
    end
    t.onTimer = function()
        local now = GetFrameTimeSeconds()
        if buffs.sv.enabled then buffs:UpdateTimers(now) end
        if debuffs.sv.enabled then debuffs:UpdateTimers(now) end
    end
    -- Many effects change in the same moment (e.g. a set proc + its Major/Minor
    -- buffs). Registering an already registered update is a no-op, so a burst
    -- collapses into a single rebuild.
    t.onSchedule = function()
        EM:RegisterForUpdate(t.rebuildName, REBUILD_MS, t.onRebuild)
    end
    return t
end

function Tracker:IsActive()
    return not self.suspended and (self.buffs.sv.enabled or self.debuffs.sv.enabled)
end

function Tracker:ApplyEnabled()
    local name = self.name
    if self:IsActive() then
        if not self.registered then
            self.registered = true
            EM:RegisterForEvent(name, EVENT_EFFECT_CHANGED, self.onSchedule)
            EM:AddFilterForEvent(name, EVENT_EFFECT_CHANGED, REGISTER_FILTER_UNIT_TAG, self.unitTag)
            EM:RegisterForEvent(name .. "Full", EVENT_EFFECTS_FULL_UPDATE, self.onSchedule)
            EM:RegisterForEvent(name .. "Activated", EVENT_PLAYER_ACTIVATED, self.onRebuild)
        end
        self:Rebuild()
    else
        if self.registered then
            self.registered = false
            EM:UnregisterForEvent(name, EVENT_EFFECT_CHANGED)
            EM:UnregisterForEvent(name .. "Full", EVENT_EFFECTS_FULL_UPDATE)
            EM:UnregisterForEvent(name .. "Activated", EVENT_PLAYER_ACTIVATED)
        end
        EM:UnregisterForUpdate(self.rebuildName)
        self:SetTimerRunning(false)
        self.buffs:Clear()
        self.debuffs:Clear()
    end
end

function Tracker:SetSuspended(suspended)
    if self.suspended == suspended then return end
    self.suspended = suspended
    self:ApplyEnabled()
end

-- Rebuild right away, dropping any pending coalesced rebuild (unit changed).
function Tracker:RebuildNow()
    EM:UnregisterForUpdate(self.rebuildName)
    self:Rebuild()
end

-- One pass over the unit's effects feeds both lists. A unit that does not
-- exist has no effects, so this also clears the icons.
function Tracker:Rebuild()
    if self.suspended then return end
    local buffs, debuffs = self.buffs, self.debuffs
    local wantBuffs, wantDebuffs = buffs.sv.enabled, debuffs.sv.enabled
    if not (wantBuffs or wantDebuffs) then return end
    local unit = self.unitTag
    buffs.count, debuffs.count = 0, 0
    for i = 1, GetNumBuffs(unit) do
        local _, started, ending, _, stacks, file, _, effectType, _, _, abilityId = GetUnitBuffInfo(unit, i)
        if file and file ~= "" then
            if effectType == BUFF then
                if wantBuffs then buffs:Add(started, ending, stacks, file, abilityId) end
            elseif effectType == DEBUFF then
                if wantDebuffs then debuffs:Add(started, ending, stacks, file, abilityId) end
            end
        end
    end

    local now = GetFrameTimeSeconds()
    local timed = false
    if wantBuffs and buffs:Commit(now) then timed = true end
    if wantDebuffs and debuffs:Commit(now) then timed = true end
    self:SetTimerRunning(timed)
end

function Tracker:SetTimerRunning(run)
    if run == self.timerRunning then return end
    self.timerRunning = run
    if run then
        EM:RegisterForUpdate(self.timerName, TIMER_MS, self.onTimer)
    else
        EM:UnregisterForUpdate(self.timerName)
    end
end

-- Player effects ------------------------------------------------------------------
local Buffs = NewList({ key = "buffs", label = "buffs", dragLabel = "Buffs", prefix = "AetherUI_Buff", bevel = "buffs" })
local Debuffs = NewList({ key = "debuffs", label = "debuffs", dragLabel = "Debuffs", prefix = "AetherUI_Debuff", bevel = "debuffs" })
AUI.Buffs, AUI.Debuffs = Buffs, Debuffs

local Effects = {
    -- Building blocks for other units (Target module).
    NewList = NewList,
    NewTracker = NewTracker,
    BAR_GAP = BAR_GAP,
}
AUI.Effects = Effects

function Effects:Initialize(sv)
    local tracker = NewTracker("player", "AetherUI_Effects", Buffs, Debuffs)
    self.tracker = tracker
    Buffs:Init(sv, AetherUI_Bars, tracker)
    Debuffs:Init(sv, AetherUI_Bars, tracker)

    self.ready = true
    self:ApplyPlacement()
    tracker:ApplyEnabled()
end

-- Container placement for the active bar layout. Called on load and by
-- ResourceBars whenever the layout is rebuilt (layout / width / height change).
function Effects:ApplyPlacement()
    if not self.ready then return end
    local RB = AUI.ResourceBars
    local layout, bars = RB.sv.layout, RB.bars
    local pb = PLAYER_PLACEMENTS.buffs[layout] or PLAYER_PLACEMENTS.buffs.default
    local pd = PLAYER_PLACEMENTS.debuffs[layout] or PLAYER_PLACEMENTS.debuffs.default
    local buffRel = pb.bar and bars[pb.bar].control
    if buffRel and AUI.Companion then
        buffRel = AUI.Companion:GetBuffAnchor() or buffRel -- same left edge
    end
    Buffs:Place(pb, buffRel)
    Debuffs:Place(pd, pd.bar and bars[pd.bar].control)
end

function Effects:SetUnlocked(unlocked)
    if not self.ready then return end
    Buffs:SetUnlocked(unlocked)
    Debuffs:SetUnlocked(unlocked)
end

function Effects:ResetPosition()
    if not self.ready then return end
    Buffs:ResetPosition()
    Debuffs:ResetPosition()
end

function Effects:HandleCommand(cmd, rest)
    return Buffs:HandleCommand(cmd, rest) or Debuffs:HandleCommand(cmd, rest)
end

AUI:RegisterModule("Effects", Effects)
