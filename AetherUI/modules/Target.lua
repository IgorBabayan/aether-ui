-- AetherUI / Target
-- Target health bar in LUI's target frame spot, with the target's buffs and
-- debuffs placed by the same rules as the player's Columns layout:
--   * name (left) and level (right) in a row just above the bar
--   * debuffs above the name row, left to right, next row above
--   * buffs under the bar, left to right, next row below
--   * permanent effects first, timed ones after with a timer under the icon
--
-- Default spot: the bar's top-left corner sits where LUI puts its target
-- frame, (192, 205) from the screen centre on a 1080p canvas, scaled like the
-- player bars. So in Columns the target bar lines up with the Health bar.
-- Width / height / text follow the player bar settings.
--
-- Performance:
--   * same Bar class as the player bars: one shared ticker that runs only
--     while something animates, cached widths / text
--   * events are filtered natively to "reticleover" (health, shield, effects)
--   * a target change is one refresh: name/level/color are cached and only
--     pushed to the label when they differ; effect icons are rebuilt at once
--     (no stale icons from the previous target), later changes are coalesced
--   * no target = frame hidden, no polls; disabled = no events at all
--   * ESO's own target frame is parked under a hidden control (no per-event
--     hiding) and handed back when the bar is turned off

local AUI = AetherUI
local EM = EVENT_MANAGER

local DoesUnitExist = DoesUnitExist
local GetUnitName = GetUnitName
local GetUnitLevel = GetUnitLevel
local GetUnitChampionPoints = GetUnitChampionPoints
local GetUnitReactionColorType = GetUnitReactionColorType
local IsUnitDead = IsUnitDead
local zo_strformat = zo_strformat

local UNIT = "reticleover"
local NAME = "AetherUI_Target"

local LUI_TARGET_X, LUI_TARGET_Y = 192, 205 -- LUI target frame top-left, 1080p
local NAME_H = 18            -- name row above the bar
local NAME_GAP = 3           -- name row -> bar
local DRAG_PAD_Y = NAME_H + NAME_GAP + 4
local BAR_CFG = { grow = "left" }

-- Name colors by reaction (Skyrim-muted). Built defensively: a constant that
-- does not exist on this client is simply skipped.
local REACTION_COLORS = {}
local function Reaction(key, r, g, b)
    if key ~= nil then REACTION_COLORS[key] = { r, g, b } end
end
Reaction(UNIT_REACTION_COLOR_HOSTILE, 0.88, 0.36, 0.30)
Reaction(UNIT_REACTION_COLOR_NEUTRAL, 0.92, 0.82, 0.42)
Reaction(UNIT_REACTION_COLOR_FRIENDLY, 0.60, 0.82, 0.48)
Reaction(UNIT_REACTION_COLOR_NPC_ALLY, 0.60, 0.82, 0.48)
Reaction(UNIT_REACTION_COLOR_PLAYER_ALLY, 0.50, 0.72, 0.96)
Reaction(UNIT_REACTION_COLOR_COMPANION, 0.70, 0.62, 0.92)
Reaction(UNIT_REACTION_COLOR_DEAD, 0.55, 0.52, 0.48)
local COLOR_DEFAULT = { 0.91, 0.86, 0.75 }
local COLOR_DEAD = REACTION_COLORS[UNIT_REACTION_COLOR_DEAD or false] or { 0.55, 0.52, 0.48 }

local Effects = AUI.Effects
local BAR_GAP = Effects.BAR_GAP

-- Same rules as the player in the Columns layout, relative to the target bar.
local BUFF_PLACEMENT = { flow = "rightDown", relPoint = BOTTOMLEFT, ox = 0, oy = BAR_GAP }
local DEBUFF_PLACEMENT = { flow = "rightUp", relPoint = TOPLEFT, ox = 0, oy = -(NAME_H + NAME_GAP + BAR_GAP) }

