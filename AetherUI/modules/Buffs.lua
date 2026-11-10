-- AetherUI / Buffs
-- Player buff icons, placed by the active bar layout:
--   columns : under the Stamina bar, left to right, wrapping into new rows below
--   pyramid : under the Magicka + Stamina row, left to right, wrapping below
--   default : screen bottom-left corner, filling upwards (bottom -> top),
--             wrapping into a new column to the right
-- "Buffs per row" sets how many icons fit in one line before wrapping.
--
-- Order: timed buffs first (soonest to expire first), then permanent ones.
--
-- Performance:
--   * one event (EVENT_EFFECT_CHANGED) filtered natively to the player
--   * bursts of effect changes are coalesced into one rebuild (REBUILD_MS)
--   * icons are pooled and never destroyed; an icon keeps its slot, so icons
--     are re-anchored only when the layout or "per row" changes
--   * texture / text / hidden state are cached; the C side is touched only
--     when something actually changes
--   * the countdown poll runs only while a timed buff is on screen, at
--     TIMER_MS, and the text changes at most once per second per icon
--   * the container is a child of the bar group, so it shares the HUD
--     fragment and the settings preview with no extra scene work
--   * disabled = no events, no polls, hidden container

local AUI = AetherUI
local EM = EVENT_MANAGER

local GetNumBuffs = GetNumBuffs
local GetUnitBuffInfo = GetUnitBuffInfo
local GetFrameTimeSeconds = GetFrameTimeSeconds
local sfmt = string.format
local mceil, mfloor = math.ceil, math.floor
local tsort = table.sort

local NAME = "AetherUI_Buffs"
local REBUILD_NAME = NAME .. "Rebuild"
local TIMER_NAME = NAME .. "Timer"

local ICON_SIZE = 32
local ICON_GAP = 4
local STEP = ICON_SIZE + ICON_GAP
local BAR_GAP = 8            -- space between the bars and the first buff row
local SCREEN_MARGIN = 12     -- default layout: distance from the screen corner
local MAX_ICONS = 60         -- hard cap, protects against unusual buff floods
local REBUILD_MS = 100
local TIMER_MS = 250

local PER_ROW_MIN, PER_ROW_MAX, PER_ROW_DEFAULT = 1, 20, 8

-- Fill direction per bar layout.
local FLOW_RIGHT, FLOW_UP = "right", "up"
local FLOW = { columns = FLOW_RIGHT, pyramid = FLOW_RIGHT, default = FLOW_UP }

local Buffs = {}
AUI.Buffs = Buffs
Buffs.PER_ROW_MIN, Buffs.PER_ROW_MAX, Buffs.PER_ROW_DEFAULT = PER_ROW_MIN, PER_ROW_MAX, PER_ROW_DEFAULT

-- Time text: "45", "12m", "2h". Changes at most once per second.
local function FormatTime(sec)
    if sec >= 3600 then return sfmt("%dh", mfloor(sec / 3600)) end
    if sec >= 60 then return sfmt("%dm", mfloor(sec / 60)) end
    return sfmt("%d", mceil(sec))
end

-- Sort: timed before permanent; timed by end time; then by ability id (stable).
local function CompareEntries(a, b)
    if a.timed ~= b.timed then return a.timed end
    if a.timed and a.ending ~= b.ending then return a.ending < b.ending end
    return a.abilityId < b.abilityId
end

-- Icons ----------------------------------------------------------------------
local function SetGradient(tex, top, bottom)
    tex:SetColor(1, 1, 1, 1)
    tex:SetVertexColors(VERTEX_POINTS_TOPLEFT + VERTEX_POINTS_TOPRIGHT, top[1], top[2], top[3], 1)
    tex:SetVertexColors(VERTEX_POINTS_BOTTOMLEFT + VERTEX_POINTS_BOTTOMRIGHT, bottom[1], bottom[2], bottom[3], 1)
