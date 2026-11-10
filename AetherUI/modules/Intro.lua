-- AetherUI / Intro
-- Skip the Bethesda / ZeniMax logo videos when the game starts.
--
-- ESO reads the "SkipPregameVideos" CVar from UserSettings.txt at launch, so
-- the change takes effect from the next game start. The game itself only lets
-- the videos be skipped once they have been watched at least once.
--
-- Performance: one CVar read at load, a write only when the value differs.

local AUI = AetherUI

local Intro = {}
AUI.Intro = Intro

local CVAR = "SkipPregameVideos"

function Intro:Apply(force)
    -- On load only the "on" state is enforced, so an "off" never overwrites a
    -- value the player set by hand in UserSettings.txt.
    if not (self.sv.skipIntro or force) then return end
    local want = self.sv.skipIntro and "1" or "0"
    if GetCVar(CVAR) ~= want then
        SetCVar(CVAR, want)
    end
end

function Intro:SetEnabled(enabled)
    enabled = enabled and true or false
    if self.sv.skipIntro == enabled then return end
    self.sv.skipIntro = enabled
    self:Apply(true)
end

function Intro:Initialize(sv)
    self.sv = sv.misc
    self:Apply(false)
end

function Intro:HandleCommand(cmd, rest)
    if cmd ~= "intro" then return false end
    if rest == "on" or rest == "off" then
        self:SetEnabled(rest == "on")
        AUI:Print("skip intro " .. rest .. " (from the next game start)")
    else
        AUI:Print("skip intro: " .. (self.sv.skipIntro and "on" or "off") .. ". /aether intro <on|off>")
    end
    return true
end

AUI:RegisterModule("Intro", Intro)
