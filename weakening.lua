-- weakening.lua
-- Randomly replaces the engine's chosen move with a random legal move.
-- This makes the computer genuinely dumber without relying on Stockfish's
-- own skill/depth weakening, allowing difficulty below its natural floor.
--
-- Usage:
--   local Weakening = require("weakening")
--   local w = Weakening:new(game, 0.3)   -- 30% chance of a random move
--   local move = w:maybeWeaken(uci_move) -- returns original or random move
--   w:setChance(0.5)                     -- update chance at any time

local Weakening = {}
Weakening.__index = Weakening

-- ---------------------------------------------------------------------------
-- Constructor
--   game         : the Chess game instance (must expose game.moves())
--   blunder_chance: 0.0 (never randomise) to 1.0 (always randomise)
-- ---------------------------------------------------------------------------
function Weakening:new(game, blunder_chance)
    local self = setmetatable({}, Weakening)
    self.game          = game
    self.blunder_chance = math.max(0.0, math.min(1.0, blunder_chance or 0.0))
    math.randomseed(os.time())
    return self
end

-- ---------------------------------------------------------------------------
-- setChance(chance)
--   Update the blunder probability at any time (e.g. from settings).
-- ---------------------------------------------------------------------------
function Weakening:setChance(chance)
    self.blunder_chance = math.max(0.0, math.min(1.0, chance or 0.0))
end

-- ---------------------------------------------------------------------------
-- maybeWeaken(uci_move) → uci_move string
--   With probability blunder_chance, picks a random legal move and returns
--   it in UCI format (e.g. "e2e4" or "e7e8q" for promotions).
--   Otherwise returns the original move unchanged.
-- ---------------------------------------------------------------------------
function Weakening:maybeWeaken(uci_move)
    if self.blunder_chance <= 0.0 then return uci_move end
    if math.random() > self.blunder_chance then return uci_move end

    -- Get all legal moves in verbose form to access from/to/promotion
    local legal = self.game.moves({ verbose = true })
    if not legal or #legal == 0 then return uci_move end

    -- Pick a random legal move
    local pick = legal[math.random(#legal)]

    -- Build UCI string: "from" .. "to" .. optional promotion piece (lowercase)
    local result = pick.from .. pick.to
    if pick.promotion then
        -- Default to queen if promotion field is present but empty/nil
        result = result .. (pick.promotion ~= "" and pick.promotion or "q"):lower()
    end

    return result
end

return Weakening
