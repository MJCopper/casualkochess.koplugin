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
        [instance.BLACK] = false,
    }
    instance.redo_stack = {}
    local replaying_redo = false
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

    local _move = instance.move
    instance.move = function(move, options)
        if move == instance then
            move, options = options, nil
        end
        local result = _move(move, options)
        if result and not replaying_redo then
            instance.redo_stack = {}
        end
        return result
    end

    local _undo = instance.undo
    instance.undo = function()
        local move = _undo(instance)

        if move then
            table.insert(instance.redo_stack, move)
        end
        return move
    end

    instance.redo = function()
        local _move = table.remove(instance.redo_stack)
        local result
        if _move then
            replaying_redo = true
            result = instance.move(_move)
            replaying_redo = false
        end
        return result
    end

    instance.redo_history = function()
        return instance.redo_stack
    end

    local _reset = instance.reset
    instance.reset = function()
        instance.redo_stack = {}
        return _reset()
    end

    setmetatable(instance, Chess)

    return instance
end

return Chess
