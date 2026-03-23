-- StoredAnimaCounter
-- Updated for WoW Midnight (Patch 12.0.1 / TOC 120001)
-- Changes from original (Shadowlands) and TWW (11.x) versions:
--   * TOC interface version bumped to 120001
--   * GetItemCount() global removed in 12.0 -> C_Item.GetItemCount()
--   * GetItemInfo() global removed in 12.0 -> C_Item.GetItemInfo()
--   * ToggleCollectionsJournal removed -> C_AddOns / Settings panel
--   * C_CovenantSanctumUI (Shadowlands-only) guarded with pcall + nil check
--   * TooltipDataProcessor uses Enum.TooltipDataType.Item (11.x+)
--   * tooltip:GetItem() wrapped in pcall to guard against Secret Value taint
--   * InterfaceOptionsFrame_OpenToCategory removed -> Settings.OpenToCategory
--   * SetScript("onUpdate") -> SetScript("OnUpdate") (correct casing)
--   * Fixed typo: SetCountBankedAnima was saving to wrong db key
--   * AceConfigDialog:AddToBlizOptions kept with graceful error handling

local addonName, addonTable = ...
local StoredAnimaCounter = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceBucket-3.0", "AceEvent-3.0")

local _G = _G
local BreakUpLargeNumbers = BreakUpLargeNumbers
local NUM_BANKBAGSLOTS = NUM_BANKBAGSLOTS or 7
local AceDB = LibStub("AceDB-3.0")
local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local LDB = LibStub:GetLibrary("LibDataBroker-1.1")

local iconString = '|T%s:16:16:0:0:64:64:4:60:4:60|t '

-- init ldbObject
local ldbObject = LDB:NewDataObject("Stored Anima", {
    type = "data source",
    text = "-",
    value = 0,
    icon = "Interface\\Icons\\spell_animabastion_orb",
    label = "Stored Anima"
})

local Format = {
    stored = 1,
    stored_plus_pool = 2,
    pool_plus_stored = 3,
    sum_only = 4,
    sum_plus_stored = 5,
    stored_plus_sum = 6,
    pool_plus_sum = 7,
    custom_format = 8
}

local baggedAnima = 0
local bankedAnima = 0

local FormatLabels = {
    "stored_only", "stored_plus_pool", "pool_plus_stored", "sum_only",
    "sum_plus_stored", "stored_plus_sum", "pool_plus_sum", "custom_format"
}

local bankListener = nil
local bucketListener = nil
local worldListener = nil
local currListener = nil
local configIsVerbose = false
local configFormat = Format.stored
local configBreakLargeNumbers = true
local configShowLabel = true
local configShowIcon = true
local configCustomFormat = "${stored}+${pool}=${sum}"
local configTTStoredAnima = true
local configTTBaggedAnima = true
local configTTReservoirAnima = true
local configTTTotalAnima = true
local configTTBankedAnima = true
local configCountBankedAnima = true
local blizOptionsCategoryID = nil   -- numeric ID returned by AceConfigDialog:AddToBlizOptions in 12.0+

local defaults = {
    profile = {
        format = Format.stored,
        verbose = false,
        breakLargeNumbers = true,
        showLabel = true,
        showIcon = true,
        customFormat = "${stored}+${pool}=${sum}",
        TTStoredAnima = true,
        TTBaggedAnima = true,
        TTReservoirAnima = true,
        TTTotalAnima = true,
        TTBankedAnima = true,
        countBankedAnima = true,
        bankedAnima = 0
    }
}

-- ---------------------------------------------------------------------------
-- Helper: safely get reservoir anima
-- C_CovenantSanctumUI is Shadowlands-only and does not exist in Midnight/TWW.
-- ---------------------------------------------------------------------------
function GetReservoirAnima()
    if C_CovenantSanctumUI and C_CovenantSanctumUI.GetAnimaInfo then
        local ok, currencyID = pcall(C_CovenantSanctumUI.GetAnimaInfo)
        if ok and currencyID then
            local info = C_CurrencyInfo.GetCurrencyInfo(currencyID)
            if info then return info.quantity end
        end
    end
    return 0
end

