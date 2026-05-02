local Checkers = {}
Checkers.__index = Checkers
local unpack = unpack or table.unpack

Checkers.WHITE = "w"
Checkers.BLACK = "b"
Checkers.MAN = "m"
Checkers.KING = "k"

local BOARD_SIZE = 8

local function other(color)
    return color == Checkers.WHITE and Checkers.BLACK or Checkers.WHITE
end

local function square(file, rank)
    if file < 1 or file > BOARD_SIZE or rank < 1 or rank > BOARD_SIZE then return nil end
    return string.char(string.byte("a") + file - 1) .. tostring(rank)
end

local function coords(sq)
    if type(sq) ~= "string" or #sq ~= 2 then return nil end
    local file = string.byte(sq:sub(1, 1)) - string.byte("a") + 1
    local rank = tonumber(sq:sub(2, 2))
    if not file or not rank or file < 1 or file > BOARD_SIZE or rank < 1 or rank > BOARD_SIZE then
        return nil
    end
    return file, rank
end

local function darkSquare(file, rank)
    return (file + rank) % 2 == 0
end

local function copyBoard(board)
    local out = {}
    for sq, piece in pairs(board) do
        out[sq] = { type = piece.type, color = piece.color }
    end
    return out
end

local function copyList(list)
    local out = {}
    for i, value in ipairs(list or {}) do
        out[i] = value
    end
    return out
end

local function copyMove(move)
    local out = {}
    for key, value in pairs(move) do
        if key == "path" or key == "captures" then
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
    for i, move in ipairs(moves or {}) do
        out[i] = copyMove(move)
    end
    return out
end

local function validPiece(piece)
    return type(piece) == "table"
       and (piece.color == Checkers.WHITE or piece.color == Checkers.BLACK)
       and (piece.type == Checkers.MAN or piece.type == Checkers.KING)
end

local function validBoard(board)
    if type(board) ~= "table" then return false end
    for sq, piece in pairs(board) do
        if not coords(sq) or not validPiece(piece) then return false end
    end
    return true
end

local function attachInstanceMethods(obj)
    obj.reset = function() return Checkers.reset(obj) end
    obj.turn = function() return Checkers.turn(obj) end
    obj.set_human = function(a, b, c)
        local color = (a == obj) and b or a
        local is_human = (a == obj) and c or b
        return Checkers.set_human(obj, color, is_human)
    end
    obj.is_human = function(a, b)
        local color = b or a
        return Checkers.is_human(obj, color)
    end
    obj.get = function(a, b)
        local sq = b or a
        return Checkers.get(obj, sq)
    end
    obj.board = function() return Checkers.board(obj) end
    obj.moves = function(a, b)
        local opts = b or a
        return Checkers.moves(obj, opts)
    end
    obj.move = function(a, b)
        local input = b or a
        return Checkers.move(obj, input)
    end
    obj.undo = function() return Checkers.undo(obj) end
    obj.redo = function() return Checkers.redo(obj) end
    obj.history = function() return Checkers.history(obj) end
    obj.game_over = function() return Checkers.game_over(obj) end
    obj.export_state = function() return Checkers.export_state(obj) end
    obj.load_state = function(a, b)
        local state = b or a
        return Checkers.load_state(obj, state)
    end
end

local function pieceDirs(piece)
    if piece.type == Checkers.KING then
        return { {1, 1}, {-1, 1}, {1, -1}, {-1, -1} }
    end
    local dr = piece.color == Checkers.WHITE and 1 or -1
    return { {1, dr}, {-1, dr} }
end

function Checkers:new()
    local obj = {
        board_state = {},
        self_turn = Checkers.BLACK,
        human_player = { [Checkers.WHITE] = true, [Checkers.BLACK] = false },
        move_history = {},
        redo_stack = {},
    }
    setmetatable(obj, Checkers)
    attachInstanceMethods(obj)
    obj:reset()
    return obj
end

