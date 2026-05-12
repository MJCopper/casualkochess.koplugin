local Reversi = {}
Reversi.__index = Reversi

Reversi.WHITE = "w"
Reversi.BLACK = "b"
Reversi.DISC = "d"

local BOARD_SIZE = 8
local DIRS = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
}

local function other(color)
    return color == Reversi.WHITE and Reversi.BLACK or Reversi.WHITE
end

local function square(file, rank)
    if file < 1 or file > BOARD_SIZE or rank < 1 or rank > BOARD_SIZE then return nil end
    return string.char(string.byte("a") + file - 1) .. tostring(rank)
end

local function coords(sq)
    if type(sq) ~= "string" or #sq ~= 2 then return nil end
    local file = string.byte(sq:sub(1, 1)) - string.byte("a") + 1
    local rank = tonumber(sq:sub(2, 2))
    if not file or not rank or file < 1 or file > BOARD_SIZE or rank < 1 or rank > BOARD_SIZE then return nil end
    return file, rank
end

local function copyBoard(board)
    local out = {}
    for sq, piece in pairs(board or {}) do
        out[sq] = { type = piece.type, color = piece.color }
    end
    return out
end

local function copyList(list)
    local out = {}
    for i, value in ipairs(list or {}) do out[i] = value end
    return out
end

local function copyMove(move)
    local out = {}
    for key, value in pairs(move or {}) do
        if key == "flips" then
            out[key] = copyList(value)
        elseif key == "before" then
            out[key] = copyBoard(value)
        else
            out[key] = value
        end
    end
    return out
end

local function copyMoves(moves)
    local out = {}
    for i, move in ipairs(moves or {}) do out[i] = copyMove(move) end
    return out
end

local function validPiece(piece)
    return type(piece) == "table"
       and piece.type == Reversi.DISC
       and (piece.color == Reversi.WHITE or piece.color == Reversi.BLACK)
end

local function validBoard(board)
    if type(board) ~= "table" then return false end
    for sq, piece in pairs(board) do
        if not coords(sq) or not validPiece(piece) then return false end
    end
    return true
end

local function attachInstanceMethods(obj)
    obj.reset = function() return Reversi.reset(obj) end
    obj.turn = function() return Reversi.turn(obj) end
    obj.set_human = function(a, b, c)
        local color = (a == obj) and b or a
        local is_human = (a == obj) and c or b
        return Reversi.set_human(obj, color, is_human)
    end
    obj.is_human = function(a, b)
        local color = b or a
        return Reversi.is_human(obj, color)
    end
    obj.get = function(a, b)
        local sq = b or a
        return Reversi.get(obj, sq)
    end
    obj.board = function() return Reversi.board(obj) end
    obj.moves = function(a, b)
        local opts = b or a
        return Reversi.moves(obj, opts)
    end
    obj.move = function(a, b)
        local input = b or a
        return Reversi.move(obj, input)
    end
    obj.undo = function() return Reversi.undo(obj) end
    obj.redo = function() return Reversi.redo(obj) end
    obj.history = function() return Reversi.history(obj) end
    obj.game_over = function() return Reversi.game_over(obj) end
    obj.export_state = function() return Reversi.export_state(obj) end
    obj.load_state = function(a, b)
        local state = b or a
        return Reversi.load_state(obj, state)
    end
end

function Reversi:new()
    local obj = {
        board_state = {},
        self_turn = Reversi.BLACK,
        human_player = { [Reversi.WHITE] = true, [Reversi.BLACK] = false },
        move_history = {},
        redo_stack = {},
    }
    setmetatable(obj, Reversi)
    attachInstanceMethods(obj)
    obj:reset()
    return obj
end

function Reversi:clone()
    local obj = {
        board_state = copyBoard(self.board_state),
        self_turn = self.self_turn,
        human_player = {
            [Reversi.WHITE] = self.human_player[Reversi.WHITE],
            [Reversi.BLACK] = self.human_player[Reversi.BLACK],
        },
        move_history = copyMoves(self.move_history),
        redo_stack = copyMoves(self.redo_stack),
    }
    setmetatable(obj, Reversi)
    attachInstanceMethods(obj)
    return obj
end

function Reversi:reset()
    self.board_state = {
        d4 = { type = Reversi.DISC, color = Reversi.WHITE },
        e5 = { type = Reversi.DISC, color = Reversi.WHITE },
        e4 = { type = Reversi.DISC, color = Reversi.BLACK },
        d5 = { type = Reversi.DISC, color = Reversi.BLACK },
    }
    self.self_turn = Reversi.BLACK
    self.move_history = {}
    self.redo_stack = {}
end

function Reversi:turn()
    return self.self_turn
end

function Reversi:set_human(color, is_human)
    self.human_player[color] = is_human and true or false
end

