local Reversi = require("reversigame")

local AI = {}

local STATIC_WEIGHTS = {
    [1] = { 120, -20, 20, 5, 5, 20, -20, 120 },
    [2] = { -20, -40, -5, -5, -5, -5, -40, -20 },
    [3] = { 20, -5, 15, 3, 3, 15, -5, 20 },
    [4] = { 5, -5, 3, 3, 3, 3, -5, 5 },
    [5] = { 5, -5, 3, 3, 3, 3, -5, 5 },
    [6] = { 20, -5, 15, 3, 3, 15, -5, 20 },
    [7] = { -20, -40, -5, -5, -5, -5, -40, -20 },
    [8] = { 120, -20, 20, 5, 5, 20, -20, 120 },
}

local CORNERS = { a1 = true, a8 = true, h1 = true, h8 = true }
local DANGEROUS = {
    a2 = "a1", b1 = "a1", b2 = "a1",
    a7 = "a8", b8 = "a8", b7 = "a8",
    h2 = "h1", g1 = "h1", g2 = "h1",
    h7 = "h8", g8 = "h8", g7 = "h8",
}
local DIRS = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
}
local CORNER_LINES = {
    { corner = "a1", lines = { { 1, 0 }, { 0, 1 } } },
    { corner = "a8", lines = { { 1, 0 }, { 0, -1 } } },
    { corner = "h1", lines = { { -1, 0 }, { 0, 1 } } },
    { corner = "h8", lines = { { -1, 0 }, { 0, -1 } } },
}

local function checkpoint(fn)
    if fn then fn() end
end

local function other(color)
    return color == Reversi.WHITE and Reversi.BLACK or Reversi.WHITE
end

local function square(file, rank)
    if file < 1 or file > 8 or rank < 1 or rank > 8 then return nil end
    return string.char(string.byte("a") + file - 1) .. tostring(rank)
end

local function coords(sq)
    local file = string.byte(sq:sub(1, 1)) - string.byte("a") + 1
    local rank = tonumber(sq:sub(2, 2))
    return file, rank
end

local function staticWeight(sq)
    local file, rank = coords(sq)
    return (STATIC_WEIGHTS[rank] and STATIC_WEIGHTS[rank][file]) or 0
end

local function pieceScore(game, color)
    local white, black = game:counts()
    return color == Reversi.WHITE and (white - black) or (black - white)
end

local function potentialMobility(game, color)
    local count = 0
    local seen = {}
    local opponent = other(color)
    for sq, piece in pairs(game.board_state) do
        if piece.color == opponent then
            local file, rank = coords(sq)
            for _, dir in ipairs(DIRS) do
                local empty = square(file + dir[1], rank + dir[2])
                if empty and not game.board_state[empty] and not seen[empty] then
                    seen[empty] = true
                    count = count + 1
                end
            end
        end
    end
    return count
end

local function frontierDiscs(game, color)
    local count = 0
    for sq, piece in pairs(game.board_state) do
        if piece.color == color then
            local file, rank = coords(sq)
            for _, dir in ipairs(DIRS) do
                local adj = square(file + dir[1], rank + dir[2])
                if adj and not game.board_state[adj] then
                    count = count + 1
                    break
                end
            end
        end
    end
    return count
end

local function stableEdgeDiscs(game, color)
    local count = 0
    local seen = {}
    for _, corner in ipairs(CORNER_LINES) do
        local piece = game.board_state[corner.corner]
        if piece and piece.color == color then
            if not seen[corner.corner] then
                seen[corner.corner] = true
                count = count + 1
            end
            for _, dir in ipairs(corner.lines) do
                local file, rank = coords(corner.corner)
                file, rank = file + dir[1], rank + dir[2]
                while true do
                    local sq = square(file, rank)
                    local edge_piece = sq and game.board_state[sq]
                    if not edge_piece or edge_piece.color ~= color then break end
                    if not seen[sq] then
                        seen[sq] = true
                        count = count + 1
                    end
                    file, rank = file + dir[1], rank + dir[2]
                end
            end
        end
    end
    return count
end

local function evaluate(game, color, yield_fn)
    checkpoint(yield_fn)
    local opponent = other(color)
    local my_moves = #game:moves({ color = color })
    local opp_moves = #game:moves({ color = opponent })
    local white, black = game:counts()
    local total = white + black
    local empty = 64 - total
    local early = empty > 36
    local late = empty <= 14
    local mobility_weight = early and 38 or (late and 8 or 28)
    local potential_weight = early and 14 or (late and 2 or 8)
    local frontier_weight = early and 14 or (late and 3 or 9)
    local disc_weight = late and 8 or (empty <= 24 and 3 or 0)
    local score = (my_moves - opp_moves) * mobility_weight
    score = score + (potentialMobility(game, color) - potentialMobility(game, opponent)) * potential_weight
    score = score - (frontierDiscs(game, color) - frontierDiscs(game, opponent)) * frontier_weight
    score = score + (stableEdgeDiscs(game, color) - stableEdgeDiscs(game, opponent)) * 65

    for sq, piece in pairs(game.board_state) do
        checkpoint(yield_fn)
        local sign = piece.color == color and 1 or -1
        score = score + sign * staticWeight(sq) * 3
        if CORNERS[sq] then
            score = score + sign * 700
        elseif DANGEROUS[sq] and not game.board_state[DANGEROUS[sq]] then
            score = score - sign * 220
        elseif sq:match("^[ah]") or sq:match("[18]$") then
            score = score + sign * 18
        end
    end

    score = score + pieceScore(game, color) * disc_weight
    return score
