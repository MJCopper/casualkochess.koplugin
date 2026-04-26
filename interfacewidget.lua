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
    return setmetatable({
        parent = opts.parent,
        onSave = opts.onSave,
        dialog = nil,
        changes = {
            show_selected = init.show_selected ~= false,
            learning_mode = init.learning_mode == true,
            previous_move_hints = init.previous_move_hints == true,
            opponent_hints = init.opponent_hints == true,
            check_hints = init.check_hints == true,
        },
    }, InterfaceWidget)
end

function InterfaceWidget:show()
    local dlg = InputDialog:new{
        title = _("Interface"),
        save_callback = function() self:saveAndClose() end,
        dismiss_callback = function() UIManager:close(self.dialog) end,
    }
    dlg.element_width = math.floor(dlg.width * 0.8)
    self.dialog = dlg

    self:buildOptions()
    self:assembleContent()

    dlg:refocusWidget()
    UIManager:show(dlg)
end

function InterfaceWidget:markDirty()
    if self.dialog._buttons_edit_callback then
        self.dialog:_buttons_edit_callback(true)
    end
    UIManager:setDirty(self.parent, "ui")
end

function InterfaceWidget:buttonLabel(key, label_text)
    return (self.changes[key] and "☑ " or "☐ ") .. label_text
end

function InterfaceWidget:makeToggle(key, label_text)
    local btn
    btn = ButtonWidget:new{
        text = self:buttonLabel(key, label_text),
        width = self.dialog.element_width,
        radius = Size.radius.button,
        padding = Size.padding.small,
        align = "left",
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
    local gap = VerticalSpan:new{ width = Size.padding.small }
    self.optionsGroup = VerticalGroup:new{
        width = self.dialog.element_width,
        self:makeToggle("show_selected", _("Highlight Selected")),
        gap,
        self:makeToggle("learning_mode", _("Player Hints")),
        VerticalSpan:new{ width = Size.padding.small },
        self:makeToggle("opponent_hints", _("Opponent Hints")),
        VerticalSpan:new{ width = Size.padding.small },
        self:makeToggle("previous_move_hints", _("Previous Move Hints")),
        VerticalSpan:new{ width = Size.padding.small },
        self:makeToggle("check_hints", _("Check Hints")),
    }
end

function InterfaceWidget:applyPreview()
    local board = self.parent and self.parent.board
    if not board then return end

    board.show_selected = self.changes.show_selected
    board.learning_mode = self.changes.learning_mode
    board.previous_move_hints = self.changes.previous_move_hints
    board.opponent_hints = self.changes.opponent_hints
    board.check_hints = self.changes.check_hints

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
end

function InterfaceWidget:assembleContent()
    local D = self.dialog
    local content = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        background = BACKGROUND_COLOR,
        padding = 0,
        margin = 0,

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
                    text = _("Reset to Defaults"),
                    radius = Size.radius.button,
                    padding = Size.padding.small,
                    width = math.floor(D.width * 0.8),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = _("Reset interface settings to defaults?"),
                            ok_text = _("Reset"),
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
    self.changes.show_selected = true
    self.changes.learning_mode = false
    self.changes.previous_move_hints = false
    self.changes.opponent_hints = false
    self.changes.check_hints = false
    self:saveAndClose()
end

function InterfaceWidget:saveAndClose()
    self:applyPreview()
    self.onSave(self.changes)
    UIManager:close(self.dialog)
end

return InterfaceWidget
