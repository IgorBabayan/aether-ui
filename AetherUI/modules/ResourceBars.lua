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
--   * dragging: the drag poll is registered only while something is held and
--     skips frames where the cursor has not moved
--   * bar text is cached; SetText runs only when the shown string changes
--
-- Positioning (unlock mode):
--   * "default" layout: each bar is dragged on its own; positions saved per bar
--   * any other layout: the whole group is dragged together

local AUI = AetherUI
local EM = EVENT_MANAGER

local GetFrameTimeMilliseconds = GetFrameTimeMilliseconds
local GetUnitPower = GetUnitPower
local GetUIMousePosition = GetUIMousePosition
local ZO_CommaDelimitNumber = ZO_CommaDelimitNumber
local zo_round = zo_round
local sfmt = string.format
local mexp, mmin, mmax = math.exp, math.min, math.max

local NAME = "AetherUI_ResourceBars"
local DRAG_NAME = NAME .. "Drag"

-- Layout ---------------------------------------------------------------------
-- Bar size is user-configurable (settings / slash commands). Width is the base
-- bar length; layouts derive their own widths from it. Height is the bar
-- thickness; bars never get thinner than BAR_HEIGHT_TEXT while text is shown.
local WIDTH_MIN, WIDTH_MAX, WIDTH_DEFAULT = 150, 600, 300
local HEIGHT_MIN, HEIGHT_MAX, HEIGHT_DEFAULT = 6, 40, 20
local SPIKE_BASE_HEIGHT = 11 -- bar height the cap/spike art was tuned for
local BAR_HEIGHT_TEXT = 18
local DRAG_PAD_Y = 10        -- vertical grab area around a bar

-- Caps + spikes overhang one bar end by this much; everything that has to
-- clear them (gap between bars, drag frame, grab area) is derived from it.
-- At the default 11 px height: offset 6 + spike 22 = 28 (gap 64, frame pad 70).
local function SpikeGeometry(bh)
    local off = zo_round(bh * 0.55)
    local len = 22 + mmax(0, zo_round((bh - SPIKE_BASE_HEIGHT) * 0.8))
    return off, len
end

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
--   grow   : edge the fill is pinned to (see STYLES)
--   spikeL / spikeR : false hides that decorative spike
local H, M, S = POWERTYPE_HEALTH, POWERTYPE_MAGICKA, POWERTYPE_STAMINA

local PYR_HP_SCALE, PYR_GAP, PYR_ROW = 1.2, 30, 14 -- pyramid health bar = 1.2 x base width
local COL_ROW = 12

-- LUI (LuiExtended) default spot for its stacked player frame: the frame's
-- top-left corner sits at (-492, 205) from screen centre on a 1080p canvas.
-- Scaled for other resolutions / aspect ratios the same way LUI does it
-- (ultrawide and multi-monitor capped at ~21:9).
local LUI_X, LUI_Y = -492, 205
local LUI_MAX_ASPECT, BASE_ASPECT = 2.45, 16 / 9

local function LuiOffset()
    local sw, sh = GuiRoot:GetDimensions()
    if sw == 0 or sh == 0 then sw, sh = 1920, 1080 end
    local aspect = sw / sh
    local wScale, hScale = sw / 1920, sh / 1080
    local aScale = aspect / BASE_ASPECT
    if aspect > LUI_MAX_ASPECT then
        aScale = LUI_MAX_ASPECT / BASE_ASPECT
        wScale = hScale * aScale
    end
    return LUI_X * wScale, LUI_Y * (hScale ^ 1.2) * aScale
end