local TargetBuffs = Effects.NewList({
    key = "targetBuffs", cmd = "tbuffs", label = "target buffs",
    prefix = "AetherUI_TargetBuff", bevel = "buffs",
})
local TargetDebuffs = Effects.NewList({
    key = "targetDebuffs", cmd = "tdebuffs", label = "target debuffs",
    prefix = "AetherUI_TargetDebuff", bevel = "debuffs",
})
AUI.TargetBuffs, AUI.TargetDebuffs = TargetBuffs, TargetDebuffs

local Target = {
    ready = false,
    registered = false,
    hasTarget = false,
    shown = false,
    unlocked = false,
    preview = false,
    placeholder = false,
}
AUI.Target = Target

function Target:Initialize(sv)
    local s = sv.target
    if type(s) ~= "table" then s = {}; sv.target = s end
    if s.enabled == nil then s.enabled = true end
    self.sv = s

    local RB = AUI.ResourceBars
    local tl = AetherUI_Target
    local frame = tl:GetNamedChild("Frame")
    self.topLevel, self.frame = tl, frame

    local bar = RB:CreateBar(frame, POWERTYPE_HEALTH, UNIT, "AetherUI_TargetBar")
    self.bar = bar
    bar.control:SetAnchor(TOPLEFT, frame, TOPLEFT, 0, 0)
    bar.dragLabel:SetText("Target")

    -- Name + level row above the bar.
    local nameLabel, levelLabel = frame:GetNamedChild("Name"), frame:GetNamedChild("Level")
    levelLabel:SetAnchor(BOTTOMRIGHT, bar.control, TOPRIGHT, 0, -NAME_GAP)
    nameLabel:SetAnchor(BOTTOMLEFT, bar.control, TOPLEFT, 0, -NAME_GAP)
    nameLabel:SetAnchor(BOTTOMRIGHT, levelLabel, BOTTOMLEFT, -8, 0)
    self.nameLabel, self.levelLabel = nameLabel, levelLabel
    self.nameText, self.levelText, self.nameColor = nil, nil, nil

    -- Drag (unlock mode): grab the bar, the frame moves; saved on its own.
    local function save(x, y) self.sv.point = { x = x, y = y } end
    bar.control:SetHandler("OnMouseDown", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then RB:BeginFreeDrag(tl, bar.dragPadX, DRAG_PAD_Y, save) end
    end)
    bar.control:SetHandler("OnMouseUp", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then RB:EndDrag() end
    end)

    -- Effects: lists live inside the frame, so they hide with it.
    local tracker = Effects.NewTracker(UNIT, NAME .. "Effects", TargetBuffs, TargetDebuffs)
    tracker.suspended = true -- woken by ApplyEnabled
    self.tracker = tracker
    TargetBuffs:Init(sv, frame, tracker)
    TargetDebuffs:Init(sv, frame, tracker)
    TargetBuffs:Place(BUFF_PLACEMENT, bar.control)
    TargetDebuffs:Place(DEBUFF_PLACEMENT, bar.control)

    local fragment = ZO_HUDFadeSceneFragment:New(tl)
    self.fragment = fragment
    HUD_SCENE:AddFragment(fragment)
    HUD_UI_SCENE:AddFragment(fragment)

    self.onTargetChanged = function() self:OnTargetChanged() end
    self.onActivated = function()
        self:HideDefaultFrame() -- in case ESO built its frame after our load
        self:OnTargetChanged()
    end
    self.onPower = function(_, _, _, _, value, _, effectiveMax)
        if self.hasTarget then bar:SetValue(value, effectiveMax) end
    end
    self.onShield = function(_, _, visual)
        if visual == ATTRIBUTE_VISUAL_POWER_SHIELDING and self.hasTarget then self:RefreshShield() end
    end
    self.onDeath = function()
        if self.hasTarget then self:UpdateInfo() end
    end

    self.ready = true
    self:ApplyLayout()
    self:ApplyText()
    self:ApplyPosition()
    self:ApplyEnabled()
end

-- Layout / position ------------------------------------------------------------
function Target:ApplyLayout()
    if not self.ready then return end
    local RB = AUI.ResourceBars
    local w, bh = RB.sv.width, RB:GetBarHeight()
    self.bar:ApplyLayout(BAR_CFG, w, bh)
    self.topLevel:SetDimensions(w, bh)
