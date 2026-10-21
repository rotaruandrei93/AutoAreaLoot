local LOOT_REQUEST_DELAY = 0.02
local DEATH_LOOT_REQUEST_DELAY = 0.15
local POST_SCAN_SETTLE_MIN = 0.05
local POST_SCAN_SETTLE_MAX = 0.40
local POST_SCAN_SETTLE_CUSHION = 0.05
local POST_SCAN_LATENCY_MULTIPLIER = 1.5
local STOP_LOOT_GRACE = 0.15
local STOP_LOOT_GRACE_MOVEMENT_TOLERANCE = 0.20
local MOVEMENT_SPEED_EPSILON = 0.01
local STOP_LOOT_SAME_AREA_INTERVAL = 0.50
local STOP_LOOT_MOVEMENT_DISTANCE = 5
local PLAYER_STATE_SAMPLE_INTERVAL = 0.10
local LOOT_SCAN_TIMEOUT = 6.0
-- The engine's loot test includes creature reach. This deliberately generous
-- center-distance limit rejects only deaths that are clearly too far away.
local DEATH_TRIGGER_DISTANCE_LIMIT = 8
local LOOT_EVENT_HISTORY_LIMIT = 500
local LOOT_CONFIRM_GRACE = 3
local LOOT_ROW_FONT_SIZE = 10
local LOOT_TIMESTAMP_WIDTH = 52
local LOOT_LOG_MIN_WIDTH = 240
local LOOT_LOG_MIN_HEIGHT = 140
local DEBUG_HISTORY_LIMIT = 300
local DEBUG_LINE_HEIGHT = 12
local PENDING_LOOT_PRIORITY = { retry = 1, combat = 2, moved = 3, death = 4 }
local LOOT_FONT = "Interface\\AddOns\\AutoAreaLoot\\Fonts\\PTSansNarrow.ttf"
local LOOT_FONT_FALLBACK = "Fonts\\FRIZQT__.TTF"
local CIRCLE_TEXTURE = "Interface\\AddOns\\AutoAreaLoot\\Icons\\Circle.tga"
local defaults = {
    enabled = true,
    lootOnDeath = true,
    lootOnStop = true,
    lootInCombat = true,
    lootWhileMoving = true,
    lootCombine = false,
    openLootLogOnLogin = false,
    filterEnabled = false,
    lootMoneyFullCorpse = false,
    filterMinQuality = -1,
    filterItems = {},
    lootLogWidth = 280,
    lootLogHeight = 195,
    lootLogPoint = "CENTER",
    lootLogRelativePoint = "CENTER",
    lootLogX = 0,
    lootLogY = 20,
    settingsVersion = 6,
}

local state = {
    initialized = false,
    manualLootOpen = false,
    autoLootWindowOpen = false,
    pendingLootReason = nil,
    lootAfterCombat = false,
    lootRequestTimer = nil,
    lootSettleUntil = nil,
    lootEvents = {},
    lootEventCount = 0,
    lootRecords = {},
    lootRecordByKey = {},
    lootWalkActive = false,
    lootWalkStartedAt = nil,
    useSpeedMovement = false,
    movementStateKnown = false,
    playerMoving = false,
    playerStateSampleElapsed = 0,
    playerSpellcastActive = false,
    playerControlLost = false,
    stopGraceTimer = nil,
    lastStopLootRequestAt = nil,
    lastStopPositionX = nil,
    lastStopPositionY = nil,
    lastStopPositionZ = nil,
    activeCapture = nil,
    pendingCaptures = {},
    moneyBaseline = nil,
    lootMoney = 0,
    lootHighlightSerial = 0,
    debugEnabled = false,
    debugLines = {},
    debugDirty = false,
}

local configFrame
local lootLogFrame
local lootLogContent
local lootLogSummary
local lootLogMoneySummary
local debugFrame
local debugEditBox
local RefreshDebugLog

local function DebugLog(message)
    if not state.debugEnabled then return end
    local now = type(GetTime) == "function" and GetTime() or 0
    local cleanMessage = tostring(message or "")
    cleanMessage = string.gsub(cleanMessage, "[\r\n]+", " ")
    table.insert(state.debugLines,
        string.format("[%09.3f] %s", now, cleanMessage))
    while table.getn(state.debugLines) > DEBUG_HISTORY_LIMIT do
        table.remove(state.debugLines, 1)
    end
    state.debugDirty = true
end

local validAnchorPoints = {
    TOPLEFT = true,
    TOP = true,
    TOPRIGHT = true,
    LEFT = true,
    CENTER = true,
    RIGHT = true,
    BOTTOMLEFT = true,
    BOTTOM = true,
    BOTTOMRIGHT = true,
}

local function IsPfUIThemeActive()
    return pfUI and pfUI.api and pfUI.media and pfUI_config
        and pfUI_config.appearance and pfUI_config.appearance.border
end

local function GetPfUIConfigColor(value, fallbackR, fallbackG, fallbackB, fallbackA)
    if IsPfUIThemeActive() and type(pfUI.api.GetStringColor) == "function"
        and type(value) == "string" then
        local ok, r, g, b, a = pcall(pfUI.api.GetStringColor, value)
        if ok and r ~= nil and g ~= nil and b ~= nil then
            return r, g, b, a or 1
        end
    end
    return fallbackR, fallbackG, fallbackB, fallbackA
end

local function GetThemeBackgroundColor()
    local value = IsPfUIThemeActive()
        and pfUI_config.appearance.border.background or nil
    return GetPfUIConfigColor(value, 0.051, 0.067, 0.090, 0.99)
end

local function GetThemeBorderColor()
    local value = IsPfUIThemeActive()
        and pfUI_config.appearance.border.color or nil
    return GetPfUIConfigColor(value, 0.188, 0.212, 0.239, 1)
end

local function GetThemeAccentColor()
    if IsPfUIThemeActive() and PFUI_CLASS_COLORS and type(UnitClass) == "function" then
        local _, class = UnitClass("player")
        local color = class and PFUI_CLASS_COLORS[class] or nil
        if color then
            if type(color.GetRGB) == "function" then
                local r, g, b = color:GetRGB()
                if r ~= nil then return r, g, b, 1 end
            elseif color.r and color.g and color.b then
                return color.r, color.g, color.b, color.a or 1
            end
        end
    end
    return 0.345, 0.651, 1.000, 1
end

local function ApplyThemeBackdrop(frame, transparency, shadow)
    if IsPfUIThemeActive() and type(pfUI.api.CreateBackdrop) == "function" then
        local ok = pcall(pfUI.api.CreateBackdrop,
            frame, nil, true, transparency)
        if ok then
            if shadow and type(pfUI.api.CreateBackdropShadow) == "function" then
                pcall(pfUI.api.CreateBackdropShadow, frame)
            end
            return
        end
    end

    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    local br, bg, bb, ba = GetThemeBackgroundColor()
    local er, eg, eb, ea = GetThemeBorderColor()
    frame:SetBackdropColor(br, bg, bb, transparency or ba)
    frame:SetBackdropBorderColor(er, eg, eb, ea)
end

local function ApplyLootFont(fontString, size)
    if not fontString or type(fontString.SetFont) ~= "function" then return end
    if IsPfUIThemeActive() and type(pfUI.font_default) == "string"
        and fontString:SetFont(pfUI.font_default, size, "OUTLINE") then
        return
    end
    if not fontString:SetFont(LOOT_FONT, size, "") then
        fontString:SetFont(LOOT_FONT_FALLBACK, size, "")
    end
end

local function StyleCloseButton(button)
    if not IsPfUIThemeActive() then return end
    button:SetWidth(15)
    button:SetHeight(15)
    button.label:SetText("")
    local texture = button:CreateTexture(nil, "ARTWORK")
    texture:SetAllPoints(button)
    texture:SetTexture(pfUI.media["img:close"])
    texture:SetVertexColor(1, 0.25, 0.25, 1)
end

local function CreateAALButton(parent, width, height, label)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(width)
    button:SetHeight(height)
    ApplyThemeBackdrop(button, 0.95)

    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
    ApplyLootFont(button.label, 10)
    button.label:SetTextColor(0.902, 0.929, 0.953, 1)
    button.label:SetText(label or "")

    button:SetScript("OnEnter", function()
        local r, g, b = GetThemeAccentColor()
        this:SetBackdropBorderColor(r, g, b, 1)
        if not IsPfUIThemeActive() then
            this:SetBackdropColor(0.090, 0.153, 0.243, 1)
        end
    end)
    button:SetScript("OnLeave", function()
        local r, g, b, a = GetThemeBorderColor()
        this:SetBackdropBorderColor(r, g, b, a)
        if not IsPfUIThemeActive() then
            this:SetBackdropColor(0.129, 0.149, 0.176, 1)
        end
    end)
    return button
end

local function CreateAALToggle(parent, label, checked, callback)
    local toggle = CreateFrame("Button", nil, parent)
    toggle:SetWidth(24)
    toggle:SetHeight(12)
    toggle.checked = checked and true or false

    local radius = 6
    local center = toggle:CreateTexture(nil, "BACKGROUND")
    center:SetTexture("Interface\\Buttons\\WHITE8X8")
    center:SetPoint("TOPLEFT", toggle, "TOPLEFT", radius, 0)
    center:SetPoint("BOTTOMRIGHT", toggle, "BOTTOMRIGHT", -radius, 0)

    local left = toggle:CreateTexture(nil, "BACKGROUND")
    left:SetTexture(CIRCLE_TEXTURE)
    left:SetTexCoord(0, 0.5, 0, 1)
    left:SetPoint("TOPLEFT", toggle, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", toggle, "BOTTOMLEFT", 0, 0)
    left:SetWidth(radius)

    local right = toggle:CreateTexture(nil, "BACKGROUND")
    right:SetTexture(CIRCLE_TEXTURE)
    right:SetTexCoord(0.5, 1, 0, 1)
    right:SetPoint("TOPRIGHT", toggle, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", toggle, "BOTTOMRIGHT", 0, 0)
    right:SetWidth(radius)

    local thumb = toggle:CreateTexture(nil, "ARTWORK")
    thumb:SetTexture(CIRCLE_TEXTURE)
    thumb:SetWidth(12)
    thumb:SetHeight(12)
    thumb:SetVertexColor(1, 1, 1, 1)

    toggle.label = toggle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    toggle.label:SetPoint("LEFT", toggle, "RIGHT", 6, 0)
    ApplyLootFont(toggle.label, 10)
    toggle.label:SetTextColor(0.902, 0.929, 0.953, 1)
    toggle.label:SetText(label or "")
    local function Paint(hovered)
        local r, g, b
        if toggle.checked then
            if IsPfUIThemeActive() then
                r, g, b = GetThemeAccentColor()
            else
                r, g, b = 0.184, 0.506, 0.969
            end
        else
            r, g, b = 0.267, 0.302, 0.345
        end
        if hovered then
            r, g, b = r + 0.08, g + 0.08, b + 0.08
        end
        center:SetVertexColor(r, g, b, 1)
        left:SetVertexColor(r, g, b, 1)
        right:SetVertexColor(r, g, b, 1)
        thumb:ClearAllPoints()
        if toggle.checked then
            thumb:SetPoint("RIGHT", toggle, "RIGHT", 0, 0)
        else
            thumb:SetPoint("LEFT", toggle, "LEFT", 0, 0)
        end
    end

    function toggle:SetChecked(value)
        self.checked = value and true or false
        Paint(false)
    end

    function toggle:GetChecked()
        return self.checked
    end

    toggle:SetScript("OnEnter", function() Paint(true) end)
    toggle:SetScript("OnLeave", function() Paint(false) end)

    toggle:SetScript("OnClick", function()
        toggle.checked = not toggle.checked
        Paint(true)
        if callback then callback(toggle.checked) end
    end)
    Paint(false)
    return toggle
end

local function CreateAALScrollbar(parent, scrollFrame, content)
    local scrollbar = CreateFrame("Frame", nil, parent)
    scrollbar:SetWidth(16)
    scrollbar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -6, -48)
    scrollbar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 32)
    scrollbar:EnableMouse(true)
    scrollbar:EnableMouseWheel(true)

    local trackWidth = 4
    local trackCapHeight = 2
    local trackR, trackG, trackB = GetThemeBorderColor()
    local thumbR, thumbG, thumbB = GetThemeAccentColor()
    local trackTop = scrollbar:CreateTexture(nil, "BACKGROUND")
    trackTop:SetTexture(CIRCLE_TEXTURE)
    trackTop:SetTexCoord(0, 1, 0, 0.5)
    trackTop:SetWidth(trackWidth)
    trackTop:SetHeight(trackCapHeight)
    trackTop:SetPoint("TOP", scrollbar, "TOP", 0, 0)
    trackTop:SetVertexColor(trackR, trackG, trackB, 0.9)

    local trackBottom = scrollbar:CreateTexture(nil, "BACKGROUND")
    trackBottom:SetTexture(CIRCLE_TEXTURE)
    trackBottom:SetTexCoord(0, 1, 0.5, 1)
    trackBottom:SetWidth(trackWidth)
    trackBottom:SetHeight(trackCapHeight)
    trackBottom:SetPoint("BOTTOM", scrollbar, "BOTTOM", 0, 0)
    trackBottom:SetVertexColor(trackR, trackG, trackB, 0.9)

    local trackCenter = scrollbar:CreateTexture(nil, "BACKGROUND")
    trackCenter:SetTexture("Interface\\Buttons\\WHITE8X8")
    trackCenter:SetPoint("TOPLEFT", trackTop, "BOTTOMLEFT", 0, 0)
    trackCenter:SetPoint("BOTTOMRIGHT", trackBottom, "TOPRIGHT", 0, 0)
    trackCenter:SetVertexColor(trackR, trackG, trackB, 0.9)

    local thumb = CreateFrame("Button", nil, scrollbar)
    local pillWidth = 12
    local pillHeight = 26
    thumb:SetWidth(20)
    thumb:SetHeight(pillHeight + 6)
    thumb:SetFrameLevel(scrollbar:GetFrameLevel() + 2)
    thumb:EnableMouse(true)
    thumb:EnableMouseWheel(true)
    local capHeight = pillWidth / 2
    local thumbTop = thumb:CreateTexture(nil, "OVERLAY")
    thumbTop:SetTexture(CIRCLE_TEXTURE)
    thumbTop:SetTexCoord(0, 1, 0, 0.5)
    thumbTop:SetWidth(pillWidth)
    thumbTop:SetHeight(capHeight)
    thumbTop:SetPoint("TOP", thumb, "TOP", 0, -3)
    thumbTop:SetVertexColor(thumbR, thumbG, thumbB, 0.95)

    local thumbBottom = thumb:CreateTexture(nil, "OVERLAY")
    thumbBottom:SetTexture(CIRCLE_TEXTURE)
    thumbBottom:SetTexCoord(0, 1, 0.5, 1)
    thumbBottom:SetWidth(pillWidth)
    thumbBottom:SetHeight(capHeight)
    thumbBottom:SetPoint("BOTTOM", thumb, "BOTTOM", 0, 3)
    thumbBottom:SetVertexColor(thumbR, thumbG, thumbB, 0.95)

    local thumbCenter = thumb:CreateTexture(nil, "OVERLAY")
    thumbCenter:SetTexture("Interface\\Buttons\\WHITE8X8")
    thumbCenter:SetPoint("TOPLEFT", thumbTop, "BOTTOMLEFT", 0, 0)
    thumbCenter:SetPoint("BOTTOMRIGHT", thumbBottom, "TOPRIGHT", 0, 0)
    thumbCenter:SetVertexColor(thumbR, thumbG, thumbB, 0.95)

    local maximum = 0
    local dragOffset = 0

    local function UpdateThumb()
        local viewHeight = scrollFrame:GetHeight() or 1
        local contentHeight = content:GetHeight() or viewHeight
        maximum = math.max(0, contentHeight - viewHeight)
        if maximum <= 0 then
            trackTop:Hide()
            trackBottom:Hide()
            trackCenter:Hide()
            thumb:Hide()
            return
        end
        trackTop:Show()
        trackBottom:Show()
        trackCenter:Show()
        thumb:Show()
        local trackHeight = scrollbar:GetHeight() or 1
        local ratio = scrollFrame:GetVerticalScroll() / maximum
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", scrollbar, "TOP", 0,
            3 - ratio * math.max(0, trackHeight - pillHeight))
    end

    local function SetScroll(value)
        value = math.max(0, math.min(value or 0, maximum))
        scrollFrame:SetVerticalScroll(value)
        UpdateThumb()
        if scrollFrame.aalOnScrollChanged then
            scrollFrame.aalOnScrollChanged()
        end
    end
    scrollFrame.aalSetScroll = SetScroll

    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function()
        SetScroll(scrollFrame:GetVerticalScroll() - arg1 * 14)
    end)
    scrollbar:SetScript("OnMouseWheel", function()
        SetScroll(scrollFrame:GetVerticalScroll() - arg1 * 14)
    end)
    scrollbar:SetScript("OnMouseDown", function()
        if arg1 ~= "LeftButton" or maximum <= 0 then return end
        local _, cursorY = GetCursorPosition()
        local scale = scrollbar:GetEffectiveScale() or 1
        local top = scrollbar:GetTop() or 0
        local trackHeight = scrollbar:GetHeight() or 1
        local travel = math.max(1, trackHeight - pillHeight)
        local ratio = math.max(0, math.min(
            (top - cursorY / scale - pillHeight / 2) / travel, 1))
        SetScroll(ratio * maximum)
    end)
    thumb:SetScript("OnMouseDown", function()
        if arg1 ~= "LeftButton" or maximum <= 0 then return end
        local _, cursorY = GetCursorPosition()
        local scale = scrollbar:GetEffectiveScale() or 1
        local _, thumbY = thumb:GetCenter()
        dragOffset = (cursorY / scale) - (thumbY or cursorY / scale)
        this:SetScript("OnUpdate", function()
            local _, currentY = GetCursorPosition()
            local frameTop = scrollbar:GetTop() or 0
            local frameBottom = scrollbar:GetBottom() or frameTop
            local travelTop = frameTop - pillHeight / 2
            local travelBottom = frameBottom + pillHeight / 2
            local wantedY = currentY / scale - dragOffset
            local travel = math.max(1, travelTop - travelBottom)
            local ratio = math.max(0, math.min(
                (travelTop - wantedY) / travel, 1))
            SetScroll(ratio * maximum)
        end)
    end)
    thumb:SetScript("OnMouseUp", function()
        this:SetScript("OnUpdate", nil)
    end)
    thumb:SetScript("OnMouseWheel", function()
        SetScroll(scrollFrame:GetVerticalScroll() - arg1 * 14)
    end)
    thumb:SetScript("OnHide", function()
        this:SetScript("OnUpdate", nil)
    end)
    scrollbar:SetScript("OnSizeChanged", UpdateThumb)
    scrollbar.Update = UpdateThumb
    return scrollbar
