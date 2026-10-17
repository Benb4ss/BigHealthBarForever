-- Big player and target health bars.
-- Custom StatusBars over Blizzard's health bars.

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

local function UpdateHealth(overlay, healthText, unit)
    local maxHealth = UnitHealthMax(unit)
    local health = UnitHealth(unit)

    overlay:SetMinMaxValues(0, maxHealth)
    overlay:SetValue(health)

    if UnitHealthMissing then
        healthText:SetText(
            "-"
            .. BreakUpLargeNumbers(UnitHealthMissing(unit))
            .. " / "
            .. BreakUpLargeNumbers(maxHealth)
        )
    else
        healthText:SetText(
            BreakUpLargeNumbers(health)
            .. " / "
            .. BreakUpLargeNumbers(maxHealth)
        )
    end
end

-- Registers an event without erroring if the client doesn't know the name.
local function SafeRegister(frame, event, unit)
    if unit then
        pcall(frame.RegisterUnitEvent, frame, event, unit)
    else
        pcall(frame.RegisterEvent, frame, event)
    end
end

-- Creates the heal and absorb bars next to the health fill.
--
-- No Lua arithmetic is done on health. Each track is anchored to the
-- edge of the bar before it, so Blizzard's fill textures place it:
--   health fill -> heal track (starts at health edge, width = missing health)
--   heal fill   -> absorb track (starts at heal edge, runs to bar right edge)
--
-- Known limit: the absorb bar uses missing health as its scale. This is
-- exact when no heals are incoming. With incoming heals, the absorb is
-- drawn slightly short of its true width.
--
-- Returns an Update function that refreshes both bars.
local function CreatePredictionBars(container, overlay, unit)
    local calc = CreateUnitHealPredictionCalculator()
    local fill = overlay:GetStatusBarTexture()

    local healTrack = CreateFrame("Frame", nil, container)
    healTrack:SetFrameStrata(STRATA)
    healTrack:SetFrameLevel(HEAL_LEVEL)
    healTrack:SetPoint("LEFT", fill, "RIGHT")
    healTrack:SetPoint("RIGHT", overlay, "RIGHT")
    healTrack:SetHeight(SUB_BAR_HEIGHT)

    local healBar = CreateFrame("StatusBar", nil, healTrack)
    healBar:EnableMouse(false)
    healBar:SetStatusBarTexture(FILL_TEXTURE)
    healBar:SetStatusBarColor(
        HEAL_COLOR[1],
        HEAL_COLOR[2],
        HEAL_COLOR[3],
        HEAL_COLOR[4]
    )
    healBar:SetAllPoints(healTrack)
    healBar:SetFrameStrata(STRATA)
    healBar:SetFrameLevel(HEAL_LEVEL)

    local absorbTrack = CreateFrame("Frame", nil, container)
    absorbTrack:SetFrameStrata(STRATA)
    absorbTrack:SetFrameLevel(ABSORB_LEVEL)
    absorbTrack:SetPoint("LEFT", healBar:GetStatusBarTexture(), "RIGHT")
    absorbTrack:SetPoint("RIGHT", overlay, "RIGHT")
    absorbTrack:SetHeight(SUB_BAR_HEIGHT)

    local absorbBar = CreateFrame("StatusBar", nil, absorbTrack)
    absorbBar:EnableMouse(false)
    absorbBar:SetStatusBarTexture(FILL_TEXTURE)
    absorbBar:SetStatusBarColor(
        ABSORB_COLOR[1],
        ABSORB_COLOR[2],
        ABSORB_COLOR[3],
        ABSORB_COLOR[4]
    )
    absorbBar:SetAllPoints(absorbTrack)
    absorbBar:SetFrameStrata(STRATA)
    absorbBar:SetFrameLevel(ABSORB_LEVEL)

    local function Update()
        if not UnitExists(unit) then
            healTrack:Hide()
            absorbTrack:Hide()
            return
        end

        UnitGetDetailedHealPrediction(unit, nil, calc)

        local missing = calc:GetMissingHealth()
        local incoming = calc:GetIncomingHeals()
        local damageAbsorbs = calc:GetDamageAbsorbs()

        -- Values go straight into the bars, with no arithmetic on them.
        -- pcall stops a failure here from breaking the addon.
        local ok = pcall(function()
            healBar:SetMinMaxValues(0, missing)
            healBar:SetValue(incoming)
            absorbBar:SetMinMaxValues(0, missing)
            absorbBar:SetValue(damageAbsorbs)
        end)

        if ok then
            healTrack:Show()
            absorbTrack:Show()
        else
            healTrack:Hide()
            absorbTrack:Hide()
        end
    end

    return Update
end