function Reversi:is_human(color)
    return self.human_player[color] ~= false
end

function Reversi:get(sq)
    return self.board_state[sq]
end

function Reversi:board()
    local rows = {}
    for rank = BOARD_SIZE, 1, -1 do
        local row = {}
        for file = 1, BOARD_SIZE do
            row[file] = self.board_state[square(file, rank)]
        end
        rows[#rows + 1] = row
    end
    return rows
end

function Reversi:flipsFor(sq, color, board)
    board = board or self.board_state
    if board[sq] then return {} end
    local file, rank = coords(sq)
    if not file then return {} end

    local flips = {}
    for _, dir in ipairs(DIRS) do
        local line = {}
        local f, r = file + dir[1], rank + dir[2]
        while true do
            local scan = square(f, r)
            if not scan then
                line = {}
                break
            end
            local piece = board[scan]
            if not piece then
                line = {}
                break
            end
            if piece.color == color then break end
            line[#line + 1] = scan
            f, r = f + dir[1], r + dir[2]
        end
        for _, flip in ipairs(line) do flips[#flips + 1] = flip end
    end
    return flips
end

function Reversi:moves(opts)
    opts = opts or {}
    local color = opts.color or self.self_turn
    local moves = {}
    for rank = 1, BOARD_SIZE do
        for file = 1, BOARD_SIZE do
            local sq = square(file, rank)
            local flips = self:flipsFor(sq, color)
            if #flips > 0 then
                moves[#moves + 1] = {
                    from = sq,
                    to = sq,
                    color = color,
                    flips = flips,
                    san = sq,
                    notation = sq,
                }
            end
        end
    end
    return moves
end

function Reversi:hasMoves(color)
    return #self:moves({ color = color }) > 0
end

function Reversi:move(input)
    local to = type(input) == "string" and input or (input and (input.to or input.square))
    local color = self.self_turn
    local flips = self:flipsFor(to, color)
    if #flips == 0 then return nil end

    local before = copyBoard(self.board_state)
    self.board_state[to] = { type = Reversi.DISC, color = color }
    for _, sq in ipairs(flips) do
        self.board_state[sq].color = color
    end

    local next_turn = other(color)
    local passed = false
    if not self:hasMoves(next_turn) and self:hasMoves(color) then
        next_turn = color
        passed = true
    end
    self.self_turn = next_turn

    local move = {
        from = to,
        to = to,
        color = color,
        flips = flips,
        pass = passed,
        before = before,
        san = passed and (to .. " pass") or to,
        notation = passed and (to .. " (pass)") or to,
    }
    self.move_history[#self.move_history + 1] = move
    self.redo_stack = {}
    return move
end

function Reversi:undo()
    local move = table.remove(self.move_history)
    if not move then return nil end
    self.board_state = copyBoard(move.before)
    self.self_turn = move.color
    self.redo_stack[#self.redo_stack + 1] = copyMove(move)
    return move
end

function Reversi:redo()
    local move = table.remove(self.redo_stack)
    if not move then return nil end
    return self:move{ to = move.to }
end

function Reversi:history()
    local out = {}
    for _, move in ipairs(self.move_history) do
        out[#out + 1] = move.notation or move.san or move.to
    end
    return out
end

function Reversi:counts()
    local white, black = 0, 0
    for _, piece in pairs(self.board_state) do
        if piece.color == Reversi.WHITE then white = white + 1 end
        if piece.color == Reversi.BLACK then black = black + 1 end
    end
    return white, black
end

function Reversi:game_over()
    if self:hasMoves(Reversi.WHITE) or self:hasMoves(Reversi.BLACK) then return false end
    local white, black = self:counts()
    if white > black then return true, "1-0", "No legal moves" end
    if black > white then return true, "0-1", "No legal moves" end
    return true, "1/2-1/2", "Equal discs"
end

function Reversi:export_state()
    return {
        board_state = copyBoard(self.board_state),
        self_turn = self.self_turn,
        human_player = {
            [Reversi.WHITE] = self.human_player[Reversi.WHITE],
            [Reversi.BLACK] = self.human_player[Reversi.BLACK],
        },
        move_history = copyMoves(self.move_history),
    }
end

function Reversi:load_state(state)
    if type(state) ~= "table" or not validBoard(state.board_state) then return false end
    if state.self_turn ~= Reversi.WHITE and state.self_turn ~= Reversi.BLACK then return false end
    self.board_state = copyBoard(state.board_state)
    self.self_turn = state.self_turn
    self.human_player = {
        [Reversi.WHITE] = state.human_player and state.human_player[Reversi.WHITE] ~= false,
        [Reversi.BLACK] = state.human_player and state.human_player[Reversi.BLACK] ~= false,
    }
    self.move_history = copyMoves(state.move_history or {})
    self.redo_stack = {}
    return true
end

return Reversi
