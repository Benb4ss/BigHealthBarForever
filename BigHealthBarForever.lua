-- Big player and target health bars.
-- Custom StatusBars over Blizzard's health bars.
--
-- Text rule: addon code never compares or does arithmetic on game numbers
-- (they can be secret in combat). Text is built only with
-- AbbreviateLargeNumbers (allowed on secret values) and string joining.
-- Blizzard's TextStatusBarMixin is not used, because its comparisons fail
-- in addon code during combat (TextStatusBar.lua UpdateTextStringWithValues).

local ADDON = ...

-- ===== Shared tuning =====
local WIDTH_ADJUST = 4
local HEIGHT = 75
local SUB_BAR_HEIGHT = HEIGHT / 2
local OFFSET_X = -2
local OFFSET_Y = 36
local STRATA = "MEDIUM"

-- Frame levels, bottom to top:
-- background < absorb bar < heal bar < health fill (overlay)
local BG_LEVEL = 46
local ABSORB_LEVEL = 47
local HEAL_LEVEL = 48
local LEVEL = 50

local FILL_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local BG_COLOR = { 0.05, 0.05, 0.05, 0.90 }
local HEAL_COLOR = { 0.00, 0.80, 0.30, 0.60 }
local ABSORB_COLOR = { 0.80, 0.80, 0.80, 0.70 }

local MASK_LEFT = 0
local MASK_TOP = 0
local MASK_RIGHT = 0
local MASK_BOTTOM = 0

local NAME_OFFSET_X = 0
local NAME_OFFSET_Y = -36

local HEALTH_TEXT_POINT = "RIGHT"
local HEALTH_TEXT_X = -3
local HEALTH_TEXT_Y = -10

local MANA_TEXT_POINT = "RIGHT"
local MANA_TEXT_X = -3
local MANA_TEXT_Y = 0

-- Text formats, chosen per unit in /bhf.
local FORMATS = {
    {"current",    "Current"},
    {"currentMax", "Current / Max"},
    {"missing",    "Missing"},
    {"missingMax", "Missing / Max"},
}
local DEFAULT_FORMAT = "current"

-- Per-character settings. Replaced by the saved table on ADDON_LOADED.
local charDb = {
    playerFormat = DEFAULT_FORMAT,
    targetFormat = DEFAULT_FORMAT,
    playerManaFormat = DEFAULT_FORMAT,
    targetManaFormat = DEFAULT_FORMAT,
}

-- Refresh function for each bar, so the options panel can refresh them.
local refreshers = {}

-- ===== Shared helpers =====
local function HideBlizzardName(...)
    for _, parent in ipairs({ ... }) do
        if parent then
            for key, value in pairs(parent) do
                if type(key) == "string"
                    and string.find(key, "Name")
                    and type(value) == "table"
                    and value.GetObjectType then

                    local kind = value:GetObjectType()
                    if kind == "FontString" or kind == "Frame" then
                        value:SetAlpha(0)
                    end
                end
            end
        end
    end
end

-- Hides Blizzard's incoming heal and absorb bars so they don't show
-- alongside ours. Matches by key name, same approach as HideBlizzardName.
local function HideBlizzardPrediction(...)
    for _, parent in ipairs({ ... }) do
        if parent then
            for key, value in pairs(parent) do
                if type(key) == "string"
                    and (string.find(key, "Prediction")
                        or string.find(key, "Absorb"))
                    and type(value) == "table"
                    and value.SetAlpha then

                    value:SetAlpha(0)
                end
            end
        end
    end
end

local function TrimLastChar(s)
    s = s:sub(1, -2)

    while #s > 0
        and s:byte(-1) >= 0x80
        and s:byte(-1) < 0xC0 do
        s = s:sub(1, -2)
    end

    if #s > 0 and s:byte(-1) >= 0xC0 then
        s = s:sub(1, -2)
    end

    return s
end

