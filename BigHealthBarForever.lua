
-- Big player and target health bars.
-- Custom StatusBars over Blizzard's health bars.

-- ===== Shared tuning =====
local WIDTH_ADJUST = 4
local HEIGHT = 75
local OFFSET_X = -2
local OFFSET_Y = 36
local STRATA = "MEDIUM"
local LEVEL = 50
local FILL_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local BG_COLOR = { 0.05, 0.05, 0.05, 0.90 }

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

local function FitName(bar, nameText, unit)
    local name, surname = UnitName(unit)
	name = name or ""
	if surname and surname ~= "" then
		name = name .. " " .. surname
	end
    local maxWidth = bar:GetWidth() - 4

    if name == nameText.lastName
        and maxWidth == nameText.lastWidth then
        return
    end

    nameText.lastName = name
    nameText.lastWidth = maxWidth
    nameText:SetText(name)

    if maxWidth <= 0 or nameText:GetStringWidth() <= maxWidth then
        return
    end

    local s = name

    while #s > 0 do
        s = TrimLastChar(s)
        nameText:SetText(s .. "...")

        if nameText:GetStringWidth() <= maxWidth then
            return
        end
    end
end

local function CreateBackground(parent)
    local background = CreateFrame("Frame", nil, parent)
    background:SetFrameStrata(STRATA)
    background:SetFrameLevel(LEVEL - 1)

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

local function ApplyLayout(overlay, blizzBar)
    overlay:SetSize(
        blizzBar:GetWidth() + WIDTH_ADJUST,
        HEIGHT
    )

    overlay:ClearAllPoints()
    overlay:SetPoint(
        "TOPLEFT",
        blizzBar,
        "TOPLEFT",
        OFFSET_X,
        OFFSET_Y
    )

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

    -- Hide Blizzard's original health text and name.
    if container.HealthBarText then
        container.HealthBarText:SetAlpha(0)
    end

    HideBlizzardName(playerFrame, playerMain)

    -- Dark background behind the player mana bar.
    local manaArea = playerMain.ManaBarArea
    local manaBar = select(1, manaArea:GetChildren())

    local manaBackground = CreateFrame("Frame", nil, manaArea)
    manaBackground:SetPoint("TOPLEFT", manaBar, "TOPLEFT", -1, 1)
    manaBackground:SetPoint("BOTTOMRIGHT", manaBar, "BOTTOMRIGHT", 1, -1)
    manaBackground:SetFrameLevel(
        math.max(0, manaBar:GetFrameLevel() - 1)
    )

    local manaTexture = manaBackground:CreateTexture(nil, "BACKGROUND")
    manaTexture:SetAllPoints()
    manaTexture:SetColorTexture(0.05, 0.05, 0.05, 1)

    local function ApplyColor()
        local _, token = UnitClass(unit)
        local color = token and RAID_CLASS_COLORS[token]

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

        background:Show()
        manaBackground:Show()
        overlay:Show()
    end

    local events = CreateFrame("Frame")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("UNIT_HEALTH")
    events:RegisterEvent("UNIT_MAXHEALTH")
    events:RegisterEvent("UNIT_NAME_UPDATE")
    events:RegisterEvent("UNIT_DISPLAYPOWER")

    events:SetScript("OnEvent", function(_, event, eventUnit)
        if event ~= "PLAYER_ENTERING_WORLD"
            and eventUnit ~= unit then
            return
        end

        Update()
    end)

    Update()
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

    local function ApplyColor()
        local ok, r, g, b = pcall(function()
            if not UnitIsPlayer(unit) then
                return nil
            end

            local _, token = UnitClass(unit)
            token = token or UnitClassBase(unit)

            local color = token and RAID_CLASS_COLORS[token]
            if color then
                return color.r, color.g, color.b
            end
        end)

        if ok and r then
            overlay:SetStatusBarColor(r, g, b)
        else
            overlay:SetStatusBarColor(
                UnitSelectionColor(unit, false)
            )
        end
    end

    local function Update()
        if not UnitExists(unit) then
            overlay:Hide()
            background:Hide()
            return
        end

        ApplyLayout(overlay, blizzBar)
        ApplyColor()
        FitName(overlay, nameText, unit)
        UpdateHealth(overlay, healthText, unit)

        background:Show()
        overlay:Show()
    end

    local events = CreateFrame("Frame")
    events:RegisterEvent("PLAYER_TARGET_CHANGED")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterUnitEvent("UNIT_HEALTH", unit)
    events:RegisterUnitEvent("UNIT_MAXHEALTH", unit)
    events:RegisterUnitEvent("UNIT_FACTION", unit)
    events:RegisterUnitEvent("UNIT_NAME_UPDATE", unit)

    events:SetScript("OnEvent", Update)

    Update()
end
