-- board.lua
local _ = require("gettext")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("buttontable")
local FrameContainer = require("ui/widget/container/framecontainer")
local Chess = require("chess/src/chess")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")

local BOARD_SIZE = 8
local SELECTED_BORDER = 5

local icons = {
    empty = "casualchess/empty", 
    [Chess.PAWN]   = { [Chess.WHITE] = "casualchess/wP", [Chess.BLACK] = "casualchess/bP" },
    [Chess.KNIGHT] = { [Chess.WHITE] = "casualchess/wN", [Chess.BLACK] = "casualchess/bN" },
    [Chess.BISHOP] = { [Chess.WHITE] = "casualchess/wB", [Chess.BLACK] = "casualchess/bB" },
    [Chess.ROOK]   = { [Chess.WHITE] = "casualchess/wR", [Chess.BLACK] = "casualchess/bR" },
    [Chess.QUEEN]  = { [Chess.WHITE] = "casualchess/wQ", [Chess.BLACK] = "casualchess/bQ" },
    [Chess.KING]   = { [Chess.WHITE] = "casualchess/wK", [Chess.BLACK] = "casualchess/bK" },
}

local Board = FrameContainer:extend{
    game = nil,
    width = 250,
    height = 250,
    moveCallback = nil,
    holdCallback = nil,
    onPromotionNeeded = nil,
    bordersize = 0,
    padding = 0,
    background = Blitbuffer.COLOR_WHITE,
    -- Padding around the board (top, left, right only — bottom flush with log)
    board_padding = nil,  -- set in init from Screen:scaleBySize(8)
}

function Board:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function Board:init()
    if not self.game then
        error("Kochess Board: must be initialized with a Game object")
        return
    end

    local margins = self:allMarginSizes()
    -- ButtonTable forces padding = Size.padding.buttontable on every button.
    -- button_size is the ICON size = cell - 2*bt_pad, so that the rendered
    -- button (icon + 2*padding) exactly fills the cell.
    -- ButtonTable forces padding independently per axis:
    --   horizontal: Size.padding.button   = scaleBySize(2) (small)
    --   vertical:   Size.padding.buttontable = scaleBySize(4) (larger)
    -- button width  = cell (ButtonTable treats width as TOTAL, no extra padding added)
    -- button height = cell (icon_height + 2*pad_v = cell, so icon_height = cell - 2*pad_v)
    local bt_pad_v = Screen:scaleBySize(4)  -- Size.padding.buttontable (vertical)
    self.board_padding = Screen:scaleBySize(8)
    -- Subtract padding from usable area before computing cell size
    local usable_w = self.width  - 2 * self.board_padding
    local usable_h = self.height - self.board_padding  -- no bottom padding
    local cell = math.min(
        math.floor(usable_w / BOARD_SIZE) - margins.w,
        math.floor(usable_h / BOARD_SIZE) - margins.h
    )
    self.button_size  = cell
    self.icon_height  = cell - 2 * bt_pad_v

    self.selected = nil

    local grid = {}
    for rank = BOARD_SIZE - 1, 0, -1 do 
        local row = {}
        for file = 0, BOARD_SIZE - 1 do 
            table.insert(row, self:createSquareButton(file, rank))
        end
        table.insert(grid, row)
    end

    local table_size = cell * BOARD_SIZE  -- cell includes padding
    self.table = ButtonTable:new{
        width = table_size,
        buttons = grid,
        shrink_unneeded_width = false,
        zero_sep = true,
        sep_width = 0,
        addVerticalSpan = function() end,
    }

    self:applySquareColors()
    -- Centre the table horizontally and apply top/left/right padding
    local CenterContainer = require("ui/widget/container/centercontainer")
    local padded = FrameContainer:new{
        bordersize     = 0,
        background     = self.background,
        padding        = 0,
        padding_top    = self.board_padding,
        padding_left   = 0,
        padding_right  = 0,
        padding_bottom = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = cell * BOARD_SIZE + self.board_padding },
            self.table,
        },
    }
    self[1] = padded

end

