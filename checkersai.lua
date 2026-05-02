local Checkers = require("checkersgame")

local AI = {}

local function evaluate(game, color)
    local score = 0
    local mobility = 0
    for sq, piece in pairs(game.board_state) do
        local value = piece.type == Checkers.KING and 175 or 100
        if piece.type == Checkers.MAN then
            local rank = tonumber(sq:sub(2, 2)) or 0
            if piece.color == Checkers.WHITE then
                value = value + rank * 4
            else
                value = value + (9 - rank) * 4
            end
        end
        if piece.color == color then
            score = score + value
        else
            score = score - value
        end
    end
    if game:turn() == color then
        mobility = #game:moves({ verbose = true }) * 3
    else
        local clone = game:clone()
        clone.self_turn = color
        mobility = #clone:moves({ verbose = true }) * 3
    end
    return score + mobility
end

local function search(game, depth, alpha, beta, color)
    local over, result = game:game_over()
    if over then
        local winner = result == "1-0" and Checkers.WHITE or Checkers.BLACK
        return winner == color and 100000 or -100000
    end
    if depth <= 0 then
        return evaluate(game, color)
    end

    local moves = game:moves({ verbose = true })
    if game:turn() == color then
        local best = -math.huge
        for _, move in ipairs(moves) do
            local clone = game:clone()
            clone:move({ from = move.from, to = move.to })
            local score = search(clone, depth - 1, alpha, beta, color)
            if score > best then best = score end
            if best > alpha then alpha = best end
            if alpha >= beta then break end
        end
        return best
    end

    local best = math.huge
    for _, move in ipairs(moves) do
        local clone = game:clone()
        clone:move({ from = move.from, to = move.to })
        local score = search(clone, depth - 1, alpha, beta, color)
        if score < best then best = score end
        if best < beta then beta = best end
        if alpha >= beta then break end
    end
    return best
end

function AI.bestMove(game, depth, blunder_chance)
    local moves = game:moves({ verbose = true })
    if #moves == 0 then return nil end

    blunder_chance = tonumber(blunder_chance) or 0
    if blunder_chance > 0 and math.random() < blunder_chance then
        return moves[math.random(#moves)]
    end

    depth = math.max(1, tonumber(depth) or 3)
    local color = game:turn()
    local best_move = moves[1]
    local best_score = -math.huge

    for _, move in ipairs(moves) do
        local clone = game:clone()
        clone:move({ from = move.from, to = move.to })
        local score = search(clone, depth - 1, -math.huge, math.huge, color)
        if score > best_score then
            best_score = score
            best_move = move
        end
    end

    return best_move
end

return AI
