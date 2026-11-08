-- AetherUI / ResourceBars
-- Skyrim (RFAD-style) Health / Magicka / Stamina bars.
--
-- Animations:
--   * smooth eased fill (fast on loss, softer on gain)
--   * damage trail: a pale segment holds at the old value, then drains
--   * gain preview: restored amount shows instantly as a translucent segment
--   * hit flash on noticeable damage
--   * breathing glow when a resource is below 25%
--   * triple blink when an ability fails for lack of resource
--   * per-bar fade out when full and out of combat, fade in on any change
--
-- Performance:
--   * events are filtered natively (unit tag + power type), no Lua-side filtering
--   * one shared per-frame ticker that exists only while something animates,
--     then unregisters itself (zero per-frame cost while idle)
--   * widths/alphas are cached; the C side is only touched when a value changes
--   * looping effects run on native AnimationTimelines, not Lua

local AUI = AetherUI
local EM = EVENT_MANAGER

local GetFrameTimeMilliseconds = GetFrameTimeMilliseconds
local GetUnitPower = GetUnitPower
local mexp, mmin, mmax = math.exp, math.min, math.max

local NAME = "AetherUI_ResourceBars"

-- Layout ---------------------------------------------------------------------
local BAR_HEIGHT = 11
local BAR_GAP = 64           -- room for caps + spikes between bars (default layout)
local FRAME_PAD = 70         -- caps + spikes overhang (both ends) for the drag frame

-- Motion tuning --------------------------------------------------------------
local FILL_RATE_DOWN = 18    -- exponential approach rates (1/s)
local FILL_RATE_UP = 7
local TRAIL_HOLD_MS = 450    -- how long the damage trail waits before draining
local TRAIL_RATE = 4.2
local SHIELD_RATE = 10
local FADE_IN_SPEED = 7      -- alpha units per second
local FADE_OUT_SPEED = 1.6
local FADE_DELAY_MS = 2500   -- full + out of combat -> fade after this
local LOW_THRESHOLD = 0.25
local HIT_FLASH_MIN = 0.015  -- min fraction lost to trigger a hit flash
local EPS = 0.0005
local PX_EPS = 0.2

-- Colours --------------------------------------------------------------------
local function C(hex, a)
    local c = ZO_ColorDef:New(hex)
    if a then c:SetAlpha(a) end
    return c
end

local FRAME = {
    trackTop = C("1C1712"), trackBottom = C("0A0806"),
    bevelTop = C("8E7752"), bevelBottom = C("2B2217"),
    capTop = C("A68C5C"), capBottom = C("3D311F"),
    spike = C("8E7752"),
    trailTop = C("F6EAC6", 0.92), trailBottom = C("B89C62", 0.92),
    shieldTop = C("EEF3FA", 0.6), shieldBottom = C("9AA8BC", 0.45),
}

-- grow: which edge the fill is pinned to.
--   center = drains from both ends (Skyrim health)
--   right  = pinned right, drains from the outer left edge (magicka, left bar)
--   left   = pinned left, drains from the outer right edge (stamina, right bar)
local STYLES = {
    [POWERTYPE_HEALTH] = {
        key = "Health", grow = "center",
        top = C("D44A3A"), bottom = C("6E1010"), gain = C("E8796A", 0.45), warn = C("FF2A1A"),
    },
    [POWERTYPE_MAGICKA] = {
        key = "Magicka", grow = "right",
        top = C("4F8FE8"), bottom = C("132C72"), gain = C("8DB8F2", 0.45), warn = C("5AA8FF"),
    },
    [POWERTYPE_STAMINA] = {
        key = "Stamina", grow = "left",
        top = C("8CC24E"), bottom = C("24521A"), gain = C("B7DD8A", 0.45), warn = C("B6FF5A"),
    },
}

local ANCHOR_POINT = { center = CENTER, left = LEFT, right = RIGHT }