-- Runs a measurement and returns its result only when the value is
-- usable by addon code. Secret numbers survive a plain pcall and only
-- error later, at the first forbidden operation, so the probe does
-- that operation on the value itself. Returns nil for secrets.
local function SafeMeasure(fn)
    local ok, v = pcall(fn)
    if not ok or v == nil then
        return nil
    end

    if not pcall(function()
        return v <= v
    end) then
        return nil
    end

    return v
end

-- True only when a game value is exactly 0. A secret value can't be
-- compared, so that case returns false.
local function IsExactlyZero(value)
    local ok, zero = pcall(function()
        return value == 0
    end)

    return ok and zero == true
end

-- Standalone font string for measuring text, created outside
-- Blizzard's frame tree. Font measurements on font strings inside
-- that tree (nameText is parented to the unit frame) can come back
-- as secret values, so all text measuring happens here instead.
local measureFrame = CreateFrame("Frame")
measureFrame:Hide()

local measureText = measureFrame:CreateFontString(
    nil,
    "OVERLAY",
    "GameFontNormal"
)

local function MeasureText(text)
    return SafeMeasure(function()
        measureText:SetText(text)
        return measureText:GetStringWidth()
    end)
end

local function FitName(bar, nameText, unit)
    local name, surname = UnitName(unit)
    name = name or ""
    if surname and surname ~= "" then
        name = name .. " " .. surname
    end

    -- Only a real, positive bar width is trusted. Secret or missing
    -- widths fall back to the last good one and never poison the
    -- cache with a zero, which is what made the fit stick as
    -- untrimmed before.
    local maxWidth = SafeMeasure(function()
        return bar:GetWidth() - 4
    end)

    if maxWidth and maxWidth > 0 then
        nameText.lastGoodWidth = maxWidth
    else
        maxWidth = nameText.lastGoodWidth
    end

    local textWidth = MeasureText(name)

    if not maxWidth or not textWidth then
        -- Measurement unavailable. Reuse the last fitted text for
        -- this name when one exists; show the full name for names
        -- never fitted. Nothing is cached, so the next update
        -- retries the fit.
        local fit = nameText.fits and nameText.fits[name]

        if fit then
            nameText:SetText(fit)
        else
            nameText:SetText(name)
            nameText.lastName = nil
        end

        return
    end

    if name == nameText.lastName
        and maxWidth == nameText.lastWidth then
        return
    end

    nameText.lastName = name
    nameText.lastWidth = maxWidth
    nameText.fits = nameText.fits or {}

    local fitted = name

    if maxWidth > 0 and textWidth > maxWidth then
        local s = name

        while #s > 0 do
            s = TrimLastChar(s)
            fitted = s .. "..."

            local width = MeasureText(fitted)

            if not width then
                -- Secret state mid-trim: fall back to the last good
                -- fit for this name.
                fitted = nameText.fits[name] or name
                break
            end

            if width <= maxWidth then
                break
            end
        end
    end

    nameText:SetText(fitted)
    nameText.fits[name] = fitted

    -- Keep the fit cache bounded.
    local count = 0

    for _ in pairs(nameText.fits) do
        count = count + 1
    end

    if count > 50 then
        wipe(nameText.fits)
        nameText.fits[name] = fitted
    end
end

local function CreateBackground(parent)
    local background = CreateFrame("Frame", nil, parent)
    background:SetFrameStrata(STRATA)
    background:SetFrameLevel(BG_LEVEL)

    local texture = background:CreateTexture(nil, "BACKGROUND")
    texture:SetAllPoints()
    texture:SetColorTexture(
        BG_COLOR[1],
        BG_COLOR[2],
        BG_COLOR[3],
        BG_COLOR[4]
    )

    return background
end

-- ===== Status text (no Blizzard text mixin) =====

-- "-missing" text. A secret value can't be compared, so the "0" case is
-- only used when the value can be read.
local function MissingText(missing)
    local okPositive, positive = pcall(function()
        return missing > 0
    end)

    if okPositive and not positive then
        return "0"
    end

    return "-" .. AbbreviateLargeNumbers(missing)
end

