-- SettingsWidget.lua
-- Settings dialog for engine, time controls, and player types.
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geometry = require("ui/geometry")
local Size = require("ui/size")
local CenterContainer = require("ui/widget/container/centercontainer")
local RadioButtonTable = require("ui/widget/radiobuttontable")
local InputDialog = require("ui/widget/inputdialog")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ButtonWidget    = require("ui/widget/button")
local ButtonProgressWidget = require("ui/widget/buttonprogresswidget")
local DoubleSpinWidget = require("ui/widget/doublespinwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ConfirmBox = require("ui/widget/confirmbox")

local Chess = require("chess")
local _ = require("gettext")

local BACKGROUND_COLOR = Blitbuffer.COLOR_WHITE

local SettingsWidget = {}
SettingsWidget.__index = SettingsWidget

-- ============================================================================
--  Constructor
-- ============================================================================
-- options:
--   engine            = your UCI engine instance
--   timer             = your timer object
--   game              = your game logic (for .is_human, .set_human, .turn, etc.)
--   onApply(settings) = callback when user clicks Apply
--   onCancel()        = callback when user clicks Cancel (optional)
function SettingsWidget:new(opts)
    assert(opts.engine, "engine is required")
    assert(opts.timer,  "timer is required")
    assert(opts.game,   "game is required")
    assert(opts.onApply and type(opts.onApply) == "function",
           "onApply callback is required")
    assert(opts.parent,   "parent is required")

    self = setmetatable({
        engine     = opts.engine,
        timer      = opts.timer,
        game       = opts.game,
        onApply    = opts.onApply,
        onCancel   = opts.onCancel,
        parent     = opts.parent,
        dialog     = nil,
        changes    = {},
    }, SettingsWidget)

    self:initializeState()
    return self
end

-- ============================================================================
--  Initialize the local `changes` table from current engine/timer/game state
-- ============================================================================
function SettingsWidget:initializeState()
    -- Skill bounds (0..20)
    self.min_skill = 0
    self.max_skill = 20

    -- Time bounds
    self.min_base_min = 1
    self.max_base_min = 180
    self.min_incr_sec = 0
    self.max_incr_sec = 60

    local currentSkill = (self.parent and tonumber(self.parent.current_skill)) or nil

    -- fall back to engine-reported value
    if not currentSkill then
        local skillOpt = self.engine.state.options["Skill Level"]

        currentSkill = (skillOpt and tonumber(skillOpt.value)) or 2
    end
    currentSkill = math.max(0, math.min(20, currentSkill))

    -- ELO bounds
    self.min_elo   = 1350
    self.max_elo   = 2850
    self.elo_step  = 50

    local eloOpt = self.engine.state.options["UCI_Elo"]
    local currentElo = (eloOpt and tonumber(eloOpt.value)) or 1350
    currentElo = math.max(self.min_elo, math.min(self.max_elo, currentElo))

    -- Current changes snapshot
    self.changes = {
        human_choice = {
            [Chess.WHITE] = self.game.is_human(Chess.WHITE),
            [Chess.BLACK] = self.game.is_human(Chess.BLACK),
        },
        skill_level     = currentSkill,
        elo_strength    = currentElo,
        engine_movetime = (self.parent and self.parent.engine_movetime) or 1,
        time_control = {
            [Chess.WHITE] = {
                base_minutes  = self.timer.base[Chess.WHITE] / 60,
                incr_seconds  = self.timer.increment[Chess.WHITE],
            },
            [Chess.BLACK] = {
                base_minutes  = self.timer.base[Chess.BLACK] / 60,
                incr_seconds  = self.timer.increment[Chess.BLACK],
            },
        },
    }
end

-- ============================================================================
--  Public show() method: builds and displays the dialog
-- ============================================================================
function SettingsWidget:show()
    local dlg = InputDialog:new{
        title          = _("Chess Settings"),
        save_callback  = function() self:applyAndClose() end,
        dismiss_callback = function()
            if self.onCancel then self.onCancel() end
        end,
    }
    dlg.element_width = math.floor(dlg.width * 0.8)
    self.dialog = dlg

    self:buildPlayerTypeGroup()
    self:buildSkillGroup()
    self:buildMoveTimeGroup()

    self:buildTimeGroups()
    self:assembleContent()

    dlg:refocusWidget()
    UIManager:show(dlg)
end

-- ============================================================================
--  Helper: enable the Apply button when something changes
-- ============================================================================
function SettingsWidget:markDirty()
    -- Signal the Save button to enable. _buttons_edit_callback is InputDialog's
    -- internal mechanism for this; guard in case it is absent in future versions.
    if self.dialog._buttons_edit_callback then
        self.dialog:_buttons_edit_callback(true)
    end
    UIManager:setDirty(self.parent, "ui")
end

-- ============================================================================
--  PLAYER TYPE RADIO GROUP
-- ============================================================================
function SettingsWidget:buildPlayerTypeGroup()
    local w = self.dialog.element_width

    local makeList = function(color)
        return {{
            { text = _("Human"),    checked =     self.changes.human_choice[color], color = color },
            { text = _("Computer"), checked = not self.changes.human_choice[color], color = color },
        }}
    end

    local function onSelect(entry)
        self.changes.human_choice[entry.color] = (entry.text == _("Human"))
        self:markDirty()
    end

    local whiteRadios = RadioButtonTable:new{
        width  = w,
        radio_buttons = makeList(Chess.WHITE),
        button_select_callback = onSelect,
        parent = self.dialog,
    }
    local blackRadios = RadioButtonTable:new{
        width  = w,
        radio_buttons = makeList(Chess.BLACK),
        button_select_callback = onSelect,
        parent = self.dialog,
    }

    self.playerSettingsGroup = VerticalGroup:new{
        width = w,
        spacing = Size.padding.large,
        VerticalGroup:new{
            width = w,
            TextWidget:new{ text = _("White")..":", face = Font:getFace("cfont", 22) },
            VerticalSpan:new{ width = Size.padding.small },
            whiteRadios,
        },
        VerticalGroup:new{
            width = w,
            TextWidget:new{ text = _("Black")..":", face = Font:getFace("cfont", 22) },
            VerticalSpan:new{ width = Size.padding.small },
            blackRadios,
        },
    }
end

-- ============================================================================
--  SKILL LEVEL GROUP
-- ============================================================================
function SettingsWidget:buildSkillGroup()
    -- Skill 0..20 maps to positions 1..21 in ButtonProgressWidget
    local function skillToPos(s) return (tonumber(s) or 2) + 1 end
    local function posToSkill(p) return p - 1 end

    local w = self.dialog.element_width
    self.skillProgress = ButtonProgressWidget:new{
        width         = w,
        num_buttons   = self.max_skill - self.min_skill + 1,  -- 21
        position      = skillToPos(self.changes.skill_level),
        fine_tune     = true,
        callback = function(pos)
            if pos == "+" then
                self.changes.skill_level = math.min(self.max_skill,
                    (tonumber(self.changes.skill_level) or 1) + 1)
            elseif pos == "-" then
                self.changes.skill_level = math.max(self.min_skill,
                    (tonumber(self.changes.skill_level) or 1) - 1)
            else
                self.changes.skill_level = posToSkill(pos)
            end
            self.skillProgress.position = skillToPos(self.changes.skill_level)
            self:markDirty()
            UIManager:setDirty(self, "ui")
        end,
    }
    local skill_elo = {
        [0]=800, [1]=900, [2]=1000, [3]=1100, [4]=1200,
        [5]=1300, [6]=1400, [7]=1500, [8]=1600, [9]=1650,
        [10]=1700, [11]=1750, [12]=1800, [13]=1900, [14]=2000,
        [15]=2100, [16]=2200, [17]=2400, [18]=2600, [19]=2800, [20]=3200,
    }
    local function skillLabel()
        local s = tonumber(self.changes.skill_level) or 2
        local elo = skill_elo[s] or "?"
        return _("Computer Skill") .. ": " .. tostring(s) .. "  ELO: ~" .. tostring(elo)
    end
    self.skillLabelWidget = TextWidget:new{
        text = skillLabel(),
        face = Font:getFace("cfont", 22),
    }
    -- Update label text whenever value changes
    local orig_skill_cb = self.skillProgress.callback
    self.skillProgress.callback = function(pos)
        orig_skill_cb(pos)
        self.skillLabelWidget:setText(skillLabel())
    end
    self.skillSettingsGroup = VerticalGroup:new{
        width = w,
        self.skillLabelWidget,
        VerticalSpan:new{ width = Size.padding.small },
        self.skillProgress,
    }
end

-- ============================================================================
--  ENGINE THINK TIME GROUP
-- ============================================================================
function SettingsWidget:buildMoveTimeGroup()
    local min_t, max_t = 1, 10
    local w = self.dialog.element_width
    self.moveTimeProgress = ButtonProgressWidget:new{
        width       = w,
        num_buttons = max_t - min_t + 1,  -- 10
        position    = (tonumber(self.changes.engine_movetime) or 1) - min_t + 1,
        fine_tune   = true,
        callback = function(pos)
            if pos == "+" then
                self.changes.engine_movetime = math.min(max_t,
                    (tonumber(self.changes.engine_movetime) or 1) + 1)
            elseif pos == "-" then
                self.changes.engine_movetime = math.max(min_t,
                    (tonumber(self.changes.engine_movetime) or 1) - 1)
            else
                self.changes.engine_movetime = pos + min_t - 1
            end
            self.moveTimeProgress.position = (tonumber(self.changes.engine_movetime) or 1) - min_t + 1
            self:markDirty()
            UIManager:setDirty(self, "ui")
        end,
    }
    local function moveTimeLabel()
        return _("Computer Think Time") .. ": " .. tostring(tonumber(self.changes.engine_movetime) or 1) .. " sec"
    end
    self.moveTimeLabelWidget = TextWidget:new{
        text = moveTimeLabel(),
        face = Font:getFace("cfont", 22),
    }
    local orig_move_cb = self.moveTimeProgress.callback
    self.moveTimeProgress.callback = function(pos)
        orig_move_cb(pos)
        self.moveTimeLabelWidget:setText(moveTimeLabel())
    end
    self.moveTimeGroup = VerticalGroup:new{
        width = w,
        self.moveTimeLabelWidget,
        VerticalSpan:new{ width = Size.padding.small },
        self.moveTimeProgress,
    }
end

-- ============================================================================
--  ELO GROUP
-- ============================================================================
function SettingsWidget:buildEloGroup()
    -- value display
    local tv = TextWidget:new{
        text   = tostring(self.changes.elo_strength),
        face   = Font:getFace("cfont",22),
        halign = "center",
        width  = 80
    }
    self.eloValueText = tv

    local function updateDisplay()
        tv:setText(tostring(math.floor(self.changes.elo_strength)))
        UIManager:setDirty(self, "ui")
    end

    local function onClick(delta)
        self.changes.elo_strength = math.max(
            self.min_elo,
            math.min(self.max_elo, self.changes.elo_strength + delta)
        )
        updateDisplay()
        self:markDirty()
    end

    local decBtn = ButtonWidget:new{
        text     = "- "..tostring(self.elo_step),
        callback = function() onClick(-self.elo_step) end,
        face     = Font:getFace("cfont",20),
        padding  = Size.padding.small,
        radius   = Size.radius.button,
        parent   = self.dialog,
    }
    local incBtn = ButtonWidget:new{
        text     = "+ "..tostring(self.elo_step),
        callback = function() onClick(self.elo_step) end,
        face     = Font:getFace("cfont",20),
        padding  = Size.padding.small,
        radius   = Size.radius.button,
        parent   = self.dialog,
    }

    local ctrl = HorizontalGroup:new{ spacing=Size.padding.small, decBtn, tv, incBtn }
    self.eloSettingsGroup = HorizontalGroup:new{
        width = self.dialog.element_width,
        TextWidget:new{ text=_("Engine ELO Strength")..":", face=Font:getFace("cfont",22) },
        ctrl
    }
end

-- ============================================================================
--  TIME GROUPS: DoubleSpinWidget popup for minutes + increment
-- ============================================================================
function SettingsWidget:buildTimeGroups()
    local function fmt(b, i)
        if i > 0 then
            return string.format("%d min  +%ds", b, i)
        else
            return string.format("%d min", b)
        end
    end

    local btn_width = math.floor(self.dialog.element_width * 0.55)

    local function openTimePicker(color, btn)
        local cur = self.changes.time_control[color]
        local color_name = (color == Chess.WHITE) and _("White") or _("Black")
        UIManager:show(DoubleSpinWidget:new{
            title_text    = color_name .. " " .. _("Time"),
            left_text     = _("Minutes"),
            left_min      = self.min_base_min,
            left_max      = self.max_base_min,
            left_value    = cur.base_minutes,
            left_default  = 15,
            right_text    = _("Increment (s)"),
            right_min     = self.min_incr_sec,
            right_max     = self.max_incr_sec,
            right_value   = cur.incr_seconds,
            right_default = 10,
            callback = function(left_val, right_val)
                cur.base_minutes = left_val
                cur.incr_seconds = right_val
                btn.text = fmt(left_val, right_val)
                btn.width = btn_width
                btn:init()
                self:markDirty()
                UIManager:setDirty(self, "ui")
            end,
        })
    end

    local function makeTimeRow(color, label_text)
        local cur = self.changes.time_control[color]
        local btn
        btn = ButtonWidget:new{
            text     = fmt(cur.base_minutes, cur.incr_seconds),
            width    = btn_width,
            radius   = Size.radius.button,
            padding  = Size.padding.small,
            callback = function() openTimePicker(color, btn) end,
        }
        return HorizontalGroup:new{
            width   = self.dialog.element_width,
            spacing = Size.padding.large,
            TextWidget:new{ text = label_text, face = Font:getFace("cfont", 22) },
            btn,
        }
    end

    self.timeSettingsGroup = VerticalGroup:new{
        width   = self.dialog.element_width,
        spacing = Size.padding.large,
        makeTimeRow(Chess.WHITE, _("White Time")),
        makeTimeRow(Chess.BLACK, _("Black Time")),
    }
end

-- ============================================================================
--  Assemble the final dialog content and show
-- ============================================================================
function SettingsWidget:assembleContent()
    local D = self.dialog
    local empty = VerticalSpan:new{ width = 0 }
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

            -- Player type only if engine is ready
            self.engine.state.uciok and CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.playerSettingsGroup:getSize().h },
                self.playerSettingsGroup
            } or VerticalSpan:new{ width = 0 },

            self.engine.state.uciok and VerticalSpan:new{ width = Size.padding.large } or empty,

            -- Skill only if engine is ready
            self.engine.state.uciok and CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.skillSettingsGroup:getSize().h },
                self.skillSettingsGroup
            } or VerticalSpan:new{ width = 0 },

            self.engine.state.uciok and VerticalSpan:new{ width = Size.padding.large } or empty,

            -- Engine think time (only if engine ready)
            self.engine.state.uciok and CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.moveTimeGroup:getSize().h },
                self.moveTimeGroup
            } or VerticalSpan:new{ width = 0 },

            self.engine.state.uciok and VerticalSpan:new{ width = Size.padding.large } or empty,

            -- Time controls
            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.timeSettingsGroup:getSize().h },
                self.timeSettingsGroup
            },
            VerticalSpan:new{ width = Size.padding.large },

            -- Buttons
            CenterContainer:new{
                dimen = Geometry:new{
                    w = D.title_bar:getSize().w,
                    h = D.button_table:getSize().h,
                },
                D.button_table
            },
            VerticalSpan:new{ width = Size.padding.small },
            CenterContainer:new{
                dimen = Geometry:new{
                    w = D.title_bar:getSize().w,
                    h = Screen:scaleBySize(32),
                },
                ButtonWidget:new{
                    text     = _("Reset to Defaults"),
                    radius   = Size.radius.button,
                    padding  = Size.padding.small,
                    width    = math.floor(D.width * 0.8),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text       = _("Reset all settings to defaults?"),
                            ok_text    = _("Reset"),
                            ok_callback = function() self:resetToDefaults() end,
                        })
                    end,
                },
            },
        }
    }

    D.movable = MovableContainer:new{ content }
    D[1]      = CenterContainer:new{ dimen = Screen:getSize(), D.movable }
