local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Geometry = require("ui/geometry")
local Size = require("ui/size")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputDialog = require("ui/widget/inputdialog")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ButtonWidget = require("ui/widget/button")
local FrameContainer = require("ui/widget/container/framecontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ConfirmBox = require("ui/widget/confirmbox")

local _ = require("gettext")

local BACKGROUND_COLOR = Blitbuffer.COLOR_WHITE

local InterfaceWidget = {}
InterfaceWidget.__index = InterfaceWidget

function InterfaceWidget:new(opts)
    assert(opts.parent, "parent is required")
    assert(opts.onSave, "onSave callback is required")

    local init = opts.initial or {}
    local state = {
        show_selected       = init.show_selected ~= false,
        learning_mode       = init.learning_mode == true,
        previous_move_hints = init.previous_move_hints == true,
        opponent_hints      = init.opponent_hints == true,
        check_hints         = init.check_hints == true,
        rotate_top_pieces   = init.rotate_top_pieces == true,
        show_coordinates    = init.show_coordinates == true,
        thinking_indicator  = init.thinking_indicator ~= false,
    }
    return setmetatable({
        parent   = opts.parent,
        onSave   = opts.onSave,
        dialog   = nil,
        is_dirty = false,
        changes  = state,
        original = {
            show_selected       = state.show_selected,
            learning_mode       = state.learning_mode,
            previous_move_hints = state.previous_move_hints,
            opponent_hints      = state.opponent_hints,
            check_hints         = state.check_hints,
            rotate_top_pieces   = state.rotate_top_pieces,
            show_coordinates    = state.show_coordinates,
            thinking_indicator  = state.thinking_indicator,
        },
    }, InterfaceWidget)
end

function InterfaceWidget:show()
    local dlg = InputDialog:new{
        title         = _("Interface"),
        save_callback = function() self:saveAndClose() end,
    }
    dlg.element_width = math.floor(dlg.width * 0.8)
    dlg.onCloseDialog = function() return true end

    local close_btn = dlg.button_table:getButtonById("close")
    if close_btn then
        close_btn.callback = function()
            if self.is_dirty then
                for k, v in pairs(self.original) do self.changes[k] = v end
                self:applyValues(self.original)
            end
            UIManager:close(dlg)
        end
    end

    self.dialog   = dlg
    self.is_dirty = false

    self:buildOptions()
    self:assembleContent()

    dlg:refocusWidget()
    UIManager:show(dlg)
end

function InterfaceWidget:markDirty()
    self.is_dirty = true
    local close_btn = self.dialog.button_table:getButtonById("close")
    if close_btn then
        close_btn:setText(_("Discard"), close_btn.width)
        close_btn:refresh()
    end
    local save_btn = self.dialog.button_table:getButtonById("save")
    if save_btn then
        save_btn:enable()
        save_btn:refresh()
    end
    UIManager:setDirty(self.parent, "ui")
end

function InterfaceWidget:buttonLabel(key, label_text)
    return (self.changes[key] and "☑ " or "☐ ") .. label_text
end

function InterfaceWidget:makeToggle(key, label_text)
    local btn
    btn = ButtonWidget:new{
        text    = self:buttonLabel(key, label_text),
        width   = self.dialog.element_width,
        radius  = Size.radius.button,
        padding = Size.padding.small,
        align   = "left",
        callback = function()
            self.changes[key] = not self.changes[key]
            btn.text = self:buttonLabel(key, label_text)
            btn:init()
            self:applyPreview()
            self:markDirty()
        end,
    }
    return btn
end

function InterfaceWidget:buildOptions()
    self.optionsGroup = VerticalGroup:new{
        width = self.dialog.element_width,
        self:makeToggle("thinking_indicator",  _("Thinking Indicator")),
        VerticalSpan:new{ width = Size.padding.small },
        self:makeToggle("show_selected",       _("Highlight Selected")),
        VerticalSpan:new{ width = Size.padding.small },
        self:makeToggle("learning_mode",       _("Player Hints")),
        VerticalSpan:new{ width = Size.padding.small },
        self:makeToggle("opponent_hints",      _("Opponent Hints")),
        VerticalSpan:new{ width = Size.padding.small },
        self:makeToggle("previous_move_hints", _("Previous Move Hints")),
        VerticalSpan:new{ width = Size.padding.small },
        self:makeToggle("check_hints",         _("Check Hints")),
        VerticalSpan:new{ width = Size.padding.small },
        self:makeToggle("rotate_top_pieces",   _("Invert Opponent Pieces")),
        VerticalSpan:new{ width = Size.padding.small },
        self:makeToggle("show_coordinates",    _("Board Coordinates")),
    }
end

function InterfaceWidget:applyValues(s)
    local board = self.parent and self.parent.board
    if not board then return end

    board.show_selected       = s.show_selected
    board.learning_mode       = s.learning_mode
    board.previous_move_hints = s.previous_move_hints
    board.opponent_hints      = s.opponent_hints
    board.check_hints         = s.check_hints
    board:setRotateTopPieces(s.rotate_top_pieces)
    board:setShowCoordinates(s.show_coordinates)

    if not board.learning_mode then
        board:clearValidMoves()
        board:clearPreviousMoveHints()
        board:clearCheckHint()
    end
    if board.learning_mode and board.check_hints then
        board:markCheckHint()
    else
        board:clearCheckHint()
    end
    if not board.show_selected and board.selected then
        board:unmarkSelected(board.selected)
    end
    board:updateBoard()
end

function InterfaceWidget:applyPreview()
    self:applyValues(self.changes)
end

function InterfaceWidget:assembleContent()
    local D = self.dialog
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
                dimen = Geometry:new{ w = D.width, h = self.optionsGroup:getSize().h },
                self.optionsGroup,
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
                    text     = _("Reset to Defaults"),
                    radius   = Size.radius.button,
                    padding  = Size.padding.small,
                    width    = math.floor(D.width * 0.8),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text        = _("Reset interface settings to defaults?"),
                            ok_text     = _("Reset"),
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

function InterfaceWidget:resetToDefaults()
    self.changes.show_selected       = true
    self.changes.learning_mode       = false
    self.changes.previous_move_hints = false
    self.changes.opponent_hints      = false
    self.changes.check_hints         = false
    self.changes.rotate_top_pieces   = false
    self.changes.show_coordinates    = false
    self.changes.thinking_indicator  = true
    self:saveAndClose()
end

function InterfaceWidget:saveAndClose()
    self:applyPreview()
    self.onSave(self.changes)
    UIManager:close(self.dialog)
end

return InterfaceWidget
