-- AetherUI / Panel
-- Summon panel, like the Bandits UI side panel: press "." (show cursor) and a
-- column of buttons appears on the left edge of the screen.
--   * assistants first, then a divider line, then companions
--   * one button per owned collectible, its own icon; hover for the name
--   * click = summon, click again = dismiss; the ones out now get a bright
--     bronze edge, full-color icon and a notch on the left; the rest are muted
--   * look: bronze-edged sockets on a dark gradient body, fading ornament
--     lines on top / bottom and between the groups, short fade in / out
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
--   * the look is pushed only on hover / active changes (a few setters per
--     button); all textures are built once with the pooled buttons
--   * disabled = no fragment, no events

local AUI = AetherUI
local EM = EVENT_MANAGER
local WM = WINDOW_MANAGER

local GetCollectibleIcon = GetCollectibleIcon
local IsCollectibleActive = IsCollectibleActive

local NAME = "AetherUI_Panel"
local SIZE = 34          -- button
local GAP = 6            -- between buttons / columns
local PAD = 9            -- inside the frame
local DIV_H = 15         -- divider slot height (ornament in the middle)
local EDGE_X = 10        -- from the left screen edge
local MAX_HEIGHT = 0.7   -- of the screen; taller lists wrap into another column
local FADE_MS = 120      -- show / hide fade

local BRONZE = { 0.78, 0.64, 0.39 }
local DIAMOND_ROT = math.pi / 4

-- Slot look per state: edge alpha, icon brightness, icon desaturation.
-- Idle slots are muted so the ones that are out read at a glance.
local EDGE_IDLE, EDGE_HOVER, EDGE_ACTIVE = 0.22, 0.6, 0.95
local ICON_IDLE, ICON_HOVER, ICON_ACTIVE = 0.72, 1, 1
local DESAT_IDLE, DESAT_HOVER, DESAT_ACTIVE = 0.45, 0.1, 0

local VTX_LEFT = (VERTEX_POINTS_TOPLEFT or 1) + (VERTEX_POINTS_BOTTOMLEFT or 4)
local VTX_RIGHT = (VERTEX_POINTS_TOPRIGHT or 2) + (VERTEX_POINTS_BOTTOMRIGHT or 8)
local VTX_TOP = (VERTEX_POINTS_TOPLEFT or 1) + (VERTEX_POINTS_TOPRIGHT or 2)
local VTX_BOTTOM = (VERTEX_POINTS_BOTTOMLEFT or 4) + (VERTEX_POINTS_BOTTOMRIGHT or 8)

local Panel = {
    ready = false,
    shown = false,
    registered = false,
    dirty = true,     -- button list changed: lay out again on next show
    count = 0,        -- buttons in use
    divCount = 0,     -- dividers in use
}
AUI.Panel = Panel

-- Drawing helpers (all built once; nothing here runs while shown) --------------------
local function Tex(name, parent, level)
    local t = WM:CreateControl(name, parent, CT_TEXTURE)
    t:SetDrawLevel(level or 0)
    return t
end

-- Two-color gradient on one texture; flat color where vertex colors are missing.
local function Gradient(t, horizontal, r1, g1, b1, a1, r2, g2, b2, a2)
    if t.SetVertexColors then
        t:SetColor(1, 1, 1, 1)
        t:SetVertexColors(horizontal and VTX_LEFT or VTX_TOP, r1, g1, b1, a1)
        t:SetVertexColors(horizontal and VTX_RIGHT or VTX_BOTTOM, r2, g2, b2, a2)
    else
        t:SetColor((r1 + r2) / 2, (g1 + g2) / 2, (b1 + b2) / 2, (a1 + a2) / 2)
    end
end

