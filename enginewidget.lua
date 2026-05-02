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

local function computeElo(skill, depth, movetime, blunder_chance)
    skill = math.max(0, math.min(20, tonumber(skill) or 0))
    depth = tonumber(depth) or 0
    movetime = math.max(1, math.min(10, tonumber(movetime) or 1))
    blunder_chance = math.max(0, math.min(1, tonumber(blunder_chance) or 0))

    local base = 1300 + (skill / 20) ^ 1.35 * 1500
    local depth_penalty = ({ [1] = 700, [2] = 500, [3] = 300, [4] = 180, [5] = 90 })[depth] or 0
    local time_bonus = 0
    if depth == 0 then
        time_bonus = math.floor(math.log(movetime) / math.log(10) * 180)
    end
    local random_floor = 200
    local nonrandom_elo = base - depth_penalty + time_bonus
    local blundered_elo = random_floor
        + (nonrandom_elo - random_floor) * ((1 - blunder_chance) ^ 1.6)

    return math.max(random_floor, math.floor(blundered_elo))
end

local EngineWidget = {}
EngineWidget.__index = EngineWidget
EngineWidget.computeElo = computeElo

function EngineWidget:new(opts)
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
        force_goldfish  = init.force_goldfish  and true or false,
    }

    return o
end

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

function EngineWidget:eloLabel()
    if self:isGoldfishActive() then
        return "Goldfish ELO: ~600"
    end
    local elo = computeElo(
        tonumber(self.changes.skill_level)     or 0,
        tonumber(self.changes.engine_depth)    or 0,
        tonumber(self.changes.engine_movetime) or 1,
        tonumber(self.changes.blunder_chance)  or 0
    )
    return _("Estimated ELO") .. ": ~" .. tostring(elo)
end

function EngineWidget:isGoldfishActive()
    local chess_mode = not (self.parent and self.parent.isCheckersMode and self.parent:isCheckersMode())
    return chess_mode
        and (self.changes.force_goldfish or (self.parent and self.parent.goldfish_active))
end

function EngineWidget:refreshEloLabel()
    if self.eloLabelWidget then
        self.eloLabelWidget:setText(self:eloLabel())
        UIManager:setDirty(self.parent, "ui")
    end
end

function EngineWidget:markDirty()
    if self.dialog._buttons_edit_callback then
        self.dialog:_buttons_edit_callback(true)
    end
    UIManager:setDirty(self.parent, "ui")
end

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

function EngineWidget:buildDepthGroup()
    local w = self.dialog.element_width
    local min_d, max_d = 1, 6
    local function depthToPos(d) return (d == 0) and 6 or d end
    local function posToDepth(p) return (p == 6) and 0 or p end

    self.depthProgress = ButtonProgressWidget:new{
        width       = w,
        num_buttons = 6,
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

function EngineWidget:buildBlunderGroup()
    local max_blunder = 0.60
    local steps = 12
    local w = self.dialog.element_width
    local function chanceToPos(c)
        c = math.max(0, math.min(max_blunder, c or 0))
        return math.floor(c * steps / max_blunder + 0.5) + 1
    end
    local function posToChance(p) return (p - 1) * max_blunder / steps end

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

function EngineWidget:buildGoldfishButton()
    local w = self.dialog.element_width
    local h = Screen:scaleBySize(32)
    local function label()
        return (self.changes.force_goldfish and "☑ " or "☐ ") .. _("Goldfish (testing only)")
    end
    self.goldfishButton = ButtonWidget:new{
        text    = label(),
        width   = w,
        height  = h,
        radius  = Size.radius.button,
        padding = Size.padding.small,
        align   = "left",
        callback = function()
            self.changes.force_goldfish = not self.changes.force_goldfish
            self.goldfishButton.text = label()
            self.goldfishButton:init()
            self:refreshEloLabel()
            self:markDirty()
            UIManager:setDirty(self.dialog, "ui")
        end,
    }
end

function EngineWidget:assembleContent()
    local D = self.dialog
    local w = D.element_width
    self:buildGoldfishButton()

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

            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.eloLabelWidget:getSize().h },
                self.eloLabelWidget,
            },

            VerticalSpan:new{ width = Size.padding.large },

            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.skillGroup:getSize().h },
                self.skillGroup,
            },

            VerticalSpan:new{ width = Size.padding.large },

            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.depthGroup:getSize().h },
                self.depthGroup,
            },

            VerticalSpan:new{ width = Size.padding.large },

            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.moveTimeGroup:getSize().h },
                self.moveTimeGroup,
            },

            VerticalSpan:new{ width = Size.padding.large },

            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.blunderGroup:getSize().h },
                self.blunderGroup,
            },

            VerticalSpan:new{ width = Size.padding.large },

            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.goldfishButton:getSize().h },
                self.goldfishButton,
            },

            VerticalSpan:new{ width = Size.padding.large },

            CenterContainer:new{
                dimen = Geometry:new{
                    w = D.title_bar:getSize().w,
                    h = D.button_table:getSize().h,
                },
                D.button_table,
            },

            VerticalSpan:new{ width = Size.padding.small },

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

function EngineWidget:resetToDefaults()
    self.changes.skill_level     = 0
    self.changes.engine_depth    = 2
    self.changes.engine_movetime = 1
    self.changes.blunder_chance  = 0.20
    self.changes.force_goldfish  = false
    self:saveAndClose()
end

function EngineWidget:saveAndClose()
    self.onSave(self.changes)
    UIManager:close(self.dialog)
end

return EngineWidget
