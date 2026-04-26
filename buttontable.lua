-- KOReader's stock Button/ButtonTable do not pass alpha through to IconWidget,
-- so transparent chess SVGs would be flattened against white.

local ButtonTable = require("ui/widget/buttontable")
local Button      = require("ui/widget/button")
local IconWidget  = require("ui/widget/iconwidget")

local _orig_btn_init = Button.init

function Button:init()
    _orig_btn_init(self)
    if self.icon and self.alpha and self.label_widget then
        self.label_widget:free()
        self.label_widget = IconWidget:new{
            icon           = self.icon,
            alpha          = self.alpha,
            rotation_angle = self.icon_rotation_angle,
            dim            = not self.enabled,
            width          = self.icon_width,
            height         = self.icon_height,
        }
        self.frame[1][1] = self.label_widget
    end
end

local _orig_bt_init = ButtonTable.init
local _orig_btn_new = Button.new
local _patching     = false

function ButtonTable:init()
    if _patching then
        _orig_bt_init(self)
        return
    end

    -- Match the row/column order used by ButtonTable:init().
    local alpha_queue = {}
    for _, row in ipairs(self.buttons or {}) do
        for _, entry in ipairs(row) do
            table.insert(alpha_queue, entry.alpha)
        end
    end

    local call_count = 0
    _patching = true

    Button.new = function(cls, opts)
        call_count = call_count + 1
        local alpha = alpha_queue[call_count]
        if alpha ~= nil and opts then
            opts.alpha = alpha
        end
        return _orig_btn_new(cls, opts)
    end

    local ok, err = pcall(_orig_bt_init, self)

    Button.new = _orig_btn_new
    _patching  = false

    if not ok then error(err) end
end

return ButtonTable
