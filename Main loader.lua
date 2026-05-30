--[[

	Zenith Interface Suite
	by zurai02

	Forked and modernized from Rayfield Interface Suite (Sirius)
	Redesigned APIs · Cleaner internals · Enhanced security · Modern theming

]]

------------------------------------------------------------------------
-- Debug bootstrap
------------------------------------------------------------------------
if debugX then
	warn("[Zenith] Initialising...")
end

------------------------------------------------------------------------
-- Service helper
------------------------------------------------------------------------
local function getService(name: string)
	local svc = game:GetService(name)
	return if cloneref then cloneref(svc) else svc
end

-- Services
local UserInputService = getService("UserInputService")
local TweenService     = getService("TweenService")
local Players          = getService("Players")
local CoreGui          = getService("CoreGui")
local HttpService      = getService("HttpService")
local RunService       = getService("RunService")

------------------------------------------------------------------------
-- Environment detection
------------------------------------------------------------------------
local IS_STUDIO: boolean = RunService:IsStudio()

------------------------------------------------------------------------
-- Remote loader (with timeout + cancellation)
------------------------------------------------------------------------

--- Fetches a Lua script from `url`, executes it, and returns its result.
--- Cancels and returns `nil` if the request takes longer than `timeout` seconds.
---@param url     string   Remote URL to fetch.
---@param timeout number?  Max wait time in seconds (default 5).
---@return any
local function loadWithTimeout(url: string, timeout: number?): ...any
	assert(type(url) == "string", "[Zenith] loadWithTimeout: expected string, got " .. type(url))

	timeout = timeout or 5

	local completed = false
	local ok, result = false, nil

	local requestThread = task.spawn(function()
		local fetchOk, fetchResult = pcall(game.HttpGet, game, url)

		if not fetchOk or #fetchResult == 0 then
			ok, result = false, (fetchOk and "Empty response" or fetchResult)
			completed  = true
			return
		end

		local execOk, execResult = pcall(function()
			return (loadstring(fetchResult) :: any)()
		end)
		ok, result = execOk, execResult
		completed   = true
	end)

	local timeoutThread = task.delay(timeout, function()
		if not completed then
			warn(("[Zenith] Request timed out after %ds: %s"):format(timeout, url))
			task.cancel(requestThread)
			result    = "Request timed out"
			completed = true
		end
	end)

	while not completed do
		task.wait()
	end

	if coroutine.status(timeoutThread) ~= "dead" then
		task.cancel(timeoutThread)
	end

	if not ok then
		warn(("[Zenith] Failed to load '%s': %s"):format(url, tostring(result)))
	end

	return if ok then result else nil
end

------------------------------------------------------------------------
-- Global environment flags
------------------------------------------------------------------------
local _getgenv        = rawget(_G, "getgenv")
local requestsEnabled = true   -- inverted flag for clarity
local customAssetId   = nil
local secureMode      = false

if _getgenv then
	local function readGenv(key)
		local ok, val = pcall(function() return _getgenv()[key] end)
		return if ok then val else nil
	end

	if readGenv("DISABLE_ZENITH_REQUESTS") or readGenv("DISABLE_RAYFIELD_REQUESTS") then
		requestsEnabled = false
	end

	local assetId = readGenv("ZENITH_ASSET_ID") or readGenv("RAYFIELD_ASSET_ID")
	if type(assetId) == "number" then
		customAssetId = assetId
	end

	if readGenv("ZENITH_SECURE") or readGenv("RAYFIELD_SECURE") then
		secureMode = true
	end
end

-- Silence all output in secure mode
if secureMode then
	local _error  = error
	local _assert = assert
	warn   = function(...) end
	print  = function(...) end
	error  = function(_, level) _error("", level) end
	assert = function(v, ...) return _assert(v) end
end

------------------------------------------------------------------------
-- Safe call helper
------------------------------------------------------------------------

--- Calls `func(...)` in a protected context. Returns the result on
--- success, or `false` on failure (with a warning).
local function callSafely(func, ...)
	if not func then return end
	local ok, res = pcall(func, ...)
	if not ok then
		warn("[Zenith] Protected call failed: " .. tostring(res))
		return false
	end
	return res
