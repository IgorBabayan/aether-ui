-- AetherUI / Companion
-- Companion health bar. Replaces ESO's companion frame (top-left of the
-- screen) while enabled. Companion name on the left inside the bar, health
-- text on the right (bar text setting).
--
-- Default spot, as wide as the Health bar:
--   * columns : level with the Magicka bar (same centre Y), on the outer
--               (left) side of the column, clear of both bars' caps and
--               spikes. Narrowed to fit the screen edge if needed (down to
--               MIN_WIDTH); only below that does it move to the right side.
--   * pyramid : under the Magicka + Stamina row; buff icons move down under it
--   * default : above the Health bar (follows Health when it is dragged)
-- The spot is native anchoring to the player bars, so it follows them while
-- they are dragged; side / width are picked again only when the player bars
-- are dropped, resized or change layout, never per frame.
-- Drag and drop (unlock mode): the bar moves on its own and keeps its spot
-- until Reset position. A dragged bar no longer pushes the buff icons.
--
-- Performance:
--   * same Bar class as the player bars: one shared ticker that runs only
--     while something animates, cached widths / text
--   * events are filtered natively to the "companion" unit (health, shield,
--     unit created / destroyed); the health handler is a single call
--   * name is pushed to the label only when it changes
--   * no companion = frame hidden, nothing runs; disabled = no events at all
--   * the buff icons are re-anchored only when the bar appears / disappears
--     or moves, never per frame
--   * ESO's companion frame is switched off with its own hide-reason system
--     (no reparenting, no per-event hiding) and handed back when disabled

local AUI = AetherUI
local EM = EVENT_MANAGER

local DoesUnitExist = DoesUnitExist
local GetUnitName = GetUnitName
local zo_strformat = zo_strformat

local UNIT = "companion"
local NAME = "AetherUI_Companion"
local HIDE_REASON = "AetherUI"

local ROW_GAP = 12           -- space between the player bars and this bar
local SIDE_GAP = 8           -- columns: space between Magicka's spikes and ours
local SCREEN_MARGIN = 8
local MIN_WIDTH = 140        -- columns: narrowest bar before switching side
local TEXT_PAD = 6           -- name / value inset from the bar ends
local NAME_VALUE_GAP = 8
local DRAG_PAD_Y = 10
local NAME_FONT = "$(BOLD_FONT)|13|soft-shadow-thick"
local PLACEHOLDER = "Companion"

local H, M, S = POWERTYPE_HEALTH, POWERTYPE_MAGICKA, POWERTYPE_STAMINA
-- Layouts where the bar hangs under the stack: the bar its top-left corner
-- attaches to (same left edge and width as Health).
local BELOW = { pyramid = M }
-- Layouts where the bar sits beside the stack, level with this bar.
local BESIDE = { columns = M }
local BAR_CFG_ROW = { grow = "center" } -- default layout: Skyrim style
local BAR_CFG_COL = { grow = "left" }

local Companion = {
    ready = false,
    registered = false,
    hasCompanion = false,
    shown = false,
    unlocked = false,
    preview = false,
    placeholder = false,
    below = false,      -- sits under the player bars (pushes the buffs)
    buffAnchor = nil,   -- control last handed to the buff icons
}
AUI.Companion = Companion

