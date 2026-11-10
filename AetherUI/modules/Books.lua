-- AetherUI / Books
--   * Auto close books: "off" | "read" (only books already in the Lore Library) | "all".
--     Lore is still learned: the game learns a book when you interact with it,
--     whether or not the reader opens. Books read from the Lore Library, the
--     quest journal or the inventory are never closed.
--   * Mark read books: while the reticle is on a lore book, a small "Read" /
--     "New" tag sits next to the interact prompt (near the cursor).
--
-- Performance:
--   * Nothing is hooked or registered until a feature is first switched on.
--   * The title index (every lore book) is built once, on first use, and kept
--     current from the "book learned" events - no rescans.
--   * The reticle hook does one API call per frame while an interact prompt is
--     up and only touches the label when the looked-at object changes.

local AUI = AetherUI

local Books = {}
AUI.Books = Books

Books.CLOSE_ORDER = { "off", "read", "all" }

local CLOSE_OFF, CLOSE_READ, CLOSE_ALL = "off", "read", "all"
local JUST_LEARNED_MS = 3000 -- a book learned this recently counts as new (it was just opened)

local ICON_READ = "EsoUI/Art/Cadwell/check.dds"
local ICON_NEW = "EsoUI/Art/ZoneStories/completionTypeIcon_lorebooks.dds"
local TEXT_READ, TEXT_NEW -- built once, on first use

local unreadByTitle   -- normalized title -> number of unread books with that title (nil = not a lore book)
local learnedAt = {}  -- bookId -> frame time (ms) it was learned this session

local closeHooked, markHooked, eventsRegistered = false, false, false
local markLabel, lastName

-- Book titles may carry grammar suffixes ("^n") and differ in case.
local function NormalizeTitle(title)
    if not title or title == "" then return nil end
    local caret = title:find("^", 1, true)
    if caret then title = title:sub(1, caret - 1) end
    return zo_strlower(title)
end

-- Title index ----------------------------------------------------------------------
local function BuildIndex()
    unreadByTitle = {}
    for categoryIndex = 1, GetNumLoreCategories() do
        local _, numCollections = GetLoreCategoryInfo(categoryIndex)
        for collectionIndex = 1, numCollections do
            local _, _, _, numBooks = GetLoreCollectionInfo(categoryIndex, collectionIndex)
            for bookIndex = 1, numBooks do
                local title, _, known = GetLoreBookInfo(categoryIndex, collectionIndex, bookIndex)
                local key = NormalizeTitle(title)
                if key then
                    unreadByTitle[key] = (unreadByTitle[key] or 0) + (known and 0 or 1)
                end
            end
        end
    end
end

local function OnBookLearned(_, categoryIndex, collectionIndex, bookIndex)
    local title, _, _, bookId = GetLoreBookInfo(categoryIndex, collectionIndex, bookIndex)
    if bookId then learnedAt[bookId] = GetFrameTimeMilliseconds() end
    if unreadByTitle then
        local key = NormalizeTitle(title)
        local unread = key and unreadByTitle[key]
        if unread and unread > 0 then unreadByTitle[key] = unread - 1 end
    end
    lastName = nil -- re-evaluate the reticle tag
end

local function RegisterEvents()
    if eventsRegistered then return end
    eventsRegistered = true
    EVENT_MANAGER:RegisterForEvent("AetherUI_Books", EVENT_LORE_BOOK_LEARNED, OnBookLearned)
    EVENT_MANAGER:RegisterForEvent("AetherUI_Books", EVENT_LORE_BOOK_LEARNED_SKILL_EXPERIENCE, OnBookLearned)
end

-- Auto close -----------------------------------------------------------------------
-- Known status straight from the book id: exact, no title ambiguity.
local function IsBookRead(bookId)
    if not bookId or bookId == 0 then return false end -- not a lore book (notes, letters...)
    local learned = learnedAt[bookId]
    if learned and GetFrameTimeMilliseconds() - learned < JUST_LEARNED_MS then return false end
    local categoryIndex, collectionIndex, bookIndex = GetLoreBookIndicesFromBookId(bookId)
    if not categoryIndex then return false end
    local _, _, known = GetLoreBookInfo(categoryIndex, collectionIndex, bookIndex)
    return known
end

function Books:ShouldClose(bookId)
    local mode = self.sv.autoClose
    if mode == CLOSE_OFF then return false end
    -- Opened on purpose from the inventory / journal: always show it.
    local scene = SCENE_MANAGER:GetCurrentScene()
    if scene and LORE_READER:GetCustomSceneInfo(scene:GetName()) then return false end
    return mode == CLOSE_ALL or IsBookRead(bookId)