end

--- Ensures a folder exists, creating it if it doesn't.
local function ensureFolder(path: string)
	if isfolder and not callSafely(isfolder, path) then
		callSafely(makefolder, path)
	end
end

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
local BUILD          = "1.0.0"
local SUITE_NAME     = "Zenith"
local FOLDER_ROOT    = "Zenith"
local FOLDER_CONFIG  = FOLDER_ROOT .. "/Configurations"
local CONFIG_EXT     = ".znth"

------------------------------------------------------------------------
-- Settings schema
------------------------------------------------------------------------
local settingsSchema = {
	General = {
		openKeybind = { Type = "bind",   Value = "K",    Name = "Open / Close Keybind" },
	},
	System = {
		analytics   = { Type = "toggle", Value = true,   Name = "Anonymous Analytics"  },
	},
}

-- Overrides supplied by the developer (highest priority, not persisted)
local overriddenSettings: { [string]: any } = {}

--- Override a setting programmatically. Overrides are not written to disk.
---@param category string  Top-level settings category (e.g. "General").
---@param key      string  Setting key (e.g. "openKeybind").
---@param value    any     New value.
local function overrideSetting(category: string, key: string, value: any)
	overriddenSettings[category .. "." .. key] = value
end

--- Read a setting, respecting override priority.
---@param category string
---@param key      string
---@return any
local function getSetting(category: string, key: string): any
	local override = overriddenSettings[category .. "." .. key]
	if override ~= nil then return override end

	local cat = settingsSchema[category]
	if cat and cat[key] then
		return cat[key].Value
	end
end

-- Propagate request-disabled flag to analytics setting
if not requestsEnabled then
	overrideSetting("System", "analytics", false)
end

------------------------------------------------------------------------
-- Settings persistence
------------------------------------------------------------------------
local settingsCreated     = false
local settingsInitialised = false

