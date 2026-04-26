-- Async UCI wrapper for Stockfish.

local Utils  = require("utils")

local M = {}

local UCIEngine = {}
UCIEngine.__index = UCIEngine

local function parse_uci_line(line, state)
    line = line:match("^%s*(.-)%s*$")
    if not line or line == "" then return end

    state.last_output = line
    if line:match("execvp failed") then
        state.last_error = line
    end

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
    local pid, rfd, wfd = Utils.execInSubProcess(cmd, args or {}, true, false)
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
        last_output = nil,
        last_error = nil,
        process_error = nil,
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
            local ok, err = _reader()
            if ok == false then
                self.state.process_error = err
                self.state.last_error = err
                self:_trigger("process_error", err)
                return false, err
            end
        end
        return true
    end

    local _write = Utils.writer(self.fd_write)
    self._write = _write
    self.send = function(data)
        if self.closed then return false end
        local ok, err = _write(tostring(data))
        if not ok then
            local msg = "engine input write failed"
            if err and err ~= "" then msg = msg .. ": " .. err end
            self.state.process_error = msg
            self.state.last_error = msg
            self:_trigger("process_error", msg)
            return false
        end
        return true
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
    local timed_out    = false

    if not self.send("uci") then return end

    Utils.pollingLoop(0.25, self._reader, function()
        ticks_left = ticks_left - 1
        if self.closed then return false end
        if self.state.uciok then return false end
        local process_error = self.state.process_error or Utils.pollProcess(self.pid)
        if process_error then
            self.state.process_error = process_error
            self.state.last_error = process_error
            self:_trigger("process_error", process_error)
            return false
        end
        if ticks_left <= 0 then
            if not timed_out then
                timed_out = true
                self:_trigger("uci_timeout", self.state.last_error or self.state.last_output)
            end
            return false
        end
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

    if not self.send(cmd) then return end

    local movetime = tonumber(opts.movetime) or 0
    local max_seconds = math.max(10, (movetime / 1000) + 10)
    local ticks_left = math.ceil(max_seconds / 0.25)
    local timed_out = false

    Utils.pollingLoop(0.25, self._reader, function()
        if self.closed or self.state.bestmove then return false end
        local process_error = self.state.process_error or Utils.pollProcess(self.pid)
        if process_error then
            self.state.process_error = process_error
            self.state.last_error = process_error
            self:_trigger("process_error", process_error)
            return false
        end
        ticks_left = ticks_left - 1
        if ticks_left <= 0 then
            if not timed_out then
                timed_out = true
                self:_trigger("go_timeout", self.state.last_error or self.state.last_output)
            end
            return false
        end
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
    Utils.pollProcess(self.pid)
    self.fd_write = nil
    self.fd_read = nil
end

M.UCIEngine = UCIEngine
return M
