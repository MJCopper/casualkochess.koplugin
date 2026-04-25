-- enginewidget.lua
-- Sub-dialog for computer engine settings: Skill, Depth, Think Time, Blunder Chance.
-- Opened from SettingsWidget via a "Computer Engine" button.
-- Has its own Save, Close, and Reset Defaults buttons.

local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geometry = require("ui/geometry")
local Size = require("ui/size")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputDialog = require("ui/widget/inputdialog")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ButtonWidget = require("ui/widget/button")
local ButtonProgressWidget = require("ui/widget/buttonprogresswidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ConfirmBox = require("ui/widget/confirmbox")

local _ = require("gettext")

local BACKGROUND_COLOR = Blitbuffer.COLOR_WHITE

-- ---------------------------------------------------------------------------
-- ELO lookup tables (mirrors settingswidget.lua)
-- ---------------------------------------------------------------------------
local SKILL_ELO = {
    [0]  = {1300,1300,1300,1300,1300,1300,1300,1300,1300,1300},
    [1]  = {1350,1360,1370,1375,1380,1385,1390,1395,1398,1400},
    [2]  = {1400,1415,1425,1435,1440,1445,1450,1455,1458,1460},
    [3]  = {1450,1465,1475,1485,1492,1496,1500,1504,1507,1510},
    [4]  = {1500,1518,1530,1540,1548,1554,1558,1562,1566,1570},
    [5]  = {1550,1570,1585,1596,1605,1612,1618,1622,1626,1630},
    [6]  = {1600,1623,1640,1653,1663,1671,1678,1683,1688,1692},
    [7]  = {1650,1676,1695,1710,1722,1731,1739,1745,1750,1755},
    [8]  = {1700,1730,1752,1769,1782,1793,1801,1808,1814,1820},
    [9]  = {1750,1783,1808,1827,1842,1854,1864,1872,1879,1885},
    [10] = {1800,1838,1865,1887,1904,1918,1929,1938,1946,1953},
    [11] = {1900,1942,1973,1997,2016,2031,2044,2054,2063,2071},
    [12] = {2000,2046,2080,2107,2128,2145,2159,2171,2181,2190},
    [13] = {2100,2150,2187,2216,2239,2258,2273,2286,2297,2307},
    [14] = {2200,2254,2295,2326,2351,2372,2389,2403,2415,2425},
    [15] = {2300,2358,2401,2435,2462,2484,2502,2517,2530,2541},
    [16] = {2350,2410,2455,2490,2518,2541,2559,2575,2588,2600},
    [17] = {2400,2462,2508,2545,2574,2597,2617,2633,2647,2659},
    [18] = {2450,2514,2562,2600,2630,2655,2675,2692,2706,2719},
    [19] = {2500,2566,2615,2655,2686,2712,2733,2750,2765,2778},
    [20] = {2550,2618,2668,2708,2740,2766,2787,2804,2819,2832},
}
local DEPTH_MULTIPLIER = { [1]=0.55, [2]=0.75, [3]=0.88, [0]=1.00 }

local function computeElo(skill, depth, movetime, blunder_chance)
    local t = math.max(1, math.min(10, movetime))
    local row = SKILL_ELO[skill]
    local base_elo = (row and row[t]) or 1300
    local dm = DEPTH_MULTIPLIER[depth or 0] or 1.00
    local bc = blunder_chance or 0
    return math.max(200, math.floor(base_elo * dm * (1.0 - bc)))
end

-- ---------------------------------------------------------------------------
-- EngineWidget
-- ---------------------------------------------------------------------------
local EngineWidget = {}
EngineWidget.__index = EngineWidget
EngineWidget.computeElo = computeElo

-- opts:
--   engine        = UCI engine instance
--   parent        = Kochess main instance (for applying settings)
--   initial       = table with {skill_level, engine_depth, engine_movetime, blunder_chance}
--   onSave(changes) = called when user saves; receives updated values
function EngineWidget:new(opts)
    assert(opts.engine,  "engine is required")
    assert(opts.parent,  "parent is required")
    assert(opts.onSave,  "onSave callback is required")

    local o = setmetatable({
        engine  = opts.engine,
        parent  = opts.parent,
        onSave  = opts.onSave,
        dialog  = nil,
        changes = {},
    }, EngineWidget)

    local init = opts.initial or {}
    o.changes = {
        skill_level     = init.skill_level     or 0,
        engine_depth    = init.engine_depth    or 2,
        engine_movetime = init.engine_movetime or 1,
        blunder_chance  = init.blunder_chance  or 0.20,
    }

    return o
end

-- ---------------------------------------------------------------------------
-- show()
-- ---------------------------------------------------------------------------
function EngineWidget:show()
    local dlg = InputDialog:new{
        title           = _("Computer Engine"),
        save_callback   = function() self:saveAndClose() end,
        dismiss_callback = function() UIManager:close(self.dialog) end,
    }
    dlg.element_width = math.floor(dlg.width * 0.8)
    self.dialog = dlg

    self:buildSkillGroup()
    self:buildDepthGroup()
    self:buildMoveTimeGroup()
    self:buildBlunderGroup()
    self:assembleContent()

    dlg:refocusWidget()
    UIManager:show(dlg)
end

-- ---------------------------------------------------------------------------
-- ELO label helper
-- ---------------------------------------------------------------------------
function EngineWidget:eloLabel()
    local elo = computeElo(
        tonumber(self.changes.skill_level)     or 0,
        tonumber(self.changes.engine_depth)    or 0,
        tonumber(self.changes.engine_movetime) or 1,
        tonumber(self.changes.blunder_chance)  or 0
    )
    return _("Estimated ELO") .. ": ~" .. tostring(elo)
end

function EngineWidget:refreshEloLabel()
    if self.eloLabelWidget then
        self.eloLabelWidget:setText(self:eloLabel())
        UIManager:setDirty(self.parent, "ui")
    end
end

-- ---------------------------------------------------------------------------
-- markDirty
-- ---------------------------------------------------------------------------
function EngineWidget:markDirty()
    if self.dialog._buttons_edit_callback then
        self.dialog:_buttons_edit_callback(true)
    end
    UIManager:setDirty(self.parent, "ui")
end

-- ---------------------------------------------------------------------------
-- SKILL GROUP
-- ---------------------------------------------------------------------------
function EngineWidget:buildSkillGroup()
    local w = self.dialog.element_width
    local min_s, max_s = 0, 20
    local function skillToPos(s) return (tonumber(s) or 0) + 1 end
    local function posToSkill(p) return p - 1 end

    self.skillProgress = ButtonProgressWidget:new{
        width       = w,
        num_buttons = max_s - min_s + 1,
        position    = skillToPos(self.changes.skill_level),
        fine_tune   = true,
        callback    = function(pos)
            local cur = skillToPos(self.changes.skill_level)
            if pos == "+" then cur = math.min(max_s + 1, cur + 1)
            elseif pos == "-" then cur = math.max(1, cur - 1)
            else cur = pos end
            self.changes.skill_level = posToSkill(cur)
            self.skillProgress.position = cur
            if self.skillLabelWidget then self.skillLabelWidget:setText(self:skillLabelText()) end
            self:refreshEloLabel()
            self:markDirty()
            UIManager:setDirty(self.parent, "ui")
        end,
    }
    local function skillLabel() return self:skillLabelText() end
    self.skillLabelWidget = TextWidget:new{
        text = skillLabel(),
        face = Font:getFace("cfont", 22),
    }
    self.skillGroup = VerticalGroup:new{
        width = w,
        self.skillLabelWidget,
        VerticalSpan:new{ width = Size.padding.small },
        self.skillProgress,
    }
end

function EngineWidget:skillLabelText()
    local s = tonumber(self.changes.skill_level) or 0
    return _("Computer Skill") .. ": " .. tostring(s)
end

-- ---------------------------------------------------------------------------
-- DEPTH GROUP
-- ---------------------------------------------------------------------------
function EngineWidget:buildDepthGroup()
    local w = self.dialog.element_width
    local min_d, max_d = 1, 4
    local function depthToPos(d) return (d == 0) and 4 or d end
    local function posToDepth(p) return (p == 4) and 0 or p end

    self.depthProgress = ButtonProgressWidget:new{
        width       = w,
        num_buttons = 4,
        position    = depthToPos(self.changes.engine_depth or 0),
        fine_tune   = true,
        callback    = function(pos)
            local cur = depthToPos(self.changes.engine_depth or 0)
            if pos == "+" then cur = math.min(max_d, cur + 1)
            elseif pos == "-" then cur = math.max(min_d, cur - 1)
            else cur = pos end
            self.changes.engine_depth = posToDepth(cur)
            self.depthProgress.position = cur
            if self.depthLabelWidget then self.depthLabelWidget:setText(self:depthLabelText()) end
            self:refreshEloLabel()
            self:markDirty()
            UIManager:setDirty(self.parent, "ui")
        end,
    }
    self.depthLabelWidget = TextWidget:new{
        text = self:depthLabelText(),
        face = Font:getFace("cfont", 22),
    }
    self.depthGroup = VerticalGroup:new{
        width = w,
        self.depthLabelWidget,
        VerticalSpan:new{ width = Size.padding.small },
        self.depthProgress,
    }
end

function EngineWidget:depthLabelText()
    local d = tonumber(self.changes.engine_depth) or 0
    local txt = (d == 0) and "∞" or tostring(d)
    return _("Search Depth") .. ": " .. txt
end

-- ---------------------------------------------------------------------------
-- MOVE TIME GROUP
-- ---------------------------------------------------------------------------
function EngineWidget:buildMoveTimeGroup()
    local min_t, max_t = 1, 10
    local w = self.dialog.element_width

    self.moveTimeProgress = ButtonProgressWidget:new{
        width       = w,
        num_buttons = max_t - min_t + 1,
        position    = (tonumber(self.changes.engine_movetime) or 1) - min_t + 1,
        fine_tune   = true,
        callback    = function(pos)
            local cur = (tonumber(self.changes.engine_movetime) or 1) - min_t + 1
            if pos == "+" then cur = math.min(max_t - min_t + 1, cur + 1)
            elseif pos == "-" then cur = math.max(1, cur - 1)
            else cur = pos end
            self.changes.engine_movetime = cur + min_t - 1
            self.moveTimeProgress.position = cur
            if self.moveTimeLabelWidget then self.moveTimeLabelWidget:setText(self:moveTimeLabelText()) end
            self:refreshEloLabel()
            self:markDirty()
            UIManager:setDirty(self.parent, "ui")
        end,
    }
    self.moveTimeLabelWidget = TextWidget:new{
        text = self:moveTimeLabelText(),
        face = Font:getFace("cfont", 22),
    }
    self.moveTimeGroup = VerticalGroup:new{
        width = w,
        self.moveTimeLabelWidget,
        VerticalSpan:new{ width = Size.padding.small },
        self.moveTimeProgress,
    }
end

function EngineWidget:moveTimeLabelText()
    return _("Think Time") .. ": " .. tostring(tonumber(self.changes.engine_movetime) or 1) .. " sec"
end

-- ---------------------------------------------------------------------------
-- BLUNDER GROUP
-- ---------------------------------------------------------------------------
function EngineWidget:buildBlunderGroup()
    local steps = 10
    local w = self.dialog.element_width
    local function chanceToPos(c) return math.floor((c or 0) * steps + 0.5) + 1 end
    local function posToChance(p) return (p - 1) / steps end

    self.blunderProgress = ButtonProgressWidget:new{
        width       = w,
        num_buttons = steps + 1,
        position    = chanceToPos(self.changes.blunder_chance or 0),
        fine_tune   = true,
        callback    = function(pos)
            local cur = chanceToPos(self.changes.blunder_chance or 0)
            if pos == "+" then cur = math.min(steps + 1, cur + 1)
            elseif pos == "-" then cur = math.max(1, cur - 1)
            else cur = pos end
            self.changes.blunder_chance = posToChance(cur)
            self.blunderProgress.position = cur
            if self.blunderLabelWidget then self.blunderLabelWidget:setText(self:blunderLabelText()) end
            self:refreshEloLabel()
            self:markDirty()
            UIManager:setDirty(self.parent, "ui")
        end,
    }
    self.blunderLabelWidget = TextWidget:new{
        text = self:blunderLabelText(),
        face = Font:getFace("cfont", 22),
    }
    self.blunderGroup = VerticalGroup:new{
        width = w,
        self.blunderLabelWidget,
        VerticalSpan:new{ width = Size.padding.small },
        self.blunderProgress,
    }
end

function EngineWidget:blunderLabelText()
    local pct = math.floor((self.changes.blunder_chance or 0) * 100)
    return _("Blunder Chance") .. ": " .. tostring(pct) .. "%"
end

-- ---------------------------------------------------------------------------
-- ASSEMBLE
-- ---------------------------------------------------------------------------
function EngineWidget:assembleContent()
    local D = self.dialog
    local w = D.element_width

    -- Shared ELO label shown at top of the dialog
    self.eloLabelWidget = TextWidget:new{
        text = self:eloLabel(),
        face = Font:getFace("cfont", 22),
    }

    local content = FrameContainer:new{
        radius     = Size.radius.window,
        bordersize = Size.border.window,
        background = BACKGROUND_COLOR,
        padding    = 0,
        margin     = 0,

        VerticalGroup:new{
            align = "left",
            D.title_bar,

            VerticalSpan:new{ width = Size.padding.large },

            -- ELO estimate banner
            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.eloLabelWidget:getSize().h },
                self.eloLabelWidget,
            },

            VerticalSpan:new{ width = Size.padding.large },

            -- Skill
            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.skillGroup:getSize().h },
                self.skillGroup,
            },

            VerticalSpan:new{ width = Size.padding.large },

            -- Depth
            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.depthGroup:getSize().h },
                self.depthGroup,
            },

            VerticalSpan:new{ width = Size.padding.large },

            -- Think time
            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.moveTimeGroup:getSize().h },
                self.moveTimeGroup,
            },

            VerticalSpan:new{ width = Size.padding.large },

            -- Blunder chance
            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.blunderGroup:getSize().h },
                self.blunderGroup,
            },

            VerticalSpan:new{ width = Size.padding.large },

            -- Save / Close buttons (from InputDialog's button_table)
            CenterContainer:new{
                dimen = Geometry:new{
                    w = D.title_bar:getSize().w,
                    h = D.button_table:getSize().h,
                },
                D.button_table,
            },

            VerticalSpan:new{ width = Size.padding.small },

            -- Reset to Defaults button
            CenterContainer:new{
                dimen = Geometry:new{
                    w = D.title_bar:getSize().w,
                    h = Screen:scaleBySize(32),
                },
                ButtonWidget:new{
                    text    = _("Reset to Defaults"),
                    radius  = Size.radius.button,
                    padding = Size.padding.small,
                    width   = math.floor(D.width * 0.8),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text       = _("Reset engine settings to defaults?"),
                            ok_text    = _("Reset"),
                            ok_callback = function() self:resetToDefaults() end,
                        })
                    end,
                },
            },
        },
    }

    D.movable = MovableContainer:new{ content }
    D[1] = CenterContainer:new{ dimen = Screen:getSize(), D.movable }
end

-- ---------------------------------------------------------------------------
-- Reset / Save
-- ---------------------------------------------------------------------------
function EngineWidget:resetToDefaults()
    self.changes.skill_level     = 0
    self.changes.engine_depth    = 2
    self.changes.engine_movetime = 1
    self.changes.blunder_chance  = 0.20
    self:saveAndClose()
end

function EngineWidget:saveAndClose()
    self.onSave(self.changes)
    UIManager:close(self.dialog)
end

return EngineWidget
