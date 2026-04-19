-- Shim for KoChess: adds alpha support for transparent chess piece icons.
--
-- Problem: stock Button:init() and ButtonTable:init() both ignore alpha.
-- Stock Button:init() creates IconWidget with alpha=false (flattens against white).
-- Stock ButtonTable:init() does not forward btn_entry.alpha to Button:new{}.
--
-- Fix: patch both Button:init() and ButtonTable:init() here, in one place,
-- so there is no dependency on load order or any other file requiring button.lua.

local ButtonTable = require("ui/widget/buttontable")
local Button      = require("ui/widget/button")
local IconWidget  = require("ui/widget/iconwidget")

-- -----------------------------------------------------------------------
-- Patch 1: Button:init() — rebuild IconWidget with alpha when self.alpha set.
-- Stock init() always creates IconWidget with alpha=false (default), which
-- causes KOReader to flatten the icon against white at cache time.
-- This patch runs every time a button is initialized or setIcon() is called
-- (setIcon calls self:init() internally).
-- -----------------------------------------------------------------------
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
        -- Re-seat inside frame -> label_container -> label_widget
        self.frame[1][1] = self.label_widget
    end
end

-- -----------------------------------------------------------------------
-- Patch 2: ButtonTable:init() — inject btn_entry.alpha into Button:new{}.
-- Stock ButtonTable:init() constructs each Button without forwarding alpha,
-- so the board's alpha=true entries would be silently ignored.
-- We temporarily wrap Button.new to inject the correct alpha by position,
-- matching the row-by-row, column-by-column order stock init uses.
--
-- Re-entrancy guard: stock ButtonTable:init() may call self:init() a second
-- time when shrink_unneeded_width triggers a layout pass. The outer wrapper
-- must remain active; the inner call must not install a second one.
-- -----------------------------------------------------------------------
local _orig_bt_init = ButtonTable.init
local _orig_btn_new = Button.new
local _patching     = false

function ButtonTable:init()
    if _patching then
        -- Inner re-entrant call: wrapper already active, just run stock init.
        _orig_bt_init(self)
        return
    end

    -- Build alpha queue: same row/column order stock ButtonTable:init() uses.
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

    -- Always restore, even on error.
    Button.new = _orig_btn_new
    _patching  = false

    if not ok then error(err) end
end

return ButtonTable