-- separate = true: bars can be dragged one by one (each anchored to the
-- top-level on its own, so moving one never drags the others along).
-- Widths(w)  -> health, magicka, stamina widths for base width w
-- Size(g)    -> top-level size;  Anchor(tl, h, m, s, g) -> place the bars
-- g = { bh = bar height, hw = health width, gap = space between bars, pad = frame pad }
local LAYOUTS = {
    -- Skyrim: Magicka | Health | Stamina in one row.
    default = {
        separate = true,
        bars = {
            [H] = { grow = "center" },
            [M] = { grow = "right" },
            [S] = { grow = "left" },
        },
        Widths = function(w) return w, w, w end,
        Size = function(g) return g.hw * 3 + g.gap * 2 + g.pad, g.bh + 33 end,
        Anchor = function(tl, h, m, s, g)
            local off = g.hw / 2 + g.gap
            h:SetAnchor(CENTER, tl, CENTER, 0, 0)
            m:SetAnchor(RIGHT, tl, CENTER, -off, 0)
            s:SetAnchor(LEFT, tl, CENTER, off, 0)
        end,
    },
    -- Bandits UI style: wide Health on top, Magicka + Stamina side by side under it.
    pyramid = {
        bars = {
            [H] = { grow = "center" },
            [M] = { grow = "right", spikeR = false },
            [S] = { grow = "left", spikeL = false },
        },
        Widths = function(w)
            local hw = zo_round(w * PYR_HP_SCALE)
            local side = (hw - PYR_GAP) / 2
            return hw, side, side
        end,
        Size = function(g) return g.hw + g.pad, g.bh * 2 + PYR_ROW + 22 end,
        Anchor = function(tl, h, m, s, g)
            h:SetAnchor(CENTER, tl, CENTER, 0, -(g.bh + PYR_ROW) / 2)
            m:SetAnchor(TOPLEFT, h, BOTTOMLEFT, 0, PYR_ROW)
            s:SetAnchor(TOPRIGHT, h, BOTTOMRIGHT, 0, PYR_ROW)
        end,
    },
    -- LUI style: Health / Magicka / Stamina stacked in one column, filled from the left.
    columns = {
        bars = {
            [H] = { grow = "left" },
            [M] = { grow = "left" },
            [S] = { grow = "left" },
        },
        Widths = function(w) return w, w, w end,
        Size = function(g) return g.hw + g.pad, g.bh * 3 + COL_ROW * 2 + 20 end,
        Anchor = function(tl, h, m, s, g)
            local bh = g.bh
            h:SetAnchor(CENTER, tl, CENTER, 0, -(bh + COL_ROW))
            m:SetAnchor(TOP, h, BOTTOM, 0, COL_ROW)
            s:SetAnchor(TOP, m, BOTTOM, 0, COL_ROW)
        end,
        -- Unmoved position: Health bar's top-left on LUI's player frame corner.
        -- Health centre = group centre - (bh + COL_ROW), see Anchor above.
        DefaultAnchor = function(tl, g)
            local x, y = LuiOffset()
            tl:SetAnchor(CENTER, GuiRoot, CENTER, x + g.hw / 2, y + g.bh * 1.5 + COL_ROW)
        end,
    },
}
local LAYOUT_ORDER = { "default", "pyramid", "columns" }

-- Bar text ---------------------------------------------------------------------
local TEXT_NONE, TEXT_VALUE, TEXT_PERCENT, TEXT_BOTH = "none", "value", "percent", "both"
local TEXT_ORDER = { TEXT_NONE, TEXT_VALUE, TEXT_PERCENT, TEXT_BOTH }
local TEXT_VALID = { none = true, value = true, percent = true, both = true }

local function FormatText(mode, cur, max)
    local pct = max > 0 and zo_round(cur / max * 100) or 0
    if mode == TEXT_PERCENT then
        return sfmt("%d%%", pct)
    elseif mode == TEXT_BOTH then
        return sfmt("%s / %s  (%d%%)", ZO_CommaDelimitNumber(cur), ZO_CommaDelimitNumber(max), pct)
    end
    return sfmt("%s / %s", ZO_CommaDelimitNumber(cur), ZO_CommaDelimitNumber(max))
