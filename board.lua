local _ = require("gettext")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("buttontable")
local FrameContainer = require("ui/widget/container/framecontainer")
local Chess = require("chess/src/chess")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")

local OverlapGroup = require("ui/widget/overlapgroup")
local IconWidget   = require("ui/widget/iconwidget")

local BOARD_SIZE = 8
local SELECTED_BORDER = 5

local icons = {
    empty = "casualchess/empty", 
    [Chess.PAWN]   = { [Chess.WHITE] = "casualchess/wP", [Chess.BLACK] = "casualchess/bP", rotated = { [Chess.WHITE] = "casualchess/wP_rot", [Chess.BLACK] = "casualchess/bP_rot" } },
    [Chess.KNIGHT] = { [Chess.WHITE] = "casualchess/wN", [Chess.BLACK] = "casualchess/bN", rotated = { [Chess.WHITE] = "casualchess/wN_rot", [Chess.BLACK] = "casualchess/bN_rot" } },
    [Chess.BISHOP] = { [Chess.WHITE] = "casualchess/wB", [Chess.BLACK] = "casualchess/bB", rotated = { [Chess.WHITE] = "casualchess/wB_rot", [Chess.BLACK] = "casualchess/bB_rot" } },
    [Chess.ROOK]   = { [Chess.WHITE] = "casualchess/wR", [Chess.BLACK] = "casualchess/bR", rotated = { [Chess.WHITE] = "casualchess/wR_rot", [Chess.BLACK] = "casualchess/bR_rot" } },
    [Chess.QUEEN]  = { [Chess.WHITE] = "casualchess/wQ", [Chess.BLACK] = "casualchess/bQ", rotated = { [Chess.WHITE] = "casualchess/wQ_rot", [Chess.BLACK] = "casualchess/bQ_rot" } },
    [Chess.KING]   = { [Chess.WHITE] = "casualchess/wK", [Chess.BLACK] = "casualchess/bK", rotated = { [Chess.WHITE] = "casualchess/wK_rot", [Chess.BLACK] = "casualchess/bK_rot" } },
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
    board_padding = nil,
    learning_mode  = false,
    show_selected  = true,
    previous_move_hints = false,
    opponent_hints = false,
    check_hints = false,
    flipped = false,
    rotate_top_pieces = false,
    _hint_squares  = nil,
    _previous_move_squares = nil,
    _check_square = nil,
    _peek_square = nil,
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
    -- ButtonTable applies vertical padding inside each square; keep icons square.
    local bt_pad_v = Screen:scaleBySize(4)
    self.board_padding = Screen:scaleBySize(8)
    local usable_w = self.width  - 2 * self.board_padding
    local usable_h = self.height - self.board_padding
    local cell = math.min(
        math.floor(usable_w / BOARD_SIZE) - margins.w,
        math.floor(usable_h / BOARD_SIZE) - margins.h
    )
    self.button_size  = cell
    self.icon_height  = cell - 2 * bt_pad_v

    self.selected = nil

    local grid = {}
    local rank_start, rank_stop, rank_step = BOARD_SIZE - 1, 0, -1
    local file_start, file_stop, file_step = 0, BOARD_SIZE - 1, 1
    if self.flipped then
        rank_start, rank_stop, rank_step = 0, BOARD_SIZE - 1, 1
        file_start, file_stop, file_step = BOARD_SIZE - 1, 0, -1
    end

    for rank = rank_start, rank_stop, rank_step do
        local row = {}
        for file = file_start, file_stop, file_step do
            table.insert(row, self:createSquareButton(file, rank))
        end
        table.insert(grid, row)
    end

    local table_size = cell * BOARD_SIZE
    self.table = ButtonTable:new{
        width = table_size,
        buttons = grid,
        shrink_unneeded_width = false,
        zero_sep = true,
        sep_width = 0,
        addVerticalSpan = function() end,
    }

    self:applySquareColors()
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

function Board:setFlipped(flipped)
    flipped = flipped and true or false
    if self.flipped == flipped then return end
    self.flipped = flipped
    self.selected = nil
    self._hint_squares = nil
    self._previous_move_squares = nil
    self._check_square = nil
    self._peek_square = nil
    self:init()
    self:updateBoard()
end

function Board:setRotateTopPieces(rotate_top_pieces)
    rotate_top_pieces = rotate_top_pieces and true or false
    if self.rotate_top_pieces == rotate_top_pieces then return end
    self.rotate_top_pieces = rotate_top_pieces
    self:updateBoard()
end

function Board:createSquareButton(file, rank)
    return {
        id = Board.toId(file, rank),
        icon = icons.empty,
        alpha = true,
        width      = self.button_size,
        icon_width = self.button_size,
        icon_height = self.icon_height,
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

function Board:handleClick(file, rank)
    local id = Board.toId(file, rank)
    local square = Board.idToPosition(id) 

    if self._peek_square then
        self:unmarkSelected(self._peek_square)
        self:clearValidMoves()
        self._peek_square = nil
    end
    self:clearCheckHint()

    if self.game and self.game.is_human and (not self.game.is_human(self.game.turn())) then
        if self.selected then
            self:unmarkSelected(self.selected)
            self.selected = nil
        end
        return
    end

    local clicked_piece = self.game.get(square)
    local is_my_piece = clicked_piece and (clicked_piece.color == self.game.turn())
    local can_peek_opponent = clicked_piece
        and not is_my_piece
        and self.learning_mode
        and self.opponent_hints

    if self.selected then
        if self.selected == square then
            self:unmarkSelected(square)
            self:clearValidMoves()
            self.selected = nil

        elseif is_my_piece then
            self:unmarkSelected(self.selected)
            self:clearValidMoves()
            self.selected = square
            self:markSelected(square)
            self:markValidMoves(square)

        elseif can_peek_opponent and not self:isLegalMoveTarget(self.selected, square) then
            self:unmarkSelected(self.selected)
            self:clearValidMoves()
            self:clearPreviousMoveHints()
            self.selected = nil
            self._peek_square = square
            self:markSelected(square)
            self:markValidMoves(square)

        else
            self:clearValidMoves()
            self:handleMove(self.selected, square)
        end
    else
        if is_my_piece then
            self:clearPreviousMoveHints()
            self.selected = square
            self:markSelected(square)
            self:markValidMoves(square)
        elseif can_peek_opponent then
            self:clearPreviousMoveHints()
            self._peek_square = square
            self:markSelected(square)
            self:markValidMoves(square)
        end
    end
end

function Board:isLegalMoveTarget(from, to)
    local moves = self.game.moves({ verbose = true, square = from })
    if not moves then return false end
    for _, move in ipairs(moves) do
        if move.to == to then
            return true
        end
    end
    return false
end

function Board:handleMove(from, to)
    self.selected = nil
    self:clearValidMoves()

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
    self:markPreviousMove(move)
    self:markCheckHint()

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

local OVERLAY_ORDER = { "previous", "check", "selected", "hint" }

local function newOverlayIcon(icon_name, w, h)
    return IconWidget:new{
        icon        = icon_name,
        alpha       = true,
        width       = w,
        height      = h,
        is_icon     = true,
    }
end

local function rebuildOverlayGroup(og, w, h)
    for i = #og, 2, -1 do
        og[i] = nil
    end
    for _, purpose in ipairs(OVERLAY_ORDER) do
        local icon_name = og._overlay_icons[purpose]
        if icon_name then
            og[#og + 1] = newOverlayIcon(icon_name, w, h)
        end
    end
end

local function overlayIcon(button, purpose, icon_name, w, h)
    local label_container = button.frame[1]
    if not label_container then return end
    local orig = label_container[1]
    if not orig then return end
    local og = orig

    if not og._is_overlay then
        og = OverlapGroup:new{
            dimen = Geom:new{ w = w, h = h },
            orig,
        }
        og._is_overlay = true
        og._orig_widget = orig
        og._overlay_icons = {}
        og._overlay_w = w
        og._overlay_h = h
        label_container[1] = og
    end

    og._overlay_icons[purpose] = icon_name
    rebuildOverlayGroup(og, w, h)
end

local function clearOverlay(button, purpose)
    local label_container = button.frame[1]
    if not label_container then return end
    local og = label_container[1]
    if og and og._is_overlay then
        if purpose then
            og._overlay_icons[purpose] = nil
        else
            og._overlay_icons = {}
        end

        for _, p in ipairs(OVERLAY_ORDER) do
            if og._overlay_icons[p] then
                rebuildOverlayGroup(og, og._overlay_w, og._overlay_h)
                return
            end
        end

        label_container[1] = og._orig_widget
    end
end

function Board:markSelected(square)
    local id_result = Board.chessToId(square)
    if not id_result then return end
    if not self.show_selected and not self.learning_mode then return end
    local button = self.table:getButtonById(id_result)
    overlayIcon(button, "selected", "casualchess/select", self.button_size, self.icon_height)
    UIManager:setDirty("all", "ui")
end

function Board:unmarkSelected(square)
    local id_result = Board.chessToId(square)
    if not id_result then return end
    local button = self.table:getButtonById(id_result)
    clearOverlay(button, "selected")
    UIManager:setDirty("all", "ui")
end

function Board:getLegalMovesForSquare(square)
    local piece = self.game.get(square)
    if not piece then return {} end
    if piece.color == self.game.turn() then
        return self.game.moves({ verbose = true, square = square })
    end
    if not (self.learning_mode and self.opponent_hints) then return {} end
    return self:getOpponentPotentialMoves(square, piece)
end

local function squareFromCoords(file, rank)
    if file < 1 or file > 8 or rank < 1 or rank > 8 then return nil end
    return string.char(string.byte("a") + file - 1) .. tostring(rank)
end

local function coordsFromSquare(square)
    if type(square) ~= "string" or #square ~= 2 then return nil end
    local file = string.byte(square:sub(1, 1)) - string.byte("a") + 1
    local rank = tonumber(square:sub(2, 2))
    if not file or not rank or file < 1 or file > 8 or rank < 1 or rank > 8 then
        return nil
    end
    return file, rank
end

function Board:getOpponentPotentialMoves(square, piece)
    local file, rank = coordsFromSquare(square)
    if not file then return {} end

    local moves = {}
    local function addIfAvailable(to_square)
        if not to_square then return false end
        local target = self.game.get(to_square)
        if target and target.color == piece.color then return false end
        moves[#moves + 1] = { from = square, to = to_square }
        return target == nil
    end

    local function addRay(df, dr)
        local f, r = file + df, rank + dr
        while true do
            local to_square = squareFromCoords(f, r)
            if not to_square then break end
            if not addIfAvailable(to_square) then break end
            f, r = f + df, r + dr
        end
    end

    if piece.type == Chess.PAWN then
        local dir = (piece.color == Chess.WHITE) and 1 or -1
        local one = squareFromCoords(file, rank + dir)
        if one and not self.game.get(one) then
            moves[#moves + 1] = { from = square, to = one }
            local start_rank = (piece.color == Chess.WHITE) and 2 or 7
            local two = squareFromCoords(file, rank + dir * 2)
            if rank == start_rank and two and not self.game.get(two) then
                moves[#moves + 1] = { from = square, to = two }
            end
        end
        for _, df in ipairs({ -1, 1 }) do
            local capture = squareFromCoords(file + df, rank + dir)
            local target = capture and self.game.get(capture)
            if target and target.color ~= piece.color then
                moves[#moves + 1] = { from = square, to = capture }
            end
        end
    elseif piece.type == Chess.KNIGHT then
        for _, d in ipairs({ {1, 2}, {2, 1}, {2, -1}, {1, -2}, {-1, -2}, {-2, -1}, {-2, 1}, {-1, 2} }) do
            addIfAvailable(squareFromCoords(file + d[1], rank + d[2]))
        end
    elseif piece.type == Chess.BISHOP then
        for _, d in ipairs({ {1, 1}, {1, -1}, {-1, -1}, {-1, 1} }) do
            addRay(d[1], d[2])
        end
    elseif piece.type == Chess.ROOK then
        for _, d in ipairs({ {1, 0}, {0, -1}, {-1, 0}, {0, 1} }) do
            addRay(d[1], d[2])
        end
    elseif piece.type == Chess.QUEEN then
        for _, d in ipairs({ {1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1} }) do
            addRay(d[1], d[2])
        end
    elseif piece.type == Chess.KING then
        for _, d in ipairs({ {1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1} }) do
            addIfAvailable(squareFromCoords(file + d[1], rank + d[2]))
        end
    end

    return moves
end

function Board:markValidMoves(square)
    self._hint_squares = {}
    if self.learning_mode and not self.show_selected then
        local id_result = Board.chessToId(square)
        if id_result then
            overlayIcon(self.table:getButtonById(id_result),
                "selected", "casualchess/select", self.button_size, self.icon_height)
        end
    end
    if not self.learning_mode then return end
    local legal = self:getLegalMovesForSquare(square)
    if not legal or #legal == 0 then return end
    for _, m in ipairs(legal) do
        local target = m.to
        local id_result = Board.chessToId(target)
        if id_result then
            local button = self.table:getButtonById(id_result)
            overlayIcon(button, "hint", "casualchess/hint", self.button_size, self.icon_height)
            table.insert(self._hint_squares, target)
        end
    end
    UIManager:setDirty("all", "ui")
end

function Board:clearValidMoves()
    if not self._hint_squares then return end
    if self.learning_mode and not self.show_selected and self.selected then
        local id_result = Board.chessToId(self.selected)
        if id_result then
            clearOverlay(self.table:getButtonById(id_result), "selected")
        end
    end
    for _, square in ipairs(self._hint_squares) do
        local id_result = Board.chessToId(square)
        if id_result then
            clearOverlay(self.table:getButtonById(id_result), "hint")
        end
    end
    self._hint_squares = {}
    UIManager:setDirty("all", "ui")
end

function Board:markPreviousMove(move)
    self:clearPreviousMoveHints()
    if not (self.learning_mode and self.previous_move_hints and move) then return end

    self._previous_move_squares = { move.from, move.to }
    for _, square in ipairs(self._previous_move_squares) do
        local id_result = Board.chessToId(square)
        if id_result then
            overlayIcon(
                self.table:getButtonById(id_result),
                "previous",
                "casualchess/hint",
                self.button_size,
                self.icon_height
            )
        end
    end
    UIManager:setDirty("all", "ui")
end

function Board:clearPreviousMoveHints()
    if not self._previous_move_squares then return end
    for _, square in ipairs(self._previous_move_squares) do
        local id_result = Board.chessToId(square)
        if id_result then
            clearOverlay(self.table:getButtonById(id_result), "previous")
        end
    end
    self._previous_move_squares = nil
    UIManager:setDirty("all", "ui")
end

function Board:getKingSquare(color)
    local board = self.game.board()
    for file_idx = 0, BOARD_SIZE - 1 do
        for rank_idx = 0, BOARD_SIZE - 1 do
            local element = board[BOARD_SIZE - rank_idx][file_idx + 1]
            if element and element.type == Chess.KING and element.color == color then
                return Board.idToPosition(Board.toId(file_idx, rank_idx))
            end
        end
    end
end

function Board:markCheckHint()
    self:clearCheckHint()
    if not (self.learning_mode and self.check_hints and self.game.in_check()) then return end

    local square = self:getKingSquare(self.game.turn())
    local id_result = square and Board.chessToId(square)
    if not id_result then return end

    self._check_square = square
    overlayIcon(
        self.table:getButtonById(id_result),
        "check",
        "casualchess/hint",
        self.button_size,
        self.icon_height
    )
    UIManager:setDirty("all", "ui")
end

function Board:clearCheckHint()
    if not self._check_square then return end
    local id_result = Board.chessToId(self._check_square)
    if id_result then
        clearOverlay(self.table:getButtonById(id_result), "check")
    end
    self._check_square = nil
    UIManager:setDirty("all", "ui")
end

function Board:placePiece(square, piece, color)
    local icon = icons.empty
    local piece_icons = piece and icons[piece]
    if piece_icons then
        icon = piece_icons[color] or icons.empty
        local top_color = self.flipped and Chess.WHITE or Chess.BLACK
        if self.rotate_top_pieces and color == top_color and piece_icons.rotated then
            icon = piece_icons.rotated[color] or icon
        end
    end
    local id_result = Board.chessToId(square)
    if not id_result then return end

    local button = self.table:getButtonById(id_result)
    button:setIcon(icon, self.button_size)

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
        local zero_id = id - 1
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