-- Layouts ----------------------------------------------------------------------
-- Each layout gives per-bar geometry and an Anchor() that places the three bar
-- controls inside the top-level. Applied only on load / when the setting
-- changes, so layouts cost nothing per frame.
--   width  : bar length in px
--   grow   : edge the fill is pinned to (see STYLES)
--   label  : where the value text sits ("top" | "bottom" | "right")
--   spikeL / spikeR : false hides that decorative spike
local H, M, S = POWERTYPE_HEALTH, POWERTYPE_MAGICKA, POWERTYPE_STAMINA

local PYR_HP_W, PYR_GAP, PYR_ROW = 360, 30, 14
local PYR_SIDE_W = (PYR_HP_W - PYR_GAP) / 2
local COL_W, COL_ROW = 300, 12

local LAYOUTS = {
    -- Skyrim: Magicka | Health | Stamina in one row.
    default = {
        bars = {
            [H] = { width = 300, grow = "center", label = "top" },
            [M] = { width = 300, grow = "right", label = "top" },
            [S] = { width = 300, grow = "left", label = "top" },
        },
        width = 300 * 3 + BAR_GAP * 2 + FRAME_PAD, height = 44,
        Anchor = function(tl, h, m, s)
            h:SetAnchor(CENTER, tl, CENTER, 0, 0)
            m:SetAnchor(RIGHT, h, LEFT, -BAR_GAP, 0)
            s:SetAnchor(LEFT, h, RIGHT, BAR_GAP, 0)
        end,
    },
    -- Bandits UI style: wide Health on top, Magicka + Stamina side by side under it.
    pyramid = {
        bars = {
            [H] = { width = PYR_HP_W, grow = "center", label = "top" },
            [M] = { width = PYR_SIDE_W, grow = "right", label = "bottom", spikeR = false },
            [S] = { width = PYR_SIDE_W, grow = "left", label = "bottom", spikeL = false },
        },
        width = PYR_HP_W + FRAME_PAD, height = BAR_HEIGHT * 2 + PYR_ROW + 44,
        Anchor = function(tl, h, m, s)
            h:SetAnchor(CENTER, tl, CENTER, 0, -(BAR_HEIGHT + PYR_ROW) / 2)
            m:SetAnchor(TOPLEFT, h, BOTTOMLEFT, 0, PYR_ROW)
            s:SetAnchor(TOPRIGHT, h, BOTTOMRIGHT, 0, PYR_ROW)
        end,
    },
    -- LUI style: Health / Magicka / Stamina stacked in one column, filled from the left.
    columns = {
        bars = {
            [H] = { width = COL_W, grow = "left", label = "right" },
            [M] = { width = COL_W, grow = "left", label = "right" },
            [S] = { width = COL_W, grow = "left", label = "right" },
        },
        width = COL_W + FRAME_PAD, height = BAR_HEIGHT * 3 + COL_ROW * 2 + 20,
        Anchor = function(tl, h, m, s)
            h:SetAnchor(CENTER, tl, CENTER, 0, -(BAR_HEIGHT + COL_ROW))
            m:SetAnchor(TOP, h, BOTTOM, 0, COL_ROW)
            s:SetAnchor(TOP, m, BOTTOM, 0, COL_ROW)
        end,
    },
}
local LAYOUT_ORDER = { "default", "pyramid", "columns" }

local LABEL_OFFSET_SIDE = 34 -- clears cap + spike

local function SetGradient(tex, top, bottom)
    tex:SetColor(1, 1, 1, 1)
    local r, g, b, a = top:UnpackRGBA()
    tex:SetVertexColors(VERTEX_POINTS_TOPLEFT + VERTEX_POINTS_TOPRIGHT, r, g, b, a)
    r, g, b, a = bottom:UnpackRGBA()
    tex:SetVertexColors(VERTEX_POINTS_BOTTOMLEFT + VERTEX_POINTS_BOTTOMRIGHT, r, g, b, a)
end

