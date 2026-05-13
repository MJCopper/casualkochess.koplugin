local Reversi = require("reversigame")

local AI = {}

-- Classic Othello static position weights.
-- Corners (a1/h1/a8/h8) are extremely valuable; X-squares (diagonally adjacent
-- to corners: b2/g2/b7/g7) are dangerous; C-squares are moderately negative.
local WEIGHTS = {
    [1] = {120, -20, 20,  5,  5, 20, -20, 120},
    [2] = {-20, -40, -5, -5, -5, -5, -40, -20},
    [3] = { 20,  -5, 15,  3,  3, 15,  -5,  20},
    [4] = {  5,  -5,  3,  3,  3,  3,  -5,   5},
    [5] = {  5,  -5,  3,  3,  3,  3,  -5,   5},
    [6] = { 20,  -5, 15,  3,  3, 15,  -5,  20},
    [7] = {-20, -40, -5, -5, -5, -5, -40, -20},
    [8] = {120, -20, 20,  5,  5, 20, -20, 120},
}

local function sqWeight(sq)
    local file = string.byte(sq:sub(1,1)) - string.byte("a") + 1
    local rank = tonumber(sq:sub(2,2))
    return WEIGHTS[rank][file]
end

local function other(color)
    return color == Reversi.WHITE and Reversi.BLACK or Reversi.WHITE
end

local function evaluate(game, color)
    local opp   = other(color)
    local total = 0
    for _ in pairs(game.board_state) do total = total + 1 end
    local empty = 64 - total

    -- Endgame: maximise disc count directly.
    if empty <= 12 then
        local mine, theirs = 0, 0
        for _, p in pairs(game.board_state) do
            if p.color == color then mine = mine + 1 else theirs = theirs + 1 end
        end
        return (mine - theirs) * 500
    end

    -- Positional score from static weight table.
    local pos = 0
    for sq, piece in pairs(game.board_state) do
        local w = sqWeight(sq)
        if piece.color == color then pos = pos + w else pos = pos - w end
    end

    -- Relative mobility: having more moves than the opponent is good.
    local my_moves = #game:computeValidMovesFor(color)
    local op_moves = #game:computeValidMovesFor(opp)
    local mobility = 0
    if my_moves + op_moves > 0 then
        mobility = 100 * (my_moves - op_moves) / (my_moves + op_moves)
    end

    return pos * 10 + mobility * 8
end

-- Sort moves best-first by static weight so alpha-beta prunes more aggressively.
local function sortMoves(moves)
    table.sort(moves, function(a, b)
        return sqWeight(a.to) > sqWeight(b.to)
    end)
end

local function search(game, depth, alpha, beta, color)
    local over, result = game:game_over()
    if over then
        if result == "1-0" then
            return (color == Reversi.WHITE) and  100000 or -100000
        elseif result == "0-1" then
            return (color == Reversi.BLACK) and  100000 or -100000
        else
            return 0
        end
    end
    if depth <= 0 then
        return evaluate(game, color)
    end

    local moves = game:moves()
    sortMoves(moves)

    if game:turn() == color then
        local best = -math.huge
        for _, move in ipairs(moves) do
            local clone = game:clone()
            clone:move{ from = move.from, to = move.to }
            local score = search(clone, depth - 1, alpha, beta, color)
            if score > best then best = score end
            if best > alpha then alpha = best end
            if alpha >= beta then break end
        end
        return best
    else
        local best = math.huge
        for _, move in ipairs(moves) do
            local clone = game:clone()
            clone:move{ from = move.from, to = move.to }
            local score = search(clone, depth - 1, alpha, beta, color)
            if score < best then best = score end
            if best < beta then beta = best end
            if alpha >= beta then break end
        end
        return best
    end
end

function AI.bestMove(game, depth, blunder_chance)
    local moves = game:moves()
    if #moves == 0 then return nil end

    blunder_chance = tonumber(blunder_chance) or 0
    if blunder_chance > 0 and math.random() < blunder_chance then
        return moves[math.random(#moves)]
    end

    depth = tonumber(depth) or 4
    if depth == 0 then depth = 5 end
    depth = math.max(1, math.min(6, depth))

    local color = game:turn()
    sortMoves(moves)

    local best_moves = {}
    local best_score = -math.huge
    for _, move in ipairs(moves) do
        local clone = game:clone()
        clone:move{ from = move.from, to = move.to }
        local score = search(clone, depth - 1, -math.huge, math.huge, color)
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
