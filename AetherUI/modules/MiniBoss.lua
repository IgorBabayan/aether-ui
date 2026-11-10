-- AetherUI / MiniBoss
-- Health bars for mini-bosses: bosses a main boss summons, or that already
-- stand next to it. One bar per mini-boss, stacked top to bottom, with the
-- mini-boss name on the left inside the bar and the HP text on the right.
-- Bars only: no buffs / debuffs.
--
-- Who is the main boss: ESO tags every boss-flagged enemy in an encounter as
-- boss1..bossN and gives no "main" flag, so the boss with the largest max
-- health is the main one (first by tag on a tie). Every other living boss
-- unit is a mini-boss. One boss alone = no bars. ESO's own boss bar under the
-- compass is left as it is.
--
-- Spot: a column right next to the target bar (the boss bar while you target
-- the boss), on its outer side:
--   * one mini-boss  : its bar is level with the target bar
--   * two or more    : the column is centred on the target bar's row
-- The column goes on the right of the target bar. With wide bars the
-- mini-boss bars get narrower to fit the space left on the right (down to
-- MIN_WIDTH); only below that does the column move to the target bar's left.
-- The column is anchored to the target bar, so it follows it when the target
-- bar is dragged; grabbing a mini-boss bar in unlock mode drags the target bar.
-- Width / height / text follow the player bar settings; bars are at least
-- tall enough for the name.
--
-- Performance:
--   * same Bar class as the player bars: one shared ticker that runs only
--     while something animates, cached widths / text
--   * one health event registration for all boss units, filtered natively
--     (unit tag prefix "boss" + health); the handler is a single table lookup
--   * boss list changes, deaths and max-health changes are coalesced into one
--     rebuild on the next frame; the rebuild walks at most MAX_BOSSES tags
--   * bars are pooled and never destroyed; a bar is re-pointed at a new unit
--     instead of being recreated; names are pushed only when they change
--   * no mini-bosses = frame hidden, nothing runs; disabled = no events at all
--   * centring is native anchoring: the top-level is resized only when the
--     number of bars changes, and the side is picked only when the target bar
--     or the bar size changes, never per frame

local AUI = AetherUI
local EM = EVENT_MANAGER

local DoesUnitExist = DoesUnitExist
local IsUnitDead = IsUnitDead
local GetUnitName = GetUnitName
local GetUnitPower = GetUnitPower
local zo_strformat = zo_strformat

local NAME = "AetherUI_MiniBoss"
local REBUILD_NAME = NAME .. "Rebuild"
local MAX = MAX_BOSSES or 12
local BOSS_TAGS = {}
for i = 1, MAX do BOSS_TAGS[i] = "boss" .. i end

local ROW_GAP = 8            -- space between stacked bars
local SIDE_GAP = 8           -- space between the target bar's spikes and ours
local SCREEN_MARGIN = 8
local MIN_WIDTH = 140        -- narrowest mini-boss bar before switching side
local TEXT_PAD = 6           -- name / value inset from the bar ends
local NAME_VALUE_GAP = 8
local BAR_CFG = { grow = "center" }
local PLACEHOLDER = "Mini-boss"
local NAME_FONT = "$(BOLD_FONT)|13|soft-shadow-thick"

local MiniBoss = {
    ready = false,
    registered = false,
    unlocked = false,
    preview = false,
    shown = false,
    pending = false,
    count = 0,       -- bars currently shown
}
AUI.MiniBoss = MiniBoss

