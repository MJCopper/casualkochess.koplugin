local _Chess = require("chess/src/chess")

local Chess = {}
Chess.__index = Chess

setmetatable(Chess, {
                 __index = function(_, key)
                     return _Chess[key]
                 end,
})

function Chess:new()
    local instance = _Chess()
    instance.human_player = {
        [instance.WHITE] = true,
        [instance.BLACK] = false,  -- Computer plays Black by default
    }
    instance.redo_stack = {}
    instance.set_human = function(color, isHuman)
        assert(color == instance.WHITE or color == instance.BLACK,
               "Invalid color: " .. tostring(color))
        instance.human_player[color] = isHuman
    end

    instance.is_human = function(color)
        assert(color == instance.WHITE or color == instance.BLACK,
               "Invalid color: " .. tostring(color))
        return instance.human_player[color]
    end

    -- override undo: call base, push onto redo_stack
    local _undo = instance.undo
    instance.undo = function()
        local move = _undo(instance)    -- call the base‐class undo

        if move then
            table.insert(instance.redo_stack, move)
        end
        return move
    end

    -- redo: pop from redo_stack and re-apply
    instance.redo = function()
        local _move = table.remove(instance.redo_stack)
        if _move then
            instance.move(_move)
        end
        return _move
    end

    instance.redo_history = function()
        return instance.redo_stack
    end

    -- override reset: clear redo stack, then call base
    _reset = instance.reset
    function Chess:reset()
        instance.redo_stack = {}
        _reset(self)
    end

    setmetatable(instance, Chess)

    return instance
end

return Chess