end
local BEVEL_TOP = { 0x8E / 255, 0x77 / 255, 0x52 / 255 }
local BEVEL_BOTTOM = { 0x2B / 255, 0x22 / 255, 0x17 / 255 }

function Buffs:CreateIcon(index)
    local c = CreateControlFromVirtual("AetherUI_Buff" .. index, self.container, "AetherUI_BuffIcon")
    SetGradient(c:GetNamedChild("Bevel"), BEVEL_TOP, BEVEL_BOTTOM)
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
function Buffs:AnchorIcon(icon)
    local i = icon.index - 1
    local perRow = self.sv.perRow
    local line, pos = mfloor(i / perRow), i % perRow
    local c = icon.control
    c:ClearAnchors()
    if self.flow == FLOW_UP then
        c:SetAnchor(BOTTOMLEFT, self.container, BOTTOMLEFT, line * STEP, -pos * STEP)
    else
        c:SetAnchor(TOPLEFT, self.container, TOPLEFT, pos * STEP, line * STEP)
    end
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

-- Module ---------------------------------------------------------------------
function Buffs:Initialize(sv)
    if type(sv.buffs) ~= "table" then sv.buffs = {} end
    self.sv = sv.buffs
    if self.sv.enabled == nil then self.sv.enabled = true end
    self.sv.perRow = zo_clamp(zo_round(tonumber(self.sv.perRow) or PER_ROW_DEFAULT), PER_ROW_MIN, PER_ROW_MAX)

    self.icons = {}
    self.entries = {}   -- reusable entry tables (no garbage per rebuild)
    self.order = {}     -- sorted references into entries
    self.shown = 0      -- icons currently visible
    self.timed = 0      -- leading icons that have a countdown
    self.registered = false

    -- Child of the bar group: same HUD fragment, same settings preview.
    local c = WINDOW_MANAGER:CreateControl("AetherUI_BuffContainer", AetherUI_Bars, CT_CONTROL)
    self.container = c

    self.onRebuild = function()
        EM:UnregisterForUpdate(REBUILD_NAME)
        self:Rebuild()
    end
    self.onTimer = function() self:UpdateTimers() end

    self.ready = true
    self:ApplyPlacement()
    self:ApplyEnabled()
end

-- Container placement for the active bar layout. Called on load and by
-- ResourceBars whenever the layout is rebuilt (layout / width / height change).
function Buffs:ApplyPlacement()
    if not self.ready then return end
    local RB = AUI.ResourceBars
    local layout = RB.sv.layout
    local flow = FLOW[layout] or FLOW_RIGHT
    local c = self.container
    c:ClearAnchors()
    if layout == "columns" then
        c:SetAnchor(TOPLEFT, RB.bars[POWERTYPE_STAMINA].control, BOTTOMLEFT, 0, BAR_GAP)
    elseif layout == "pyramid" then
        -- Magicka's left edge = left edge of the Magicka + Stamina row.
        c:SetAnchor(TOPLEFT, RB.bars[POWERTYPE_MAGICKA].control, BOTTOMLEFT, 0, BAR_GAP)
    else
        c:SetAnchor(BOTTOMLEFT, GuiRoot, BOTTOMLEFT, SCREEN_MARGIN, -SCREEN_MARGIN)
    end

    if flow ~= self.flow then
        self.flow = flow
        self:Relayout()
    else
        self:UpdateContainerSize()
    end
end

function Buffs:Relayout()
    for _, icon in ipairs(self.icons) do self:AnchorIcon(icon) end
    self:UpdateContainerSize()
end

-- Container covers the visible icons (keeps hit tests and debugging honest).
function Buffs:UpdateContainerSize()
    local n, perRow = self.shown, self.sv.perRow
    local along = n < perRow and n or perRow
    local lines = n > 0 and mceil(n / perRow) or 0
    local w, h
    if self.flow == FLOW_UP then
        w, h = lines * STEP, along * STEP
    else
        w, h = along * STEP, lines * STEP
    end
    self.container:SetDimensions(w > 0 and w - ICON_GAP or 1, h > 0 and h - ICON_GAP or 1)
