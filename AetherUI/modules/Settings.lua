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

local GROUP_NAME_LABELS = {
    character = "Character name",
    account = "Account name",
    both = "Character + account name",
}
local GROUP_NAME_TOOLTIPS = {
    character = "Character name only, e.g. Aela the Huntress.",
    account = "Account name only, e.g. @Aela.",
    both = "Character name followed by the account name, e.g. Aela the Huntress @Aela.",
}
local ROLE_LABELS = {
    tank = "Tank color",
    healer = "Healer color",
    dd = "Damage dealer color",
}
local ROLE_TOOLTIPS = {
    tank = "Health bar color of group members with the Tank role.",
    healer = "Health bar color of group members with the Healer role.",
    dd = "Health bar color of group members with the Damage Dealer role (or no role).",
}

local BOOK_CLOSE_LABELS = {
    off = "Off",
    read = "Already read",
    all = "All books",
}
local BOOK_CLOSE_TOOLTIPS = {
    off = "Books open as usual.",
    read = "Books already in your Lore Library close at once. New books still open.",
    all = "Every book you pick up in the world closes at once. Lore is still learned.",
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
    local Companion = AUI.Companion
    local CastBar = AUI.CastBar
    local Group = AUI.Group
    local Intro, Books, Pledges = AUI.Intro, AUI.Books, AUI.Pledges
    local Keybinds = AUI.Keybinds
    local Panel = AUI.Panel
    local bars = sv.bars

    -- One button per unlocked collectible of a summon group, built once here
    -- (collectibles unlocked later appear after /reloadui).
    local function SummonButtons(groupKey, noneText)
        local ids = Keybinds:GetUnlocked(groupKey)
        if #ids == 0 then
            return { { type = "description", text = noneText } }
        end
        local controls = {}
        for i = 1, #ids do
            local id = ids[i]
            controls[i] = {
                type = "button",
                name = Keybinds.CollectibleName(id),
                tooltip = function()
                    return IsCollectibleActive(id) and "Out now. Click to dismiss." or "Click to summon."
                end,
                func = function() Keybinds.Summon(id) end,
                width = "half",
            }
        end
        return controls
    end

    -- One checkbox per unlocked collectible of a summon group: on the panel or
    -- not. Built once here, like the summon buttons above.
    local function PanelToggles(groupKey, noneText)
        local ids = Keybinds:GetUnlocked(groupKey)
        if #ids == 0 then
            return { { type = "description", text = noneText } }
        end
        local function off() return not sv.panel.enabled end
        local controls = {}
        if #ids > 1 then
            controls[1] = {
                type = "button", name = "Show all", width = "half", disabled = off,
                func = function() for i = 1, #ids do Panel:SetShown(ids[i], true) end end,
            }
            controls[2] = {
                type = "button", name = "Hide all", width = "half", disabled = off,
                func = function() for i = 1, #ids do Panel:SetShown(ids[i], false) end end,
            }
        end
        for i = 1, #ids do
            local id = ids[i]
            controls[#controls + 1] = {
                type = "checkbox",
                name = zo_iconTextFormat(GetCollectibleIcon(id), 24, 24, Keybinds.CollectibleName(id)),
                getFunc = function() return Panel:IsShown(id) end,
                setFunc = function(value) Panel:SetShown(id, value) end,
                disabled = off,
                default = true,
            }
        end
        return controls
    end

    local closeNames, closeTips = {}, {}
    for i, key in ipairs(Books.CLOSE_ORDER) do
        closeNames[i] = BOOK_CLOSE_LABELS[key] or key
        closeTips[i] = BOOK_CLOSE_TOOLTIPS[key] or ""
    end

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

    local groupNames, groupTips = {}, {}
    for i, key in ipairs(Group.NAME_ORDER) do
        groupNames[i] = GROUP_NAME_LABELS[key] or key
        groupTips[i] = GROUP_NAME_TOOLTIPS[key] or ""
    end

    -- One colour picker per role; changes recolour only that role's bars.
    local function RoleColor(role)
        local def = Group.DEFAULT_COLORS[role]
        return {
            type = "colorpicker",
            name = ROLE_LABELS[role],
            tooltip = ROLE_TOOLTIPS[role],
            getFunc = function() return Group:GetRoleColor(role) end,
            setFunc = function(r, g, b) Group:SetRoleColor(role, r, g, b) end,
            disabled = function() return not sv.group.enabled end,
            default = { r = def.r, g = def.g, b = def.b },
        }
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
            tooltip = "Health bar for what you are looking at, level with your Health bar on the other "
                .. "side of the screen (Columns: the LUI target frame spot).\n"
                .. "Default / Pyramid layouts: the LUI target frame spot.\nReplaces ESO's own target frame. "
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
                .. "in a column beside the target bar (the boss bar while you target the boss).\n"
                .. "One mini-boss is level with the target bar; two or more are centred on it.\n"
                .. "The mini-boss name is on the left of the bar, its health on the right. No buffs or debuffs.\n"
                .. "The main boss is the one with the most max health; it keeps ESO's own boss bar.\n"
                .. "Uses the bar width, height and text settings above.",
            getFunc = function() return sv.miniBoss.enabled end,
            setFunc = function(value) MiniBoss:SetEnabled(value) end,
            default = true,
        },

        { type = "header", name = "Companion" },
        {
            type = "checkbox",
            name = "Show companion bar",
            tooltip = "Health bar for your companion, as wide as the Health bar.\n"
                .. "Columns: level with the Magicka bar, on the outer (left) side of your bars.\n"
                .. "Pyramid: under the player bars; your buffs move down under it.\n"
                .. "Default layout: above the Health bar.\n"
                .. "Companion name on the left, its health on the right. Replaces ESO's companion frame.\n"
                .. "Drag it anywhere while the bars are unlocked.\n"
                .. "Uses the bar height and text settings above.",
            getFunc = function() return sv.companion.enabled end,
            setFunc = function(value) Companion:SetEnabled(value) end,
            default = true,
        },

        { type = "header", name = "Cast bar" },
        {
            type = "checkbox",
            name = "Show cast bar",
            tooltip = "A bar for your casts and channels (LUI style): ability icon on the left, "
                .. "ability name and time left inside the bar.\n"
                .. "Casts fill up, channels drain. Cancelled by block, dodge, bash, crowd control, "
                .. "weapon swap, and by moving during a recall.\n"
                .. "Sits under the screen centre; drag it anywhere while the bars are unlocked.",
            getFunc = function() return sv.castBar.enabled end,
            setFunc = function(value) CastBar:SetEnabled(value) end,
            default = true,
        },
        {
            type = "checkbox",
            name = "Show heavy attacks",
            tooltip = "Also show the wind-up of heavy attacks.",
            getFunc = function() return sv.castBar.heavy end,
            setFunc = function(value) CastBar:SetHeavy(value) end,
            disabled = function() return not sv.castBar.enabled end,
            default = false,
        },
        {
            type = "checkbox",
            name = "Show ability name",
            tooltip = "Ability name on the left inside the bar.",
            getFunc = function() return sv.castBar.label end,
            setFunc = function(value) CastBar:SetShowLabel(value) end,
            disabled = function() return not sv.castBar.enabled end,
            default = true,
        },
        {
            type = "checkbox",
            name = "Show time left",
            tooltip = "Seconds left on the right inside the bar, e.g. 1.4.",
            getFunc = function() return sv.castBar.timer end,
            setFunc = function(value) CastBar:SetShowTimer(value) end,
            disabled = function() return not sv.castBar.enabled end,
            default = true,
        },
        {
            type = "slider",
            name = "Cast bar width",
            tooltip = "Length of the cast bar in pixels.",
            min = CastBar.WIDTH_MIN, max = CastBar.WIDTH_MAX, step = 5,
            getFunc = function() return sv.castBar.width end,
            setFunc = function(value) CastBar:SetWidth(value) end,
            disabled = function() return not sv.castBar.enabled end,
            default = CastBar.WIDTH_DEFAULT,
        },
        {
            type = "slider",
            name = "Cast bar height",
            tooltip = "Thickness of the cast bar in pixels. The ability icon is 10 px taller.",
            min = CastBar.HEIGHT_MIN, max = CastBar.HEIGHT_MAX, step = 1,
            getFunc = function() return sv.castBar.height end,
            setFunc = function(value) CastBar:SetHeight(value) end,
            disabled = function() return not sv.castBar.enabled end,
            default = CastBar.HEIGHT_DEFAULT,
        },

        { type = "header", name = "Group frames" },
        {
            type = "checkbox",
            name = "Show group frames",
            tooltip = "Group and raid frames in the AetherUI bar style. Replaces ESO's group and raid frames.\n"
                .. "Up to 4 members: one column. 5 or more: columns of 4.\n"
                .. "Health bar color follows each member's role and changes when they switch role.\n"
                .. "Leader crown and name on the left, health (or Dead / Offline) on the right.\n"
                .. "Out of range members are dimmed. Group companions are not shown.\n"
                .. "Right-click a member (cursor shown with .) for the LUI menu: whisper, visit house, "
                .. "travel to player, add friend, kick, promote to leader, leave group.\n"
                .. "Drag them anywhere while the bars are unlocked.",
            getFunc = function() return sv.group.enabled end,
            setFunc = function(value) Group:SetEnabled(value) end,
            default = true,
        },
        {
            type = "dropdown",
            name = "Name",
            tooltip = "Name written on each group frame.",
            choices = groupNames,
            choicesValues = Group.NAME_ORDER,
            choicesTooltips = groupTips,
            getFunc = function() return sv.group.name end,
            setFunc = function(value) Group:SetNameMode(value) end,
            disabled = function() return not sv.group.enabled end,
            default = "character",
        },
        {
            type = "dropdown",
            name = "Health text",
            tooltip = "Health text on the right of each group frame.",
            choices = textNames,
            choicesValues = RB.TEXT_ORDER,
            choicesTooltips = textTips,
            getFunc = function() return sv.group.text end,
            setFunc = function(value) Group:SetTextMode(value) end,
            disabled = function() return not sv.group.enabled end,
            default = "percent",
        },
        RoleColor("tank"),
        RoleColor("healer"),
        RoleColor("dd"),

        { type = "header", name = "Summon" },
        {
            type = "description",
            text = "Summon any assistant or companion you own with one click. Click again to dismiss it.\n"
                .. "Only one assistant and one companion can be out at a time: summoning another replaces it.\n"
                .. "Each one also has its own key in Controls > Keybindings > AetherUI (unbound by default).",
        },
        {
            type = "submenu",
            name = "Assistants",
            tooltip = "Bankers, merchants, fences, the ragpicker, armory and other assistants you own.",
            controls = SummonButtons("assistant", "No assistants unlocked."),
        },
        {
            type = "submenu",
            name = "Companions",
            tooltip = "Companions you own.",
            controls = SummonButtons("companion", "No companions unlocked."),
        },

        { type = "header", name = "Summon panel" },
        {
            type = "checkbox",
            name = "Show summon panel",
            tooltip = "Press . (show cursor) and a column of summon buttons appears on the left edge of the screen, "
                .. "like the Bandits UI side panel.\n"
                .. "Assistants on top, then a line, then companions.\n"
                .. "Click a button to summon, click again to dismiss. The ones out now have a bronze frame.\n"
                .. "Hidden again when the cursor goes away or a menu opens.",
            getFunc = function() return sv.panel.enabled end,
            setFunc = function(value) Panel:SetEnabled(value) end,
            default = true,
        },
        {
            type = "submenu",
            name = "Assistants on the panel",
            tooltip = "Choose which of your assistants get a button on the panel.",
            controls = PanelToggles("assistant", "No assistants unlocked."),
        },
        {
            type = "submenu",
            name = "Companions on the panel",
            tooltip = "Choose which of your companions get a button on the panel.",
            controls = PanelToggles("companion", "No companions unlocked."),
        },

        { type = "header", name = "General" },
        {
            type = "checkbox",
            name = "Skip intro",
            tooltip = "Skip the Bethesda and ZeniMax logo videos when the game starts.\n"
                .. "Takes effect from the next game start. The game only allows this once the videos were watched once.",
            getFunc = function() return sv.misc.skipIntro end,
            setFunc = function(value) Intro:SetEnabled(value) end,
            default = true,
        },
        {
            type = "dropdown",
            name = "Auto close books",
            tooltip = "Close books you pick up in the world right away.\n"
                .. "The book is still learned. Books opened from the Lore Library, quest journal or inventory always show.",
            choices = closeNames,
            choicesValues = Books.CLOSE_ORDER,
            choicesTooltips = closeTips,
            getFunc = function() return sv.books.autoClose end,
            setFunc = function(value) Books:SetAutoClose(value) end,
            default = "read",
        },
        {
            type = "checkbox",
            name = "Mark read books",
            tooltip = "While you look at a lore book, a tag next to the interact prompt (near the cursor) shows "
                .. "whether it is already in your Lore Library (Read) or not (New).",
            getFunc = function() return sv.books.markRead end,
            setFunc = function(value) Books:SetMarkRead(value) end,
            default = true,
        },
        {
            type = "checkbox",
            name = "Mark pledge dungeons",
            tooltip = "In the Dungeon Finder list (Group & Activity Finder > Dungeons), mark the dungeons of the "
                .. "Undaunted pledges you have taken.\n"
                .. "Pledge icon: pledge taken. Check mark: pledge done, ready to hand in.",
            getFunc = function() return sv.pledges.enabled end,
            setFunc = function(value) Pledges:SetEnabled(value) end,
            default = true,
        },

        { type = "header", name = "Position" },
        {
            type = "checkbox",
            name = "Unlock bars",
            tooltip = "Drag the bars and the buff / debuff icons to a new position. "
                .. "Locked again when this page closes.\n"
                .. "Default layout: each bar moves on its own.\nOther layouts: all bars move together.\n"
                .. "The target bar moves on its own; its mini-boss bars and its buffs / debuffs move with it.\n"
                .. "The companion bar moves on its own.\n"
                .. "The cast bar moves on its own.\n"
                .. "The group frames move together as one block.\n"
                .. "Each buff / debuff group can be dragged on its own.",
            getFunc = function() return RB.unlocked end,
            setFunc = function(value) RB:SetUnlocked(value) end,
            default = false,
        },
        {
            type = "button",
            name = "Reset position",
            tooltip = "Move the bars and the buff / debuff icons back to their default position.\n"
                .. "Columns layout: same spot as the LUI player frame.\n"
                .. "Target bar: level with your Health bar, mirrored across the screen centre.\n"
                .. "Mini-boss bars: beside the target bar.\n"
                .. "Companion bar: beside Magicka (Columns), under your bars (Pyramid), above Health (Default).\n"
                .. "Cast bar: under the screen centre, where LUI puts it.\n"
                .. "Group frames: top-left, where ESO's group frames are.",
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
