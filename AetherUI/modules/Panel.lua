-- AetherUI / Panel
-- Summon panel, like the Bandits UI side panel: press "." (show cursor) and a
-- column of buttons appears on the left edge of the screen.
--   * assistants first, then a divider line, then companions
--   * one button per owned collectible, its own icon; hover for the name
--   * click = summon, click again = dismiss; the ones out now have a bronze
--     frame
--   * which buttons are on the panel is chosen in the settings (all owned by
--     default; new ones show up on their own)
--   * a tall list wraps into a second column instead of running off screen
-- It goes away with the cursor and never shows over menus.
--
-- Performance:
--   * shown by ESO's own "hudui" scene (the "." cursor mode): no polling, no
--     reticle events, nothing runs while the panel is hidden
--   * buttons are pooled; the layout is rebuilt only when the button list
--     changed (setting, new unlock), and then on the next show
--   * active state is read once on show; while shown, one collectible event
--     (one table lookup) keeps it current; unregistered again on hide
--   * disabled = no fragment, no events

local AUI = AetherUI
local EM = EVENT_MANAGER
local WM = WINDOW_MANAGER

local GetCollectibleIcon = GetCollectibleIcon
local IsCollectibleActive = IsCollectibleActive

local NAME = "AetherUI_Panel"
local SIZE = 32          -- button
local GAP = 4            -- between buttons
local PAD = 6            -- inside the frame
local DIV_H = 9          -- divider slot height (line in the middle)
local EDGE_X = 10        -- from the left screen edge
local MAX_HEIGHT = 0.7   -- of the screen; taller lists wrap into another column

local BRONZE = { 0.78, 0.64, 0.39 }
local ICON_NORMAL, ICON_HOVER = 0.86, 1

local Panel = {
    ready = false,
    shown = false,
    registered = false,
    dirty = true,     -- button list changed: lay out again on next show
    count = 0,        -- buttons in use
    divCount = 0,     -- dividers in use
}
AUI.Panel = Panel

-- Buttons ----------------------------------------------------------------------------
local function ShowTooltip(control)
    local id = control.collectibleId
    if not id then return end
    local Keybinds = AUI.Keybinds
    local hint = IsCollectibleActive(id) and "Out now. Click to dismiss." or "Click to summon."
    ZO_Tooltips_ShowTextTooltip(control, RIGHT, Keybinds.CollectibleName(id) .. "\n|cA8946A" .. hint .. "|r")
end

local function OnEnter(control)
    control.icon:SetColor(ICON_HOVER, ICON_HOVER, ICON_HOVER, 1)
    control.hover:SetHidden(false)
    ShowTooltip(control)
end

local function OnExit(control)
    control.icon:SetColor(ICON_NORMAL, ICON_NORMAL, ICON_NORMAL, 1)
    control.hover:SetHidden(true)
    ZO_Tooltips_HideTextTooltip()
end

local function OnClick(control, button, upInside)
    if button ~= MOUSE_BUTTON_INDEX_LEFT or not upInside then return end
    local id = control.collectibleId
    if not id then return end
    PlaySound(SOUNDS.DEFAULT_CLICK)
    AUI.Keybinds.Summon(id) -- toggles: summons, or dismisses if already out
end

function Panel:GetButton(i)
    local b = self.buttons[i]
    if b then return b end

    local name = NAME .. "Button" .. i
    b = WM:CreateControl(name, self.frame, CT_CONTROL)
    b:SetDimensions(SIZE, SIZE)
    b:SetMouseEnabled(true)

    -- Active: bronze frame around the slot.
    local active = WM:CreateControl(name .. "Active", b, CT_TEXTURE)
    active:SetAnchor(TOPLEFT, b, TOPLEFT, -2, -2)
    active:SetAnchor(BOTTOMRIGHT, b, BOTTOMRIGHT, 2, 2)
    active:SetColor(BRONZE[1], BRONZE[2], BRONZE[3], 0.95)
    active:SetDrawLevel(1)
    active:SetHidden(true)

    local slotBg = WM:CreateControl(name .. "Bg", b, CT_TEXTURE)
    slotBg:SetAnchorFill(b)
    slotBg:SetColor(0.02, 0.016, 0.012, 1)
    slotBg:SetDrawLevel(2)

    local icon = WM:CreateControl(name .. "Icon", b, CT_TEXTURE)
    icon:SetAnchor(TOPLEFT, b, TOPLEFT, 1, 1)
    icon:SetAnchor(BOTTOMRIGHT, b, BOTTOMRIGHT, -1, -1)
    icon:SetColor(ICON_NORMAL, ICON_NORMAL, ICON_NORMAL, 1)
    icon:SetDrawLevel(3)

    local hover = WM:CreateControl(name .. "Hover", b, CT_TEXTURE)
    hover:SetAnchorFill(icon)
    hover:SetColor(1, 0.95, 0.8, 0.14)
    hover:SetDrawLevel(4)
    hover:SetHidden(true)

    b.icon, b.active, b.hover = icon, active, hover
    b.isActive = false
    b:SetHandler("OnMouseEnter", OnEnter)
    b:SetHandler("OnMouseExit", OnExit)
    b:SetHandler("OnMouseUp", OnClick)

    self.buttons[i] = b
    return b