end

RefreshDebugLog = function(scrollToBottom)
    if not debugEditBox or not debugFrame or not debugFrame:IsShown() then return end
    local text = table.concat(state.debugLines, "\n")
    debugEditBox:SetText(text)
    local lineCount = math.max(1, table.getn(state.debugLines))
    local viewHeight = debugFrame.scrollFrame:GetHeight() or 1
    debugEditBox:SetHeight(math.max(viewHeight, lineCount * DEBUG_LINE_HEIGHT + 8))
    debugFrame.scrollFrame:UpdateScrollChildRect()
    if scrollToBottom then
        -- Vanilla updates a ScrollFrame's range over several frames after its
        -- EditBox changes. Follow the bottom until that range has settled.
        debugFrame.scrollToBottomFrames = 3
    end
    if debugFrame.scrollbar then debugFrame.scrollbar:Update() end
    state.debugDirty = false
end

local function UpdateDebugTitle()
    if not debugFrame or not debugFrame.title then return end
    debugFrame.title:SetText("AutoAreaLoot Debug - "
        .. (state.debugEnabled and "CAPTURING" or "PAUSED"))
end

local function CreateDebugWindow()
    if debugFrame then return end

    debugFrame = CreateFrame("Frame", "AutoAreaLootDebugFrame", UIParent)
    debugFrame:SetWidth(560)
    debugFrame:SetHeight(300)
    debugFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    debugFrame:SetFrameStrata("DIALOG")
    debugFrame:SetToplevel(true)
    debugFrame:SetMovable(true)
    debugFrame:EnableMouse(true)
    debugFrame:RegisterForDrag("LeftButton")
    debugFrame:SetScript("OnDragStart", function() this:StartMoving() end)
    debugFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    ApplyThemeBackdrop(debugFrame, 0.94, true)

    local header = debugFrame:CreateTexture(nil, "BACKGROUND")
    header:SetTexture("Interface\\Buttons\\WHITE8X8")
    header:SetPoint("TOPLEFT", debugFrame, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", debugFrame, "TOPRIGHT", -1, -1)
    header:SetHeight(34)
    if IsPfUIThemeActive() then
        local r, g, b = GetThemeBackgroundColor()
        header:SetVertexColor(r, g, b, 0.75)
    else
        header:SetVertexColor(0.090, 0.153, 0.243, 0.55)
    end

    local accent = debugFrame:CreateTexture(nil, "BORDER")
    accent:SetTexture("Interface\\Buttons\\WHITE8X8")
    accent:SetPoint("TOPLEFT", debugFrame, "TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", debugFrame, "TOPRIGHT", -1, -1)
    accent:SetHeight(2)
    local accentR, accentG, accentB = GetThemeAccentColor()
    accent:SetVertexColor(accentR, accentG, accentB, 0.85)

    debugFrame.title = debugFrame:CreateFontString(
        nil, "ARTWORK", "GameFontNormalLarge")
    debugFrame.title:SetPoint("TOP", debugFrame, "TOP", 0, -11)
    ApplyLootFont(debugFrame.title, 12)
    debugFrame.title:SetTextColor(0.902, 0.929, 0.953, 1)

    local close = CreateAALButton(debugFrame, 18, 18, "X")
    close:SetPoint("TOPRIGHT", debugFrame, "TOPRIGHT", -6, -6)
    ApplyLootFont(close.label, 9)
    StyleCloseButton(close)
    close:SetScript("OnClick", function() this:GetParent():Hide() end)

    local scrollFrame = CreateFrame(
        "ScrollFrame", "AutoAreaLootDebugScrollFrame", debugFrame)
    scrollFrame:SetPoint("TOPLEFT", debugFrame, "TOPLEFT", 10, -42)
    scrollFrame:SetPoint("BOTTOMRIGHT", debugFrame, "BOTTOMRIGHT", -24, 32)
    debugFrame.scrollFrame = scrollFrame

    debugEditBox = CreateFrame(
        "EditBox", "AutoAreaLootDebugEditBox", scrollFrame)
    debugEditBox:SetWidth(516)
    debugEditBox:SetHeight(220)
    debugEditBox:SetMultiLine(true)
    debugEditBox:SetMaxLetters(0)
    debugEditBox:SetAutoFocus(false)
    debugEditBox:EnableMouse(true)
    ApplyLootFont(debugEditBox, 10)
    debugEditBox:SetTextColor(0.820, 0.870, 0.920, 1)
    debugEditBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    scrollFrame:SetScrollChild(debugEditBox)
    debugFrame.scrollbar = CreateAALScrollbar(
        debugFrame, scrollFrame, debugEditBox)

    local clear = CreateAALButton(debugFrame, 46, 18, "Clear")
    clear:SetPoint("BOTTOMLEFT", debugFrame, "BOTTOMLEFT", 10, 7)
    clear:SetScript("OnClick", function()
        state.debugLines = {}
        RefreshDebugLog(false)
    end)

    local selectAll = CreateAALButton(debugFrame, 66, 18, "Select All")
    selectAll:SetPoint("LEFT", clear, "RIGHT", 6, 0)
    selectAll:SetScript("OnClick", function()
        state.debugEnabled = false
        debugFrame.pauseButton.label:SetText("Resume")
        UpdateDebugTitle()
        RefreshDebugLog(false)
        debugEditBox:SetFocus()
        debugEditBox:HighlightText()
    end)

    local pause = CreateAALButton(debugFrame, 78, 18, "Pause")
    pause:SetPoint("LEFT", selectAll, "RIGHT", 6, 0)
    pause:SetScript("OnClick", function()
        state.debugEnabled = not state.debugEnabled
        this.label:SetText(state.debugEnabled and "Pause" or "Resume")
        UpdateDebugTitle()
        if state.debugEnabled then DebugLog("Debug capture resumed") end
    end)
    debugFrame.pauseButton = pause

    local hint = debugFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hint:SetPoint("BOTTOMRIGHT", debugFrame, "BOTTOMRIGHT", -10, 10)
    ApplyLootFont(hint, 9)
    hint:SetTextColor(0.55, 0.62, 0.70, 1)
    hint:SetText("Select All pauses capture; then Ctrl+C")

    debugFrame:SetScript("OnShow", function()
        debugFrame.debugRefreshElapsed = 0
        UpdateDebugTitle()
        debugFrame.pauseButton.label:SetText(
            state.debugEnabled and "Pause" or "Resume")
        RefreshDebugLog(true)
    end)
    debugFrame:SetScript("OnUpdate", function()
        this.debugRefreshElapsed = (this.debugRefreshElapsed or 0) + arg1
        if state.debugDirty and this.debugRefreshElapsed >= 0.10 then
            this.debugRefreshElapsed = 0
            RefreshDebugLog(true)
        end
        if this.scrollToBottomFrames and this.scrollToBottomFrames > 0 then
            local scrollFrame = this.scrollFrame
            scrollFrame:UpdateScrollChildRect()
            local maximum
            if type(scrollFrame.GetVerticalScrollRange) == "function" then
                maximum = scrollFrame:GetVerticalScrollRange()
            else
                maximum = math.max(0,
                    (debugEditBox:GetHeight() or 1)
                    - (scrollFrame:GetHeight() or 1))
            end
            scrollFrame:SetVerticalScroll(math.max(0, maximum or 0))
            if type(scrollFrame.Scroll) == "function" then
                scrollFrame:Scroll()
            end
            if this.scrollbar then this.scrollbar:Update() end
            this.scrollToBottomFrames = this.scrollToBottomFrames - 1
        end
    end)
    debugFrame:Hide()
end

local function ShowDebugWindow()
    CreateDebugWindow()
    debugFrame:Show()
    UpdateDebugTitle()
    RefreshDebugLog(true)
end

local function StopLootRowHighlight(row)
    row:SetScript("OnUpdate", nil)
    row.highlightElapsed = nil
    row.highlight:SetAlpha(0)
    row.highlight:Hide()
end

local function StartLootRowHighlight(row)
    local holdTime = 0.20
    local fadeTime = 1.00
    row.highlightElapsed = 0
    row.highlight:SetAlpha(1)
    row.highlight:Show()
    row:SetScript("OnUpdate", function()
        this.highlightElapsed = (this.highlightElapsed or 0) + arg1
        if this.highlightElapsed <= holdTime then
            this.highlight:SetAlpha(1)
            return
        end

        local alpha = 1 - ((this.highlightElapsed - holdTime) / fadeTime)
        if alpha <= 0 then
            StopLootRowHighlight(this)
        else
            this.highlight:SetAlpha(alpha)
        end
    end)
end

local function GetLootDisplayRecordCount()
    if AutoAreaLootDB.lootCombine then
        return table.getn(state.lootRecords)
    end
    return table.getn(state.lootEvents)
end

local function GetLootDisplayRecord(index)
    if AutoAreaLootDB.lootCombine then
        return state.lootRecords[index]
    end
    local eventCount = table.getn(state.lootEvents)
    return state.lootEvents[eventCount - index + 1]
end

local function CreateLootLogRow()
    local row = CreateFrame("Frame", nil, lootLogContent)
    row:EnableMouse(true)
    row:EnableMouseWheel(true)
    row.timestamp = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.timestamp:SetJustifyH("RIGHT")
    row.timestamp:SetTextColor(1.000, 0.820, 0.000, 1)
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.text:SetJustifyH("LEFT")
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints(row)
    local r, g, b = GetThemeAccentColor()
    row.highlight:SetTexture(r, g, b, 0.32)
    row.highlight:SetAlpha(0)
    row.highlight:Hide()
    row:SetScript("OnEnter", function()
        if not this.itemLink or not GameTooltip then return end
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, this.itemLink)
        if not ok then GameTooltip:Hide() end
    end)
    row:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
    row:SetScript("OnMouseWheel", function()
        local scrollFrame = lootLogFrame and lootLogFrame.scrollFrame
        if scrollFrame and scrollFrame.aalSetScroll then
            scrollFrame.aalSetScroll(
                (scrollFrame:GetVerticalScroll() or 0) - arg1 * 14)
        end
    end)
    table.insert(lootLogContent.rows, row)
    return row
end

local function RefreshVisibleLootRows()
    if not lootLogFrame or not lootLogContent or not lootLogFrame:IsShown() then
        return
    end

    local rowHeight = LOOT_ROW_FONT_SIZE + 4
    local rowWidth = math.max(1, lootLogContent:GetWidth() or 222)
    local recordCount = GetLootDisplayRecordCount()
    local scrollFrame = lootLogFrame.scrollFrame
    local scrollOffset = scrollFrame:GetVerticalScroll() or 0
    local firstIndex = math.floor(scrollOffset / rowHeight) + 1
    local visibleCount = math.ceil((scrollFrame:GetHeight() or rowHeight) / rowHeight) + 2

    for poolIndex = 1, visibleCount do
        local recordIndex = firstIndex + poolIndex - 1
        local record = recordIndex <= recordCount
            and GetLootDisplayRecord(recordIndex) or nil
        local row = lootLogContent.rows[poolIndex] or CreateLootLogRow()

        if record then
            row:SetHeight(rowHeight)
            row:SetWidth(rowWidth)
            row.timestamp:SetHeight(rowHeight)
            row.text:SetHeight(rowHeight)
            ApplyLootFont(row.timestamp, LOOT_ROW_FONT_SIZE)
            ApplyLootFont(row.text, LOOT_ROW_FONT_SIZE)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", lootLogContent, "TOPLEFT", 4,
                -(recordIndex - 1) * rowHeight)
            row.timestamp:ClearAllPoints()
            row.text:ClearAllPoints()
            if AutoAreaLootDB.lootCombine then
                row.timestamp:Hide()
                row.text:SetPoint("LEFT", row, "LEFT", 3, 0)
                row.text:SetWidth(math.max(1, rowWidth - 6))
                row.text:SetText(record.label .. " x" .. record.count)
            else
                row.timestamp:SetPoint("LEFT", row, "LEFT", 3, 0)
                row.timestamp:SetWidth(LOOT_TIMESTAMP_WIDTH)
                row.timestamp:SetText("[" .. (record.timestamp or "--:--") .. "]")
                row.timestamp:Show()
                row.text:SetPoint("LEFT", row, "LEFT",
                    LOOT_TIMESTAMP_WIDTH + 8, 0)
                row.text:SetWidth(math.max(1,
                    rowWidth - LOOT_TIMESTAMP_WIDTH - 11))
                row.text:SetText(record.message)
            end
            if record.kind == "item" then
                if type(record.key) == "string" then
                    row.itemLink = record.key
                elseif tonumber(record.key) then
                    row.itemLink = "item:" .. tonumber(record.key)
                else
                    row.itemLink = nil
                end
            else
                row.itemLink = nil
            end

            if row.boundRecord ~= record then
                if GameTooltip and type(GameTooltip.IsOwned) == "function"
                    and GameTooltip:IsOwned(row) then
                    GameTooltip:Hide()
                end
                StopLootRowHighlight(row)
                row.boundRecord = record
                row.highlightSerial = nil
            end
            local now = type(GetTime) == "function" and GetTime() or 0
            if AutoAreaLootDB.lootCombine and record.highlightSerial
                and record.highlightUntil and record.highlightUntil > now
                and row.highlightSerial ~= record.highlightSerial then
                row.highlightSerial = record.highlightSerial
                StartLootRowHighlight(row)
            elseif not AutoAreaLootDB.lootCombine
                or not record.highlightUntil or record.highlightUntil <= now then
                StopLootRowHighlight(row)
            end
            row:Show()
        else
            StopLootRowHighlight(row)
            row.boundRecord = nil
            row.itemLink = nil
            row:Hide()
        end
    end

    for poolIndex = visibleCount + 1, table.getn(lootLogContent.rows) do
        local row = lootLogContent.rows[poolIndex]
        StopLootRowHighlight(row)
        row.boundRecord = nil
        row.itemLink = nil
        row:Hide()
    end
end

local function RefreshLootLog()
    if not lootLogContent or not lootLogFrame or not lootLogFrame:IsShown() then
        return
    end

    local rowHeight = LOOT_ROW_FONT_SIZE + 4
    local recordCount = GetLootDisplayRecordCount()
    local contentHeight = math.max(recordCount * rowHeight, 1)
    lootLogContent:SetHeight(contentHeight)

    local scrollFrame = lootLogFrame.scrollFrame
    local maximum = math.max(0, contentHeight - (scrollFrame:GetHeight() or 1))
    if (scrollFrame:GetVerticalScroll() or 0) > maximum then
        scrollFrame:SetVerticalScroll(maximum)
    end

    local moneyText = type(GetCoinTextureString) == "function"
        and GetCoinTextureString(state.lootMoney, 9)
        or (state.lootMoney .. " copper")
    lootLogSummary:SetText("Session loot: " .. state.lootEventCount)
    lootLogMoneySummary:SetText("Money: " .. moneyText)
    scrollFrame:UpdateScrollChildRect()
    RefreshVisibleLootRows()
    if lootLogFrame.scrollbar then
        lootLogFrame.scrollbar:Update()
    end
end

local function GetLootTimestamp()
    if type(date) == "function" then
        local ok, timestamp = pcall(date, "%H:%M:%S")
        if ok and type(timestamp) == "string" then return timestamp end
    end
    if type(GetGameTime) == "function" then
        local ok, hour, minute = pcall(GetGameTime)
        if ok and hour ~= nil and minute ~= nil then
            return string.format("%02d:%02d", hour, minute)
        end
    end
    return "--:--"
end

local function AppendLootEvent(eventData)
    state.lootEventCount = state.lootEventCount + 1
    table.insert(state.lootEvents, eventData)
    while table.getn(state.lootEvents) > LOOT_EVENT_HISTORY_LIMIT do
        table.remove(state.lootEvents, 1)
    end
end

local function AddLootItem(label, key, count)
    local record = state.lootRecordByKey[key]
    if record then
        record.count = record.count + count
        record.label = label
    else
        record = {
            kind = "item",
            key = key,
            label = label,
            count = count,
        }
        table.insert(state.lootRecords, record)
        state.lootRecordByKey[key] = record
    end

    if AutoAreaLootDB.lootCombine and lootLogFrame
        and lootLogFrame:IsShown() then
        state.lootHighlightSerial = state.lootHighlightSerial + 1
        record.highlightSerial = state.lootHighlightSerial
        record.highlightUntil =
            (type(GetTime) == "function" and GetTime() or 0) + 1.20
    end

    local message = label .. (count > 1 and (" x" .. count) or "")
    AppendLootEvent({
        kind = "item",
        label = label,
        key = key,
        count = count,
        timestamp = GetLootTimestamp(),
        message = message,
    })
end

local function FormatMoney(amount)
    if type(GetCoinTextureString) == "function" then
        return "Money: " .. GetCoinTextureString(amount)
    end
    return "Money: " .. amount .. " copper"
end

local function AddLootMoney(amount)
    amount = tonumber(amount) or 0
    if amount <= 0 then return end
    local message = FormatMoney(amount)
    state.lootMoney = state.lootMoney + amount
    AppendLootEvent({
        kind = "money",
        timestamp = GetLootTimestamp(),
        message = message,
        amount = amount,
    })
end

