local Checkers = require("checkersgame")

local AI = {}

local WHITE = Checkers.WHITE
local BLACK = Checkers.BLACK
local MAN = Checkers.MAN
local KING = Checkers.KING
local BOARD_SIZE = 8
local unpack = unpack or table.unpack

local function checkpoint(fn)
    if fn then fn() end
end

local function other(color)
    return color == WHITE and BLACK or WHITE
end

local function square(file, rank)
    if file < 1 or file > BOARD_SIZE or rank < 1 or rank > BOARD_SIZE then return nil end
    return string.char(string.byte("a") + file - 1) .. tostring(rank)
end

local function coords(sq)
    local file = string.byte(sq:sub(1, 1)) - string.byte("a") + 1
    local rank = tonumber(sq:sub(2, 2))
    return file, rank
end

local function pieceCode(piece)
    return piece.color .. piece.type
end

local function pieceColor(code)
    return code:sub(1, 1)
end

local function pieceType(code)
    return code:sub(2, 2)
end

local function pieceDirs(code)
    if pieceType(code) == KING then
        return { { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }
    end
    local dr = pieceColor(code) == WHITE and 1 or -1
    return { { 1, dr }, { -1, dr } }
end

local function copyBoard(board)
    local out = {}
    for sq, piece in pairs(board) do out[sq] = piece end
    return out
end

local function boardFromGame(game)
    local board = {}
    for sq, piece in pairs(game.board_state) do board[sq] = pieceCode(piece) end
    return board
end

local function promotes(code, to)
    if pieceType(code) ~= MAN then return false end
    local rank = to:sub(2, 2)
    return (pieceColor(code) == WHITE and rank == "8") or (pieceColor(code) == BLACK and rank == "1")
end

local function capturesFrom(from, code, board, path, captures)
    local file, rank = coords(from)
    local found = false
    local results = {}

    for _, d in ipairs(pieceDirs(code)) do
        local mid = square(file + d[1], rank + d[2])
        local to = square(file + d[1] * 2, rank + d[2] * 2)
        local jumped = mid and board[mid]
        if to and jumped and pieceColor(jumped) ~= pieceColor(code) and not board[to] then
            found = true
            local next_board = copyBoard(board)
            next_board[from] = nil
            next_board[mid] = nil
            local next_code = promotes(code, to) and (pieceColor(code) .. KING) or code
            next_board[to] = next_code

            local next_path = { unpack(path) }
            next_path[#next_path + 1] = to
            local next_captures = { unpack(captures) }
            next_captures[#next_captures + 1] = mid

            if promotes(code, to) then
                results[#results + 1] = {
                    from = path[1],
                    to = to,
                    path = next_path,
                    captures = next_captures,
                    piece = pieceType(code),
                    color = pieceColor(code),
                    promotion = KING,
                }
            else
                local more = capturesFrom(to, next_code, next_board, next_path, next_captures)
                for _, move in ipairs(more) do results[#results + 1] = move end
            end
        end
    end

    if not found and #captures > 0 then
        results[#results + 1] = {
            from = path[1],
            to = from,
            path = path,
            captures = captures,
            piece = pieceType(code),
            color = pieceColor(code),
        }
    end

    return results
end

local function quietMovesFrom(from, code, board)
    local file, rank = coords(from)
    local moves = {}
    for _, d in ipairs(pieceDirs(code)) do
        local to = square(file + d[1], rank + d[2])
        if to and not board[to] then
            moves[#moves + 1] = {
                from = from,
                to = to,
                path = { from, to },
                captures = {},
                piece = pieceType(code),
                color = pieceColor(code),
            }
        end
    end
    return moves
end

local function movesFor(board, turn)
    local captures = {}
    local quiet = {}
    for from, code in pairs(board) do
        if pieceColor(code) == turn then
            local piece_captures = capturesFrom(from, code, board, { from }, {})
            for _, move in ipairs(piece_captures) do captures[#captures + 1] = move end
            if #piece_captures == 0 then
                for _, move in ipairs(quietMovesFrom(from, code, board)) do quiet[#quiet + 1] = move end
            end
        end
    end
    return (#captures > 0) and captures or quiet
end

local function applyMove(board, move)
    local next_board = copyBoard(board)
    local code = next_board[move.from]
    next_board[move.from] = nil
    for _, captured in ipairs(move.captures or {}) do next_board[captured] = nil end
    if promotes(code, move.to) then code = pieceColor(code) .. KING end
    next_board[move.to] = code
    return next_board
end

local function boardKey(board, turn, depth)
    local out = { turn, ":", tostring(depth), ":" }
    for rank = 1, BOARD_SIZE do
        for file = 1, BOARD_SIZE do
            out[#out + 1] = board[square(file, rank)] or ".."
        end
    end
    return table.concat(out)
end

local function evaluate(board, turn, color, yield_fn)
    checkpoint(yield_fn)
    local score = 0
    for sq, code in pairs(board) do
        checkpoint(yield_fn)
        local value = pieceType(code) == KING and 175 or 100
        if pieceType(code) == MAN then
            local rank = tonumber(sq:sub(2, 2)) or 0
            value = value + (pieceColor(code) == WHITE and rank * 4 or (9 - rank) * 4)
        end
        score = score + (pieceColor(code) == color and value or -value)
    end

    local mobility_turn = color
    local mobility = #movesFor(board, mobility_turn) * 3
    if turn ~= color then
        mobility = mobility - #movesFor(board, turn) * 2
    end
    return score + mobility
end

local function moveScore(move)
    local score = 0
    if move.captures and #move.captures > 0 then score = score + #move.captures * 500 end
    if move.promotion then score = score + 180 end
    local _, rank = coords(move.to)
    if move.color == WHITE then
        score = score + rank * 4
    else
        score = score + (9 - rank) * 4
    end
    return score
end

local function orderedMoves(board, turn)
    local moves = movesFor(board, turn)
    for _, move in ipairs(moves) do move._score = moveScore(move) end
    table.sort(moves, function(a, b) return a._score > b._score end)
    return moves
end

local function terminalScore(winner, color, depth)
    return (winner == color and 100000 or -100000) + depth
end

local function search(board, turn, depth, alpha, beta, color, cache, yield_fn)
    checkpoint(yield_fn)
    local moves = orderedMoves(board, turn)
    if #moves == 0 then return terminalScore(other(turn), color, depth) end
    if depth <= 0 then return evaluate(board, turn, color, yield_fn) end

    local key = boardKey(board, turn, depth)
    local cached = cache[key]
    if cached then return cached end

    local full_search = true
    if turn == color then
        local best = -math.huge
        for _, move in ipairs(moves) do
            checkpoint(yield_fn)
            local score = search(applyMove(board, move), other(turn), depth - 1, alpha, beta, color, cache, yield_fn)
            if score > best then best = score end
            if best > alpha then alpha = best end
            if alpha >= beta then
                full_search = false
                break
            end
        end
        if full_search then cache[key] = best end
        return best
    end

    local best = math.huge
    for _, move in ipairs(moves) do
        checkpoint(yield_fn)
        local score = search(applyMove(board, move), other(turn), depth - 1, alpha, beta, color, cache, yield_fn)
        if score < best then best = score end
        if best < beta then beta = best end
        if alpha >= beta then
            full_search = false
            break
        end
    end
    if full_search then cache[key] = best end
    return best
end

function AI.bestMove(game, depth, blunder_chance, yield_fn)
    local color = game:turn()
    local board = boardFromGame(game)
    local moves = orderedMoves(board, color)
    if #moves == 0 then return nil end

    blunder_chance = tonumber(blunder_chance) or 0
    if blunder_chance > 0 and math.random() < blunder_chance then
        return moves[math.random(#moves)]
    end

    depth = math.max(1, tonumber(depth) or 3)
    local cache = {}
    local best_moves = {}
    local best_score = -math.huge

    for _, move in ipairs(moves) do
        checkpoint(yield_fn)
        local score = search(applyMove(board, move), other(color), depth - 1, -math.huge, math.huge, color, cache, yield_fn)
        if score > best_score then
            best_score = score
            best_moves = { move }
        elseif score == best_score then
            best_moves[#best_moves + 1] = move
        end
    end

    return best_moves[math.random(#best_moves)]
end

return AI
