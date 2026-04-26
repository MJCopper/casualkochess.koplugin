-- Async UCI wrapper for Stockfish.

local Utils  = require("utils")

local M = {}

local UCIEngine = {}
UCIEngine.__index = UCIEngine

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

    local _reader = Utils.reader(
        self.fd_read,
        function(line)
            parse_uci_line(line, self.state)
            self:_trigger("read", line)
        end
    )
    self._reader = function()
        if not self.closed then
            _reader()
        end
    end

    local _write = Utils.writer(self.fd_write)
    self._write = _write
    self.send = function(data)
        if self.closed then return false end
        return _write(tostring(data))
    end

    return self
end

function UCIEngine:on(event, fn)
    self.callbacks[event] = self.callbacks[event] or {}
    table.insert(self.callbacks[event], fn)
end

function UCIEngine:_trigger(event, ...)
    local list = self.callbacks[event]
    if not list then return end
    for _, fn in ipairs(list) do pcall(fn, ...) end
end

function UCIEngine:uci()
    self.state.uciok   = false
    self.state.readyok = false
    local ticks_left   = 80

    self.send("uci")

    Utils.pollingLoop(0.25, self._reader, function()
        ticks_left = ticks_left - 1
        if self.closed then return false end
        if self.state.uciok then return false end
        if ticks_left <= 0 then return false end
        return true
    end)
end

function UCIEngine:isready()
    self.send("isready")
end

function UCIEngine:setOption(name, value)
    value = tostring(value)
    self.send(string.format("setoption name %s value %s", name, value))
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

function UCIEngine:go(opts)
    opts = opts or {}
    local cmd = "go"

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

    Utils.pollingLoop(0.25, self._reader, function()
        return not self.closed and not self.state.bestmove
    end)
end

function UCIEngine:stop()
    self.send("stop")
end

function UCIEngine:quit()
    if self.closed then return end
    self._write("quit")
    self.closed = true
    Utils.closeFd(self.fd_write)
    Utils.closeFd(self.fd_read)
    self.fd_write = nil
    self.fd_read = nil
end

M.UCIEngine = UCIEngine
return M