-- Helper: safely get anima icon (falls back to a known FileID)
function StoredAnimaCounter:GetAnimaIcon()
    if C_CovenantSanctumUI and C_CovenantSanctumUI.GetAnimaInfo then
        local ok, currencyID = pcall(C_CovenantSanctumUI.GetAnimaInfo)
        if ok and currencyID then
            local info = C_CurrencyInfo.GetCurrencyInfo(currencyID)
            if info then return info.iconFileID end
        end
    end
    return 3528287 -- spell_animabastion_orb FileID fallback
end

-- ---------------------------------------------------------------------------
-- Hooks
-- TooltipDataProcessor.AddTooltipPostCall uses Enum.TooltipDataType.Item
-- (passing the string "ALL" was removed in later 11.x patches).
-- tooltip:GetItem() is wrapped in pcall because in Midnight the item link
-- can be a "Secret Value" when moused over during combat, which throws an
-- error if not caught.
-- ---------------------------------------------------------------------------
function StoredAnimaCounter:SetUpHooks()
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if not (configTTBaggedAnima or configTTReservoirAnima or configTTTotalAnima
                or configTTStoredAnima or configTTBankedAnima) then
            return
        end

        -- Guard against tooltips that don't support GetItem (e.g. ShoppingTooltip)
        -- and Secret Value taint introduced in Midnight 12.0
        if not tooltip.GetItem then return end
        local ok, _, link = pcall(function() return tooltip:GetItem() end)
        if not ok or link == nil then return end

        if not C_Item.IsAnimaItemByID(link) then return end

        local stored, pool, sum, banked, bagged
        if configBreakLargeNumbers then
            stored = BreakUpLargeNumbers(StoredAnimaCounter:GetStoredAnima())
            pool   = BreakUpLargeNumbers(GetReservoirAnima())
            sum    = BreakUpLargeNumbers(GetReservoirAnima() + StoredAnimaCounter:GetStoredAnima())
            bagged = BreakUpLargeNumbers(baggedAnima)
            banked = BreakUpLargeNumbers(bankedAnima)
        else
            stored = StoredAnimaCounter:GetStoredAnima()
            pool   = GetReservoirAnima()
            sum    = GetReservoirAnima() + StoredAnimaCounter:GetStoredAnima()
            bagged = baggedAnima
            banked = bankedAnima
        end

        tooltip:AddLine("\n")
        if configTTBaggedAnima  then tooltip:AddDoubleLine("|cFF2C94FEAnima (bag):|r",       "|cFFFFFFFF" .. bagged  .. "|r") end
        if configTTBankedAnima  then tooltip:AddDoubleLine("|cFF2C94FEAnima (bank):|r",      "|cFFFFFFFF" .. banked  .. "|r") end
        if configTTStoredAnima  then tooltip:AddDoubleLine("|cFF2C94FEAnima (stored):|r",    "|cFFFFFFFF" .. stored  .. "|r") end
        if configTTReservoirAnima then tooltip:AddDoubleLine("|cFF2C94FEAnima (reservoir):|r", "|cFFFFFFFF" .. pool  .. "|r") end
        if configTTTotalAnima   then tooltip:AddDoubleLine("|cFF2C94FEAnima (total):|r",     "|cFFFFFFFF" .. sum     .. "|r") end
    end)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function StoredAnimaCounter:OnInitialize()
    StoredAnimaCounter:SetupDB()
    StoredAnimaCounter:SetupConfig()
    print("Addon " .. addonName .. " loaded!")
end

function StoredAnimaCounter:OnEnable()
    StoredAnimaCounter:RefreshConfig()

    if worldListener == nil then
        worldListener = self:RegisterEvent("PLAYER_ENTERING_WORLD", "ScanForStoredAnimaDelayed")
    end
    if currListener == nil then
        currListener = self:RegisterEvent("CURRENCY_DISPLAY_UPDATE", "ScanForStoredAnima")
    end
    if bucketListener == nil then
        bucketListener = self:RegisterBucketEvent("BAG_UPDATE", 0.2, "ScanChange")
    end
    if bankListener == nil then
        bankListener = self:RegisterBucketEvent("BANKFRAME_OPENED", 0.2, "ScanBankForStoredAnima")
    end
end