local function SetHorizontalFade(tex, color, fadeLeft)
    tex:SetColor(1, 1, 1, 1)
    local r, g, b, a = color:UnpackRGBA()
    local opaque = fadeLeft and (VERTEX_POINTS_TOPRIGHT + VERTEX_POINTS_BOTTOMRIGHT)
                             or (VERTEX_POINTS_TOPLEFT + VERTEX_POINTS_BOTTOMLEFT)
    local clear = fadeLeft and (VERTEX_POINTS_TOPLEFT + VERTEX_POINTS_BOTTOMLEFT)
                            or (VERTEX_POINTS_TOPRIGHT + VERTEX_POINTS_BOTTOMRIGHT)
    tex:SetVertexColors(opaque, r, g, b, a)
    tex:SetVertexColors(clear, r, g, b, 0)
end

local function MakeDiamond(tex)
    if tex.SetTransformRotationZ then
        tex:SetTransformRotationZ(math.pi / 4)
    else
        tex:SetTextureRotation(math.pi / 4, 0.5, 0.5)
    end
end

local function Approach(v, target, rate, dt)
    local d = target - v
    if d > -EPS and d < EPS then return target end
    return v + d * (1 - mexp(-rate * dt))
end

-- Shared ticker --------------------------------------------------------------
local RB = {}
AUI.ResourceBars = RB

local active = {}
local tickerRunning = false
local lastFrameMs = 0

local function OnTick()
    local now = GetFrameTimeMilliseconds()
    local dt = (now - lastFrameMs) / 1000
    lastFrameMs = now
    if dt > 0.1 then dt = 0.1 elseif dt < 0 then dt = 0 end

    for bar in pairs(active) do
        if bar:Step(now, dt) then
            active[bar] = nil
        end
    end

    if next(active) == nil then
        EM:UnregisterForUpdate(NAME)
        tickerRunning = false
    end
end

local function Wake(bar)
    active[bar] = true
    if not tickerRunning then
        tickerRunning = true
        lastFrameMs = GetFrameTimeMilliseconds()
        EM:RegisterForUpdate(NAME, 0, OnTick)
    end
end

-- Bar ------------------------------------------------------------------------
local Bar = ZO_Object:Subclass()

function Bar:New(...)
    local obj = ZO_Object.New(self)
    obj:Initialize(...)
    return obj
end

function Bar:Initialize(parent, powerType, style)
    local c = CreateControlFromVirtual("AetherUI_Bar" .. style.key, parent, "AetherUI_ResourceBar")
    self.control = c
    self.powerType = powerType
    self.style = style

    local function child(n) return c:GetNamedChild(n) end
    self.track, self.fillTex, self.trailTex, self.gainTex = child("Track"), child("Fill"), child("Trail"), child("Gain")
    self.shieldTex, self.flashTex, self.glowTex, self.alertTex = child("Shield"), child("Flash"), child("Glow"), child("Alert")
    self.valueLabel = child("Value")
    self.spikeL, self.spikeR = child("SpikeL"), child("SpikeR")
    self.width = 0

    for _, tex in ipairs({ self.gainTex, self.trailTex, self.fillTex }) do
        tex:SetHeight(BAR_HEIGHT)
    end
    self.shieldTex:SetHeight(BAR_HEIGHT)

    -- Look
    SetGradient(child("Track"), FRAME.trackTop, FRAME.trackBottom)
    SetGradient(child("Bevel"), FRAME.bevelTop, FRAME.bevelBottom)
    SetGradient(self.fillTex, style.top, style.bottom)
    SetGradient(self.trailTex, FRAME.trailTop, FRAME.trailBottom)
    SetGradient(self.shieldTex, FRAME.shieldTop, FRAME.shieldBottom)
    self.gainTex:SetColor(style.gain:UnpackRGBA())
    self.glowTex:SetColor(style.warn:UnpackRGB())
    self.alertTex:SetColor(style.warn:UnpackRGB())
    for _, n in ipairs({ "CapL", "CapR" }) do
        local cap = child(n)
        SetGradient(cap, FRAME.capTop, FRAME.capBottom)
        MakeDiamond(cap)
        MakeDiamond(child(n .. "Inner"))
    end
    SetHorizontalFade(self.spikeL, FRAME.spike, true)
    SetHorizontalFade(self.spikeR, FRAME.spike, false)

    -- Native timelines
    self.lowAnim = ANIMATION_MANAGER:CreateTimelineFromVirtual("AetherUI_LowPulseAnim", self.glowTex)
    self.alertAnim = ANIMATION_MANAGER:CreateTimelineFromVirtual("AetherUI_AlertBlinkAnim", self.alertTex)
    self.hitAnim = ANIMATION_MANAGER:CreateTimelineFromVirtual("AetherUI_HitFlashAnim", self.flashTex)
    self.alertAnim:SetHandler("OnStop", function() self.alertTex:SetHidden(true) end)

    -- State (fractions 0..1)
    self.cur, self.max = 0, 0
    self.target, self.fill, self.trail = 1, 1, 1
    self.shieldTarget, self.shield = 0, 0
    self.trailHoldUntil = 0
    self.alpha, self.targetAlpha = 1, 1
    self.hideAt = nil
    self.isLow = false
    self.px = {}       -- cached widths per texture
    self.hidden = {}   -- cached hidden flags per texture
