-- AetherUI / CastBarData
-- Ability id tables for the cast bar. Most casts and channels are detected
-- generically through GetAbilityCastInfo(); these lists only patch the cases
-- the API gets wrong. Player abilities, innate actions and recalls only
-- (quest and memento special cases are left out on purpose).
--
-- Ids and timings are taken from LuiExtended's CastBarTable
-- (MIT License, (c) LuiExtended authors), trimmed to what applies to players.

AetherUI = AetherUI or {}

AetherUI.CastBarData = {
    -- Heavy attack wind-ups (shown only when "Show heavy attacks" is on).
    IsHeavy = {
        [15279] = true, -- One Handed
        [16420] = true, -- Dual Wield
        [16041] = true, -- Two Handed
        [16691] = true, -- Bow
        [16212] = true, -- Restoration
        [15383] = true, -- Inferno
        [16261] = true, -- Ice
        [18396] = true, -- Lightning
        [18429] = true, -- Unarmed
    },

    -- Shown even when GetAbilityCastInfo reports no cast time.
    IsCast = {
        [6811] = true,   -- Recall
        [69293] = true,  -- Sigil of Imperial Retreat
        [37059] = true,  -- Mount Up
        [141013] = true, -- Mount Up (Passenger)
        [14031] = true,  -- Mundus Use
        [14644] = true,  -- Revive (Death Dialogue)
        [32346] = true,  -- Skyshard Collect
        [151928] = true, -- Aetherial Well
        [47270] = true,  -- Ritual of Mara
        [63427] = true,  -- Clean Fish (Filet Fish)
        [78052] = true,  -- Minor Pardon
        [76350] = true,  -- Moderate Pardon
        [76349] = true,  -- Full Pardon
        -- Customized Actions: recall variants
        [209299] = true, [187552] = true, [215092] = true, [200161] = true, [215089] = true,
        [191859] = true, [199791] = true, [181388] = true, [221093] = true, [229849] = true,
        [240795] = true, [259040] = true, [247620] = true, [232080] = true,
        -- Heavy attacks (filtered by the heavy setting)
        [15279] = true, [16420] = true, [16041] = true, [16691] = true, [16212] = true,
        [15383] = true, [16261] = true, [18396] = true, [18429] = true,
    },

    -- Never shown (off-GCD toggles).
    Ignore = {
        [132141] = true, -- Blood Frenzy
        [134160] = true, -- Simmering Frenzy
        [135841] = true, -- Sated Fury
    },

    -- Fixed duration (ms) where the API reports none or a wrong one.
    DurationFix = {
        [115478] = 1200, -- Bone Goliath Transformation (self snare)
        [118673] = 1200, -- Pummeling Goliath
        [118287] = 1200, -- Ravenous Goliath
        [20930] = 5000,  -- Engulfing Dragonfire
        [185805] = 4500, -- Fatecarver (magicka)
        [193331] = 4500, -- Fatecarver (stamina)
        [183122] = 4500, -- Exhausting Fatecarver (magicka)
        [193397] = 4500, -- Exhausting Fatecarver (stamina)
        [186366] = 4500, -- Pragmatic Fatecarver (magicka)
        [193398] = 4500, -- Pragmatic Fatecarver (stamina)
        [189533] = 4500, -- Fatecarver (channel)
        [37059] = 1165,  -- Mount Up
        [141013] = 1165, -- Mount Up (Passenger)
        [14644] = 4000,  -- Revive (Death Dialogue)
        [32346] = 5800,  -- Skyshard Collect
        [151928] = 3000, -- Aetherial Well
        [47270] = 5600,  -- Ritual of Mara
        [14031] = 5000,  -- Mundus Use
    },

    -- Extra display delay (ms) on top of the duration.
    DisplayDelay = {
        [63029] = 100, -- Radiant Destruction
        [63044] = 100, -- Radiant Glory
        [63046] = 100, -- Radiant Oppression
    },

    -- Cast-time abilities shown as a channel (bar drains).
    ChannelConvert = {
        [12256] = true, -- Pack Siege
    },

    -- Channel buff whose combat id ticks GAINED every hit: start once from the slotted id.
    ChannelTrack = {
        [32821] = { slottedId = 20930, durationMs = 5000 }, -- Engulfing Dragonfire
    },

    -- Cast stops when this effect fades from the player.
    BreakOnEffectFaded = {
        [33208] = true,  -- Devour (Werewolf)
        [134583] = true, -- Vampiric Drain
        [135905] = true, -- Drain Vigor
        [137259] = true, -- Exhilarating Drain
        [189533] = true, -- Fatecarver (channel)
        [193331] = true, -- Fatecarver (stamina)
        [193397] = true, -- Exhausting Fatecarver (stamina)
        [193398] = true, -- Pragmatic Fatecarver (stamina)
        [183537] = true, -- Remedy Cascade
        [186193] = true, -- Cascading Fortune
        [198309] = true, -- Remedy Cascade (stamina)
        [198330] = true, -- Cascading Fortune (stamina)
        [186200] = true, -- Curative Surge
        [198537] = true, -- Curative Surge (stamina)
        [32821] = true,  -- Engulfing Dragonfire
    },

    -- Cast stops as soon as the player moves (the game cancels these on movement).
    BreakOnMove = {
        [6811] = true,   -- Recall
        [69293] = true,  -- Sigil of Imperial Retreat
        [209299] = true, [187552] = true, [215092] = true, [200161] = true, [215089] = true,
        [191859] = true, [199791] = true, [181388] = true, [221093] = true, [229849] = true,
        [240795] = true, [259040] = true, [247620] = true, [232080] = true,
        [63427] = true,  -- Clean Fish
        [78052] = true, [76350] = true, [76349] = true, -- Pardon edicts
        [40515] = true,  -- Devour (Werewolf)
    },

    -- Player actions that cancel any cast.
    BreakingActions = {
        [28549] = true, -- Roll Dodge
        [55146] = true, -- Interrupt Bonus (bash)
    },

    -- Casts that block, dodge and crowd control do not cancel.
    IgnoreBreak = {
        [86792] = true, -- Eating (High Hrothgar Festival Mints)
        [43700] = true, -- Wand of Finding
        [81575] = true, -- WitchFest Cauldron
    },

    -- Stuns caused by the cast itself (do not cancel it).
    IgnoreStun = {
        [36434] = true,  -- Mount Up
        [141001] = true, -- Mount Up (Passenger)
        [74232] = true,  -- Malacath's Wrathful Flame
        [92863] = true,  -- Dreamer's Chime
        [115046] = true, -- Nascent Indrik
    },
}