function StoredAnimaCounter:ScanChange(events)
    for bagId, val in pairs(events) do
        if (bagId == -1 or (bagId > NUM_BAG_SLOTS and bagId <= NUM_BAG_SLOTS + NUM_BANKBAGSLOTS)) then
            StoredAnimaCounter:ScanBankForStoredAnima()
        elseif (bagId >= 0 and bagId <= NUM_BAG_SLOTS) then
            StoredAnimaCounter:ScanForStoredAnima()
        else
            StoredAnimaCounter:ScanBankForStoredAnima()
            StoredAnimaCounter:ScanForStoredAnima()
        end
    end
end

function StoredAnimaCounter:OnDisable()
    if worldListener  then self:UnregisterEvent(worldListener);   worldListener  = nil end
    if currListener   then self:UnregisterEvent(currListener);    currListener   = nil end
    if bucketListener then self:UnregisterBucket(bucketListener); bucketListener = nil end
    if bankListener   then self:UnregisterBucket(bankListener);   bankListener   = nil end
end

function StoredAnimaCounter:SetupDB()
    self.db = AceDB:New("StoredAnimaCounterDB", defaults)
    self.db.RegisterCallback(self, "OnProfileChanged", "RefreshConfig")
    self.db.RegisterCallback(self, "OnProfileCopied",  "RefreshConfig")
    self.db.RegisterCallback(self, "OnProfileReset",   "RefreshConfig")
end

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------
function StoredAnimaCounter:SetupConfig()
    local options = {
        name = addonName,
        handler = StoredAnimaCounter,
        type = "group",
        childGroups = "tree",
        args = {
            config = {
                name = "Configuration",
                desc = "Opens the SAC Configuration panel",
                type = "execute",
                func = "OpenConfigPanel",
                guiHidden = true
            },
            general = {
                name = "General",
                type = "group",
                handler = StoredAnimaCounter,
                args = {
                    headerFormat = { name = "Formatting", type = "header", order = 1 },
                    format = {
                        name = "Choose output format",
                        type = "select",
                        values = FormatLabels,
                        set = "SetFormat", get = "GetFormat",
                        width = "full", order = 2
                    },
                    formatDesc = {
                        name = "\nChoose a format to adapt how the value of Stored Anima is displayed.\n"
                             .. " stored = 100\n stored_plus_pool = 100 (4900)\n pool_plus_stored = 4900 (100)\n"
                             .. " sum_only = 5000\n sum_plus_stored = 5000 (100)\n stored_plus_sum = 100 (5000)\n"
                             .. " pool_plus_sum = 4900 (5000)",
                        type = "description", order = 3
                    },
                    customFormat = {
                        name = "Custom format",
                        desc = "Create your own custom format string for the output",
                        type = "input",
                        set = "SetCustomFormat", get = "GetCustomFormat",
                        width = "full", order = 4
                    },
                    customFormatDesc = {
                        name = "\nVariables: ${stored} ${pool} ${sum} ${bagged} ${banked}",
                        type = "description", order = 5
                    },
                    headerVerbose = { name = "Extra toggles", type = "header", order = 6 },
                    largeNumbers = {
                        name = "Break down large numbers",
                        desc = "Type large number using separators",
                        type = "toggle",
                        set = "SetBreakLargeNumbers", get = "GetBreakLargeNumbers",
                        width = "full", order = 7
                    },
                    countBankedAnima = {
                        name = "Count banked anima",
                        desc = "Also count anima stored in bank as stored (open Bank at least once)",
                        type = "toggle",
                        set = "SetCountBankedAnima", get = "GetCountBankedAnima",
                        width = "full", order = 8
                    },
                    icon = {
                        name = "Show icon in text",
                        desc = "Show icon in the value text (workaround for eg. ElvUI Datatexts)",
                        type = "toggle",
                        set = "SetShowIcon", get = "GetShowIcon",
                        width = "full", order = 9
                    },
                    label = {
                        name = "Show label",
                        desc = "Show label in front of output",
                        type = "toggle",
                        set = "SetShowLabel", get = "GetShowLabel",
                        width = "full", order = 10
                    },
                    verbose = {
                        name = "Enable chat output",
                        desc = "Toggle verbose output in chat",
                        type = "toggle",
                        set = "SetVerbose", get = "GetVerbose",
                        width = "full", order = 11
                    }
                }
            },
            tooltip = {
                name = "Tooltip",
                type = "group",
                handler = StoredAnimaCounter,
                args = {
                    tooltipDesc   = { name = "\nToggle info to show on anima item tooltips", type = "description", order = 1 },
                    baggedAnimaToggle = {
                        name = "Show bagged anima", desc = "Show total anima currently in your bags",
                        type = "toggle", set = "SetTTBaggedAnima", get = "GetTTBaggedAnima", width = "full", order = 2
                    },
                    bankedAnimaToggle = {
                        name = "Show banked anima", desc = "Show total anima currently stored in your bank",
                        type = "toggle", set = "SetTTBankedAnima", get = "GetTTBankedAnima", width = "full", order = 3
                    },
                    storedAnimaToggle = {
                        name = "Show stored anima", desc = "Show total anima in bags and bank (if enabled)",
                        type = "toggle", set = "SetTTStoredAnima", get = "GetTTStoredAnima", width = "full", order = 4
                    },
                    reservoirAnimaToggle = {
                        name = "Show reservoir anima", desc = "Show anima in your covenant's reservoir",
                        type = "toggle", set = "SetTTReservoirAnima", get = "GetTTReservoirAnima", width = "full", order = 5
                    },
                    totalAnimaToggle = {
                        name = "Show total anima", desc = "Show total of bagged and reservoir anima",
                        type = "toggle", set = "SetTTTotalAnima", get = "GetTTTotalAnima", width = "full", order = 6
                    }
                }
            }
        }
    }
    options.args.profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db)
    AceConfig:RegisterOptionsTable(addonName, options, {"storedanimacounter", "sac"})

    -- AceConfigDialog:AddToBlizOptions returns a numeric category ID in 12.0+.
    -- We store it so OpenConfigPanel can pass it to Settings.OpenToCategory,
    -- which requires a number — passing the addon name string causes the error:
    --   "bad argument #1 to 'OpenSettingsPanel' (outside of expected range)"
    local ok, result = pcall(function() return AceConfigDialog:AddToBlizOptions(addonName) end)
    if ok and type(result) == "number" then
        blizOptionsCategoryID = result
    end