local function loadSettings()
	local raw = nil

	local ok, err = pcall(function()
		if callSafely(isfolder, FOLDER_ROOT) then
			local path = FOLDER_ROOT .. "/settings" .. CONFIG_EXT
			if callSafely(isfile, path) then
				raw = callSafely(readfile, path)
			end
		end

		-- Studio override for fast iteration
		if IS_STUDIO then
			raw = [[{"General":{"openKeybind":{"Value":"K","Type":"bind","Name":"Open / Close Keybind"}},"System":{"analytics":{"Value":false,"Type":"toggle","Name":"Anonymous Analytics"}}}]]
		end

		local parsed = {}
		if raw then
			local decOk, decoded = pcall(function()
				return HttpService:JSONDecode(raw)
			end)
			parsed = if decOk then decoded else {}
		end

		if not settingsCreated then return end

		if next(parsed) then
			for catName, category in pairs(settingsSchema) do
				if parsed[catName] then
					for keyName, setting in pairs(category) do
						if parsed[catName][keyName] then
							setting.Value = parsed[catName][keyName].Value
							setting.Element:Set(getSetting(catName, keyName))
						end
					end
				end
			end
		else
			-- Apply only developer overrides when no saved settings exist
			for compound, value in overriddenSettings do
				local parts = string.split(compound, ".")
				assert(#parts == 2, "[Zenith] Malformed override key: " .. compound)
				local cat, key = parts[1], parts[2]
				if settingsSchema[cat] and settingsSchema[cat][key] then
					settingsSchema[cat][key].Element:Set(value)
				end
			end
		end

		settingsInitialised = true
	end)

	if not ok then
		if writefile then
			warn("[Zenith] Could not access settings storage: " .. tostring(err))
		end
	end
end

if debugX then warn("[Zenith] Loading settings...") end
loadSettings()
if debugX then warn("[Zenith] Settings loaded.") end

------------------------------------------------------------------------
-- Analytics (optional, anonymous)
------------------------------------------------------------------------
local ANALYTICS_ENDPOINT = "https://zenith-collect.zurai02.workers.dev"
local ANALYTICS_TOKEN    = "" -- Set your own token here

local reporter = nil

if requestsEnabled and not IS_STUDIO and ANALYTICS_TOKEN ~= "" then
	local fetchOk, fetchResult = pcall(game.HttpGet, game,
		"https://raw.githubusercontent.com/zurai02/Zenith/main/reporter.lua")

	if fetchOk and #fetchResult > 0 then
		local execOk, Analytics = pcall(function()
			return (loadstring(fetchResult) :: any)()
		end)

		if execOk and Analytics then
			pcall(function()
				reporter = Analytics.new({
					url          = ANALYTICS_ENDPOINT,
					token        = ANALYTICS_TOKEN,
					product_name = SUITE_NAME,
					category     = "UILibrary",
				})
			end)
		end
	end
end

------------------------------------------------------------------------
-- Request function (executor-agnostic)
------------------------------------------------------------------------
local requestFunc =
	(syn          and syn.request)          or
	(fluxus       and fluxus.request)       or
	(http         and http.request)         or
	http_request                            or
	request

------------------------------------------------------------------------
-- Prompt / consent module
------------------------------------------------------------------------
local prompt = IS_STUDIO
	and require(script.Parent.prompt)
	or  loadWithTimeout("https://raw.githubusercontent.com/zurai02/Zenith/main/prompt.lua")

if not prompt then
	warn("[Zenith] Prompt module unavailable — using no-op fallback.")
	prompt = { create = function() end }
end

------------------------------------------------------------------------
-- Secure notification helper
------------------------------------------------------------------------
local _secureWarningsShown: { [string]: boolean } = {}

local function secureNotify(tag: string, title: string, body: string)
	if _secureWarningsShown[tag] then return end
	_secureWarningsShown[tag] = true

	task.spawn(function()
		while not (ZenithLibrary and ZenithLibrary.Notify) do
			task.wait(0.5)
		end
		ZenithLibrary:Notify({ Title = title, Content = body, Duration = 8 })
	end)
end

------------------------------------------------------------------------
-- Theme definitions
------------------------------------------------------------------------

--- All themes follow the same key schema so the UI layer can swap them
--- at runtime without any conditional logic.
local Themes = {

	-- ── Midnight (default dark) ────────────────────────────────────────
	Midnight = {
		TextColor                     = Color3.fromRGB(235, 235, 235),

		Background                    = Color3.fromRGB(18, 18, 22),
		Topbar                        = Color3.fromRGB(26, 26, 32),
		Shadow                        = Color3.fromRGB(10, 10, 14),

		NotificationBackground        = Color3.fromRGB(22, 22, 28),
		NotificationActionsBackground = Color3.fromRGB(225, 225, 235),

		TabBackground                 = Color3.fromRGB(32, 32, 40),
		TabStroke                     = Color3.fromRGB(44, 44, 54),
		TabBackgroundSelected         = Color3.fromRGB(100, 100, 255),
		TabTextColor                  = Color3.fromRGB(180, 180, 200),
		SelectedTabTextColor          = Color3.fromRGB(255, 255, 255),

		ElementBackground             = Color3.fromRGB(28, 28, 35),
		ElementBackgroundHover        = Color3.fromRGB(36, 36, 46),
		SecondaryElementBackground    = Color3.fromRGB(22, 22, 28),
		ElementStroke                 = Color3.fromRGB(50, 50, 65),
		SecondaryElementStroke        = Color3.fromRGB(40, 40, 52),

		SliderBackground              = Color3.fromRGB(60, 60, 200),
		SliderProgress                = Color3.fromRGB(100, 100, 255),
		SliderStroke                  = Color3.fromRGB(120, 120, 255),

		ToggleBackground              = Color3.fromRGB(28, 28, 38),
		ToggleEnabled                 = Color3.fromRGB(80, 80, 240),
		ToggleDisabled                = Color3.fromRGB(70, 70, 90),
		ToggleEnabledStroke           = Color3.fromRGB(100, 100, 255),
		ToggleDisabledStroke          = Color3.fromRGB(90, 90, 110),
		ToggleEnabledOuterStroke      = Color3.fromRGB(60, 60, 160),
		ToggleDisabledOuterStroke     = Color3.fromRGB(50, 50, 65),

		DropdownSelected              = Color3.fromRGB(36, 36, 50),
		DropdownUnselected            = Color3.fromRGB(24, 24, 34),

		InputBackground               = Color3.fromRGB(26, 26, 34),
		InputStroke                   = Color3.fromRGB(55, 55, 75),
		PlaceholderColor              = Color3.fromRGB(120, 120, 150),
	},

	-- ── Arctic (clean light) ──────────────────────────────────────────
	Arctic = {
		TextColor                     = Color3.fromRGB(30, 35, 45),

		Background                    = Color3.fromRGB(245, 247, 252),
		Topbar                        = Color3.fromRGB(230, 234, 244),
		Shadow                        = Color3.fromRGB(190, 196, 215),

		NotificationBackground        = Color3.fromRGB(252, 253, 255),
		NotificationActionsBackground = Color3.fromRGB(235, 238, 248),

		TabBackground                 = Color3.fromRGB(220, 226, 240),
		TabStroke                     = Color3.fromRGB(200, 208, 228),
		TabBackgroundSelected         = Color3.fromRGB(255, 255, 255),
		TabTextColor                  = Color3.fromRGB(80, 90, 115),
		SelectedTabTextColor          = Color3.fromRGB(20, 25, 40),

		ElementBackground             = Color3.fromRGB(238, 241, 250),
		ElementBackgroundHover        = Color3.fromRGB(225, 230, 245),
		SecondaryElementBackground    = Color3.fromRGB(235, 238, 248),
		ElementStroke                 = Color3.fromRGB(200, 208, 228),
		SecondaryElementStroke        = Color3.fromRGB(210, 216, 232),

		SliderBackground              = Color3.fromRGB(140, 170, 220),
		SliderProgress                = Color3.fromRGB(80, 130, 210),
		SliderStroke                  = Color3.fromRGB(100, 150, 220),

		ToggleBackground              = Color3.fromRGB(215, 222, 238),
		ToggleEnabled                 = Color3.fromRGB(50, 120, 210),
		ToggleDisabled                = Color3.fromRGB(160, 168, 188),
		ToggleEnabledStroke           = Color3.fromRGB(70, 140, 230),
		ToggleDisabledStroke          = Color3.fromRGB(180, 186, 204),
		ToggleEnabledOuterStroke      = Color3.fromRGB(100, 140, 200),
		ToggleDisabledOuterStroke     = Color3.fromRGB(185, 192, 210),

		DropdownSelected              = Color3.fromRGB(228, 232, 246),
		DropdownUnselected            = Color3.fromRGB(218, 224, 240),

		InputBackground               = Color3.fromRGB(238, 241, 250),
		InputStroke                   = Color3.fromRGB(190, 198, 220),
		PlaceholderColor              = Color3.fromRGB(140, 148, 170),
	},

	-- ── Ember (warm dark) ─────────────────────────────────────────────
	Ember = {
		TextColor                     = Color3.fromRGB(255, 240, 220),

		Background                    = Color3.fromRGB(22, 14, 10),
		Topbar                        = Color3.fromRGB(32, 20, 14),
		Shadow                        = Color3.fromRGB(12, 8, 5),

		NotificationBackground        = Color3.fromRGB(28, 18, 12),
		NotificationActionsBackground = Color3.fromRGB(245, 225, 205),

		TabBackground                 = Color3.fromRGB(50, 32, 22),
		TabStroke                     = Color3.fromRGB(68, 44, 30),
		TabBackgroundSelected         = Color3.fromRGB(230, 140, 60),
		TabTextColor                  = Color3.fromRGB(220, 190, 160),
		SelectedTabTextColor          = Color3.fromRGB(30, 15, 5),

		ElementBackground             = Color3.fromRGB(36, 24, 16),
		ElementBackgroundHover        = Color3.fromRGB(48, 32, 22),
		SecondaryElementBackground    = Color3.fromRGB(28, 18, 12),
		ElementStroke                 = Color3.fromRGB(72, 48, 34),
		SecondaryElementStroke        = Color3.fromRGB(62, 40, 28),

		SliderBackground              = Color3.fromRGB(180, 90, 30),
		SliderProgress                = Color3.fromRGB(230, 120, 50),
		SliderStroke                  = Color3.fromRGB(255, 145, 65),

		ToggleBackground              = Color3.fromRGB(36, 24, 16),
		ToggleEnabled                 = Color3.fromRGB(220, 110, 40),
		ToggleDisabled                = Color3.fromRGB(90, 60, 45),
		ToggleEnabledStroke           = Color3.fromRGB(255, 140, 60),
		ToggleDisabledStroke          = Color3.fromRGB(110, 75, 58),
		ToggleEnabledOuterStroke      = Color3.fromRGB(180, 90, 40),
		ToggleDisabledOuterStroke     = Color3.fromRGB(70, 50, 38),

		DropdownSelected              = Color3.fromRGB(50, 34, 24),
		DropdownUnselected            = Color3.fromRGB(34, 22, 15),

		InputBackground               = Color3.fromRGB(36, 24, 16),
		InputStroke                   = Color3.fromRGB(80, 52, 36),
		PlaceholderColor              = Color3.fromRGB(170, 130, 100),
	},

	-- ── Void (OLED black + violet accent) ────────────────────────────
	Void = {
		TextColor                     = Color3.fromRGB(230, 220, 255),

		Background                    = Color3.fromRGB(4, 4, 8),
		Topbar                        = Color3.fromRGB(10, 8, 16),
		Shadow                        = Color3.fromRGB(2, 2, 4),

		NotificationBackground        = Color3.fromRGB(8, 6, 14),
		NotificationActionsBackground = Color3.fromRGB(230, 220, 255),

		TabBackground                 = Color3.fromRGB(22, 16, 36),
		TabStroke                     = Color3.fromRGB(36, 26, 56),
		TabBackgroundSelected         = Color3.fromRGB(140, 80, 255),
		TabTextColor                  = Color3.fromRGB(180, 160, 220),
		SelectedTabTextColor          = Color3.fromRGB(255, 255, 255),

		ElementBackground             = Color3.fromRGB(14, 10, 24),
		ElementBackgroundHover        = Color3.fromRGB(22, 16, 36),
		SecondaryElementBackground    = Color3.fromRGB(10, 8, 18),
		ElementStroke                 = Color3.fromRGB(44, 30, 70),
		SecondaryElementStroke        = Color3.fromRGB(36, 24, 58),

		SliderBackground              = Color3.fromRGB(80, 40, 180),
		SliderProgress                = Color3.fromRGB(120, 70, 240),
		SliderStroke                  = Color3.fromRGB(150, 90, 255),

		ToggleBackground              = Color3.fromRGB(14, 10, 24),
		ToggleEnabled                 = Color3.fromRGB(120, 60, 240),
		ToggleDisabled                = Color3.fromRGB(55, 40, 85),
		ToggleEnabledStroke           = Color3.fromRGB(150, 90, 255),
		ToggleDisabledStroke          = Color3.fromRGB(75, 55, 110),
		ToggleEnabledOuterStroke      = Color3.fromRGB(90, 50, 180),
		ToggleDisabledOuterStroke     = Color3.fromRGB(40, 28, 65),

		DropdownSelected              = Color3.fromRGB(22, 16, 38),
		DropdownUnselected            = Color3.fromRGB(12, 8, 22),

		InputBackground               = Color3.fromRGB(14, 10, 24),
		InputStroke                   = Color3.fromRGB(55, 36, 100),
		PlaceholderColor              = Color3.fromRGB(130, 100, 180),
	},

	-- ── Jade (muted teal dark) ────────────────────────────────────────
	Jade = {
		TextColor                     = Color3.fromRGB(210, 235, 230),

		Background                    = Color3.fromRGB(10, 22, 20),
		Topbar                        = Color3.fromRGB(16, 32, 28),
		Shadow                        = Color3.fromRGB(6, 14, 12),

		NotificationBackground        = Color3.fromRGB(14, 28, 24),
		NotificationActionsBackground = Color3.fromRGB(210, 235, 230),

		TabBackground                 = Color3.fromRGB(28, 55, 48),
		TabStroke                     = Color3.fromRGB(38, 70, 62),
		TabBackgroundSelected         = Color3.fromRGB(60, 180, 150),
		TabTextColor          
