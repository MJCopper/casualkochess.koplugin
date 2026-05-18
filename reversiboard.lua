local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("buttontable")
local FrameContainer = require("ui/widget/container/framecontainer")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local IconWidget = require("ui/widget/iconwidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Reversi = require("reversigame")

local _PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("@(.+)/[^/]+%.lua$") or "."

local BOARD_SIZE = 8
local SELECTED_BORDER = 5

local icons = {
    empty = "casualchess/empty",
    [Reversi.DISC] = {
        [Reversi.WHITE] = "casualchess/reversi_white",
        [Reversi.BLACK] = "casualchess/reversi_black",
    },
}

local Board = FrameContainer:extend{
    game = nil,
    width = 250,
    height = 250,
    moveCallback = nil,
    bordersize = 0,
    padding = 0,
    background = Blitbuffer.COLOR_WHITE,
    board_padding = nil,
    flipped = false,
    rotate_top_pieces = false,
    show_coordinates = false,
    learning_mode = false,
    show_selected = true,
    previous_move_hints = false,
    opponent_hints = false,
    selected = nil,
    _peek_square = nil,
    _hint_squares = nil,
    _previous_move_squares = nil,
}

function Board:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function Board:init()
    if not self.game then error("Reversi Board: must be initialized with a Game object") end

    local margins = self:allMarginSizes()
    local bt_pad_v = Screen:scaleBySize(4)
    self.board_padding = Screen:scaleBySize(8)
    local coord_size = self.show_coordinates and Screen:scaleBySize(16) or 0
    local usable_w = self.width - 2 * self.board_padding
    local usable_h = self.height - self.board_padding
    local cell = math.min(
        math.floor((usable_w - 2 * coord_size) / BOARD_SIZE) - margins.w,
        math.floor((usable_h - 2 * coord_size) / BOARD_SIZE) - margins.h
    )
    self.button_size = cell
    self.icon_height = cell - 2 * bt_pad_v
    self.selected = nil
    self._peek_square = nil
    self._hint_squares = {}
    self._previous_move_squares = nil

    local rank_start, rank_stop, rank_step = BOARD_SIZE - 1, 0, -1
    local file_start, file_stop, file_step = 0, BOARD_SIZE - 1, 1
    if self.flipped then
        rank_start, rank_stop, rank_step = 0, BOARD_SIZE - 1, 1
        file_start, file_stop, file_step = BOARD_SIZE - 1, 0, -1
    end

    local grid = {}
    for rank = rank_start, rank_stop, rank_step do
        local row = {}
        for file = file_start, file_stop, file_step do
            row[#row + 1] = self:createSquareButton(file, rank)
        end
        grid[#grid + 1] = row
    end

    self.table = ButtonTable:new{
        width = cell * BOARD_SIZE,
        buttons = grid,
        shrink_unneeded_width = false,
        zero_sep = true,
        sep_width = 0,
        addVerticalSpan = function() end,
    }

    self:applySquareColors()
    local CenterContainer = require("ui/widget/container/centercontainer")
    local ts = self.table:getSize()

    local inner_widget = self.table

    if self.show_coordinates then
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local VerticalSpan    = require("ui/widget/verticalspan")
        local ImageWidget     = require("ui/widget/imagewidget")
        local file_letters = {"a","b","c","d","e","f","g","h"}

        local corner = function()
            return VerticalSpan:new{ width = coord_size }
        end

        local function make_label(name, w, h, rotated)
            local suffix = rotated and "_rot" or ""
            local path = _PLUGIN_DIR .. "/icons/coord_" .. name .. suffix .. ".svg"
            return CenterContainer:new{
                dimen = Geom:new{ w = w, h = h },
                ImageWidget:new{
                    file         = path,
                    width        = coord_size,
                    height       = coord_size,
                    scale_factor = 0,
                    alpha        = true,
                },
            }
        end

        local function make_file_row(rotated)
            local children = { corner() }
            for file_idx = file_start, file_stop, file_step do
                children[#children + 1] = make_label(
                    file_letters[file_idx + 1], cell, coord_size, rotated)
            end
            children[#children + 1] = corner()
            return HorizontalGroup:new(children)
        end

        local function make_rank_col(rotated)
            local children = {}
            for rank_idx = rank_start, rank_stop, rank_step do
                children[#children + 1] = make_label(
                    tostring(rank_idx + 1), coord_size, cell, rotated)
            end
            return VerticalGroup:new(children)
        end

        local rot = self.rotate_top_pieces
        local middle_row = HorizontalGroup:new{ align = "top",
            make_rank_col(false),
            self.table,
            make_rank_col(rot),
        }
        inner_widget = VerticalGroup:new{ align = "center",
            make_file_row(rot),
            middle_row,
            make_file_row(false),
        }
    end

    local inner_h = ts.h + 2 * coord_size
    self[1] = FrameContainer:new{
        bordersize = 0,
        background = self.background,
        padding = 0,
        padding_top = self.board_padding,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = inner_h + self.board_padding },
            inner_widget,
        },
    }
end

function Board:setFlipped(flipped)
    flipped = flipped and true or false
    if self.flipped == flipped then return end
    self.flipped = flipped
    self:init()
    self:updateBoard()
end

function Board:setRotateTopPieces(rotate_top_pieces)
    rotate_top_pieces = rotate_top_pieces and true or false
    if self.rotate_top_pieces == rotate_top_pieces then return end
    self.rotate_top_pieces = rotate_top_pieces
    if self.show_coordinates then self:init() end
    self:updateBoard()
end

function Board:setShowCoordinates(show_coordinates)
    show_coordinates = show_coordinates and true or false
    if self.show_coordinates == show_coordinates then return end
    self.show_coordinates = show_coordinates
    self:init()
    self:updateBoard()
end

function Board:createSquareButton(file, rank)
    return {
        id = Board.toId(file, rank),
        icon = icons.empty,
        alpha = true,
        width = self.button_size,
        icon_width = self.button_size,
        icon_height = self.icon_height,
        bordersize = Screen:scaleBySize(SELECTED_BORDER),
        margin = 0,
        padding = 0,
        callback = function() self:handleClick(file, rank) end,
    }
end

function Board:applySquareColors()
    for rank = 0, BOARD_SIZE - 1 do
        for file = 0, BOARD_SIZE - 1 do
            local button = self.table:getButtonById(Board.toId(file, rank))
            local color = Board.positionToColor(Board.idToPosition(Board.toId(file, rank)))
            button.frame.background = color
            button.frame.border_color = color
        end
    end
end

local function overlayIcon(button, purpose, icon_name, w, h)
    local label_container = button.frame[1]
    if not label_container or not label_container[1] then return end
    local orig = label_container[1]
    local og = orig
    if not og._is_overlay then
        og = OverlapGroup:new{ dimen = Geom:new{ w = w, h = h }, orig }
        og._is_overlay = true
        og._orig_widget = orig
        og._overlay_icons = {}
        og._overlay_w = w
        og._overlay_h = h
        label_container[1] = og
    end
    og._overlay_icons[purpose] = icon_name
    for i = #og, 2, -1 do og[i] = nil end
    for _, name in pairs(og._overlay_icons) do
        og[#og + 1] = IconWidget:new{ icon = name, alpha = true, width = w, height = h, is_icon = true }
    end
end

local function clearOverlay(button, purpose)
    local label_container = button.frame[1]
    if not label_container then return end
    local og = label_container[1]
    if not (og and og._is_overlay) then return end
    og._overlay_icons[purpose] = nil
    for _, _ in pairs(og._overlay_icons) do
        for i = #og, 2, -1 do og[i] = nil end
        for _, name in pairs(og._overlay_icons) do
            og[#og + 1] = IconWidget:new{ icon = name, alpha = true, width = og._overlay_w, height = og._overlay_h, is_icon = true }
        end
        return
    end
    label_container[1] = og._orig_widget
end

function Board:handleClick(file, rank)
    if not self.game:is_human(self.game:turn()) then return end
    local sq = Board.idToPosition(Board.toId(file, rank))
    local piece = self.game:get(sq)

    if self._peek_square then
        self:unmarkSelected(self._peek_square)
        self._peek_square = nil
    end

    if piece and piece.color ~= self.game:turn() and self.learning_mode and self.opponent_hints then
        self:clearValidMoves()
        self:clearPreviousMoveHints()
        self._peek_square = sq
        self:markSelected(sq)
        self:markValidMoves(piece.color)
        return
    end

    self:clearPreviousMoveHints()
    local move = self.game:move{ to = sq }
    if move then
        self:clearValidMoves()
        self:handleGameMove(move)
        return
    end

    self:clearValidMoves()
    if self.learning_mode then self:markValidMoves(self.game:turn()) end
end

function Board:markSelected(sq)
    if not self.show_selected and not self.learning_mode then return end
    local id = Board.chessToId(sq)
    if id then overlayIcon(self.table:getButtonById(id), "selected", "casualchess/select", self.button_size, self.icon_height) end
    UIManager:setDirty("all", "ui")
end

function Board:unmarkSelected(sq)
    local id = Board.chessToId(sq)
    if id then clearOverlay(self.table:getButtonById(id), "selected") end
    UIManager:setDirty("all", "ui")
end

function Board:markValidMoves(color)
    self._hint_squares = {}
    if not self.learning_mode then return end
    for _, move in ipairs(self.game:moves({ color = color or self.game:turn(), verbose = true })) do
        local id = Board.chessToId(move.to)
        if id then
            overlayIcon(self.table:getButtonById(id), "hint", "casualchess/hint", self.button_size, self.icon_height)
            self._hint_squares[#self._hint_squares + 1] = move.to
        end
    end
    UIManager:setDirty("all", "ui")
end

function Board:clearValidMoves()
    if self._peek_square then
        local id = Board.chessToId(self._peek_square)
        if id then clearOverlay(self.table:getButtonById(id), "selected") end
    end
    self._peek_square = nil
    for _, sq in ipairs(self._hint_squares or {}) do
        local id = Board.chessToId(sq)
        if id then clearOverlay(self.table:getButtonById(id), "hint") end
    end
    self._hint_squares = {}
    UIManager:setDirty("all", "ui")
end

function Board:clearPreviousMoveHints()
    if not self._previous_move_squares then return end
    for _, item in ipairs(self._previous_move_squares) do
        local id = Board.chessToId(item.sq)
        if id then clearOverlay(self.table:getButtonById(id), item.purpose) end
    end
    self._previous_move_squares = nil
    UIManager:setDirty("all", "ui")
end

function Board:markPreviousMove(move)
    self:clearPreviousMoveHints()
    if not (self.learning_mode and self.previous_move_hints and move) then return end
    self._previous_move_squares = {}
    local id = Board.chessToId(move.to)
    if id then
        overlayIcon(self.table:getButtonById(id), "previous", "casualchess/hint", self.button_size, self.icon_height)
        self._previous_move_squares[#self._previous_move_squares + 1] = { sq = move.to, purpose = "previous" }
    end
    for _, sq in ipairs(move.flips or {}) do
        local flip_id = Board.chessToId(sq)
        if flip_id then
            overlayIcon(self.table:getButtonById(flip_id), "previous_path", "casualchess/hint_path", self.button_size, self.icon_height)
            self._previous_move_squares[#self._previous_move_squares + 1] = { sq = sq, purpose = "previous_path" }
        end
    end
    UIManager:setDirty("all", "ui")
end

function Board:clearCheckHint()
end

function Board:markCheckHint()
end

function Board:handleGameMove(move)
    self:updateBoard()
    self:markPreviousMove(move)
    if self.moveCallback then self.moveCallback(move) end
end

function Board:placePiece(sq, piece, color)
    local id = Board.chessToId(sq)
    if not id then return end
    local piece_icons = piece and icons[piece]
    local icon = (piece_icons and piece_icons[color]) or icons.empty
    local button = self.table:getButtonById(id)
    button:setIcon(icon, self.button_size)
    local color_value = Board.positionToColor(sq)
    button.frame.background = color_value
    button.frame.border_color = color_value
end

function Board:updateSquare(sq)
    local piece = self.game:get(sq)
    if piece then self:placePiece(sq, piece.type, piece.color) else self:placePiece(sq) end
end

function Board:updateBoard()
    for file = 0, BOARD_SIZE - 1 do
        for rank = 0, BOARD_SIZE - 1 do
            self:updateSquare(Board.idToPosition(Board.toId(file, rank)))
        end
    end
    self:clearValidMoves()
    if self.game:is_human(self.game:turn()) then self:markValidMoves(self.game:turn()) end
    UIManager:setDirty(self, "ui")
end

function Board.toId(file, rank)
    return file * BOARD_SIZE + rank + 1
end

function Board.chessToId(position)
    if type(position) == "string" and #position == 2 then
        local file = string.byte(position:sub(1, 1)) - string.byte("a")
        local rank = tonumber(position:sub(2, 2)) - 1
        if file >= 0 and file < BOARD_SIZE and rank >= 0 and rank < BOARD_SIZE then return Board.toId(file, rank) end
    end
end

function Board.idToPosition(id)
    local zero_id = id - 1
    local file = math.floor(zero_id / BOARD_SIZE)
    local rank = zero_id % BOARD_SIZE
    return string.char(string.byte("a") + file) .. tostring(rank + 1)
end

function Board.positionToColor(position)
    local id = Board.chessToId(position)
    local file = math.floor((id - 1) / BOARD_SIZE)
    local rank = (id - 1) % BOARD_SIZE
    return (file + rank) % 2 == 0 and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_LIGHT_GRAY
end

function Board:allMarginSizes()
    self._padding_top = self.padding_top or self.padding
    self._padding_right = self.padding_right or self.padding
    self._padding_bottom = self.padding_bottom or self.padding
    self._padding_left = self.padding_left or self.padding
    return {
        w = (self.margin + self.bordersize) * 2 + self._padding_left + self._padding_right,
        h = (self.margin + self.bordersize) * 2 + self._padding_top + self._padding_bottom,
    }
end

return Board
