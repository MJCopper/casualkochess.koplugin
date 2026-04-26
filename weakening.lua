-- Optional random move substitution for lower computer difficulty.

local Weakening = {}
Weakening.__index = Weakening

function Weakening:new(game, blunder_chance)
    local self = setmetatable({}, Weakening)
    self.game          = game
    self.blunder_chance = math.max(0.0, math.min(1.0, blunder_chance or 0.0))
    math.randomseed(os.time())
    return self
end

function Weakening:setChance(chance)
    self.blunder_chance = math.max(0.0, math.min(1.0, chance or 0.0))
end

function Weakening:maybeWeaken(uci_move)
    if self.blunder_chance <= 0.0 then return uci_move end
    if math.random() > self.blunder_chance then return uci_move end

    local legal = self.game.moves({ verbose = true })
    if not legal or #legal == 0 then return uci_move end

    local pick = legal[math.random(#legal)]

    local result = pick.from .. pick.to
    if pick.promotion then
        result = result .. (pick.promotion ~= "" and pick.promotion or "q"):lower()
    end

    return result
end

return Weakening
