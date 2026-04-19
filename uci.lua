-- uci.lua: UCI chess engine wrapper for KoChess
-- Manages a Stockfish subprocess via stdin/stdout pipes.
-- All I/O is non-blocking and async via UIManager:scheduleIn / pollingLoop.

local Utils  = require("utils")

local M = {}

local UCIEngine = {}
UCIEngine.__index = UCIEngine

-- ---------------------------------------------------------------------------
-- Line parser — called for every line received from the engine
-- ---------------------------------------------------------------------------
local function parse_uci_line(line, state)
    line = line:match("^%s*(.-)%s*$")
    if not line or line == "" then return end

    local eng = state._engine

    if line == "uciok" then
        state.uciok = true
        eng:_trigger("uciok")

    elseif line == "readyok" then
        state.readyok = true
        eng:_trigger("readyok")

    elseif line:find("^id name") then
        state.id_name = line:match("^id name%s+(.+)$")

    elseif line:find("^bestmove") then
        local mv = line:match("^bestmove%s+(%S+)")

        state.bestmove = mv
        eng:_trigger("bestmove", mv)

    elseif line:find("^option") then
        -- "option name Skill Level type spin default 20 min 0 max 20"
        local name    = line:match("name%s+(.-)%s+type")
        local kind    = line:match("type%s+(%w+)")
        local default = line:match("default%s+(%S+)")
        if name and kind then
            state.options[name] = {
                type    = kind,
                default = default,
                value   = default,
                min     = line:match("min%s+(%d+)"),
                max     = line:match("max%s+(%d+)"),
            }
        end
    end
end

-- ---------------------------------------------------------------------------
-- spawn(cmd, args) → UCIEngine instance or nil
-- Forks Stockfish and wires up async I/O.
-- ---------------------------------------------------------------------------
function UCIEngine.spawn(cmd, args)
    local pid, rfd, wfd = Utils.execInSubProcess(cmd, args or {}, true, true)
    if not pid then return nil end

    local self = setmetatable({}, UCIEngine)
    self.pid       = pid
    self.fd_read   = rfd
    self.fd_write  = wfd
    self.callbacks = {}
    self.state = {
        uciok    = false,
        readyok  = false,
        bestmove = nil,
        options  = {},
        _engine  = self,
    }

    -- Build the non-blocking reader closure
    self._reader = Utils.reader(
        self.fd_read,
        function(line)
            parse_uci_line(line, self.state)
            self:_trigger("read", line)
        end
    )

    -- Build the writer closure
    local _write = Utils.writer(self.fd_write)
    self.send = function(data)
        _write(tostring(data))
    end

    return self
end

-- ---------------------------------------------------------------------------
-- Event system
-- ---------------------------------------------------------------------------
function UCIEngine:on(event, fn)
    self.callbacks[event] = self.callbacks[event] or {}
    table.insert(self.callbacks[event], fn)
end

function UCIEngine:_trigger(event, ...)
    local list = self.callbacks[event]
    if not list then return end
    for _, fn in ipairs(list) do pcall(fn, ...) end
end

-- ---------------------------------------------------------------------------
-- UCI command helpers
-- ---------------------------------------------------------------------------

-- Send "uci" and poll until we receive "uciok" (or give up after ~20s).
-- Fully async — does not block the UI.
function UCIEngine:uci()
    self.state.uciok   = false
    self.state.readyok = false
    local ticks_left   = 80   -- 80 × 250ms = 20 seconds max wait

    self.send("uci")

    Utils.pollingLoop(0.25, self._reader, function()
        ticks_left = ticks_left - 1
        if self.state.uciok then return false end  -- done
        if ticks_left <= 0 then return false end
        return true  -- keep polling
    end)
end

function UCIEngine:isready()
    self.send("isready")
end

function UCIEngine:setOption(name, value)
    value = tostring(value)
    self.send(string.format("setoption name %s value %s", name, value))
    -- Keep local state in sync so SettingsWidget can read current values
    self.state.options[name] = self.state.options[name]
        or { type = "string", default = nil }
    self.state.options[name].value = value
    self:isready()
end

function UCIEngine:ucinewgame()
    self.send("ucinewgame")
end

function UCIEngine:position(spec)
    local cmd = "position" .. (spec.fen and (" fen " .. spec.fen) or " startpos")
    if spec.moves and spec.moves ~= "" then
        cmd = cmd .. " moves " .. spec.moves
    end
    self.send(cmd)
end

-- Send "go" and poll until bestmove arrives.
-- The bestmove callback in main.lua handles the actual move application.
-- Fully async — does not block the UI.
function UCIEngine:go(opts)
    opts = opts or {}
    local cmd = "go"

    -- Emit tokens in the standard UCI order
    local order = {
        "searchmoves", "ponder",
        "wtime", "btime", "winc", "binc", "movestogo",
        "depth", "nodes", "mate", "movetime",
        "infinite",
    }
    for _, k in ipairs(order) do
        local v = opts[k]
        if v ~= nil then
            if type(v) == "boolean" then
                if v then cmd = cmd .. " " .. k end
            else
                cmd = cmd .. " " .. k .. " " .. tostring(v)
            end
        end
    end

    self.state.bestmove = nil

    self.send(cmd)

    -- Poll until bestmove arrives; no timeout needed here since movetime
    -- is set in the go command itself (engine will always reply).
    Utils.pollingLoop(0.25, self._reader, function()
        return not self.state.bestmove
    end)
end

function UCIEngine:stop()
    self.send("stop")
end

M.UCIEngine = UCIEngine
return M