end

function Panel:GetDivider(i)
    local d = self.dividers[i]
    if d then return d end
    d = WM:CreateControl(NAME .. "Divider" .. i, self.frame, CT_TEXTURE)
    d:SetDimensions(SIZE - 6, 1)
    d:SetColor(BRONZE[1], BRONZE[2], BRONZE[3], 0.7)
    d:SetDrawLevel(2)
    self.dividers[i] = d
    return d
end

function Panel:SetActive(b, active)
    active = active and true or false
    if b.isActive ~= active then
        b.isActive = active
        b.active:SetHidden(not active)
    end
end

function Panel:RefreshActive()
    for i = 1, self.count do
        local b = self.buttons[i]
        self:SetActive(b, IsCollectibleActive(b.collectibleId))
    end
end

-- Layout -------------------------------------------------------------------------------
-- Owned and not switched off in the settings, assistants then companions.
-- Column flow: when the next item would pass the max height, a new column
-- starts to the right. A divider that would open a new column is dropped
-- (the column break already separates the groups).
function Panel:Build()
    self.dirty = false
    local byId = self.byId
    ZO_ClearTable(byId)

    local Keybinds = AUI.Keybinds
    local hidden = self.sv.hidden
    local maxH = zo_max(SIZE, zo_floor(GuiRoot:GetHeight() * MAX_HEIGHT))
    local x, y, bottom = 0, 0, 0
    local nb, nd = 0, 0
    local frame = self.frame

    local function NextColumn()
        x, y = x + SIZE + GAP, 0
    end

    for _, key in ipairs(Keybinds.SUMMON_ORDER) do
        local ids = Keybinds:GetUnlocked(key)
        local groupStarted = false
        for i = 1, #ids do
            local id = ids[i]
            if not hidden[id] then
                if not groupStarted and nb > 0 then
                    if y + DIV_H > maxH then
                        NextColumn()
                    elseif y > 0 then
                        nd = nd + 1
                        local d = self:GetDivider(nd)
                        d:ClearAnchors()
                        d:SetAnchor(TOPLEFT, frame, TOPLEFT, PAD + x + 3, PAD + y + zo_floor((DIV_H - GAP) / 2))
                        d:SetHidden(false)
                        y = y + DIV_H
                    end
                end
                groupStarted = true

                if y > 0 and y + SIZE > maxH then NextColumn() end
                nb = nb + 1
                local b = self:GetButton(nb)
                b.collectibleId = id
                byId[id] = b
                b.icon:SetTexture(GetCollectibleIcon(id))
                b:ClearAnchors()
                b:SetAnchor(TOPLEFT, frame, TOPLEFT, PAD + x, PAD + y)
                b:SetHidden(false)
                y = y + SIZE + GAP
                if y > bottom then bottom = y end
            end
        end
    end

    for i = nb + 1, self.count do
        local b = self.buttons[i]
        b.collectibleId = nil
        b:SetHidden(true)
    end
    for i = nd + 1, self.divCount do self.dividers[i]:SetHidden(true) end
    self.count, self.divCount = nb, nd

    if nb > 0 then
        self.topLevel:SetDimensions(x + SIZE + PAD * 2, bottom - GAP + PAD * 2)
    end
    frame:SetHidden(nb == 0)
end