end

-- Geometry for the active layout. Not a hot path (load / setting change only).
function Bar:ApplyLayout(cfg)
    self.width = cfg.width
    self.control:SetDimensions(cfg.width, BAR_HEIGHT)

    local point = ANCHOR_POINT[cfg.grow]
    for _, tex in ipairs({ self.gainTex, self.trailTex, self.fillTex }) do
        tex:ClearAnchors()
        tex:SetAnchor(point, self.track, point, 0, 0)
    end

    self.spikeL:SetHidden(cfg.spikeL == false)
    self.spikeR:SetHidden(cfg.spikeR == false)

    local label = self.valueLabel
    label:ClearAnchors()
    if cfg.label == "bottom" then
        label:SetAnchor(TOP, self.control, BOTTOM, 0, 4)
    elseif cfg.label == "right" then
        label:SetAnchor(LEFT, self.control, RIGHT, LABEL_OFFSET_SIDE, 0)
    else
        label:SetAnchor(BOTTOM, self.control, TOP, 0, -4)
    end

    -- Widths changed: drop the caches and redraw once.
    ZO_ClearTable(self.px)
    ZO_ClearTable(self.hidden)
    self:Render()
end

function Bar:SetWidthCached(tex, px)
    local visible = px >= 0.5
    if self.hidden[tex] ~= not visible then
        self.hidden[tex] = not visible
        tex:SetHidden(not visible)
    end
    if visible then
        local old = self.px[tex]
        if not old or px - old > PX_EPS or old - px > PX_EPS then
            self.px[tex] = px
            tex:SetWidth(px)
        end
    end
end

function Bar:Render()
    local w, fill, target = self.width, self.fill, self.target
    self:SetWidthCached(self.fillTex, fill * w)
    self:SetWidthCached(self.trailTex, self.trail > fill and self.trail * w or 0)
    self:SetWidthCached(self.gainTex, target > fill and target * w or 0)
    if self.powerType == POWERTYPE_HEALTH then
        self:SetWidthCached(self.shieldTex, self.shield * w)
    end
end

function Bar:SetValue(cur, max, instant)
    self.cur, self.max = cur, max
    local pct = max > 0 and cur / max or 0
    if pct > 1 then pct = 1 elseif pct < 0 then pct = 0 end

    local old = self.target
    self.target = pct

    if instant then
        self.fill, self.trail = pct, pct
        self.shield = self.shieldTarget
    elseif pct < old then
        if self.trail < self.fill then self.trail = self.fill end
        self.trailHoldUntil = GetFrameTimeMilliseconds() + TRAIL_HOLD_MS
        if old - pct >= HIT_FLASH_MIN and self.alpha > 0 then
            self.hitAnim:PlayFromStart()
        end
    end

    if RB.sv.showNumbers then
        self.valueLabel:SetText(zo_strformat("<<1>> / <<2>>", ZO_CommaDelimitNumber(cur), ZO_CommaDelimitNumber(max)))
    end

    self:UpdateLow()
    if instant then self:Render() end
    Wake(self)