end

function Target:ApplyText()
    if not self.ready then return end
    self.bar:ApplyTextMode(AUI.ResourceBars.sv.text)
end

function Target:ApplyPosition()
    local tl = self.topLevel
    tl:ClearAnchors()
    local p = self.sv.point
    if p then
        tl:SetAnchor(CENTER, GuiRoot, TOPLEFT, p.x, p.y)
    else
        local x, y = AUI.ResourceBars.LuiOffset(LUI_TARGET_X, LUI_TARGET_Y)
        tl:SetAnchor(TOPLEFT, GuiRoot, CENTER, x, y)
    end
end

function Target:ResetPosition()
    if not self.ready then return end
    self.sv.point = nil
    self:ApplyPosition()
end

-- ESO's default target frame ----------------------------------------------------
function Target:HideDefaultFrame()
    local f = ZO_TargetUnitFramereticleover
    if not f or self.defaultParent then return end
    if not self.sink then
        self.sink = WINDOW_MANAGER:CreateControl("AetherUI_DefaultTargetSink", GuiRoot, CT_CONTROL)
        self.sink:SetHidden(true)
    end
    self.defaultParent = f:GetParent()
    f:SetParent(self.sink)
end

function Target:RestoreDefaultFrame()
    local f = ZO_TargetUnitFramereticleover
    if f and self.defaultParent then
        f:SetParent(self.defaultParent)
        self.defaultParent = nil
    end
end

-- Enable / events ------------------------------------------------------------------
function Target:ApplyEnabled()
    local on = self.sv.enabled
    if on ~= self.registered then
        self.registered = on
        if on then
            EM:RegisterForEvent(NAME, EVENT_RETICLE_TARGET_CHANGED, self.onTargetChanged)
            EM:RegisterForEvent(NAME .. "Activated", EVENT_PLAYER_ACTIVATED, self.onActivated)

            EM:RegisterForEvent(NAME .. "Power", EVENT_POWER_UPDATE, self.onPower)
            EM:AddFilterForEvent(NAME .. "Power", EVENT_POWER_UPDATE,
                REGISTER_FILTER_UNIT_TAG, UNIT,
                REGISTER_FILTER_POWER_TYPE, POWERTYPE_HEALTH)

            for i, ev in ipairs({ EVENT_UNIT_ATTRIBUTE_VISUAL_ADDED, EVENT_UNIT_ATTRIBUTE_VISUAL_UPDATED, EVENT_UNIT_ATTRIBUTE_VISUAL_REMOVED }) do
                local ns = NAME .. "Shield" .. i
                EM:RegisterForEvent(ns, ev, self.onShield)
                EM:AddFilterForEvent(ns, ev, REGISTER_FILTER_UNIT_TAG, UNIT)
            end

            EM:RegisterForEvent(NAME .. "Death", EVENT_UNIT_DEATH_STATE_CHANGED, self.onDeath)
            EM:AddFilterForEvent(NAME .. "Death", EVENT_UNIT_DEATH_STATE_CHANGED, REGISTER_FILTER_UNIT_TAG, UNIT)

            self:HideDefaultFrame()
        else
            EM:UnregisterForEvent(NAME, EVENT_RETICLE_TARGET_CHANGED)
            EM:UnregisterForEvent(NAME .. "Activated", EVENT_PLAYER_ACTIVATED)
            EM:UnregisterForEvent(NAME .. "Power", EVENT_POWER_UPDATE)
            for i, ev in ipairs({ EVENT_UNIT_ATTRIBUTE_VISUAL_ADDED, EVENT_UNIT_ATTRIBUTE_VISUAL_UPDATED, EVENT_UNIT_ATTRIBUTE_VISUAL_REMOVED }) do
                EM:UnregisterForEvent(NAME .. "Shield" .. i, ev)
            end
            EM:UnregisterForEvent(NAME .. "Death", EVENT_UNIT_DEATH_STATE_CHANGED)
            self:RestoreDefaultFrame()
        end
    end
    self.bar.control:SetMouseEnabled(on and self.unlocked)
    self.tracker:SetSuspended(not on)
    self:OnTargetChanged()
