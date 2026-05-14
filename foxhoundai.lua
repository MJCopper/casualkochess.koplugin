local Game = require("foxhoundgame")

local AI = {}

local FOX_DIRS = { { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }
local HOUND_DIRS = { { 1, -1 }, { -1, -1 } }

local function checkpoint(fn)
    if fn then fn() end
end

local function other(color)
    return color == Game.WHITE and Game.BLACK or Game.WHITE
end

local function coords(sq)
    local file = string.byte(sq:sub(1, 1)) - string.byte("a") + 1
    local rank = tonumber(sq:sub(2, 2))
    return file, rank
end

local function square(file, rank)
    if file < 1 or file > 8 or rank < 1 or rank > 8 then return nil end
    return string.char(string.byte("a") + file - 1) .. tostring(rank)
end

local function rankOf(sq)
    return tonumber(sq and sq:sub(2, 2)) or 0
end

local function fileOf(sq)
    if not sq then return 0 end
    return string.byte(sq:sub(1, 1)) - string.byte("a") + 1
end

local function sortedHounds(hounds)
    table.sort(hounds)
    return hounds
end

local function stateFromGame(game)
    local state = {
        fox = nil,
        hounds = {},
        turn = game:turn(),
    }
    for sq, piece in pairs(game.board_state) do
        if piece.type == Game.FOX then
            state.fox = sq
        elseif piece.type == Game.HOUND then
            state.hounds[#state.hounds + 1] = sq
        end
    end
    sortedHounds(state.hounds)
    return state
end

local function occupied(state)
    local out = {}
    if state.fox then out[state.fox] = true end
    for _, sq in ipairs(state.hounds) do out[sq] = true end
    return out
end

local function stateKey(state, depth)
    return tostring(depth) .. "|" .. state.turn .. "|" .. tostring(state.fox) .. "|" .. table.concat(state.hounds, ",")
end

local function movesFor(state, color)
    local moves = {}
    local occ = occupied(state)

    if color == Game.WHITE then
        local file, rank = coords(state.fox)
        for _, dir in ipairs(FOX_DIRS) do
            local to = square(file + dir[1], rank + dir[2])
            if to and not occ[to] then
                moves[#moves + 1] = {
                    from = state.fox,
                    to = to,
                    piece = Game.FOX,
                    color = Game.WHITE,
                    notation = "Fox " .. state.fox .. "-" .. to,
                }
            end
        end
        return moves
    end

    for _, from in ipairs(state.hounds) do
        local file, rank = coords(from)
        for _, dir in ipairs(HOUND_DIRS) do
            local to = square(file + dir[1], rank + dir[2])
            if to and not occ[to] then
                moves[#moves + 1] = {
                    from = from,
                    to = to,
                    piece = Game.HOUND,
                    color = Game.BLACK,
                    notation = "Hound " .. from .. "-" .. to,
                }
            end
        end
    end
    return moves
end

local function applyMove(state, move)
    local next_state = {
        fox = state.fox,
        hounds = {},
        turn = other(state.turn),
    }
    for i, sq in ipairs(state.hounds) do
        next_state.hounds[i] = sq
    end

    if move.piece == Game.FOX then
        next_state.fox = move.to
    else
        for i, sq in ipairs(next_state.hounds) do
            if sq == move.from then
                next_state.hounds[i] = move.to
                break
            end
        end
        sortedHounds(next_state.hounds)
    end

    return next_state
end

local function terminal(state)
    if not state.fox then return true, "0-1" end
    if rankOf(state.fox) == 8 then return true, "1-0" end

    local moves = movesFor(state, state.turn)
    if #moves > 0 then return false end
    return true, state.turn == Game.WHITE and "0-1" or "1-0"
end

local function terminalScore(result, color, ply)
    local winner = result == "1-0" and Game.WHITE or Game.BLACK
    if winner == color then
        return 100000 - ply
    end
    return -100000 + ply
end

local function evaluate(state, color, yield_fn)
    checkpoint(yield_fn)
    if not state.fox then return color == Game.BLACK and 100000 or -100000 end

    local fox_rank = rankOf(state.fox)
    local fox_file = fileOf(state.fox)
    local fox_moves = movesFor(state, Game.WHITE)
    local hound_mobility = #movesFor(state, Game.BLACK)
    local fox_forward = 0
    local fox_backward = 0
    local hound_data = {}
    local hounds_ahead = {}
    local file_coverage = {}
    local left_diag_blocked = false
    local right_diag_blocked = false
    local left_guard = nil
    local right_guard = nil
    local min_hound_rank = 9
    local max_hound_rank = 0
    local score = fox_rank * 120 - hound_mobility * 2

    for _, move in ipairs(fox_moves) do
        if rankOf(move.to) > fox_rank then
            fox_forward = fox_forward + 1
        else
            fox_backward = fox_backward + 1
        end
    end
    score = score + fox_forward * 50 + fox_backward * 10

    if fox_file == 1 or fox_file == 8 then
        score = score - 50
    elseif fox_file == 2 or fox_file == 7 then
        score = score - 25
    end

    for _, sq in ipairs(state.hounds) do
        local hound_rank = rankOf(sq)
        local hound_file = fileOf(sq)
        local rank_diff = hound_rank - fox_rank
        hound_data[#hound_data + 1] = { file = hound_file, rank = hound_rank, diff = rank_diff }
        if hound_rank < min_hound_rank then min_hound_rank = hound_rank end
        if hound_rank > max_hound_rank then max_hound_rank = hound_rank end
        if hound_rank >= fox_rank then
            local file_diff = hound_file - fox_file
            local file_dist = math.abs(file_diff)
            hounds_ahead[#hounds_ahead + 1] = { file = hound_file, rank = hound_rank }
            file_coverage[hound_file] = true

            if hound_file < fox_file and (not left_guard or fox_file - hound_file < fox_file - left_guard.file) then
                left_guard = { file = hound_file, rank = hound_rank, diff = rank_diff }
            elseif hound_file > fox_file and (not right_guard or hound_file - fox_file < right_guard.file - fox_file) then
                right_guard = { file = hound_file, rank = hound_rank, diff = rank_diff }
            end

            if rank_diff > 0 and file_dist == rank_diff then
                if file_diff < 0 then
                    left_diag_blocked = true
                else
                    right_diag_blocked = true
                end
            end

            score = score - rank_diff * 10
            if file_dist <= 1 and rank_diff <= 2 then
                score = score - 35
            elseif file_dist <= 2 and rank_diff <= 3 then
                score = score - 15
            end
        else
            score = score + 45
        end
    end

    local rank_spread = max_hound_rank - min_hound_rank
    if rank_spread <= 1 then
        score = score - 70
    elseif rank_spread == 2 then
        score = score - 35
    else
        score = score + (rank_spread - 2) * 120
    end

    local ideal_band = 0
    local badly_placed = 0
    for _, hound in ipairs(hound_data) do
        if hound.diff < 0 then
            score = score + 140 + math.abs(hound.diff) * 45
            badly_placed = badly_placed + 1
        elseif hound.diff == 0 then
            score = score + 60
        elseif hound.diff <= 3 then
            score = score - 28
            ideal_band = ideal_band + 1
        elseif hound.diff == 4 then
            score = score + 10
        else
            score = score + (hound.diff - 4) * 40
            badly_placed = badly_placed + 1
        end
        if rank_spread > 2 and hound.rank <= min_hound_rank + 1 then
            score = score + 90
        end
        if max_hound_rank - hound.rank > 2 then
            score = score + (max_hound_rank - hound.rank - 2) * 80
        end
    end
    if ideal_band >= 3 then
        score = score - 55
    elseif badly_placed >= 2 then
        score = score + 80
    end

    if left_diag_blocked and right_diag_blocked then
        score = score - 120
    elseif left_diag_blocked or right_diag_blocked then
        score = score - 40
    end

    if left_guard and right_guard then
        local guard_gap = right_guard.file - left_guard.file
        score = score - 65
        if guard_gap <= 4 then
            score = score - 35
        else
            score = score + (guard_gap - 4) * 30
        end
    else
        score = score + 90
    end

    local covered_count = 0
    for _ in pairs(file_coverage) do covered_count = covered_count + 1 end
    score = score - covered_count * 15

    table.sort(hounds_ahead, function(a, b) return a.file < b.file end)
    local best_wall = #hounds_ahead > 0 and 1 or 0
    local cur_wall = best_wall
    for i = 2, #hounds_ahead do
        local gap = hounds_ahead[i].file - hounds_ahead[i - 1].file
        if gap <= 2 then
            cur_wall = cur_wall + 1
            if cur_wall > best_wall then best_wall = cur_wall end
        else
            cur_wall = 1
        end
    end

    if best_wall >= 4 then
        score = score - 60
    elseif best_wall == 3 then
        score = score - 35
    elseif best_wall == 2 then
        score = score - 15
    end

    for _, move in ipairs(fox_moves) do
        local to_rank = rankOf(move.to)
        if to_rank > fox_rank then
            local ahead_after_move = 0
            for _, hound in ipairs(hound_data) do
                if hound.rank > to_rank then ahead_after_move = ahead_after_move + 1 end
            end
            if ahead_after_move <= 1 then
                score = score + 220
            elseif ahead_after_move == 2 then
                score = score + 90
            end
            if to_rank >= min_hound_rank then
                score = score + 160
            end
        end
    end

    return color == Game.WHITE and score or -score
end

local function moveScore(state, move, color, yield_fn)
    checkpoint(yield_fn)
    local next_state = applyMove(state, move)
    return evaluate(next_state, color, yield_fn)
end

local function orderedMoves(state, color, yield_fn)
    local moves = movesFor(state, state.turn)
    for _, move in ipairs(moves) do
        move._score = moveScore(state, move, color, yield_fn)
    end
    table.sort(moves, function(a, b) return a._score > b._score end)
    return moves
end

local function search(state, depth, alpha, beta, color, ply, yield_fn, cache)
    checkpoint(yield_fn)

    local over, result = terminal(state)
    if over then return terminalScore(result, color, ply) end
    if depth <= 0 then return evaluate(state, color, yield_fn) end

    local key = stateKey(state, depth)
    local cached = cache[key]
    if cached then return cached end

    local moves = orderedMoves(state, color, yield_fn)
    local maximizing = state.turn == color
    local best = maximizing and -math.huge or math.huge

    for _, move in ipairs(moves) do
        checkpoint(yield_fn)
        local score = search(applyMove(state, move), depth - 1, alpha, beta, color, ply + 1, yield_fn, cache)
        if maximizing then
            if score > best then best = score end
            if best > alpha then alpha = best end
        else
            if score < best then best = score end
            if best < beta then beta = best end
        end
        if alpha >= beta then break end
    end

    cache[key] = best
    return best
end

function AI.bestMove(game, depth, blunder_chance, yield_fn)
    if game.setup_pending then return nil end

    local state = stateFromGame(game)
    local color = state.turn
    local moves = orderedMoves(state, color, yield_fn)
    if #moves == 0 then return nil end

    blunder_chance = tonumber(blunder_chance) or 0
    if blunder_chance > 0 and math.random() < blunder_chance then
        return moves[math.random(#moves)]
    end

    depth = tonumber(depth) or 4
    if depth == 0 then depth = 8 end
    depth = math.max(1, math.min(8, depth + 2))

    local cache = {}
    local best = {}
    local best_score = -math.huge
    for _, move in ipairs(moves) do
        checkpoint(yield_fn)
        local score = search(applyMove(state, move), depth - 1, -math.huge, math.huge, color, 1, yield_fn, cache)
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