function MiniBoss:Initialize(sv)
    local s = sv.miniBoss
    if type(s) ~= "table" then s = {}; sv.miniBoss = s end
    if s.enabled == nil then s.enabled = true end
    self.sv = s

    local tl = AetherUI_MiniBoss
    self.topLevel, self.frame = tl, tl:GetNamedChild("Frame")
    self.slots = {}      -- pooled { bar, nameLabel, tag, name }
    self.byTag = {}      -- unit tag -> slot, for the health event
    self.maxByTag = {}   -- unit tag -> max health seen at the last rebuild
    self.list = {}       -- reused: mini-boss tags in the current rebuild
    self.width, self.barHeight = 0, 0   -- shown size (width may be narrowed to fit)
    self.baseWidth = 0                  -- bar width setting
    self.textOn = false
    self.side = nil      -- RIGHT / LEFT of the target bar
    s.point = nil        -- 0.10: own saved spot, now follows the target bar

    local fragment = ZO_HUDFadeSceneFragment:New(tl)
    self.fragment = fragment
    HUD_SCENE:AddFragment(fragment)
    HUD_UI_SCENE:AddFragment(fragment)

    self.onRebuild = function()
        EM:UnregisterForUpdate(REBUILD_NAME)
        self.pending = false
        self:Rebuild()
    end
    self.queueRebuild = function() self:QueueRebuild() end
    self.onActivated = function() self:Rebuild() end
    self.onPower = function(_, unitTag, _, _, value, _, effectiveMax)
        local slot = self.byTag[unitTag]
        if slot then slot.bar:SetValue(value, effectiveMax) end
        -- Max health decides who is the main boss.
        if effectiveMax ~= self.maxByTag[unitTag] then self:QueueRebuild() end
    end

    self.ready = true
    self:ApplyLayout() -- also places the column
    self:ApplyEnabled()
end

-- Bars ---------------------------------------------------------------------------
local function AnchorName(slot, withValue)
    local label, bar = slot.nameLabel, slot.bar
    label:ClearAnchors()
    label:SetAnchor(LEFT, bar.track, LEFT, TEXT_PAD, 1)
    if withValue then
        label:SetAnchor(RIGHT, bar.valueLabel, LEFT, -NAME_VALUE_GAP, 0)
    else
        label:SetAnchor(RIGHT, bar.track, RIGHT, -TEXT_PAD, 1)
    end
end

function MiniBoss:GetSlot(i)
    local slot = self.slots[i]
    if slot then return slot end

    local RB = AUI.ResourceBars
    local bar = RB:CreateBar(self.frame, POWERTYPE_HEALTH, BOSS_TAGS[1], NAME .. "Bar" .. i)
    local c = bar.control
    c:SetHidden(true)
    if i == 1 then
        c:SetAnchor(TOPLEFT, self.frame, TOPLEFT, 0, 0)
    else
        c:SetAnchor(TOPLEFT, self.slots[i - 1].bar.control, BOTTOMLEFT, 0, ROW_GAP)
    end
    bar.dragLabel:SetText("Mini-bosses")

    -- HP text moves to the right end; the name takes the left.
    local value = bar.valueLabel
    value:ClearAnchors()
    value:SetAnchor(RIGHT, bar.track, RIGHT, -TEXT_PAD, 1)
    value:SetHorizontalAlignment(TEXT_ALIGN_RIGHT)

    local label = WINDOW_MANAGER:CreateControl(NAME .. "Name" .. i, c, CT_LABEL)
    label:SetFont(NAME_FONT)
    label:SetColor(0.91, 0.86, 0.75, 1)
    label:SetHorizontalAlignment(TEXT_ALIGN_LEFT)
    label:SetVerticalAlignment(TEXT_ALIGN_CENTER)
    label:SetMaxLineCount(1)
    label:SetWrapMode(TEXT_WRAP_MODE_ELLIPSIS)
    label:SetDrawLevel(16)

    -- Drag (unlock mode): the column belongs to the target bar, so any
    -- mini-boss bar drags the target bar (and the column with it).
    c:SetHandler("OnMouseDown", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then AUI.Target:BeginDrag() end
    end)
    c:SetHandler("OnMouseUp", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then RB:EndDrag() end
    end)

    slot = { bar = bar, nameLabel = label, tag = nil, name = nil }
    self.slots[i] = slot

    -- Bring the new bar up to the current settings.
    bar:ApplyLayout(BAR_CFG, self.width, self.barHeight)
    bar:ApplyTextMode(RB.sv.text)
    AnchorName(slot, self.textOn)
    self:ApplySlotDrag(slot)
    return slot
end

local function SetSlotName(slot, name)
    if slot.name ~= name then
        slot.name = name
        slot.nameLabel:SetText(name)
    end
end

function MiniBoss:ApplySlotDrag(slot)
    local unlocked = self.unlocked
    local bar = slot.bar
    bar.control:SetMouseEnabled(unlocked and self.sv.enabled)
    bar.dragOverlay:SetHidden(not unlocked)
    bar.dragLabel:SetHidden(not unlocked)
end

-- Rebuild ----------------------------------------------------------------------
function MiniBoss:QueueRebuild()
    if self.pending then return end
    self.pending = true
    EM:RegisterForUpdate(REBUILD_NAME, 0, self.onRebuild)