end

function Bar:SetShield(value)
    local pct = (self.max > 0 and value and value > 0) and mmin(1, value / self.max) or 0
    if pct ~= self.shieldTarget then
        self.shieldTarget = pct
        Wake(self)
    end
end

function Bar:UpdateLow()
    local low = self.max > 0 and self.target <= LOW_THRESHOLD and not IsUnitDead("player")
    if low == self.isLow then return end
    self.isLow = low
    if low then
        self.glowTex:SetHidden(false)
        self.lowAnim:PlayFromStart()
    else
        self.lowAnim:Stop()
        self.glowTex:SetAlpha(0)
        self.glowTex:SetHidden(true)
    end
end

function Bar:Alert()
    self.alertTex:SetHidden(false)
    self.alertAnim:PlayFromStart()
    self.hideAt = nil
    Wake(self)
end

function Bar:ShouldShow()
    return RB.unlocked or RB.preview or RB.sv.alwaysShow or RB.inCombat
        or self.target < 0.999 or self.shieldTarget > 0
        or self.alertAnim:IsPlaying()
end

-- Returns true when fully settled (bar can leave the ticker).
function Bar:Step(now, dt)
    local target = self.target

    local fill = self.fill
    if fill ~= target then
        fill = Approach(fill, target, target < fill and FILL_RATE_DOWN or FILL_RATE_UP, dt)
        self.fill = fill
    end

    local trail = self.trail
    if trail > fill then
        if now >= self.trailHoldUntil then
            trail = Approach(trail, target, TRAIL_RATE, dt)
        end
        if trail < fill then trail = fill end
    else
        trail = fill
    end
    self.trail = trail

    if self.shield ~= self.shieldTarget then
        self.shield = Approach(self.shield, self.shieldTarget, SHIELD_RATE, dt)
    end

    -- Visibility
    local show = self:ShouldShow()
    if show then
        self.hideAt = nil
        self.targetAlpha = 1
    else
        if not self.hideAt then self.hideAt = now + FADE_DELAY_MS end
        if now >= self.hideAt then self.targetAlpha = 0 end
    end

    local a, ta = self.alpha, self.targetAlpha
    if a ~= ta then
        if a < ta then a = mmin(ta, a + FADE_IN_SPEED * dt) else a = mmax(ta, a - FADE_OUT_SPEED * dt) end
        self.alpha = a
        self.control:SetAlpha(a)
        self.control:SetHidden(a <= 0)
    end

    self:Render()

    return fill == target and trail == fill and self.shield == self.shieldTarget
        and a == ta and (show or ta == 0)
end

function Bar:Refresh(instant)
    local cur, _, effectiveMax = GetUnitPower("player", self.powerType)
    self:SetValue(cur, effectiveMax, instant)
end

function Bar:SetNumbersVisible(visible)
    self.valueLabel:SetHidden(not visible)
    if visible then
        self.valueLabel:SetText(zo_strformat("<<1>> / <<2>>", ZO_CommaDelimitNumber(self.cur), ZO_CommaDelimitNumber(self.max)))
    end
end

