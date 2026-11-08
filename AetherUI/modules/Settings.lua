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
            default = VISIBILITY_AUTO,
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

        { type = "header", name = "Position" },
        {
            type = "checkbox",
            name = "Unlock bars",
            tooltip = "Drag the bars to a new position. Locked again when this page closes.\n"
                .. "Default layout: each bar moves on its own.\nOther layouts: all bars move together.",
            getFunc = function() return RB.unlocked end,
            setFunc = function(value) RB:SetUnlocked(value) end,
            default = false,
        },
        {
            type = "button",
            name = "Reset position",
            tooltip = "Move the bars back to their default position.\nColumns layout: same spot as the LUI player frame.",
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