end

function MiniBoss:Rebuild()
    if not self.ready then return end
    local byTag, maxByTag, list = self.byTag, self.maxByTag, self.list
    ZO_ClearTable(byTag)
    ZO_ClearTable(maxByTag)

    local n = 0
    if self.sv.enabled then
        -- Pass 1: the main boss = largest max health.
        local mainTag, mainMax = nil, -1
        for i = 1, MAX do
            local tag = BOSS_TAGS[i]
            if DoesUnitExist(tag) then
                local _, _, maxHp = GetUnitPower(tag, POWERTYPE_HEALTH)
                maxHp = maxHp or 0
                maxByTag[tag] = maxHp
                if maxHp > mainMax then mainTag, mainMax = tag, maxHp end
            end
        end
        -- Pass 2: every other living boss is a mini-boss, in tag order.
        for i = 1, MAX do
            local tag = BOSS_TAGS[i]
            if maxByTag[tag] and tag ~= mainTag and not IsUnitDead(tag) then
                n = n + 1
                list[n] = tag
            end
        end
    end

    for i = 1, n do
        local tag = list[i]
        local slot = self:GetSlot(i)
        local changed = slot.tag ~= tag
        slot.tag = tag
        slot.bar.unitTag = tag
        byTag[tag] = slot
        SetSlotName(slot, zo_strformat(SI_UNIT_NAME, GetUnitName(tag)))
        slot.bar:Refresh(changed) -- a new unit snaps, the same unit animates
    end

    -- Placeholder while unlocked / previewed, so the stack can be placed.
    if n == 0 and self.sv.enabled and (self.unlocked or self.preview) then
        n = 1
        local slot = self:GetSlot(1)
        slot.tag = nil
        SetSlotName(slot, PLACEHOLDER)
        slot.bar:SetValue(1, 1, true)
    end

    self:ShowCount(n)
end

function MiniBoss:ShowCount(n)
    local slots, old = self.slots, self.count
    for i = n + 1, old do
        local slot = slots[i]
        slot.tag = nil
        slot.bar.control:SetHidden(true)
    end
    for i = old + 1, n do
        slots[i].bar.control:SetHidden(false)
    end
    self.count = n
    if n ~= old and n > 0 then self:UpdateSize() end

    local show = n > 0
    if show ~= self.shown then
        self.shown = show
        self.frame:SetHidden(not show)
    end
end

-- Layout / text / position --------------------------------------------------------
function MiniBoss:ApplyLayout()
    if not self.ready then return end
    local RB = AUI.ResourceBars
    local bh = RB:GetBarHeight()
    if bh < RB.BAR_HEIGHT_TEXT then bh = RB.BAR_HEIGHT_TEXT end -- room for the name
    self.baseWidth, self.barHeight = RB.sv.width, bh
    self.width = 0 -- forces the bars to be laid out by ApplyPosition
    self:ApplyText()
    self:ApplyPosition() -- picks side + width, lays the bars out
end

function MiniBoss:SetWidth(w)
    if w == self.width then return end
    self.width = w
    local bh = self.barHeight
    for i = 1, #self.slots do
        self.slots[i].bar:ApplyLayout(BAR_CFG, w, bh)
    end
    self:UpdateSize()
end

-- The top-level is exactly the shown column, so anchoring its centre line to
-- the target bar centres the column (one bar = level with the target bar).
function MiniBoss:UpdateSize()
    local n = self.count
    if n < 1 then n = 1 end
    self.topLevel:SetDimensions(self.width, n * self.barHeight + (n - 1) * ROW_GAP)
end

function MiniBoss:ApplyText()
    if not self.ready then return end
    local mode = AUI.ResourceBars.sv.text
    local textOn = mode ~= "none"
    self.textOn = textOn
    for i = 1, #self.slots do
        local slot = self.slots[i]
        slot.bar:ApplyTextMode(mode)
        AnchorName(slot, textOn)
    end
end