-- Module ---------------------------------------------------------------------
function RB:Initialize(sv)
    self.sv = sv.bars
    self.inCombat = IsUnitInCombat("player")
    self.unlocked = false

    local tl = AetherUI_Bars
    self.topLevel = tl
    self.bars = {}

    local health = Bar:New(tl, POWERTYPE_HEALTH, STYLES[POWERTYPE_HEALTH])
    local magicka = Bar:New(tl, POWERTYPE_MAGICKA, STYLES[POWERTYPE_MAGICKA])
    local stamina = Bar:New(tl, POWERTYPE_STAMINA, STYLES[POWERTYPE_STAMINA])

    self.bars[POWERTYPE_HEALTH] = health
    self.bars[POWERTYPE_MAGICKA] = magicka
    self.bars[POWERTYPE_STAMINA] = stamina
    self.health = health

    if not LAYOUTS[self.sv.layout] then self.sv.layout = "default" end
    self:ApplyLayout()
    self:ApplyPosition()
    self:HideDefaultBars()

    local fragment = ZO_HUDFadeSceneFragment:New(tl)
    self.fragment = fragment
    HUD_SCENE:AddFragment(fragment)
    HUD_UI_SCENE:AddFragment(fragment)

    self:RegisterEvents()
    self:ApplyNumbers()
    self:RefreshAll(true)
end

function RB:HideDefaultBars()
    local sink = WINDOW_MANAGER:CreateControl("AetherUI_DefaultBarSink", GuiRoot, CT_CONTROL)
    sink:SetHidden(true)
    for _, name in ipairs({ "ZO_PlayerAttributeHealth", "ZO_PlayerAttributeMagicka", "ZO_PlayerAttributeStamina" }) do
        local ctrl = _G[name]
        if ctrl then ctrl:SetParent(sink) end
    end
end

function RB:RefreshShield()
    local value = GetUnitAttributeVisualizerEffectInfo("player", ATTRIBUTE_VISUAL_POWER_SHIELDING,
        STAT_MITIGATION, ATTRIBUTE_HEALTH, POWERTYPE_HEALTH)
    self.health:SetShield(value or 0)
end

function RB:RefreshAll(instant)
    for _, bar in pairs(self.bars) do
        bar:Refresh(instant)
    end
    self:RefreshShield()
end

function RB:WakeAll()
    for _, bar in pairs(self.bars) do Wake(bar) end
end

function RB:RegisterEvents()
    for powerType, bar in pairs(self.bars) do
        local ns = NAME .. bar.style.key
        EM:RegisterForEvent(ns, EVENT_POWER_UPDATE, function(_, _, _, _, value, _, effectiveMax)
            bar:SetValue(value, effectiveMax)
        end)
        EM:AddFilterForEvent(ns, EVENT_POWER_UPDATE,
            REGISTER_FILTER_UNIT_TAG, "player",
            REGISTER_FILTER_POWER_TYPE, powerType)
    end

    EM:RegisterForEvent(NAME, EVENT_PLAYER_COMBAT_STATE, function(_, inCombat)
        self.inCombat = inCombat
        self:WakeAll()
    end)

    local function OnShieldEvent(_, _, unitAttributeVisual)
        if unitAttributeVisual == ATTRIBUTE_VISUAL_POWER_SHIELDING then self:RefreshShield() end
    end
    for i, ev in ipairs({ EVENT_UNIT_ATTRIBUTE_VISUAL_ADDED, EVENT_UNIT_ATTRIBUTE_VISUAL_UPDATED, EVENT_UNIT_ATTRIBUTE_VISUAL_REMOVED }) do
        local ns = NAME .. "Shield" .. i
        EM:RegisterForEvent(ns, ev, OnShieldEvent)
        EM:AddFilterForEvent(ns, ev, REGISTER_FILTER_UNIT_TAG, "player")
    end

    local function OnReset()
        self.inCombat = IsUnitInCombat("player")
        self:RefreshAll(true)
    end
    EM:RegisterForEvent(NAME, EVENT_PLAYER_ACTIVATED, OnReset)
    EM:RegisterForEvent(NAME, EVENT_PLAYER_DEAD, OnReset)
    EM:RegisterForEvent(NAME, EVENT_PLAYER_ALIVE, OnReset)

    -- "Not enough magicka/stamina" blink.
    if ACTION_RESULT_INSUFFICIENT_RESOURCE then
        EM:RegisterForEvent(NAME .. "Insufficient", EVENT_COMBAT_EVENT,
            function(_, _, _, _, _, _, _, _, _, _, _, powerType)
                local bar = self.bars[powerType]
                if bar then bar:Alert() end
            end)
        EM:AddFilterForEvent(NAME .. "Insufficient", EVENT_COMBAT_EVENT,
            REGISTER_FILTER_COMBAT_RESULT, ACTION_RESULT_INSUFFICIENT_RESOURCE,
            REGISTER_FILTER_SOURCE_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER)
    end