function Companion:Initialize(sv)
    local s = sv.companion
    if type(s) ~= "table" then s = {}; sv.companion = s end
    if s.enabled == nil then s.enabled = true end
    if type(s.point) ~= "table" or not (tonumber(s.point.x) and tonumber(s.point.y)) then s.point = nil end
    self.sv = s

    local RB = AUI.ResourceBars
    local tl = AetherUI_Companion
    local frame = tl:GetNamedChild("Frame")
    self.topLevel, self.frame = tl, frame

    local bar = RB:CreateBar(frame, H, UNIT, NAME .. "Bar", RB.STYLE_COMPANION)
    self.bar = bar
    bar.control:SetAnchor(TOPLEFT, frame, TOPLEFT, 0, 0)

    -- Health text on the right end; the name takes the left.
    local value = bar.valueLabel
    value:ClearAnchors()
    value:SetAnchor(RIGHT, bar.track, RIGHT, -TEXT_PAD, 1)
    value:SetHorizontalAlignment(TEXT_ALIGN_RIGHT)

    local label = WINDOW_MANAGER:CreateControl(NAME .. "Name", bar.control, CT_LABEL)
    label:SetFont(NAME_FONT)
    label:SetColor(0.91, 0.86, 0.75, 1)
    label:SetHorizontalAlignment(TEXT_ALIGN_LEFT)
    label:SetVerticalAlignment(TEXT_ALIGN_CENTER)
    label:SetMaxLineCount(1)
    label:SetWrapMode(TEXT_WRAP_MODE_ELLIPSIS)
    label:SetDrawLevel(16)
    self.nameLabel, self.nameText = label, nil

    -- Drag (unlock mode): grab the bar, it moves on its own; saved on drop.
    self.savePoint = function(x, y)
        self.sv.point = { x = x, y = y }
        self:ApplyPosition()
    end
    bar.control:SetHandler("OnMouseDown", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then
            RB:BeginFreeDrag(tl, bar.dragPadX, DRAG_PAD_Y, self.savePoint)
        end
    end)
    bar.control:SetHandler("OnMouseUp", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then RB:EndDrag() end
    end)

    local fragment = ZO_HUDFadeSceneFragment:New(tl)
    self.fragment = fragment
    HUD_SCENE:AddFragment(fragment)
    HUD_UI_SCENE:AddFragment(fragment)

    self.onChanged = function()
        self:HideDefaultFrame() -- ESO builds its frame on the first summon
        self:OnCompanionChanged()
    end
    self.onPower = function(_, _, _, _, v, _, effectiveMax)
        if self.hasCompanion then bar:SetValue(v, effectiveMax) end
    end
    self.onShield = function(_, _, visual)
        if visual == ATTRIBUTE_VISUAL_POWER_SHIELDING and self.hasCompanion then self:RefreshShield() end
    end

    -- ESO creates its companion frame lazily; switch it off the moment it exists.
    if UNIT_FRAMES and UNIT_FRAMES.CreateFrame then
        local hook = SecurePostHook or ZO_PostHook
        hook(UNIT_FRAMES, "CreateFrame", function(_, unitTag)
            if unitTag == UNIT and self.sv.enabled then self:HideDefaultFrame() end
        end)
    end

    self.ready = true
    self:ApplyLayout()
    self:ApplyText()
    self:ApplyEnabled()
end

-- Layout / text / position ------------------------------------------------------
-- As wide as the Health bar of the active layout, tall enough for the name.
function Companion:ApplyLayout()
    if not self.ready then return end
    local RB = AUI.ResourceBars
    local health = RB.health
    local bh = RB:GetBarHeight()
    if bh < RB.BAR_HEIGHT_TEXT then bh = RB.BAR_HEIGHT_TEXT end
    self.baseWidth = health and health.width or RB.sv.width
    self.barHeight = bh
    self.cfg = RB.sv.layout == "default" and BAR_CFG_ROW or BAR_CFG_COL
    self.width = nil -- forces the bar to be laid out by ApplyPosition
    self:ApplyPosition()
end

-- Bar geometry, only when the width actually changes.
function Companion:SetWidth(w)
    if w == self.width then return end
    self.width = w
    self.bar:ApplyLayout(self.cfg, w, self.barHeight)
    self.topLevel:SetDimensions(w, self.barHeight)
end

-- Columns: beside Magicka, left side first. Returns side point, width.
function Companion:PickSide(anchor)
    local RB = AUI.ResourceBars
    local own = RB.Overhang(self.barHeight)
    local gap = RB.Overhang(RB:GetBarHeight()) + own + SIDE_GAP
    local w = self.baseWidth
    local left, right = anchor:GetLeft(), anchor:GetRight()
    if not (left and right) then return LEFT, w, gap end
    local room = left - gap - own - SCREEN_MARGIN
    if room >= w then return LEFT, w, gap end
    if room >= MIN_WIDTH then return LEFT, zo_round(room), gap end
    room = GuiRoot:GetWidth() - SCREEN_MARGIN - own - right - gap
    if room < w then w = zo_round(zo_max(room, MIN_WIDTH)) end
    return RIGHT, w, gap
end

