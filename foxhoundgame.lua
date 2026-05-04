local Game = {}
Game.__index = Game
local unpack = unpack or table.unpack

Game.WHITE = "w"
Game.BLACK = "b"
Game.FOX = "f"
Game.HOUND = "h"

local BOARD_SIZE = 8
local FOX_STARTS = { "a1", "c1", "e1", "g1" }
local HOUND_STARTS = { "b8", "d8", "f8", "h8" }

local function other(color)
    return color == Game.WHITE and Game.BLACK or Game.WHITE
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
        if key == "before" then
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

local function weightedFoxStart()
    local roll = math.random()
    if roll < 0.35 then return "c1" end
    if roll < 0.70 then return "e1" end
    if roll < 0.85 then return "a1" end
    return "g1"
end

local function validStart(sq)
    for _, start in ipairs(FOX_STARTS) do
        if sq == start then return true end
    end
    return false
end

local function attachInstanceMethods(obj)
    obj.reset = function() return Game.reset(obj) end
    obj.turn = function() return Game.turn(obj) end
    obj.set_human = function(a, b, c)
        local color, is_human
        if a == obj then
            color, is_human = b, c
        else
            color, is_human = a, b
        end
        return Game.set_human(obj, color, is_human)
    end
    obj.is_human = function(a, b)
        local color = b or a
        return Game.is_human(obj, color)
    end
    obj.get = function(a, b)
        local sq = b or a
        return Game.get(obj, sq)
    end
    obj.board = function() return Game.board(obj) end
    obj.moves = function(a, b)
        local opts = b or a
        return Game.moves(obj, opts)
    end
    obj.move = function(a, b)
        local input = b or a
        return Game.move(obj, input)
    end
    obj.undo = function() return Game.undo(obj) end
    obj.redo = function() return Game.redo(obj) end
    obj.history = function() return Game.history(obj) end
    obj.game_over = function() return Game.game_over(obj) end
    obj.export_state = function() return Game.export_state(obj) end
    obj.load_state = function(a, b)
        local state = b or a
        return Game.load_state(obj, state)
    end
end

function Game:new()
    local obj = {
        board_state = {},
        self_turn = Game.WHITE,
        human_player = { [Game.WHITE] = true, [Game.BLACK] = false },
        move_history = {},
        redo_stack = {},
        setup_pending = true,
    }
    setmetatable(obj, Game)
    attachInstanceMethods(obj)
    obj:reset()
    return obj
end

function Game:clone()
    local obj = {
        board_state = copyBoard(self.board_state),
        self_turn = self.self_turn,
        human_player = {
            [Game.WHITE] = self.human_player[Game.WHITE],
            [Game.BLACK] = self.human_player[Game.BLACK],
        },
        move_history = copyMoves(self.move_history),
        redo_stack = copyMoves(self.redo_stack),
        setup_pending = self.setup_pending,
    }
    setmetatable(obj, Game)
    attachInstanceMethods(obj)
    return obj
end

function Game:reset()
    self.board_state = {}
    for _, sq in ipairs(HOUND_STARTS) do
        self.board_state[sq] = { type = Game.HOUND, color = Game.BLACK }
    end
    self.self_turn = Game.WHITE
    self.move_history = {}
    self.redo_stack = {}
    self.setup_pending = true
    if self.human_player and self.human_player[Game.WHITE] == false then
        self:choose_fox_start(weightedFoxStart())
    end
end

function Game:set_human(color, is_human)
    self.human_player[color] = is_human and true or false
    if color == Game.WHITE and not is_human and self.setup_pending then
        self:choose_fox_start(weightedFoxStart())
    end
end

function Game:is_human(color)
    return self.human_player[color] ~= false
end

function Game:turn()
    return self.self_turn
end

function Game:get(sq)
    return self.board_state[sq]
end

function Game:valid_fox_starts()
    return copyList(FOX_STARTS)
end

function Game:choose_fox_start(sq)
    if not self.setup_pending or not validStart(sq) then return false end
    self.board_state[sq] = { type = Game.FOX, color = Game.WHITE }
    self.setup_pending = false
    self.self_turn = Game.WHITE
    return true
end

function Game:board()
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

function Game:fox_square()
    for sq, piece in pairs(self.board_state) do
        if piece.type == Game.FOX then return sq end
    end
end

function Game:moves(opts)
    opts = opts or {}
    if self.setup_pending then return {} end

    local color = self.self_turn
    local square_filter = opts.square
    local moves = {}

    for from, piece in pairs(self.board_state) do
        if piece.color == color and (not square_filter or square_filter == from) then
            local file, rank = coords(from)
            local dirs = piece.type == Game.FOX
                and { { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }
                or { { 1, -1 }, { -1, -1 } }
            for _, d in ipairs(dirs) do
                local to = square(file + d[1], rank + d[2])
                if to and not self.board_state[to] then
                    moves[#moves + 1] = {
                        from = from, to = to, piece = piece.type, color = piece.color,
                        notation = (piece.type == Game.FOX and "Fox " or "Hound ") .. from .. "-" .. to,
                    }
                end
            end
        end
    end

    return moves
end

function Game:move(input)
    local legal = self:moves({ square = input.from })
    for _, move in ipairs(legal) do
        if move.to == input.to then
            move.before = copyBoard(self.board_state)
            self.board_state[move.from] = nil
            self.board_state[move.to] = { type = move.piece, color = move.color }
            self.self_turn = other(self.self_turn)
            self.move_history[#self.move_history + 1] = move
            self.redo_stack = {}
            return move
        end
    end
end

function Game:undo()
    local move = table.remove(self.move_history)
    if not move then return nil end
    self.board_state = move.before
    self.self_turn = move.color
    self.redo_stack[#self.redo_stack + 1] = move
    return move
end

function Game:redo()
    local move = table.remove(self.redo_stack)
    if not move then return nil end
    return self:move{ from = move.from, to = move.to }
end

function Game:history()
    local out = {}
    for _, move in ipairs(self.move_history) do
        out[#out + 1] = move.notation or (move.from .. "-" .. move.to)
    end
    return out
end

function Game:game_over()
    if self.setup_pending then return false end
    local fox = self:fox_square()
    if not fox then return true, "0-1", "Fox trapped" end
    if fox:sub(2, 2) == "8" then return true, "1-0", "Fox escaped" end

    local legal = self:moves({ verbose = true })
    if #legal > 0 then return false end
    if self.self_turn == Game.WHITE then
        return true, "0-1", "Fox trapped"
    end
    return true, "1-0", "Hounds blocked"
end

function Game:export_state()
    return {
        version = 1,
        board_state = copyBoard(self.board_state),
        self_turn = self.self_turn,
        move_history = copyMoves(self.move_history),
        redo_stack = copyMoves(self.redo_stack),
        setup_pending = self.setup_pending,
    }
end

function Game:load_state(state)
    if type(state) ~= "table" or state.version ~= 1 or type(state.board_state) ~= "table" then return false end
    self.board_state = copyBoard(state.board_state)
    self.self_turn = state.self_turn == Game.WHITE and Game.WHITE or Game.BLACK
    self.move_history = copyMoves(state.move_history)
    self.redo_stack = copyMoves(state.redo_stack)
    self.setup_pending = state.setup_pending == true
    return true
end

return Game