function Checkers:clone()
    local obj = {
        board_state = copyBoard(self.board_state),
        self_turn = self.self_turn,
        human_player = {
            [Checkers.WHITE] = self.human_player[Checkers.WHITE],
            [Checkers.BLACK] = self.human_player[Checkers.BLACK],
        },
        move_history = {},
        redo_stack = {},
    }
    setmetatable(obj, Checkers)
    attachInstanceMethods(obj)
    return obj
end

function Checkers:reset()
    self.board_state = {}
    for rank = 1, 3 do
        for file = 1, BOARD_SIZE do
            if darkSquare(file, rank) then
                self.board_state[square(file, rank)] = { type = Checkers.MAN, color = Checkers.WHITE }
            end
        end
    end
    for rank = 6, 8 do
        for file = 1, BOARD_SIZE do
            if darkSquare(file, rank) then
                self.board_state[square(file, rank)] = { type = Checkers.MAN, color = Checkers.BLACK }
            end
        end
    end
    self.self_turn = Checkers.BLACK
    self.move_history = {}
    self.redo_stack = {}
end

function Checkers:turn()
    return self.self_turn
end

function Checkers:set_human(color, is_human)
    self.human_player[color] = is_human and true or false
end

function Checkers:is_human(color)
    return self.human_player[color] ~= false
end

function Checkers:get(sq)
    return self.board_state[sq]
end

function Checkers:board()
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