-- Show / hide (ESO's "hudui" scene = cursor mode) -----------------------------------
function Panel:OnShowing()
    self.shown = true
    if self.dirty then self:Build() end
    self:RefreshActive()
    EM:RegisterForEvent(NAME .. "Collectible", EVENT_COLLECTIBLE_UPDATED, self.onCollectible)
    if EVENT_ACTIVE_COMPANION_STATE_CHANGED then
        EM:RegisterForEvent(NAME .. "Companion", EVENT_ACTIVE_COMPANION_STATE_CHANGED, self.onCompanion)
    end
end

function Panel:OnHidden()
    self.shown = false
    EM:UnregisterForEvent(NAME .. "Collectible", EVENT_COLLECTIBLE_UPDATED)
    if EVENT_ACTIVE_COMPANION_STATE_CHANGED then
        EM:UnregisterForEvent(NAME .. "Companion", EVENT_ACTIVE_COMPANION_STATE_CHANGED)
    end
    ZO_Tooltips_HideTextTooltip()
end

-- Init ----------------------------------------------------------------------------------
function Panel:Initialize(sv)
    local s = sv.panel
    if type(s) ~= "table" then s = {}; sv.panel = s end
    if s.enabled == nil then s.enabled = true end
    if type(s.hidden) ~= "table" then s.hidden = {} end
    self.sv = s

    self.buttons, self.dividers, self.byId = {}, {}, {}

    local tl = WM:CreateTopLevelWindow(NAME)
    tl:SetHidden(true)
    tl:SetClampedToScreen(true)
    tl:SetDrawTier(DT_MEDIUM)
    tl:SetDimensions(SIZE + PAD * 2, SIZE + PAD * 2)
    tl:SetAnchor(LEFT, GuiRoot, LEFT, EDGE_X, 0)
    self.topLevel = tl

    local frame = WM:CreateControl(NAME .. "Frame", tl, CT_CONTROL)
    frame:SetAnchorFill(tl)
    frame:SetHidden(true)
    self.frame = frame

    -- AetherUI frame: black rim, bronze edge, dark inside.
    local rim = WM:CreateControl(NAME .. "Rim", frame, CT_TEXTURE)
    rim:SetAnchor(TOPLEFT, frame, TOPLEFT, -2, -2)
    rim:SetAnchor(BOTTOMRIGHT, frame, BOTTOMRIGHT, 2, 2)
    rim:SetColor(0.02, 0.016, 0.012, 0.92)
    local edge = WM:CreateControl(NAME .. "Edge", frame, CT_TEXTURE)
    edge:SetAnchorFill(frame)
    edge:SetColor(BRONZE[1], BRONZE[2], BRONZE[3], 0.55)
    local inner = WM:CreateControl(NAME .. "Inner", frame, CT_TEXTURE)
    inner:SetAnchor(TOPLEFT, frame, TOPLEFT, 1, 1)
    inner:SetAnchor(BOTTOMRIGHT, frame, BOTTOMRIGHT, -1, -1)
    inner:SetColor(0.06, 0.05, 0.04, 0.88)

    self.onCollectible = function(_, id)
        local b = self.byId[id]
        if b then self:SetActive(b, IsCollectibleActive(id)) end
    end
    self.onCompanion = function() self:RefreshActive() end
    self.onUnlocks = function()
        self.dirty = true
        if self.shown then self:Build(); self:RefreshActive() end
    end

    local fragment = ZO_SimpleSceneFragment:New(tl)
    fragment:RegisterCallback("StateChange", function(_, newState)
        if newState == SCENE_FRAGMENT_SHOWING then
            self:OnShowing()
        elseif newState == SCENE_FRAGMENT_HIDDEN then
            self:OnHidden()
        end
    end)
    self.fragment = fragment

    self.ready = true
    self:ApplyEnabled()
end

-- Settings ------------------------------------------------------------------------------
function Panel:ApplyEnabled()
    local on = self.sv.enabled
    if on == self.registered then return end
    self.registered = on
    local unlockEvent = EVENT_COLLECTIBLES_UNLOCK_STATE_CHANGED
    if on then
        HUD_UI_SCENE:AddFragment(self.fragment)
        if unlockEvent then EM:RegisterForEvent(NAME .. "Unlocks", unlockEvent, self.onUnlocks) end
    else
        HUD_UI_SCENE:RemoveFragment(self.fragment)
        if unlockEvent then EM:UnregisterForEvent(NAME .. "Unlocks", unlockEvent) end
        self.topLevel:SetHidden(true)
    end
end

function Panel:SetEnabled(enabled)
    enabled = enabled and true or false
    if self.sv.enabled == enabled then return end
    self.sv.enabled = enabled
    if self.ready then self:ApplyEnabled() end
end

function Panel:IsShown(id)
    return not self.sv.hidden[id]
end

-- Put one collectible on the panel or take it off.
function Panel:SetShown(id, show)
    local hidden = self.sv.hidden
    local value = (not show) or nil
    if hidden[id] == value then return end
    hidden[id] = value
    self.dirty = true
    if self.shown then self:Build(); self:RefreshActive() end
end

-- Slash commands ------------------------------------------------------------------------
function Panel:HandleCommand(cmd, rest)
    if cmd ~= "panel" then return false end
    if rest == "on" or rest == "off" then
        self:SetEnabled(rest == "on")
        AUI:Print("summon panel " .. rest)
    else
        AUI:Print("summon panel: " .. (self.sv.enabled and "on" or "off") .. ". /aether panel <on|off>")
    end
    return true
end

AUI:RegisterModule("Panel", Panel)