local function SafeGetMoney()
    if type(GetMoney) ~= "function" then return end
    local ok, value = pcall(GetMoney)
    if ok and value ~= nil then
        return tonumber(value)
    end
end

-- Loot confirmation is deliberately independent from the corpse-walk state.
-- CHAT_MSG_LOOT proves an item reached the player; scan results only identify
-- which of those messages came from the corpses handled by this addon.
local lootSelfPattern
local lootSelfTypes
local lootSelfMultiplePattern
local lootSelfMultipleTypes

local function IsPatternMagic(character)
    return string.find("()%.%+%-%*%?[]^$", character, 1, true) ~= nil
end

local function CompileFormatPattern(formatText)
    if type(formatText) ~= "string" then return nil, nil end
    local output = { "^" }
    local captureTypes = {}
    local index = 1
    local length = string.len(formatText)

    while index <= length do
        local character = string.sub(formatText, index, index)
        if character == "%" then
            local nextCharacter = string.sub(formatText, index + 1, index + 1)
            if nextCharacter == "%" then
                table.insert(output, "%%")
                index = index + 2
            elseif nextCharacter == "s" or nextCharacter == "d" then
                table.insert(captureTypes, nextCharacter)
                table.insert(output, nextCharacter == "s" and "(.+)" or "(%d+)")
                index = index + 2
            else
                -- Also support positional formats such as %1$s.
                local cursor = index + 1
                while string.find(string.sub(formatText, cursor, cursor), "%d") do
                    cursor = cursor + 1
                end
                if string.sub(formatText, cursor, cursor) == "$" then
                    local valueType = string.sub(formatText, cursor + 1, cursor + 1)
                    if valueType == "s" or valueType == "d" then
                        table.insert(captureTypes, valueType)
                        table.insert(output, valueType == "s" and "(.+)" or "(%d+)")
                        index = cursor + 2
                    else
                        table.insert(output, "%%")
                        index = index + 1
                    end
                else
                    table.insert(output, "%%")
                    index = index + 1
                end
            end
        else
            if IsPatternMagic(character) then
                table.insert(output, "%" .. character)
            else
                table.insert(output, character)
            end
            index = index + 1
        end
    end

    table.insert(output, "$")
    return table.concat(output), captureTypes
end

local function InitializeLootPatterns()
    lootSelfPattern, lootSelfTypes = CompileFormatPattern(LOOT_ITEM_SELF)
    lootSelfMultiplePattern, lootSelfMultipleTypes =
        CompileFormatPattern(LOOT_ITEM_SELF_MULTIPLE)
end

local function ReadLootCaptures(message, pattern, captureTypes)
    if not pattern or not captureTypes then return nil end
    local first, second = string.match(message, pattern)
    if first == nil then return nil end

    local itemText
    local count = 1
    if captureTypes[1] == "s" then itemText = first end
    if captureTypes[1] == "d" then count = tonumber(first) or 1 end
    if captureTypes[2] == "s" then itemText = second end
    if captureTypes[2] == "d" then count = tonumber(second) or 1 end
    return itemText, count
end

local function ParseSelfLootMessage(message)
    if type(message) ~= "string" then return nil end
    local itemText, count = ReadLootCaptures(
        message, lootSelfMultiplePattern, lootSelfMultipleTypes)
    if not itemText then
        itemText, count = ReadLootCaptures(message, lootSelfPattern, lootSelfTypes)
    end
    if not itemText then return nil end

    local itemIDText = string.match(itemText, "item:(%d+)")
    local itemID = itemIDText and tonumber(itemIDText) or nil
    if not itemID then return nil end
    return {
        kind = "item",
        itemID = itemID,
        label = itemText,
        count = math.max(1, tonumber(count) or 1),
    }
end

local function RemovePendingCapture(capture)
    capture.expirationToken = nil
    for index = table.getn(state.pendingCaptures), 1, -1 do
        if state.pendingCaptures[index] == capture then
            table.remove(state.pendingCaptures, index)
        end
    end
end

local function PrunePendingCaptures()
    local now = type(GetTime) == "function" and GetTime() or 0
    for index = table.getn(state.pendingCaptures), 1, -1 do
        local capture = state.pendingCaptures[index]
        if capture.expiresAt and capture.expiresAt <= now then
            DebugLog("Confirmation window expired; dropping unmatched expectations")
            capture.expirationToken = nil
            table.remove(state.pendingCaptures, index)
        end
    end
end

local function CaptureHasExpectedLoot(capture)
    for _, count in pairs(capture.expectedItems or {}) do
        if count > 0 then return true end
    end
    for _, entry in ipairs(capture.expectedMoney or {}) do
        if entry.remaining > 0 then return true end
    end
    return false
end

local function ConsumeItemConfirmation(capture, confirmation)
    local remaining = capture.expectedItems[confirmation.itemID] or 0
    if remaining <= 0 then return false, confirmation.count end

    local confirmed = math.min(remaining, confirmation.count)
    local key = string.match(confirmation.label, "|H(item:[^|]+)|h")
        or confirmation.itemID
    AddLootItem(confirmation.label, key, confirmed)
    capture.expectedItems[confirmation.itemID] = remaining - confirmed
    DebugLog("Item confirmed: item=" .. confirmation.itemID
        .. " count=" .. confirmed .. " remaining="
        .. capture.expectedItems[confirmation.itemID])
    return true, confirmation.count - confirmed
end

local function ConsumeMoneyConfirmation(capture, amount)
    local remainingAmount = math.max(0, tonumber(amount) or 0)
    local consumed = false
    for _, entry in ipairs(capture.expectedMoney) do
        if remainingAmount <= 0 then break end
        if entry.remaining > 0 then
            local confirmed = math.min(entry.remaining, remainingAmount)
            AddLootMoney(confirmed)
            entry.remaining = entry.remaining - confirmed
            remainingAmount = remainingAmount - confirmed
            consumed = true
        end
    end
    DebugLog("Money confirmation: gained=" .. (tonumber(amount) or 0)
        .. " matched=" .. (consumed and "yes" or "no")
        .. " unmatched=" .. remainingAmount)
    return consumed, remainingAmount
end

local function MatchPendingEvent(captureEvent)
    PrunePendingCaptures()
    DebugLog("Matching " .. captureEvent.kind .. " confirmation against "
        .. table.getn(state.pendingCaptures) .. " completed capture(s)")

    local remaining
    if captureEvent.kind == "item" then
        remaining = math.max(1, tonumber(captureEvent.count) or 1)
    elseif captureEvent.kind == "money" then
        remaining = math.max(0, tonumber(captureEvent.amount) or 0)
    else
        return false
    end

    local matched = false
    local index = 1
    while index <= table.getn(state.pendingCaptures) and remaining > 0 do
        local capture = state.pendingCaptures[index]
        local consumed
        if captureEvent.kind == "item" then
            local confirmation = {
                itemID = captureEvent.itemID,
                label = captureEvent.label,
                count = remaining,
            }
            consumed, remaining = ConsumeItemConfirmation(capture, confirmation)
        else
            consumed, remaining = ConsumeMoneyConfirmation(capture, remaining)
        end

        if consumed then matched = true end
        if not CaptureHasExpectedLoot(capture) then
            capture.expirationToken = nil
            table.remove(state.pendingCaptures, index)
        else
            index = index + 1
        end
    end

    if matched then
        RefreshLootLog()
    end
    if remaining > 0 then
        DebugLog("Confirmation remainder did not match corpse scans: kind="
            .. captureEvent.kind .. " amount=" .. remaining)
    end
    if not matched then
        DebugLog("Confirmation did not match any pending corpse scan")
    end
    return matched, remaining
end

local function BufferOrMatchCaptureEvent(captureEvent)
    -- Delayed confirmations must reach earlier captures before they expire,
    -- even when another walk is still running.
    local _, remaining = MatchPendingEvent(captureEvent)
    if not remaining or remaining <= 0 then return end
    if state.activeCapture then
        if captureEvent.kind == "item" then
            captureEvent.count = remaining
        else
            captureEvent.amount = remaining
        end
        table.insert(state.activeCapture.events, captureEvent)
        DebugLog("Buffered " .. captureEvent.kind
            .. " confirmation while corpse scan is active")
        return
    end
end

local function GetLiveCaptureGuids()
    local liveGuids = {}
    for _, pendingCapture in ipairs(state.pendingCaptures) do
        for guid in pairs(pendingCapture.guids or {}) do
            liveGuids[guid] = true
        end
    end
    return liveGuids
end

local function ShortCorpseGuid(guid)
    if type(guid) ~= "string" then return "unknown" end
    if string.len(guid) <= 10 then return guid end
    return "..." .. string.sub(guid, -8)
end

local function CompleteLootCapture(capture, results)
    PrunePendingCaptures()
    capture.expectedItems = {}
    capture.expectedMoney = {}
    capture.guids = {}

    local scannedCorpseCount = 0
    local corpseCount = 0
    local duplicateCorpseCount = 0
    local itemCount = 0
    local moneyCount = 0
    local liveGuids = GetLiveCaptureGuids()
    for _, corpse in ipairs(results or {}) do
        scannedCorpseCount = scannedCorpseCount + 1
        local guid = type(corpse.guid) == "string" and corpse.guid or nil
        if guid and liveGuids[guid] then
            duplicateCorpseCount = duplicateCorpseCount + 1
            DebugLog("Duplicate corpse expectations skipped: guid="
                .. ShortCorpseGuid(guid))
        else
            corpseCount = corpseCount + 1
            if guid then
                capture.guids[guid] = true
                liveGuids[guid] = true
            end
            DebugLog("Corpse expectations accepted: guid="
                .. ShortCorpseGuid(guid))
            local coin = math.max(0, tonumber(corpse.coin) or 0)
            if coin > 0 then
                table.insert(capture.expectedMoney, { remaining = coin })
                moneyCount = moneyCount + coin
            end
            for _, item in ipairs(corpse.items or {}) do
                local itemID = tonumber(item.itemID)
                if itemID then
                    local count = math.max(1, tonumber(item.count) or 1)
                    capture.expectedItems[itemID] =
                        (capture.expectedItems[itemID] or 0) + count
                    itemCount = itemCount + count
                end
            end
        end
    end

    DebugLog("Scan results prepared: scanned=" .. scannedCorpseCount
        .. " accepted=" .. corpseCount
        .. " duplicates=" .. duplicateCorpseCount
        .. " items=" .. itemCount .. " money=" .. moneyCount
        .. " bufferedEvents=" .. table.getn(capture.events))

    capture.expiresAt = (type(GetTime) == "function" and GetTime() or 0)
        + LOOT_CONFIRM_GRACE
    table.insert(state.pendingCaptures, capture)
    while table.getn(state.pendingCaptures) > 8 do
        RemovePendingCapture(state.pendingCaptures[1])
    end
    for _, captureEvent in ipairs(capture.events) do
        -- Captures are ordered oldest first. This lets delayed loot from a
        -- preceding walk consume its expectations before the new walk's.
        MatchPendingEvent(captureEvent)
    end
    capture.events = {}
    RefreshLootLog()

    if not CaptureHasExpectedLoot(capture) then
        DebugLog("Capture complete; all expected loot already confirmed")
        RemovePendingCapture(capture)
        return
    end

    local expirationToken = {}
    capture.expirationToken = expirationToken
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(LOOT_CONFIRM_GRACE, function()
            if capture.expirationToken ~= expirationToken then return end
            capture.expirationToken = nil
            DebugLog("Confirmation grace timer ended; removing capture")
            RemovePendingCapture(capture)
        end)
    else
        DebugLog("No timer API; removing pending confirmation capture")
        RemovePendingCapture(capture)
    end
end

local function SaveLootLogGeometry()
    if not lootLogFrame or not AutoAreaLootDB then return end

    local width = lootLogFrame:GetWidth()
    local height = lootLogFrame:GetHeight()
    AutoAreaLootDB.lootLogWidth = math.max(
        LOOT_LOG_MIN_WIDTH, tonumber(width) or LOOT_LOG_MIN_WIDTH)
    AutoAreaLootDB.lootLogHeight = math.max(
        LOOT_LOG_MIN_HEIGHT, tonumber(height) or LOOT_LOG_MIN_HEIGHT)

    local point, _, relativePoint, x, y = lootLogFrame:GetPoint()
    if validAnchorPoints[point] and validAnchorPoints[relativePoint] then
        AutoAreaLootDB.lootLogPoint = point
        AutoAreaLootDB.lootLogRelativePoint = relativePoint
        AutoAreaLootDB.lootLogX = tonumber(x) or 0
        AutoAreaLootDB.lootLogY = tonumber(y) or 0
    end
end