-- Builds the text for one format. source.value(), source.max() and
-- source.missing() return game numbers, which may be secret. If the
-- chosen format can't be built, falls back to the current value. If even
-- that fails, returns an empty string.
local function BuildStatusText(format, source)
    local ok, text = pcall(function()
        if format == "currentMax" then
            return AbbreviateLargeNumbers(source.value())
                .. " / "
                .. AbbreviateLargeNumbers(source.max())
        end

        if format == "missing" or format == "missingMax" then
            local missingText = MissingText(source.missing())

            if format == "missingMax" then
                return missingText
                    .. " / "
                    .. AbbreviateLargeNumbers(source.max())
            end

            return missingText
        end

        return AbbreviateLargeNumbers(source.value())
    end)

    if ok then
        return text
    end

    local okCurrent, current = pcall(function()
        return AbbreviateLargeNumbers(source.value())
    end)

    if okCurrent then
        return current
    end

    return ""
end

-- Attaches status text to a bar. host is the StatusBar that runs the
-- OnUpdate and OnHide handlers. hoverFrame is the frame whose mouseover
-- reveals the text. Hover uses a rectangle test (IsMouseOver), so no mouse
-- input is taken from Blizzard's bars.
-- Visibility follows the Status Text option (cvar "statusText") and hover,
-- as Blizzard's bars do (TextStatusBar.lua). Sets host.RefreshStatusText.
local function AttachStatusText(host, hoverFrame, fontString, getFormat, source)
    local hovered = false

    local function Refresh()
        local shouldShow = (GetCVar("statusText") == "1" or hovered)
            and not source.forceHide()

        if not shouldShow then
            fontString:Hide()
            return
        end

        fontString:SetText(BuildStatusText(getFormat(), source))
        fontString:Show()
    end

    host.RefreshStatusText = Refresh

    host:SetScript("OnUpdate", function()
        local over = hoverFrame:IsMouseOver()

        if over ~= hovered then
            hovered = over
            Refresh()
        end
    end)

    host:SetScript("OnHide", function()
        if hovered then
            hovered = false
            Refresh()
        end
    end)
end

