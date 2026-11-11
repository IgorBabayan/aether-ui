-- AetherUI / Keybinds
-- "AetherUI" group in Controls > Keybindings (actions live in Bindings.xml):
--   * Reload Interface           default F12
--   * Teleport to Primary House  default Home
--   * Summon <Companion>         one per companion, unbound by default
--   * Summon <Assistant>         one per assistant (banker, merchant, fence,
--                                ragpicker, armory...), unbound by default
--
-- Defaults are applied once per account and only when the key is free, so a
-- user's own binds (or a later unbind) are never overwritten.
--
-- Performance: no events, no polling. The collectible lists are read once at
-- load; a key press is a table lookup plus one API call.

local AUI = AetherUI

local GetCollectibleName = GetCollectibleName
local IsCollectibleUnlocked = IsCollectibleUnlocked
local UseCollectible = UseCollectible
local zo_strformat = zo_strformat

local Keybinds = {}
AUI.Keybinds = Keybinds

local DEFAULT_BINDS = {
    { action = "AETHERUI_RELOAD_UI", key = KEY_F12 },
    { action = "AETHERUI_JUMP_PRIMARY_HOUSE", key = KEY_HOME },
}

-- Summonable collectible groups. maxSlots must match the slots in Bindings.xml.
local SUMMON_GROUPS = {
    companion = {
        categoryType = COLLECTIBLE_CATEGORY_TYPE_COMPANION,
        action = "AETHERUI_SUMMON_COMPANION_",
        maxSlots = 16,
        ids = {},   -- slot -> collectibleId
    },
    assistant = {
        categoryType = COLLECTIBLE_CATEGORY_TYPE_ASSISTANT,
        action = "AETHERUI_SUMMON_ASSISTANT_",
        maxSlots = 32,
        ids = {},
    },
}
Keybinds.SUMMON_ORDER = { "assistant", "companion" }

ZO_CreateStringId("SI_BINDING_NAME_AETHERUI_RELOAD_UI", "Reload Interface")
ZO_CreateStringId("SI_BINDING_NAME_AETHERUI_JUMP_PRIMARY_HOUSE", "Teleport to Primary House")

local function CollectibleName(id)
    return zo_strformat(SI_COLLECTIBLE_NAME_FORMATTER, GetCollectibleName(id))
end
Keybinds.CollectibleName = CollectibleName

-- Every collectible of the group (owned or not), sorted by id so slots stay
-- stable when new ones are added to the game or unlocked.
local function BuildSlots(group)
    local categoryType = group.categoryType
    if not categoryType then return end
    local ids = {}
    for i = 1, GetTotalCollectiblesByCategoryType(categoryType) do
        local id = GetCollectibleIdFromType(categoryType, i)
        if id and id ~= 0 then ids[#ids + 1] = id end
    end
    table.sort(ids)

    local slots = group.ids
    for slot = 1, zo_min(#ids, group.maxSlots) do
        local id = ids[slot]
        slots[slot] = id
        ZO_CreateStringId("SI_BINDING_NAME_" .. group.action .. slot, "Summon " .. CollectibleName(id))
    end
end

local function IsKeyFree(layerIndex, key)
    local _, _, actionIndex = GetBindingIndicesFromKeys(layerIndex, key, KEY_INVALID, KEY_INVALID, KEY_INVALID, KEY_INVALID)
    return not actionIndex
end

local function HasBinding(layerIndex, categoryIndex, actionIndex)
    for b = 1, GetMaxBindingsPerAction() do
        local key = GetActionBindingInfo(layerIndex, categoryIndex, actionIndex, b)
        if key and key ~= KEY_INVALID then return true end
    end
    return false
end

local function ApplyDefaultBinds(sv)
    if sv.defaultsApplied then return end
    for i = 1, #DEFAULT_BINDS do
        local def = DEFAULT_BINDS[i]
        local layerIndex, categoryIndex, actionIndex = GetActionIndicesFromName(def.action)
        if layerIndex and not HasBinding(layerIndex, categoryIndex, actionIndex) and IsKeyFree(layerIndex, def.key) then
            CreateDefaultActionBind(def.action, def.key)
        end
    end
    sv.defaultsApplied = true
end

function Keybinds.ReloadInterface()
    ReloadUI("ingame")
end

function Keybinds.JumpToPrimaryHouse()
    local houseId = GetHousingPrimaryHouse()
    if not houseId or houseId == 0 then
        AUI:Print("no primary house set.")
        return
    end
    RequestJumpToHouse(houseId)
end

-- Summon (or dismiss, if already out) one companion / assistant collectible.
function Keybinds.Summon(id)
    if not id then return end
    if not IsCollectibleUnlocked(id) then
        AUI:Print(CollectibleName(id) .. " is not unlocked.")
        return
    end
    UseCollectible(id) -- toggles: summons, or dismisses if already active
end

function Keybinds.SummonCompanion(slot)
    Keybinds.Summon(SUMMON_GROUPS.companion.ids[slot])
end

function Keybinds.SummonAssistant(slot)
    Keybinds.Summon(SUMMON_GROUPS.assistant.ids[slot])
end

-- Unlocked collectibles of a group ("assistant" | "companion"), in slot order.
-- Not a hot path: called once when the settings page is built.
function Keybinds:GetUnlocked(groupKey)
    local out = {}
    local group = SUMMON_GROUPS[groupKey]
    if not group then return out end
    local ids = group.ids
    for slot = 1, #ids do
        local id = ids[slot]
        if IsCollectibleUnlocked(id) then out[#out + 1] = id end
    end
    return out
end

function Keybinds:Initialize(sv)
    for _, key in ipairs(self.SUMMON_ORDER) do
        BuildSlots(SUMMON_GROUPS[key])
    end
    ApplyDefaultBinds(sv.keybinds)
end

AUI:RegisterModule("Keybinds", Keybinds)