local function CreateLootLog()
    if lootLogFrame then return end

    lootLogFrame = CreateFrame("Frame", "AutoAreaLootLogFrame", UIParent)
    lootLogFrame:SetWidth(math.max(
        LOOT_LOG_MIN_WIDTH, AutoAreaLootDB.lootLogWidth))
    lootLogFrame:SetHeight(math.max(
        LOOT_LOG_MIN_HEIGHT, AutoAreaLootDB.lootLogHeight))
    lootLogFrame:SetPoint(
        AutoAreaLootDB.lootLogPoint,
        UIParent,
        AutoAreaLootDB.lootLogRelativePoint,
        AutoAreaLootDB.lootLogX,
        AutoAreaLootDB.lootLogY)
    lootLogFrame:SetFrameStrata("DIALOG")
    lootLogFrame:SetToplevel(true)
    lootLogFrame:SetMovable(true)
    lootLogFrame:SetResizable(true)
    if lootLogFrame.SetMinResize then
        lootLogFrame:SetMinResize(LOOT_LOG_MIN_WIDTH, LOOT_LOG_MIN_HEIGHT)
    end
    if lootLogFrame.SetClampedToScreen then
        lootLogFrame:SetClampedToScreen(true)
    end
    lootLogFrame:EnableMouse(true)
    lootLogFrame:RegisterForDrag("LeftButton")
    lootLogFrame:SetScript("OnDragStart", function() this:StartMoving() end)
    lootLogFrame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        SaveLootLogGeometry()
    end)
    lootLogFrame:SetScript("OnHide", SaveLootLogGeometry)
    ApplyThemeBackdrop(lootLogFrame, 0.90, true)

    local header = lootLogFrame:CreateTexture(nil, "BACKGROUND")
    header:SetTexture("Interface\\Buttons\\WHITE8X8")
    header:SetPoint("TOPLEFT", lootLogFrame, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", lootLogFrame, "TOPRIGHT", -1, -1)
    header:SetHeight(30)
    if IsPfUIThemeActive() then
        local r, g, b = GetThemeBackgroundColor()
        header:SetVertexColor(r, g, b, 0.75)
    else
        header:SetVertexColor(0.090, 0.153, 0.243, 0.55)
    end

    local accent = lootLogFrame:CreateTexture(nil, "BORDER")
    accent:SetTexture("Interface\\Buttons\\WHITE8X8")
    accent:SetPoint("TOPLEFT", lootLogFrame, "TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", lootLogFrame, "TOPRIGHT", -1, -1)
    accent:SetHeight(2)
    local accentR, accentG, accentB = GetThemeAccentColor()
    accent:SetVertexColor(accentR, accentG, accentB, 0.85)

    local title = lootLogFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", lootLogFrame, "TOP", 0, -12)
    ApplyLootFont(title, 12)
    title:SetTextColor(0.902, 0.929, 0.953, 1)
    title:SetText("AutoAreaLoot Log")

    local close = CreateAALButton(lootLogFrame, 18, 18, "X")
    close:SetPoint("TOPRIGHT", lootLogFrame, "TOPRIGHT", -6, -6)
    ApplyLootFont(close.label, 9)
    StyleCloseButton(close)
    close:SetScript("OnClick", function() this:GetParent():Hide() end)

    lootLogSummary = lootLogFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    lootLogSummary:SetPoint("TOPLEFT", lootLogFrame, "TOPLEFT", 16, -34)
    ApplyLootFont(lootLogSummary, 9)
    lootLogSummary:SetTextColor(0.545, 0.580, 0.620, 1)

    lootLogMoneySummary = lootLogFrame:CreateFontString(
        nil, "ARTWORK", "GameFontHighlightSmall")
    lootLogMoneySummary:SetPoint("TOPRIGHT", lootLogFrame, "TOPRIGHT", -16, -34)
    lootLogMoneySummary:SetJustifyH("RIGHT")
    ApplyLootFont(lootLogMoneySummary, 9)
    lootLogMoneySummary:SetTextColor(0.545, 0.580, 0.620, 1)

    local scrollFrame = CreateFrame("ScrollFrame", "AutoAreaLootLogScrollFrame", lootLogFrame)
    scrollFrame:SetPoint("TOPLEFT", lootLogFrame, "TOPLEFT", 12, -48)
    scrollFrame:SetPoint("BOTTOMRIGHT", lootLogFrame, "BOTTOMRIGHT", -24, 32)
    lootLogFrame.scrollFrame = scrollFrame

    lootLogContent = CreateFrame("Frame", "AutoAreaLootLogContent", scrollFrame)
    lootLogContent:SetWidth(math.max(1, lootLogFrame:GetWidth() - 58))
    lootLogContent:SetHeight(1)
    lootLogContent.rows = {}
    scrollFrame:SetScrollChild(lootLogContent)
    lootLogFrame.scrollbar = CreateAALScrollbar(lootLogFrame, scrollFrame, lootLogContent)
    scrollFrame.aalOnScrollChanged = RefreshVisibleLootRows

    local resizeGrip = CreateFrame("Button", nil, lootLogFrame)
    resizeGrip:SetWidth(16)
    resizeGrip:SetHeight(16)
    resizeGrip:SetPoint("BOTTOMRIGHT", lootLogFrame, "BOTTOMRIGHT", -2, 2)
    resizeGrip:SetFrameLevel(lootLogFrame:GetFrameLevel() + 5)
    resizeGrip:SetNormalTexture(
        "Interface\\AddOns\\AutoAreaLoot\\Icons\\SizeGrabber-Up.tga")
    resizeGrip:SetHighlightTexture(
        "Interface\\AddOns\\AutoAreaLoot\\Icons\\SizeGrabber-Highlight.tga")
    resizeGrip:SetPushedTexture(
        "Interface\\AddOns\\AutoAreaLoot\\Icons\\SizeGrabber-Down.tga")
    resizeGrip:SetScript("OnMouseDown", function()
        if arg1 == "LeftButton" then
            lootLogFrame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        lootLogFrame:StopMovingOrSizing()
        lootLogContent:SetWidth(math.max(1, lootLogFrame:GetWidth() - 58))
        RefreshLootLog()
        SaveLootLogGeometry()
    end)
    resizeGrip:SetScript("OnHide", function()
        lootLogFrame:StopMovingOrSizing()
    end)

    lootLogFrame:SetScript("OnSizeChanged", function()
        if not lootLogContent then return end
        lootLogContent:SetWidth(math.max(1, this:GetWidth() - 58))
        RefreshLootLog()
    end)

    local clear = CreateAALButton(lootLogFrame, 48, 18, "Clear")
    clear:SetPoint("BOTTOMLEFT", lootLogFrame, "BOTTOMLEFT", 12, 7)
    clear:SetScript("OnClick", function()
        state.lootEvents = {}
        state.lootEventCount = 0
        state.lootRecords = {}
        state.lootRecordByKey = {}
        state.lootMoney = 0
        lootLogFrame.scrollFrame:SetVerticalScroll(0)
        RefreshLootLog()
    end)

    local combine = CreateAALToggle(lootLogFrame, "Combine", AutoAreaLootDB.lootCombine, function(checked)
        AutoAreaLootDB.lootCombine = checked
        lootLogFrame.scrollFrame:SetVerticalScroll(0)
        RefreshLootLog()
    end)
    combine:SetPoint("BOTTOMLEFT", lootLogFrame, "BOTTOMLEFT", 70, 9)

    RefreshLootLog()
    lootLogFrame:Hide()
end

local function ShowLootLog()
    CreateLootLog()
    if lootLogFrame:IsShown() then
        lootLogFrame:Hide()
    else
        lootLogFrame:Show()
        RefreshLootLog()
    end
end

local function InitializeSettings()
    if type(AutoAreaLootDB) ~= "table" then
        AutoAreaLootDB = {}
    end

    local settingsVersion = tonumber(AutoAreaLootDB.settingsVersion) or 0
    if settingsVersion < 2 then
        if type(AutoAreaLootDB.autoLootOutOfCombat) == "boolean" then
            AutoAreaLootDB.lootOnStop = AutoAreaLootDB.autoLootOutOfCombat
        end
        AutoAreaLootDB.lootOnDeath = true
    end
    if settingsVersion < 3 then
        AutoAreaLootDB.lootInCombat = true
    end
    if settingsVersion < defaults.settingsVersion then
        AutoAreaLootDB.autoLootOutOfCombat = nil
        AutoAreaLootDB.lootFontSize = nil
        AutoAreaLootDB.settingsVersion = defaults.settingsVersion
    end

    for key, value in pairs(defaults) do
        if type(AutoAreaLootDB[key]) ~= type(value) then
            AutoAreaLootDB[key] = value
        end
    end
    if not validAnchorPoints[AutoAreaLootDB.lootLogPoint] then
        AutoAreaLootDB.lootLogPoint = defaults.lootLogPoint
    end
    if not validAnchorPoints[AutoAreaLootDB.lootLogRelativePoint] then
        AutoAreaLootDB.lootLogRelativePoint = defaults.lootLogRelativePoint
    end
    state.initialized = true
end

local eventFrame
local missingClassicAPIWarningShown = false
local missingNampowerWarningShown = false

local function IsEventAvailable(eventName)
    return C_EventUtils
        and type(C_EventUtils.IsEventValid) == "function"
        and C_EventUtils.IsEventValid(eventName)
end

local function HasClassicAPILoot()
    if C_Loot and type(C_Loot.LootAllCorpses) == "function" then
        return true
    end
    if not missingClassicAPIWarningShown then
        missingClassicAPIWarningShown = true
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot requires the ClassicAPI DLL with C_Loot.LootAllCorpses.")
    end
    return false
end

local function IsPlayerInCombat()
    return type(UnitAffectingCombat) == "function" and UnitAffectingCombat("player")
end

local function IsPlayerChanneling()
    if type(UnitChannelInfo) ~= "function" then return false end
    local ok, channelName = pcall(UnitChannelInfo, "player")
    return ok and channelName ~= nil
end

local function IsPlayerCasting()
    if type(UnitCastingInfo) ~= "function" then return false end
    local ok, castName = pcall(UnitCastingInfo, "player")
    return ok and castName ~= nil
end

local function IsPlayerDeadOrGhost()
    if type(UnitIsDeadOrGhost) ~= "function" then return false end
    local ok, deadOrGhost = pcall(UnitIsDeadOrGhost, "player")
    return ok and deadOrGhost and true or false
end

local function GetPlayerLootRestriction()
    if state.playerControlLost then return "player control is lost" end
    if IsPlayerDeadOrGhost() then return "player is dead or a ghost" end
    if state.playerSpellcastActive then return "player spellcast is active" end
    if IsPlayerChanneling() then return "player is channeling" end
    if IsPlayerCasting() then return "player is casting" end
    return nil
end

local function GetPlayerSpeedMovementState()
    if type(GetUnitSpeed) ~= "function" then return nil end
    local ok, speed = pcall(GetUnitSpeed, "player")
    speed = tonumber(speed)
    if not ok or not speed then return nil end
    return speed > MOVEMENT_SPEED_EPSILON
end

local function IsPlayerCurrentlyMoving()
    local moving = GetPlayerSpeedMovementState()
    if moving ~= nil then
        return moving
    end
    return state.playerMoving and true or false
end

-- With "Loot while moving" on, walking does not hold looting back.
local function IsMovementBlockingLoot()
    return IsPlayerCurrentlyMoving() and not AutoAreaLootDB.lootWhileMoving
end

local function GetUnitWorldPosition(unit)
    if type(UnitPosition) ~= "function" then return nil end
    local ok, first, second, third = pcall(UnitPosition, unit)
    if not ok then return nil end
    local x = tonumber(first)
    local y = tonumber(second)
    local z = tonumber(third) or 0
    if not x or not y then return nil end
    -- ClassicAPI and SuperWoW differ in axis labels, but Euclidean distance
    -- is unchanged when the first two world axes are swapped.
    return x, y, z
end

local function GetPlayerWorldPosition()
    return GetUnitWorldPosition("player")
end

local function GetUnitDistanceFromPlayer(unit)
    if type(UnitDistanceSquared) == "function" then
        local ok, distanceSquared, checked = pcall(UnitDistanceSquared, unit)
        distanceSquared = tonumber(distanceSquared)
        if ok and checked and distanceSquared and distanceSquared >= 0 then
            return math.sqrt(distanceSquared)
        end
    end

    local unitX, unitY, unitZ = GetUnitWorldPosition(unit)
    local playerX, playerY, playerZ = GetPlayerWorldPosition()
    if not unitX or not playerX then return nil end
    local dx = unitX - playerX
    local dy = unitY - playerY
    local dz = unitZ - playerZ
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function ShouldAcceptDeathTrigger(guid)
    if type(guid) ~= "string" then return true, nil end
    local distance = GetUnitDistanceFromPlayer(guid)
    if not distance then return true, nil end
    return distance <= DEATH_TRIGGER_DISTANCE_LIMIT, distance
end

local function GetDistanceFromLastStop(x, y, z)
    if not x or not state.lastStopPositionX then return nil end
    local dx = x - state.lastStopPositionX
    local dy = y - state.lastStopPositionY
    local dz = z - state.lastStopPositionZ
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function IsLootScanInProgress()
    if not C_Loot or type(C_Loot.IsScanInProgress) ~= "function" then
        return false
    end
    local ok, inProgress = pcall(C_Loot.IsScanInProgress)
    return ok and inProgress and true or false
end

local CompleteActiveLootWalk
local ScheduleLootRequest

local function NormalizePendingLootReason(source)
    local reason = source
    if reason ~= "death" and reason ~= "moved" and reason ~= "combat" then
        reason = "retry"
    end
    return reason
end

local function QueuePendingLootRequest(source)
    local reason = NormalizePendingLootReason(source)
    local currentPriority = PENDING_LOOT_PRIORITY[state.pendingLootReason] or 0
    if PENDING_LOOT_PRIORITY[reason] > currentPriority then
        state.pendingLootReason = reason
    end
end

local function GetLootSettleDelay()
    if not state.lootSettleUntil or type(GetTime) ~= "function" then return 0 end
    local remaining = state.lootSettleUntil - GetTime()
    if remaining <= 0 then
        state.lootSettleUntil = nil
        return 0
    end
    return remaining
end

local function GetAdaptiveLootSettleDuration()
    local latency
    if type(GetNetStats) == "function" then
        local ok, bandwidthIn, bandwidthOut, thirdLatency, fourthLatency =
            pcall(GetNetStats)
        if ok then
            -- Vanilla reports latency as the third value. Clients exposing the
            -- newer home/world pair use the fourth value for world latency.
            latency = tonumber(fourthLatency) or tonumber(thirdLatency)
        end
    end

    local duration = POST_SCAN_SETTLE_MIN
    if latency and latency >= 0 then
        duration = POST_SCAN_SETTLE_CUSHION
            + (latency / 1000) * POST_SCAN_LATENCY_MULTIPLIER
    end
    duration = math.max(POST_SCAN_SETTLE_MIN,
        math.min(POST_SCAN_SETTLE_MAX, duration))
    return duration, latency
end

local function LootNearbyCorpses(source)
    source = source or "retry"
    DebugLog("Loot request entered: source=" .. source .. " enabled="
        .. tostring(state.initialized and AutoAreaLootDB.enabled)
        .. " manual=" .. tostring(state.manualLootOpen)
        .. " localWalk=" .. tostring(state.lootWalkActive)
        .. " apiScan=" .. tostring(IsLootScanInProgress())
        .. " combat=" .. tostring(IsPlayerInCombat()))
    if not state.initialized then
        DebugLog("Loot request stopped: addon not initialized")
        return false
    end
    if not AutoAreaLootDB.enabled then
        DebugLog("Loot request stopped: addon disabled")
        return false
    end
    if not HasClassicAPILoot() then
        DebugLog("Loot request stopped: ClassicAPI loot API unavailable")
        return false
    end
    if AutoAreaLootDB.filterEnabled and AAL_Filter
        and not AAL_Filter.HasAPI() then
        DebugLog("Loot request stopped: filter needs GetNearbyLootableUnits/LootUnit")
        if not state.filterApiWarned then
            state.filterApiWarned = true
            DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot: the item filter needs a ClassicAPI DLL with C_Loot.GetNearbyLootableUnits and C_Loot.LootUnit. Nothing will be looted until you update it or turn the filter off.")
        end
        return false
    end
    if state.filterWalk then
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: filtered loot walk is running; source=" .. source)
        return false
    end

    if state.stopGraceTimer then
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: waiting for stable-stop grace; source="
            .. source)
        return false
    end

    if IsMovementBlockingLoot() then
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: player is moving; source=" .. source)
        return false
    end

    local restriction = GetPlayerLootRestriction()
    if restriction then
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: " .. restriction .. "; source=" .. source)
        return false
    end

    if source == "stop" and state.lootRequestTimer then
        DebugLog("Stop request coalesced into pending scheduled request")
        return false
    end

    if IsPlayerInCombat() and not AutoAreaLootDB.lootInCombat then
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: combat looting disabled")
        return false
    end

    if state.manualLootOpen then
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: manual loot window is open")
        return false
    end

    if state.lootWalkActive then
        if IsLootScanInProgress() then
            QueuePendingLootRequest(source)
            DebugLog("Loot request deferred: our ClassicAPI walk is still active; source="
                .. source)
            return false
        end
        -- Recover if a later trigger notices that the completion event was
        -- missed after ClassicAPI already returned to idle.
        DebugLog("Recovering local walk after ClassicAPI returned idle")
        CompleteActiveLootWalk()
        if state.pendingLootReason then
            local pendingReason = state.pendingLootReason
            state.pendingLootReason = nil
            DebugLog("Recovered completion: preserving queued request; source="
                .. pendingReason)
            ScheduleLootRequest(
                pendingReason == "death" and DEATH_LOOT_REQUEST_DELAY or nil,
                pendingReason)
            return false
        end
    end

    if IsLootScanInProgress() then
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: another ClassicAPI scan is active")
        return false
    end

    local settleDelay = GetLootSettleDelay()
    if settleDelay > 0 then
        local sourceReason = NormalizePendingLootReason(source)
        if sourceReason == "retry" then
            if state.pendingLootReason then
                local pendingReason = state.pendingLootReason
                state.pendingLootReason = nil
                DebugLog("Successful scan is settling; scheduling queued request; source="
                    .. pendingReason)
                ScheduleLootRequest(settleDelay, pendingReason)
                return false
            end
            DebugLog("Loot request coalesced: successful scan is still settling; source="
                .. source)
            return false
        end
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: waiting "
            .. string.format("%.3f", settleDelay)
            .. " seconds for corpse state to settle")
        ScheduleLootRequest(settleDelay, source)
        return false
    end

    state.pendingLootReason = nil
    local capture = { events = {} }
    local fullPass = state.forceFullLoot
        and type(GetTime) == "function" and (GetTime() - state.forceFullLoot) < 10
    state.forceFullLoot = nil
    if fullPass then DebugLog("Full loot pass for corpses that hold money") end
    capture.filtered = (AutoAreaLootDB.filterEnabled and not fullPass) and true or false
    state.activeCapture = capture
    state.lootWalkActive = true
    state.lootWalkStartedAt = type(GetTime) == "function" and GetTime() or nil
    local callOK, callResult
    if capture.filtered then
        DebugLog("Starting filtered corpse walk (item filter is on)")
        callOK, callResult = pcall(AAL_Filter.StartWalk)
    else
        DebugLog("Calling C_Loot.LootAllCorpses")
        callOK, callResult = pcall(C_Loot.LootAllCorpses)
    end
    local started = callOK and callResult and true or false
    DebugLog("LootAllCorpses returned: callOK=" .. tostring(callOK)
        .. " result=" .. tostring(callResult)
        .. " apiScan=" .. tostring(IsLootScanInProgress()))
    if not started then
        if state.activeCapture == capture then
            state.activeCapture = nil
            state.lootWalkActive = false
            state.lootWalkStartedAt = nil
        end
        if IsLootScanInProgress() then
            QueuePendingLootRequest(source)
            DebugLog("Failed call left API scan active; queued one follow-up")
        end
    end
    return started
end

ScheduleLootRequest = function(delay, source)
    source = source or "retry"
    if not state.initialized then
        DebugLog("Schedule skipped: addon not initialized")
        return
    end
    if not AutoAreaLootDB.enabled then
        DebugLog("Schedule skipped: addon disabled")
        return
    end
    if IsMovementBlockingLoot() then
        QueuePendingLootRequest(source)
        DebugLog("Schedule deferred while player is moving; source=" .. source)
        return
    end
    local restriction = GetPlayerLootRestriction()
    if restriction then
        QueuePendingLootRequest(source)
        DebugLog("Schedule deferred while " .. restriction .. "; source=" .. source)
        return
    end
    local settleDelay = GetLootSettleDelay()
    local sourceReason = NormalizePendingLootReason(source)
    if settleDelay > 0 and sourceReason == "retry" then
        DebugLog("Schedule coalesced: successful scan is settling; source="
            .. source)
        return
    end
    if state.lootRequestTimer then
        local timerReason = NormalizePendingLootReason(
            state.lootRequestTimer.source)
        if PENDING_LOOT_PRIORITY[sourceReason]
            > PENDING_LOOT_PRIORITY[timerReason] then
            DebugLog("Scheduled request upgraded: " .. timerReason
                .. " -> " .. sourceReason)
            state.lootRequestTimer = nil
        else
            DebugLog("Schedule coalesced: request timer already pending; source="
                .. state.lootRequestTimer.source)
            return
        end
    end
    if not HasClassicAPILoot() then
        DebugLog("Schedule skipped: ClassicAPI loot API unavailable")
        return
    end
    if not C_Timer or type(C_Timer.After) ~= "function" then
        DebugLog("Schedule skipped: C_Timer.After unavailable")
        return
    end

    local requestedDelay = math.max(0, tonumber(delay) or LOOT_REQUEST_DELAY)
    local effectiveDelay = math.max(requestedDelay, settleDelay)

    -- One timer per burst; invalidated tokens cannot service a later request.
    local token = { source = source }
    state.lootRequestTimer = token
    DebugLog("Loot request scheduled in "
        .. string.format("%.3f", effectiveDelay) .. " seconds; source=" .. source)
    C_Timer.After(effectiveDelay, function()
        if state.lootRequestTimer ~= token then
            DebugLog("Scheduled request discarded: timer token invalidated")
            return
        end
        state.lootRequestTimer = nil
        DebugLog("Scheduled loot request fired; source=" .. token.source)
        LootNearbyCorpses(token.source)
    end)
end