local function CreateOverlay(parent, blizzBar, blizzMask, globalName)
    local overlay = CreateFrame("StatusBar", globalName, parent)
    overlay:EnableMouse(false)
    overlay:SetStatusBarTexture(FILL_TEXTURE)

    local blizzFill = blizzBar:GetStatusBarTexture()
    local fillAtlas = blizzFill and blizzFill:GetAtlas()

    if fillAtlas then
        local fill = overlay:GetStatusBarTexture()
        fill:SetAtlas(fillAtlas)
        fill:SetDesaturated(true)
    end

    local mask = overlay:CreateMaskTexture()
    mask:SetPoint("TOPLEFT", overlay, "TOPLEFT", MASK_LEFT, MASK_TOP)
    mask:SetPoint(
        "BOTTOMRIGHT",
        overlay,
        "BOTTOMRIGHT",
        MASK_RIGHT,
        MASK_BOTTOM
    )

    local maskAtlas = blizzMask and blizzMask:GetAtlas()

    if maskAtlas then
        mask:SetAtlas(maskAtlas)
        overlay:GetStatusBarTexture():AddMaskTexture(mask)
    end

    local nameText = overlay:CreateFontString(
        nil,
        "OVERLAY",
        "GameFontNormal"
    )

    nameText:SetPoint(
        "BOTTOM",
        overlay,
        "TOP",
        NAME_OFFSET_X,
        NAME_OFFSET_Y
    )
    nameText:SetWordWrap(false)

    -- Health text, at our own position (not Blizzard's).
    local healthText = overlay:CreateFontString(
        nil,
        "OVERLAY",
        "TextStatusBarText"
    )

    healthText:SetPoint(
        HEALTH_TEXT_POINT,
        overlay,
        HEALTH_TEXT_POINT,
        HEALTH_TEXT_X,
        HEALTH_TEXT_Y
    )

    blizzBar:SetAlpha(0)

    return overlay, nameText, healthText
end

-- Blizzard frame widths can come back as secret number values once
-- combat starts, and GetWidth() + WIDTH_ADJUST then errors out. The
-- layout anchors both edges instead of reading any width, so it stays
-- taint-safe during combat.
local function ApplyLayout(overlay, blizzBar)
    overlay:ClearAllPoints()
    overlay:SetPoint(
        "TOPLEFT",
        blizzBar,
        "TOPLEFT",
        OFFSET_X,
        OFFSET_Y
    )
    overlay:SetPoint(
        "TOPRIGHT",
        blizzBar,
        "TOPRIGHT",
        WIDTH_ADJUST + OFFSET_X,
        OFFSET_Y
    )
    overlay:SetHeight(HEIGHT)

    overlay:SetFrameStrata(STRATA)
    overlay:SetFrameLevel(LEVEL)
end

local function UpdateHealth(overlay, unit)
    local maxHealth = UnitHealthMax(unit)
    local health = UnitHealth(unit)

    -- Zero-max guard, as in UnitFrameHealthBar_Update (UnitFrame.lua).
    overlay.forceHideText = false

    if IsExactlyZero(maxHealth) then
        maxHealth = 1
        overlay.forceHideText = true
    end

    overlay:SetMinMaxValues(0, maxHealth)
    overlay:SetValue(health)
    overlay.RefreshStatusText()
end

-- Registers an event without erroring if the client doesn't know the name.
local function SafeRegister(frame, event, unit)
    if unit then
        pcall(frame.RegisterUnitEvent, frame, event, unit)
    else
        pcall(frame.RegisterEvent, frame, event)
    end
end

-- Creates the heal and absorb bars over the health bar.
--
-- Both bars are as wide as the health bar and scaled to max health, the
-- same scale Blizzard uses (UnitFrameHealPredictionBars_Update). Unlike
-- Blizzard, they are not clamped to the bar, so they can run past its
-- right edge when incoming heals or absorbs exceed missing health.
-- Each bar starts at the edge of the one before it:
--   health fill -> heal bar -> absorb bar
--
-- Width is read from the overlay and cached, like FitName's
-- lastGoodWidth, so a secret value in combat keeps the last good width.
--
-- Returns an Update function that refreshes both bars.
local function CreatePredictionBars(container, overlay, unit)
    local fill = overlay:GetStatusBarTexture()
    local barWidth = 0

    local healBar = CreateFrame("StatusBar", nil, container)
    healBar:EnableMouse(false)
    healBar:SetStatusBarTexture(FILL_TEXTURE)
    healBar:SetStatusBarColor(
        HEAL_COLOR[1],
        HEAL_COLOR[2],
        HEAL_COLOR[3],
        HEAL_COLOR[4]
    )
    healBar:SetFrameStrata(STRATA)
    healBar:SetFrameLevel(HEAL_LEVEL)
    healBar:SetPoint("LEFT", fill, "RIGHT")
    healBar:SetHeight(SUB_BAR_HEIGHT)

    local absorbBar = CreateFrame("StatusBar", nil, container)
    absorbBar:EnableMouse(false)
    absorbBar:SetStatusBarTexture(FILL_TEXTURE)
    absorbBar:SetStatusBarColor(
        ABSORB_COLOR[1],
        ABSORB_COLOR[2],
        ABSORB_COLOR[3],
        ABSORB_COLOR[4]
    )
    absorbBar:SetFrameStrata(STRATA)
    absorbBar:SetFrameLevel(ABSORB_LEVEL)
    absorbBar:SetPoint("LEFT", healBar:GetStatusBarTexture(), "RIGHT")
    absorbBar:SetHeight(SUB_BAR_HEIGHT)

    local function ApplyWidth()
        local width = SafeMeasure(function()
            return overlay:GetWidth()
        end)

        if width and width > 0 then
            barWidth = width
        end

        if barWidth > 0 then
            healBar:SetWidth(barWidth)
            absorbBar:SetWidth(barWidth)
        end
    end

    local function Update()
        if not UnitExists(unit) then
            healBar:Hide()
            absorbBar:Hide()
            return
        end

        ApplyWidth()

        -- Same calls as UnitFrameHealPredictionBars_Update: UnitGetIncomingHeals
        -- and UnitGetTotalAbsorbs. Everything is inside one protected call, so
        -- a secret value here can only hide these two bars, not break the rest.
        local ok = pcall(function()
            local incoming = UnitGetIncomingHeals(unit) or 0
            local absorbs = UnitGetTotalAbsorbs(unit) or 0
            local maxHealth = UnitHealthMax(unit)

            healBar:SetMinMaxValues(0, maxHealth)
            healBar:SetValue(incoming)
            absorbBar:SetMinMaxValues(0, maxHealth)
            absorbBar:SetValue(absorbs)
        end)

        if ok then
            healBar:Show()
            absorbBar:Show()
        else
            healBar:Hide()
            absorbBar:Hide()
        end
    end

    return Update
end

-- ===== Mana text =====
-- Blizzard's mana bar keeps its fill. Its own text is hidden, and a
-- StatusBar holder draws our text in the chosen format.
-- Settings are copied from Blizzard's mana bar (PlayerFrame.xml ManaBar,
-- TargetFrameStatusBarMixin:OnLoad).
local function CreateManaText(manaBar, unit, globalName, formatKey)
    local holder = CreateFrame("StatusBar", globalName, manaBar:GetParent())
    holder:EnableMouse(false)
    holder:SetAllPoints(manaBar)
    holder:SetFrameStrata(STRATA)
    holder:SetFrameLevel(LEVEL)

    local centerText = holder:CreateFontString(
        nil,
        "OVERLAY",
        "TextStatusBarText"
    )

    centerText:SetPoint(
        MANA_TEXT_POINT,
        holder,
        MANA_TEXT_POINT,
        MANA_TEXT_X,
        MANA_TEXT_Y
    )

    local source = {
        value = function()
            return UnitPower(unit, manaBar.powerType)
        end,
        max = function()
            return UnitPowerMax(unit, manaBar.powerType)
        end,
        missing = function()
            return UnitPowerMissing(unit, manaBar.powerType)
        end,
        forceHide = function()
            return holder.forceHideText
        end,
    }

    AttachStatusText(
        holder,
        manaBar,
        centerText,
        function()
            return charDb[formatKey] or DEFAULT_FORMAT
        end,
        source
    )

    -- Hide Blizzard's mana text so only ours shows.
    if manaBar.ManaBarText then
        manaBar.ManaBarText:SetAlpha(0)
    end

    if manaBar.LeftText then
        manaBar.LeftText:SetAlpha(0)
    end

    if manaBar.RightText then
        manaBar.RightText:SetAlpha(0)
    end

    return function()
        local maxPower = UnitPowerMax(unit, manaBar.powerType)
        local power = UnitPower(unit, manaBar.powerType)

        holder.forceHideText = false

        if IsExactlyZero(maxPower) then
            maxPower = 1
            holder.forceHideText = true
        end

        holder:SetMinMaxValues(0, maxPower)
        holder:SetValue(power)
        holder.RefreshStatusText()
    end