function Board:createSquareButton(file, rank)
    return {
        id = Board.toId(file, rank),
        icon = icons.empty,
        alpha = true,
        width      = self.button_size,   -- total button width = cell (fills width exactly)
        icon_width = self.button_size,
        icon_height = self.icon_height,  -- smaller so button height = cell after padding
        bordersize = Screen:scaleBySize(SELECTED_BORDER),
        margin = 0,
        padding = 0,
        allow_hold_when_disabled = true,
        callback = function() self:handleClick(file, rank) end,
        hold_callback = self.holdCallback,
    }
end

function Board:applySquareColors()
    for rank = 0, BOARD_SIZE - 1 do
        for file = 0, BOARD_SIZE - 1 do
            local button = self.table:getButtonById(Board.toId(file, rank))
            local color = ((file + rank) % 2 == 1)
                and Blitbuffer.COLOR_LIGHT_GRAY
                or Blitbuffer.COLOR_DARK_GRAY
            
            button.frame.background = color
            button.frame.border_color = color
        end
    end
end

-- Click handling
function Board:handleClick(file, rank)
    local id = Board.toId(file, rank)
    local square = Board.idToPosition(id) 

    -- Block interaction if not human
    if self.game and self.game.is_human and (not self.game.is_human(self.game.turn())) then

        -- clear any stale selection
        if self.selected then
            self:unmarkSelected(self.selected)
            self.selected = nil
        end
        return
    end

    local clicked_piece = self.game.get(square)
    local is_my_piece = clicked_piece and (clicked_piece.color == self.game.turn())

    if self.selected then
        if self.selected == square then
            -- deselect
            self:unmarkSelected(square)
            self.selected = nil

        elseif is_my_piece then
            -- switch selection
            self:unmarkSelected(self.selected)
            self.selected = square
            self:markSelected(square)

        else
            -- attempt move
            self:handleMove(self.selected, square)
        end
    else
        -- select piece
        if is_my_piece then

            self.selected = square
            self:markSelected(square)
        end
    end
end

function Board:handleMove(from, to)
    self.selected = nil 

    local piece = self.game.get(from) 

    local is_pawn_promotion = false
    if piece and piece.type == Chess.PAWN then
        local to_rank_num = tonumber(to:sub(2, 2)) 
        if (piece.color == Chess.WHITE and to_rank_num == 8) or
           (piece.color == Chess.BLACK and to_rank_num == 1) then
            is_pawn_promotion = true
        end
    end

    if is_pawn_promotion and self.onPromotionNeeded then
        self:unmarkSelected(from)
        self.onPromotionNeeded(from, to, piece.color)
    else
        local move = self.game.move{ from = from, to = to }
        if move then
            self:handleGameMove(move)
        else

            self:unmarkSelected(from)
            self:updateBoard()
        end
    end
end

function Board:handleGameMove(move)
    if not move then return end 

    self:updateSquare(move.from) 
    self:updateSquare(move.to)   

    self:handleMoveFlags(move, move.to)

    if self.moveCallback then
        self.moveCallback(move) 
    end
end

function Board:handleMoveFlags(move, to)
    if not move.flags then return end

    local to_id_result = Board.chessToId(to)
    if not to_id_result then return end
    local to_id = to_id_result

    if move.flags == Chess.FLAGS.EP_CAPTURE then
        local captured_pawn_rank_offset = (move.color == Chess.BLACK and 1 or -1)
        local captured_pawn_id = to_id + captured_pawn_rank_offset * BOARD_SIZE 
        local captured_pawn_square_result = Board.idToPosition(captured_pawn_id)
        if captured_pawn_square_result then
            self:updateSquare(captured_pawn_square_result)
        end
    elseif move.flags == Chess.FLAGS.KSIDE_CASTLE then
        local rook_from_file_id = 7 
        local rook_to_file_id = 5 
        local rank_index = (move.color == Chess.WHITE and 0 or 7) 
        self:updateSquare(Board.idToPosition(Board.toId(rook_from_file_id, rank_index)))
        self:updateSquare(Board.idToPosition(Board.toId(rook_to_file_id, rank_index)))
    elseif move.flags == Chess.FLAGS.QSIDE_CASTLE then
        local rook_from_file_id = 0 
        local rook_to_file_id = 3 
        local rank_index = (move.color == Chess.WHITE and 0 or 7) 
        self:updateSquare(Board.idToPosition(Board.toId(rook_from_file_id, rank_index)))
        self:updateSquare(Board.idToPosition(Board.toId(rook_to_file_id, rank_index)))
    end
