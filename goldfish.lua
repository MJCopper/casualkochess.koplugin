local Chess = require("chess")

local Goldfish = {}

local piece_values = {
    p = 100,
    n = 320,
    b = 330,
    r = 500,
    q = 900,
    k = 0,
}

local center_squares = {
    d4 = true, e4 = true, d5 = true, e5 = true,
    c3 = true, d3 = true, e3 = true, f3 = true,
    c4 = true, f4 = true, c5 = true, f5 = true,
    c6 = true, d6 = true, e6 = true, f6 = true,
}

local function squareCoords(square)
    if type(square) ~= "string" or #square ~= 2 then return nil end
    local file = string.byte(square:sub(1, 1)) - string.byte("a") + 1
    local rank = tonumber(square:sub(2, 2))
    if not file or not rank or file < 1 or file > 8 or rank < 1 or rank > 8 then return nil end
    return file, rank
end

local function squareName(file, rank)
    return string.char(string.byte("a") + file - 1) .. tostring(rank)
end

local function material(game)
    local score = 0
    for rank_index, row in ipairs(game.board()) do
        local rank = 9 - rank_index
        for file, piece in ipairs(row) do
            if piece then
                local value = piece_values[piece.type] or 0
                local square = squareName(file, rank)
                if piece.type == "p" then
                    local advance = piece.color == Chess.WHITE and (rank - 2) or (7 - rank)
                    value = value + math.max(0, advance) * 8
                    if rank == 7 or rank == 2 then value = value + 45 end
                elseif piece.type == "n" or piece.type == "b" then
                    if center_squares[square] then value = value + 20 end
                elseif piece.type == "r" then
                    if rank == 7 or rank == 2 then value = value + 12 end
                elseif piece.type == "k" then
                    local edge = math.min(file - 1, 8 - file) + math.min(rank - 1, 8 - rank)
                    value = value + math.min(20, edge * 4)
                end
                score = score + (piece.color == Chess.WHITE and value or -value)
            end
        end
    end
    return score
end

local function evaluate(game, turn)
    local score = material(game)
    if game.in_check and game.in_check() then
        score = score + (game.turn() == Chess.WHITE and -35 or 35)
    end
    return turn == Chess.WHITE and score or -score
end

local function moveToUci(move)
    if not move then return "0000" end
    return move.from .. move.to .. (move.promotion or "")
end

local function randomMove(moves)
    if #moves == 0 then return nil end
    return moves[math.random(#moves)]
end

local function terminalScore(result, turn, ply)
    if result == "1/2-1/2" then return 0 end
    local white_wins = result == "1-0"
    local turn_wins = (turn == Chess.WHITE and white_wins) or (turn == Chess.BLACK and not white_wins)
    return (turn_wins and 100000 or -100000) - ply
end

local function search(game, depth, turn, ply)
    local over, result = game.game_over()
    if over then return terminalScore(result, turn, ply) end
    if depth <= 0 then return evaluate(game, turn) end

    local maximizing = game.turn() == turn
    local moves = game.moves({ verbose = true })
    if #moves == 0 then return evaluate(game, turn) end

    local best = maximizing and -1000000 or 1000000
    for _, move in ipairs(moves) do
        local played = game.move{ from = move.from, to = move.to, promotion = move.promotion }
        if played then
            local score = search(game, depth - 1, turn, ply + 1)
            game.undo()
            if maximizing then
                if score > best then best = score end
            elseif score < best then
                best = score
            end
        end
    end
    return best
end

local function chooseMove(game, opts)
    opts = opts or {}
    local moves = game.moves({ verbose = true })
    if #moves == 0 then return nil end

    local turn = game.turn()
    local depth = 2
    local scored = {}
    for _, move in ipairs(moves) do
        local played = game.move{ from = move.from, to = move.to, promotion = move.promotion }
        local score
        if played then
            local over, result = game.game_over()
            if over then
                score = terminalScore(result, turn, 1)
            else
                score = search(game, depth - 1, turn, 1)
            end
            game.undo()
        else
            score = -100000
        end
        scored[#scored + 1] = { move = move, score = score }
    end

    table.sort(scored, function(a, b) return a.score > b.score end)

    local best_score = scored[1].score
    local best = {}
    for _, item in ipairs(scored) do
        if item.score ~= best_score then break end
        best[#best + 1] = item.move
    end
    return randomMove(best)
end

function Goldfish.bestMove(game, opts)
    return chooseMove(game, opts)
end

function Goldfish.bestMoveUci(game, opts)
    return moveToUci(chooseMove(game, opts))
end

return Goldfish