end

-- Wraps a mana refresh so an error is reported once per failure streak.
local function MakeManaUpdater(name, refresh)
    local reported = false

    return function()
        local ok, err = pcall(refresh)

        if not ok then
            if not reported then
                reported = true
                print(name .. ": mana text update failed: " .. tostring(err))
            end
        else
            reported = false
        end
    end
end

-- Dark box behind the player's mana bar, created on ManaBarArea so it sits
-- under the bar's own frame level.
local function CreateManaBackground(manaArea, manaBar)
    local manaBackground = CreateFrame("Frame", nil, manaArea)
    manaBackground:SetPoint("TOPLEFT", manaBar, "TOPLEFT", -1, 1)
    manaBackground:SetPoint("BOTTOMRIGHT", manaBar, "BOTTOMRIGHT", 1, -1)

    -- GetFrameLevel() can also return a secret value in combat.
    local okLevel, level = pcall(function()
        return math.max(0, manaBar:GetFrameLevel() - 1)
    end)
    manaBackground:SetFrameLevel(okLevel and level or 0)

    local manaTexture = manaBackground:CreateTexture(nil, "BACKGROUND")
    manaTexture:SetAllPoints()
    manaTexture:SetColorTexture(0.05, 0.05, 0.05, 1)

    return manaBackground