function Companion:ApplyText()
    if not self.ready then return end
    local mode = AUI.ResourceBars.sv.text
    self.bar:ApplyTextMode(mode)
    local label, bar = self.nameLabel, self.bar
    label:ClearAnchors()
    label:SetAnchor(LEFT, bar.track, LEFT, TEXT_PAD, 1)
    if mode ~= "none" then
        label:SetAnchor(RIGHT, bar.valueLabel, LEFT, -NAME_VALUE_GAP, 0)
    else
        label:SetAnchor(RIGHT, bar.track, RIGHT, -TEXT_PAD, 1)
    end
end

-- Not a hot path: load, layout / size change, drag drop, reset.
function Companion:ApplyPosition()
    if not self.ready then return end
    local tl = self.topLevel
    tl:ClearAnchors()
    local p = self.sv.point
    local below = false
    local RB = AUI.ResourceBars
    local layout = RB.sv.layout
    if p then
        self:SetWidth(self.baseWidth)
        tl:SetAnchor(CENTER, GuiRoot, TOPLEFT, p.x, p.y)
    elseif BESIDE[layout] then
        local anchor = RB.bars[BESIDE[layout]].control
        local side, w, gap = self:PickSide(anchor)
        self:SetWidth(w)
        -- RIGHT <-> LEFT anchoring lines up the vertical centres.
        if side == LEFT then
            tl:SetAnchor(RIGHT, anchor, LEFT, -gap, 0)
        else
            tl:SetAnchor(LEFT, anchor, RIGHT, gap, 0)
        end
    else
        self:SetWidth(self.baseWidth)
        local under = BELOW[layout]
        if under then
            tl:SetAnchor(TOPLEFT, RB.bars[under].control, BOTTOMLEFT, 0, ROW_GAP)
            below = true
        else
            tl:SetAnchor(BOTTOM, RB.health.control, TOP, 0, -ROW_GAP)
        end
    end
    self.below = below
    self:UpdateBuffAnchor()
end

-- Control the player buff icons attach to instead of their layout bar, or nil.
function Companion:GetBuffAnchor()
    if self.ready and self.shown and self.below then return self.bar.control end
    return nil
end

-- Re-anchor the buff icons only when the answer above actually changes.
function Companion:UpdateBuffAnchor()
    local anchor = self:GetBuffAnchor()
    if anchor ~= self.buffAnchor then
        self.buffAnchor = anchor
        if AUI.Effects then AUI.Effects:ApplyPlacement() end
    end
end

-- Player bars dropped after a drag: an unmoved bar re-picks its side / width.
function Companion:FollowPlayer()
    if self.ready and not self.sv.point then self:ApplyPosition() end
end

function Companion:ResetPosition()
    if not self.ready then return end
    self.sv.point = nil
    self:ApplyPosition()
end

-- ESO's companion frame -------------------------------------------------------------
function Companion:SetDefaultFrameHidden(hidden)
    if UNIT_FRAMES and UNIT_FRAMES.SetFrameHiddenForReason then
        UNIT_FRAMES:SetFrameHiddenForReason(UNIT, HIDE_REASON, hidden)
    end
end

function Companion:HideDefaultFrame() self:SetDefaultFrameHidden(true) end

