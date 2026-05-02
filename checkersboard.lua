local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("buttontable")
local FrameContainer = require("ui/widget/container/framecontainer")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local IconWidget = require("ui/widget/iconwidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Checkers = require("checkersgame")

local BOARD_SIZE = 8
local SELECTED_BORDER = 5

local icons = {
    empty = "casualchess/empty",
    [Checkers.MAN] = {
        [Checkers.WHITE] = "casualchess/wChecker",
        [Checkers.BLACK] = "casualchess/bChecker",
        rotated = {
            [Checkers.WHITE] = "casualchess/wChecker_rot",
            [Checkers.BLACK] = "casualchess/bChecker_rot",
        },
    },
    [Checkers.KING] = {
        [Checkers.WHITE] = "casualchess/wCheckerKing",
        [Checkers.BLACK] = "casualchess/bCheckerKing",
        rotated = {
            [Checkers.WHITE] = "casualchess/wCheckerKing_rot",
            [Checkers.BLACK] = "casualchess/bCheckerKing_rot",
        },
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
    learning_mode = false,
    show_selected = true,
    previous_move_hints = false,
    opponent_hints = false,
    selected = nil,
    _peek_square = nil,
    _hint_squares = nil,
    _hint_path_squares = nil,
    _previous_move_squares = nil,
    _jump_state = nil,
}

function Board:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function Board:init()
    if not self.game then
        error("Checkers Board: must be initialized with a Game object")
        return
    end

    local margins = self:allMarginSizes()
    local bt_pad_v = Screen:scaleBySize(4)
    self.board_padding = Screen:scaleBySize(8)
    local usable_w = self.width - 2 * self.board_padding
    local usable_h = self.height - self.board_padding
    local cell = math.min(
        math.floor(usable_w / BOARD_SIZE) - margins.w,
        math.floor(usable_h / BOARD_SIZE) - margins.h
    )
    self.button_size = cell
    self.icon_height = cell - 2 * bt_pad_v
    self.selected = nil
    self._peek_square = nil
    self._hint_squares = {}
    self._hint_path_squares = {}
    self._previous_move_squares = nil
    self._jump_state = nil

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
    self[1] = FrameContainer:new{
        bordersize = 0,
        background = self.background,
        padding = 0,
        padding_top = self.board_padding,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = cell * BOARD_SIZE + self.board_padding },
            self.table,
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
        og[#og + 1] = IconWidget:new{
            icon = name, alpha = true, width = w, height = h, is_icon = true,
        }
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
            og[#og + 1] = IconWidget:new{
                icon = name, alpha = true, width = og._overlay_w, height = og._overlay_h, is_icon = true,
            }
        end
        return
    end
    label_container[1] = og._orig_widget
end

function Board:handleClick(file, rank)
    if not self.game:is_human(self.game:turn()) then return end

    local sq = Board.idToPosition(Board.toId(file, rank))
    local piece = self.game:get(sq)

    if self._jump_state then
        if self:handleJumpStep(sq) then return end
        return
    end

    if self._peek_square then
        self:unmarkSelected(self._peek_square)
        self:clearValidMoves()
        self._peek_square = nil
    end

    local is_my_piece = piece and piece.color == self.game:turn()
    local can_peek_opponent = piece
        and not is_my_piece
        and self.learning_mode
        and self.opponent_hints

    if self.selected then
        if self.selected == sq then
            self:clearValidMoves()
            self.selected = nil
            self:updateSquare(sq)
            return
        end
        local move = self:moveOrStartJump(self.selected, sq)
        if move then
            self.selected = nil
            self:clearValidMoves()
            self:handleGameMove(move)
            return
        elseif self._jump_state then
            return
        end
        self:clearValidMoves()
        self:updateSquare(self.selected)
        self.selected = nil
    end

    if is_my_piece then
        self:clearPreviousMoveHints()
        self.selected = sq
        self:markSelected(sq)
        self:markValidMoves(sq)
    elseif can_peek_opponent then
        self:clearPreviousMoveHints()
        self._peek_square = sq
        self:markSelected(sq)
        self:markValidMoves(sq)
    end
end

function Board:moveOrStartJump(from, to)
    local legal = self.game:moves({ verbose = true, square = from })
    local matches = {}
    local first_step_matches = {}
    for _, move in ipairs(legal) do
        if move.to == to then
            matches[#matches + 1] = move
        end
        if #(move.captures or {}) > 1 and move.path and move.path[2] == to then
            first_step_matches[#first_step_matches + 1] = move
        end
    end

    if #first_step_matches > 0 then
        return self:startJumpSelection(from, to)
    end

    if #matches == 0 then return nil end

    local move = matches[1]
    if #(move.captures or {}) <= 1 then
        return self.game:move{ from = from, to = to }
    end

    if #matches == 1 and move.path then
        local first_step = move.path[2]
        if first_step then
            local started = self:startJumpSelection(from, first_step)
            if started then return started end
        end
    end

    return nil
end

function Board:copyBoardState()
    local out = {}
    for sq, piece in pairs(self.game.board_state) do
        out[sq] = { type = piece.type, color = piece.color }
    end
    return out
end

function Board:startJumpSelection(from, first_to)
    local steps = self.game:jump_steps(from)
    for _, step in ipairs(steps) do
        if step.to == first_to then
            local piece = self.game:get(from)
            local board = self:copyBoardState()
            board[from] = nil
            board[step.captured] = nil
            board[step.to] = { type = piece.type, color = piece.color }
            self._jump_state = {
                path = { from, step.to },
                captures = { step.captured },
                board = board,
                current = step.to,
            }
            self.selected = step.to
            self:clearValidMoves()
            self:updateBoard()
            self:markSelected(step.to)
            local more = self.game:jump_steps(step.to, board)
            if #more == 0 then
                return self:commitJumpSelection()
            end
            self:markJumpStepHints(more)
            return nil
        end
    end
end

function Board:handleJumpStep(to)
    local state = self._jump_state
    local steps = self.game:jump_steps(state.current, state.board)
    for _, step in ipairs(steps) do
        if step.to == to then
            local piece = state.board[state.current]
            state.board[state.current] = nil
            state.board[step.captured] = nil
            state.board[step.to] = { type = piece.type, color = piece.color }
            state.current = step.to
            state.path[#state.path + 1] = step.to
            state.captures[#state.captures + 1] = step.captured
            self.selected = step.to
            self:clearValidMoves()
            self:updateBoard()
            self:markSelected(step.to)
            local more = self.game:jump_steps(step.to, state.board)
            if #more == 0 then
                self:commitJumpSelection()
            else
                self:markJumpStepHints(more)
            end
            return true
        end
    end
    return false
end

function Board:commitJumpSelection()
    local state = self._jump_state
    self._jump_state = nil
    self:clearValidMoves()
    self.selected = nil
    local move = self.game:commit_path{ path = state.path }
    if move then self:handleGameMove(move) end
    return true
end

function Board:markJumpStepHints(steps)
    self._hint_squares = {}
    self._hint_path_squares = {}

    local continuations
    local state = self._jump_state
    if state and state.board and state.current then
        local piece = state.board[state.current]
        continuations = piece and self.game:capturesFrom(state.current, piece, state.board, { state.current }, {}) or {}
    end

    if continuations and #continuations > 0 then
        for _, move in ipairs(continuations) do
            for i = 2, math.max(1, #(move.path or {}) - 1) do
                local path_sq = move.path[i]
                local path_id = Board.chessToId(path_sq)
                if path_id then
                    overlayIcon(self.table:getButtonById(path_id), "hint_path", "casualchess/hint_path", self.button_size, self.icon_height)
                    self._hint_path_squares[#self._hint_path_squares + 1] = path_sq
                end
            end
            for _, captured_sq in ipairs(move.captures or {}) do
                local captured_id = Board.chessToId(captured_sq)
                if captured_id then
                    overlayIcon(self.table:getButtonById(captured_id), "hint_path", "casualchess/hint_path", self.button_size, self.icon_height)
                    self._hint_path_squares[#self._hint_path_squares + 1] = captured_sq
                end
            end
            local id = Board.chessToId(move.to)
            if id then
                overlayIcon(self.table:getButtonById(id), "hint", "casualchess/hint", self.button_size, self.icon_height)
                self._hint_squares[#self._hint_squares + 1] = move.to
            end
        end
    else
        for _, step in ipairs(steps) do
            local captured_id = Board.chessToId(step.captured)
            if captured_id then
                overlayIcon(self.table:getButtonById(captured_id), "hint_path", "casualchess/hint_path", self.button_size, self.icon_height)
                self._hint_path_squares[#self._hint_path_squares + 1] = step.captured
            end
            local id = Board.chessToId(step.to)
            if id then
                overlayIcon(self.table:getButtonById(id), "hint", "casualchess/hint", self.button_size, self.icon_height)
                self._hint_squares[#self._hint_squares + 1] = step.to
            end
        end
    end
    UIManager:setDirty("all", "ui")
end

function Board:markSelected(sq)
    if not self.show_selected and not self.learning_mode then return end
    local id = Board.chessToId(sq)
    if id then
        overlayIcon(self.table:getButtonById(id), "selected", "casualchess/select", self.button_size, self.icon_height)
        UIManager:setDirty("all", "ui")
    end
end

function Board:unmarkSelected(sq)
    local id = Board.chessToId(sq)
    if id then
        clearOverlay(self.table:getButtonById(id), "selected")
        UIManager:setDirty("all", "ui")
    end
end

function Board:markValidMoves(sq)
    self._hint_squares = {}
    self._hint_path_squares = {}
    if self.learning_mode and not self.show_selected then
        local id = Board.chessToId(sq)
        if id then
            overlayIcon(self.table:getButtonById(id), "selected", "casualchess/select", self.button_size, self.icon_height)
        end
    end
    if not self.learning_mode then return end
    local piece = self.game:get(sq)
    local restore_turn
    if piece and piece.color ~= self.game:turn() and self.learning_mode and self.opponent_hints then
        restore_turn = self.game.self_turn
        self.game.self_turn = piece.color
    end
    local moves = self.game:moves({ verbose = true, square = sq })
    if restore_turn then self.game.self_turn = restore_turn end

    local has_captures = false
    for _, move in ipairs(moves) do
        if #(move.captures or {}) > 0 then
            has_captures = true
            break
        end
    end

    if has_captures then
        for _, move in ipairs(moves) do
            for i = 2, math.max(1, #(move.path or {}) - 1) do
                local path_sq = move.path[i]
                local path_id = Board.chessToId(path_sq)
                if path_id then
                    overlayIcon(self.table:getButtonById(path_id), "hint_path", "casualchess/hint_path", self.button_size, self.icon_height)
                    self._hint_path_squares[#self._hint_path_squares + 1] = path_sq
                end
            end
            for _, captured_sq in ipairs(move.captures or {}) do
                local captured_id = Board.chessToId(captured_sq)
                if captured_id then
                    overlayIcon(self.table:getButtonById(captured_id), "hint_path", "casualchess/hint_path", self.button_size, self.icon_height)
                    self._hint_path_squares[#self._hint_path_squares + 1] = captured_sq
                end
            end
            local id = Board.chessToId(move.to)
            if id then
                overlayIcon(self.table:getButtonById(id), "hint", "casualchess/hint", self.button_size, self.icon_height)
                self._hint_squares[#self._hint_squares + 1] = move.to
            end
        end
    end

    if not has_captures then
        for _, move in ipairs(moves) do
            local id = Board.chessToId(move.to)
            if id then
                overlayIcon(self.table:getButtonById(id), "hint", "casualchess/hint", self.button_size, self.icon_height)
                self._hint_squares[#self._hint_squares + 1] = move.to
            end
        end
    end
    UIManager:setDirty("all", "ui")
end

function Board:clearValidMoves()
    local selected = self.selected or self._peek_square
    if selected then
        local id = Board.chessToId(selected)
        if id then clearOverlay(self.table:getButtonById(id), "selected") end
    end
    for _, sq in ipairs(self._hint_squares or {}) do
        local id = Board.chessToId(sq)
        if id then clearOverlay(self.table:getButtonById(id), "hint") end
    end
    for _, sq in ipairs(self._hint_path_squares or {}) do
        local id = Board.chessToId(sq)
        if id then clearOverlay(self.table:getButtonById(id), "hint_path") end
    end
    self._hint_squares = {}
    self._hint_path_squares = {}
    UIManager:setDirty("all", "ui")
end

function Board:clearPreviousMoveHints()
    if not self._previous_move_squares then return end
    for _, sq in ipairs(self._previous_move_squares) do
        local id = Board.chessToId(sq)
        if id then clearOverlay(self.table:getButtonById(id), "previous") end
    end
    self._previous_move_squares = nil
    UIManager:setDirty("all", "ui")
end

function Board:markPreviousMove(move)
    self:clearPreviousMoveHints()
    if not (self.learning_mode and self.previous_move_hints and move) then return end

    self._previous_move_squares = {}
    local seen = {}
    local function addSquare(sq)
        if sq and not seen[sq] then
            seen[sq] = true
            self._previous_move_squares[#self._previous_move_squares + 1] = sq
        end
    end

    if move.path and #move.path > 0 then
        for _, sq in ipairs(move.path) do
            addSquare(sq)
        end
    else
        addSquare(move.from)
        addSquare(move.to)
    end

    for _, captured in ipairs(move.captures or {}) do
        addSquare(captured)
    end
    for _, sq in ipairs(self._previous_move_squares) do
        local id = Board.chessToId(sq)
        if id then
            overlayIcon(self.table:getButtonById(id), "previous", "casualchess/hint", self.button_size, self.icon_height)
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
    local staged = self._jump_state and self._jump_state.board[sq]
    if staged then
        piece = staged.type
        color = staged.color
    elseif self._jump_state then
        piece = nil
        color = nil
    end
    local piece_icons = piece and icons[piece]
    local icon = (piece_icons and piece_icons[color]) or icons.empty
    if piece_icons then
        local top_color = self.flipped and Checkers.WHITE or Checkers.BLACK
        if self.rotate_top_pieces and color == top_color and piece_icons.rotated then
            icon = piece_icons.rotated[color] or icon
        end
    end
    local button = self.table:getButtonById(id)
    button:setIcon(icon, self.button_size)
    local color_value = Board.positionToColor(sq)
    button.frame.background = color_value
    button.frame.border_color = color_value
end

function Board:updateSquare(sq)
    local piece = self.game:get(sq)
    if piece then
        self:placePiece(sq, piece.type, piece.color)
    else
        self:placePiece(sq)
    end
end

function Board:updateBoard()
    for file = 0, BOARD_SIZE - 1 do
        for rank = 0, BOARD_SIZE - 1 do
            self:updateSquare(Board.idToPosition(Board.toId(file, rank)))
        end
    end
    UIManager:setDirty(self, "ui")
end

function Board.toId(file, rank)
    return file * BOARD_SIZE + rank + 1
end

function Board.chessToId(position)
    if type(position) == "string" and #position == 2 then
        local file = string.byte(position:sub(1, 1)) - string.byte("a")
        local rank = tonumber(position:sub(2, 2)) - 1
        if file >= 0 and file < BOARD_SIZE and rank >= 0 and rank < BOARD_SIZE then
            return Board.toId(file, rank)
        end
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
    return Geom:new{
        w = (self.margin + self.bordersize) * 2 + self._padding_right + self._padding_left,
        h = (self.margin + self.bordersize) * 2 + self._padding_top + self._padding_bottom,
    }
end

return Board