end

-- Health bar colour for the player: class colour, or green if none.
local function ApplyPlayerColor(overlay, unit)
    local _, token = UnitClass(unit)
    local color = token and CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[token]
        or token and RAID_CLASS_COLORS[token]

    if color then
        overlay:SetStatusBarColor(color.r, color.g, color.b)
    else
        overlay:SetStatusBarColor(0, 1, 0)
    end
end

-- Health bar colour for the target: class colour for players, otherwise the
-- game's reaction colour (UnitSelectionColor).
local function ApplyTargetColor(overlay, unit)
    local ok, r, g, b = pcall(function()
        if not UnitIsPlayer(unit) then
            return nil
        end

        local _, token = UnitClass(unit)
        local color = token and CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[token]
            or token and RAID_CLASS_COLORS[token]

        if color then
            return color.r, color.g, color.b
        end
    end)

    if ok and r then
        overlay:SetStatusBarColor(r, g, b)
    else
        overlay:SetStatusBarColor(UnitSelectionColor(unit, false))
    end
end

-- Shared factory for a unit's big health bar. The per-unit differences come
-- in through config; everything else is the same code for both bars.
-- Returns SafeUpdate (health, names, prediction, mana) and ManaSafeUpdate.
local function CreateUnitHealthBar(config)
    local unit = config.unit
    local main = config.main
    local container = main.HealthBarsContainer
    local blizzBar = container.HealthBar
    local blizzMask = container.HealthBarMask

    local overlay, nameText, healthText = CreateOverlay(
        container,
        blizzBar,
        blizzMask,
        config.name
    )

    local background = CreateBackground(container)

    background:SetPoint("TOPLEFT", overlay, "LEFT", 3, 16)
    background:SetPoint(
        "BOTTOMRIGHT",
        config.backgroundAnchor(overlay, main),
        "BOTTOMRIGHT",
        config.backgroundX,
        config.backgroundY
    )

    -- Hide Blizzard's original health text, name, and prediction bars.
    if container.HealthBarText then
        container.HealthBarText:SetAlpha(0)
    end

    HideBlizzardName(config.frame, main)
    HideBlizzardPrediction(container, blizzBar)

    local manaBar = config.getManaBar(main)

    local manaBackground = nil

    if config.hasManaBackground then
        manaBackground = CreateManaBackground(main.ManaBarArea, manaBar)
    end

    -- Health text, built by our own code.
    local healthSource = {
        value = function()
            return UnitHealth(unit)
        end,
        max = function()
            return UnitHealthMax(unit)
        end,
        missing = function()
            return UnitHealthMissing(unit)
        end,
        forceHide = function()
            return overlay.forceHideText
        end,
    }

    AttachStatusText(
        overlay,
        overlay,
        healthText,
        function()
            return charDb[config.healthFormatKey] or DEFAULT_FORMAT
        end,
        healthSource
    )

    local UpdatePrediction = CreatePredictionBars(container, overlay, unit)

    local ManaSafeUpdate = MakeManaUpdater(
        config.manaName,
        CreateManaText(manaBar, unit, config.manaName, config.manaFormatKey)
    )

    local function ShowAll()
        background:Show()

        if manaBackground then
            manaBackground:Show()
        end

        overlay:Show()
    end

    local function Update()
        if not UnitExists(unit) then
            overlay:Hide()
            background:Hide()
            UpdatePrediction()
            return
        end

        ApplyLayout(overlay, blizzBar)
        config.applyColor(overlay, unit)
        FitName(overlay, nameText, unit)

        -- Prediction runs before health, so a failure in the health text
        -- cannot stop the heal and absorb bars from updating.
        UpdatePrediction()
        UpdateHealth(overlay, unit)

        ShowAll()
    end

    -- Recovery wrapper: an error must not permanently hide the bar.
    -- The error is reported once per failure streak so the root cause
    -- stays visible instead of being silently swallowed by pcall.
    local reported = false

    local function SafeUpdate()
        local ok, err = pcall(Update)

        if not ok then
            if not reported then
                reported = true
                print(config.name .. ": update failed: " .. tostring(err))
            end

            local existsOK, exists = pcall(UnitExists, unit)

            if existsOK and exists then
                -- ApplyLayout runs in its own pcall so a secret-value error
                -- here can never skip the Show calls below. The old version
                -- bundled them together, which is why the bar vanished for
                -- the rest of the fight.
                pcall(ApplyLayout, overlay, blizzBar)
                pcall(ShowAll)
            end
        else
            reported = false
        end

        ManaSafeUpdate()
    end

    -- Unit events use RegisterUnitEvent, so this frame does not wake for
    -- other units. Global events (PLAYER_ENTERING_WORLD and similar) stay plain.
    local events = CreateFrame("Frame")

    for _, event in ipairs(config.globalEvents) do
        events:RegisterEvent(event)
    end

    for _, event in ipairs(config.unitEvents) do
        events:RegisterUnitEvent(event, unit)
    end

    SafeRegister(events, "UNIT_HEAL_PREDICTION", unit)
    SafeRegister(events, "UNIT_ABSORB_AMOUNT_CHANGED", unit)

    events:SetScript("OnEvent", function(_, event, arg1)
        -- The Status Text option changed: refresh so the text shows or hides.
        if event == "CVAR_UPDATE" then
            if arg1 == "statusText" then
                SafeUpdate()
            end

            return
        end

        if event == "UNIT_POWER_UPDATE" or event == "UNIT_MAXPOWER" then
            ManaSafeUpdate()
            return
        end

        SafeUpdate()
    end)

    -- Optional failsafe: rerun the full update on an interval. Covers missed
    -- events, mistimed targeting, and any state where the bar ended up hidden
    -- or covered without an event to recover it.
    if config.failsafeInterval then
        local elapsed = 0

        events:SetScript("OnUpdate", function(_, delta)
            elapsed = elapsed + delta

            if elapsed >= config.failsafeInterval then
                elapsed = 0
                SafeUpdate()
            end
        end)
    end

    SafeUpdate()

    return {
        SafeUpdate = SafeUpdate,
        ManaSafeUpdate = ManaSafeUpdate,
    }