end

-- Takes over the lore reader's EVENT_SHOW_BOOK handler (same two lines as the base
-- game's) so the decision is made before anything is shown: no one-frame flash,
-- and it does not depend on event handler order.
local function HookAutoClose()
    if closeHooked or not LORE_READER then return end
    closeHooked = true
    RegisterEvents()
    local control = LORE_READER.control
    control:UnregisterForEvent(EVENT_SHOW_BOOK)
    control:RegisterForEvent(EVENT_SHOW_BOOK, function(_, title, body, medium, showTitle, bookId)
        if Books:ShouldClose(bookId) then
            EndInteraction(INTERACTION_BOOK)
            return
        end
        local overrideImage, overrideImageTitlePosition = GetLoreBookOverrideImageFromBookId(bookId)
        LORE_READER:Show(title, body, medium, showTitle, overrideImage, overrideImageTitlePosition)
    end)
end

-- Reticle tag ----------------------------------------------------------------------
local function CreateMarkLabel()
    local interact = RETICLE.interact
    local label = WINDOW_MANAGER:CreateControl("AetherUI_BookMark", interact, CT_LABEL)
    label:SetFont("ZoFontWinH4")
    label:SetAnchor(LEFT, RETICLE.interactKeybindButton, RIGHT, 12, 0)
    label:SetHidden(true)
    TEXT_READ = ZO_SUCCEEDED_TEXT:Colorize(zo_iconTextFormatNoSpace(ICON_READ, 22, 22, "Read", true))
    TEXT_NEW = ZO_SELECTED_TEXT:Colorize(zo_iconTextFormatNoSpace(ICON_NEW, 22, 22, "New", true))
    return label
end

local function UpdateMark(reticle)
    -- The label is a child of the interact prompt: it hides with it for free.
    if not Books.sv.markRead or reticle.interact:IsHidden() then
        lastName = nil
        return
    end
    local _, name = GetGameCameraInteractableActionInfo()
    if name == lastName then return end
    lastName = name

    if not unreadByTitle then BuildIndex() end
    local key = NormalizeTitle(name)
    local unread = key and unreadByTitle[key]
    local text = unread and (unread == 0 and TEXT_READ or TEXT_NEW)
    if text then markLabel:SetText(text) end
    markLabel:SetHidden(text == nil)
end

local function HookMark()
    if markHooked or not RETICLE then return end
    markHooked = true
    RegisterEvents()
    markLabel = CreateMarkLabel()
    local hook = SecurePostHook or ZO_PostHook
    hook(RETICLE, "UpdateInteractText", UpdateMark)
end

-- Public -----------------------------------------------------------------------------
function Books:ApplyEnabled()
    if self.sv.autoClose ~= CLOSE_OFF then HookAutoClose() end
    if self.sv.markRead then
        HookMark()
    elseif markLabel then
        markLabel:SetHidden(true)
    end
    lastName = nil
end

function Books:SetAutoClose(mode)
    if mode ~= CLOSE_OFF and mode ~= CLOSE_READ and mode ~= CLOSE_ALL then return end
    if self.sv.autoClose == mode then return end
    self.sv.autoClose = mode
    self:ApplyEnabled()
end

function Books:SetMarkRead(enabled)
    enabled = enabled and true or false
    if self.sv.markRead == enabled then return end
    self.sv.markRead = enabled
    self:ApplyEnabled()
end

function Books:Initialize(sv)
    self.sv = sv.books
    self:ApplyEnabled()
end

function Books:HandleCommand(cmd, rest)
    if cmd == "books" then
        if rest == CLOSE_OFF or rest == CLOSE_READ or rest == CLOSE_ALL then
            self:SetAutoClose(rest)
            AUI:Print("auto close books: " .. rest)
        else
            AUI:Print("auto close books: " .. self.sv.autoClose .. ". /aether books <off|read|all>")
        end
        return true
    elseif cmd == "bookmark" then
        if rest == "on" or rest == "off" then
            self:SetMarkRead(rest == "on")
            AUI:Print("mark read books " .. rest)
        else
            AUI:Print("mark read books: " .. (self.sv.markRead and "on" or "off") .. ". /aether bookmark <on|off>")
        end
        return true
    end
    return false
end

AUI:RegisterModule("Books", Books)