-- ===== Player health bar =====
do
    local unit = "player"

    local playerFrame = PlayerFrame
    local playerMain =
        playerFrame.PlayerFrameContent.PlayerFrameContentMain
    local container = playerMain.HealthBarsContainer
    local blizzBar = container.HealthBar
    local blizzMask = container.HealthBarMask

    local overlay, nameText, healthText = CreateOverlay(
        container,
        blizzBar,
        blizzMask,
        "BigPlayerHealthBar"
    )

    local background = CreateBackground(container)

    background:SetPoint("TOPLEFT", overlay, "LEFT", 3, 16)
    background:SetPoint(
        "BOTTOMRIGHT",
        playerMain.ManaBar or overlay,
        "BOTTOMRIGHT",
        -3,
        21
    )

    -- Hide Blizzard's original health text, name, and prediction bars.
    if container.HealthBarText then
        container.HealthBarText:SetAlpha(0)
    end

    HideBlizzardName(playerFrame, playerMain)
    HideBlizzardPrediction(container, blizzBar)

    -- Dark background behind the player mana bar.
    local manaArea = playerMain.ManaBarArea
    local manaBar = select(1, manaArea:GetChildren())

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

    local UpdatePrediction = CreatePredictionBars(container, overlay, unit)

    local function ApplyColor()
        local _, token = UnitClass(unit)
        local color = token and CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[token]
            or token and RAID_CLASS_COLORS[token]

        if color then
            overlay:SetStatusBarColor(color.r, color.g, color.b)
        else
            overlay:SetStatusBarColor(0, 1, 0)
        end
    end

    local function Update()
        ApplyLayout(overlay, blizzBar)
        ApplyColor()
        FitName(overlay, nameText, unit)
        UpdateHealth(overlay, healthText, unit)
        UpdatePrediction()

        background:Show()
        manaBackground:Show()
        overlay:Show()
    end

    -- Same recovery wrapper as the target bar: a secret-value error
    -- during combat must not leave the player bar hidden.
    local reported = false

    local function SafeUpdate()
        local ok, err = pcall(Update)

        if not ok then
            if not reported then
                reported = true
                print("BigPlayerHealthBar: update failed: " .. tostring(err))
            end

            pcall(ApplyLayout, overlay, blizzBar)
            pcall(function()
                background:Show()
                manaBackground:Show()
                overlay:Show()
            end)
        else
            reported = false
        end
    end

    local events = CreateFrame("Frame")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("UNIT_HEALTH")
    events:RegisterEvent("UNIT_MAXHEALTH")
    events:RegisterEvent("UNIT_NAME_UPDATE")
    events:RegisterEvent("UNIT_DISPLAYPOWER")
    SafeRegister(events, "UNIT_HEAL_PREDICTION")
    SafeRegister(events, "UNIT_ABSORB_AMOUNT_CHANGED")

    events:SetScript("OnEvent", function(_, event, eventUnit)
        if event ~= "PLAYER_ENTERING_WORLD"
            and eventUnit ~= unit then
            return
        end

        SafeUpdate()
    end)

    SafeUpdate()
end

-- ===== Target health bar =====
do
    local unit = "target"

    local targetFrame = TargetFrame
    local targetMain =
        targetFrame.TargetFrameContent.TargetFrameContentMain
    local container = targetMain.HealthBarsContainer
    local blizzBar = container.HealthBar
    local blizzMask = container.HealthBarMask

    local overlay, nameText, healthText = CreateOverlay(
        container,
        blizzBar,
        blizzMask,
        "BigTargetHealthBar"
    )

    local background = CreateBackground(container)

    background:SetPoint("TOPLEFT", overlay, "LEFT", 3, 16)
    background:SetPoint(
        "BOTTOMRIGHT",
        targetMain.ManaBar or overlay,
        "BOTTOMRIGHT",
        -6,
        12
    )

    if container.HealthBarText then
        container.HealthBarText:SetAlpha(0)
    end

    HideBlizzardName(targetFrame, targetMain)
    HideBlizzardPrediction(container, blizzBar)

    local UpdatePrediction = CreatePredictionBars(container, overlay, unit)

    local function ApplyColor()
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

    local function Update()
        if not UnitExists(unit) then
            overlay:Hide()
            background:Hide()
            UpdatePrediction()
            return
        end

        ApplyLayout(overlay, blizzBar)
        ApplyColor()
        FitName(overlay, nameText, unit)
        UpdateHealth(overlay, healthText, unit)
        UpdatePrediction()

        background:Show()
        overlay:Show()
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
                print("BigTargetHealthBar: update failed: " .. tostring(err))
            end

            local existsOK, exists = pcall(UnitExists, unit)

            if existsOK and exists then
                -- ApplyLayout runs in its own pcall so a secret-value
                -- error here can never skip the Show calls below. The
                -- old version bundled them together, which is why the
                -- bar vanished for the rest of the fight.
                pcall(ApplyLayout, overlay, blizzBar)
                pcall(function()
                    background:Show()
                    overlay:Show()
                end)
            end
        else
            reported = false
        end
    end

    local events = CreateFrame("Frame")
    events:RegisterEvent("PLAYER_TARGET_CHANGED")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterUnitEvent("UNIT_HEALTH", unit)
    events:RegisterUnitEvent("UNIT_MAXHEALTH", unit)
    events:RegisterUnitEvent("UNIT_FACTION", unit)
    events:RegisterUnitEvent("UNIT_NAME_UPDATE", unit)
    SafeRegister(events, "UNIT_HEAL_PREDICTION", unit)
    SafeRegister(events, "UNIT_ABSORB_AMOUNT_CHANGED", unit)

    events:SetScript("OnEvent", function()
        SafeUpdate()
    end)

    -- Failsafe: rerun the full update once per second. Covers missed
    -- events, mistimed targeting, and any state where the bar ended
    -- up hidden or covered without an event to recover it.
    local elapsed = 0

    events:SetScript("OnUpdate", function(self, delta)
        elapsed = elapsed + delta

        if elapsed >= 1 then
            elapsed = 0
            SafeUpdate()
        end
    end)

    SafeUpdate()
end