end

-- ===== Player health bar =====
do
    local bar = CreateUnitHealthBar({
        unit = "player",
        name = "BigPlayerHealthBar",
        frame = PlayerFrame,
        main = PlayerFrame.PlayerFrameContent.PlayerFrameContentMain,

        -- Background sits on the health overlay on purpose. This keeps the
        -- current look.
        backgroundAnchor = function(overlay)
            return overlay
        end,
        backgroundX = -3,
        backgroundY = 21,

        -- ManaBar sits under ManaBarArea (PlayerFrame.xml). PlayerFrame_GetManaBar
        -- (PlayerFrame.lua) returns this same object.
        getManaBar = function(main)
            return main.ManaBarArea.ManaBar
        end,
        hasManaBackground = true,

        healthFormatKey = "playerFormat",
        manaName = "BigPlayerManaText",
        manaFormatKey = "playerManaFormat",
        applyColor = ApplyPlayerColor,

        globalEvents = { "PLAYER_ENTERING_WORLD", "CVAR_UPDATE" },
        unitEvents = {
            "UNIT_HEALTH",
            "UNIT_MAXHEALTH",
            "UNIT_NAME_UPDATE",
            "UNIT_DISPLAYPOWER",
            "UNIT_POWER_UPDATE",
            "UNIT_MAXPOWER",
        },
    })

    refreshers.player = bar.SafeUpdate
    refreshers.playerMana = bar.ManaSafeUpdate
end