end

-- Layout / visibility (used by the settings panel and slash commands) ---------
RB.LAYOUT_ORDER = LAYOUT_ORDER

function RB:ApplyLayout()
    local layout = LAYOUTS[self.sv.layout] or LAYOUTS.default
    local tl = self.topLevel
    local h, m, s = self.bars[H], self.bars[M], self.bars[S]
    for powerType, bar in pairs(self.bars) do
        bar.control:ClearAnchors()
        bar:ApplyLayout(layout.bars[powerType])
    end
    layout.Anchor(tl, h.control, m.control, s.control)
    tl:SetDimensions(layout.width, layout.height)
end

function RB:SetLayout(name)
    if not LAYOUTS[name] then return false end
    if self.sv.layout ~= name then
        self.sv.layout = name
        self:ApplyLayout()
    end
    return true
end

function RB:SetAlwaysShow(always)
    self.sv.alwaysShow = always
    self:WakeAll()
end

function RB:SetNumbers(show)
    self.sv.showNumbers = show
    self:ApplyNumbers()
end

-- Keep the bars visible on top of the settings menu so changes are seen live.
function RB:SetPreview(enabled)
    if self.preview == enabled then return end
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
    self:WakeAll()
end

-- Position / settings ----------------------------------------------------------
function RB:ApplyPosition()
    local tl = self.topLevel
    tl:ClearAnchors()
    local p = self.sv.point
    if p then
        tl:SetAnchor(CENTER, GuiRoot, TOPLEFT, p.x, p.y)
    elseif ZO_PlayerAttribute then
        tl:SetAnchor(CENTER, ZO_PlayerAttribute, CENTER, 0, 0)
    else
        tl:SetAnchor(BOTTOM, GuiRoot, BOTTOM, 0, -110)
    end
end

function RB:OnMoveStop()
    local x, y = self.topLevel:GetCenter()
    self.sv.point = { x = x, y = y }
end

function RB:SetUnlocked(unlocked)
    self.unlocked = unlocked
    local tl = self.topLevel
    tl:SetMouseEnabled(unlocked)
    tl:SetMovable(unlocked)
    tl:GetNamedChild("DragOverlay"):SetHidden(not unlocked)
    tl:GetNamedChild("DragLabel"):SetHidden(not unlocked)
    self:WakeAll()
end

function RB:ApplyNumbers()
    for _, bar in pairs(self.bars) do bar:SetNumbersVisible(self.sv.showNumbers) end
end

function RB:HandleCommand(cmd, rest)
    if cmd == "unlock" then
        self:SetUnlocked(true)
        AUI:Print("bars unlocked. Drag them, then /aether lock")
    elseif cmd == "lock" then
        self:SetUnlocked(false)
        AUI:Print("bars locked.")
    elseif cmd == "reset" then
        self.sv.point = nil
        self:ApplyPosition()
        AUI:Print("bar position reset.")
    elseif cmd == "numbers" then
        self:SetNumbers(not self.sv.showNumbers)
        AUI:Print("numbers " .. (self.sv.showNumbers and "on" or "off"))
    elseif cmd == "always" then
        self:SetAlwaysShow(not self.sv.alwaysShow)
        AUI:Print("always show " .. (self.sv.alwaysShow and "on" or "off"))
    elseif cmd == "layout" then
        if self:SetLayout(rest) then
            AUI:Print("layout: " .. rest)
        else
            AUI:Print("layouts: " .. table.concat(LAYOUT_ORDER, " | "))
        end
    else
        return false
    end
    return true
end

AUI:RegisterModule("ResourceBars", RB)