local function ScheduleStableStopLoot(source)
    source = source or "stop"
    if not C_Timer or type(C_Timer.After) ~= "function" then
        DebugLog("Stop grace unavailable; servicing request immediately")
        LootNearbyCorpses(source)
        return
    end

    local startX, startY, startZ = GetPlayerWorldPosition()
    local token = {
        source = source,
        startX = startX,
        startY = startY,
        startZ = startZ,
    }
    state.stopGraceTimer = token
    DebugLog("Waiting " .. string.format("%.3f", STOP_LOOT_GRACE)
        .. " seconds for a stable stop; source=" .. source)
    C_Timer.After(STOP_LOOT_GRACE, function()
        if state.stopGraceTimer ~= token then
            DebugLog("Stable-stop request discarded: token invalidated")
            return
        end
        state.stopGraceTimer = nil
        if IsMovementBlockingLoot() then
            QueuePendingLootRequest(token.source)
            DebugLog("Stable-stop request deferred: movement-start event received")
            return
        end
        local currentX, currentY, currentZ = GetPlayerWorldPosition()
        if token.startX and currentX then
            local dx = currentX - token.startX
            local dy = currentY - token.startY
            local dz = currentZ - token.startZ
            local moved = math.sqrt(dx * dx + dy * dy + dz * dz)
            if moved > STOP_LOOT_GRACE_MOVEMENT_TOLERANCE then
                state.playerMoving = true
                QueuePendingLootRequest(token.source)
                DebugLog("Stable-stop request deferred: moved "
                    .. string.format("%.2f", moved)
                    .. " yards during grace")
                return
            end
        end

        local effectiveSource = token.source
        local pendingReason = state.pendingLootReason
        local effectiveReason = NormalizePendingLootReason(effectiveSource)
        if pendingReason and PENDING_LOOT_PRIORITY[pendingReason]
            > PENDING_LOOT_PRIORITY[effectiveReason] then
            effectiveSource = pendingReason
        end
        DebugLog("Stable stop confirmed; servicing source=" .. effectiveSource)
        LootNearbyCorpses(effectiveSource)
    end)
end

CompleteActiveLootWalk = function(injectedResults)
    if not state.lootWalkActive then
        DebugLog("Completion ignored: no local corpse walk is active")
        return false
    end

    local capture = state.activeCapture
    local completedAt = type(GetTime) == "function" and GetTime() or nil
    local scanDuration
    if completedAt and state.lootWalkStartedAt then
        scanDuration = math.max(0, completedAt - state.lootWalkStartedAt)
    end
    state.lootWalkActive = false
    state.lootWalkStartedAt = nil
    state.activeCapture = nil
    DebugLog("Completing local corpse walk; capture=" .. tostring(capture ~= nil))

    if capture then
        local results = {}
        if injectedResults then
            results = injectedResults
            DebugLog("Filtered walk produced " .. table.getn(results)
                .. " corpse result(s)")
        elseif type(C_Loot.GetLastScanResults) == "function" then
            local resultsOK, returnedResults = pcall(C_Loot.GetLastScanResults)
            if resultsOK and type(returnedResults) == "table" then
                results = returnedResults
                DebugLog("GetLastScanResults returned "
                    .. table.getn(results) .. " corpse result(s)")
            else
                DebugLog("GetLastScanResults failed or returned no table: "
                    .. tostring(returnedResults))
            end
        else
            DebugLog("GetLastScanResults is unavailable")
        end
        if table.getn(results) > 0 and type(GetTime) == "function" then
            local settleDuration, latency =
                GetAdaptiveLootSettleDuration()
            state.lootSettleUntil = GetTime() + settleDuration
            DebugLog("Non-empty scan: latency=" .. tostring(latency or "unknown")
                .. "ms scanTime=" .. string.format("%.3f", scanDuration or 0)
                .. "s settling=" .. string.format("%.3f", settleDuration)
                .. " seconds")
            if state.pendingLootReason == "retry" then
                state.pendingLootReason = nil
                DebugLog("Discarded redundant stop/combat follow-up after successful scan")
            end
        end
        -- Any logging failure ends here and cannot affect looting.
        local captureOK, captureError = pcall(CompleteLootCapture, capture, results)
        if not captureOK then
            DebugLog("Loot logger completion failed: " .. tostring(captureError))
        end
    end
    return true
end

local function ServicePendingLootRequest()
    if state.filterWalk then return end
    if not state.pendingLootReason then
        DebugLog("No queued loot request to service")
        return
    end
    if IsMovementBlockingLoot() then
        DebugLog("Queued loot request retained while player is moving; source="
            .. state.pendingLootReason)
        return
    end
    local restriction = GetPlayerLootRestriction()
    if restriction then
        DebugLog("Queued loot request retained while " .. restriction .. "; source="
            .. state.pendingLootReason)
        return
    end
    if state.stopGraceTimer then
        DebugLog("Queued loot request retained during stable-stop grace; source="
            .. state.pendingLootReason)
        return
    end
    if state.lootWalkActive then
        if IsLootScanInProgress() then
            DebugLog("Queued loot request retained behind active scan; source="
                .. state.pendingLootReason)
            return
        end
        -- Recover if the scan completed but its completion event was missed.
        DebugLog("Recovering queued request after ClassicAPI returned idle")
        CompleteActiveLootWalk()
    end
    if IsLootScanInProgress() then
        DebugLog("Queued loot request retained behind active scan; source="
            .. state.pendingLootReason)
        return
    end

    local source = state.pendingLootReason
    state.pendingLootReason = nil
    DebugLog("Servicing queued loot request; source=" .. source)
    ScheduleLootRequest(
        source == "death" and DEATH_LOOT_REQUEST_DELAY or nil, source)
end

local function RecoverTimedOutLootWalk()
    if state.filterWalk then return end
    if not state.lootWalkActive or not state.lootWalkStartedAt
        or type(GetTime) ~= "function" then
        return
    end

    local elapsed = GetTime() - state.lootWalkStartedAt
    if elapsed < LOOT_SCAN_TIMEOUT then return end

    if IsLootScanInProgress() then
        DebugLog("Loot walk exceeded timeout but ClassicAPI still reports it active")
        return
    end

    DebugLog("Recovering loot walk after "
        .. string.format("%.3f", elapsed)
        .. " seconds without a completion event")
    CompleteActiveLootWalk()
    ServicePendingLootRequest()
end

-- ===== Item filter =====
-- With the filter on, LootAllCorpses is not used. Instead each nearby corpse is
-- opened in turn, the wanted slots (and optionally money) are taken, and the
-- window is closed again before moving on to the next corpse.
AAL_Filter = {}

local WALK_CORPSE_TIMEOUT = 1.5
local WALK_TOTAL_TIMEOUT = 20
local SKIP_RECENT_SECONDS = 20
local SKIP_MONEY_SECONDS = 3
local MOVE_POLL_BACKOFF = 0.25
local FILTER_QUALITY_BY_COLOR = {
    ["9d9d9d"] = 0, ["ffffff"] = 1, ["1eff00"] = 2,
    ["0070dd"] = 3, ["a335ee"] = 4, ["ff8000"] = 5,
}
local FILTER_QUALITY_NAMES = { [0] = "grey", "white", "green", "blue", "purple", "orange" }
local FILTER_QUALITY_ALIASES = {
    grey = 0, gray = 0, poor = 0,
    white = 1, common = 1,
    green = 2, uncommon = 2,
    blue = 3, rare = 3,
    purple = 4, epic = 4,
    orange = 5, legendary = 5,
}

local function FilterNow()
    return type(GetTime) == "function" and GetTime() or 0
end

local function FilterPrint(message)
    DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot: " .. message)
end

function AAL_Filter.HasAPI()
    return C_Loot and type(C_Loot.GetNearbyLootableUnits) == "function"
        and type(C_Loot.LootUnit) == "function"
end

function AAL_Filter.ParseEntry(text)
    text = string.match(text or "", "^%s*(.-)%s*$")
    if not text or text == "" then return nil end
    local id = string.match(text, "item:(%d+)")
    if id then
        return { id = tonumber(id), name = string.match(text, "%[(.-)%]") }
    end
    if string.find(text, "^%d+$") then
        return { id = tonumber(text) }
    end
    return { name = text }
end

function AAL_Filter.EntryLabel(entry)
    if entry.name then return entry.name end
    return "item:" .. tostring(entry.id)
end

local function EntriesMatch(a, b)
    if a.id and b.id then return a.id == b.id end
    if a.name and b.name then
        return string.lower(a.name) == string.lower(b.name)
    end
    return false
end

function AAL_Filter.FindEntry(entry)
    for index, existing in ipairs(AutoAreaLootDB.filterItems) do
        if EntriesMatch(existing, entry) then return index end
    end
    return nil
end

function AAL_Filter.GetNameAndQuality(item)
    local name, quality = item.name, item.quality
    local itemID = tonumber(item.itemID)
    if (not name or quality == nil) and itemID and type(GetItemInfo) == "function" then
        local ok, infoName, _, infoQuality =
            pcall(GetItemInfo, "item:" .. itemID .. ":0:0:0")
        if ok then
            name = name or infoName
            if quality == nil then quality = infoQuality end
        end
    end
    if type(item.link) == "string" then
        if not name then
            name = string.match(item.link, "%[(.-)%]")
        end
        if quality == nil then
            local color = string.match(item.link, "|cff(%x%x%x%x%x%x)")
            if color then
                quality = FILTER_QUALITY_BY_COLOR[string.lower(color)]
            end
        end
    end
    return name, quality
end

function AAL_Filter.ShouldLoot(item)
    local itemID = tonumber(item.itemID)
    if not itemID then return false end
    local name, quality = AAL_Filter.GetNameAndQuality(item)
    local lowerName = name and string.lower(name) or nil
    for _, entry in ipairs(AutoAreaLootDB.filterItems) do
        if entry.id then
            if entry.id == itemID then return true end
        elseif lowerName and entry.name
            and string.lower(entry.name) == lowerName then
            return true
        end
    end
    local minQuality = tonumber(AutoAreaLootDB.filterMinQuality) or -1
    if minQuality >= 0 and quality and quality >= minQuality then
        return true
    end
    return false
end

function AAL_Filter.GetQualityLabel()
    local minQuality = tonumber(AutoAreaLootDB.filterMinQuality) or -1
    if minQuality < 0 then return "off" end
    return (FILTER_QUALITY_NAMES[minQuality] or tostring(minQuality)) .. " and better"
end

function AAL_Filter.CycleQuality()
    local minQuality = tonumber(AutoAreaLootDB.filterMinQuality) or -1
    minQuality = minQuality + 1
    if minQuality > 5 then minQuality = -1 end
    AutoAreaLootDB.filterMinQuality = minQuality
    return AAL_Filter.GetQualityLabel()
end

local function ParseCoinText(text)
    if type(text) ~= "string" then return 0 end
    text = string.lower(text)
    local total = 0
    local function Part(word, multiplier)
        if type(word) ~= "string" or word == "" then return end
        local amount = string.match(text, "(%d+)%s*" .. string.lower(word))
        if amount then total = total + tonumber(amount) * multiplier end
    end
    Part(GOLD, 10000)
    Part(SILVER, 100)
    Part(COPPER, 1)
    return total
end

function AAL_Filter.SetLootFrameHidden(hidden)
    if type(LootFrame) ~= "table" or type(LootFrame.SetAlpha) ~= "function" then
        return
    end
    if hidden then
        LootFrame:SetAlpha(0)
        state.filterHidLootFrame = true
    elseif state.filterHidLootFrame then
        LootFrame:SetAlpha(1)
        state.filterHidLootFrame = nil
    end
end

function AAL_Filter.Reset()
    if state.filterWalk then
        state.filterWalk = nil
        state.lootWalkActive = false
        state.activeCapture = nil
        state.lootWalkStartedAt = nil
    end
    state.filterSkip = nil
    AAL_Filter.SetLootFrameHidden(false)
end

-- Corpses in loot range. With the filter on, corpses already checked and found
-- to hold nothing wanted are left out so they are not opened again and again.
function AAL_Filter.ListLootableUnits(useSkip)
    local guids = {}
    if not (C_Loot and type(C_Loot.GetNearbyLootableUnits) == "function") then
        return guids
    end
    local ok, units = pcall(C_Loot.GetNearbyLootableUnits)
    if not ok or type(units) ~= "table" then return guids end
    local now = FilterNow()
    local skip = useSkip and state.filterSkip or nil
    for _, unit in ipairs(units) do
        local guid = type(unit) == "table" and unit.guid or nil
        if type(guid) == "string" then
            local skipUntil = skip and skip[guid]
            if not (skipUntil and (skipUntil == true or skipUntil > now)) then
                table.insert(guids, guid)
            end
        end
    end
    return guids
end

local function FilterSignature()
    local parts = { tostring(AutoAreaLootDB.lootMoneyFullCorpse),
        tostring(AutoAreaLootDB.filterMinQuality) }
    for _, entry in ipairs(AutoAreaLootDB.filterItems) do
        table.insert(parts, tostring(entry.id) .. ":" .. tostring(entry.name))
    end
    return table.concat(parts, "|")
end

function AAL_Filter.StartWalk()
    -- A changed filter means corpses skipped earlier may now hold wanted items.
    local signature = FilterSignature()
    if signature ~= state.filterSignature then
        state.filterSignature = signature
        state.filterSkip = nil
    end
    local skipCount = 0
    for _ in pairs(state.filterSkip or {}) do skipCount = skipCount + 1 end
    if skipCount > 300 then state.filterSkip = nil end

    local guids = AAL_Filter.ListLootableUnits(true)
    if table.getn(guids) == 0 then return false end
    local latencyOK, _, latency = pcall(GetAdaptiveLootSettleDuration)
    latency = latencyOK and tonumber(latency) or 150
    state.filterWalk = {
        queue = guids,
        results = {},
        startedAt = FilterNow(),
        nextAt = 0,
        -- A corpse that has not answered after a few round trips is out of reach.
        corpseTimeout = math.max(0.8, math.min(2.5, latency / 1000 * 4)),
    }
    AAL_Filter.SetLootFrameHidden(true)
    DebugLog("Filtered walk: " .. table.getn(guids) .. " corpse(s) queued")
    return true
end

-- Takes one item from the corpse window that is open. ClassicAPI's call is
-- used because the stock LootSlot does nothing in a window opened this way.
local function TakeItem(guid, itemID)
    if not (C_Loot and type(C_Loot.LootUnitItem) == "function") then return false end
    local ok, accepted = pcall(C_Loot.LootUnitItem, guid, itemID)
    DebugLog("LootUnitItem item=" .. tostring(itemID) .. " ok=" .. tostring(ok)
        .. " accepted=" .. tostring(accepted))
    return (ok and accepted) and true or false
end

function AAL_Filter.FinishWalk(reason)
    local walk = state.filterWalk
    if not walk then return end
    state.filterWalk = nil
    AAL_Filter.SetLootFrameHidden(false)
    if walk.current and type(CloseLoot) == "function" then pcall(CloseLoot) end
    DebugLog("Filtered walk finished: " .. tostring(reason) .. "; corpses with loot="
        .. table.getn(walk.results))
    CompleteActiveLootWalk(walk.results)
    if walk.sawMoney then
        -- The game offers no way to take only the money, so a corpse that
        -- holds money gets one normal loot-all pass afterwards.
        state.forceFullLoot = FilterNow()
        QueuePendingLootRequest("moved")
        DebugLog("Filtered walk: money seen; full loot pass queued")
    else
        -- Corpses already handled are remembered, so only a short pause is needed.
        state.lootSettleUntil = FilterNow() + 0.15
    end
    ServicePendingLootRequest()
end

-- Asks for the next corpse, or finishes when none are left.
local function SendNextCorpse(walk)
    local guid = table.remove(walk.queue, 1)
    if not guid then
        AAL_Filter.FinishWalk("done")
        return
    end
    walk.current = { guid = guid, sentAt = FilterNow() }
    local ok = pcall(C_Loot.LootUnit, guid)
    if not ok then walk.current = nil end
end

function AAL_Filter.Tick()
    local walk = state.filterWalk
    if not walk then return end
    local now = FilterNow()
    if now - walk.startedAt > WALK_TOTAL_TIMEOUT then
        AAL_Filter.FinishWalk("timeout")
        return
    end
    local current = walk.current
    if current then
        if now - current.sentAt > (walk.corpseTimeout or WALK_CORPSE_TIMEOUT) then
            DebugLog("Filtered walk: corpse did not answer in time; moving on")
            if type(CloseLoot) == "function" then pcall(CloseLoot) end
            walk.current = nil
            SendNextCorpse(walk)
        end
        return
    end
    if state.manualLootOpen then return end
    SendNextCorpse(walk)
end