end

-- ============================================================================
--  APPLY: gather `self.changes`, perform any engine/timer updates, then callback
-- ============================================================================
function SettingsWidget:resetToDefaults()
    self.changes.skill_level     = 2
    self.changes.engine_movetime = 1
    self.changes.human_choice    = { [Chess.WHITE] = true, [Chess.BLACK] = false }
    self.changes.time_control    = {
        [Chess.WHITE] = { base_minutes = 15, incr_seconds = 10 },
        [Chess.BLACK] = { base_minutes = 15, incr_seconds = 10 },
    }
    self:applyAndClose()
end
function SettingsWidget:applyAndClose()
    local s = self.changes

    -- 1) Skill Level (0..20)
    local optSkill = self.engine.state.options["Skill Level"]
    local v = tonumber(s.skill_level) or 2
    v = math.max(0, math.min(20, v))

    if optSkill then
        self.engine:setOption("Skill Level", tostring(v))
    end

    if self.parent then
        self.parent.current_skill = v
    end
    -- ELO strength (UCI_LimitStrength + UCI_Elo) - disabled by default
    local optLimit = self.engine.state.options["UCI_LimitStrength"]
    if optLimit and tostring(optLimit.value) ~= "false" then
        self.engine:setOption("UCI_LimitStrength", "false")
    end
    -- If user changed ELO, apply it (requires UCI_LimitStrength=true)
    -- Currently ELO mode is kept disabled; this just stores the preference.

    if self.engine and self.engine.state.uciok then
        self.engine.send("isready")
    end

    -- 2) Time controls
    local function applyTime(color)
        local baseOld = self.timer.base[color] / 60
        local incrOld = self.timer.increment[color]
        local c = s.time_control[color]
        if baseOld ~= c.base_minutes then
            self.timer.base[color] = c.base_minutes * 60
            self.timer.time[color] = c.base_minutes * 60
        end
        if incrOld ~= c.incr_seconds then
            self.timer.increment[color] = c.incr_seconds
        end
    end
    applyTime(Chess.WHITE)
    applyTime(Chess.BLACK)

    -- 3) Player types
    for _, color in ipairs({Chess.WHITE, Chess.BLACK}) do
        if self.game.is_human(color) ~= s.human_choice[color] then
            self.game.set_human(color, s.human_choice[color])
        end
    end

    -- 4) Engine think time
    if self.parent then
        self.parent.engine_movetime = math.max(1, math.min(10,
            tonumber(s.engine_movetime) or 1))
    end

    -- 5) Persist all settings
    if self.parent and self.parent.setSetting then
        local p = self.parent
        p:setSetting("skill_level",    v)
        p:setSetting("engine_movetime", math.max(1, math.min(10, tonumber(s.engine_movetime) or 1)))
        p:setSetting("human_white",    s.human_choice[Chess.WHITE])
        p:setSetting("human_black",    s.human_choice[Chess.BLACK])
        local wc = s.time_control[Chess.WHITE]
        local bc = s.time_control[Chess.BLACK]
        p:setSetting("time_base_white", wc.base_minutes * 60)
        p:setSetting("time_base_black", bc.base_minutes * 60)
        p:setSetting("time_incr_white", wc.incr_seconds)
        p:setSetting("time_incr_black", bc.incr_seconds)
    end

    self.onApply(s)
    UIManager:close(self.dialog)
end

return SettingsWidget