-- ===== Target health bar =====
do
    local bar = CreateUnitHealthBar({
        unit = "target",
        name = "BigTargetHealthBar",
        frame = TargetFrame,
        main = TargetFrame.TargetFrameContent.TargetFrameContentMain,

        backgroundAnchor = function(overlay, main)
            return main.ManaBar or overlay
        end,
        backgroundX = -6,
        backgroundY = 12,

        getManaBar = function(main)
            return main.ManaBar
        end,
        hasManaBackground = false,

        healthFormatKey = "targetFormat",
        manaName = "BigTargetManaText",
        manaFormatKey = "targetManaFormat",
        applyColor = ApplyTargetColor,

        globalEvents = { "PLAYER_TARGET_CHANGED", "PLAYER_ENTERING_WORLD", "CVAR_UPDATE" },
        unitEvents = {
            "UNIT_HEALTH",
            "UNIT_MAXHEALTH",
            "UNIT_FACTION",
            "UNIT_NAME_UPDATE",
            "UNIT_POWER_UPDATE",
            "UNIT_MAXPOWER",
        },

        -- Failsafe: rerun the full update once per second.
        failsafeInterval = 1,
    })

    refreshers.target = bar.SafeUpdate
    refreshers.targetMana = bar.ManaSafeUpdate
end

-- ===== Options (/bhf) =====
-- Layout follows StatusTextFormat.lua: a Settings canvas category, dropdowns
-- built with SetupMenu and CreateRadio (Blizzard_Menu MenuImplementationGuide),
-- and Settings.OpenToCategory(category:GetID()).

local function RefreshAll()
    for _, refresh in pairs(refreshers) do
        refresh()
    end
end

local function CreateDropdown(panel, anchor, key)
    local dropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    dropdown:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
    dropdown:SetWidth(200)
    dropdown:SetupMenu(function(_, root)
        for _, entry in ipairs(FORMATS) do
            local value, label = entry[1], entry[2]
            root:CreateRadio(label,
                function() return charDb[key] == value end,
                function()
                    charDb[key] = value
                    RefreshAll()
                end,
                value)
        end
    end)

    return dropdown
end

local function CreateOptions()
    local panel = CreateFrame("Frame")
    panel.name = "BigHealthBarForever"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("BigHealthBarForever")

    -- Distance from the left edge of one column to the next.
    local COLUMN_WIDTH = 260

    local columns = {
        {
            header = "Player",
            rows = {
                {"playerFormat",     "Health text:"},
                {"playerManaFormat", "Mana text:"},
            },
        },
        {
            header = "Target",
            rows = {
                {"targetFormat",     "Health text:"},
                {"targetManaFormat", "Mana text:"},
            },
        },
    }

    local columnEnds = {}

    for col, column in ipairs(columns) do
        local left = 16 + (col - 1) * COLUMN_WIDTH

        local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        header:SetPoint("TOPLEFT", title, "BOTTOMLEFT", left - 16, -24)
        header:SetText(column.header)

        local anchor = header

        for _, row in ipairs(column.rows) do
            local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -20)
            label:SetText(row[2])
            anchor = CreateDropdown(panel, label, row[1])
        end

        columnEnds[col] = anchor
    end

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", columnEnds[1], "BOTTOMLEFT", 0, -12)
    note:SetText("If a value can't be read in combat, the text falls back to Current.")

    local command = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    command:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -6)
    command:SetText("Type /bhf to open this panel.")

    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)

    SLASH_BIGHEALTHBARFOREVER1 = "/bhf"
    SlashCmdList.BIGHEALTHBARFOREVER = function()
        Settings.OpenToCategory(category:GetID())
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end

    -- Saved per character. Fill in missing values and reject unknown
    -- formats, as StatusTextFormat.lua does.
    BigHealthBarForeverCharDB = BigHealthBarForeverCharDB or {}
    local saved = BigHealthBarForeverCharDB

    for _, key in ipairs({ "playerFormat", "targetFormat", "playerManaFormat", "targetManaFormat" }) do
        local valid = false

        for _, entry in ipairs(FORMATS) do
            if entry[1] == saved[key] then
                valid = true
            end
        end

        if not valid then
            saved[key] = DEFAULT_FORMAT
        end
    end

    charDb = saved

    CreateOptions()
    RefreshAll()
    self:UnregisterEvent("ADDON_LOADED")
end)