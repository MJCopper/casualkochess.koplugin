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
local EngineWidget = require("enginewidget")
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

        currentSkill = (skillOpt and tonumber(skillOpt.value)) or 0
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
        engine_depth    = (self.parent and self.parent.engine_depth) or 2,
        engine_movetime = (self.parent and self.parent.engine_movetime) or 1,
        blunder_chance  = (self.parent and self.parent.blunder_chance) or 0.20,
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
    self:buildDifficultyGroup()
    self:buildEngineButton()
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

    local function fmt(b, i)
        if i > 0 then return string.format("%d min  +%ds", b, i)
        else return string.format("%d min", b) end
    end

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
                btn.width = btn_w
                btn:init()
                self:markDirty()
                UIManager:setDirty(self, "ui")
            end,
        })
    end

    local function onSelect(entry)
        self.changes.human_choice[entry.color] = (entry.text == _("Human"))
        self:markDirty()
    end

    local function makeRow(color)
        local cur = self.changes.time_control[color]
        local radio_w = math.floor(w * 0.60)
        local btn_w   = math.floor(w * 0.35)
        local label = (color == Chess.WHITE) and _("White") or _("Black")
        local btn
        btn = ButtonWidget:new{
            text     = fmt(cur.base_minutes, cur.incr_seconds),
            width    = btn_w,
            radius   = Size.radius.button,
            padding  = Size.padding.small,
            callback = function() openTimePicker(color, btn) end,
        }
        -- Two-row RadioButtonTable stacks Human / Computer vertically
        local radios = RadioButtonTable:new{
            width  = radio_w,
            radio_buttons = {
                {{ text = _("Human"),    checked =     self.changes.human_choice[color], color = color }},
                {{ text = _("Computer"), checked = not self.changes.human_choice[color], color = color }},
            },
            button_select_callback = onSelect,
            parent = self.dialog,
        }
        local radioCol = VerticalGroup:new{
            width = radio_w,
            TextWidget:new{ text = label .. ":", face = Font:getFace("cfont", 22) },
            VerticalSpan:new{ width = Size.padding.small },
            radios,
        }
        return HorizontalGroup:new{
            width   = w,
            spacing = Size.padding.large,
            radioCol,
            btn,
        }
    end

    self.playerSettingsGroup = VerticalGroup:new{
        width   = w,
        spacing = Size.padding.large,
        makeRow(Chess.WHITE),
        makeRow(Chess.BLACK),
    }
end