end

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
    self.capL, self.capR = child("CapL"), child("CapR")
    self.shine = child("Shine")
    self.capLInner, self.capRInner = child("CapLInner"), child("CapRInner")
    self.text = nil    -- last string handed to the label
    self.dragOverlay, self.dragLabel = child("DragOverlay"), child("DragLabel")
    self.dragLabel:SetText(style.key)
    self.dragPadX = 0  -- set by ApplyLayout (depends on bar height)
    self.width = 0

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
function Bar:ApplyLayout(cfg, width, bh)
    local c = self.control
    self.width = width
    c:SetDimensions(width, bh)
    for _, tex in ipairs({ self.gainTex, self.trailTex, self.fillTex, self.shieldTex }) do
        tex:SetHeight(bh)
    end
    self.shine:SetHeight(mmax(2, zo_round(bh * 0.35)))

    -- Diamond caps scale with the bar.
    local capOff = zo_round(bh * 0.3)
    self.capL:SetDimensions(bh, bh)
    self.capR:SetDimensions(bh, bh)
    self.capL:ClearAnchors()
    self.capL:SetAnchor(CENTER, self.control, LEFT, -capOff, 0)
    self.capR:ClearAnchors()
    self.capR:SetAnchor(CENTER, self.control, RIGHT, capOff, 0)
    local inner = zo_round(bh * 0.45)
    self.capLInner:SetDimensions(inner, inner)
    self.capRInner:SetDimensions(inner, inner)

    -- Spikes move out past the bigger caps; grab area follows them.
    local spikeOff, spikeLen = SpikeGeometry(bh)
    self.spikeL:SetDimensions(spikeLen, 1)
    self.spikeL:ClearAnchors()
    self.spikeL:SetAnchor(RIGHT, c, LEFT, -spikeOff, 0)
    self.spikeR:SetDimensions(spikeLen, 1)
    self.spikeR:ClearAnchors()
    self.spikeR:SetAnchor(LEFT, c, RIGHT, spikeOff, 0)

    local padX = spikeOff + spikeLen + 6
    self.dragPadX = padX
    c:SetHitInsets(-padX, -DRAG_PAD_Y, padX, DRAG_PAD_Y)
    local overlay = self.dragOverlay
    overlay:ClearAnchors()
    overlay:SetAnchor(TOPLEFT, c, TOPLEFT, -padX, -DRAG_PAD_Y)
    overlay:SetAnchor(BOTTOMRIGHT, c, BOTTOMRIGHT, padX, DRAG_PAD_Y)

    local point = ANCHOR_POINT[cfg.grow]
    for _, tex in ipairs({ self.gainTex, self.trailTex, self.fillTex }) do
        tex:ClearAnchors()
        tex:SetAnchor(point, self.track, point, 0, 0)
    end

    self.spikeL:SetHidden(cfg.spikeL == false)
    self.spikeR:SetHidden(cfg.spikeR == false)

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

    local mode = RB.sv.text
    if mode ~= TEXT_NONE then self:SetText(FormatText(mode, cur, max)) end

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

function Bar:SetText(text)
    if text ~= self.text then
        self.text = text
        self.valueLabel:SetText(text)
    end
end

function Bar:ApplyTextMode(mode)
    local visible = mode ~= TEXT_NONE
    self.valueLabel:SetHidden(not visible)
    if visible then self:SetText(FormatText(mode, self.cur, self.max)) end
end

