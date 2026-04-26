local Device = require("device")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Font = require("ui/font")
local Size = require("ui/size")
local Geometry = require("ui/geometry")
local DataStorage = require("datastorage")
local LuaSettings  = require("luasettings")
local util = require("util")
local json = require("json")

pcall(function() util.makePath(DataStorage:getDataDir() .. "/icons") end)

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TitleBarWidget = require("ui/widget/titlebar")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ButtonWidget    = require("ui/widget/button")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local HorizontalGroup = require("ui/widget/horizontalgroup") 
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local MovableContainer = require("ui/widget/container/movablecontainer")
local TextWidget = require("ui/widget/textwidget")
local InputText = require("ui/widget/inputtext")
local PathChooser = require("ui/widget/pathchooser")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ConfirmBox = require("ui/widget/confirmbox")

local Chess = require("chess")
local ChessBoard = require("board")
local Timer = require("timer")
local Uci = require("uci")
local SettingsWidget = require("settingswidget")
local Weakening = require("weakening")
local _ = require("gettext")

local function getPluginPath()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "")
    local path = src:match("^(.*[/\\])main%.lua$") or "."

    return path
end

local function normalizePath(path)
    path = (path or ""):gsub("\\", "/")
    return path:gsub("/+", "/")
end

local function joinPath(...)
    local parts = {...}
    local path = tostring(parts[1] or "")
    for i = 2, #parts do
        local part = tostring(parts[i] or "")
        path = path:gsub("/+$", "") .. "/" .. part:gsub("^/+", "")
    end
    return normalizePath(path)
end

local PLUGIN_PATH = normalizePath(getPluginPath()):gsub("/+$", "")

local ENGINES_DIR = joinPath(PLUGIN_PATH, "engines")

local function fileExists(path)
    local ok = lfs.attributes(path, "mode")
    return ok == "file"
end

local function chmodX(path)
    os.execute('chmod +x "' .. path .. '"')
end

local function getEnginePath()
    local path = joinPath(ENGINES_DIR, "stockfish")

    if fileExists(path) then
        chmodX(path)
        return path
    end

    return nil
end

local UCI_ENGINE_PATH = getEnginePath()
local GAMES_PATH = joinPath(PLUGIN_PATH, "Games")

local BACKGROUND_COLOR = Blitbuffer.COLOR_WHITE
local PGN_LOG_FONT = "smallinfofont"
local PGN_LOG_FONT_SIZE = 14
local TOOLBAR_PADDING = 4

local Kochess = FrameContainer:extend{
    name = "casualkochess",
    background = BACKGROUND_COLOR,
    bordersize = 0,
    padding = 0,
    full_width = Screen:getWidth(),
    full_height = Screen:getHeight(),
    notation_font = PGN_LOG_FONT,
    notation_size = PGN_LOG_FONT_SIZE,
    game = nil, timer = nil, engine = nil, board = nil,
    pgn_log = nil, status_bar = nil, running = false,
}

function Kochess:onCasualChessStart()
    self:startGame()
    return true
end

function Kochess:onCloseWidget()
    if self.board then
        self.board:clearValidMoves()
    end
    self:shutdownEngine()
end

function Kochess:handleEvent(event)
    -- Dispatcher can launch the game while this widget is not on the stack.
    if event.handler == "onCasualChessStart" then
        return self:onCasualChessStart()
    end
    -- FileManager can still propagate child events after UIManager:close().
    local on_stack = false
    for i = #UIManager._window_stack, 1, -1 do
        if UIManager._window_stack[i].widget == self then
            on_stack = true
            break
        end
    end
    if not on_stack then return false end
    return FrameContainer.handleEvent(self, event)
end

