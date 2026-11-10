-- AetherUI / Keybinds
-- "AetherUI" group in Controls > Keybindings (actions live in Bindings.xml):
--   * Reload Interface           default F12
--   * Teleport to Primary House  default Home
--   * Summon <Companion>         one per companion, unbound by default
--
-- Defaults are applied once per account and only when the key is free, so a
-- user's own binds (or a later unbind) are never overwritten.
--
-- Performance: no events, no polling. The companion list is read once at load;
-- a key press is a table lookup plus one API call.

local AUI = AetherUI

local Keybinds = {}
AUI.Keybinds = Keybinds

local MAX_COMPANION_SLOTS = 16 -- must match the slots in Bindings.xml
local SUMMON_ACTION = "AETHERUI_SUMMON_COMPANION_"

local DEFAULT_BINDS = {
    { action = "AETHERUI_RELOAD_UI", key = KEY_F12 },
    { action = "AETHERUI_JUMP_PRIMARY_HOUSE", key = KEY_HOME },
}

local companionIds = {} -- slot -> collectibleId

ZO_CreateStringId("SI_BINDING_NAME_AETHERUI_RELOAD_UI", "Reload Interface")
ZO_CreateStringId("SI_BINDING_NAME_AETHERUI_JUMP_PRIMARY_HOUSE", "Teleport to Primary House")

-- Every companion collectible (owned or not), sorted by id so slots stay stable
-- when new companions are added to the game or unlocked.
local function BuildCompanionSlots()
    local categoryType = COLLECTIBLE_CATEGORY_TYPE_COMPANION
    local ids = {}
    for i = 1, GetTotalCollectiblesByCategoryType(categoryType) do
        local id = GetCollectibleIdFromType(categoryType, i)
        if id and id ~= 0 then ids[#ids + 1] = id end
    end
    table.sort(ids)

    for slot = 1, zo_min(#ids, MAX_COMPANION_SLOTS) do
        local id = ids[slot]
        companionIds[slot] = id
        local name = zo_strformat(SI_COLLECTIBLE_NAME_FORMATTER, GetCollectibleName(id))
        ZO_CreateStringId("SI_BINDING_NAME_" .. SUMMON_ACTION .. slot, "Summon " .. name)
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

function Keybinds.SummonCompanion(slot)
    local id = companionIds[slot]
    if not id then return end
    if not IsCollectibleUnlocked(id) then
        AUI:Print(zo_strformat(SI_COLLECTIBLE_NAME_FORMATTER, GetCollectibleName(id)) .. " is not unlocked.")
        return
    end
    UseCollectible(id) -- toggles: summons, or dismisses if already active
end

function Keybinds:Initialize(sv)
    BuildCompanionSlots()
    ApplyDefaultBinds(sv.keybinds)
end

AUI:RegisterModule("Keybinds", Keybinds)