end

function StoredAnimaCounter:RefreshConfig()
    configIsVerbose         = self.db.profile.verbose
    configFormat            = self.db.profile.format
    configBreakLargeNumbers = self.db.profile.breakLargeNumbers
    configShowLabel         = self.db.profile.showLabel
    configShowIcon          = self.db.profile.showIcon
    configCustomFormat      = self.db.profile.customFormat
    configTTBaggedAnima     = self.db.profile.TTBaggedAnima
    configTTBankedAnima     = self.db.profile.TTBankedAnima
    configTTStoredAnima     = self.db.profile.TTStoredAnima
    configTTReservoirAnima  = self.db.profile.TTReservoirAnima
    configTTTotalAnima      = self.db.profile.TTTotalAnima
    configCountBankedAnima  = self.db.profile.countBankedAnima
    bankedAnima             = self.db.profile.bankedAnima
    StoredAnimaCounter:SetUpHooks()
    StoredAnimaCounter:ScanForStoredAnima()
end

-- Opens settings panel.
-- In 12.0+, Settings.OpenToCategory requires a numeric category ID, NOT a string.
-- Passing the addon name string causes: "bad argument #1 to 'OpenSettingsPanel'
-- (outside of expected range -2147483648 to 2147483647)"
-- The numeric ID is returned by AceConfigDialog:AddToBlizOptions and stored at setup time.
function StoredAnimaCounter:OpenConfigPanel(info)
    if Settings and Settings.OpenToCategory then
        if blizOptionsCategoryID then
            Settings.OpenToCategory(blizOptionsCategoryID)
        else
            -- Fallback: try to open by forcing AceConfigDialog to show its own frame
            AceConfigDialog:Open(addonName)
        end
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(addonName)
        InterfaceOptionsFrame_OpenToCategory(addonName)
    else
        AceConfigDialog:Open(addonName)
    end
end

