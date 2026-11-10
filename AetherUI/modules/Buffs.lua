-- AetherUI / Buffs + Debuffs
-- Player effect icons, placed by the active bar layout.
--
-- Buffs:
--   columns : under the Stamina bar, left to right, next row below
--   pyramid : under the Magicka + Stamina row, left to right, next row below
--   default : screen bottom-left corner, bottom to top,
--             next column to the right
-- Debuffs:
--   columns : above the Health bar, left to right, next row above
--   pyramid : above the Health bar, left to right, next row above
--   default : screen bottom-right corner, bottom to top,
--             next column to the left
-- "Per row" (one setting per list) sets how many icons fit in one line.
--
-- Order: permanent effects first, then timed ones (soonest to expire first).
-- Every icon has a timer slot under it; temporary effects show their countdown
-- there. The slot is always reserved, so rows never shift as effects come and go.
--
-- Performance:
--   * one event (EVENT_EFFECT_CHANGED) filtered natively to the player, shared
--     by both lists; one GetUnitBuffInfo pass feeds buffs and debuffs together
--   * bursts of effect changes are coalesced into one rebuild (REBUILD_MS)
--   * icons are pooled and never destroyed; an icon keeps its slot, so icons
--     are re-anchored only when the layout or "per row" changes
--   * texture / text / hidden state are cached; the C side is touched only
--     when something actually changes
--   * one countdown poll for both lists, running only while a timed icon is on
--     screen, at TIMER_MS; text changes at most once per second per icon
--   * containers are children of the bar group, so they share the HUD
--     fragment and the settings preview with no extra scene work
--   * a disabled list is skipped entirely; both disabled = no events, no polls

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

local NAME = "AetherUI_Effects"
local REBUILD_NAME = NAME .. "Rebuild"
local TIMER_NAME = NAME .. "Timer"

local ICON_SIZE = 32
local ICON_GAP = 4
local TIME_H = 14            -- timer text slot under each icon
local STEP_X = ICON_SIZE + ICON_GAP
local STEP_Y = ICON_SIZE + TIME_H + ICON_GAP
local BAR_GAP = 8            -- space between the bars and the first icon row
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