-- The corpse we asked for is open: take what the filter wants, close the
-- window and go straight on to the next corpse. The takes and the close travel
-- to the server in order, so there is no need to wait for confirmations.
function AAL_Filter.OnLootOpened()
    local walk = state.filterWalk
    local current = walk and walk.current
    if not current then
        -- A window we did not ask for (the player's own): leave it alone.
        state.manualLootOpen = true
        return
    end
    if current.opened then return end
    current.opened = true

    local result = { guid = current.guid, coin = 0, items = {} }
    local wanted, failed, hasMoney = 0, 0, false
    local count = type(GetNumLootItems) == "function" and GetNumLootItems() or 0
    for slot = 1, count do
        local isCoin
        if type(LootSlotIsCoin) == "function" then
            isCoin = LootSlotIsCoin(slot)
        elseif type(LootSlotIsItem) == "function" then
            isCoin = not LootSlotIsItem(slot)
        end
        local _, name, quantity, quality, locked = GetLootSlotInfo(slot)
        DebugLog("Filtered walk slot " .. slot .. ": " .. (isCoin and "money" or "item")
            .. " name=" .. tostring(name) .. " quality=" .. tostring(quality)
            .. " locked=" .. tostring(locked))
        if isCoin then
            if AutoAreaLootDB.lootMoneyFullCorpse then
                hasMoney = true
                walk.sawMoney = true
            end
        elseif not locked then
            local link = type(GetLootSlotLink) == "function" and GetLootSlotLink(slot) or nil
            local itemID = link and tonumber(string.match(link, "item:(%d+)")) or nil
            local item = {
                itemID = itemID, link = link, name = name,
                quality = quality, count = tonumber(quantity) or 1,
            }
            if itemID and AAL_Filter.ShouldLoot(item) then
                if TakeItem(current.guid, itemID) then
                    wanted = wanted + 1
                    table.insert(result.items, item)
                else
                    failed = failed + 1
                end
            end
        end
    end
    if type(CloseLoot) == "function" then pcall(CloseLoot) end

    if table.getn(result.items) > 0 then
        table.insert(walk.results, result)
    end
    state.filterSkip = state.filterSkip or {}
    if failed > 0 then
        state.filterSkip[current.guid] = nil   -- try this corpse again next time
    elseif hasMoney then
        state.filterSkip[current.guid] = FilterNow() + SKIP_MONEY_SECONDS
    elseif wanted > 0 then
        -- Everything wanted was taken. Look again much later in case a take
        -- did not go through; a corpse with nothing wanted left is then skipped for good.
        state.filterSkip[current.guid] = FilterNow() + SKIP_RECENT_SECONDS
    else
        state.filterSkip[current.guid] = true
    end
    DebugLog("Filtered walk: took " .. wanted .. " item(s), failed " .. failed
        .. ", money=" .. tostring(hasMoney) .. " from "
        .. string.sub(tostring(current.guid), -6))
    walk.current = nil
    SendNextCorpse(walk)
end

-- An error here must never leave a walk stuck or the loot window hidden.
local function AbortWalkAfterError(where, err)
    DebugLog("Filtered walk error in " .. where .. ": " .. tostring(err))
    AAL_Filter.FinishWalk("error")
end

function AAL_Filter.SafeTick()
    local ok, err = pcall(AAL_Filter.Tick)
    if not ok then AbortWalkAfterError("Tick", err) end
end

function AAL_Filter.SafeOnLootOpened()
    local ok, err = pcall(AAL_Filter.OnLootOpened)
    if not ok then AbortWalkAfterError("OnLootOpened", err) end
end

function AAL_Filter.SafePoll()
    local ok, err = pcall(AAL_Filter.PollWhileMoving)
    if not ok then DebugLog("Moving poll error: " .. tostring(err)) end
end

-- While the player walks, check every so often for a corpse in range.
function AAL_Filter.PollWhileMoving()
    if not AutoAreaLootDB.enabled or not AutoAreaLootDB.lootWhileMoving then return end
    if state.lootWalkActive or state.filterWalk or state.manualLootOpen
        or state.lootRequestTimer then return end
    local now = FilterNow()
    if now < (state.movePollNext or 0) then return end
    if not IsPlayerCurrentlyMoving() then return end
    if IsPlayerInCombat() and not AutoAreaLootDB.lootInCombat then return end
    if GetPlayerLootRestriction() or GetLootSettleDelay() > 0 then return end
    if table.getn(AAL_Filter.ListLootableUnits(AutoAreaLootDB.filterEnabled)) == 0 then
        return
    end
    state.movePollNext = now + MOVE_POLL_BACKOFF
    DebugLog("Moving poll: lootable corpse in range; requesting loot")
    ScheduleLootRequest(0, "moved")
end

function AAL_Filter.PrintList()
    local count = table.getn(AutoAreaLootDB.filterItems)
    FilterPrint("filter is " .. (AutoAreaLootDB.filterEnabled and "ON" or "OFF")
        .. "; quality rule: " .. AAL_Filter.GetQualityLabel() .. ".")
    if count == 0 then
        FilterPrint("item list is empty. Add one with /aal add [shift-click an item]")
        return
    end
    for index, entry in ipairs(AutoAreaLootDB.filterItems) do
        DEFAULT_CHAT_FRAME:AddMessage("  " .. index .. ". " .. AAL_Filter.EntryLabel(entry))
    end
end

local function ParseOnOff(text, current)
    text = string.lower(text or "")
    if text == "on" or text == "1" or text == "yes" then return true end
    if text == "off" or text == "0" or text == "no" then return false end
    return not current
end

function AAL_Filter.HandleCommand(sub, rest)
    if sub == "items" or sub == "menu" then
        AAL_Filter.ShowMenu()
        return true
    elseif sub == "add" then
        local entry = AAL_Filter.ParseEntry(rest)
        if not entry then
            FilterPrint("usage: /aal add [shift-click an item] or /aal add Linen Cloth")
        elseif AAL_Filter.FindEntry(entry) then
            FilterPrint(AAL_Filter.EntryLabel(entry) .. " is already on the list.")
        else
            table.insert(AutoAreaLootDB.filterItems, entry)
            FilterPrint("added " .. AAL_Filter.EntryLabel(entry) .. " to the filter list.")
            AAL_Filter.RefreshAll()
            if not AutoAreaLootDB.filterEnabled then
                FilterPrint("the filter is OFF. Turn it on with /aal filter on")
            end
        end
        return true
    elseif sub == "remove" or sub == "del" then
        local entry = AAL_Filter.ParseEntry(rest)
        local index = entry and AAL_Filter.FindEntry(entry)
        if index then
            table.remove(AutoAreaLootDB.filterItems, index)
            FilterPrint("removed " .. AAL_Filter.EntryLabel(entry) .. ".")
            AAL_Filter.RefreshAll()
        else
            FilterPrint("that item is not on the list. See /aal list")
        end
        return true
    elseif sub == "list" then
        AAL_Filter.PrintList()
        return true
    elseif sub == "clear" then
        AutoAreaLootDB.filterItems = {}
        FilterPrint("filter item list cleared.")
        AAL_Filter.RefreshAll()
        return true
    elseif sub == "filter" then
        AutoAreaLootDB.filterEnabled =
            ParseOnOff(rest, AutoAreaLootDB.filterEnabled)
        if not AutoAreaLootDB.filterEnabled then AAL_Filter.Reset() end
        FilterPrint("filter " .. (AutoAreaLootDB.filterEnabled and "ON" or "OFF") .. ".")
        AAL_Filter.RefreshAll()
        return true
    elseif sub == "money" then
        AutoAreaLootDB.lootMoneyFullCorpse =
            ParseOnOff(rest, AutoAreaLootDB.lootMoneyFullCorpse)
        FilterPrint("loot money (whole corpse): "
            .. (AutoAreaLootDB.lootMoneyFullCorpse and "ON (a corpse with money is looted completely)" or "OFF") .. ".")
        AAL_Filter.RefreshAll()
        return true
    elseif sub == "quality" then
        local word = string.lower(rest or "")
        if word == "off" or word == "none" or word == "" then
            AutoAreaLootDB.filterMinQuality = -1
        elseif FILTER_QUALITY_ALIASES[word] then
            AutoAreaLootDB.filterMinQuality = FILTER_QUALITY_ALIASES[word]
        else
            FilterPrint("usage: /aal quality off | grey | white | green | blue | purple | orange")
            return true
        end
        FilterPrint("quality rule: " .. AAL_Filter.GetQualityLabel() .. ".")
        AAL_Filter.RefreshAll()
        return true
    elseif sub == "moving" then
        AutoAreaLootDB.lootWhileMoving =
            ParseOnOff(rest, AutoAreaLootDB.lootWhileMoving)
        FilterPrint("loot while moving: "
            .. (AutoAreaLootDB.lootWhileMoving and "ON" or "OFF") .. ".")
        AAL_Filter.RefreshAll()
        return true
    elseif sub == "help" then
        FilterPrint("filter commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /aal items  - open the filter menu (drag and drop, search)")
        DEFAULT_CHAT_FRAME:AddMessage("  /aal filter on|off  - only loot items you chose")
        DEFAULT_CHAT_FRAME:AddMessage("  /aal add [item]  - add an item (shift-click or type the name)")
        DEFAULT_CHAT_FRAME:AddMessage("  /aal remove [item]  - remove an item")
        DEFAULT_CHAT_FRAME:AddMessage("  /aal list  - show the filter")
        DEFAULT_CHAT_FRAME:AddMessage("  /aal clear  - empty the item list")
        DEFAULT_CHAT_FRAME:AddMessage("  /aal quality green  - also loot every green or better item (off to disable)")
        DEFAULT_CHAT_FRAME:AddMessage("  /aal money on|off  - loot corpses that hold money completely (items included)")
        DEFAULT_CHAT_FRAME:AddMessage("  /aal moving on|off  - loot while walking, no need to stop")
        return true
    end
    return false
end

-- ===== Filter menu (drag and drop, search) =====
local MENU_RESULT_ROWS = 5
local MENU_LIST_ROWS = 7
local MENU_ROW_HEIGHT = 20
local MENU_MAX_RESULTS = 150
local MENU_MIN_QUERY = 3
local menuFrame

local function GetItemInfoSafe(itemID)
    if not itemID or type(GetItemInfo) ~= "function" then return nil end
    local ok, name, link, quality = pcall(GetItemInfo, "item:" .. itemID .. ":0:0:0")
    if ok and name then return name, quality end
    return nil
end

local function GetEntryDisplay(entry)
    local infoName, quality = GetItemInfoSafe(entry.id)
    local name = entry.name or infoName or ("item:" .. tostring(entry.id))
    local color = ITEM_QUALITY_COLORS and quality and ITEM_QUALITY_COLORS[quality]
    if color then return name, color.r, color.g, color.b, true end
    return name, 0.902, 0.929, 0.953, infoName ~= nil
end

function AAL_Filter.AddEntry(entry)
    if not entry then return false end
    if AAL_Filter.FindEntry(entry) then
        FilterPrint(AAL_Filter.EntryLabel(entry) .. " is already on the list.")
        return false
    end
    table.insert(AutoAreaLootDB.filterItems, entry)
    FilterPrint("added " .. AAL_Filter.EntryLabel(entry) .. " to the filter list.")
    if not AutoAreaLootDB.filterEnabled then
        FilterPrint("the filter is OFF. Turn it on in the filter menu or with /aal filter on")
    end
    if menuFrame then menuFrame.listOffset = 9999 end
    AAL_Filter.RefreshAll()
    return true
end

function AAL_Filter.RemoveIndex(index)
    local entry = AutoAreaLootDB.filterItems[index]
    if not entry then return end
    table.remove(AutoAreaLootDB.filterItems, index)
    FilterPrint("removed " .. AAL_Filter.EntryLabel(entry) .. ".")
    AAL_Filter.RefreshAll()
end

function AAL_Filter.HandleDrop()
    if type(GetCursorInfo) ~= "function" then
        FilterPrint("drag and drop needs the ClassicAPI GetCursorInfo function.")
        return
    end
    local kind, itemID, link = GetCursorInfo()
    itemID = tonumber(itemID)
    if kind ~= "item" or not itemID then return end
    local name
    if type(link) == "string" then name = string.match(link, "%[(.-)%]") end
    name = name or GetItemInfoSafe(itemID)
    if type(ClearCursor) == "function" then pcall(ClearCursor) end
    local label = name or ("item:" .. itemID)
    if AAL_Filter.AddEntry({ id = itemID, name = name }) then
        if type(PlaySound) == "function" then
            pcall(PlaySound, "igMainMenuOptionCheckBoxOn")
        end
        AAL_Filter.ShowDropFeedback("Added: " .. label, 0.3, 1, 0.5, itemID)
    else
        AAL_Filter.ShowDropFeedback(label .. " is already on your list.",
            1, 0.65, 0.2, itemID)
    end
end

local function GetItemTextureSafe(itemID)
    if itemID and type(GetItemInfo) == "function" then
        local ok, _, _, _, _, _, _, _, _, texture =
            pcall(GetItemInfo, "item:" .. itemID .. ":0:0:0")
        if ok and texture then return texture end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local DROP_HINT_TEXT = "Drag an item from your bags onto the slot to add it to your list."

function AAL_Filter.PaintDropSlot()
    local f = menuFrame
    if not f or not f.dropSlot then return end
    local drop, hint = f.dropSlot, f.dropHint
    if f.feedbackUntil then
        drop.icon:SetTexture(f.feedbackTexture)
        drop.icon:Show()
        drop.plus:Hide()
        drop:SetBackdropBorderColor(f.feedbackR, f.feedbackG, f.feedbackB, 1)
        hint:SetText(f.feedbackText)
        hint:SetTextColor(f.feedbackR, f.feedbackG, f.feedbackB, 1)
    elseif f.holdingItem then
        drop.icon:Hide()
        drop.plus:Show()
        drop.plus:SetTextColor(0.3, 1, 0.5, 1)
        drop:SetBackdropBorderColor(0.3, 1, 0.5, 1)
        hint:SetText("Release the item here to add it to your list.")
        hint:SetTextColor(0.3, 1, 0.5, 1)
    else
        drop.icon:Hide()
        drop.plus:Show()
        drop.plus:SetTextColor(0.345, 0.651, 1, 1)
        if drop.hover then
            local r, g, b = GetThemeAccentColor()
            drop:SetBackdropBorderColor(r, g, b, 1)
        else
            local r, g, b, a = GetThemeBorderColor()
            drop:SetBackdropBorderColor(r, g, b, a)
        end
        hint:SetText(DROP_HINT_TEXT)
        hint:SetTextColor(0.902, 0.929, 0.953, 1)
    end
end

function AAL_Filter.ShowDropFeedback(text, r, g, b, itemID)
    local f = menuFrame
    if not f or not f.dropSlot then return end
    f.feedbackText = text
    f.feedbackR, f.feedbackG, f.feedbackB = r, g, b
    f.feedbackTexture = GetItemTextureSafe(itemID)
    f.feedbackUntil = FilterNow() + 2.5
    AAL_Filter.PaintDropSlot()
end

local function CreateMenuScrollbar(parent, area, rows, getTotal, getOffset, setOffset)
    local trackHeight = rows * MENU_ROW_HEIGHT
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetWidth(8)
    bar:SetHeight(trackHeight)
    bar:SetPoint("TOPLEFT", area, "TOPRIGHT", 4, 0)
    bar:EnableMouse(true)
    bar:EnableMouseWheel(true)

    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetTexture("Interface\\Buttons\\WHITE8X8")
    track:SetWidth(2)
    track:SetHeight(trackHeight)
    track:SetPoint("TOP", bar, "TOP", 0, 0)
    local br, bg, bb = GetThemeBorderColor()
    track:SetVertexColor(br, bg, bb, 0.9)

    local thumb = CreateFrame("Frame", nil, bar)
    thumb:SetWidth(6)
    thumb:SetHeight(20)
    thumb:EnableMouse(true)
    local thumbTexture = thumb:CreateTexture(nil, "ARTWORK")
    thumbTexture:SetTexture("Interface\\Buttons\\WHITE8X8")
    thumbTexture:SetAllPoints(thumb)
    local ar, ag, ab = GetThemeAccentColor()
    thumbTexture:SetVertexColor(ar, ag, ab, 0.9)
    thumb:Hide()

    function bar.Update()
        local total = getTotal()
        if total <= rows then
            thumb:Hide()
            return
        end
        local thumbHeight = math.max(16, trackHeight * rows / total)
        local travel = trackHeight - thumbHeight
        local ratio = getOffset() / (total - rows)
        thumb:SetHeight(thumbHeight)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", bar, "TOP", 0, -ratio * travel)
        thumb:Show()
    end

    local function SetFromCursor(grab)
        local total = getTotal()
        if total <= rows then return end
        local top = bar:GetTop()
        if not top then return end
        local _, cursorY = GetCursorPosition()
        local scale = bar:GetEffectiveScale() or 1
        local thumbHeight = thumb:GetHeight()
        local travel = math.max(1, trackHeight - thumbHeight)
        local y = top - cursorY / scale - (grab or thumbHeight / 2)
        local ratio = math.max(0, math.min(y / travel, 1))
        setOffset(math.floor(ratio * (total - rows) + 0.5))
    end

    bar:SetScript("OnMouseDown", function() SetFromCursor(nil) end)
    bar:SetScript("OnMouseWheel", function() setOffset(getOffset() - arg1) end)
    thumb:SetScript("OnMouseWheel", function() setOffset(getOffset() - arg1) end)
    thumb:SetScript("OnMouseDown", function()
        local _, cursorY = GetCursorPosition()
        local scale = bar:GetEffectiveScale() or 1
        local thumbTop = thumb:GetTop() or 0
        local grab = thumbTop - cursorY / scale
        thumb:SetScript("OnUpdate", function()
            if type(IsMouseButtonDown) == "function"
                and not IsMouseButtonDown("LeftButton") then
                thumb:SetScript("OnUpdate", nil)
                return
            end
            SetFromCursor(grab)
        end)
    end)
    thumb:SetScript("OnMouseUp", function() thumb:SetScript("OnUpdate", nil) end)
    thumb:SetScript("OnHide", function() thumb:SetScript("OnUpdate", nil) end)
    return bar
end

local function ShowRowTooltip(row)
    local entry = row.entry
    if not entry or not entry.id or not GetItemInfoSafe(entry.id) then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. entry.id .. ":0:0:0")
    if ok then GameTooltip:Show() else GameTooltip:Hide() end
end