end

-- Visual updates
function Board:markSelected(square)
    local id_result = Board.chessToId(square)
    if not id_result then return end
    local button = self.table:getButtonById(id_result)

    button.frame.background = Blitbuffer.COLOR_WHITE
    button.frame.border_color = Blitbuffer.COLOR_BLACK

    UIManager:setDirty(self, "ui")
end

function Board:unmarkSelected(square)
    local id_result = Board.chessToId(square)
    if not id_result then return end
    local button = self.table:getButtonById(id_result)

    -- restore original square color
    local original_color = Board.positionToColor(square)
    button.frame.background = original_color
    button.frame.border_color = original_color

    UIManager:setDirty(self, "ui")
end

function Board:placePiece(square, piece, color)
    local icon = (piece and icons[piece] and icons[piece][color]) or icons.empty
    local id_result = Board.chessToId(square)
    if not id_result then return end

    local button = self.table:getButtonById(id_result)
    button:setIcon(icon, self.button_size)

    -- restore square color after icon set
    local original_color = Board.positionToColor(square)
    button.frame.background = original_color
    button.frame.border_color = original_color

    UIManager:setDirty(self, "ui")
end

function Board:updateSquare(square)
    local piece = self.game.get(square)
    if piece then
        self:placePiece(square, piece.type, piece.color)
    else
        self:placePiece(square) 
    end
end

function Board:updateBoard()
    local board_fen = self.game.board()
    for file_idx = 0, BOARD_SIZE - 1 do
        for rank_idx = 0, BOARD_SIZE - 1 do
            local element = board_fen[BOARD_SIZE - rank_idx][file_idx + 1]
            local square = Board.idToPosition(Board.toId(file_idx, rank_idx))
            if element then
                self:placePiece(square, element.type, element.color)
            else
                self:placePiece(square)
            end
        end
    end
    UIManager:setDirty(self, "ui")
end

function Board.toId(file, rank) return file * BOARD_SIZE + rank + 1 end

function Board.chessToId(position)
    if type(position) == "string" and #position == 2 then
        local file_char = position:sub(1, 1)
        local rank_char = position:sub(2, 2)
        if 'a' <= file_char and file_char <= 'h' and '1' <= rank_char and rank_char <= '8' then
            local file_idx = string.byte(file_char) - string.byte('a')
            local rank_idx = tonumber(rank_char) - 1
            return Board.toId(file_idx, rank_idx)
        end
    end
    return nil
end

function Board.idToPosition(id)
    if type(id) == "number" and id >= 1 and id <= BOARD_SIZE * BOARD_SIZE then
        local zero_id = id - 1  -- convert back to 0-based for decomposition
        local file_idx = math.floor(zero_id / BOARD_SIZE)
        local rank_idx = zero_id % BOARD_SIZE
        local file_char = string.char(file_idx + string.byte('a'))
        local rank_char = tostring(rank_idx + 1)
        return file_char .. rank_char
    end
    return nil
end

function Board.positionToColor(position)
    if type(position) == "string" and #position == 2 then
        local file_char = position:sub(1, 1)
        local rank_char = position:sub(2, 2)
        if 'a' <= file_char and file_char <= 'h' and '1' <= rank_char and rank_char <= '8' then
            local file_idx = string.byte(file_char) - string.byte('a')
            local rank_idx = tonumber(rank_char) - 1
            return (file_idx + rank_idx) % 2 == 1 and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_DARK_GRAY
        end
    end
    return nil 
end

function Board:allMarginSizes()
    self._padding_top = self.padding_top or self.padding
    self._padding_right = self.padding_right or self.padding
    self._padding_bottom = self.padding_bottom or self.padding
    self._padding_left = self.padding_left or self.padding
    return Geom:new{
        w = (self.margin + self.bordersize) * 2 + self._padding_right + self._padding_left,
        h = (self.margin + self.bordersize) * 2 + self._padding_top + self._padding_bottom,
    }
end

return Board