end

function Buffs:ApplyEnabled()
    local enabled = self.sv.enabled
    self.container:SetHidden(not enabled)
    if enabled then
        if not self.registered then
            self.registered = true
            EM:RegisterForEvent(NAME, EVENT_EFFECT_CHANGED, function() self:ScheduleRebuild() end)
            EM:AddFilterForEvent(NAME, EVENT_EFFECT_CHANGED, REGISTER_FILTER_UNIT_TAG, "player")
            EM:RegisterForEvent(NAME .. "Full", EVENT_EFFECTS_FULL_UPDATE, function() self:ScheduleRebuild() end)
            EM:RegisterForEvent(NAME .. "Activated", EVENT_PLAYER_ACTIVATED, function() self:Rebuild() end)
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
function Buffs:ScheduleRebuild()
    EM:RegisterForUpdate(REBUILD_NAME, REBUILD_MS, self.onRebuild)
end

function Buffs:Rebuild()
    if not self.sv.enabled then return end
    local entries, order = self.entries, self.order
    local n = 0
    for i = 1, GetNumBuffs("player") do
        local _, started, ending, _, stacks, file, _, effectType, _, _, abilityId = GetUnitBuffInfo("player", i)
        if effectType == BUFF_EFFECT_TYPE_BUFF and file and file ~= "" then
            n = n + 1
            local e = entries[n]
            if not e then e = {}; entries[n] = e end
            e.timed = ending > started
            e.ending = ending
            e.stacks = stacks or 0
            e.file = file
            e.abilityId = abilityId or 0
            order[n] = e
        end
    end
    for i = n + 1, #order do order[i] = nil end
    if n > 1 then tsort(order, CompareEntries) end
    if n > MAX_ICONS then n = MAX_ICONS end

    local now = GetFrameTimeSeconds()
    local timed = 0
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
            timed = i
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
    self.timed = timed  -- timed buffs are sorted first: icons 1..timed
    if changedCount then self:UpdateContainerSize() end
    self:SetTimerRunning(timed > 0)
end

function Buffs:SetTimerRunning(run)
    if run == self.timerRunning then return end
    self.timerRunning = run
    if run then
        EM:RegisterForUpdate(TIMER_NAME, TIMER_MS, self.onTimer)
    else
        EM:UnregisterForUpdate(TIMER_NAME)
    end
end

function Buffs:UpdateTimers()
    local now = GetFrameTimeSeconds()
    local icons = self.icons
    for i = 1, self.timed do
        local icon = icons[i]
        local rem = icon.ending - now
        SetIconTime(icon, rem > 0 and FormatTime(rem) or "")
    end
end

-- Settings / slash commands ----------------------------------------------------
function Buffs:SetEnabled(enabled)
    enabled = enabled and true or false
    if self.sv.enabled == enabled then return end
    self.sv.enabled = enabled
    self:ApplyEnabled()
end

-- Returns the applied value, or nil for non-numeric input.
function Buffs:SetPerRow(count)
    count = tonumber(count)
    if not count then return nil end
    count = zo_clamp(zo_round(count), PER_ROW_MIN, PER_ROW_MAX)
    if self.sv.perRow ~= count then
        self.sv.perRow = count
        self:Relayout()
    end
    return count
end

function Buffs:HandleCommand(cmd, rest)
    if cmd ~= "buffs" then return false end
    if rest == "on" or rest == "off" then
        self:SetEnabled(rest == "on")
        AUI:Print("buffs " .. rest)
    else
        local n = self:SetPerRow(rest)
        if n then
            AUI:Print("buffs per row: " .. n)
        else
            AUI:Print(sfmt("buffs: %s, %d per row. /aether buffs <on|off|%d-%d>",
                self.sv.enabled and "on" or "off", self.sv.perRow, PER_ROW_MIN, PER_ROW_MAX))
        end
    end
    return true
end

AUI:RegisterModule("Buffs", Buffs)