local function CreateMenuRow(parent, index, buttonText, onAction)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(MENU_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * MENU_ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * MENU_ROW_HEIGHT)
    row:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
    local highlight = row:GetHighlightTexture()
    if highlight then highlight:SetVertexColor(1, 1, 1, 0.08) end

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -62, 0)
    row.text:SetJustifyH("LEFT")
    ApplyLootFont(row.text, 11)

    row.button = CreateAALButton(row, 54, 16, buttonText)
    row.button:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    ApplyLootFont(row.button.label, 9)
    row.button:SetScript("OnClick", function() onAction(row) end)

    row:SetScript("OnClick", function() onAction(row) end)
    row:SetScript("OnEnter", function() ShowRowTooltip(row) end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:Hide()
    return row
end

function AAL_Filter.RefreshMenu()
    if not menuFrame or not menuFrame:IsShown() then return end
    local results = menuFrame.results or {}
    local resultCount = table.getn(results)
    menuFrame.resultOffset = math.max(0, math.min(menuFrame.resultOffset or 0,
        math.max(0, resultCount - MENU_RESULT_ROWS)))
    for index = 1, MENU_RESULT_ROWS do
        local row = menuFrame.resultRows[index]
        local entry = results[menuFrame.resultOffset + index]
        if entry then
            row.entry = entry
            local name, r, g, b = GetEntryDisplay(entry)
            row.text:SetText(name)
            row.text:SetTextColor(r, g, b, 1)
            row.button.label:SetText(AAL_Filter.FindEntry(entry) and "Added" or "Add")
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end
    menuFrame.resultsHeader:SetText("Results (" .. resultCount .. ")")
    menuFrame.noteText:SetText(menuFrame.note or "")

    local list = AutoAreaLootDB.filterItems
    local listCount = table.getn(list)
    menuFrame.listOffset = math.max(0, math.min(menuFrame.listOffset or 0,
        math.max(0, listCount - MENU_LIST_ROWS)))
    for index = 1, MENU_LIST_ROWS do
        local row = menuFrame.listRows[index]
        local entry = list[menuFrame.listOffset + index]
        if entry then
            row.entry = entry
            row.listIndex = menuFrame.listOffset + index
            local name, r, g, b = GetEntryDisplay(entry)
            row.text:SetText(name)
            row.text:SetTextColor(r, g, b, 1)
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end
    menuFrame.listHeader:SetText("Your filter list (" .. listCount .. ")")
    menuFrame.emptyText:SetText(listCount == 0
        and "Empty. Drop an item on the slot above or add one from the results." or "")
    menuFrame.filterToggle:SetChecked(AutoAreaLootDB.filterEnabled)
    if menuFrame.resultBar then menuFrame.resultBar.Update() end
    if menuFrame.listBar then menuFrame.listBar.Update() end
end

-- Asks pfQuest's HearthDB (SQLite) database for items by name or ID. It answers
-- later, so the result list is handed to `callback`. Returns true if accepted.
function AAL_Filter.SearchHDB(query, callback)
    if type(pfDatabase) ~= "table"
        or type(pfDatabase.SearchItemTitlesHDB) ~= "function" then
        return false
    end
    local ok, accepted = pcall(pfDatabase.SearchItemTitlesHDB, pfDatabase,
        query, MENU_MAX_RESULTS, function(data, err)
            local list = {}
            if not err and type(data) == "table" then
                for id, value in pairs(data) do
                    local name = type(value) == "table" and value.title or value
                    id = tonumber(id)
                    if id and type(name) == "string" then
                        table.insert(list, { id = id, name = name })
                    end
                end
            end
            pcall(callback, list)
        end)
    return (ok and accepted) and true or false
end

function AAL_Filter.RunSearch()
    if not menuFrame then return end
    local text = menuFrame.searchBox:GetText()
    local query = string.match(text or "", "^%s*(.-)%s*$") or ""
    menuFrame.searchRequest = (menuFrame.searchRequest or 0) + 1
    local request = menuFrame.searchRequest
    menuFrame.results = {}
    menuFrame.resultOffset = 0

    if query == "" or (string.len(query) < MENU_MIN_QUERY and not tonumber(query)) then
        menuFrame.note = "Type at least " .. MENU_MIN_QUERY
            .. " letters to search the pfQuest database."
        AAL_Filter.RefreshMenu()
        return
    end

    menuFrame.note = "Searching the pfQuest database..."
    AAL_Filter.RefreshMenu()
    local accepted = AAL_Filter.SearchHDB(query, function(list)
        if not menuFrame or request ~= menuFrame.searchRequest then return end
        table.sort(list, function(a, b)
            return string.lower(a.name) < string.lower(b.name)
        end)
        menuFrame.results = list
        menuFrame.resultOffset = 0
        menuFrame.note = table.getn(list) .. " match(es) from the pfQuest database."
        AAL_Filter.RefreshMenu()
    end)
    if not accepted then
        menuFrame.note = "Search needs pfQuest-HDB and HearthDB.dll. "
            .. "You can still drag items onto the slot or use /aal add."
        AAL_Filter.RefreshMenu()
    end
end

function AAL_Filter.RefreshAll()
    if AAL_RefreshConfig then AAL_RefreshConfig() end
    AAL_Filter.RefreshMenu()
end

local function CreateMenuLabel(parent, x, y, text, size)
    local label = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    ApplyLootFont(label, size or 10)
    label:SetTextColor(0.902, 0.929, 0.953, 1)
    label:SetJustifyH("LEFT")
    label:SetText(text or "")
    return label
end

local function CreateFilterMenu()
    if menuFrame then return end
    menuFrame = CreateFrame("Frame", "AutoAreaLootFilterMenu", UIParent)
    menuFrame:SetWidth(340)
    menuFrame:SetHeight(450)
    menuFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    menuFrame:SetFrameStrata("DIALOG")
    menuFrame:SetToplevel(true)
    menuFrame:SetMovable(true)
    menuFrame:EnableMouse(true)
    menuFrame:RegisterForDrag("LeftButton")
    menuFrame:SetScript("OnDragStart", function() this:StartMoving() end)
    menuFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    ApplyThemeBackdrop(menuFrame, 0.92, true)
    menuFrame.results = {}
    menuFrame.resultOffset = 0
    menuFrame.listOffset = 0

    -- Solid fill so the settings panel behind the menu does not show through.
    local solid = menuFrame:CreateTexture(nil, "BACKGROUND")
    solid:SetTexture("Interface\\Buttons\\WHITE8X8")
    solid:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 1, -1)
    solid:SetPoint("BOTTOMRIGHT", menuFrame, "BOTTOMRIGHT", -1, 1)
    do
        local r, g, b = GetThemeBackgroundColor()
        solid:SetVertexColor(r, g, b, 1)
    end

    local header = menuFrame:CreateTexture(nil, "BACKGROUND")
    header:SetTexture("Interface\\Buttons\\WHITE8X8")
    header:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -1, -1)
    header:SetHeight(30)
    if IsPfUIThemeActive() then
        local r, g, b = GetThemeBackgroundColor()
        header:SetVertexColor(r, g, b, 0.75)
    else
        header:SetVertexColor(0.090, 0.153, 0.243, 0.55)
    end

    local accent = menuFrame:CreateTexture(nil, "BORDER")
    accent:SetTexture("Interface\\Buttons\\WHITE8X8")
    accent:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -1, -1)
    accent:SetHeight(2)
    local accentR, accentG, accentB = GetThemeAccentColor()
    accent:SetVertexColor(accentR, accentG, accentB, 0.85)

    local title = menuFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", menuFrame, "TOP", 0, -10)
    ApplyLootFont(title, 12)
    title:SetTextColor(0.902, 0.929, 0.953, 1)
    title:SetText("AutoAreaLoot Filter")

    local close = CreateAALButton(menuFrame, 18, 18, "X")
    close:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -6, -6)
    ApplyLootFont(close.label, 9)
    StyleCloseButton(close)
    close:SetScript("OnClick", function() menuFrame:Hide() end)

    -- Drop slot
    local drop = CreateFrame("Button", nil, menuFrame)
    drop:SetWidth(36)
    drop:SetHeight(36)
    drop:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 14, -40)
    ApplyThemeBackdrop(drop, 0.95)
    drop.icon = drop:CreateTexture(nil, "ARTWORK")
    drop.icon:SetPoint("TOPLEFT", drop, "TOPLEFT", 3, -3)
    drop.icon:SetPoint("BOTTOMRIGHT", drop, "BOTTOMRIGHT", -3, 3)
    drop.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    drop.icon:Hide()
    drop.plus = drop:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    drop.plus:SetPoint("CENTER", drop, "CENTER", 0, 0)
    ApplyLootFont(drop.plus, 22)
    drop.plus:SetTextColor(0.345, 0.651, 1, 1)
    drop.plus:SetText("+")
    drop:RegisterForClicks("LeftButtonUp")
    drop:SetScript("OnReceiveDrag", function() AAL_Filter.HandleDrop() end)
    drop:SetScript("OnClick", function() AAL_Filter.HandleDrop() end)
    drop:SetScript("OnEnter", function()
        drop.hover = true
        AAL_Filter.PaintDropSlot()
    end)
    drop:SetScript("OnLeave", function()
        drop.hover = false
        AAL_Filter.PaintDropSlot()
    end)
    menuFrame.dropSlot = drop

    local dropHint = CreateMenuLabel(menuFrame, 58, -42, DROP_HINT_TEXT, 10)
    dropHint:SetWidth(268)
    dropHint:SetHeight(32)
    dropHint:SetJustifyV("TOP")
    menuFrame.dropHint = dropHint

    -- Search
    CreateMenuLabel(menuFrame, 14, -92, "Search:", 10)
    local box = CreateFrame("EditBox", nil, menuFrame)
    box:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 62, -88)
    box:SetWidth(264)
    box:SetHeight(20)
    box:SetAutoFocus(false)
    box:SetTextInsets(5, 5, 0, 0)
    box:SetMaxLetters(60)
    ApplyLootFont(box, 11)
    box:SetTextColor(0.902, 0.929, 0.953, 1)
    ApplyThemeBackdrop(box, 0.95)
    box:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    box:SetScript("OnEnterPressed", function()
        this:ClearFocus()
        menuFrame.searchDue = nil
        AAL_Filter.RunSearch()
    end)
    box:SetScript("OnTextChanged", function()
        menuFrame.searchDue = FilterNow() + 0.3
    end)
    menuFrame.searchBox = box

    -- Results
    menuFrame.resultsHeader = CreateMenuLabel(menuFrame, 14, -118, "Results", 10)
    local resultsArea = CreateFrame("Frame", nil, menuFrame)
    resultsArea:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 14, -134)
    resultsArea:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -26, -134)
    resultsArea:SetHeight(MENU_RESULT_ROWS * MENU_ROW_HEIGHT)
    resultsArea:EnableMouseWheel(true)
    resultsArea:SetScript("OnMouseWheel", function()
        menuFrame.resultOffset = (menuFrame.resultOffset or 0) - arg1
        AAL_Filter.RefreshMenu()
    end)
    menuFrame.resultRows = {}
    for index = 1, MENU_RESULT_ROWS do
        menuFrame.resultRows[index] = CreateMenuRow(resultsArea, index, "Add",
            function(row)
                if row.entry and not AAL_Filter.FindEntry(row.entry) then
                    AAL_Filter.AddEntry({ id = row.entry.id, name = row.entry.name })
                end
            end)
    end
    menuFrame.noteText = CreateMenuLabel(menuFrame, 14, -238, "", 9)
    menuFrame.noteText:SetWidth(312)
    menuFrame.noteText:SetTextColor(0.65, 0.70, 0.75, 1)

    -- Your list
    menuFrame.listHeader = CreateMenuLabel(menuFrame, 14, -262, "Your filter list", 10)
    local listArea = CreateFrame("Frame", nil, menuFrame)
    listArea:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 14, -278)
    listArea:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -26, -278)
    listArea:SetHeight(MENU_LIST_ROWS * MENU_ROW_HEIGHT)
    listArea:EnableMouseWheel(true)
    listArea:SetScript("OnMouseWheel", function()
        menuFrame.listOffset = (menuFrame.listOffset or 0) - arg1
        AAL_Filter.RefreshMenu()
    end)
    menuFrame.listRows = {}
    for index = 1, MENU_LIST_ROWS do
        menuFrame.listRows[index] = CreateMenuRow(listArea, index, "Remove",
            function(row)
                if row.listIndex and row.entry then
                    AAL_Filter.RemoveIndex(row.listIndex)
                end
            end)
    end
    menuFrame.emptyText = CreateMenuLabel(menuFrame, 18, -286, "", 9)
    menuFrame.emptyText:SetWidth(300)
    menuFrame.emptyText:SetTextColor(0.65, 0.70, 0.75, 1)

    menuFrame.resultBar = CreateMenuScrollbar(menuFrame, resultsArea,
        MENU_RESULT_ROWS,
        function() return table.getn(menuFrame.results or {}) end,
        function() return menuFrame.resultOffset or 0 end,
        function(value)
            menuFrame.resultOffset = value
            AAL_Filter.RefreshMenu()
        end)
    menuFrame.listBar = CreateMenuScrollbar(menuFrame, listArea,
        MENU_LIST_ROWS,
        function() return table.getn(AutoAreaLootDB.filterItems) end,
        function() return menuFrame.listOffset or 0 end,
        function(value)
            menuFrame.listOffset = value
            AAL_Filter.RefreshMenu()
        end)

    -- Toggles
    menuFrame.filterToggle = CreateAALToggle(menuFrame, "Filter on",
        AutoAreaLootDB.filterEnabled, function(checked)
            AutoAreaLootDB.filterEnabled = checked
            if not checked then AAL_Filter.Reset() end
            AAL_Filter.RefreshAll()
        end)
    menuFrame.filterToggle:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 20, -426)

    menuFrame:SetScript("OnShow", function()
        AAL_Filter.RunSearch()
    end)
    menuFrame:SetScript("OnHide", function()
        GameTooltip:Hide()
        menuFrame.searchDue = nil
    end)
    menuFrame:SetScript("OnUpdate", function()
        local now = FilterNow()
        if menuFrame.searchDue and now >= menuFrame.searchDue then
            menuFrame.searchDue = nil
            AAL_Filter.RunSearch()
        end
        local holding = false
        if type(GetCursorInfo) == "function" then
            holding = (GetCursorInfo() == "item")
        end
        if holding ~= menuFrame.holdingItem then
            menuFrame.holdingItem = holding
            AAL_Filter.PaintDropSlot()
        end
        if menuFrame.feedbackUntil and now >= menuFrame.feedbackUntil then
            menuFrame.feedbackUntil = nil
            AAL_Filter.PaintDropSlot()
        end
    end)
    menuFrame:Hide()
end

function AAL_Filter.ShowMenu()
    if not state.initialized then return end
    CreateFilterMenu()
    if menuFrame:IsShown() then
        menuFrame:Hide()
    else
        menuFrame:Show()
    end
end

-- ESC closes one window at a time: the filter menu first, then the settings
-- panel. A hidden helper frame is what ESC actually closes (WoW closes every
-- registered frame at once), and it decides which real window to close.
do
    local escProxy = CreateFrame("Frame", "AutoAreaLootEscProxy", UIParent)
    escProxy:Hide()
    local syncing = false

    local function IsOpen(frame)
        return frame and frame:IsShown() and true or false
    end

    local function SyncEscProxy()
        local wanted = IsOpen(menuFrame) or IsOpen(AutoAreaLootConfigFrame)
        if wanted ~= IsOpen(escProxy) then
            syncing = true
            if wanted then escProxy:Show() else escProxy:Hide() end
            syncing = false
        end
    end

    escProxy:SetScript("OnHide", function()
        if syncing then return end
        if IsOpen(menuFrame) then
            menuFrame:Hide()
        elseif IsOpen(AutoAreaLootConfigFrame) then
            AutoAreaLootConfigFrame:Hide()
        end
        SyncEscProxy()
    end)

    local watcher = CreateFrame("Frame", nil, UIParent)
    local waited = 0
    watcher:SetScript("OnUpdate", function()
        waited = waited + (arg1 or 0)
        if waited < 0.1 then return end
        waited = 0
        SyncEscProxy()
    end)

    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "AutoAreaLootEscProxy")
    end
end

local function SetEnabled(enabled)
    AutoAreaLootDB.enabled = enabled and true or false
    DebugLog("Addon enabled set to " .. tostring(AutoAreaLootDB.enabled))
    if not AutoAreaLootDB.enabled then
        if AAL_Filter then AAL_Filter.Reset() end
        state.lootRequestTimer = nil
        state.lootSettleUntil = nil
        state.pendingLootReason = nil
        state.lootAfterCombat = false
        state.lootWalkActive = false
        state.lootWalkStartedAt = nil
        state.activeCapture = nil
        state.stopGraceTimer = nil
        state.lastStopLootRequestAt = nil
        state.lastStopPositionX = nil
        state.lastStopPositionY = nil
        state.lastStopPositionZ = nil
    end
end

local function CreateCheckButton(parent, label, y, setting)
    local check = CreateAALToggle(parent, label, AutoAreaLootDB[setting], function(checked)
        AutoAreaLootDB[setting] = checked
        if setting == "enabled" then
            SetEnabled(AutoAreaLootDB.enabled)
        end
    end)
    check:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    return check
end

local function RefreshConfigPanel()
    if not configFrame or not state.initialized then return end
    configFrame.filterCheck:SetChecked(AutoAreaLootDB.filterEnabled)
    configFrame.moneyCheck:SetChecked(AutoAreaLootDB.lootMoneyFullCorpse)
    configFrame.movingCheck:SetChecked(AutoAreaLootDB.lootWhileMoving)
    configFrame.qualityButton.label:SetText("Quality: " .. AAL_Filter.GetQualityLabel())
    configFrame.enabledCheck:SetChecked(AutoAreaLootDB.enabled)
    configFrame.deathCheck:SetChecked(AutoAreaLootDB.lootOnDeath)
    configFrame.stopCheck:SetChecked(AutoAreaLootDB.lootOnStop)
    configFrame.combatCheck:SetChecked(AutoAreaLootDB.lootInCombat)
    configFrame.openLogCheck:SetChecked(AutoAreaLootDB.openLootLogOnLogin)
end

