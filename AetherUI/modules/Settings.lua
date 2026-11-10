-- AetherUI / Settings
-- Addon settings page (Settings > Addons > AetherUI), built on LibAddonMenu-2.0.
-- LAM is an optional dependency: without it the addon still runs and every
-- option stays reachable through /aether slash commands.
--
-- Performance: the panel is built lazily by LAM the first time it is opened;
-- nothing here runs per frame. The bars are previewed live while the panel
-- is open and returned to the HUD when it closes.

local AUI = AetherUI

local Settings = {}
AUI.Settings = Settings

local PANEL_NAME = "AetherUI_SettingsPanel"

local VISIBILITY_AUTO, VISIBILITY_ALWAYS = "auto", "always"

local LAYOUT_LABELS = {
    default = "Default",
    pyramid = "Pyramid",
    columns = "Columns",
}
local LAYOUT_TOOLTIPS = {
    default = "Magicka, Health and Stamina in one row (Skyrim style).",
    pyramid = "Health on top, Magicka and Stamina side by side under it (Bandits UI style).",
    columns = "Health, Magicka and Stamina stacked in a single column (LUI style).",
}

local TEXT_LABELS = {
    none = "None",
    value = "Value",
    percent = "Percentage",
    both = "Value + percentage",
}
local TEXT_TOOLTIPS = {
    none = "No text. Slim Skyrim-style bars.",
    value = "Current / max, e.g. 18,240 / 24,000.",
    percent = "Percentage, e.g. 76%.",
    both = "Current / max and percentage, e.g. 18,240 / 24,000  (76%).",
}

