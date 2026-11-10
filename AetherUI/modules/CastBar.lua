-- AetherUI / CastBar
-- Player cast / channel bar (LUI style): ability icon on the left, ability
-- name inside the bar on the left, time left on the right. Casts fill up,
-- channels drain. Same Skyrim bar art as the player bars, in gold.
--
-- Detection (ported from LuiExtended's cast bar, trimmed):
--   * start: player combat events BEGIN / BEGIN_CHANNEL (casts) and
--     EFFECT_GAINED / EFFECT_GAINED_DURATION (channels), duration from
--     GetAbilityCastInfo() plus the fixes in CastBarData
--   * stop: time up, channel effect faded, new cast, roll dodge / bash,
--     hard crowd control on the player, block, weapon swap, moving during
--     a recall, zoning
--   * soul gem resurrection is shown too
--
-- Performance:
--   * every combat event registration is filtered natively by result (and
--     source / target / ability id), so damage and heal ticks never reach Lua
--   * the fill is a native size animation: no Lua per frame while casting
--   * one 50 ms poll (time text, block / movement checks) that exists only
--     while a cast is shown; idle cost is zero
--   * time text is formatted only when the shown tenth changes
--   * disabled = no events registered at all

local AUI = AetherUI
local EM = EVENT_MANAGER
local Data = AUI.CastBarData

local GetFrameTimeMilliseconds = GetFrameTimeMilliseconds
local GetAbilityCastInfo = GetAbilityCastInfo
local GetAbilityIcon = GetAbilityIcon
local GetAbilityName = GetAbilityName
local IsBlockActive = IsBlockActive
local IsPlayerMoving = IsPlayerMoving
local IsPlayerStunned = IsPlayerStunned
local zo_strformat = zo_strformat
local sfmt = string.format
local mceil, mmax, mmin = math.ceil, math.max, math.min

local NAME = "AetherUI_CastBar"
local TICK_NAME = NAME .. "Tick"

local WIDTH_MIN, WIDTH_MAX, WIDTH_DEFAULT = 150, 600, 300
local HEIGHT_MIN, HEIGHT_MAX, HEIGHT_DEFAULT = 18, 40, 22
local ICON_EXTRA = 10           -- icon is this much taller than the bar
local ICON_GAP = 4              -- icon -> left cap
local TEXT_PAD = 8
local DRAG_PAD_Y = 10
local TICK_MS = 50
local ACTIVATE_SUPPRESS_MS = 2000 -- ignore effect replays right after zoning
local MIN_CHANNEL_MS = 1000

local PLACEHOLDER_NAME = "Cast bar"
local PLACEHOLDER_ICON = "EsoUI/Art/Icons/icon_missing.dds"
local SOUL_GEM_ICON = "EsoUI/Art/Icons/achievement_frostvault_death_challenge.dds"
local SOUL_GEM_NAME = "Soul Gem Resurrection"
local RECALL_ID = 6811

local BEGIN = ACTION_RESULT_BEGIN
local BEGIN_CHANNEL = ACTION_RESULT_BEGIN_CHANNEL
local GAINED = ACTION_RESULT_EFFECT_GAINED
local GAINED_DURATION = ACTION_RESULT_EFFECT_GAINED_DURATION
local FADED = ACTION_RESULT_EFFECT_FADED

-- Results that may start (or end) a cast. One native-filtered registration each.
local START_RESULTS = { BEGIN, BEGIN_CHANNEL, GAINED, GAINED_DURATION, FADED }
-- Hard crowd control on the player cancels the cast.
local BREAK_RESULTS = {
    ACTION_RESULT_STAGGERED, ACTION_RESULT_STUNNED, ACTION_RESULT_KNOCKBACK,
    ACTION_RESULT_LEVITATED, ACTION_RESULT_FEARED, ACTION_RESULT_DISORIENTED,
    ACTION_RESULT_CHARMED,
}

local HEAVY_SLOT = 2
local BAR_CFG = { grow = "left", spikeL = false }

local IS_HEAVY, IS_CAST, IGNORE = Data.IsHeavy, Data.IsCast, Data.Ignore
local DURATION_FIX, DISPLAY_DELAY = Data.DurationFix, Data.DisplayDelay
local CHANNEL_CONVERT, CHANNEL_TRACK = Data.ChannelConvert, Data.ChannelTrack
local BREAK_ON_MOVE, IGNORE_BREAK, IGNORE_STUN = Data.BreakOnMove, Data.IgnoreBreak, Data.IgnoreStun

-- Slotted ids started from a ChannelTrack buff (their own GAINED is skipped).
local TRACKED_SLOTTED = {}
for _, t in pairs(CHANNEL_TRACK) do TRACKED_SLOTTED[t.slottedId] = true end

local function C(hex, a)
    local c = ZO_ColorDef:New(hex)
    if a then c:SetAlpha(a) end
    return c
end

-- Gold, the addon's accent colour.
local STYLE_CAST = {
    key = "Cast bar", grow = "left",
    top = C("E8C36A"), bottom = C("7A5414"), gain = C("F2DC9E", 0.45), warn = C("FFD86A"),
}
local BEVEL_TOP, BEVEL_BOTTOM = C("8E7752"), C("2B2217")

local function SetGradient(tex, top, bottom)
    tex:SetColor(1, 1, 1, 1)
    local r, g, b, a = top:UnpackRGBA()
    tex:SetVertexColors(VERTEX_POINTS_TOPLEFT + VERTEX_POINTS_TOPRIGHT, r, g, b, a)
    r, g, b, a = bottom:UnpackRGBA()
    tex:SetVertexColors(VERTEX_POINTS_BOTTOMLEFT + VERTEX_POINTS_BOTTOMRIGHT, r, g, b, a)
end

-- Input lag padding, as LUI does it (half the ping, capped).
local function InputLag()
    return mmin(mmax(GetLatency() * 0.5 - 1, 0), 48)
end

local CastBar = {
    ready = false,
    registered = false,
    casting = false,
    shown = false,
    unlocked = false,
    preview = false,
    placeholder = false,
    id = 0,              -- ability id being shown (0 = soul gem / none)
    channeled = false,
    starts = 0, ends = 0,
    tenths = -1,         -- last time text shown, in tenths of a second
    blockAtStart = false,
    blockReleased = false,
    suppressUntil = 0,
    weaponPair = nil,
}
AUI.CastBar = CastBar

CastBar.WIDTH_MIN, CastBar.WIDTH_MAX, CastBar.WIDTH_DEFAULT = WIDTH_MIN, WIDTH_MAX, WIDTH_DEFAULT
CastBar.HEIGHT_MIN, CastBar.HEIGHT_MAX, CastBar.HEIGHT_DEFAULT = HEIGHT_MIN, HEIGHT_MAX, HEIGHT_DEFAULT

function CastBar:Initialize(sv)
    local s = sv.castBar
    if type(s) ~= "table" then s = {}; sv.castBar = s end
    if s.enabled == nil then s.enabled = true end
    if s.heavy == nil then s.heavy = false end
    if s.label == nil then s.label = true end
    if s.timer == nil then s.timer = true end
    s.width = zo_clamp(zo_round(tonumber(s.width) or WIDTH_DEFAULT), WIDTH_MIN, WIDTH_MAX)
    s.height = zo_clamp(zo_round(tonumber(s.height) or HEIGHT_DEFAULT), HEIGHT_MIN, HEIGHT_MAX)
    if type(s.point) ~= "table" or not (tonumber(s.point.x) and tonumber(s.point.y)) then s.point = nil end
    self.sv = s

    local RB = AUI.ResourceBars
    local tl = AetherUI_CastBar
    local frame = tl:GetNamedChild("Frame")
    self.topLevel, self.frame = tl, frame

    -- Ability icon (same frame as the buff icons, bronze bevel).
    local icon = CreateControlFromVirtual(NAME .. "Icon", frame, "AetherUI_BuffIcon")
    icon:SetHidden(false)
    SetGradient(icon:GetNamedChild("Bevel"), BEVEL_TOP, BEVEL_BOTTOM)
    icon:GetNamedChild("Time"):SetHidden(true)
    icon:GetNamedChild("Stack"):SetHidden(true)
    icon:SetAnchor(LEFT, frame, LEFT, 0, 0)
    self.icon, self.iconTex, self.iconPath = icon, icon:GetNamedChild("Icon"), nil

    -- Bar: shared art, the fill is driven by our own animation.
    local bar = RB:CreateBar(frame, nil, "player", NAME .. "Bar", STYLE_CAST)
    self.bar, self.fill = bar, bar.fillTex

    -- Value label = time left, right end. Own label = ability name, left end.
    local timer = bar.valueLabel
    timer:ClearAnchors()
    timer:SetAnchor(RIGHT, bar.track, RIGHT, -TEXT_PAD, 1)
    timer:SetHorizontalAlignment(TEXT_ALIGN_RIGHT)
    timer:SetColor(0.96, 0.92, 0.85, 1)
    self.timer = timer

    local label = WINDOW_MANAGER:CreateControl(NAME .. "Name", bar.control, CT_LABEL)
    label:SetFont("$(BOLD_FONT)|14|soft-shadow-thick")
    label:SetColor(0.96, 0.92, 0.85, 1)
    label:SetHorizontalAlignment(TEXT_ALIGN_LEFT)
    label:SetVerticalAlignment(TEXT_ALIGN_CENTER)
    label:SetMaxLineCount(1)
    label:SetWrapMode(TEXT_WRAP_MODE_ELLIPSIS)
    label:SetDrawLevel(16)
    label:SetAnchor(LEFT, bar.track, LEFT, TEXT_PAD, 1)
    label:SetAnchor(RIGHT, timer, LEFT, -TEXT_PAD, 0)
    self.nameLabel, self.nameText = label, nil

    -- Native fill animation (falls back to a per-frame width update).
    if ANIMATION_SIZE then
        local timeline = ANIMATION_MANAGER:CreateTimeline()
        self.anim = timeline:InsertAnimation(ANIMATION_SIZE, self.fill)
        self.timeline = timeline
    end

    -- Drag (unlock mode).
    self.savePoint = function(x, y)
        self.sv.point = { x = x, y = y }
        self:ApplyPosition()
    end
    bar.control:SetHandler("OnMouseDown", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then RB:BeginFreeDrag(tl, 0, DRAG_PAD_Y, self.savePoint) end
    end)
    bar.control:SetHandler("OnMouseUp", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then RB:EndDrag() end
    end)

    local fragment = ZO_HUDFadeSceneFragment:New(tl)
    self.fragment = fragment
    HUD_SCENE:AddFragment(fragment)
    HUD_UI_SCENE:AddFragment(fragment)
    -- Siege weapons have their own HUD scenes (packing siege is a cast too).
    for _, name in ipairs({ "siegeBar", "siegeBarUI" }) do
        local scene = SCENE_MANAGER:GetScene(name)
        if scene then scene:AddFragment(fragment) end
    end

    self:CreateHandlers()

    self.ready = true
    self:ApplyLayout()
    self:ApplyPosition()
    self:ApplyText()
    self:ApplyEnabled()
end

-- Event handlers (closures made once) ---------------------------------------------
function CastBar:CreateHandlers()
    self.onTick = function() self:Tick() end

    -- EVENT_COMBAT_EVENT: (_, result, isError, abilityName, graphic, slotType,
    -- sourceName, sourceType, targetName, targetType, hitValue, powerType,
    -- damageType, log, sourceUnitId, targetUnitId, abilityId)
    self.onStart = function(_, result, _, _, _, _, _, _, _, _, hitValue, _, _, _, _, _, abilityId)
        self:OnCombatStart(result, hitValue, abilityId)
    end
    self.onBreakAction = function()
        if self.casting and not IGNORE_BREAK[self.id] then self:Stop() end
    end
    self.onCrowdControl = function(_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, abilityId)
        if self.casting and not IGNORE_STUN[abilityId] and not IGNORE_BREAK[self.id] then self:Stop() end
    end
    self.onEffect = function(_, changeType)
        if changeType == EFFECT_RESULT_FADED and self.casting then self:Stop() end
    end
    self.onSlotUsed = function(_, slot)
        if slot == HEAVY_SLOT and self.casting then self:Stop() end
    end
    self.onSoulGemStart = function(_, durationMs)
        self:Show(0, GetFrameTimeMilliseconds(), durationMs or 0, false, SOUL_GEM_ICON, SOUL_GEM_NAME)
    end
    self.onSoulGemEnd = function() self:Stop() end
    self.onWeaponPair = function(_, pair)
        if pair == ACTIVE_WEAPON_PAIR_NONE then return end
        local old = self.weaponPair
        self.weaponPair = pair
        if old and old ~= pair and self.casting then self:Stop() end
    end
    self.onActivated = function()
        self:Stop()
        self.suppressUntil = GetFrameTimeMilliseconds() + ACTIVATE_SUPPRESS_MS
        local pair = GetActiveWeaponPairInfo()
        self.weaponPair = (pair and pair ~= ACTIVE_WEAPON_PAIR_NONE) and pair or nil
    end
    self.onDeactivated = function() self:Stop() end
end

-- Not a hot path: enable toggle only.
function CastBar:SetRegistered(on)
    if on == self.registered then return end
    self.registered = on
    local ns

    for i, result in ipairs(START_RESULTS) do
        ns = NAME .. "Start" .. i
        if on then
            EM:RegisterForEvent(ns, EVENT_COMBAT_EVENT, self.onStart)
            EM:AddFilterForEvent(ns, EVENT_COMBAT_EVENT,
                REGISTER_FILTER_COMBAT_RESULT, result,
                REGISTER_FILTER_SOURCE_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER,
                REGISTER_FILTER_IS_ERROR, false)
        else
            EM:UnregisterForEvent(ns, EVENT_COMBAT_EVENT)
        end
    end

    for i, result in ipairs(BREAK_RESULTS) do
        ns = NAME .. "CC" .. i
        if on then
            EM:RegisterForEvent(ns, EVENT_COMBAT_EVENT, self.onCrowdControl)
            EM:AddFilterForEvent(ns, EVENT_COMBAT_EVENT,
                REGISTER_FILTER_COMBAT_RESULT, result,
                REGISTER_FILTER_TARGET_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER,
                REGISTER_FILTER_IS_ERROR, false)
        else
            EM:UnregisterForEvent(ns, EVENT_COMBAT_EVENT)
        end
    end

    for abilityId in pairs(Data.BreakingActions) do
        ns = NAME .. "Action" .. abilityId
        if on then
            EM:RegisterForEvent(ns, EVENT_COMBAT_EVENT, self.onBreakAction)
            EM:AddFilterForEvent(ns, EVENT_COMBAT_EVENT,
                REGISTER_FILTER_ABILITY_ID, abilityId,
                REGISTER_FILTER_SOURCE_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER)
        else
            EM:UnregisterForEvent(ns, EVENT_COMBAT_EVENT)
        end
    end

    for abilityId in pairs(Data.BreakOnEffectFaded) do
        ns = NAME .. "Effect" .. abilityId
        if on then
            EM:RegisterForEvent(ns, EVENT_EFFECT_CHANGED, self.onEffect)
            EM:AddFilterForEvent(ns, EVENT_EFFECT_CHANGED,
                REGISTER_FILTER_ABILITY_ID, abilityId,
                REGISTER_FILTER_UNIT_TAG, "player")
        else
            EM:UnregisterForEvent(ns, EVENT_EFFECT_CHANGED)
        end
    end

    local simple = {
        { EVENT_ACTION_SLOT_ABILITY_USED, self.onSlotUsed },
        { EVENT_START_SOUL_GEM_RESURRECTION, self.onSoulGemStart },
        { EVENT_END_SOUL_GEM_RESURRECTION, self.onSoulGemEnd },
        { EVENT_ACTIVE_WEAPON_PAIR_CHANGED, self.onWeaponPair },
        { EVENT_PLAYER_ACTIVATED, self.onActivated },
        { EVENT_PLAYER_DEACTIVATED, self.onDeactivated },
    }
    for i, e in ipairs(simple) do
        ns = NAME .. "Ev" .. i
        if on then EM:RegisterForEvent(ns, e[1], e[2]) else EM:UnregisterForEvent(ns, e[1]) end
    end
end

-- Detection -------------------------------------------------------------------------
function CastBar:ShouldShow(abilityId, channeled, castTime)
    if IGNORE[abilityId] then return false end
    if IS_HEAVY[abilityId] and not self.sv.heavy then return false end
    if IS_CAST[abilityId] or channeled or (castTime or 0) > 0 then return true end
    return DURATION_FIX[abilityId] ~= nil or CHANNEL_CONVERT[abilityId] ~= nil
end

local function Duration(abilityId, result, hitValue, channeled, castTime)
    local fix = DURATION_FIX[abilityId]
    local d
    if channeled then
        d = fix or (result == GAINED_DURATION and hitValue or 0)
    else
        d = fix or castTime or 0
        if d <= 0 and result == BEGIN and (hitValue or 0) > 0 then d = hitValue end
    end
    if d <= 0 then return 0 end
    if channeled and not fix and d < MIN_CHANNEL_MS then d = MIN_CHANNEL_MS end
    return d + (DISPLAY_DELAY[abilityId] or 0) + InputLag()
end

function CastBar:OnCombatStart(result, hitValue, abilityId)
    -- Channel buff that ticks GAINED every hit: start once from its slotted id.
    local track = CHANNEL_TRACK[abilityId]
    if track then
        if result == FADED then
            if self.casting and self.id == track.slottedId then self:Stop() end
        elseif (result == GAINED or result == GAINED_DURATION) and not self.casting then
            self:Show(track.slottedId, GetFrameTimeMilliseconds(), track.durationMs + InputLag(), true)
        end
        return
    end

    if result == FADED then
        -- Channel ended early (or on time): only the one being shown.
        if self.casting and self.channeled and self.id == abilityId then self:Stop() end
        return
    end

    local channeled, castTime = GetAbilityCastInfo(abilityId)
    if not self:ShouldShow(abilityId, channeled, castTime) then return end

    local gain = result == GAINED or result == GAINED_DURATION
    if CHANNEL_CONVERT[abilityId] then
        -- Cast-time ability shown as a channel, started by its BEGIN.
        if result ~= BEGIN then return end
        channeled = true
    elseif channeled or DURATION_FIX[abilityId] then
        if not gain or (channeled and TRACKED_SLOTTED[abilityId]) then return end
    elseif result ~= BEGIN and result ~= BEGIN_CHANNEL then
        return
    end

    local duration = Duration(abilityId, result, hitValue, channeled, castTime)
    if duration > 0 then
        self:Show(abilityId, GetFrameTimeMilliseconds(), duration, channeled)
    end
end

-- Show / stop -------------------------------------------------------------------------
function CastBar:SetIcon(path)
    if path ~= self.iconPath then
        self.iconPath = path
        self.iconTex:SetTexture(path)
    end
end

function CastBar:SetName(text)
    if text ~= self.nameText then
        self.nameText = text
        self.nameLabel:SetText(text)
    end
end

function CastBar:Show(abilityId, now, duration, channeled, icon, name)
    if duration <= 0 then return end
    if abilityId ~= 0 and now < self.suppressUntil then return end
    -- GAINED and GAINED_DURATION of one channel arrive together: keep the first.
    if self.casting and channeled and self.id == abilityId and now < self.ends then return end

    if not icon then
        icon = GetAbilityIcon(abilityId)
        name = zo_strformat(SI_ABILITY_NAME, GetAbilityName(abilityId))
    end

    self.casting = true
    self.placeholder = false
    self.id, self.channeled = abilityId, channeled
    self.starts, self.ends = now, now + duration
    self.tenths = -1
    self.blockAtStart, self.blockReleased = IsBlockActive(), false

    self:SetIcon(icon)
    self:SetName(name)

    -- Casts fill up, channels drain.
    local w, h = self.width, self.barHeight
    local from, to = 0, w
    if channeled then from, to = w, 0 end
    if self.timeline then
        self.timeline:Stop()
        local anim = self.anim
        anim:SetDuration(duration)
        anim:SetStartAndEndWidth(from, to)
        anim:SetStartAndEndHeight(h, h)
        self.timeline:PlayFromStart()
    else
        self.fill:SetWidth(from)
    end

    self:Tick(now)
    EM:UnregisterForUpdate(TICK_NAME)
    EM:RegisterForUpdate(TICK_NAME, self.timeline and TICK_MS or 0, self.onTick)
    self:UpdateVisibility()
end

function CastBar:Stop()
    if not self.casting then return end
    self.casting = false
    self.id = 0
    EM:UnregisterForUpdate(TICK_NAME)
    if self.timeline then self.timeline:Stop() end
    self:UpdateVisibility()
end

-- Runs only while a cast is shown.
function CastBar:Tick(now)
    now = now or GetFrameTimeMilliseconds()
    local remain = self.ends - now
    if remain <= 0 then
        self:Stop()
        return
    end

    if not self.timeline then
        local p = (now - self.starts) / (self.ends - self.starts)
        if self.channeled then p = 1 - p end
        self.fill:SetWidth(self.width * p)
    end

    local tenths = mceil(remain / 100)
    if tenths ~= self.tenths then
        self.tenths = tenths
        if self.sv.timer then self.bar:SetText(sfmt("%.1f", tenths / 10)) end
    end

    local id = self.id
    if id == 0 or IGNORE_BREAK[id] then return end

    -- Block cancels the cast. Casts started while blocking get one grace:
    -- releasing and blocking again cancels.
    if not IsPlayerStunned() then
        local block = IsBlockActive()
        if self.blockAtStart then
            if not block then
                self.blockReleased = true
            elseif self.blockReleased then
                self:Stop()
                return
            end
        elseif block then
            self:Stop()
            return
        end
    end

    if BREAK_ON_MOVE[id] and IsPlayerMoving() then self:Stop() end
end

-- Visibility / placeholder ---------------------------------------------------------
function CastBar:UpdateVisibility()
    local placeholder = not self.casting and (self.unlocked or self.preview)
    local show = self.sv.enabled and (self.casting or placeholder) or false
    if show and placeholder and not self.placeholder then
        self.placeholder = true
        if self.timeline then self.timeline:Stop() end
        self.fill:SetWidth(self.width * 0.6)
        local icon = GetAbilityIcon(RECALL_ID)
        self:SetIcon((icon and icon ~= "") and icon or PLACEHOLDER_ICON)
        self:SetName(PLACEHOLDER_NAME)
        self.tenths = -1
        self.bar:SetText("1.5")
    end
    if show ~= self.shown then
        self.shown = show
        self.frame:SetHidden(not show)
    end
end

-- Layout / text / position (not hot paths) ----------------------------------------
function CastBar:ApplyLayout()
    if not self.ready then return end
    local RB = AUI.ResourceBars
    local w, bh = self.sv.width, self.sv.height
    local iconSize = bh + ICON_EXTRA
    -- Left cap is a diamond (rotated square) centred bh * 0.3 outside the bar.
    local capExt = zo_round(bh * 0.3) + mceil(bh * 0.71)
    self.width, self.barHeight = w, bh

    self.icon:SetDimensions(iconSize, iconSize)
    local bar = self.bar
    bar.control:ClearAnchors()
    bar.control:SetAnchor(LEFT, self.icon, RIGHT, ICON_GAP + capExt, 0)
    bar:ApplyLayout(BAR_CFG, w, bh)

    self.topLevel:SetDimensions(iconSize + ICON_GAP + capExt + w + RB.Overhang(bh), mmax(iconSize, bh))

    -- Resized mid-cast: the running animation keeps going with the old width;
    -- the placeholder is redrawn at the new one.
    if self.placeholder then
        self.placeholder = false
        self:UpdateVisibility()
    elseif not self.casting then
        self.fill:SetWidth(0)
    end
end

function CastBar:ApplyText()
    if not self.ready then return end
    self.nameLabel:SetHidden(not self.sv.label)
    local timer = self.timer
    timer:SetHidden(not self.sv.timer)
    self.nameLabel:ClearAnchors()
    self.nameLabel:SetAnchor(LEFT, self.bar.track, LEFT, TEXT_PAD, 1)
    if self.sv.timer then
        self.nameLabel:SetAnchor(RIGHT, timer, LEFT, -TEXT_PAD, 0)
        self.tenths = -1 -- redraw on the next tick
    else
        self.nameLabel:SetAnchor(RIGHT, self.bar.track, RIGHT, -TEXT_PAD, 1)
    end
end

-- Default: LUI's cast bar spot, centred 320 px below the screen centre.
function CastBar:ApplyPosition()
    if not self.ready then return end
    local tl = self.topLevel
    tl:ClearAnchors()
    local p = self.sv.point
    if p then
        tl:SetAnchor(CENTER, GuiRoot, TOPLEFT, p.x, p.y)
    else
        tl:SetAnchor(CENTER, GuiRoot, CENTER, 0, 320)
    end
end

function CastBar:ResetPosition()
    if not self.ready then return end
    self.sv.point = nil
    self:ApplyPosition()
end

-- Settings ----------------------------------------------------------------------------
function CastBar:ApplyEnabled()
    local on = self.sv.enabled
    self:SetRegistered(on)
    if not on then self:Stop() end
    self.bar.control:SetMouseEnabled(on and self.unlocked)
    self:UpdateVisibility()
end

function CastBar:SetEnabled(enabled)
    enabled = enabled and true or false
    if self.sv.enabled == enabled then return end
    self.sv.enabled = enabled
    self:ApplyEnabled()
end

function CastBar:SetHeavy(enabled)
    self.sv.heavy = enabled and true or false
    if not enabled and self.casting and IS_HEAVY[self.id] then self:Stop() end
end

function CastBar:SetShowLabel(enabled)
    self.sv.label = enabled and true or false
    self:ApplyText()
end

function CastBar:SetShowTimer(enabled)
    self.sv.timer = enabled and true or false
    self:ApplyText()
end

function CastBar:SetWidth(width)
    width = tonumber(width)
    if not width then return nil end
    width = zo_clamp(zo_round(width), WIDTH_MIN, WIDTH_MAX)
    if width ~= self.sv.width then
        self.sv.width = width
        self:ApplyLayout()
    end
    return width
end

function CastBar:SetHeight(height)
    height = tonumber(height)
    if not height then return nil end
    height = zo_clamp(zo_round(height), HEIGHT_MIN, HEIGHT_MAX)
    if height ~= self.sv.height then
        self.sv.height = height
        self:ApplyLayout()
    end
    return height
end

-- Unlock / preview (driven by ResourceBars) --------------------------------------
function CastBar:SetUnlocked(unlocked)
    if not self.ready then return end
    self.unlocked = unlocked
    local bar = self.bar
    bar.control:SetMouseEnabled(unlocked and self.sv.enabled)
    bar.dragOverlay:SetHidden(not unlocked)
    bar.dragLabel:SetHidden(not unlocked)
    self:UpdateVisibility()
end

function CastBar:SetPreview(enabled)
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
function CastBar:HandleCommand(cmd, rest)
    if cmd ~= "castbar" then return false end
    if rest == "on" or rest == "off" then
        self:SetEnabled(rest == "on")
        AUI:Print("cast bar " .. rest)
    elseif rest == "heavy" then
        self:SetHeavy(not self.sv.heavy)
        AUI:Print("cast bar heavy attacks " .. (self.sv.heavy and "on" or "off"))
    else
        AUI:Print("cast bar: " .. (self.sv.enabled and "on" or "off")
            .. ", heavy attacks " .. (self.sv.heavy and "on" or "off")
            .. ". /aether castbar <on|off|heavy>")
    end
    return true
end

AUI:RegisterModule("CastBar", CastBar)
