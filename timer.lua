local Chess = require("chess/src/chess")
local Utils = require("utils")

local Timer = {}
local TIMER_TIMEOUT = 1
Timer.__index = Timer

function Timer:new(duration, increment, callback)
    local obj = {
        base = duration,
        increment = increment,
        time = { [Chess.WHITE] = duration[Chess.WHITE], [Chess.BLACK] = duration[Chess.BLACK] },
        currentPlayer = Chess.WHITE,
        running = false,
        startTime = 0,
        callback = callback,
    }
    setmetatable(obj, self)
    return obj
end

function Timer:start()
    if not self.running then
        self.startTime = os.time()
        self.running = true
        if self.callback then
            Utils.pollingLoop(TIMER_TIMEOUT,
                              function()
                                  if self:getRemainingTime(self.currentPlayer) <= 0 then
                                      self:stop()
                                      return
                                  end
                                  self.callback()
                              end,
                              function()
                                  return self.running
                              end)
        end
    end
end

function Timer:stop()
    if self.running then
        local elapsed = os.difftime(os.time(), self.startTime)
        self.time[self.currentPlayer] = math.max(0, self.time[self.currentPlayer] - elapsed
                                                 + self.increment[self.currentPlayer])
        self.running = false
    end
end

function Timer:switchPlayer()
    self:stop()
    self.currentPlayer = (self.currentPlayer == Chess.WHITE) and Chess.BLACK or Chess.WHITE
    self:start()
end

function Timer:reset()
    self.time = { [Chess.WHITE] = self.base[Chess.WHITE], [Chess.BLACK] = self.base[Chess.BLACK] }
    self.currentPlayer = Chess.WHITE
    self.running = false
end

function Timer:getRemainingTime(player)
    if self.running and player == self.currentPlayer then
        local elapsed = os.difftime(os.time(), self.startTime)
        return math.max(0, self.time[player] - elapsed)
    end
    return self.time[player]
end

function Timer:formatTime(seconds)
    local hours = math.floor(seconds / (60 * 60))
    local minutes = math.floor(seconds / 60) % 60
    local secs = seconds % 60
    return string.format("%02d:%02d:%02d", hours, minutes, secs)
end

return Timer