function Settings:Initialize(sv)
    local LAM = LibAddonMenu2
    if not LAM then return end

    local RB = AUI.ResourceBars
    local Buffs = AUI.Buffs
    local Debuffs = AUI.Debuffs
    local Target = AUI.Target
    local TargetBuffs, TargetDebuffs = AUI.TargetBuffs, AUI.TargetDebuffs
    local MiniBoss = AUI.MiniBoss
    local bars = sv.bars

    local layoutValues, layoutNames, layoutTips = {}, {}, {}
    for i, key in ipairs(RB.LAYOUT_ORDER) do
        layoutValues[i] = key
        layoutNames[i] = LAYOUT_LABELS[key] or key
        layoutTips[i] = LAYOUT_TOOLTIPS[key] or ""
    end

    local textNames, textTips = {}, {}
    for i, key in ipairs(RB.TEXT_ORDER) do
        textNames[i] = TEXT_LABELS[key] or key
        textTips[i] = TEXT_TOOLTIPS[key] or ""
    end

    local panel = LAM:RegisterAddonPanel(PANEL_NAME, {
        type = "panel",
        name = "AetherUI",
        displayName = "|cC8A464Aether|rUI",
        author = "IgorBabayan",
        version = AUI.version,
        registerForRefresh = true,
        registerForDefaults = true,
    })
    self.panel = panel

    LAM:RegisterOptionControls(PANEL_NAME, {
        { type = "header", name = "Resource bars" },
        {
            type = "dropdown",
            name = "Visibility",
            tooltip = "Auto-hide: bars fade out when full and out of combat.\nShow: bars are always visible.",
            choices = { "Auto-hide", "Show" },
            choicesValues = { VISIBILITY_AUTO, VISIBILITY_ALWAYS },
            getFunc = function() return bars.alwaysShow and VISIBILITY_ALWAYS or VISIBILITY_AUTO end,
            setFunc = function(value) RB:SetAlwaysShow(value == VISIBILITY_ALWAYS) end,
            default = VISIBILITY_ALWAYS,
        },
        {
            type = "dropdown",
            name = "Layout",
            tooltip = "How the Health, Magicka and Stamina bars are arranged.",
            choices = layoutNames,
            choicesValues = layoutValues,
            choicesTooltips = layoutTips,
            getFunc = function() return bars.layout end,
            setFunc = function(value) RB:SetLayout(value) end,
            default = "columns",
        },
        {
            type = "dropdown",
            name = "Bar text",
            tooltip = "Text drawn inside each bar. Bars get taller while text is shown.",
            choices = textNames,
            choicesValues = RB.TEXT_ORDER,
            choicesTooltips = textTips,
            getFunc = function() return bars.text end,
            setFunc = function(value) RB:SetTextMode(value) end,
            default = "both",
        },
        {
            type = "slider",
            name = "Bar width",
            tooltip = "Length of the bars in pixels.\nPyramid layout: Health is 20% wider, Magicka and Stamina share its width.",
            min = RB.WIDTH_MIN, max = RB.WIDTH_MAX, step = 5,
            getFunc = function() return bars.width end,
            setFunc = function(value) RB:SetBarWidth(value) end,
            default = RB.WIDTH_DEFAULT,
        },
        {
            type = "slider",
            name = "Bar height",
            tooltip = "Thickness of the bars in pixels.\nWhile bar text is shown, bars are at least 18 px tall.",
            min = RB.HEIGHT_MIN, max = RB.HEIGHT_MAX, step = 1,
            getFunc = function() return bars.height end,
            setFunc = function(value) RB:SetBarHeight(value) end,
            default = RB.HEIGHT_DEFAULT,
        },

        { type = "header", name = "Buffs" },
        {
            type = "checkbox",
            name = "Show buffs",
            tooltip = "Show your active buffs as icons.\nPermanent buffs come first, then temporary ones with a timer under the icon.",
            getFunc = function() return sv.buffs.enabled end,
            setFunc = function(value) Buffs:SetEnabled(value) end,
            default = true,
        },
        {
            type = "slider",
            name = "Buffs per row",
            tooltip = "How many buff icons fit in one row before a new row starts.\n"
                .. "Columns: under Stamina, left to right, new rows below.\n"
                .. "Pyramid: under Magicka and Stamina, left to right, new rows below.\n"
                .. "Default: screen bottom-left corner, bottom to top (a row is one column of icons).",
            min = Buffs.PER_ROW_MIN, max = Buffs.PER_ROW_MAX, step = 1,
            getFunc = function() return sv.buffs.perRow end,
            setFunc = function(value) Buffs:SetPerRow(value) end,
            disabled = function() return not sv.buffs.enabled end,
            default = Buffs.PER_ROW_DEFAULT,
        },

        { type = "header", name = "Debuffs" },
        {
            type = "checkbox",
            name = "Show debuffs",
            tooltip = "Show your active debuffs as icons with a red frame.\nPermanent debuffs come first, then temporary ones with a timer under the icon.",
            getFunc = function() return sv.debuffs.enabled end,
            setFunc = function(value) Debuffs:SetEnabled(value) end,
            default = true,
        },
        {
            type = "slider",
            name = "Debuffs per row",
            tooltip = "How many debuff icons fit in one row before a new row starts.\n"
                .. "Columns and Pyramid: above Health, left to right, new rows above.\n"
                .. "Default: screen bottom-right corner, bottom to top (a row is one column of icons, new columns to the left).",
            min = Debuffs.PER_ROW_MIN, max = Debuffs.PER_ROW_MAX, step = 1,
            getFunc = function() return sv.debuffs.perRow end,
            setFunc = function(value) Debuffs:SetPerRow(value) end,
            disabled = function() return not sv.debuffs.enabled end,
            default = Debuffs.PER_ROW_DEFAULT,
        },

        { type = "header", name = "Target" },
        {
            type = "checkbox",
            name = "Show target bar",
            tooltip = "Health bar for what you are looking at, in the LUI target frame spot "
                .. "(lines up with Health in the Columns layout).\nReplaces ESO's own target frame. "
                .. "Uses the bar width, height and text settings above.",
            getFunc = function() return sv.target.enabled end,
            setFunc = function(value) Target:SetEnabled(value) end,
            default = true,
        },
        {
            type = "checkbox",
            name = "Show target buffs",
            tooltip = "Target's buffs under the target bar, left to right, new rows below.\n"
                .. "Permanent buffs come first, then temporary ones with a timer under the icon.",
            getFunc = function() return sv.targetBuffs.enabled end,
            setFunc = function(value) TargetBuffs:SetEnabled(value) end,
            disabled = function() return not sv.target.enabled end,
            default = true,
        },
        {
            type = "slider",
            name = "Target buffs per row",
            tooltip = "How many target buff icons fit in one row before a new row starts.",
            min = TargetBuffs.PER_ROW_MIN, max = TargetBuffs.PER_ROW_MAX, step = 1,
            getFunc = function() return sv.targetBuffs.perRow end,
            setFunc = function(value) TargetBuffs:SetPerRow(value) end,
            disabled = function() return not (sv.target.enabled and sv.targetBuffs.enabled) end,
            default = TargetBuffs.PER_ROW_DEFAULT,
        },
        {
            type = "checkbox",
            name = "Show target debuffs",
            tooltip = "Target's debuffs above the target name, left to right, new rows above.\n"
                .. "Permanent debuffs come first, then temporary ones with a timer under the icon.",
            getFunc = function() return sv.targetDebuffs.enabled end,
            setFunc = function(value) TargetDebuffs:SetEnabled(value) end,
            disabled = function() return not sv.target.enabled end,
            default = true,
        },
        {
            type = "slider",
            name = "Target debuffs per row",
            tooltip = "How many target debuff icons fit in one row before a new row starts.",
            min = TargetDebuffs.PER_ROW_MIN, max = TargetDebuffs.PER_ROW_MAX, step = 1,
            getFunc = function() return sv.targetDebuffs.perRow end,
            setFunc = function(value) TargetDebuffs:SetPerRow(value) end,
            disabled = function() return not (sv.target.enabled and sv.targetDebuffs.enabled) end,
            default = TargetDebuffs.PER_ROW_DEFAULT,
        },

        { type = "header", name = "Mini-bosses" },
        {
            type = "checkbox",
            name = "Show mini-boss bars",
            tooltip = "A health bar for each mini-boss a boss summons or fights alongside, "
                .. "stacked under ESO's boss bar at the top of the screen.\n"
                .. "The mini-boss name is on the left of the bar, its health on the right. No buffs or debuffs.\n"
                .. "The main boss is the one with the most max health; it keeps ESO's own boss bar.\n"
                .. "Uses the bar width, height and text settings above.",
            getFunc = function() return sv.miniBoss.enabled end,
            setFunc = function(value) MiniBoss:SetEnabled(value) end,
            default = true,
        },

        { type = "header", name = "Position" },
        {
            type = "checkbox",
            name = "Unlock bars",
            tooltip = "Drag the bars to a new position. Locked again when this page closes.\n"
                .. "Default layout: each bar moves on its own.\nOther layouts: all bars move together.\n"
                .. "The target bar and the mini-boss bars each move on their own.",
            getFunc = function() return RB.unlocked end,
            setFunc = function(value) RB:SetUnlocked(value) end,
            default = false,
        },
        {
            type = "button",
            name = "Reset position",
            tooltip = "Move the bars back to their default position.\nColumns layout: same spot as the LUI player frame.\n"
                .. "Target bar: same spot as the LUI target frame.\n"
                .. "Mini-boss bars: top centre, under ESO's boss bar.",
            func = function() RB:ResetPosition() end,
            width = "half",
        },
    })

    -- Live preview while our page is open.
    CALLBACK_MANAGER:RegisterCallback("LAM-PanelOpened", function(p)
        if p == panel then RB:SetPreview(true) end
    end)
    CALLBACK_MANAGER:RegisterCallback("LAM-PanelClosed", function(p)
        if p == panel then
            if RB.unlocked then RB:SetUnlocked(false) end
            RB:SetPreview(false)
        end
    end)
end

function Settings:Open()
    if self.panel then
        LibAddonMenu2:OpenToPanel(self.panel)
    else
        AUI:Print("settings page needs LibAddonMenu-2.0 installed.")
    end
end

function Settings:HandleCommand(cmd)
    if cmd == "settings" or cmd == "config" then
        self:Open()
        return true
    end
    return false
end

AUI:RegisterModule("Settings", Settings)