-- Module ---------------------------------------------------------------------
function RB:Initialize(sv)
    self.sv = sv.bars
    self.inCombat = IsUnitInCombat("player")
    self.unlocked = false
    if type(self.sv.points) ~= "table" then self.sv.points = {} end
    -- 0.3 and older: showNumbers boolean -> text mode.
    if self.sv.showNumbers ~= nil then
        self.sv.text = self.sv.showNumbers and TEXT_VALUE or TEXT_NONE
        self.sv.showNumbers = nil
    end
    if not TEXT_VALID[self.sv.text] then self.sv.text = TEXT_NONE end
    self.sv.width = zo_clamp(zo_round(tonumber(self.sv.width) or WIDTH_DEFAULT), WIDTH_MIN, WIDTH_MAX)
    self.sv.height = zo_clamp(zo_round(tonumber(self.sv.height) or HEIGHT_DEFAULT), HEIGHT_MIN, HEIGHT_MAX)

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

    tl:SetHandler("OnMouseDown", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then self:BeginGroupDrag() end
    end)
    tl:SetHandler("OnMouseUp", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then self:EndDrag() end
    end)

    for _, bar in pairs(self.bars) do
        local c = bar.control
        c:SetHandler("OnMouseDown", function(_, button)
            if button == MOUSE_BUTTON_INDEX_LEFT then self:BeginDrag(bar) end
        end)
        c:SetHandler("OnMouseUp", function(_, button)
            if button == MOUSE_BUTTON_INDEX_LEFT then self:EndDrag() end
        end)
    end

    if not LAYOUTS[self.sv.layout] then self.sv.layout = "columns" end
    self:ApplyLayout()
    self:ApplyPosition()
    self:HideDefaultBars()

    local fragment = ZO_HUDFadeSceneFragment:New(tl)
    self.fragment = fragment
    HUD_SCENE:AddFragment(fragment)
    HUD_UI_SCENE:AddFragment(fragment)

    self:RegisterEvents()
    self:ApplyText()
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
RB.TEXT_ORDER = TEXT_ORDER
RB.WIDTH_MIN, RB.WIDTH_MAX, RB.WIDTH_DEFAULT = WIDTH_MIN, WIDTH_MAX, WIDTH_DEFAULT
RB.HEIGHT_MIN, RB.HEIGHT_MAX, RB.HEIGHT_DEFAULT = HEIGHT_MIN, HEIGHT_MAX, HEIGHT_DEFAULT

-- Effective bar height: the configured height, but tall enough for text.
function RB:GetBarHeight()
    local bh = self.sv.height
    if self.sv.text ~= TEXT_NONE and bh < BAR_HEIGHT_TEXT then bh = BAR_HEIGHT_TEXT end
    return bh
end

local geo = { bh = 0, hw = 0, gap = 0, pad = 0 } -- reused, no garbage per relayout

function RB:ApplyLayout()
    local layout = LAYOUTS[self.sv.layout] or LAYOUTS.default
    local tl = self.topLevel
    local h, m, s = self.bars[H], self.bars[M], self.bars[S]
    local bh = self:GetBarHeight()
    local hw, mw, sw = layout.Widths(self.sv.width)
    local spikeOff, spikeLen = SpikeGeometry(bh)
    local overhang = spikeOff + spikeLen
    geo.bh, geo.hw, geo.gap, geo.pad = bh, hw, overhang * 2 + 8, overhang * 2 + 14

    local widths = { [H] = hw, [M] = mw, [S] = sw }
    for powerType, bar in pairs(self.bars) do
        bar.control:ClearAnchors()
        bar:ApplyLayout(layout.bars[powerType], widths[powerType], bh)
    end
    layout.Anchor(tl, h.control, m.control, s.control, geo)
    tl:SetDimensions(layout.Size(geo))
    self.layoutCfg = layout

    -- The unmoved group's default spot depends on layout and bar size.
    if not self.sv.point then self:ApplyPosition() end

    -- Default layout: bars the player has moved sit at their own saved spot.
    if layout.separate then
        local points = self.sv.points
        for _, bar in pairs(self.bars) do
            local p = points[bar.style.key]
            if p then
                bar.control:ClearAnchors()
                bar.control:SetAnchor(CENTER, GuiRoot, TOPLEFT, p.x, p.y)
            end
        end
    end

    -- Buff icons follow the layout (no-op until the Buffs module is ready).
    if AUI.Buffs then AUI.Buffs:ApplyPlacement() end
end