-- Container placement per list and bar layout.
--   bar      = power type of the bar to attach to (nil = screen corner)
--   relPoint = point on that bar / GuiRoot; ox, oy = offset
local H, M, S = POWERTYPE_HEALTH, POWERTYPE_MAGICKA, POWERTYPE_STAMINA
local PLACEMENTS = {
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

-- Effect list (one for buffs, one for debuffs) ------------------------------------
local List = {}
List.__index = List
List.PER_ROW_MIN, List.PER_ROW_MAX, List.PER_ROW_DEFAULT = PER_ROW_MIN, PER_ROW_MAX, PER_ROW_DEFAULT

local function NewList(key, label, controlPrefix)
    return setmetatable({
        key = key,                -- "buffs" | "debuffs" (saved vars + placement key)
        label = label,            -- chat output
        prefix = controlPrefix,   -- icon control names
        bevel = BEVELS[key],
        placements = PLACEMENTS[key],
        icons = {},
        entries = {},             -- reusable entry tables (no garbage per rebuild)
        order = {},               -- sorted references into entries
        count = 0,                -- entries collected in the current pass
        shown = 0,                -- icons currently visible
        timedFrom = 1,            -- icons timedFrom..shown have a countdown (timed sort last)
    }, List)
end

local Buffs = NewList("buffs", "buffs", "AetherUI_Buff")
local Debuffs = NewList("debuffs", "debuffs", "AetherUI_Debuff")
AUI.Buffs, AUI.Debuffs = Buffs, Debuffs

function List:Init(sv, enabledDefault)
    local s = sv[self.key]
    if type(s) ~= "table" then s = {}; sv[self.key] = s end
    if s.enabled == nil then s.enabled = enabledDefault end
    s.perRow = zo_clamp(zo_round(tonumber(s.perRow) or PER_ROW_DEFAULT), PER_ROW_MIN, PER_ROW_MAX)
    self.sv = s
    self.container = WINDOW_MANAGER:CreateControl(self.prefix .. "Container", AetherUI_Bars, CT_CONTROL)
    self.container:SetHidden(not s.enabled)
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
    self:AnchorIcon(icon)
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

function List:ApplyPlacement(layout, bars)
    local p = self.placements[layout] or self.placements.default
    local flow = FLOWS[p.flow]
    local c = self.container
    c:ClearAnchors()
    c:SetAnchor(flow.point, p.bar and bars[p.bar].control or GuiRoot, p.relPoint, p.ox, p.oy)
    if flow ~= self.flow then
        self.flow = flow
        self:Relayout()
    else
        self:UpdateContainerSize()
    end
end

function List:Relayout()
    if not self.flow then return end
    for _, icon in ipairs(self.icons) do self:AnchorIcon(icon) end
    self:UpdateContainerSize()
end

-- Container covers the visible icons (keeps hit tests and debugging honest).
function List:UpdateContainerSize()
    local n, perRow = self.shown, self.sv.perRow
    local along = n < perRow and n or perRow
    local lines = n > 0 and mceil(n / perRow) or 0
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

-- Drop every icon (list turned off).
function List:Clear()
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
    AUI.Effects:ApplyEnabled()
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
    if cmd ~= self.key then return false end
    if rest == "on" or rest == "off" then
        self:SetEnabled(rest == "on")
        AUI:Print(self.label .. " " .. rest)
    else
        local n = self:SetPerRow(rest)
        if n then
            AUI:Print(self.label .. " per row: " .. n)
        else
            AUI:Print(sfmt("%s: %s, %d per row. /aether %s <on|off|%d-%d>", self.label,
                self.sv.enabled and "on" or "off", self.sv.perRow, self.key, PER_ROW_MIN, PER_ROW_MAX))
        end
    end
    return true
end

-- Shared driver: events, scan, countdown --------------------------------------------
local Effects = { registered = false, timerRunning = false }
AUI.Effects = Effects

function Effects:Initialize(sv)
    Buffs:Init(sv, true)
    Debuffs:Init(sv, true)

    self.onRebuild = function()
        EM:UnregisterForUpdate(REBUILD_NAME)
        self:Rebuild()
    end
    self.onTimer = function()
        local now = GetFrameTimeSeconds()
        if Buffs.sv.enabled then Buffs:UpdateTimers(now) end
        if Debuffs.sv.enabled then Debuffs:UpdateTimers(now) end
    end
    self.onSchedule = function() self:ScheduleRebuild() end

    self.ready = true
    self:ApplyPlacement()
    self:ApplyEnabled()
end

-- Container placement for the active bar layout. Called on load and by
-- ResourceBars whenever the layout is rebuilt (layout / width / height change).
function Effects:ApplyPlacement()
    if not self.ready then return end
    local RB = AUI.ResourceBars
    local layout, bars = RB.sv.layout, RB.bars
    Buffs:ApplyPlacement(layout, bars)
    Debuffs:ApplyPlacement(layout, bars)
end

function Effects:ApplyEnabled()
    local any = Buffs.sv.enabled or Debuffs.sv.enabled
    if any then
        if not self.registered then
            self.registered = true
            EM:RegisterForEvent(NAME, EVENT_EFFECT_CHANGED, self.onSchedule)
            EM:AddFilterForEvent(NAME, EVENT_EFFECT_CHANGED, REGISTER_FILTER_UNIT_TAG, "player")
            EM:RegisterForEvent(NAME .. "Full", EVENT_EFFECTS_FULL_UPDATE, self.onSchedule)
            EM:RegisterForEvent(NAME .. "Activated", EVENT_PLAYER_ACTIVATED, self.onRebuild)
        end
        self:Rebuild()
    else
        if self.registered then
            self.registered = false
            EM:UnregisterForEvent(NAME, EVENT_EFFECT_CHANGED)
            EM:UnregisterForEvent(NAME .. "Full", EVENT_EFFECTS_FULL_UPDATE)
            EM:UnregisterForEvent(NAME .. "Activated", EVENT_PLAYER_ACTIVATED)
        end
        EM:UnregisterForUpdate(REBUILD_NAME)
        self:SetTimerRunning(false)
    end
end

-- Many effects change in the same moment (e.g. a set proc + its Major/Minor
-- buffs). Registering an already registered update is a no-op, so a burst
-- collapses into a single rebuild.
function Effects:ScheduleRebuild()
    EM:RegisterForUpdate(REBUILD_NAME, REBUILD_MS, self.onRebuild)
end

-- One pass over the player's effects feeds both lists.
function Effects:Rebuild()
    local wantBuffs, wantDebuffs = Buffs.sv.enabled, Debuffs.sv.enabled
    if not (wantBuffs or wantDebuffs) then return end
    Buffs.count, Debuffs.count = 0, 0
    for i = 1, GetNumBuffs("player") do
        local _, started, ending, _, stacks, file, _, effectType, _, _, abilityId = GetUnitBuffInfo("player", i)
        if file and file ~= "" then
            if effectType == BUFF then
                if wantBuffs then Buffs:Add(started, ending, stacks, file, abilityId) end
            elseif effectType == DEBUFF then
                if wantDebuffs then Debuffs:Add(started, ending, stacks, file, abilityId) end
            end
        end
    end

    local now = GetFrameTimeSeconds()
    local timed = false
    if wantBuffs and Buffs:Commit(now) then timed = true end
    if wantDebuffs and Debuffs:Commit(now) then timed = true end
    self:SetTimerRunning(timed)
end

function Effects:SetTimerRunning(run)
    if run == self.timerRunning then return end
    self.timerRunning = run
    if run then
        EM:RegisterForUpdate(TIMER_NAME, TIMER_MS, self.onTimer)
    else
        EM:UnregisterForUpdate(TIMER_NAME)
    end
end

function Effects:HandleCommand(cmd, rest)
    return Buffs:HandleCommand(cmd, rest) or Debuffs:HandleCommand(cmd, rest)
end

AUI:RegisterModule("Effects", Effects)