end

function Target:SetEnabled(enabled)
    enabled = enabled and true or false
    if self.sv.enabled == enabled then return end
    self.sv.enabled = enabled
    self:ApplyEnabled()
end

-- Target state -------------------------------------------------------------------
local function SetLabelText(self, field, label, text)
    if self[field] ~= text then
        self[field] = text
        label:SetText(text)
    end
end

function Target:SetNameColor(c)
    if self.nameColor ~= c then
        self.nameColor = c
        self.nameLabel:SetColor(c[1], c[2], c[3], 1)
    end
end

function Target:UpdateInfo()
    SetLabelText(self, "nameText", self.nameLabel, zo_strformat(SI_UNIT_NAME, GetUnitName(UNIT)))
    local cp = GetUnitChampionPoints(UNIT) or 0
    local level = GetUnitLevel(UNIT) or 0
    SetLabelText(self, "levelText", self.levelLabel,
        cp > 0 and ("CP " .. cp) or (level > 0 and tostring(level) or ""))
    if IsUnitDead(UNIT) then
        self:SetNameColor(COLOR_DEAD)
    else
        self:SetNameColor(REACTION_COLORS[GetUnitReactionColorType(UNIT)] or COLOR_DEFAULT)
    end
end

function Target:RefreshShield()
    local value = GetUnitAttributeVisualizerEffectInfo(UNIT, ATTRIBUTE_VISUAL_POWER_SHIELDING,
        STAT_MITIGATION, ATTRIBUTE_HEALTH, POWERTYPE_HEALTH)
    self.bar:SetShield(value or 0)
end

function Target:OnTargetChanged()
    local has = self.sv.enabled and DoesUnitExist(UNIT) or false
    self.hasTarget = has
    if has then
        self.placeholder = false
        self:UpdateInfo()
        self.bar:Refresh(true)
        self:RefreshShield()
    end
    -- No target: the unit has no effects, so this clears the icons.
    if self.sv.enabled then self.tracker:RebuildNow() end
    self:UpdateVisibility()
end

-- Shown with a target, or as a placeholder while unlocked / previewed.
function Target:UpdateVisibility()
    local show = self.sv.enabled and (self.hasTarget or self.unlocked or self.preview)
    if show and not self.hasTarget and not self.placeholder then
        self.placeholder = true
        SetLabelText(self, "nameText", self.nameLabel, "Target")
        SetLabelText(self, "levelText", self.levelLabel, "")
        self:SetNameColor(COLOR_DEFAULT)
        self.bar:SetShield(0)
        self.bar:SetValue(1, 1, true)
    end
    if show ~= self.shown then
        self.shown = show
        self.frame:SetHidden(not show)
    end
end

-- Unlock / preview (driven by ResourceBars) --------------------------------------
function Target:SetUnlocked(unlocked)
    if not self.ready then return end
    self.unlocked = unlocked
    local bar = self.bar
    bar.control:SetMouseEnabled(unlocked and self.sv.enabled)
    bar.dragOverlay:SetHidden(not unlocked)
    bar.dragLabel:SetHidden(not unlocked)
    self:UpdateVisibility()
end

-- Keep the target bar visible on top of the settings menu, like the player bars.
function Target:SetPreview(enabled)
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
function Target:HandleCommand(cmd, rest)
    if cmd == "target" then
        if rest == "on" or rest == "off" then
            self:SetEnabled(rest == "on")
            AUI:Print("target bar " .. rest)
        else
            AUI:Print("target bar: " .. (self.sv.enabled and "on" or "off") .. ". /aether target <on|off>")
        end
        return true
    end
    return TargetBuffs:HandleCommand(cmd, rest) or TargetDebuffs:HandleCommand(cmd, rest)
end

AUI:RegisterModule("Target", Target)
