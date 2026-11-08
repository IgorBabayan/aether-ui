-- AetherUI core: saved variables, module registry, slash commands.

AetherUI = AetherUI or {}
local AUI = AetherUI

AUI.name = "AetherUI"
AUI.version = "0.1.0"
AUI.modules = {}

local SV_VERSION = 1
local DEFAULTS = {
    bars = {
        alwaysShow = false,  -- Skyrim behaviour: hide bars when full and out of combat
        showNumbers = false, -- Skyrim shows no numbers by default
        point = nil,         -- { x, y } center of the bar group; nil = default ESO position
    },
}

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
    AUI:Print("commands: /aether unlock | lock | reset | numbers | always")
end

local function OnAddOnLoaded(_, addonName)
    if addonName ~= AUI.name then return end
    EVENT_MANAGER:UnregisterForEvent(AUI.name, EVENT_ADD_ON_LOADED)

    AUI.sv = ZO_SavedVars:NewAccountWide("AetherUI_SV", SV_VERSION, nil, DEFAULTS)

    for i = 1, #AUI.modules do
        AUI.modules[i]:Initialize(AUI.sv)
    end

    SLASH_COMMANDS["/aether"] = OnSlashCommand
end

EVENT_MANAGER:RegisterForEvent(AUI.name, EVENT_ADD_ON_LOADED, OnAddOnLoaded)