-- Beside the target bar, clear of both bars' caps and spikes: right side,
-- narrowed to fit if needed, left side only when even MIN_WIDTH won't fit.
-- Called on load and when the target bar or the bar size changes.
function MiniBoss:ApplyPosition()
    if not self.ready then return end
    local RB, Target = AUI.ResourceBars, AUI.Target
    local anchor = Target.bar.control
    local ownOverhang = RB.Overhang(self.barHeight)
    local gap = RB.Overhang(RB:GetBarHeight()) + ownOverhang + SIDE_GAP
    local w, side = self.baseWidth, RIGHT
    local right = anchor:GetRight()
    if right then
        -- Room between our left spike and the screen edge, our right spike included.
        local room = GuiRoot:GetWidth() - SCREEN_MARGIN - ownOverhang - right - gap
        if room < w then
            if room >= MIN_WIDTH then w = zo_round(room) else side = LEFT end
        end
    end
    self.side = side
    self:SetWidth(w)
    local tl = self.topLevel
    tl:ClearAnchors()
    if side == RIGHT then
        tl:SetAnchor(LEFT, anchor, RIGHT, gap, 0)
    else
        tl:SetAnchor(RIGHT, anchor, LEFT, -gap, 0)
    end
end

-- Enable / events ------------------------------------------------------------------
function MiniBoss:ApplyEnabled()
    local on = self.sv.enabled
    if on ~= self.registered then
        self.registered = on
        if on then
            EM:RegisterForEvent(NAME, EVENT_BOSSES_CHANGED, self.queueRebuild)
            EM:RegisterForEvent(NAME .. "Activated", EVENT_PLAYER_ACTIVATED, self.onActivated)

            EM:RegisterForEvent(NAME .. "Power", EVENT_POWER_UPDATE, self.onPower)
            EM:AddFilterForEvent(NAME .. "Power", EVENT_POWER_UPDATE,
                REGISTER_FILTER_UNIT_TAG_PREFIX, "boss",
                REGISTER_FILTER_POWER_TYPE, POWERTYPE_HEALTH)

            EM:RegisterForEvent(NAME .. "Death", EVENT_UNIT_DEATH_STATE_CHANGED, self.queueRebuild)
            EM:AddFilterForEvent(NAME .. "Death", EVENT_UNIT_DEATH_STATE_CHANGED,
                REGISTER_FILTER_UNIT_TAG_PREFIX, "boss")
        else
            EM:UnregisterForEvent(NAME, EVENT_BOSSES_CHANGED)
            EM:UnregisterForEvent(NAME .. "Activated", EVENT_PLAYER_ACTIVATED)
            EM:UnregisterForEvent(NAME .. "Power", EVENT_POWER_UPDATE)
            EM:UnregisterForEvent(NAME .. "Death", EVENT_UNIT_DEATH_STATE_CHANGED)
            if self.pending then
                EM:UnregisterForUpdate(REBUILD_NAME)
                self.pending = false
            end
        end
    end
    for i = 1, #self.slots do self:ApplySlotDrag(self.slots[i]) end
    self:Rebuild()
end

function MiniBoss:SetEnabled(enabled)
    enabled = enabled and true or false
    if self.sv.enabled == enabled then return end
    self.sv.enabled = enabled
    self:ApplyEnabled()
end

-- Unlock / preview (driven by ResourceBars) --------------------------------------
function MiniBoss:SetUnlocked(unlocked)
    if not self.ready then return end
    self.unlocked = unlocked
    for i = 1, #self.slots do self:ApplySlotDrag(self.slots[i]) end
    self:Rebuild() -- a bar created here already picks up the unlocked state
end

-- Keep the bars visible on top of the settings menu, like the player bars.
function MiniBoss:SetPreview(enabled)
    if not self.ready or self.preview == enabled then return end
    self.preview = enabled
    local tl = self.topLevel
    if enabled then
        self.savedDrawTier = tl:GetDrawTier()
        tl:SetDrawTier(DT_HIGH)
        GAME_MENU_SCENE:AddFragment(self.fragment)
    else
        GAME_MENU_SCENE:RemoveFragment(self.fragment)
        tl:SetDrawTier(self.savedDrawTier or DT_LOW)
    end
    self:Rebuild()
end

-- Slash commands -------------------------------------------------------------------
function MiniBoss:HandleCommand(cmd, rest)
    if cmd ~= "miniboss" then return false end
    if rest == "on" or rest == "off" then
        self:SetEnabled(rest == "on")
        AUI:Print("mini-boss bars " .. rest)
    else
        AUI:Print("mini-boss bars: " .. (self.sv.enabled and "on" or "off") .. ". /aether miniboss <on|off>")
    end
    return true
end

AUI:RegisterModule("MiniBoss", MiniBoss)