-- ---------------------------------------------------------------------------
-- Accessors / setters (AceConfig callbacks)
-- ---------------------------------------------------------------------------
function StoredAnimaCounter:SetVerbose(info, v)          configIsVerbose = v;         self.db.profile.verbose = v            end
function StoredAnimaCounter:GetVerbose(info)             return configIsVerbose                                               end
function StoredAnimaCounter:SetFormat(info, v)           configFormat = v;            self.db.profile.format = v;             StoredAnimaCounter:OutputValue() end
function StoredAnimaCounter:GetFormat(info)              return configFormat                                                  end
function StoredAnimaCounter:SetBreakLargeNumbers(info,v) configBreakLargeNumbers = v; self.db.profile.breakLargeNumbers = v;  StoredAnimaCounter:OutputValue() end
function StoredAnimaCounter:GetBreakLargeNumbers(info)   return configBreakLargeNumbers                                      end
function StoredAnimaCounter:SetCountBankedAnima(info, v) configCountBankedAnima = v;  self.db.profile.countBankedAnima = v;   StoredAnimaCounter:OutputValue() end  -- bugfix: was saving to wrong key
function StoredAnimaCounter:GetCountBankedAnima(info)    return configCountBankedAnima                                       end
function StoredAnimaCounter:SetShowLabel(info, v)        configShowLabel = v;         self.db.profile.showLabel = v;          StoredAnimaCounter:OutputValue() end
function StoredAnimaCounter:GetShowLabel(info)           return configShowLabel                                               end
function StoredAnimaCounter:SetShowIcon(info, v)         configShowIcon = v;          self.db.profile.showIcon = v;           StoredAnimaCounter:OutputValue() end
function StoredAnimaCounter:GetShowIcon(info)            return configShowIcon                                                end
function StoredAnimaCounter:SetTTStoredAnima(info, v)    configTTStoredAnima = v;     self.db.profile.TTStoredAnima = v;      StoredAnimaCounter:OutputValue() end
function StoredAnimaCounter:GetTTStoredAnima(info)       return configTTStoredAnima                                          end
function StoredAnimaCounter:SetTTBaggedAnima(info, v)    configTTBaggedAnima = v;     self.db.profile.TTBaggedAnima = v;      StoredAnimaCounter:OutputValue() end
function StoredAnimaCounter:GetTTBaggedAnima(info)       return configTTBaggedAnima                                          end
function StoredAnimaCounter:SetTTReservoirAnima(info, v) configTTReservoirAnima = v;  self.db.profile.TTReservoirAnima = v;   StoredAnimaCounter:OutputValue() end
function StoredAnimaCounter:GetTTReservoirAnima(info)    return configTTReservoirAnima                                       end
function StoredAnimaCounter:SetTTTotalAnima(info, v)     configTTTotalAnima = v;      self.db.profile.TTTotalAnima = v;       StoredAnimaCounter:OutputValue() end
function StoredAnimaCounter:GetTTTotalAnima(info)        return configTTTotalAnima                                           end
function StoredAnimaCounter:SetTTBankedAnima(info, v)    configTTBankedAnima = v;     self.db.profile.TTBankedAnima = v;      StoredAnimaCounter:OutputValue() end
function StoredAnimaCounter:GetTTBankedAnima(info)       return configTTBankedAnima                                          end
function StoredAnimaCounter:SetCustomFormat(info, v)     configCustomFormat = v;      self.db.profile.customFormat = v;       StoredAnimaCounter:OutputValue() end
function StoredAnimaCounter:GetCustomFormat(info)        return configCustomFormat                                            end

-- ---------------------------------------------------------------------------
-- Anima scanning
-- ---------------------------------------------------------------------------
function StoredAnimaCounter:ScanForStoredAnimaDelayed()
    SAC__wait(10, StoredAnimaCounter.ScanForStoredAnima, time())
end

function StoredAnimaCounter:ScanForStoredAnima()
    vprint("Scanning bags:")
    local total = 0
    for bag = BACKPACK_CONTAINER, NUM_BAG_SLOTS do
        local slots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, slots do
            total = total + StoredAnimaCounter:CountAnima(bag, slot)
        end
    end
    baggedAnima = total
    StoredAnimaCounter:OutputValue()
end