-- Thin bronze line, bright in the middle and fading out at both ends, with an
-- optional small diamond on it. Returns a control `width` wide, 1px tall
-- (anchor both ends to stretch it).
local function OrnamentLine(name, parent, width, alpha, diamond)
    local c = WM:CreateControl(name, parent, CT_CONTROL)
    c:SetDimensions(width, 1)
    local r, g, b = BRONZE[1], BRONZE[2], BRONZE[3]
    -- Halves split at the centre, so the line stretches with its control.
    local left = Tex(name .. "L", c, 2)
    left:SetAnchor(TOPLEFT, c, TOPLEFT, 0, 0)
    left:SetAnchor(BOTTOMRIGHT, c, BOTTOM, 0, 0)
    Gradient(left, true, r, g, b, 0, r, g, b, alpha)
    local right = Tex(name .. "R", c, 2)
    right:SetAnchor(TOPLEFT, c, TOP, 0, 0)
    right:SetAnchor(BOTTOMRIGHT, c, BOTTOMRIGHT, 0, 0)
    Gradient(right, true, r, g, b, alpha, r, g, b, 0)
    if diamond then
        local d = Tex(name .. "D", c, 3)
        d:SetDimensions(5, 5)
        d:SetAnchor(CENTER, c, CENTER, 0, 0)
        d:SetColor(r, g, b, zo_min(1, alpha + 0.1))
        if d.SetTextureRotation then d:SetTextureRotation(DIAMOND_ROT) end
    end
    return c
end

-- Buttons ----------------------------------------------------------------------------
local function ShowTooltip(control)
    local id = control.collectibleId
    if not id then return end
    local Keybinds = AUI.Keybinds
    local hint = IsCollectibleActive(id) and "Out now. Click to dismiss." or "Click to summon."
    ZO_Tooltips_ShowTextTooltip(control, RIGHT, Keybinds.CollectibleName(id) .. "\n|cA8946A" .. hint .. "|r")
end

-- Pushes the look for the slot's current hover / active state. Called only on
-- mouse enter / exit and when the active state actually changes.
local function ApplyLook(b)
    local edge, icon, desat
    if b.isHover then
        edge, icon, desat = EDGE_HOVER, ICON_HOVER, DESAT_HOVER
    elseif b.isActive then
        edge, icon, desat = EDGE_ACTIVE, ICON_ACTIVE, DESAT_ACTIVE
    else
        edge, icon, desat = EDGE_IDLE, ICON_IDLE, DESAT_IDLE
    end
    if b.isActive and edge < EDGE_ACTIVE then edge = EDGE_ACTIVE end
    b.edge:SetAlpha(edge)
    b.icon:SetColor(icon, icon, icon, 1)
    b.icon:SetDesaturation(desat)
    b.hover:SetHidden(not b.isHover)
end

local function OnEnter(control)
    control.isHover = true
    ApplyLook(control)
    ShowTooltip(control)
end

local function OnExit(control)
    control.isHover = false
    ApplyLook(control)
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

    -- Socket: bronze 1px edge (alpha = state), dark well, icon inset 2px.
    local edge = Tex(name .. "Edge", b, 1)
    edge:SetAnchorFill(b)
    edge:SetColor(BRONZE[1], BRONZE[2], BRONZE[3], 1)

    local well = Tex(name .. "Well", b, 2)
    well:SetAnchor(TOPLEFT, b, TOPLEFT, 1, 1)
    well:SetAnchor(BOTTOMRIGHT, b, BOTTOMRIGHT, -1, -1)
    Gradient(well, false, 0.015, 0.012, 0.01, 1, 0.05, 0.04, 0.03, 1)

    local icon = Tex(name .. "Icon", b, 3)
    icon:SetAnchor(TOPLEFT, b, TOPLEFT, 2, 2)
    icon:SetAnchor(BOTTOMRIGHT, b, BOTTOMRIGHT, -2, -2)

    -- Inner shade: darkens the icon's lower edge so it sits in the socket.
    local shade = Tex(name .. "Shade", b, 4)
    shade:SetAnchor(TOPLEFT, icon, LEFT, 0, 0)
    shade:SetAnchor(BOTTOMRIGHT, icon, BOTTOMRIGHT, 0, 0)
    Gradient(shade, false, 0, 0, 0, 0, 0, 0, 0, 0.35)

    local hover = Tex(name .. "Hover", b, 5)
    hover:SetAnchorFill(icon)
    hover:SetColor(1, 0.92, 0.75, 0.1)
    hover:SetHidden(true)

    -- Out now: a bronze notch on the slot's outer left side.
    local marker = Tex(name .. "Marker", b, 6)
    marker:SetDimensions(2, SIZE - 12)
    marker:SetAnchor(RIGHT, b, LEFT, -3, 0)
    marker:SetColor(BRONZE[1] * 1.15, BRONZE[2] * 1.15, BRONZE[3] * 1.15, 1)
    marker:SetHidden(true)

    b.icon, b.edge, b.hover, b.marker = icon, edge, hover, marker
    b.isActive, b.isHover = false, false
    ApplyLook(b)
    b:SetHandler("OnMouseEnter", OnEnter)
    b:SetHandler("OnMouseExit", OnExit)
    b:SetHandler("OnMouseUp", OnClick)

    self.buttons[i] = b
    return b