function RB:IsSeparateLayout()
    local layout = LAYOUTS[self.sv.layout] or LAYOUTS.default
    return layout.separate == true
end

function RB:SetLayout(name)
    if not LAYOUTS[name] then return false end
    if self.sv.layout ~= name then
        self:EndDrag()
        self.sv.layout = name
        self:ApplyLayout()
        if self.unlocked then self:ApplyDragMode() end
    end
    return true
end

function RB:SetAlwaysShow(always)
    self.sv.alwaysShow = always
    self:WakeAll()
end

function RB:SetTextMode(mode)
    if not TEXT_VALID[mode] then return false end
    local old = self.sv.text
    if old == mode then return true end
    local oldHeight = self:GetBarHeight()
    self.sv.text = mode
    -- Relayout only if the effective height changed (text on/off on a thin bar).
    if self:GetBarHeight() ~= oldHeight then self:ApplyLayout() end
    self:ApplyText()
    return true
end

-- Bar size. Values are clamped; nothing happens when the value is unchanged.
-- Returns the applied value, or nil for non-numeric input.
function RB:SetBarWidth(width)
    width = tonumber(width)
    if not width then return nil end
    width = zo_clamp(zo_round(width), WIDTH_MIN, WIDTH_MAX)
    if self.sv.width ~= width then
        self:EndDrag()
        self.sv.width = width
        self:ApplyLayout()
    end
    return width
end

function RB:SetBarHeight(height)
    height = tonumber(height)
    if not height then return nil end
    height = zo_clamp(zo_round(height), HEIGHT_MIN, HEIGHT_MAX)
    if self.sv.height ~= height then
        local oldHeight = self:GetBarHeight()
        self.sv.height = height
        if self:GetBarHeight() ~= oldHeight then
            self:EndDrag()
            self:ApplyLayout()
        end
    end
    return height
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
    local layout = self.layoutCfg
    if p then
        tl:SetAnchor(CENTER, GuiRoot, TOPLEFT, p.x, p.y)
    elseif layout and layout.DefaultAnchor then
        layout.DefaultAnchor(tl, geo)
    elseif ZO_PlayerAttribute then
        tl:SetAnchor(CENTER, ZO_PlayerAttribute, CENTER, 0, 0)
    else
        tl:SetAnchor(BOTTOM, GuiRoot, BOTTOM, 0, -110)
    end
end

function RB:ResetPosition()
    self:EndDrag()
    self.sv.point = nil
    ZO_ClearTable(self.sv.points)
    self:ApplyLayout() -- also re-applies the default position
end

-- Dragging ---------------------------------------------------------------------
-- One code path for both modes, driven by GetUIMousePosition and anchored to
-- GuiRoot TOPLEFT. (The native movable top-level was dropped: it kept the
-- group's original anchor to ZO_PlayerAttribute and its screen clamp, which
-- pinned the group to the screen bottom while dragging.)
--   default layout : drag target is one bar, saved to sv.points[key]
--   other layouts  : drag target is the whole top-level, saved to sv.point
-- The poll runs only while the mouse button is held and skips frames where the
-- cursor has not moved.
local drag = { control = nil, padX = 0, padY = 0, key = nil, dx = 0, dy = 0, mx = 0, my = 0 }

local function MoveDragged(force)
    local mx, my = GetUIMousePosition()
    if not force and mx == drag.mx and my == drag.my then return end
    drag.mx, drag.my = mx, my

    local c = drag.control
    local sw, sh = GuiRoot:GetDimensions()
    local hw, hh = c:GetWidth() / 2 + drag.padX, c:GetHeight() / 2 + drag.padY
    local x = zo_clamp(mx + drag.dx, hw, sw - hw)
    local y = zo_clamp(my + drag.dy, hh, sh - hh)
    c:ClearAnchors()
    c:SetAnchor(CENTER, GuiRoot, TOPLEFT, x, y)
    return x, y
end

local function OnDragUpdate()
    MoveDragged(false)
end