function StoredAnimaCounter:ScanBankForStoredAnima()
    vprint("Scanning bank:")
    local total = 0
    local bankReadable = false

    local slots = C_Container.GetContainerNumSlots(BANK_CONTAINER)
    bankReadable = slots > 0
    for slot = 1, slots do
        total = total + StoredAnimaCounter:CountAnima(BANK_CONTAINER, slot)
    end

    for bag = (NUM_BAG_SLOTS + 1), (NUM_BAG_SLOTS + NUM_BANKBAGSLOTS) do
        local bagSlots = C_Container.GetContainerNumSlots(bag)
        bankReadable = bankReadable and (bagSlots > 0)
        for slot = 1, bagSlots do
            total = total + StoredAnimaCounter:CountAnima(bag, slot)
        end
    end

    if bankReadable then
        bankedAnima = total
        StoredAnimaCounter.db.profile.bankedAnima = total
    else
        bankedAnima = StoredAnimaCounter.db.profile.bankedAnima or 0
    end
    StoredAnimaCounter:OutputValue()
end

function StoredAnimaCounter:OutputValue()
    local stored, pool, sum, bagged, banked

    if configBreakLargeNumbers then
        stored = BreakUpLargeNumbers(StoredAnimaCounter:GetStoredAnima())
        pool   = BreakUpLargeNumbers(GetReservoirAnima())
        sum    = BreakUpLargeNumbers(GetReservoirAnima() + StoredAnimaCounter:GetStoredAnima())
        bagged = BreakUpLargeNumbers(baggedAnima)
        banked = BreakUpLargeNumbers(bankedAnima)
    else
        stored = StoredAnimaCounter:GetStoredAnima()
        pool   = GetReservoirAnima()
        sum    = GetReservoirAnima() + StoredAnimaCounter:GetStoredAnima()
        bagged = baggedAnima
        banked = bankedAnima
    end

    ldbObject.text = ""
    if configShowIcon  then ldbObject.text = string.format(iconString, StoredAnimaCounter:GetAnimaIcon()) end
    if configShowLabel then ldbObject.text = ldbObject.text .. string.format("|cFF2C94FE%s:|r ", ldbObject.label) end

    vprint(">> Total stored anima: " .. stored)
    ldbObject.value = StoredAnimaCounter:GetStoredAnima()

    if     configFormat == Format.stored          then ldbObject.text = ldbObject.text .. string.format("%s", stored)
    elseif configFormat == Format.stored_plus_pool then ldbObject.text = ldbObject.text .. string.format("%s (%s)", stored, pool)
    elseif configFormat == Format.pool_plus_stored then ldbObject.text = ldbObject.text .. string.format("%s (%s)", pool, stored)
    elseif configFormat == Format.sum_only         then ldbObject.text = ldbObject.text .. string.format("%s", sum)
    elseif configFormat == Format.sum_plus_stored  then ldbObject.text = ldbObject.text .. string.format("%s (%s)", sum, stored)
    elseif configFormat == Format.stored_plus_sum  then ldbObject.text = ldbObject.text .. string.format("%s (%s)", stored, sum)
    elseif configFormat == Format.pool_plus_sum    then ldbObject.text = ldbObject.text .. string.format("%s (%s)", pool, sum)
    elseif configFormat == Format.custom_format    then
        local txt = string.gsub(configCustomFormat, "${stored}", stored)
        txt = string.gsub(txt, "${pool}",   pool)
        txt = string.gsub(txt, "${sum}",    sum)
        txt = string.gsub(txt, "${bagged}", bagged)
        txt = string.gsub(txt, "${banked}", banked)
        ldbObject.text = ldbObject.text .. txt
    end

    -- ElvUI length hack
    local len = #ldbObject.text
    if len < 3 then ldbObject.text = " " .. ldbObject.text end
    if len < 2 then ldbObject.text = ldbObject.text .. " " end
    if len < 1 then ldbObject.text = "-" end
end

-- C_Item.GetItemCount replaces the global GetItemCount() which was removed in 12.0
-- C_Item.GetItemInfo replaces the global GetItemInfo() which was removed in 12.0
function StoredAnimaCounter:CountAnima(bag, slot)
    local itemId = C_Container.GetContainerItemID(bag, slot)
    if itemId == nil or not C_Item.IsAnimaItemByID(itemId) then return 0 end

    local itemCount   = C_Item.GetItemCount(itemId)            -- 12.0+: global removed
    local itemQuality = C_Item.GetItemQualityByID(itemId)
    local animaCount

    if itemQuality == 2 and itemId == 183727 then              -- warmode bonus item
        animaCount = (itemCount or 1) * 3
    else
        animaCount = (itemCount or 1) * StoredAnimaCounter:GetAnimaForQuality(itemQuality)
    end

    AnimaPrint(animaCount, itemId)
    return animaCount