-- Enable / events ------------------------------------------------------------------
function Companion:ApplyEnabled()
    local on = self.sv.enabled
    if on ~= self.registered then
        self.registered = on
        if on then
            EM:RegisterForEvent(NAME, EVENT_ACTIVE_COMPANION_STATE_CHANGED, self.onChanged)
            EM:RegisterForEvent(NAME .. "Activated", EVENT_PLAYER_ACTIVATED, self.onChanged)
            for i, ev in ipairs({ EVENT_UNIT_CREATED, EVENT_UNIT_DESTROYED }) do
                local ns = NAME .. "Unit" .. i
                EM:RegisterForEvent(ns, ev, self.onChanged)
                EM:AddFilterForEvent(ns, ev, REGISTER_FILTER_UNIT_TAG, UNIT)
            end

            EM:RegisterForEvent(NAME .. "Power", EVENT_POWER_UPDATE, self.onPower)
            EM:AddFilterForEvent(NAME .. "Power", EVENT_POWER_UPDATE,
                REGISTER_FILTER_UNIT_TAG, UNIT,
                REGISTER_FILTER_POWER_TYPE, H)

            for i, ev in ipairs({ EVENT_UNIT_ATTRIBUTE_VISUAL_ADDED, EVENT_UNIT_ATTRIBUTE_VISUAL_UPDATED, EVENT_UNIT_ATTRIBUTE_VISUAL_REMOVED }) do
                local ns = NAME .. "Shield" .. i
                EM:RegisterForEvent(ns, ev, self.onShield)
                EM:AddFilterForEvent(ns, ev, REGISTER_FILTER_UNIT_TAG, UNIT)
            end
            self:HideDefaultFrame()
        else
            EM:UnregisterForEvent(NAME, EVENT_ACTIVE_COMPANION_STATE_CHANGED)
            EM:UnregisterForEvent(NAME .. "Activated", EVENT_PLAYER_ACTIVATED)
            for i, ev in ipairs({ EVENT_UNIT_CREATED, EVENT_UNIT_DESTROYED }) do
                EM:UnregisterForEvent(NAME .. "Unit" .. i, ev)
            end
            EM:UnregisterForEvent(NAME .. "Power", EVENT_POWER_UPDATE)
            for i, ev in ipairs({ EVENT_UNIT_ATTRIBUTE_VISUAL_ADDED, EVENT_UNIT_ATTRIBUTE_VISUAL_UPDATED, EVENT_UNIT_ATTRIBUTE_VISUAL_REMOVED }) do
                EM:UnregisterForEvent(NAME .. "Shield" .. i, ev)
            end
            self:SetDefaultFrameHidden(false)
        end
    end
    self.bar.control:SetMouseEnabled(on and self.unlocked)
    self:OnCompanionChanged()
end

function Companion:SetEnabled(enabled)
    enabled = enabled and true or false
    if self.sv.enabled == enabled then return end
    self.sv.enabled = enabled
    self:ApplyEnabled()
end

-- Companion state ------------------------------------------------------------------
function Companion:SetName(text)
    if self.nameText ~= text then
        self.nameText = text
        self.nameLabel:SetText(text)
    end
end

function Companion:RefreshShield()
    local v = GetUnitAttributeVisualizerEffectInfo(UNIT, ATTRIBUTE_VISUAL_POWER_SHIELDING,
        STAT_MITIGATION, ATTRIBUTE_HEALTH, H)
    self.bar:SetShield(v or 0)
end

function Companion:OnCompanionChanged()
    local has = self.sv.enabled and DoesUnitExist(UNIT) or false
    self.hasCompanion = has
    if has then
        self.placeholder = false
        self:SetName(zo_strformat(SI_UNIT_NAME, GetUnitName(UNIT)))
        self.bar:Refresh(true)
        self:RefreshShield()
    end
    self:UpdateVisibility()
end

-- Shown with a companion, or as a placeholder while unlocked / previewed.
function Companion:UpdateVisibility()
    local show = self.sv.enabled and (self.hasCompanion or self.unlocked or self.preview) or false
    if show and not self.hasCompanion and not self.placeholder then
        self.placeholder = true
        self:SetName(PLACEHOLDER)
        self.bar:SetShield(0)
        self.bar:SetValue(1, 1, true)
    end
    if show ~= self.shown then
        self.shown = show
        self.frame:SetHidden(not show)
        self:UpdateBuffAnchor()
    end
end

-- Unlock / preview (driven by ResourceBars) --------------------------------------
function Companion:SetUnlocked(unlocked)
    if not self.ready then return end
    self.unlocked = unlocked
    local bar = self.bar
    bar.control:SetMouseEnabled(unlocked and self.sv.enabled)
    bar.dragOverlay:SetHidden(not unlocked)
    bar.dragLabel:SetHidden(not unlocked)
    self:UpdateVisibility()
end

-- Keep the bar visible on top of the settings menu, like the player bars.
function Companion:SetPreview(enabled)
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
    self:UpdateVisibility()
end

-- Slash commands -------------------------------------------------------------------
function Companion:HandleCommand(cmd, rest)
    if cmd ~= "companion" then return false end
    if rest == "on" or rest == "off" then
        self:SetEnabled(rest == "on")
        AUI:Print("companion bar " .. rest)
    else
        AUI:Print("companion bar: " .. (self.sv.enabled and "on" or "off") .. ". /aether companion <on|off>")
    end
    return true
end

AUI:RegisterModule("Companion", Companion)
