local Reversi = require("reversigame")

local AI = {}

local WHITE = Reversi.WHITE
local BLACK = Reversi.BLACK
local EMPTY = "."
local BOARD_SIZE = 8
local BOARD_SQUARES = 64
local DIRS = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
}
local STATIC_WEIGHTS = {
    120, -20, 20, 5, 5, 20, -20, 120,
    -20, -40, -5, -5, -5, -5, -40, -20,
    20, -5, 15, 3, 3, 15, -5, 20,
    5, -5, 3, 3, 3, 3, -5, 5,
    5, -5, 3, 3, 3, 3, -5, 5,
    20, -5, 15, 3, 3, 15, -5, 20,
    -20, -40, -5, -5, -5, -5, -40, -20,
    120, -20, 20, 5, 5, 20, -20, 120,
}
local CORNERS = { [1] = true, [8] = true, [57] = true, [64] = true }
local DANGEROUS = {
    [2] = 1, [9] = 1, [10] = 1,
    [7] = 8, [15] = 8, [16] = 8,
    [49] = 57, [50] = 57, [58] = 57,
    [55] = 64, [56] = 64, [63] = 64,
}
local EDGE = {}
for i = 1, 8 do
    EDGE[i] = true
    EDGE[56 + i] = true
    EDGE[(i - 1) * 8 + 1] = true
    EDGE[i * 8] = true
end
local CORNER_LINES = {
    { corner = 1, dirs = { { 1, 0 }, { 0, 1 } } },
    { corner = 8, dirs = { { -1, 0 }, { 0, 1 } } },
    { corner = 57, dirs = { { 1, 0 }, { 0, -1 } } },
    { corner = 64, dirs = { { -1, 0 }, { 0, -1 } } },
}

local function checkpoint(fn)
    if fn then fn() end
end

local function other(color)
    return color == WHITE and BLACK or WHITE
end

local function index(file, rank)
    if file < 1 or file > BOARD_SIZE or rank < 1 or rank > BOARD_SIZE then return nil end
    return (rank - 1) * BOARD_SIZE + file
end

local function coords(idx)
    local rank = math.floor((idx - 1) / BOARD_SIZE) + 1
    local file = idx - (rank - 1) * BOARD_SIZE
    return file, rank
end

local function square(idx)
    local file, rank = coords(idx)
    return string.char(string.byte("a") + file - 1) .. tostring(rank)
end

local function idxFromSquare(sq)
    local file = string.byte(sq:sub(1, 1)) - string.byte("a") + 1
    local rank = tonumber(sq:sub(2, 2))
    return index(file, rank)
end

local function copyBoard(board)
    local out = {}
    for i = 1, BOARD_SQUARES do out[i] = board[i] end
    return out
end

local function boardFromGame(game)
    local board = {}
    for i = 1, BOARD_SQUARES do board[i] = EMPTY end
    for sq, piece in pairs(game.board_state) do
        local idx = idxFromSquare(sq)
        if idx then board[idx] = piece.color end
    end
    return board
end