end

function Panel:GetDivider(i)
    local d = self.dividers[i]
    if d then return d end
    d = OrnamentLine(NAME .. "Divider" .. i, self.frame, SIZE, 0.75, true)
    self.dividers[i] = d
    return d
end

function Panel:SetActive(b, active)
    active = active and true or false
    if b.isActive ~= active then
        b.isActive = active
        b.marker:SetHidden(not active)
        ApplyLook(b)
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
                        d:SetAnchor(LEFT, frame, TOPLEFT, PAD + x, PAD + y + zo_floor((DIV_H - GAP) / 2))
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
    for i = 1, self.count do
        local b = self.buttons[i]
        if b.isHover then b.isHover = false; ApplyLook(b) end
    end
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

    -- AetherUI frame: soft dark shadow, faint bronze edge, dark gradient body,
    -- ornamented bronze lines across the top and bottom.
    local shadow = Tex(NAME .. "Shadow", frame, 0)
    shadow:SetAnchor(TOPLEFT, frame, TOPLEFT, -3, -3)
    shadow:SetAnchor(BOTTOMRIGHT, frame, BOTTOMRIGHT, 3, 3)
    shadow:SetColor(0, 0, 0, 0.45)
    local edge = Tex(NAME .. "Edge", frame, 0)
    edge:SetAnchorFill(frame)
    edge:SetColor(BRONZE[1], BRONZE[2], BRONZE[3], 0.28)
    local inner = Tex(NAME .. "Inner", frame, 1)
    inner:SetAnchor(TOPLEFT, frame, TOPLEFT, 1, 1)
    inner:SetAnchor(BOTTOMRIGHT, frame, BOTTOMRIGHT, -1, -1)
    Gradient(inner, false, 0.075, 0.062, 0.048, 0.9, 0.03, 0.025, 0.02, 0.9)

    local top = OrnamentLine(NAME .. "Top", frame, SIZE, 0.9, false)
    top:SetAnchor(TOPLEFT, frame, TOPLEFT, 1, 1)
    top:SetAnchor(TOPRIGHT, frame, TOPRIGHT, -1, 1)
    local bottom = OrnamentLine(NAME .. "Bottom", frame, SIZE, 0.9, false)
    bottom:SetAnchor(BOTTOMLEFT, frame, BOTTOMLEFT, 1, -1)
    bottom:SetAnchor(BOTTOMRIGHT, frame, BOTTOMRIGHT, -1, -1)

    self.onCollectible = function(_, id)
        local b = self.byId[id]
        if b then self:SetActive(b, IsCollectibleActive(id)) end
    end
    self.onCompanion = function() self:RefreshActive() end
    self.onUnlocks = function()
        self.dirty = true
        if self.shown then self:Build(); self:RefreshActive() end
    end

    -- Short fade in / out; falls back to a plain fragment on older clients.
    local fragment
    if ZO_HUDFadeSceneFragment then
        fragment = ZO_HUDFadeSceneFragment:New(tl, FADE_MS, FADE_MS)
    else
        fragment = ZO_SimpleSceneFragment:New(tl)
    end
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
