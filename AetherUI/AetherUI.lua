-- AetherUI core: saved variables, module registry, slash commands.

AetherUI = AetherUI or {}
local AUI = AetherUI

AUI.name = "AetherUI"
AUI.version = "0.6.0"
AUI.modules = {}

local SV_VERSION = 1
local DEFAULTS = {
    bars = {
        alwaysShow = false,  -- Skyrim behaviour: hide bars when full and out of combat
        layout = "columns",  -- "default" | "pyramid" | "columns"
        text = "both",       -- bar text: "none" | "value" | "percent" | "both"
        width = 300,         -- base bar length in px (150-600); layouts scale from it
        height = 20,         -- bar thickness in px (6-40); at least 18 while text is shown
        point = nil,         -- { x, y } center of the bar group; nil = layout default (columns: LUI spot)
        points = {},         -- default layout only: per-bar { x, y } centers keyed by bar ("Health", ...)
    },
}

-- One fixed profile instead of ESO's default (GetWorldName()), so settings are
-- shared by every character on the account on every server (NA / EU / PTS).
local SV_PROFILE = "Account"

-- Older builds stored settings under the current server name. Move them to the
-- shared profile once, so nothing is lost on upgrade.
local function MigrateServerProfile()
    local raw = AetherUI_SV
    if type(raw) ~= "table" then return end
    local display = GetDisplayName()
    local shared = raw[SV_PROFILE]
    if shared and shared[display] and shared[display]["$AccountWide"] then return end

    local world = raw[GetWorldName()]
    local old = world and world[display] and world[display]["$AccountWide"]
    if not old then return end

    raw[SV_PROFILE] = shared or {}
    raw[SV_PROFILE][display] = { ["$AccountWide"] = old }
    world[display]["$AccountWide"] = nil
end

function AUI:RegisterModule(name, module)
    module.moduleName = name
    self.modules[#self.modules + 1] = module
end

function AUI:Print(msg)
    if CHAT_ROUTER then
        CHAT_ROUTER:AddSystemMessage("|cC8A464AetherUI|r " .. msg)
    else
        d("AetherUI: " .. msg)
    end
end

local function OnSlashCommand(args)
    local cmd, rest = zo_strsplit(" ", zo_strlower(args or ""))
    for i = 1, #AUI.modules do
        local m = AUI.modules[i]
        if m.HandleCommand and m:HandleCommand(cmd, rest) then return end
    end
    AUI:Print("commands: /aether settings | unlock | lock | reset | text <none|value|percent|both> | always | layout <default|pyramid|columns> | width <150-600> | height <6-40>")
end

local function OnAddOnLoaded(_, addonName)
    if addonName ~= AUI.name then return end
    EVENT_MANAGER:UnregisterForEvent(AUI.name, EVENT_ADD_ON_LOADED)

    MigrateServerProfile()
    AUI.sv = ZO_SavedVars:NewAccountWide("AetherUI_SV", SV_VERSION, nil, DEFAULTS, SV_PROFILE)

    for i = 1, #AUI.modules do
        AUI.modules[i]:Initialize(AUI.sv)
    end

    SLASH_COMMANDS["/aether"] = OnSlashCommand
end

EVENT_MANAGER:RegisterForEvent(AUI.name, EVENT_ADD_ON_LOADED, OnAddOnLoaded)