local function flipsFor(board, idx, color)
    if board[idx] ~= EMPTY then return nil end
    local opponent = other(color)
    local file, rank = coords(idx)
    local flips = {}

    for _, dir in ipairs(DIRS) do
        local line = {}
        local f, r = file + dir[1], rank + dir[2]
        while true do
            local scan = index(f, r)
            if not scan or board[scan] == EMPTY then
                line = nil
                break
            end
            if board[scan] == color then break end
            if board[scan] ~= opponent then
                line = nil
                break
            end
            line[#line + 1] = scan
            f, r = f + dir[1], r + dir[2]
        end
        if line then
            for _, flip in ipairs(line) do flips[#flips + 1] = flip end
        end
    end

    if #flips == 0 then return nil end
    return flips
end

local function movesFor(board, color)
    local moves = {}
    local candidates = {}
    local opponent = other(color)
    for idx = 1, BOARD_SQUARES do
        if board[idx] == opponent then
            local file, rank = coords(idx)
            for _, dir in ipairs(DIRS) do
                local empty = index(file + dir[1], rank + dir[2])
                if empty and board[empty] == EMPTY then candidates[empty] = true end
            end
        end
    end
    for idx in pairs(candidates) do
        local flips = flipsFor(board, idx, color)
        if flips then
            moves[#moves + 1] = { idx = idx, flips = flips }
        end
    end
    return moves
end

local function applyMove(board, move, color)
    local next_board = copyBoard(board)
    next_board[move.idx] = color
    for _, flip in ipairs(move.flips) do next_board[flip] = color end
    return next_board
end

local function toGameMove(move, color)
    local flips = {}
    for i, idx in ipairs(move.flips or {}) do flips[i] = square(idx) end
    local sq = square(move.idx)
    return {
        from = sq,
        to = sq,
        color = color,
        flips = flips,
        san = sq,
        notation = sq,
    }
end

local function boardKey(board, turn, depth)
    local out = { turn, ":", tostring(depth), ":" }
    for i = 1, BOARD_SQUARES do out[#out + 1] = board[i] end
    return table.concat(out)
end

local function countPieces(board)
    local white, black = 0, 0
    for i = 1, BOARD_SQUARES do
        if board[i] == WHITE then
            white = white + 1
        elseif board[i] == BLACK then
            black = black + 1
        end
    end
    return white, black
end

local function potentialMobility(board, color)
    local count = 0
    local seen = {}
    local opponent = other(color)
    for idx = 1, BOARD_SQUARES do
        if board[idx] == opponent then
            local file, rank = coords(idx)
            for _, dir in ipairs(DIRS) do
                local empty = index(file + dir[1], rank + dir[2])
                if empty and board[empty] == EMPTY and not seen[empty] then
                    seen[empty] = true
                    count = count + 1
                end
            end
        end
    end
    return count
end

local function frontierDiscs(board, color)
    local count = 0
    for idx = 1, BOARD_SQUARES do
        if board[idx] == color then
            local file, rank = coords(idx)
            for _, dir in ipairs(DIRS) do
                local adj = index(file + dir[1], rank + dir[2])
                if adj and board[adj] == EMPTY then
                    count = count + 1
                    break
                end
            end
        end
    end
    return count
end

local function stableEdgeDiscs(board, color)
    local count = 0
    local seen = {}
    for _, corner in ipairs(CORNER_LINES) do
        if board[corner.corner] == color then
            if not seen[corner.corner] then
                seen[corner.corner] = true
                count = count + 1
            end
            for _, dir in ipairs(corner.dirs) do
                local file, rank = coords(corner.corner)
                file, rank = file + dir[1], rank + dir[2]
                while true do
                    local idx = index(file, rank)
                    if not idx or board[idx] ~= color then break end
                    if not seen[idx] then
                        seen[idx] = true
                        count = count + 1
                    end
                    file, rank = file + dir[1], rank + dir[2]
                end
            end
        end
    end
    return count
end

local function evaluate(board, color, yield_fn)
    checkpoint(yield_fn)
    local opponent = other(color)
    local white, black = countPieces(board)
    local total = white + black
    local empty = BOARD_SQUARES - total
    local my_moves = #movesFor(board, color)
    local opp_moves = #movesFor(board, opponent)
    local early = empty > 36
    local late = empty <= 14
    local mobility_weight = early and 38 or (late and 8 or 28)
    local potential_weight = early and 14 or (late and 2 or 8)
    local frontier_weight = early and 14 or (late and 3 or 9)
    local disc_weight = late and 8 or (empty <= 24 and 3 or 0)
    local score = (my_moves - opp_moves) * mobility_weight

    score = score + (potentialMobility(board, color) - potentialMobility(board, opponent)) * potential_weight
    score = score - (frontierDiscs(board, color) - frontierDiscs(board, opponent)) * frontier_weight
    score = score + (stableEdgeDiscs(board, color) - stableEdgeDiscs(board, opponent)) * 65
    score = score + (color == WHITE and (white - black) or (black - white)) * disc_weight

    for idx = 1, BOARD_SQUARES do
        checkpoint(yield_fn)
        local piece = board[idx]
        if piece ~= EMPTY then
            local sign = piece == color and 1 or -1
            score = score + sign * STATIC_WEIGHTS[idx] * 3
            if CORNERS[idx] then
                score = score + sign * 700
            elseif DANGEROUS[idx] and board[DANGEROUS[idx]] == EMPTY then
                score = score - sign * 220
            elseif EDGE[idx] then
                score = score + sign * 18
            end
        end
    end

    return score
end

local function terminalScore(board, color, ply)
    local white, black = countPieces(board)
    if white == black then return 0 end
    local won = color == WHITE and white > black or black > white
    local margin = math.abs(white - black)
    return (won and 100000 or -100000) + (won and margin or -margin) - ply
end

local function branchLimit(depth)
    if depth >= 6 then return 3 end
    if depth >= 5 then return 4 end
    if depth >= 4 then return 5 end
    return nil
end

local function orderScore(board, move, color)
    local score = #(move.flips or {}) * 8 + STATIC_WEIGHTS[move.idx] * 4
    if CORNERS[move.idx] then
        score = score + 1200
    elseif DANGEROUS[move.idx] and board[DANGEROUS[move.idx]] == EMPTY then
        score = score - 450
    elseif EDGE[move.idx] then
        score = score + 80
    end
    return score
end

local function orderedMoves(board, color, limit)
    local moves = movesFor(board, color)
    for _, move in ipairs(moves) do move._score = orderScore(board, move, color) end
    table.sort(moves, function(a, b) return a._score > b._score end)
    if limit and #moves > limit then
        for i = #moves, limit + 1, -1 do moves[i] = nil end
    end
    return moves
end

local function bestHeuristicMove(board, moves, color, yield_fn)
    local best = {}
    local best_score = -math.huge
    for _, move in ipairs(moves) do
        checkpoint(yield_fn)
        local score = evaluate(applyMove(board, move, color), color, yield_fn)
        if score > best_score then
            best_score = score
            best = { move }
        elseif score == best_score then
            best[#best + 1] = move
        end
    end
    return best[math.random(#best)]
end

local function weakerMove(moves)
    table.sort(moves, function(a, b) return (a._score or 0) > (b._score or 0) end)
    local start = math.max(1, math.floor(#moves / 2) + 1)
    return moves[math.random(start, #moves)]
end

local function search(board, turn, depth, alpha, beta, color, ply, cache, yield_fn)
    checkpoint(yield_fn)
    local moves = orderedMoves(board, turn, branchLimit(depth))
    local opponent = other(turn)
    if #moves == 0 then
        if #movesFor(board, opponent) == 0 then
            return terminalScore(board, color, ply)
        end
        return search(board, opponent, depth - 1, alpha, beta, color, ply + 1, cache, yield_fn)
    end
    if depth <= 0 then return evaluate(board, color, yield_fn) end

    local key = boardKey(board, turn, depth)
    local cached = cache[key]
    if cached then return cached end

    local full_search = true
    if turn == color then
        local best = -math.huge
        for _, move in ipairs(moves) do
            checkpoint(yield_fn)
            local score = search(applyMove(board, move, turn), opponent, depth - 1, alpha, beta, color, ply + 1, cache, yield_fn)
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
        local score = search(applyMove(board, move, turn), opponent, depth - 1, alpha, beta, color, ply + 1, cache, yield_fn)
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
        if math.random() < 0.5 then
            return toGameMove(moves[math.random(#moves)], color)
        end
        return toGameMove(weakerMove(moves), color)
    end

    depth = tonumber(depth) or 4
    if depth == 0 then depth = 6 end
    depth = math.max(1, math.min(6, depth))

    if depth <= 3 then
        return toGameMove(bestHeuristicMove(board, moves, color, yield_fn), color)
    end

    moves = orderedMoves(board, color, branchLimit(depth))
    local cache = {}
    local best = {}
    local best_score = -math.huge
    for _, move in ipairs(moves) do
        checkpoint(yield_fn)
        local score = search(applyMove(board, move, color), other(color), depth - 1, -math.huge, math.huge, color, 1, cache, yield_fn)
        if score > best_score then
            best_score = score
            best = { move }
        elseif score == best_score then
            best[#best + 1] = move
        end
    end
    return toGameMove(best[math.random(#best)], color)
end

return AI