function Kochess:init()
    self.dimensions = Geometry:new{ w = self.full_width, h = self.full_height }
    self.covers_fullscreen = true
    Dispatcher:registerAction("casualkochess", {
        category = "none", event = "CasualChessStart", title = _("Casual Chess"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
    self:installIconsIfNeeded()
    local path = DataStorage:getSettingsDir() .. "/casualkochess.lua"
    self.settings = LuaSettings:open(path)
end

function Kochess:saveSettings()
    self.settings:flush()
end

function Kochess:getSetting(key, default)
    return self.settings:readSetting(key, default)
end

function Kochess:setSetting(key, value)
    self.settings:saveSetting(key, value)
    self:saveSettings()
end

function Kochess:getEngineStatusText()
    if not UCI_ENGINE_PATH then
        return "Stockfish engine not found.\nCopy the engine binary to:\n" .. ENGINES_DIR .. "/"
    end
    if self.engine and self.engine.state and self.engine.state.uciok then
        return "Stockfish engine is ready."
    end

    local text = "Stockfish engine is not ready.\nPath:\n" .. UCI_ENGINE_PATH
    local detail = self.engine_status_text
        or self.engine_last_output
        or (self.engine and self.engine.state and (self.engine.state.last_error or self.engine.state.last_output))
    if detail and detail ~= "" then
        text = text .. "\n\nLast engine output:\n" .. detail
    end
    return text
end

function Kochess:switchToHumanVsHuman()
    self.human_white = true
    self.human_black = true
    if self.game then
        self.game.set_human(Chess.WHITE, true)
        self.game.set_human(Chess.BLACK, true)
    end
    self:setSetting("human_white", true)
    self:setSetting("human_black", true)
    if self.status_bar then
        self:updatePlayerDisplay()
    end
    self:updateBoardOrientation()
end

function Kochess:markEngineInvalid(reason)
    self.engine_status_text = reason or "Stockfish engine is not ready."
    self:switchToHumanVsHuman()
end

function Kochess:installIconsIfNeeded()
    local data_dir = DataStorage:getDataDir()
    local dest_dir = data_dir .. "/icons/casualchess"
    local src_dir  = joinPath(PLUGIN_PATH, "icons")
    if lfs.attributes(src_dir, "mode") ~= "directory" then return end
    util.makePath(dest_dir)
    for entry in lfs.dir(src_dir) do
        if entry:match("%.svg$") then
            local dest_file = dest_dir .. "/" .. entry
            if lfs.attributes(dest_file, "mode") ~= "file" then
                os.execute('cp "' .. joinPath(src_dir, entry) .. '" "' .. dest_file .. '"')
            end
        end
    end
end

function Kochess:addToMainMenu(menu_items)
    menu_items.casualkochess = {
        text = _("Casual Chess"), sorting_hint = "tools", callback = function() self:startGame() end, keep_menu_open = false,
    }
end

function Kochess:startGame()
    self.last_cp = nil
    self.last_mate = nil
    self.eval_turn = nil

    if UIManager.isWidgetShown and UIManager:isWidgetShown(self) then
        UIManager:close(self)
    end

    self:initializeGameLogic()
    self:initializeEngine()
    self:loadOpenings()
    self:buildUILayout()
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
    self:restoreGameState()
    self.board:updateBoard()
    UIManager:show(self)
end

function Kochess:saveGameState()
    local pgn = self.game.pgn and self.game.pgn() or ""
    self:setSetting("saved_pgn", pgn)
    self:setSetting("saved_time_white", self.timer:getRemainingTime(Chess.WHITE))
    self:setSetting("saved_time_black", self.timer:getRemainingTime(Chess.BLACK))
    self:setSetting("saved_running", self.running)
end

function Kochess:restoreGameState()
    local pgn = self:getSetting("saved_pgn", "")
    if not pgn or pgn == "" then return end

    local ok = pcall(function() self.game.load_pgn(pgn) end)
    if not ok then
        self:setSetting("saved_pgn", "")
        return
    end

    local tw = self:getSetting("saved_time_white", nil)
    local tb = self:getSetting("saved_time_black", nil)
    if tw then self.timer.time[Chess.WHITE] = tw end
    if tb then self.timer.time[Chess.BLACK] = tb end

    self.timer.currentPlayer = self.game.turn()
    self.running = self:getSetting("saved_running", false)

    if self.engine and self.engine.state.uciok then
        self.engine.send("ucinewgame")
        local moves = {}
        for _, m in ipairs(self.game.history({ verbose = true })) do
            moves[#moves+1] = m.from .. m.to .. (m.promotion or "")
        end
        if #moves > 0 then
            self.engine:position({ moves = table.concat(moves, " ") })
        end
    end

    self:updatePgnLog()
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
end

function Kochess:loadOpenings()
    if self.openings then return end

    self.openings = {}
    local path = joinPath(PLUGIN_PATH, "data/aperturas.json")

    local f = io.open(path, "r")
    if not f then

        return
    end

    local content = f:read("*all")
    f:close()

    local ok, data = pcall(json.decode, content)
    if not ok or type(data) ~= "table" then

        return
    end

    self.openings = data

end

function Kochess:initializeEngine()

    local CASUAL = {
        skill_level     = 0,
        engine_depth    = 2,
        engine_movetime = 1,
        blunder_chance  = 0.20,
    }

    local missing = self.settings:readSetting("skill_level")    == nil
                 or self.settings:readSetting("engine_depth")   == nil
                 or self.settings:readSetting("engine_movetime") == nil
                 or self.settings:readSetting("blunder_chance") == nil
    if missing then
        for k, v in pairs(CASUAL) do
            self:setSetting(k, v)
        end
    end

    local defaultSkill   = self:getSetting("skill_level",     CASUAL.skill_level)
    self.current_skill   = defaultSkill
    if self.engine_movetime == nil then
        self.engine_movetime = self:getSetting("engine_movetime", CASUAL.engine_movetime)
    end
    if self.engine_depth == nil then
        self.engine_depth = self:getSetting("engine_depth", CASUAL.engine_depth)
    end
    if self.blunder_chance == nil then
        self.blunder_chance = self:getSetting("blunder_chance", CASUAL.blunder_chance)
    end
    if self.weakening then
        self.weakening:setChance(self.blunder_chance)
    end
    self.human_white = self:getSetting("human_white", true)
    self.human_black = self:getSetting("human_black", false)
    self.last_cp = nil
    self.engine_status_text = nil
    self.engine_last_output = nil

    if not UCI_ENGINE_PATH then
        self:markEngineInvalid("Stockfish engine not found.")
        return
    end

    self.engine = Uci.UCIEngine.spawn(UCI_ENGINE_PATH, {})

    
    if not self.engine then

        self:markEngineInvalid("Engine process could not be created.")
        return
    end

    self.engine:on("read", function(data)
        if data then
            local clean = data:gsub("\r", "")

            for line in tostring(data):gmatch("[^\r\n]+") do
                self.engine_last_output = line
                if line:match("execvp failed") then
                    self:markEngineInvalid(line)
                end
                if line:match("^info ") then
                    local mp = tonumber(line:match(" multipv (%d+)")) or 1
                    if mp == 1 then
                        local cp = line:match(" score cp (-?%d+)")
                        local mate = line:match(" score mate (-?%d+)")
                        if mate then
                            local mv = tonumber(mate)
                            if self.eval_turn == Chess.BLACK then mv = -mv end
                            self.last_mate = mv
                            self.last_cp = nil

                        elseif cp then
                            local cpv = tonumber(cp)
                            if self.eval_turn == Chess.BLACK then cpv = -cpv end
                            self.last_cp = cpv
                            self.last_mate = nil
                        end
                    end
                end
            end
        end
    end)

    self.engine:on("uciok", function()
        self.engine_status_text = nil

        if not self:getSetting("saved_pgn", "") or self:getSetting("saved_pgn", "") == "" then
            self:updatePgnLogInitialText()
        end

        self.engine.send("setoption name Hash value 8")
        self.engine.send("setoption name Threads value 1")
        self.engine.send("setoption name Skill Level value " .. defaultSkill)
        self.engine.send("setoption name Move Overhead value 150")
        self.engine.send("setoption name Ponder value false")
        self.engine.send("setoption name Slow Mover value 90")
        self.current_skill = defaultSkill

        self.engine:ucinewgame()

        -- Restored computer-vs-computer games can resume once UCI is ready.
        local is_cvc = not self.game.is_human(Chess.WHITE) and not self.game.is_human(Chess.BLACK)
        if is_cvc and self.running then
            local moves = {}
            for _, m in ipairs(self.game.history({ verbose = true })) do
                moves[#moves+1] = m.from .. m.to .. (m.promotion or "")
            end
            if #moves > 0 then
                self.engine:position({ moves = table.concat(moves, " ") })
            end
            self.engine.send("isready")
            self:launchNextMove()
        else
            self.engine.send("isready")
        end

        UIManager:setDirty(self, "ui")
    end)

    self.engine:on("bestmove", function(move_uci)
        self.engine_busy = false

        if not self.game.is_human(self.game.turn()) then
            self:uciMove(move_uci)
        end
    end)

    self.engine:on("process_error", function(err)
        self.engine_busy = false
        self:markEngineInvalid(err or "Stockfish engine process failed.")
    end)

    self.engine:on("uci_timeout", function(last_output)
        local text = "Timed out waiting for Stockfish UCI response."
        if last_output and last_output ~= "" then
            text = text .. "\n" .. last_output
        end
        self:markEngineInvalid(text)
    end)

    self.engine:on("go_timeout", function(last_output)
        self.engine_busy = false
        local text = "Timed out waiting for Stockfish bestmove."
        if last_output and last_output ~= "" then
            text = text .. "\n" .. last_output
        end
        self:markEngineInvalid(text)
    end)
    
    self.engine:uci()
end

function Kochess:initializeGameLogic()
    self.game = Chess:new()
    self.game.reset()
    self.game.initial_fen = self.game.fen()
    local human_white = self:getSetting("human_white", true)
    local human_black = self:getSetting("human_black", false)
    self.game.set_human(Chess.WHITE, human_white)
    self.game.set_human(Chess.BLACK, human_black)
    local base_w = self:getSetting("time_base_white", 900)
    local base_b = self:getSetting("time_base_black", 900)
    local incr_w = self:getSetting("time_incr_white", 10)
    local incr_b = self:getSetting("time_incr_black", 10)
    self.timer = Timer:new(
        {[Chess.WHITE]=base_w, [Chess.BLACK]=base_b},
        {[Chess.WHITE]=incr_w, [Chess.BLACK]=incr_b},
        function() self:updateTimerDisplay() end)
    self.running = false
    self.weakening = Weakening:new(self.game, self.blunder_chance or 0.0)
end

function Kochess:initializeBoard(board_h)
    self.board = ChessBoard:new{
        game          = self.game,
        width         = self.full_width,
        height        = board_h or math.floor(0.7 * self.full_height),
        moveCallback  = function(move) self:onMoveExecuted(move) end,
        onPromotionNeeded = function(f, t, c) self:openPromotionDialog(f, t, c) end,
        learning_mode = self:getSetting("learning_mode", false),
        show_selected = self:getSetting("show_selected", true),
        previous_move_hints = self:getSetting("previous_move_hints", false),
        opponent_hints = self:getSetting("opponent_hints", false),
        check_hints = self:getSetting("check_hints", false),
        flipped = self:shouldFlipBoard(),
        rotate_top_pieces = self:getSetting("rotate_top_pieces", false),
    }
end

function Kochess:shouldFlipBoard()
    return self.game
       and self.game.is_human(Chess.BLACK)
       and not self.game.is_human(Chess.WHITE)
end

function Kochess:updateBoardOrientation()
    if not self.board then return end
    self.board:setFlipped(self:shouldFlipBoard())
    self.board:setRotateTopPieces(self:getSetting("rotate_top_pieces", false))
end

function Kochess:buildUILayout()
    local status_bar = self:createStatusBar()
    local status_h   = status_bar:getSize().h

    local pad           = Screen:scaleBySize(8)
    local line_h        = Screen:scaleBySize(PGN_LOG_FONT_SIZE) + 4
    local pgn_h         = line_h
    local eval_h        = line_h
    local log_border    = Screen:scaleBySize(1)
    local toolbar_btn_h = Screen:scaleBySize(32)
    local text_frame_h  = log_border * 2 + pad + pgn_h + eval_h + pad
    local min_log_h     = text_frame_h + toolbar_btn_h

    local BOARD_SIZE    = 8
    local board_pad     = Screen:scaleBySize(8)
    local available_h   = self.full_height - status_h - min_log_h
    local usable_w      = self.full_width - 2 * board_pad
    local cell          = math.floor(math.min(usable_w, available_h - board_pad) / BOARD_SIZE)
    local board_h       = cell * BOARD_SIZE + board_pad
    local log_h         = self.full_height - status_h - board_h
    local pgn_h         = log_h - text_frame_h + line_h

    self:initializeBoard(board_h)
    local toolbar_btn_w = math.floor(self.full_width / 5)
    local inner_w       = self.full_width - 2 * pad

    local frame_fixed_h = log_border * 2 + pad + eval_h + pad
    local pgn_h         = math.max(line_h, log_h - frame_fixed_h - toolbar_btn_h)

    self.eval_line = TextWidget:new{
        text    = "Eval: --",
        face    = Font:getFace(PGN_LOG_FONT, PGN_LOG_FONT_SIZE),
        halign  = "left",
        padding = 0,
        width   = inner_w,
    }

    local eval_line_left = LeftContainer:new{
        dimen = Geometry:new{ w = inner_w, h = eval_h },
        self.eval_line,
    }

    self:updateEvalLine()

    self.pgn_log = self:createPgnLogWidget("", inner_w, pgn_h)

    local toolbar = HorizontalGroup:new{
        self:createToolbarButton("chevron.left",       toolbar_btn_w, toolbar_btn_h, function() self:handleUndoMove(false) end),
        self:createToolbarButton("chevron.right",      toolbar_btn_w, toolbar_btn_h, function() self:handleRedoMove(false) end),
        self:createToolbarButton("bookmark",           toolbar_btn_w, toolbar_btn_h, function() UIManager:show(self:openSaveDialog()) end),
        self:createToolbarButton("appbar.filebrowser", toolbar_btn_w, toolbar_btn_h, function() self:openLoadPgnDialog() end),
        self:createToolbarButton("plus",               toolbar_btn_w, toolbar_btn_h, function()
            UIManager:show(ConfirmBox:new{
                text        = _("Start a new game?"),
                ok_text     = _("New Game"),
                ok_callback = function() self:resetGame() end,
            })
        end),
    }

    local log_section = VerticalGroup:new{
        width = self.full_width,
        FrameContainer:new{
            background     = BACKGROUND_COLOR,
            bordersize     = log_border,
            padding        = 0,
            padding_left   = pad,
            padding_right  = pad,
            padding_top    = pad,
            padding_bottom = pad,
            width          = self.full_width,
            VerticalGroup:new{
                width = inner_w,
                self.pgn_log,
                eval_line_left,
            },
        },
        toolbar,
    }

    local main_vgroup = VerticalGroup:new{
        align = "center", width = self.full_width, height = self.full_height,
        self.board, log_section, status_bar,
    }
    self.status_bar = status_bar
    -- Keep the full-screen layout anchored at y=0 even when content is tall.
    self[1] = main_vgroup
end

function Kochess:updatePgnLogInitialText()
    if self.pgn_log then self.pgn_log:setText(""); UIManager:setDirty(self, "ui") end
end

function Kochess:detectOpening()
    if not self.openings then return nil end

    local hist = self.game.history and self.game:history() or nil
    if type(hist) ~= "table" or #hist == 0 then
        hist = self.game.history and self.game.history() or {}
    end

    local moves = {}
    for i, san in ipairs(hist) do
        if type(san) == "string" and san ~= "" then
            san = san:gsub("[+#?!]", "")
            moves[#moves + 1] = san
        end
    end

    local played = table.concat(moves, " ")

    local best = nil
    for _, o in ipairs(self.openings) do
        if played:find(o.moves, 1, true) == 1 then
            if not best or #o.moves > #best.moves then
                best = o
            end
        end
    end

    return best
end

local function formatEval(self)
    local mate = self.last_mate
    if mate ~= nil then
        local m = tonumber(mate) or 0
        if m == 0 then
            return "eval: # (checkmate)"
        end
        local side  = (m > 0) and "White" or "Black"
        local moves = math.max(1, math.ceil(math.abs(m) / 2))
        return string.format("eval: Mate in %d (%s)", moves, side)
    end

    local cp = self.last_cp
    if cp == nil then
        return ""
    end

    local v = (tonumber(cp) or 0) / 100.0
    local abs = math.abs(v)

    local tag
    if abs < 0.20 then
        tag = "(roughly equal)"
    elseif abs < 0.50 then
        tag = (v > 0) and "(slight advantage for White)" or "(slight advantage for Black)"
    elseif abs < 1.00 then
        tag = (v > 0) and "(small advantage for White)" or "(small advantage for Black)"
    elseif abs < 2.00 then
        tag = (v > 0) and "(clear advantage for White)" or "(clear advantage for Black)"
    elseif abs < 4.00 then
        tag = (v > 0) and "(winning advantage for White)" or "(winning advantage for Black)"
    else
        tag = (v > 0) and "(decisive advantage for White)" or "(decisive advantage for Black)"
    end

    return string.format("eval: %+.2f %s", v, tag)
end

function Kochess:updateEvalLine()
    if self.eval_line then
        self.eval_line:setText(formatEval(self))
        UIManager:setDirty(self, "ui")
    end
end

function Kochess:createPgnLogWidget(txt, w, h) return TextBoxWidget:new{ use_xtext=true, text=txt, face=Font:getFace(self.notation_font, self.notation_size), scroll=true, width=w, height=h, dialog=self } end
function Kochess:createToolbarButton(icon, w, h, cb) return ButtonWidget:new{ icon=icon, width=w, icon_width=w, icon_height=h, padding=0, margin=0, bordersize=0, callback=cb } end
function Kochess:handleUndoMove(all) self:stopUCI(); self.timer:stop(); if all then while self.game.undo() do end else self.game.undo() end; self.board:updateBoard(); self:updatePgnLog(); UIManager:setDirty(self, "ui"); self.timer:start() end
function Kochess:handleRedoMove(all) self:stopUCI(); self.timer:stop(); if all then while self.game.redo() do end else self.game.redo() end; self.board:updateBoard(); self:updatePgnLog(); UIManager:setDirty(self, "ui"); self.timer:start() end

function Kochess:onMoveExecuted(move)

    self.running = true

    self:updatePgnLog()

    local opening = self:detectOpening()

    if self.eval_line then
        local eval_txt = formatEval(self)
        if opening then
            self.eval_line:setText(string.format("%s (%s) · %s", opening.name, opening.eco or "?", eval_txt))
        else
            self.eval_line:setText(eval_txt)
        end
    end

    local is_over, result, reason = self.game.game_over()
    if is_over then
        self:showGameOverDialog(result, reason)
        UIManager:setDirty(self, "ui")
        return
    end

    self:launchNextMove()
    UIManager:setDirty(self, "ui")
end

function Kochess:launchNextMove()
    self.timer:switchPlayer()
    self:updateTimerDisplay()
    if not (self.engine and self.engine.state.uciok and not self.game.is_human(self.game.turn())) then return end

    local is_cvc = not self.game.is_human(Chess.WHITE) and not self.game.is_human(Chess.BLACK)
    if not is_cvc then
        self:launchUCI()
    else
        -- Let UIManager process taps between computer-vs-computer moves.
        local token = {}
        self._pending_launch = token
        UIManager:scheduleIn(1, function()
            if self._pending_launch ~= token then return end
            self._pending_launch = nil
            self:launchUCI()
        end)
    end
end

function Kochess:launchCurrentComputerMove()
    if not (self.engine and self.engine.state.uciok and not self.game.is_human(self.game.turn())) then return end

    self.running = true
    self.timer.currentPlayer = self.game.turn()
    self.timer:start()
    self:updateTimerDisplay()
    self:launchUCI()
end

function Kochess:uciMove(str)
    if self.weakening then
        str = self.weakening:maybeWeaken(str)
    end
    local m = self.game.move({from=str:sub(1,2), to=str:sub(3,4), promotion=(#str==5 and str:sub(5,5) or nil)})
    if m then self.board:handleGameMove(m) end
end

function Kochess:launchUCI()
    if not (self.engine and self.engine.state and self.engine.state.uciok) then return end
    if self.engine_busy then return end
    self.engine_busy = true

    local moves = {}
    for _, m in ipairs(self.game.history({ verbose = true })) do
        moves[#moves + 1] = m.from .. m.to .. (m.promotion or "")
    end
    self.engine:position({ moves = table.concat(moves, " ") })

    self.eval_turn = self.game.turn()

    local movetime_ms = (self.engine_movetime or 1) * 1000
    local wtime = math.max(100, self.timer:getRemainingTime(Chess.WHITE) * 1000)
    local btime = math.max(100, self.timer:getRemainingTime(Chess.BLACK) * 1000)

    local d = tonumber(self.engine_depth) or 0
    local depth_limit = (d >= 1 and d <= 5) and d or nil

    self.engine:go({
        wtime    = wtime,
        btime    = btime,
        winc     = self.timer.increment[Chess.WHITE] * 1000,
        binc     = self.timer.increment[Chess.BLACK] * 1000,
        movetime = movetime_ms,
        depth    = depth_limit,
    })
end

function Kochess:stopUCI()
    self._pending_launch = nil
    self.engine_busy = false
    if self.engine and not self.engine.closed and self.engine.state.uciok then self.engine.send("stop") end
end

function Kochess:shutdownEngine()
    self._pending_launch = nil
    self.engine_busy = false
    if self.engine and not self.engine.closed then
        self.engine:quit()
    end
    self.engine = nil
end

function Kochess:updatePgnLog()
    local moves = self.game:history()
    local txt = ""
    for i, m in ipairs(moves) do
        if i%2==1 then txt = txt .. " " .. (math.floor(i/2)+1) .. "." end
        txt = txt .. " " .. m
    end
    self.pgn_log:setText(txt)

    if self.pgn_log.scrollToBottom then
        self.pgn_log:scrollToBottom()
    elseif self.pgn_log.scrollTo then
        self.pgn_log:scrollTo(1e9)
    end
end

function Kochess:updateTimerDisplay()
    local ind = self.running and ((self.game.turn()==Chess.WHITE and " < ") or " > ") or " || "
    self.status_bar:setTitle(self.timer:formatTime(self.timer:getRemainingTime(Chess.WHITE)) .. ind .. self.timer:formatTime(self.timer:getRemainingTime(Chess.BLACK)))
    self:updatePlayerDisplay(ind)
    UIManager:setDirty(self.status_bar, "ui")
end

function Kochess:updatePlayerDisplay(ind)
    local white = "White(" .. (self.game.is_human(Chess.WHITE) and "Human" or "Computer") .. ")"
    local black = "(" .. (self.game.is_human(Chess.BLACK) and "Human" or "Computer") .. ")Black"
    local sep = ind or (self.running and ((self.game.turn()==Chess.WHITE and " < ") or " > ") or " || ")
    self.status_bar:setSubTitle(white .. sep .. black)
end

function Kochess:resetGame()
    self:stopUCI(); self.game.reset(); self.timer:reset()
    if self.engine then self.engine.send("ucinewgame") end
    self.board:clearValidMoves()
    self.board:clearPreviousMoveHints()
    self.board:clearCheckHint()
    self:setSetting("saved_pgn", "")
    self.running = false
    self:updateTimerDisplay(); self:updatePlayerDisplay(); self.board:updateBoard(); UIManager:setDirty(self, "ui")
    self:launchCurrentComputerMove()
end

function Kochess:showGameOverDialog(result, reason)
    local text
    if result == "1-0" or result == "0-1" then
        local winner = (result == "1-0") and _("White") or _("Black")
        text = string.format(_("Checkmate! %s wins."), winner)
    else
        local label
        if not reason then
            text = _("Draw!")
        elseif reason == "Stalemate" then
            label = _("Stalemate")
        elseif reason == "Insufficient material" then
            label = _("Insufficient material")
        elseif reason == "Threefold repetition" then
            label = _("Threefold repetition")
        elseif reason == "Fifty-move rule" then
            label = _("Fifty-move rule")
        else
            label = reason
        end
        if label then
            text = string.format(_("Draw! %s."), label)
        end
    end

    self:stopUCI()
    self.timer:stop()
    self.running = false
    self:updateTimerDisplay()

    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Continue"),
        cancel_text = nil,
        ok_callback = function()
            self.last_cp = nil
            self.last_mate = nil
            self.eval_turn = nil
            self.running = false

            self:resetGame()
            self:updatePgnLogInitialText()
            self:updateEvalLine()

            self:launchCurrentComputerMove()
        end,
    })
end

function Kochess:createStatusBar()
    local Screen = require("device").screen
    return TitleBarWidget:new{
        fullscreen             = true,
        title                  = "00:00",
        subtitle               = "HvH",
        left_icon              = "appbar.settings",
        left_icon_size_ratio   = 1.0,
        right_icon_size_ratio  = 1.0,
        title_top_padding      = Screen:scaleBySize(2),
        bottom_v_padding       = Screen:scaleBySize(8),
        left_icon_tap_callback = function()
            SettingsWidget:new{
                engine  = self.engine,
                timer   = self.timer,
                game    = self.game,
                parent  = self,
                onApply = function()
                    self:stopUCI()
                    self.timer:reset()
                    self:updateBoardOrientation()
                    self:updatePlayerDisplay()
                    self:updateTimerDisplay()
                    self:launchCurrentComputerMove()
                end,
            }:show()
        end,
        close_callback = function()
            UIManager:show(ConfirmBox:new{
                text        = _("Exit Chess?"),
                ok_text     = _("Exit"),
                ok_callback = function()
                    self.timer:stop()
                    self:saveGameState()
                    UIManager:close(self, "full")
                end,
            })
        end,
    }
end

function Kochess:openLoadPgnDialog()
    UIManager:show(
        PathChooser:new{
            path = GAMES_PATH,
            title = _("Load PGN File"),
            select_directory = false,
            onConfirm = function(path)
                if not path then return end
                local fh = io.open(path, "r")
                if not fh then
                    UIManager:show(InfoMessage:new{
                        text = _("Could not open file:\n") .. path,
                    })
                    return
                end
                local pgn_data = fh:read("*a")
                fh:close()

                self:stopUCI()
                self.timer:stop()

                self.game.reset()
                self.game.load_pgn(pgn_data)

                self.board:updateBoard()
                self:updatePgnLog()
                self:updateTimerDisplay()
                self:updatePlayerDisplay()

                if self.engine and self.engine.state.uciok then
                    self.engine.send("ucinewgame")
                    self.engine.send("isready")
                end

                UIManager:setDirty(self, "ui")
                self.timer:start()
            end,
        }
    )
end

function Kochess:handleSaveFile(dialog, filename_input, current_dir)
    filename_input:onCloseKeyboard()
    local dir = current_dir
    local file = filename_input:getText():gsub("\n$", "")

    if not file:lower():match("%.pgn$") then
        file = file .. ".pgn"
    end

    local sep = package.config:sub(1, 1)
    local fullpath = dir .. sep .. file
    local pgn_data = self.game.pgn()

    local fh, err = io.open(fullpath, "w")
    if not fh then
        UIManager:show(InfoMessage:new{
            text = _("Could not save file:\n") .. tostring(err),
        })
        return
    end

    fh:write(pgn_data)
    fh:close()

    UIManager:close(dialog)
    UIManager:show(InfoMessage:new{
        text = _("Game saved to:\n") .. fullpath,
    })
end

function Kochess:openSaveDialog()
    local current_dir = GAMES_PATH
    local dialog
    local filename_input

    local function onSaveConfirm()
        self:handleSaveFile(dialog, filename_input, current_dir)
    end

    dialog = InputDialog:new{
        title = _("Save current game as"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        filename_input:onCloseKeyboard()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = onSaveConfirm,
                },
            }
        }
    }

    local dir_label = TextWidget:new{
        text = current_dir,
        face = Font:getFace("smallinfofont"),
        truncate_left = true,
        max_width = dialog:getSize().w * 0.8,
    }

    local browse_button = ButtonWidget:new{
        text = "...",
        callback = function()
            UIManager:show(
                PathChooser:new{
                    path = current_dir,
                    title = _("Select Save Folder"),
                    select_file = false,
                    show_files = true,
                    parent = dialog,
                    onConfirm = function(chosen)
                        if chosen and #chosen > 0 then
                            current_dir = chosen
                            dir_label:setText(chosen)
                            UIManager:setDirty(dialog, "ui")
                        end
                    end
                }
            )
        end,
    }

    filename_input = InputText:new{
        text = "game.pgn",
        focused = true,
        parent = dialog,
        enter_callback = onSaveConfirm,
    }

    local content = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        background = Blitbuffer.COLOR_WHITE,
        padding = 0,
        margin = 0,
        VerticalGroup:new{
            align = "left",
            dialog.title_bar,
            HorizontalGroup:new{
                spacing = Size.padding.large,
                TextWidget:new{ text = _("Folder") .. ":", face = Font:getFace("cfont", 22) },
                dir_label,
                HorizontalSpan:new{ width = Size.padding.small },
                browse_button,
            },
            HorizontalGroup:new{
                spacing = Size.padding.large,
                TextWidget:new{ text = _("Filename") .. ":", face = Font:getFace("cfont", 22) },
                filename_input,
            },
            CenterContainer:new{
                dimen = Geometry:new{
                    w = dialog.title_bar:getSize().w,
                    h = dialog.button_table:getSize().h,
                },
                dialog.button_table
            },
        },
    }

    dialog.movable = MovableContainer:new{ content }
    dialog[1] = CenterContainer:new{ dimen = Screen:getSize(), dialog.movable }
    dialog:refocusWidget()
    return dialog
end

function Kochess:openPromotionDialog(f,t,c)
    local choices = {q=Chess.QUEEN, r=Chess.ROOK, b=Chess.BISHOP, n=Chess.KNIGHT}
    local icons_p = { [Chess.QUEEN] = {[Chess.WHITE]="casualchess/wQ", [Chess.BLACK]="casualchess/bQ"}, [Chess.ROOK] = {[Chess.WHITE]="casualchess/wR", [Chess.BLACK]="casualchess/bR"}, [Chess.BISHOP] = {[Chess.WHITE]="casualchess/wB", [Chess.BLACK]="casualchess/bB"}, [Chess.KNIGHT] = {[Chess.WHITE]="casualchess/wN", [Chess.BLACK]="casualchess/bN"} }

    local icon_size = Screen:scaleBySize(60)

    local dialog = InputDialog:new{ title=_("Promote to"), buttons={} }
    local btns = {}
    for char, type in pairs(choices) do
        table.insert(btns, ButtonWidget:new{ icon=icons_p[type][c], width=icon_size, icon_width=icon_size, icon_height=icon_size, callback=function()
            UIManager:close(dialog)
            local m = self.game.move({from=f, to=t, promotion=char})
            if m then self.board:handleGameMove(m); self:onMoveExecuted(m) end
        end })
    end

    local content = FrameContainer:new{ radius=Size.radius.window, bordersize=Size.border.window, background=BACKGROUND_COLOR, padding=Size.padding.large,
        VerticalGroup:new{ align="center", dialog.title_bar, VerticalSpan:new{width=20}, HorizontalGroup:new{ spacing=20, unpack(btns) } }
    }
    dialog.movable = MovableContainer:new{ content }; dialog[1] = CenterContainer:new{ dimen=Screen:getSize(), dialog.movable }
    UIManager:show(dialog)
end

return Kochess