-- ============================================================================
--  DIFFICULTY PRESETS
-- ============================================================================
function SettingsWidget:buildDifficultyGroup()
    local w = self.dialog.element_width

    local PRESETS = {
        {
            name          = _("Beginner"),
            skill_level   = 0,
            engine_depth  = 1,
            engine_movetime = 1,
            blunder_chance  = 0.40,
            elo           = 429,
        },
        {
            name          = _("Casual"),
            skill_level   = 0,
            engine_depth  = 2,
            engine_movetime = 1,
            blunder_chance  = 0.20,
            elo           = 780,
        },
        {
            name          = _("Intermediate"),
            skill_level   = 0,
            engine_depth  = 3,
            engine_movetime = 2,
            blunder_chance  = 0.10,
            elo           = 1029,
        },
        {
            name          = _("Club Player"),
            skill_level   = 10,
            engine_depth  = 0,
            engine_movetime = 3,
            blunder_chance  = 0.0,
            elo           = 1865,
        },
        {
            name          = _("Master"),
            skill_level   = 20,
            engine_depth  = 0,
            engine_movetime = 10,
            blunder_chance  = 0.0,
            elo           = 2832,
        },
    }

    -- Find which preset (if any) matches current settings
    local function currentPos()
        for i, p in ipairs(PRESETS) do
            if p.skill_level    == self.changes.skill_level
            and p.engine_depth  == self.changes.engine_depth
            and p.engine_movetime == self.changes.engine_movetime
            and math.abs((p.blunder_chance or 0) - (self.changes.blunder_chance or 0)) < 0.01
            then
                return i
            end
        end
        return nil  -- custom / no match
    end

    local function difficultyLabel()
        local pos = currentPos()
        if pos then
            local p = PRESETS[pos]
            return p.name .. "  ELO: ~" .. tostring(p.elo)
        else
            return _("Custom")
        end
    end

    self.difficultyLabelWidget = TextWidget:new{
        text = difficultyLabel(),
        face = Font:getFace("cfont", 22),
    }

    local function applyPreset(pos)
        local p = PRESETS[pos]
        if not p then return end
        self.changes.skill_level     = p.skill_level
        self.changes.engine_depth    = p.engine_depth
        self.changes.engine_movetime = p.engine_movetime
        self.changes.blunder_chance  = p.blunder_chance
        self:applyEngineChanges(self.changes)
        self.difficultyLabelWidget:setText(difficultyLabel())
        self:markDirty()
        UIManager:setDirty(self.parent, "ui")
    end

    local cur = currentPos() or 1
    self.difficultyProgress = ButtonProgressWidget:new{
        width       = w,
        num_buttons = #PRESETS,
        position    = cur,
        fine_tune   = true,
        callback    = function(pos)
            local p = currentPos() or 1
            if pos == "+" then p = math.min(#PRESETS, p + 1)
            elseif pos == "-" then p = math.max(1, p - 1)
            else p = pos end
            self.difficultyProgress.position = p
            applyPreset(p)
        end,
    }

    self.difficultyGroup = VerticalGroup:new{
        width = w,
        self.difficultyLabelWidget,
        VerticalSpan:new{ width = Size.padding.small },
        self.difficultyProgress,
    }
end
function SettingsWidget:buildEngineButton()
    local w = self.dialog.element_width
    self.engineButton = ButtonWidget:new{
        text    = _("Computer Engine..."),
        width   = w,
        radius  = Size.radius.button,
        padding = Size.padding.small,
        callback = function()
            local ew = EngineWidget:new{
                engine  = self.engine,
                parent  = self.parent,
                initial = {
                    skill_level     = self.changes.skill_level,
                    engine_depth    = self.changes.engine_depth,
                    engine_movetime = self.changes.engine_movetime,
                    blunder_chance  = self.changes.blunder_chance,
                },
                onSave = function(saved)
                    -- Merge saved engine values back into our changes table
                    self.changes.skill_level     = saved.skill_level
                    self.changes.engine_depth    = saved.engine_depth
                    self.changes.engine_movetime = saved.engine_movetime
                    self.changes.blunder_chance  = saved.blunder_chance
                    -- Apply immediately to parent and engine
                    self:applyEngineChanges(saved)
                end,
            }
            ew:show()
        end,
    }
    self.engineButtonGroup = CenterContainer:new{
        dimen = Geometry:new{ w = self.dialog.width, h = self.engineButton:getSize().h },
        self.engineButton,
    }
end

-- Apply only the engine-related fields (called from EngineWidget onSave)
function SettingsWidget:applyEngineChanges(s)
    local optSkill = self.engine.state.options["Skill Level"]
    local v = math.max(0, math.min(20, tonumber(s.skill_level) or 0))
    if optSkill then self.engine:setOption("Skill Level", tostring(v)) end
    if self.parent then
        self.parent.current_skill = v
        self.parent.engine_movetime = math.max(1, math.min(10, tonumber(s.engine_movetime) or 1))
        local d = tonumber(s.engine_depth) or 0
        self.parent.engine_depth = (d >= 1 and d <= 3) and d or 0
        local bc = math.max(0.0, math.min(1.0, tonumber(s.blunder_chance) or 0.0))
        self.parent.blunder_chance = bc
        if self.parent.weakening then self.parent.weakening:setChance(bc) end
    end
    if self.parent and self.parent.setSetting then
        local p = self.parent
        p:setSetting("skill_level",     v)
        p:setSetting("engine_depth",    self.parent.engine_depth)
        p:setSetting("engine_movetime", self.parent.engine_movetime)
        p:setSetting("blunder_chance",  self.parent.blunder_chance)
    end
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

            -- Player type + clock buttons (only if engine is ready)
            self.engine.state.uciok and CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.playerSettingsGroup:getSize().h },
                self.playerSettingsGroup
            } or VerticalSpan:new{ width = 0 },

            self.engine.state.uciok and VerticalSpan:new{ width = Size.padding.large } or empty,

            -- Difficulty preset slider (only if engine ready)
            self.engine.state.uciok and CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.difficultyGroup:getSize().h },
                self.difficultyGroup,
            } or VerticalSpan:new{ width = 0 },

            self.engine.state.uciok and VerticalSpan:new{ width = Size.padding.large } or empty,

            -- Computer Engine button (only if engine ready)
            self.engine.state.uciok and CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.engineButton:getSize().h },
                self.engineButton,
            } or VerticalSpan:new{ width = 0 },

            self.engine.state.uciok and VerticalSpan:new{ width = Size.padding.large } or empty,

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
    self.changes.skill_level     = 0
    self.changes.engine_depth    = 2
    self.changes.blunder_chance  = 0.20
    self.changes.engine_movetime = 1
    self.changes.human_choice    = { [Chess.WHITE] = true, [Chess.BLACK] = false }
    self.changes.time_control    = {
        [Chess.WHITE] = { base_minutes = 15, incr_seconds = 10 },
        [Chess.BLACK] = { base_minutes = 15, incr_seconds = 10 },
    }
    -- Also apply engine defaults immediately
    self:applyEngineChanges(self.changes)
    self:applyAndClose()
end
function SettingsWidget:applyAndClose()
    local s = self.changes

    -- 1) Time controls
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

    -- 2) Player types
    for _, color in ipairs({Chess.WHITE, Chess.BLACK}) do
        if self.game.is_human(color) ~= s.human_choice[color] then
            self.game.set_human(color, s.human_choice[color])
        end
    end

    -- 3) Persist time and player settings
    if self.parent and self.parent.setSetting then
        local p = self.parent
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
