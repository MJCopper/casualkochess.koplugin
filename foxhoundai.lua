local Game = require("foxhoundgame")

local AI = {}

local function checkpoint(fn)
    if fn then fn() end
end

local function rankOf(sq)
    return tonumber(sq and sq:sub(2, 2)) or 0
end

local function evaluate(game, color, yield_fn)
    checkpoint(yield_fn)
    local fox = game:fox_square()
    if not fox then return color == Game.BLACK and 100000 or -100000 end

    local fox_rank = rankOf(fox)
    local clone = game:clone()
    clone.self_turn = Game.WHITE
    local fox_mobility = #clone:moves({ verbose = true })
    clone.self_turn = Game.BLACK
    local hound_mobility = #clone:moves({ verbose = true })

    local score = fox_rank * 120 + fox_mobility * 35 - hound_mobility * 8
    for sq, piece in pairs(game.board_state) do
        checkpoint(yield_fn)
        if piece.type == Game.HOUND then
            local hound_rank = rankOf(sq)
            if hound_rank >= fox_rank then
                score = score - (hound_rank - fox_rank) * 10
            else
                score = score + 45
            end
        end
    end

    return color == Game.WHITE and score or -score
end

local function terminalScore(result, color, ply)
    local winner = result == "1-0" and Game.WHITE or Game.BLACK
    return (winner == color and 100000 or -100000) - ply
end

local function moveScore(game, move, color, yield_fn)
    checkpoint(yield_fn)
    local clone = game:clone()
    clone:move{ from = move.from, to = move.to }
    return evaluate(clone, color, yield_fn)
end

local function orderedMoves(game, color, yield_fn)
    local moves = game:moves({ verbose = true })
    for _, move in ipairs(moves) do
        move._score = moveScore(game, move, color, yield_fn)
    end
    table.sort(moves, function(a, b)
        return a._score > b._score
    end)
    return moves
end

local function search(game, depth, alpha, beta, color, ply, yield_fn)
    checkpoint(yield_fn)
    local over, result = game:game_over()
    if over then return terminalScore(result, color, ply) end
    if depth <= 0 then return evaluate(game, color, yield_fn) end

    local moves = orderedMoves(game, color, yield_fn)
    if game:turn() == color then
        local best = -math.huge
        for _, move in ipairs(moves) do
            checkpoint(yield_fn)
            local clone = game:clone()
            clone:move{ from = move.from, to = move.to }
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
        clone:move{ from = move.from, to = move.to }
        local score = search(clone, depth - 1, alpha, beta, color, ply + 1, yield_fn)
        if score < best then best = score end
        if best < beta then beta = best end
        if alpha >= beta then break end
    end
    return best
end

function AI.bestMove(game, depth, blunder_chance, yield_fn)
    if game.setup_pending then return nil end
    local color = game:turn()
    local moves = orderedMoves(game, color, yield_fn)
    if #moves == 0 then return nil end

    blunder_chance = tonumber(blunder_chance) or 0
    if blunder_chance > 0 and math.random() < blunder_chance then
        return moves[math.random(#moves)]
    end

    depth = tonumber(depth) or 4
    if depth == 0 then depth = 6 end
    depth = math.max(1, math.min(6, depth + 1))

    local best = {}
    local best_score = -math.huge
    for _, move in ipairs(moves) do
        checkpoint(yield_fn)
        local clone = game:clone()
        clone:move{ from = move.from, to = move.to }
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
