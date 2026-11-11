-- AetherUI / Group
-- Group and raid frames in the AetherUI bar style. Replaces ESO's group
-- (up to 4) and raid (5-12) frames while enabled.
--
-- One bar per group member, in group order:
--   * small group (up to 4): one column of wide bars
--   * raid (5 and more)   : columns of 4 narrower bars (ESO's Group 1/2/3)
-- Inside each bar: leader crown and name on the left, health text (or
-- Dead / Offline) on the right.
-- Fill colour follows the member's selected role (tank / healer / damage
-- dealer), each colour set in the settings, and changes as soon as the
-- member switches role. Name shows the character name, the account name or
-- both. Out of support range = dimmed, offline = more dimmed.
-- Drag and drop (unlock mode): the whole grid moves as one piece; its
-- top-left corner is saved, so it grows right / down when the group grows.
-- Right-click a member (cursor mode) for the LUI context menu: whisper,
-- visit house, Tales of Tribute invite, travel to player, add friend, kick /
-- disband / leave group, promote to leader.
--
-- Performance:
--   * same Bar class as the player bars: one shared ticker that runs only
--     while something animates, cached widths / text
--   * one registration per event for all members, filtered natively (unit
--     tag prefix "group", health only); handlers are a single table lookup
--   * roster changes (join / leave / reorder / zone) are coalesced into one
--     rebuild on the next frame; the rebuild walks at most the group size
--   * bars are pooled (created on first need, never destroyed) and re-pointed
--     at another member instead of recreated
--   * role colours, names, status, leader and alpha are pushed to the
--     controls only when they change; bars are re-anchored only when the grid
--     changes (small group <-> raid, or new bars)
--   * not grouped = frame hidden, nothing runs; disabled = no events at all
--   * the context menu is built only on right-click; one shared handler for
--     every bar (the slot is stored on the control)
--   * ESO's frames are switched off with their own hide-reason system (no
--     reparenting, nothing per frame) and handed back when disabled

local AUI = AetherUI
local EM = EVENT_MANAGER

local GetGroupSize = GetGroupSize
local GetGroupUnitTagByIndex = GetGroupUnitTagByIndex
local GetGroupMemberSelectedRole = GetGroupMemberSelectedRole
local GetUnitName = GetUnitName
local GetUnitDisplayName = GetUnitDisplayName
local IsUnitOnline = IsUnitOnline
local IsUnitDead = IsUnitDead
local IsUnitGroupLeader = IsUnitGroupLeader
local IsUnitInGroupSupportRange = IsUnitInGroupSupportRange
local zo_strformat = zo_strformat
local AreUnitsEqual = AreUnitsEqual
local DoesUnitExist = DoesUnitExist

local NAME = "AetherUI_Group"
local REBUILD_NAME = NAME .. "Rebuild"
local HIDE_REASON = "AetherUI"
local H = POWERTYPE_HEALTH

