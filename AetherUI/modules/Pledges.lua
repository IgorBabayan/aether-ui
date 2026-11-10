-- AetherUI / Pledges
-- Marks the dungeons of your active Undaunted pledges in the Dungeon Finder list
-- (Group & Activity Finder > Dungeons, keyboard UI):
--   * pledge icon  - pledge taken, dungeon not done yet
--   * check mark   - pledge done, ready to hand in
--
-- Pledge quests are found by quest type (QUEST_TYPE_UNDAUNTED_PLEDGE), so it
-- works in every client language. The dungeon is matched by the name after the
-- "Pledge:" prefix, with the quest's zone as a fallback.
--
-- Performance: quest events only flag the pledge list as stale; it is rebuilt
-- (one pass over the journal, max 25 quests) the next time the list is drawn.
-- The list row hook is a table lookup per visible row.

local AUI = AetherUI

local Pledges = {}
AUI.Pledges = Pledges

local ENTRY_TEMPLATE = "ZO_ActivityFinderTemplateNavigationEntry_Keyboard"
local ICON_ACTIVE = zo_iconFormat("EsoUI/Art/Compass/repeatableQuest_icon.dds", 26, 26)
local ICON_DONE = zo_iconFormat("EsoUI/Art/Cadwell/check.dds", 22, 22)

local byName = {}  -- normalized dungeon name -> true when the pledge is done
local byZone = {}  -- zoneId -> true when the pledge is done
local dirty = true
local hooked = false

local function Normalize(name)
    if not name or name == "" then return nil end
    local caret = name:find("^", 1, true)
    if caret then name = name:sub(1, caret - 1) end
    return zo_strlower(zo_strtrim(name))
end

local function Rebuild()
    ZO_ClearTable(byName)
    ZO_ClearTable(byZone)
    for questIndex = 1, MAX_JOURNAL_QUESTS do
        if IsValidQuestIndex(questIndex) and GetJournalQuestType(questIndex) == QUEST_TYPE_UNDAUNTED_PLEDGE then
            local done = GetJournalQuestIsComplete(questIndex) and true or false
            local questName = GetJournalQuestName(questIndex)
            -- "Pledge: Fungal Grotto I" / "Engagement : ..." -> dungeon name
            local key = Normalize(questName:match(":%s*(.+)$") or questName)
            if key then byName[key] = done end
            local _, _, zoneIndex = GetJournalQuestLocationInfo(questIndex)
            if zoneIndex then
                local zoneId = GetZoneId(zoneIndex)
                if zoneId and zoneId ~= 0 then byZone[zoneId] = done end
            end
        end
    end
    dirty = false
end

-- nil = no pledge, false = pledge active, true = pledge done
local function GetPledgeState(location)
    if dirty then Rebuild() end
    local state = byName[Normalize(location:GetRawName())]
    if state == nil and location.zoneId then state = byZone[location.zoneId] end
    return state
end

local function GetFinder()
    local finder = DUNGEON_FINDER_KEYBOARD
    return finder and finder.navigationTree and finder
end

local function RefreshList()
    local finder = GetFinder()
    if finder and finder.control and not finder.control:IsHidden() then
        finder.navigationTree:RefreshVisible(false)
    end
end

local function OnQuestsChanged()
    dirty = true
    if Pledges.sv.enabled then RefreshList() end
end

-- Wrap the row setup of the dungeon list. Rows are rebuilt by the tree on every
-- list refresh, so new rows always go through the wrapper.
local function HookFinder()
    if hooked then return true end
    local finder = GetFinder()
    local info = finder and finder.navigationTree.templateInfo[ENTRY_TEMPLATE]
    if not info then return false end
    hooked = true

    local original = info.setupFunction
    info.setupFunction = function(node, control, data, ...)
        original(node, control, data, ...)
        if not Pledges.sv.enabled or not data.GetRawName then return end
        local state = GetPledgeState(data)
        if state ~= nil then
            control.text:SetText(data:GetNameKeyboard() .. " " .. (state and ICON_DONE or ICON_ACTIVE))
        end
    end

    local events = { EVENT_QUEST_ADDED, EVENT_QUEST_REMOVED, EVENT_QUEST_ADVANCED, EVENT_QUEST_COMPLETE, EVENT_QUEST_LIST_UPDATED }
    for i = 1, #events do
        EVENT_MANAGER:RegisterForEvent("AetherUI_Pledges", events[i], OnQuestsChanged)
    end
    -- A pledge flips to "done" on its last condition update; keep this one cheap.
    EVENT_MANAGER:RegisterForEvent("AetherUI_Pledges", EVENT_QUEST_CONDITION_COUNTER_CHANGED, function()
        dirty = true
    end)
    return true
end

function Pledges:ApplyEnabled()
    if self.sv.enabled and not HookFinder() then
        -- The finder UI is not built yet: try again once the player is in the world.
        EVENT_MANAGER:RegisterForEvent("AetherUI_PledgesInit", EVENT_PLAYER_ACTIVATED, function()
            EVENT_MANAGER:UnregisterForEvent("AetherUI_PledgesInit", EVENT_PLAYER_ACTIVATED)
            HookFinder()
            RefreshList()
        end)
        return
    end
    dirty = true
    RefreshList()
end

function Pledges:SetEnabled(enabled)
    enabled = enabled and true or false
    if self.sv.enabled == enabled then return end
    self.sv.enabled = enabled
    self:ApplyEnabled()
end

function Pledges:Initialize(sv)
    self.sv = sv.pledges
    if self.sv.enabled then self:ApplyEnabled() end
end

function Pledges:HandleCommand(cmd, rest)
    if cmd ~= "pledges" then return false end
    if rest == "on" or rest == "off" then
        self:SetEnabled(rest == "on")
        AUI:Print("pledge marks " .. rest)
    else
        AUI:Print("pledge marks: " .. (self.sv.enabled and "on" or "off") .. ". /aether pledges <on|off>")
    end
    return true
end

AUI:RegisterModule("Pledges", Pledges)