end

function StoredAnimaCounter:GetAnimaForQuality(quality)
    if     quality == 4 then return 250   -- Epic
    elseif quality == 3 then return 35    -- Rare
    elseif quality == 2 then return 5     -- Uncommon
    else                     return 0
    end
end

function StoredAnimaCounter:GetStoredAnima()
    if StoredAnimaCounter:GetCountBankedAnima() then
        return baggedAnima + bankedAnima
    else
        return baggedAnima
    end
end

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------
function vprint(val)
    if configIsVerbose then print(val) end
end

-- C_Item.GetItemInfo replaces the global GetItemInfo() removed in 12.0
function AnimaPrint(val, itemId)
    if configIsVerbose then
        local itemLink = select(2, C_Item.GetItemInfo(itemId))
        if itemLink then
            print("Anima present: " .. val .. " on " .. itemLink)
        end
    end
end

function ldbObject:OnTooltipShow()
    local stored, pool, sum, banked, bagged
    if configBreakLargeNumbers then
        stored = BreakUpLargeNumbers(StoredAnimaCounter:GetStoredAnima())
        pool   = BreakUpLargeNumbers(GetReservoirAnima())
        sum    = BreakUpLargeNumbers(GetReservoirAnima() + StoredAnimaCounter:GetStoredAnima())
        banked = BreakUpLargeNumbers(bankedAnima)
        bagged = BreakUpLargeNumbers(baggedAnima)
    else
        stored = StoredAnimaCounter:GetStoredAnima()
        pool   = GetReservoirAnima()
        sum    = GetReservoirAnima() + StoredAnimaCounter:GetStoredAnima()
        banked = bankedAnima
        bagged = baggedAnima
    end

    self:AddLine("|cFF2C94FEStored Anima|r")
    self:AddLine("An overview of anima stored in your bags, but not yet deposited in your covenant's reservoir.", 1.0, 0.82, 0.0, 1)
    self:AddLine("\n")
    self:AddDoubleLine("Bags:",    "|cFFFFFFFF" .. bagged .. "|r")
    if configCountBankedAnima then
        self:AddDoubleLine("Bank:", "|cFFFFFFFF" .. banked .. "|r")
        self:AddDoubleLine("Stored (bag+bank):", "|cFFFFFFFF" .. stored .. "|r")
    end
    self:AddDoubleLine("Reservoir:", "|cFFFFFFFF" .. pool .. "|r")
    self:AddDoubleLine("Total:",     "|cFFFFFFFF" .. sum  .. "|r")
end

function ldbObject:OnClick(button)
    if button == "RightButton" then
        StoredAnimaCounter:OpenConfigPanel()
    elseif button == "LeftButton" then
        -- ToggleCharacter('TokenFrame') was removed in 10.x.
        -- ToggleCollectionsJournal was removed in 12.0.
        -- Best current replacement: open the Currency tab via the character info frame.
        if CharacterFrame and CharacterFrame:IsShown() then
            CharacterFrame:Hide()
        elseif PaperDollFrame then
            ShowUIPanel(CharacterFrame)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Lightweight wait/delay helper
-- Fixed: SetScript("OnUpdate") - lowercase "onUpdate" is silently ignored in 12.0+
-- ---------------------------------------------------------------------------
local waitTable = {}
local waitFrame = nil

function SAC__wait(delay, func, ...)
    if type(delay) ~= "number" or type(func) ~= "function" then return false end
    if waitFrame == nil then
        waitFrame = CreateFrame("Frame", "SACWaitFrame", UIParent)
        waitFrame:SetScript("OnUpdate", function(self, elapse)
            local count = #waitTable
            local i = 1
            while i <= count do
                local rec = tremove(waitTable, i)
                local d   = tremove(rec, 1)
                local f   = tremove(rec, 1)
                local p   = tremove(rec, 1)
                if d > elapse then
                    tinsert(waitTable, i, {d - elapse, f, p})
                    i = i + 1
                else
                    count = count - 1
                    f(unpack(p))
                end
            end
        end)
    end
    tinsert(waitTable, {delay, func, {...}})
    return true
end