end

local function moveScore(game, move, color, yield_fn)
    checkpoint(yield_fn)
    local score = #(move.flips or {}) * 3 + staticWeight(move.to) * 4
    if CORNERS[move.to] then
        score = score + 900
    elseif DANGEROUS[move.to] and not game.board_state[DANGEROUS[move.to]] then
        score = score - 350
    elseif move.to:match("^[ah]") or move.to:match("[18]$") then
        score = score + 55
    end

    local clone = game:clone()
    clone:move{ to = move.to }
    score = score + evaluate(clone, color, yield_fn)
    return score
end

local function orderedMoves(game, color, yield_fn, limit)
    local moves = game:moves({ verbose = true })
    for _, move in ipairs(moves) do
        checkpoint(yield_fn)
        move._score = moveScore(game, move, color, yield_fn)
    end
    table.sort(moves, function(a, b)
        return a._score > b._score
    end)
    if limit and #moves > limit then
        for i = #moves, limit + 1, -1 do
            moves[i] = nil
        end
    end
    return moves
end

local function bestHeuristicMove(game, moves, color, yield_fn)
    local best = {}
    local best_score = -math.huge
    for _, move in ipairs(moves) do
        checkpoint(yield_fn)
        local score = move._score or moveScore(game, move, color, yield_fn)
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
    table.sort(moves, function(a, b)
        return (a._score or 0) > (b._score or 0)
    end)
    local start = math.max(1, math.floor(#moves / 2) + 1)
    return moves[math.random(start, #moves)]
end

local function terminalScore(result, color, ply)
    if result == "1/2-1/2" then return 0 end
    local winner = result == "1-0" and Reversi.WHITE or Reversi.BLACK
    return (winner == color and 100000 or -100000) - ply
end

local function branchLimit(depth)
    if depth >= 6 then return 3 end
    if depth >= 5 then return 4 end
    if depth >= 4 then return 5 end
    return 6
end

local function search(game, depth, alpha, beta, color, ply, yield_fn)
    checkpoint(yield_fn)
    local over, result = game:game_over()
    if over then return terminalScore(result, color, ply) end
    if depth <= 0 then return evaluate(game, color, yield_fn) end

    local moves = orderedMoves(game, color, yield_fn, branchLimit(depth))
    if #moves == 0 then
        local clone = game:clone()
        clone.self_turn = other(clone.self_turn)
        return search(clone, depth - 1, alpha, beta, color, ply + 1, yield_fn)
    end

    if game:turn() == color then
        local best = -math.huge
        for _, move in ipairs(moves) do
            checkpoint(yield_fn)
            local clone = game:clone()
            clone:move{ to = move.to }
            local score = search(clone, depth - 1, alpha, beta, color, ply + 1, yield_fn)
            if score > best then best = score end
            if best > alpha then alpha = best end
            if alpha >= beta then break end
        end
        return best
    end

    local best = math.huge
    for _, move in ipairs(moves) do
        checkpoint(yield_fn)
        local clone = game:clone()
        clone:move{ to = move.to }
        local score = search(clone, depth - 1, alpha, beta, color, ply + 1, yield_fn)
        if score < best then best = score end
        if best < beta then beta = best end
        if alpha >= beta then break end
    end
    return best
end

function AI.bestMove(game, depth, blunder_chance, yield_fn)
    local color = game:turn()
    local moves = orderedMoves(game, color, yield_fn)
    if #moves == 0 then return nil end

    blunder_chance = tonumber(blunder_chance) or 0
    if blunder_chance > 0 and math.random() < blunder_chance then
        return weakerMove(moves)
    end

    depth = tonumber(depth) or 4
    if depth == 0 then depth = 6 end
    depth = math.max(1, math.min(6, depth))

    if depth <= 3 then
        return bestHeuristicMove(game, moves, color, yield_fn)
    end

    moves = orderedMoves(game, color, yield_fn, branchLimit(depth))
    local best = {}
    local best_score = -math.huge
    for _, move in ipairs(moves) do
        checkpoint(yield_fn)
        local clone = game:clone()
        clone:move{ to = move.to }
        local score = search(clone, depth - 1, -math.huge, math.huge, color, 1, yield_fn)
        if score > best_score then
            best_score = score
            best = { move }
        elseif score == best_score then
            best[#best + 1] = move
        end
    end
    return best[math.random(#best)]
end

return AI