local SMALL_MAX = STANDARD_GROUP_SIZE_THRESHOLD or 4 -- above this ESO switches to raid frames
local GRID_SMALL = { key = "small", width = 240, height = 24, perColumn = SMALL_MAX }
local GRID_RAID = { key = "raid", width = 170, height = 20, perColumn = 4 }
local ROW_GAP = 12           -- clears the diamond caps above / below
local COL_GAP = 12           -- between one column's right caps and the next one's left caps
local DEFAULT_X, DEFAULT_Y = 56, 110 -- top-left of the first bar (ESO's group frame spot)
local TEXT_PAD = 6
local NAME_VALUE_GAP = 8
local LEADER_SIZE = 16
local LEADER_ICON = "EsoUI/Art/UnitFrames/groupIcon_leader.dds"
local NAME_FONT = "$(BOLD_FONT)|13|soft-shadow-thick"
local ACCOUNT_COLOR = "A8946A" -- account name in "both" mode, muted gold
local BAR_CFG = { grow = "left", spikeL = false, spikeR = false }

local ALPHA_FULL, ALPHA_FAR, ALPHA_OFFLINE = 1, 0.5, 0.35

local NAME_CHARACTER, NAME_ACCOUNT, NAME_BOTH = "character", "account", "both"
local NAME_ORDER = { NAME_CHARACTER, NAME_ACCOUNT, NAME_BOTH }
local NAME_VALID = { character = true, account = true, both = true }
local TEXT_VALID = { none = true, value = true, percent = true, both = true }

local ROLE_ORDER = { "tank", "healer", "dd" }
local ROLE_BY_LFG = {
    [LFG_ROLE_TANK or 2] = "tank",
    [LFG_ROLE_HEAL or 4] = "healer",
}                            -- anything else (damage dealer, no role) = "dd"
local DEFAULT_COLORS = {
    tank = { r = 0.83, g = 0.29, b = 0.23 },   -- red
    healer = { r = 0.42, g = 0.76, b = 0.29 }, -- green
    dd = { r = 0.60, g = 0.60, b = 0.60 },     -- gray
}

local STATUS_TEXT = { dead = "Dead", offline = "Offline" }
local STATUS_COLOR = { dead = { 0.86, 0.36, 0.30 }, offline = { 0.62, 0.58, 0.52 } }

-- Unlock / preview placeholder: one of each role, so the colours show.
local PLACEHOLDER = {
    { role = "tank", char = "Tank", account = "@Tank", hp = 1, leader = true },
    { role = "healer", char = "Healer", account = "@Healer", hp = 0.8 },
    { role = "dd", char = "Damage dealer", account = "@DamageDealer", hp = 0.55 },
    { role = "dd", char = "Damage dealer", account = "@DamageDealer2", hp = 1 },
}

local Group = {
    ready = false,
    registered = false,
    unlocked = false,
    preview = false,
    shown = false,
    pending = false,
    count = 0,        -- bars currently shown
    grid = nil,       -- GRID_SMALL / GRID_RAID currently laid out
}
AUI.Group = Group
Group.NAME_ORDER = NAME_ORDER
Group.ROLE_ORDER = ROLE_ORDER
Group.DEFAULT_COLORS = DEFAULT_COLORS

local function ValidColor(c)
    return type(c) == "table" and tonumber(c.r) and tonumber(c.g) and tonumber(c.b)
end

function Group:Initialize(sv)
    local s = sv.group
    if type(s) ~= "table" then s = {}; sv.group = s end
    if s.enabled == nil then s.enabled = true end
    if not NAME_VALID[s.name] then s.name = NAME_CHARACTER end
    if not TEXT_VALID[s.text] then s.text = "percent" end
    if type(s.colors) ~= "table" then s.colors = {} end
    for role, def in pairs(DEFAULT_COLORS) do
        if not ValidColor(s.colors[role]) then
            s.colors[role] = { r = def.r, g = def.g, b = def.b }
        end
    end
    if type(s.point) ~= "table" or not (tonumber(s.point.x) and tonumber(s.point.y)) then s.point = nil end
    self.sv = s

    local RB = AUI.ResourceBars
    self.styles = {}
    for _, role in ipairs(ROLE_ORDER) do
        local c = s.colors[role]
        self.styles[role] = RB.MakeStyle("Group", c.r, c.g, c.b)
    end

    local tl = AetherUI_Group
    self.topLevel, self.frame = tl, tl:GetNamedChild("Frame")
    self.dragOverlay, self.dragLabel = tl:GetNamedChild("DragOverlay"), tl:GetNamedChild("DragLabel")
    tl:SetHitInsets(-24, -10, 24, 10)
    self.slots = {}   -- pooled { bar, nameLabel, statusLabel, leaderIcon, tag, ... }
    self.byTag = {}   -- unit tag -> slot, for the member events

    -- Drag (unlock mode): the whole grid; its top-left corner is saved.
    self.savePoint = function(x, y)
        local w, h = tl:GetDimensions()
        self.sv.point = { x = zo_round(x - w / 2), y = zo_round(y - h / 2) }
        self:ApplyPosition()
    end
    tl:SetHandler("OnMouseDown", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then RB:BeginFreeDrag(tl, 24, 10, self.savePoint) end
    end)
    tl:SetHandler("OnMouseUp", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then RB:EndDrag() end
    end)

    local fragment = ZO_HUDFadeSceneFragment:New(tl)
    self.fragment = fragment
    HUD_SCENE:AddFragment(fragment)
    HUD_UI_SCENE:AddFragment(fragment)

    -- Event handlers (one closure each, created once).
    self.onRebuild = function()
        EM:UnregisterForUpdate(REBUILD_NAME)
        self.pending = false
        self:Rebuild()
    end
    self.queueRebuild = function() self:QueueRebuild() end
    self.onPower = function(_, unitTag, _, _, value, _, effectiveMax)
        local slot = self.byTag[unitTag]
        if slot then slot.bar:SetValue(value, effectiveMax) end
    end
    self.onShield = function(_, unitTag, visual)
        if visual ~= ATTRIBUTE_VISUAL_POWER_SHIELDING then return end
        local slot = self.byTag[unitTag]
        if slot then self:RefreshShield(slot) end
    end
    self.onRole = function(_, unitTag)
        if unitTag == "player" and GetLocalPlayerGroupUnitTag then unitTag = GetLocalPlayerGroupUnitTag() end
        local slot = self.byTag[unitTag]
        if slot then self:SetSlotRole(slot, ROLE_BY_LFG[GetGroupMemberSelectedRole(unitTag)] or "dd") end
    end
    self.onStatus = function(_, unitTag)
        local slot = self.byTag[unitTag]
        if slot then self:UpdateStatus(slot) end
    end
    self.onLeader = function()
        for i = 1, self.count do
            local slot = self.slots[i]
            if slot.tag then self:SetSlotLeader(slot, IsUnitGroupLeader(slot.tag)) end
        end
    end

    -- ESO creates group / raid frames lazily; switch each off the moment it exists.
    if UNIT_FRAMES and UNIT_FRAMES.CreateFrame then
        local hook = SecurePostHook or ZO_PostHook
        hook(UNIT_FRAMES, "CreateFrame", function(_, unitTag)
            if self.sv.enabled and unitTag and (ZO_Group_IsGroupUnitTag(unitTag) or IsGroupCompanionUnitTag(unitTag)) then
                local f = UNIT_FRAMES:GetFrame(unitTag)
                if f then f:SetHiddenForReason(HIDE_REASON, true) end
            end
        end)
    end

    self.ready = true
    self:ApplyEnabled()
end

-- ESO's group / raid frames -------------------------------------------------------
function Group:SetDefaultFramesHidden(hidden)
    local UF = UNIT_FRAMES
    if not UF then return end
    for _, list in ipairs({ UF.groupFrames, UF.raidFrames, UF.companionRaidFrames }) do
        if type(list) == "table" then
            for _, f in pairs(list) do f:SetHiddenForReason(HIDE_REASON, hidden) end
        end
    end
    -- "Group 1 / 2 / 3" headers of the raid layout.
    local reasons = UF.groupAndRaidHiddenReasons
    if reasons and reasons.SetHiddenForReason then
        reasons:SetHiddenForReason(HIDE_REASON, hidden)
        if UF.UpdateGroupAnchorFrames then UF:UpdateGroupAnchorFrames() end
    end
end

-- Context menu (LUI) -------------------------------------------------------------------
-- Same entries and rules as LuiExtended's group frames (and ESO's group list).
local function ShowMemberMenu(control, unitTag)
    ClearMenu()
    local isPlayer = AreUnitsEqual(unitTag, "player")
    local isLFG = DoesGroupModificationRequireVote()
    local displayName = zo_strformat("<<C:1>>", GetUnitDisplayName(unitTag))
    local characterName = GetUnitName(unitTag)
    local isOnline = IsUnitOnline(unitTag)
    local playerIsLeader = IsUnitGroupLeader("player")

    if isPlayer then
        AddMenuItem(GetString(SI_GROUP_LIST_MENU_LEAVE_GROUP), function()
            ZO_Dialogs_ShowDialog("GROUP_LEAVE_DIALOG")
        end)
    elseif isOnline then
        if IsChatSystemAvailableForCurrentPlatform() then
            AddMenuItem(GetString(SI_SOCIAL_LIST_PANEL_WHISPER), function()
                StartChatInput("", CHAT_CHANNEL_WHISPER, characterName)
            end)
        end
        AddMenuItem(GetString(SI_SOCIAL_MENU_VISIT_HOUSE), function()
            JumpToHouse(displayName)
        end)
        if not ZO_IsTributeLocked() then
            AddMenuItem(GetString(SI_SOCIAL_MENU_TRIBUTE_INVITE), function()
                InviteToTributeByDisplayName(displayName)
            end)
        end
        AddMenuItem(GetString(SI_SOCIAL_MENU_JUMP_TO_PLAYER), function()
            JumpToGroupMember(characterName)
        end)
    end

    if not isPlayer and not IsFriend(displayName) and not IsIgnored(displayName) then
        AddMenuItem(GetString(SI_SOCIAL_MENU_ADD_FRIEND), function()
            ZO_Dialogs_ShowDialog("REQUEST_FRIEND", { name = displayName })
        end)
    end

    if IsGroupModificationAvailable() and playerIsLeader and not isLFG then
        if isPlayer then
            AddMenuItem(GetString(SI_GROUP_LIST_MENU_DISBAND_GROUP), function()
                ZO_Dialogs_ShowDialog("GROUP_DISBAND_DIALOG")
            end)
        else
            AddMenuItem(GetString(SI_GROUP_LIST_MENU_KICK_FROM_GROUP), function()
                GroupKick(unitTag)
            end)
        end
    end

    -- Promoting is not "group modification" (ESO's own rule).
    if playerIsLeader and not isPlayer and isOnline then
        AddMenuItem(GetString(SI_GROUP_LIST_MENU_PROMOTE_TO_LEADER), function()
            GroupPromote(unitTag)
        end)
    end

    ShowMenu(control)
end

-- One handler for every bar; placeholder bars (no tag) do nothing.
local function OnBarMouseUp(control, button, upInside)
    if button ~= MOUSE_BUTTON_INDEX_RIGHT or not upInside then return end
    local slot = control.aetherSlot
    local tag = slot and slot.tag
    if tag and DoesUnitExist(tag) then ShowMemberMenu(control, tag) end
end

-- Slots ----------------------------------------------------------------------------
local function NewLabel(name, parent, align)
    local label = WINDOW_MANAGER:CreateControl(name, parent, CT_LABEL)
    label:SetFont(NAME_FONT)
    label:SetColor(0.91, 0.86, 0.75, 1)
    label:SetHorizontalAlignment(align)
    label:SetVerticalAlignment(TEXT_ALIGN_CENTER)
    label:SetMaxLineCount(1)
    label:SetDrawLevel(16)
    return label
end

-- Name between the leader crown (or bar start) and the right-hand text.
function Group:AnchorName(slot)
    local label, bar = slot.nameLabel, slot.bar
    label:ClearAnchors()
    if slot.leader then
        label:SetAnchor(LEFT, slot.leaderIcon, RIGHT, 3, 0)
    else
        label:SetAnchor(LEFT, bar.track, LEFT, TEXT_PAD, 1)
    end
    if slot.status then
        label:SetAnchor(RIGHT, slot.statusLabel, LEFT, -NAME_VALUE_GAP, 0)
    elseif self.sv.text ~= "none" then
        label:SetAnchor(RIGHT, bar.valueLabel, LEFT, -NAME_VALUE_GAP, 0)
    else
        label:SetAnchor(RIGHT, bar.track, RIGHT, -TEXT_PAD, 1)
    end
end

-- Health text, or nothing while Dead / Offline is shown in its place.
function Group:ApplySlotText(slot)
    local mode = slot.status and "none" or self.sv.text
    slot.bar.textMode = mode
    slot.bar:ApplyTextMode(mode)
    self:AnchorName(slot)
end

function Group:GetSlot(i)
    local slot = self.slots[i]
    if slot then return slot end

    local RB = AUI.ResourceBars
    local bar = RB:CreateBar(self.frame, H, "group1", NAME .. "Bar" .. i, self.styles.dd)
    local c = bar.control
    c:SetHidden(true)

    local value = bar.valueLabel
    value:ClearAnchors()
    value:SetAnchor(RIGHT, bar.track, RIGHT, -TEXT_PAD, 1)
    value:SetHorizontalAlignment(TEXT_ALIGN_RIGHT)

    local nameLabel = NewLabel(NAME .. "Name" .. i, c, TEXT_ALIGN_LEFT)
    nameLabel:SetWrapMode(TEXT_WRAP_MODE_ELLIPSIS)

    local status = NewLabel(NAME .. "Status" .. i, c, TEXT_ALIGN_RIGHT)
    status:SetAnchor(RIGHT, bar.track, RIGHT, -TEXT_PAD, 1)
    status:SetHidden(true)

    local leader = WINDOW_MANAGER:CreateControl(NAME .. "Leader" .. i, c, CT_TEXTURE)
    leader:SetTexture(LEADER_ICON)
    leader:SetDimensions(LEADER_SIZE, LEADER_SIZE)
    leader:SetAnchor(LEFT, bar.track, LEFT, TEXT_PAD - 2, 0)
    leader:SetDrawLevel(16)
    leader:SetHidden(true)

    slot = {
        bar = bar, nameLabel = nameLabel, statusLabel = status, leaderIcon = leader,
        tag = nil, name = nil, role = "dd", status = nil, leader = false, alpha = 1, grid = nil,
    }
    self.slots[i] = slot
    -- Right-click menu. Off in unlock mode, where the top-level takes the
    -- mouse for dragging (a mouse-enabled child would swallow the drag).
    c.aetherSlot = slot
    c:SetHitInsets(-4, -4, 4, 4)
    c:SetHandler("OnMouseUp", OnBarMouseUp)
    c:SetMouseEnabled(not self.unlocked)
    self:ApplySlotText(slot)
    return slot
end

function Group:SetSlotName(slot, name)
    if slot.name ~= name then
        slot.name = name
        slot.nameLabel:SetText(name)
    end
end

function Group:SetSlotRole(slot, role)
    if slot.role ~= role then
        slot.role = role
        slot.bar:SetColors(self.styles[role])
    end
end

function Group:SetSlotLeader(slot, leader)
    leader = leader and true or false
    if slot.leader ~= leader then
        slot.leader = leader
        slot.leaderIcon:SetHidden(not leader)
        self:AnchorName(slot)
    end
end

function Group:SetSlotStatus(slot, status)
    if slot.status == status then return end
    slot.status = status
    local label = slot.statusLabel
    if status then
        label:SetText(STATUS_TEXT[status])
        label:SetColor(unpack(STATUS_COLOR[status]))
    end
    label:SetHidden(status == nil)
    self:ApplySlotText(slot)
end

function Group:SetSlotAlpha(slot, a)
    if slot.alpha ~= a then
        slot.alpha = a
        slot.bar.control:SetAlpha(a)
    end
end

-- Dead / offline / out of range for a real member.
function Group:UpdateStatus(slot)
    local tag = slot.tag
    local online = IsUnitOnline(tag)
    local status = (not online and "offline") or (IsUnitDead(tag) and "dead") or nil
    self:SetSlotStatus(slot, status)
    local a = ALPHA_FULL
    if not online then
        a = ALPHA_OFFLINE
    elseif not IsUnitInGroupSupportRange(tag) then
        a = ALPHA_FAR
    end
    self:SetSlotAlpha(slot, a)
end

function Group:RefreshShield(slot)
    local v = GetUnitAttributeVisualizerEffectInfo(slot.tag, ATTRIBUTE_VISUAL_POWER_SHIELDING,
        STAT_MITIGATION, ATTRIBUTE_HEALTH, H)
    slot.bar:SetShield(v or 0)
end

function Group:FormatName(char, account)
    local mode = self.sv.name
    if mode == NAME_ACCOUNT then return account end
    if mode == NAME_BOTH then return char .. " |c" .. ACCOUNT_COLOR .. account .. "|r" end
    return char
end

-- Rebuild ---------------------------------------------------------------------------
function Group:QueueRebuild()
    if self.pending then return end
    self.pending = true
    EM:RegisterForUpdate(REBUILD_NAME, 0, self.onRebuild)
end

function Group:Rebuild()
    if not self.ready then return end
    local byTag = self.byTag
    ZO_ClearTable(byTag)

    local n = self.sv.enabled and GetGroupSize() or 0
    local placeholder = n == 0 and self.sv.enabled and (self.unlocked or self.preview)
    if placeholder then n = #PLACEHOLDER end
    self:SetGrid(n > SMALL_MAX and GRID_RAID or GRID_SMALL, n)

    if placeholder then
        for i = 1, n do
            local p, slot = PLACEHOLDER[i], self:GetSlot(i)
            slot.tag = nil
            self:SetSlotName(slot, self:FormatName(p.char, p.account))
            self:SetSlotRole(slot, p.role)
            self:SetSlotLeader(slot, p.leader)
            self:SetSlotStatus(slot, nil)
            self:SetSlotAlpha(slot, ALPHA_FULL)
            slot.bar:SetShield(0)
            slot.bar:SetValue(zo_round(p.hp * 24000), 24000, true)
        end
    else
        local shown = 0
        for i = 1, n do
            local tag = GetGroupUnitTagByIndex(i)
            if tag then
                shown = shown + 1
                local slot = self:GetSlot(shown)
                local changed = slot.tag ~= tag
                slot.tag = tag
                slot.bar.unitTag = tag
                byTag[tag] = slot
                self:SetSlotName(slot, self:FormatName(zo_strformat(SI_UNIT_NAME, GetUnitName(tag)), GetUnitDisplayName(tag)))
                self:SetSlotRole(slot, ROLE_BY_LFG[GetGroupMemberSelectedRole(tag)] or "dd")
                self:SetSlotLeader(slot, IsUnitGroupLeader(tag))
                self:UpdateStatus(slot)
                slot.bar:Refresh(changed) -- a new member snaps, the same member animates
                self:RefreshShield(slot)
            end
        end
        n = shown
    end

    self:ShowCount(n)
end

-- Grid: lay out bars 1..n for the small group or raid shape. Bars only move
-- when the shape changes or a bar is new to it.
function Group:SetGrid(grid, n)
    local changed = grid ~= self.grid
    self.grid = grid
    local w, h, per = grid.width, grid.height, grid.perColumn
    -- Caps overhang each bar end (no spikes on group bars).
    local overhang = zo_round(h * 0.3) + zo_ceil(h * 0.71)
    local stepX, stepY = w + overhang * 2 + COL_GAP, h + ROW_GAP
    for i = 1, n do
        local slot = self:GetSlot(i)
        if slot.grid ~= grid then
            slot.grid = grid
            local c = slot.bar.control
            slot.bar:ApplyLayout(BAR_CFG, w, h)
            local col, row = zo_floor((i - 1) / per), (i - 1) % per
            c:ClearAnchors()
            c:SetAnchor(TOPLEFT, self.frame, TOPLEFT, col * stepX, row * stepY)
        end
    end
    if changed or n ~= self.count then
        local cols = zo_max(1, zo_ceil(n / per))
        local rows = zo_max(1, zo_min(n, per))
        self.topLevel:SetDimensions(cols * stepX - overhang * 2 - COL_GAP, rows * stepY - ROW_GAP)
    end
end

function Group:ShowCount(n)
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

    local show = n > 0
    if show ~= self.shown then
        self.shown = show
        self.frame:SetHidden(not show)
    end
end

-- Position -----------------------------------------------------------------------------
function Group:ApplyPosition()
    if not self.ready then return end
    local tl, p = self.topLevel, self.sv.point
    tl:ClearAnchors()
    if p then
        tl:SetAnchor(TOPLEFT, GuiRoot, TOPLEFT, p.x, p.y)
    else
        tl:SetAnchor(TOPLEFT, GuiRoot, TOPLEFT, DEFAULT_X, DEFAULT_Y)
    end
end

function Group:ResetPosition()
    if not self.ready then return end
    self.sv.point = nil
    self:ApplyPosition()
end

-- Settings ---------------------------------------------------------------------------
function Group:SetNameMode(mode)
    if not NAME_VALID[mode] then return false end
    if self.sv.name ~= mode then
        self.sv.name = mode
        self:Rebuild()
    end
    return true
end

function Group:SetTextMode(mode)
    if not TEXT_VALID[mode] then return false end
    if self.sv.text ~= mode then
        self.sv.text = mode
        for i = 1, #self.slots do self:ApplySlotText(self.slots[i]) end
    end
    return true
end

function Group:GetRoleColor(role)
    local c = self.sv.colors[role]
    return c.r, c.g, c.b
end

-- Recolour only the bars of that role.
function Group:SetRoleColor(role, r, g, b)
    local c = self.sv.colors[role]
    if not c then return end
    c.r, c.g, c.b = r, g, b
    local style = AUI.ResourceBars.MakeStyle("Group", r, g, b)
    self.styles[role] = style
    for i = 1, #self.slots do
        local slot = self.slots[i]
        if slot.role == role then slot.bar:SetColors(style) end
    end
end

-- Enable / events ----------------------------------------------------------------------
local ROSTER_EVENTS = {
    EVENT_GROUP_UPDATE, EVENT_GROUP_MEMBER_JOINED, EVENT_GROUP_MEMBER_LEFT, EVENT_PLAYER_ACTIVATED,
}
local UNIT_EVENTS = { EVENT_UNIT_CREATED, EVENT_UNIT_DESTROYED }
local SHIELD_EVENTS = {
    EVENT_UNIT_ATTRIBUTE_VISUAL_ADDED, EVENT_UNIT_ATTRIBUTE_VISUAL_UPDATED, EVENT_UNIT_ATTRIBUTE_VISUAL_REMOVED,
}
local STATUS_EVENTS = {
    EVENT_GROUP_MEMBER_CONNECTED_STATUS, EVENT_GROUP_SUPPORT_RANGE_UPDATE, EVENT_UNIT_DEATH_STATE_CHANGED,
}

function Group:RegisterEvents(on)
    for i, ev in ipairs(ROSTER_EVENTS) do
        if on then EM:RegisterForEvent(NAME .. "Roster" .. i, ev, self.queueRebuild)
        else EM:UnregisterForEvent(NAME .. "Roster" .. i, ev) end
    end
    for i, ev in ipairs(UNIT_EVENTS) do
        local ns = NAME .. "Unit" .. i
        if on then
            EM:RegisterForEvent(ns, ev, self.queueRebuild)
            EM:AddFilterForEvent(ns, ev, REGISTER_FILTER_UNIT_TAG_PREFIX, "group")
        else
            EM:UnregisterForEvent(ns, ev)
        end
    end
    for i, ev in ipairs(SHIELD_EVENTS) do
        local ns = NAME .. "Shield" .. i
        if on then
            EM:RegisterForEvent(ns, ev, self.onShield)
            EM:AddFilterForEvent(ns, ev, REGISTER_FILTER_UNIT_TAG_PREFIX, "group")
        else
            EM:UnregisterForEvent(ns, ev)
        end
    end
    for i, ev in ipairs(STATUS_EVENTS) do
        local ns = NAME .. "Status" .. i
        if on then
            EM:RegisterForEvent(ns, ev, self.onStatus)
            -- Death state fires for every unit (enemies too): members only.
            if ev == EVENT_UNIT_DEATH_STATE_CHANGED then
                EM:AddFilterForEvent(ns, ev, REGISTER_FILTER_UNIT_TAG_PREFIX, "group")
            end
        else
            EM:UnregisterForEvent(ns, ev)
        end
    end
    if on then
        EM:RegisterForEvent(NAME .. "Power", EVENT_POWER_UPDATE, self.onPower)
        EM:AddFilterForEvent(NAME .. "Power", EVENT_POWER_UPDATE,
            REGISTER_FILTER_UNIT_TAG_PREFIX, "group",
            REGISTER_FILTER_POWER_TYPE, H)
        EM:RegisterForEvent(NAME .. "Role", EVENT_GROUP_MEMBER_ROLE_CHANGED, self.onRole)
        EM:RegisterForEvent(NAME .. "Leader", EVENT_LEADER_UPDATE, self.onLeader)
    else
        EM:UnregisterForEvent(NAME .. "Power", EVENT_POWER_UPDATE)
        EM:UnregisterForEvent(NAME .. "Role", EVENT_GROUP_MEMBER_ROLE_CHANGED)
        EM:UnregisterForEvent(NAME .. "Leader", EVENT_LEADER_UPDATE)
        if self.pending then
            EM:UnregisterForUpdate(REBUILD_NAME)
            self.pending = false
        end
    end
end

function Group:ApplyEnabled()
    local on = self.sv.enabled
    if on ~= self.registered then
        self.registered = on
        self:RegisterEvents(on)
        self:SetDefaultFramesHidden(on)
    end
    self:ApplyDrag()
    self:ApplyPosition()
    self:Rebuild()
end

function Group:SetEnabled(enabled)
    enabled = enabled and true or false
    if self.sv.enabled == enabled then return end
    self.sv.enabled = enabled
    self:ApplyEnabled()
end

-- Unlock / preview (driven by ResourceBars) ------------------------------------------
function Group:ApplyDrag()
    local on = self.unlocked and self.sv.enabled
    self.topLevel:SetMouseEnabled(on)
    self.dragOverlay:SetHidden(not on)
    self.dragLabel:SetHidden(not on)
    local menu = not self.unlocked
    for i = 1, #self.slots do self.slots[i].bar.control:SetMouseEnabled(menu) end
end

function Group:SetUnlocked(unlocked)
    if not self.ready then return end
    self.unlocked = unlocked
    self:ApplyDrag()
    self:Rebuild()
end

-- Keep the frames visible on top of the settings menu, like the player bars.
function Group:SetPreview(enabled)
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

-- Slash commands -------------------------------------------------------------------------
function Group:HandleCommand(cmd, rest)
    if cmd == "group" then
        if rest == "on" or rest == "off" then
            self:SetEnabled(rest == "on")
            AUI:Print("group frames " .. rest)
        else
            AUI:Print("group frames: " .. (self.sv.enabled and "on" or "off") .. ". /aether group <on|off>")
        end
        return true
    elseif cmd == "groupname" then
        if self:SetNameMode(rest) then
            AUI:Print("group frame names: " .. rest)
        else
            AUI:Print("group frame names: " .. self.sv.name .. ". /aether groupname <" .. table.concat(NAME_ORDER, "|") .. ">")
        end
        return true
    end
    return false
end

AUI:RegisterModule("Group", Group)