function Checkers:capturesFrom(from, piece, board, path, captures)
    local file, rank = coords(from)
    local found = false
    local results = {}

    for _, d in ipairs(pieceDirs(piece)) do
        local mid = square(file + d[1], rank + d[2])
        local to = square(file + d[1] * 2, rank + d[2] * 2)
        local jumped = mid and board[mid]
        if to and jumped and jumped.color ~= piece.color and not board[to] then
            found = true
            local next_board = copyBoard(board)
            next_board[from] = nil
            next_board[mid] = nil
            local next_piece = { type = piece.type, color = piece.color }
            local promotes = next_piece.type == Checkers.MAN
                and ((next_piece.color == Checkers.WHITE and to:sub(2, 2) == "8")
                  or (next_piece.color == Checkers.BLACK and to:sub(2, 2) == "1"))
            if promotes then next_piece.type = Checkers.KING end
            next_board[to] = next_piece

            local next_path = { unpack(path) }
            next_path[#next_path + 1] = to
            local next_captures = { unpack(captures) }
            next_captures[#next_captures + 1] = mid

            if promotes then
                results[#results + 1] = {
                    from = path[1], to = to, path = next_path, captures = next_captures,
                    piece = piece.type, color = piece.color,
                    promotion = Checkers.KING,
                }
            else
                local more = self:capturesFrom(to, next_piece, next_board, next_path, next_captures)
                for _, move in ipairs(more) do results[#results + 1] = move end
            end
        end
    end

    if not found and #captures > 0 then
        results[#results + 1] = {
            from = path[1], to = from, path = path, captures = captures,
            piece = piece.type, color = piece.color,
        }
    end

    return results
end

function Checkers:jump_steps(from, board)
    board = board or self.board_state
    local piece = board[from]
    if not piece then return {} end
    local file, rank = coords(from)
    local moves = {}

    for _, d in ipairs(pieceDirs(piece)) do
        local mid = square(file + d[1], rank + d[2])
        local to = square(file + d[1] * 2, rank + d[2] * 2)
        local jumped = mid and board[mid]
        if to and jumped and jumped.color ~= piece.color and not board[to] then
            moves[#moves + 1] = { from = from, to = to, captured = mid }
        end
    end

    return moves
end

function Checkers:quietMovesFrom(from, piece)
    local file, rank = coords(from)
    local moves = {}
    for _, d in ipairs(pieceDirs(piece)) do
        local to = square(file + d[1], rank + d[2])
        if to and not self.board_state[to] then
            moves[#moves + 1] = {
                from = from, to = to, path = { from, to }, captures = {},
                piece = piece.type, color = piece.color,
            }
        end
    end
    return moves
end

function Checkers:moves(opts)
    opts = opts or {}
    local square_filter = opts.square
    local captures = {}
    local quiet = {}

    for from, piece in pairs(self.board_state) do
        if piece.color == self.self_turn and (not square_filter or square_filter == from) then
            local piece_captures = self:capturesFrom(from, piece, self.board_state, { from }, {})
            for _, move in ipairs(piece_captures) do captures[#captures + 1] = move end
            if #piece_captures == 0 then
                for _, move in ipairs(self:quietMovesFrom(from, piece)) do quiet[#quiet + 1] = move end
            end
        end
    end

    return (#captures > 0) and captures or quiet
end

local function moveText(move)
    local sep = (#move.captures > 0) and "x" or "-"
    return table.concat(move.path, sep)
end

function Checkers:move(input)
    local legal = self:moves({ verbose = true, square = input.from })
    for _, move in ipairs(legal) do
        if move.to == input.to then
            local before = copyBoard(self.board_state)
            local piece = self.board_state[move.from]
            self.board_state[move.from] = nil
            for _, captured in ipairs(move.captures) do
                self.board_state[captured] = nil
            end
            local placed = { type = piece.type, color = piece.color }
            if placed.type == Checkers.MAN then
                local rank = move.to:sub(2, 2)
                if (placed.color == Checkers.WHITE and rank == "8")
                or (placed.color == Checkers.BLACK and rank == "1") then
                    placed.type = Checkers.KING
                    move.promotion = Checkers.KING
                end
            end
            self.board_state[move.to] = placed
            move.notation = moveText(move)
            move.before = before
            move.after_turn = other(self.self_turn)
            self.self_turn = other(self.self_turn)
            self.move_history[#self.move_history + 1] = move
            self.redo_stack = {}
            return move
        end
    end
end

function Checkers:commit_path(input)
    if not input or not input.path or #input.path < 2 then return nil end

    local legal = self:moves({ verbose = true, square = input.path[1] })
    for _, move in ipairs(legal) do
        if #move.path == #input.path then
            local matches = true
            for i, sq in ipairs(move.path) do
                if input.path[i] ~= sq then
                    matches = false
                    break
                end
            end
            if matches then
                return self:move{ from = move.from, to = move.to }
            end
        end
    end
end

function Checkers:undo()
    local move = table.remove(self.move_history)
    if not move then return nil end
    self.board_state = move.before
    self.self_turn = move.color
    self.redo_stack[#self.redo_stack + 1] = move
    return move
end

function Checkers:redo()
    local move = table.remove(self.redo_stack)
    if not move then return nil end
    return self:move({ from = move.from, to = move.to })
end

function Checkers:history()
    local out = {}
    for _, move in ipairs(self.move_history) do
        out[#out + 1] = move.notation or moveText(move)
    end
    return out
end

function Checkers:game_over()
    local legal = self:moves({ verbose = true })
    if #legal > 0 then return false end
    local winner = other(self.self_turn)
    return true, winner == Checkers.WHITE and "1-0" or "0-1", "No legal moves"
end

function Checkers:export_state()
    return {
        version = 1,
        board_state = copyBoard(self.board_state),
        self_turn = self.self_turn,
        move_history = copyMoves(self.move_history),
        redo_stack = copyMoves(self.redo_stack),
    }
end

function Checkers:load_state(state)
    if type(state) ~= "table" or state.version ~= 1 then return false end
    if state.self_turn ~= Checkers.WHITE and state.self_turn ~= Checkers.BLACK then return false end
    if not validBoard(state.board_state) then return false end

    self.board_state = copyBoard(state.board_state)
    self.self_turn = state.self_turn
    self.move_history = copyMoves(state.move_history)
    self.redo_stack = copyMoves(state.redo_stack)
    return true
end

return Checkers
