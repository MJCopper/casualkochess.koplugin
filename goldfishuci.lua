local Chess = require("chess")
local UIManager = require("ui/uimanager")
local Goldfish = require("goldfish")

local GoldfishUCI = {}
GoldfishUCI.__index = GoldfishUCI

local function parseMoves(moves)
    local out = {}
    if type(moves) ~= "string" then return out end
    for move in moves:gmatch("%S+") do
        out[#out + 1] = move
    end
    return out
end

local function applyUciMove(game, move)
    if not move or #move < 4 then return end
    game.move{
        from = move:sub(1, 2),
        to = move:sub(3, 4),
        promotion = #move >= 5 and move:sub(5, 5) or nil,
    }
end

local function trigger(self, event, ...)
    local list = self.callbacks[event]
    if not list then return end
    for _, fn in ipairs(list) do pcall(fn, ...) end
end

function GoldfishUCI.new()
    local self = setmetatable({}, GoldfishUCI)
    self.callbacks = {}
    self.options = {
        ["Skill Level"] = { type = "spin", default = "0", value = "0", min = "0", max = "20" },
    }
    self.state = {
        uciok = false,
        readyok = false,
        bestmove = nil,
        options = self.options,
        id_name = "Goldfish Lua",
        last_output = "Goldfish Lua fallback is active.",
        last_error = nil,
        _engine = self,
    }
    self.game = Chess:new()
    self.game.reset()
    self.closed = false
    self.send = function(command) return self:handleCommand(command) end
    return self
end

function GoldfishUCI:on(event, fn)
    self.callbacks[event] = self.callbacks[event] or {}
    self.callbacks[event][#self.callbacks[event] + 1] = fn
end

function GoldfishUCI:_trigger(event, ...)
    trigger(self, event, ...)
end

function GoldfishUCI:emitLine(line)
    self.state.last_output = line
    self:_trigger("read", line)
end

function GoldfishUCI:uci()
    self.state.uciok = true
    self:emitLine("id name Goldfish Lua")
    self:emitLine("option name Skill Level type spin default 0 min 0 max 20")
    self:emitLine("uciok")
    self:_trigger("uciok")
end

function GoldfishUCI:isready()
    self.state.readyok = true
    self:emitLine("readyok")
    self:_trigger("readyok")
end

function GoldfishUCI:setOption(name, value)
    self.options[name] = self.options[name] or { type = "string", default = nil }
    self.options[name].value = tostring(value)
    self:isready()
end

function GoldfishUCI:ucinewgame()
    self.game = Chess:new()
    self.game.reset()
end

function GoldfishUCI:position(spec)
    spec = spec or {}
    self.game = Chess:new(spec.fen)
    self.game.reset()
    if spec.fen then
        self.game.load(spec.fen)
    end
    for _, move in ipairs(parseMoves(spec.moves)) do
        applyUciMove(self.game, move)
    end
end

function GoldfishUCI:go(opts)
    opts = opts or {}
    self.state.bestmove = nil
    local token = {}
    self._go_token = token
    UIManager:scheduleIn(0.1, function()
        if self.closed or self._go_token ~= token then return end
        local skill = self.options["Skill Level"] and self.options["Skill Level"].value or 0
        local move = Goldfish.bestMoveUci(self.game, {
            skill_level = skill,
            movetime = opts.movetime,
        })
        self.state.bestmove = move
        self:emitLine("bestmove " .. move)
        self:_trigger("bestmove", move)
    end)
end

function GoldfishUCI:stop()
    self._go_token = nil
end

function GoldfishUCI:quit()
    self:stop()
    self.closed = true
end

function GoldfishUCI:handleCommand(command)
    if self.closed then return false end
    command = tostring(command or "")
    if command == "uci" then
        self:uci()
    elseif command == "isready" then
        self:isready()
    elseif command == "ucinewgame" then
        self:ucinewgame()
    elseif command == "stop" then
        self:stop()
    elseif command == "quit" then
        self:quit()
    elseif command:match("^setoption%s+") then
        local name, value = command:match("^setoption%s+name%s+(.-)%s+value%s+(.+)$")
        if name then self:setOption(name, value) end
    elseif command:match("^position%s+") then
        local moves = command:match("%s+moves%s+(.+)$")
        local fen = command:match("^position%s+fen%s+(.-)%s+moves%s+") or command:match("^position%s+fen%s+(.+)$")
        self:position{ fen = fen, moves = moves }
    elseif command:match("^go%s*") then
        self:go()
    end
    return true
end

return GoldfishUCI
