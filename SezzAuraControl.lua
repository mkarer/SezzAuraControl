--[[

	s:UI Aura Window

	Martin Karer / Sezz, 2014
	http://www.sezz.at

--]]

local MAJOR, MINOR = "Sezz:Controls:Aura-0.1", 1;
local APkg = Apollo.GetPackage(MAJOR);
if (APkg and (APkg.nVersion or 0) >= MINOR) then return; end

local AuraControl = APkg and APkg.tPackage or {};
local GeminiGUI, GeminiTimer, log;

-- Lua API
local format, floor, mod, strlen = string.format, math.floor, math.mod, string.len;

-- Wildstar API
local Apollo, XmlDoc = Apollo, XmlDoc;

-----------------------------------------------------------------------------
-- Tooltips
-----------------------------------------------------------------------------

local GenerateBuffTooltipForm = function(luaCaller, wndParent, splSource, tFlags)
	-- Stolen from ToolTips.lua (because it's only available after "ToolTips" is loaded)
	-- TODO: Remove and fetch it when it's finally available...

	-- Initial Bad Data Checks
	if splSource == nil then
		return
	end

	local wndTooltip = wndParent:LoadTooltipForm("ui\\Tooltips\\TooltipsForms.xml", "BuffTooltip_Base", luaCaller)
	wndTooltip:FindChild("NameString"):SetText(splSource:GetName())

    -- Dispellable
	local eSpellClass = splSource:GetClass()
	if eSpellClass == Spell.CodeEnumSpellClass.BuffDispellable or eSpellClass == Spell.CodeEnumSpellClass.DebuffDispellable then
		wndTooltip:FindChild("DispellableString"):SetText(Apollo.GetString("Tooltips_Dispellable"))
	else
		wndTooltip:FindChild("DispellableString"):SetText("")
	end

	-- Calculate width
	local nNameLeft, nNameTop, nNameRight, nNameBottom = wndTooltip:FindChild("NameString"):GetAnchorOffsets()
	local nNameWidth = Apollo.GetTextWidth("CRB_InterfaceLarge", splSource:GetName())
	local nDispelWidth = Apollo.GetTextWidth("CRB_InterfaceMedium", wndTooltip:FindChild("DispellableString"):GetText())
	local nOffset = math.max(0, nNameWidth + nDispelWidth + (nNameLeft * 4) - wndTooltip:FindChild("NameString"):GetWidth())

	-- Resize Tooltip width
	wndTooltip:SetAnchorOffsets(0, 0, wndTooltip:GetWidth() + nOffset, wndTooltip:GetHeight())

	-- General Description
	wndTooltip:FindChild("GeneralDescriptionString"):SetText(wndParent:GetBuffTooltip())
	wndTooltip:FindChild("GeneralDescriptionString"):SetHeightToContentHeight()

	-- Resize tooltip height
	wndTooltip:SetAnchorOffsets(0, 0, wndTooltip:GetWidth(), wndTooltip:GetHeight() + wndTooltip:FindChild("GeneralDescriptionString"):GetHeight())

	return wndTooltip
end

local wndTooltipContainer;
local tTooltipContainer = {
	__XmlNode = "Forms",
	{ -- Form
		__XmlNode="Form", Class="BuffWindow",
		LAnchorPoint="0", LAnchorOffset="0", TAnchorPoint="0", TAnchorOffset="0", RAnchorPoint="0", RAnchorOffset="0", BAnchorPoint="0", BAnchorOffset="0",
		RelativeToClient="1", Template="Default",
		Font="Default", Text="", TooltipType="OnCursor",
		BGColor="00000000", TextColor="UI_WindowTextDefault",
		Border="0", Picture="0", SwallowMouseClicks="0", Moveable="0", Escapable="0", IgnoreMouse="1",
		Overlapped="1", TooltipColor="", Sprite="", Tooltip="",
		Name="SezzAuraTooltipContainer", Visible="0",
		BuffDispellable="1", BuffNonDispellable="1", DebuffDispellable="1", DebuffNonDispellable="1", Hero="0", PulseWhenExpiring="0", DoNotShowTimeRemaining="1", ShowMS="0",
	},
};

local function GetTooltipText(tAura)
	if (wndTooltipContainer and wndTooltipContainer:IsValid()) then
		wndTooltipContainer:Destroy();
	end

	tTooltipContainer[1].BuffIndex = tAura.nIndex;
	tTooltipContainer[1].BeneficialBuffs = tAura.bIsDebuff and "0" or "1";
	tTooltipContainer[1].HarmfulBuffs = tAura.bIsDebuff and "1" or "0";

	wndTooltipContainer = Apollo.LoadForm(XmlDoc.CreateFromTable(tTooltipContainer), "SezzAuraTooltipContainer", nil, self);
	wndTooltipContainer:SetUnit(tAura.unit.__proto__ or tAura.unit);

	local strTooltip = wndTooltipContainer:GetBuffTooltip();
	return strlen(strTooltip) > 0 and strTooltip or nil;
end

local GetBuffTooltip = function(self)
	return self.strBuffTooltip;
end

-----------------------------------------------------------------------------
-- Window Control Metatable
-----------------------------------------------------------------------------

local tUserDataWrapper = {};
local tUserDataMetatable = {};

function tUserDataMetatable:__index(strKey)
	local proto = rawget(self, "__proto__");
	local field = proto and proto[strKey];

	if (type(field) ~= "function") then
		return field;
	else
		return function(obj, ...)
			if (obj == self) then
				return field(proto, ...);
			else
				return field(obj, ...);
			end
		end
	end
end

function tUserDataWrapper:New(o)
	return setmetatable({__proto__ = o}, tUserDataMetatable);
end

-----------------------------------------------------------------------------

function AuraControl:Enable()
	-- Create/Enable Timer
	if (not self.tmrUpdater and not self.bAura) then
		if (self.wndOverlay and self.nDuration < 50000) then
			Apollo.RegisterEventHandler("NextFrame", "UpdateTimeLeft", self);
		else
			self.tmrUpdater = self:ScheduleRepeatingTimer("UpdateTimeLeft", 0.1);
		end
	end

	return self;
end

function AuraControl:Destroy()
	-- We can't reuse windows (right?), so we have to self-destruct ;)
	Apollo.RemoveEventHandler("NextFrame", self);
	self:CancelTimer(self.tmrUpdater, true);
	self.wndIcon:RemoveEventHandler("MouseButtonUp", self);
	self.wndMain:Destroy();
	self = nil;
end

local function TimeBreakDown(nSeconds)
    local nDays = floor(nSeconds / (60 * 60 * 24));
    local nHours = floor((nSeconds - (nDays * (60 * 60 * 24))) / (60 * 60));
    local nMinutes = floor((nSeconds - (nDays * (60 * 60 * 24)) - (nHours * (60 * 60))) / 60);
    local nSeconds = mod(nSeconds, 60);

    return nDays, nHours, nMinutes, nSeconds;
end

function AuraControl:UpdateDuration(fDuration)
	-- (float) fDuration: time left in seconds from unit:GetBuffs(), we need to convert this to milliseconds
	if (not self.bAura) then
		local nDuration = floor(fDuration * 1000);
		local nEndTime = GameLib.GetTickCount() + nDuration;

		if (not self.nEndTime or self.nEndTime ~= nEndTime) then
--			if (self.nEndTime) then
--				log:debug("%s endtimer changed from %d to %d", self.tAura.splEffect:GetName(), self.nEndTime or 0, nEndTime);
--			end

			self.nEndTime = nEndTime;
			self.nDuration = nDuration;
			self:UpdateTimeLeft();
		end
	end
end

function AuraControl:UpdateTimeLeft()
	local nNow = GameLib.GetTickCount();
	local nTimeLeftMs = self.nEndTime - nNow;
	local nTimeLeft = floor(nTimeLeftMs / 1000);

	if (self.bAura or nTimeLeft < 0) then -- nTimeLeft < 0 = Carbine's Bug!
		self.wndDuration:SetText("");

		if (self.wndOverlay) then
			self.wndOverlay:SetProgress(0);
		end
	else
		local nDays, nHours, nMinutes, nSeconds = TimeBreakDown(nTimeLeft);

		if (nTimeLeft < 3600) then
			-- Less than 1h, [MM:SS]
			self.wndDuration:SetText(format("%02d:%02d", nMinutes, nSeconds));
		elseif (nTimeLeft >= 36000) then
			-- 10 hours or more, [HHh]
			self.wndDuration:SetText(format("%1dh", nHours));
		else
			-- from 1 to 9 hours, [HHh:MM]
			self.wndDuration:SetText(format("%1dh:%02d", nHours, nMinutes));
		end

		if (self.wndOverlay and self.nDuration and self.nDuration > 0) then
			local fProgress = floor(nTimeLeftMs / (self.nDuration / 100) + 0.01);
			self.wndOverlay:SetProgress(fProgress);
		end
	end
end

function AuraControl:UpdateCount(nCount)
	self.nCount = nCount;
	self.wndCount:SetText(nCount);
	self.wndCount:Show(nCount > 1, true);
end

function AuraControl:UpdateTooltip()
	if (not self.wndMain.strBuffTooltip) then
		self.wndMain.strBuffTooltip = GetTooltipText(self.tAura) or self.tAura.splEffect:GetFlavor();
	end

	if (not self.wndMain.GetBuffTooltip) then
		self.wndMain.GetBuffTooltip = GetBuffTooltip;
		GenerateBuffTooltipForm(self.wndIcon, self.wndMain, self.tAura.splEffect);
	end
end

function AuraControl:CancelAura(wndHandler, wndControl, eMouseButton)
	if (eMouseButton == GameLib.CodeEnumInputMouse.Right) then
		log:debug("Cancel Aura: %s (ID: %d)", self.tAura.splEffect:GetName(), self.tAura.splEffect:GetId());
	end
end

function AuraControl:Update(tAura)
	self.tAuraData.nIndex = tAura.nIndex;
	self:UpdateDuration(tAura.fTimeRemaining);
	self:UpdateCount(tAura.nCount);
end

-----------------------------------------------------------------------------
-- Constructor
-----------------------------------------------------------------------------

function AuraControl:New(wndParent, tAuraData, tWindowPrototype)
	-- tWindowPrototype: GeminiGUI window prototype
	self = setmetatable({}, { __index = AuraControl });

	-- Initialize Properties
	self.tAura = tAuraData;

	-- Create Aura Window
	local wndMain = tUserDataWrapper:New(GeminiGUI:Create(tWindowPrototype):GetInstance(self, wndParent));
	self.wndMain = wndMain;

	-- Overlay
	local wndOverlay = wndMain:FindChild("IconOverlay");
	if (wndOverlay) then
		wndOverlay:SetProgress(100);
		wndOverlay:SetMax(100);
		self.wndOverlay = wndOverlay;
	end

	-- Update Icon Sprite
	local wndIcon = wndMain:FindChild("Icon");
	self.wndIcon = wndIcon;
	wndIcon:SetSprite(tAuraData.splEffect:GetIcon());

	-- Update Duration
	self.bAura = (tAuraData.fTimeRemaining == 0);
	self.wndDuration = wndMain:FindChild("Duration");
	self:UpdateDuration(tAuraData.fTimeRemaining);

	-- Update Stack Counter
	self.wndCount = wndMain:FindChild("Count");
	self:UpdateCount(tAuraData.nCount);

	-- Create Tooltip
	self.wndIcon:AddEventHandler("MouseEnter", "UpdateTooltip", self);

	-- Add Click Event (Cancel Aura)
	self.wndIcon:AddEventHandler("MouseButtonUp", "CancelAura", self);

	-- Return
	return self;
end

-----------------------------------------------------------------------------
-- Apollo Registration
-----------------------------------------------------------------------------

function AuraControl:OnLoad()
	local GeminiLogging = Apollo.GetPackage("Gemini:Logging-1.2") and Apollo.GetAddon("GeminiConsole") and Apollo.GetPackage("Gemini:Logging-1.2").tPackage;
	if (GeminiLogging) then
		log = GeminiLogging:GetLogger({
			level = GeminiLogging.DEBUG,
			pattern = "%d %n %c %l - %m",
			appender ="GeminiConsole"
		});
	else
		log = setmetatable({}, { __index = function() return function(self, ...) local args = #{...}; if (args > 1) then Print(string.format(...)); elseif (args == 1) then Print(tostring(...)); end; end; end });
	end

	GeminiGUI = Apollo.GetPackage("Gemini:GUI-1.0").tPackage;
	Apollo.GetPackage("Gemini:Timer-1.0").tPackage:Embed(self);
end

function AuraControl:OnDependencyError(strDep, strError)
	return false;
end

-----------------------------------------------------------------------------

Apollo.RegisterPackage(AuraControl, MAJOR, MINOR, { "Gemini:GUI-1.0", "Gemini:Timer-1.0" });