local function CreateConfigPanel()
    if configFrame then return end

    configFrame = CreateFrame("Frame", "AutoAreaLootConfigFrame", UIParent)
    configFrame:SetWidth(260)
    configFrame:SetHeight(322)
    configFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    configFrame:SetFrameStrata("DIALOG")
    configFrame:SetToplevel(true)
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", function() this:StartMoving() end)
    configFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    configFrame:SetScript("OnShow", RefreshConfigPanel)
    ApplyThemeBackdrop(configFrame, 0.90, true)

    local header = configFrame:CreateTexture(nil, "BACKGROUND")
    header:SetTexture("Interface\\Buttons\\WHITE8X8")
    header:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -1, -1)
    header:SetHeight(34)
    if IsPfUIThemeActive() then
        local r, g, b = GetThemeBackgroundColor()
        header:SetVertexColor(r, g, b, 0.75)
    else
        header:SetVertexColor(0.090, 0.153, 0.243, 0.55)
    end

    local accent = configFrame:CreateTexture(nil, "BORDER")
    accent:SetTexture("Interface\\Buttons\\WHITE8X8")
    accent:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -1, -1)
    accent:SetHeight(2)
    local accentR, accentG, accentB = GetThemeAccentColor()
    accent:SetVertexColor(accentR, accentG, accentB, 0.85)

    local title = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", configFrame, "TOP", 0, -10)
    ApplyLootFont(title, 13)
    title:SetTextColor(0.902, 0.929, 0.953, 1)
    title:SetText("AutoAreaLoot")

    local close = CreateAALButton(configFrame, 18, 18, "X")
    close:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -6, -6)
    ApplyLootFont(close.label, 9)
    StyleCloseButton(close)
    close:SetScript("OnClick", function() this:GetParent():Hide() end)

    configFrame.enabledCheck = CreateCheckButton(
        configFrame, "Loot enabled", -44, "enabled")
    configFrame.deathCheck = CreateCheckButton(
        configFrame, "Loot on death", -68, "lootOnDeath")
    configFrame.stopCheck = CreateCheckButton(
        configFrame, "Loot on movement stop", -92, "lootOnStop")
    configFrame.combatCheck = CreateCheckButton(
        configFrame, "Allow looting in combat", -116, "lootInCombat")
    configFrame.openLogCheck = CreateCheckButton(
        configFrame, "Open loot log on login/reload", -140, "openLootLogOnLogin")

    configFrame.filterCheck = CreateCheckButton(
        configFrame, "Only loot items on my list", -164, "filterEnabled")
    configFrame.moneyCheck = CreateCheckButton(
        configFrame, "Loot money (whole corpse)", -188, "lootMoneyFullCorpse")
    configFrame.movingCheck = CreateCheckButton(
        configFrame, "Loot while moving", -212, "lootWhileMoving")

    local qualityButton = CreateAALButton(configFrame, 180, 18, "Quality: off")
    qualityButton:SetPoint("TOP", configFrame, "TOP", 0, -238)
    ApplyLootFont(qualityButton.label, 10)
    qualityButton:SetScript("OnClick", function()
        AAL_Filter.CycleQuality()
        RefreshConfigPanel()
    end)
    configFrame.qualityButton = qualityButton

    local menuButton = CreateAALButton(configFrame, 180, 18, "Edit Filter List...")
    menuButton:SetPoint("TOP", configFrame, "TOP", 0, -264)
    ApplyLootFont(menuButton.label, 10)
    menuButton:SetScript("OnClick", function() AAL_Filter.ShowMenu() end)

    local logButton = CreateAALButton(configFrame, 118, 18, "Open Loot Log")
    logButton:SetPoint("BOTTOM", configFrame, "BOTTOM", 0, 7)
    ApplyLootFont(logButton.label, 10)
    logButton:SetScript("OnClick", ShowLootLog)

    configFrame:Hide()
end

AAL_RefreshConfig = RefreshConfigPanel

local function ShowConfigPanel()
    CreateConfigPanel()
    if configFrame:IsShown() then
        configFrame:Hide()
    else
        configFrame:Show()
    end
end

local function HandlePlayerMovementStarted(source)
    state.playerMoving = true
    state.movementStateKnown = true
    if state.stopGraceTimer then
        QueuePendingLootRequest(state.stopGraceTimer.source)
        state.stopGraceTimer = nil
        DebugLog("Movement resumed: cancelled stable-stop grace; source="
            .. source)
    else
        DebugLog("Movement started; source=" .. source)
    end
end

local function HandlePlayerMovementStopped(source)
    state.playerMoving = false
    state.movementStateKnown = true
    if AutoAreaLootDB.lootOnStop then
        DebugLog("Stop trigger accepted; source=" .. source)
        local now = type(GetTime) == "function" and GetTime() or nil
        local x, y, z = GetPlayerWorldPosition()
        local moved = GetDistanceFromLastStop(x, y, z)
        local elapsed = now and state.lastStopLootRequestAt
            and now - state.lastStopLootRequestAt or nil
        local withinSameArea = not moved
            or moved < STOP_LOOT_MOVEMENT_DISTANCE
        local withinCooldown = elapsed
            and elapsed < STOP_LOOT_SAME_AREA_INTERVAL
        local coalesced = withinSameArea and withinCooldown
        if coalesced then
            DebugLog("Stop trigger coalesced: elapsed="
                .. (elapsed and string.format("%.3f", elapsed) or "unknown")
                .. " moved=" .. (moved and string.format("%.2f", moved)
                    or "unknown") .. " yards")
            if state.pendingLootReason then
                ScheduleStableStopLoot(state.pendingLootReason)
            end
            return
        end
        state.lastStopLootRequestAt = now
        if x then
            state.lastStopPositionX = x
            state.lastStopPositionY = y
            state.lastStopPositionZ = z
        end
        if moved then
            DebugLog("Stop trigger position accepted: moved="
                .. string.format("%.2f", moved) .. " yards")
        end
        if IsPlayerInCombat() then
            state.lootAfterCombat = true
            DebugLog("Stop trigger marked a post-combat pass")
        end
        local stopSource = moved
            and moved >= STOP_LOOT_MOVEMENT_DISTANCE and "moved" or "stop"
        ScheduleStableStopLoot(stopSource)
    else
        DebugLog("Stop trigger ignored: setting disabled")
        if state.pendingLootReason then
            ScheduleStableStopLoot(state.pendingLootReason)
        end
    end
end

eventFrame = CreateFrame("Frame")

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("PLAYER_MONEY")
if IsEventAvailable("LOOT_SCAN_COMPLETED") then
    eventFrame:RegisterEvent("LOOT_SCAN_COMPLETED")
end
if IsEventAvailable("UNIT_SPELLCAST_CHANNEL_STOP") then
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
end
if IsEventAvailable("UNIT_SPELLCAST_START") then
    eventFrame:RegisterEvent("UNIT_SPELLCAST_START")
end
if IsEventAvailable("UNIT_SPELLCAST_CHANNEL_START") then
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
end
if IsEventAvailable("UNIT_SPELLCAST_STOP") then
    eventFrame:RegisterEvent("UNIT_SPELLCAST_STOP")
end
if IsEventAvailable("UNIT_SPELLCAST_CHANNEL_INTERRUPTED") then
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_INTERRUPTED")
end
if IsEventAvailable("UNIT_SPELLCAST_CHANNEL_FAILED") then
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_FAILED")
end
-- The 1.12 client reports tradeskill-style casts such as bandaging through
-- these player-only events. They close the short gap where UnitCastingInfo or
-- UnitChannelInfo may still return nil immediately after the cast begins.
eventFrame:RegisterEvent("SPELLCAST_START")
eventFrame:RegisterEvent("SPELLCAST_CHANNEL_START")
eventFrame:RegisterEvent("SPELLCAST_STOP")
eventFrame:RegisterEvent("SPELLCAST_CHANNEL_STOP")
eventFrame:RegisterEvent("SPELLCAST_INTERRUPTED")
eventFrame:RegisterEvent("SPELLCAST_FAILED")
if IsEventAvailable("PLAYER_CONTROL_LOST") then
    eventFrame:RegisterEvent("PLAYER_CONTROL_LOST")
end
if IsEventAvailable("PLAYER_CONTROL_GAINED") then
    eventFrame:RegisterEvent("PLAYER_CONTROL_GAINED")
end
if IsEventAvailable("UNIT_DIED") then
    eventFrame:RegisterEvent("UNIT_DIED")
else
    eventFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
    if not missingNampowerWarningShown then
        missingNampowerWarningShown = true
        DEFAULT_CHAT_FRAME:AddMessage(
            "AutoAreaLoot: Nampower is recommended for reliable death detection; using combat-text fallback.")
    end
end

eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" then
        if arg1 == "AutoAreaLoot" then
            InitializeSettings()
            InitializeLootPatterns()
            state.useSpeedMovement = type(GetUnitSpeed) == "function"
            state.moneyBaseline = SafeGetMoney()
            CreateConfigPanel()
            eventFrame:UnregisterEvent("ADDON_LOADED")
            HasClassicAPILoot()
            if AutoAreaLootDB.openLootLogOnLogin then
                ShowLootLog()
            end
        end
        return
    end

    DebugLog("Event received: " .. tostring(event))

    if event == "PLAYER_LEAVING_WORLD" then
        DebugLog("Leaving world: clearing transient loot state")
        state.lootRequestTimer = nil
        state.lootSettleUntil = nil
        state.pendingLootReason = nil
        state.lootAfterCombat = false
        state.manualLootOpen = false
        state.autoLootWindowOpen = false
        state.lootWalkActive = false
        state.lootWalkStartedAt = nil
        state.playerMoving = false
        state.movementStateKnown = false
        state.playerStateSampleElapsed = 0
        state.playerSpellcastActive = false
        state.playerControlLost = false
        state.stopGraceTimer = nil
        state.lastStopLootRequestAt = nil
        state.lastStopPositionX = nil
        state.lastStopPositionY = nil
        state.lastStopPositionZ = nil
        state.activeCapture = nil
        state.pendingCaptures = {}
        state.moneyBaseline = nil
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        if state.lootAfterCombat or state.pendingLootReason then
            DebugLog("Combat ended: preserving one deferred loot request")
            if state.lootAfterCombat then
                QueuePendingLootRequest("combat")
            end
            state.lootAfterCombat = false
            ServicePendingLootRequest()
        else
            DebugLog("Combat ended: no deferred loot request")
        end
        return
    end

    if event == "PLAYER_CONTROL_LOST" then
        state.playerControlLost = true
        DebugLog("Player control lost; deferring loot")
        return
    end

    if event == "PLAYER_CONTROL_GAINED" then
        state.playerControlLost = false
        DebugLog("Player control gained; servicing deferred loot")
        ServicePendingLootRequest()
        return
    end

    if event == "UNIT_DIED" or event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" then
        if AutoAreaLootDB.lootOnDeath then
            local deathGuid = event == "UNIT_DIED" and arg1 or nil
            local accepted, distance = ShouldAcceptDeathTrigger(deathGuid)
            if not accepted then
                DebugLog("Death trigger ignored: guid="
                    .. ShortCorpseGuid(deathGuid) .. " distance="
                    .. string.format("%.2f", distance)
                    .. " yards exceeds " .. DEATH_TRIGGER_DISTANCE_LIMIT)
                return
            end
            DebugLog("Death trigger accepted: guid="
                .. ShortCorpseGuid(deathGuid) .. " distance="
                .. (distance and string.format("%.2f", distance) or "unknown"))
            if IsPlayerInCombat() then
                state.lootAfterCombat = true
                DebugLog("Death trigger marked a post-combat pass")
            end
            if state.stopGraceTimer or state.lootWalkActive
                or IsLootScanInProgress() then
                QueuePendingLootRequest("death")
                DebugLog("Death trigger queued behind active scan or stop grace")
            else
                ScheduleLootRequest(DEATH_LOOT_REQUEST_DELAY, "death")
            end
        else
            DebugLog("Death trigger ignored: setting disabled")
        end
        return
    end

    if event == "LOOT_OPENED" then
        if state.filterWalk then
            AAL_Filter.SafeOnLootOpened()
            return
        end
        if state.lootWalkActive then
            state.autoLootWindowOpen = true
            DebugLog("Loot window opened during automatic walk; closing it")
            if type(CloseLoot) == "function" then
                pcall(CloseLoot)
            else
                state.manualLootOpen = true
                DebugLog("CloseLoot is unavailable; treating window as manual")
            end
        else
            state.manualLootOpen = true
            DebugLog("Manual loot window marked open")
        end
        return
    end

    if event == "LOOT_CLOSED" and state.filterWalk then
        state.manualLootOpen = false
        return
    end

    if event == "LOOT_CLOSED" then
        state.manualLootOpen = false
        state.autoLootWindowOpen = false
        DebugLog("Manual loot window marked closed")
        ServicePendingLootRequest()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        AAL_Filter.Reset()
        state.moneyBaseline = SafeGetMoney()
        state.playerMoving = false
        state.movementStateKnown = false
        state.playerStateSampleElapsed = 0
        state.playerSpellcastActive = false
        state.playerControlLost = false
        state.stopGraceTimer = nil
        state.lastStopLootRequestAt = nil
        state.lastStopPositionX = nil
        state.lastStopPositionY = nil
        state.lastStopPositionZ = nil
        DebugLog("Entered world: money baseline=" .. tostring(state.moneyBaseline))
        return
    end

    if event == "CHAT_MSG_LOOT" then
        local parseOK, confirmation = pcall(ParseSelfLootMessage, arg1)
        DebugLog("Loot chat parse: ok=" .. tostring(parseOK)
            .. " selfItem=" .. tostring(confirmation ~= nil))
        if parseOK and confirmation then
            local matchOK, matchError = pcall(
                BufferOrMatchCaptureEvent, confirmation)
            if not matchOK then
                DebugLog("Loot confirmation handler failed: "
                    .. tostring(matchError))
            end
        elseif not parseOK then
            DebugLog("Loot chat parser failed: " .. tostring(confirmation))
        end
        return
    end

    if event == "PLAYER_MONEY" then
        local currentMoney = SafeGetMoney()
        DebugLog("Money event: before=" .. tostring(state.moneyBaseline)
            .. " after=" .. tostring(currentMoney))
        if currentMoney ~= nil and state.moneyBaseline ~= nil then
            local gained = currentMoney - state.moneyBaseline
            if gained > 0 then
                DebugLog("Positive money change detected: " .. gained)
                local matchOK, matchError = pcall(BufferOrMatchCaptureEvent,
                    { kind = "money", amount = gained })
                if not matchOK then
                    DebugLog("Money confirmation handler failed: "
                        .. tostring(matchError))
                end
            else
                DebugLog("Money change was not a gain: " .. gained)
            end
        end
        state.moneyBaseline = currentMoney
        return
    end

    if event == "LOOT_SCAN_COMPLETED" then
        DebugLog("ClassicAPI reported LOOT_SCAN_COMPLETED")
        CompleteActiveLootWalk()
        ServicePendingLootRequest()
        return
    end

    if event == "SPELLCAST_START" or event == "SPELLCAST_CHANNEL_START"
        or event == "UNIT_SPELLCAST_START"
        or event == "UNIT_SPELLCAST_CHANNEL_START" then
        if string.sub(event, 1, 5) ~= "UNIT_" or arg1 == "player" then
            state.playerSpellcastActive = true
            DebugLog("Player spellcast started; automatic loot blocked")
        end
        return
    end

    if event == "SPELLCAST_STOP" or event == "SPELLCAST_CHANNEL_STOP"
        or event == "SPELLCAST_INTERRUPTED" or event == "SPELLCAST_FAILED"
        or event == "UNIT_SPELLCAST_STOP" then
        if string.sub(event, 1, 5) ~= "UNIT_" or arg1 == "player" then
            state.playerSpellcastActive = false
            DebugLog("Player spellcast ended; servicing deferred loot")
            ServicePendingLootRequest()
        end
        return
    end

    if event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_CHANNEL_INTERRUPTED"
        or event == "UNIT_SPELLCAST_CHANNEL_FAILED" then
        if arg1 == "player" then
            state.playerSpellcastActive = false
            DebugLog("Player channel ended; servicing deferred loot")
            ServicePendingLootRequest()
        end
        return
    end

end)

eventFrame:SetScript("OnUpdate", function()
    if not state.initialized then return end

    if state.filterWalk then AAL_Filter.SafeTick() end

    state.movePollElapsed = (state.movePollElapsed or 0) + arg1
    if state.movePollElapsed >= 0.10 then
        state.movePollElapsed = 0
        AAL_Filter.SafePoll()
    end

    state.playerStateSampleElapsed = state.playerStateSampleElapsed + arg1
    if state.playerStateSampleElapsed >= PLAYER_STATE_SAMPLE_INTERVAL then
        state.playerStateSampleElapsed = 0
        RecoverTimedOutLootWalk()
    end

    if not state.useSpeedMovement then return end
    local moving = GetPlayerSpeedMovementState()
    if moving == nil then return end
    if not state.movementStateKnown then
        state.playerMoving = moving
        state.movementStateKnown = true
        DebugLog("Speed movement baseline: moving=" .. tostring(moving))
        return
    end
    if moving == state.playerMoving then return end
    if moving then
        HandlePlayerMovementStarted("speed")
    else
        HandlePlayerMovementStopped("speed")
    end
end)

SLASH_AUTOAREA_LOOT1 = "/aal"
SlashCmdList["AUTOAREA_LOOT"] = function(message)
    if not state.initialized then return end
    local command = string.lower(string.match(message or "", "^%s*(.-)%s*$"))
    local filterSub, filterRest = string.match(
        string.match(message or "", "^%s*(.-)%s*$"), "^(%S+)%s*(.-)$")
    if filterSub and AAL_Filter
        and AAL_Filter.HandleCommand(string.lower(filterSub), filterRest) then
        return
    end

    if command == "on" then
        SetEnabled(true)
        RefreshConfigPanel()
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot: enabled.")
    elseif command == "off" then
        SetEnabled(false)
        RefreshConfigPanel()
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot: disabled.")
    elseif command == "status" then
        DEFAULT_CHAT_FRAME:AddMessage(
            "AutoAreaLoot is " .. (AutoAreaLootDB.enabled and "enabled" or "disabled")
            .. "; death trigger " .. (AutoAreaLootDB.lootOnDeath and "on" or "off")
            .. "; stop trigger " .. (AutoAreaLootDB.lootOnStop and "on" or "off")
            .. "; combat looting " .. (AutoAreaLootDB.lootInCombat and "on" or "off")
            .. "; item filter " .. (AutoAreaLootDB.filterEnabled and "on" or "off")
            .. ".")
    elseif command == "log" then
        ShowLootLog()
    elseif command == "debug" or command == "debug on" then
        state.debugEnabled = true
        DebugLog("Debug capture enabled")
        ShowDebugWindow()
        DEFAULT_CHAT_FRAME:AddMessage(
            "AutoAreaLoot: debug capture enabled. Use /aal debug off to stop it.")
    elseif command == "debug off" then
        DebugLog("Debug capture disabled")
        state.debugEnabled = false
        UpdateDebugTitle()
        if debugFrame and debugFrame.pauseButton then
            debugFrame.pauseButton.label:SetText("Resume")
        end
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot: debug capture disabled.")
    elseif command == "debug clear" then
        state.debugLines = {}
        RefreshDebugLog(false)
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot: debug log cleared.")
    else
        ShowConfigPanel()
    end
end