local function StartDrag(control, padX, padY, key)
    local cx, cy = control:GetCenter()
    local mx, my = GetUIMousePosition()
    drag.control, drag.padX, drag.padY, drag.key = control, padX, padY, key
    drag.dx, drag.dy, drag.mx, drag.my = cx - mx, cy - my, mx, my
    EM:RegisterForUpdate(DRAG_NAME, 0, OnDragUpdate)
end

function RB:BeginDrag(bar)
    if drag.control or not (self.unlocked and self:IsSeparateLayout()) then return end
    StartDrag(bar.control, bar.dragPadX, DRAG_PAD_Y, bar.style.key)
end

function RB:BeginGroupDrag()
    if drag.control or not self.unlocked or self:IsSeparateLayout() then return end
    StartDrag(self.topLevel, 0, 0, nil)
end

function RB:EndDrag()
    if not drag.control then return end
    EM:UnregisterForUpdate(DRAG_NAME)
    local x, y = MoveDragged(true)
    local key = drag.key
    drag.control, drag.key = nil, nil
    if key then
        self.sv.points[key] = { x = x, y = y }
    else
        self.sv.point = { x = x, y = y }
    end
end

-- Switch mouse handling between per-bar and group dragging.
function RB:ApplyDragMode()
    local unlocked = self.unlocked
    local separate = self:IsSeparateLayout()
    local group = unlocked and not separate
    local perBar = unlocked and separate

    local tl = self.topLevel
    tl:SetMouseEnabled(group)
    tl:GetNamedChild("DragOverlay"):SetHidden(not group)
    tl:GetNamedChild("DragLabel"):SetHidden(not group)

    for _, bar in pairs(self.bars) do
        bar.control:SetMouseEnabled(perBar)
        bar.dragOverlay:SetHidden(not perBar)
        bar.dragLabel:SetHidden(not perBar)
    end
end

function RB:SetUnlocked(unlocked)
    if not unlocked then self:EndDrag() end
    self.unlocked = unlocked
    self:ApplyDragMode()
    self:WakeAll()
end

function RB:ApplyText()
    local mode = self.sv.text
    for _, bar in pairs(self.bars) do bar:ApplyTextMode(mode) end
end

function RB:HandleCommand(cmd, rest)
    if cmd == "unlock" then
        self:SetUnlocked(true)
        if self:IsSeparateLayout() then
            AUI:Print("bars unlocked. Drag each bar, then /aether lock")
        else
            AUI:Print("bars unlocked. Drag the group, then /aether lock")
        end
    elseif cmd == "lock" then
        self:SetUnlocked(false)
        AUI:Print("bars locked.")
    elseif cmd == "reset" then
        self:ResetPosition()
        AUI:Print("bar position reset.")
    elseif cmd == "numbers" then
        self:SetTextMode(self.sv.text == TEXT_NONE and TEXT_VALUE or TEXT_NONE)
        AUI:Print("text: " .. self.sv.text)
    elseif cmd == "text" then
        if self:SetTextMode(rest) then
            AUI:Print("text: " .. rest)
        else
            AUI:Print("text modes: " .. table.concat(TEXT_ORDER, " | "))
        end
    elseif cmd == "always" then
        self:SetAlwaysShow(not self.sv.alwaysShow)
        AUI:Print("always show " .. (self.sv.alwaysShow and "on" or "off"))
    elseif cmd == "width" then
        local w = self:SetBarWidth(rest)
        if w then
            AUI:Print("bar width: " .. w)
        else
            AUI:Print(sfmt("bar width: %d (%d-%d)", self.sv.width, WIDTH_MIN, WIDTH_MAX))
        end
    elseif cmd == "height" then
        local h = self:SetBarHeight(rest)
        if h then
            AUI:Print("bar height: " .. h)
        else
            AUI:Print(sfmt("bar height: %d (%d-%d)", self.sv.height, HEIGHT_MIN, HEIGHT_MAX))
        end
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
