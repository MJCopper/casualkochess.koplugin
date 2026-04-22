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
local json = require("json")

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
    -- resolve path relative to this file
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "") -- strip leading @ added by LuaJIT
    -- strip filename to get directory
    local path = src:match("^(.*[/\\])main%.lua$")

    return path
end

local PLUGIN_PATH = getPluginPath()

local ENGINES_DIR = PLUGIN_PATH .. "engines/"

local function fileExists(path)
    local ok = lfs.attributes(path, "mode")
    return ok == "file"
end

local function chmodX(path)
    -- required on Kindle/Kobo; harmless on other platforms
    os.execute('chmod +x "' .. path .. '"')
end

local function getArch()
    -- uname -m is available on Kobo, Kindle, and Linux
    local p = io.popen("uname -m 2>/dev/null")
    if not p then return "unknown" end
    local out = p:read("*a") or ""
    p:close()
    out = out:gsub("%s+", "")

    return (#out > 0) and out or "unknown"
end

local function getEnginePath()
    local arch = getArch()

    -- 1) prefer device-specific binary
    local candidates = {} 

    if Device:isKobo() then
        candidates = { ENGINES_DIR .. "stockfish" }
    elseif Device:isKindle() then
        candidates = { ENGINES_DIR .. "stockfish_kindle" }
    else
        -- fallback for PC/dev
        candidates = { PLUGIN_PATH .. "dev/engines/stockfish_pc"}
    end

    -- 2) arch fallback if device type doesn't match
    if arch == "x86_64" then
        candidates[#candidates+1] = ENGINES_DIR .. "stockfish_pc"
    elseif arch:match("^arm") then
        candidates[#candidates+1] = ENGINES_DIR .. "stockfish"
    elseif arch == "aarch64" then
        candidates[#candidates+1] = ENGINES_DIR .. "stockfish_linux_aarch64"
    end

    -- 3) use first binary that exists
    for _, path in ipairs(candidates) do
        if fileExists(path) then
            chmodX(path)
            return path
        end
    end

    return nil
end

local UCI_ENGINE_PATH = getEnginePath()
local GAMES_PATH = PLUGIN_PATH .. "Games"

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
    -- Clear any board state when widget is closed
    if self.board then
        self.board:clearValidMoves()
    end
end

function Kochess:handleEvent(event)
    -- CasualChessStart must bypass the stack guard — it is fired by the
    -- Dispatcher when the game is closed (not on stack) to launch the game.
    if event.handler == "onCasualChessStart" then
        return self:onCasualChessStart()
    end
    -- Block all other event handling when we are not currently shown as a
    -- top-level widget. Without this, the plugin receives events via
    -- FileManager's child propagation even after UIManager:close().
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
    -- Load persisted settings
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

local function mkdir_p(path)
    local sep = package.config:sub(1,1)
    local cur = ""
    for part in path:gmatch("[^" .. sep .. "]+") do
        cur = (cur == "") and part or (cur .. sep .. part)
        if lfs.attributes(cur, "mode") ~= "directory" then
            lfs.mkdir(cur)
        end
    end
end

function Kochess:installIconsIfNeeded()
    local data_dir = DataStorage:getDataDir()
    local dest_dir = data_dir .. "/resources/icons/casualchess"
    local src_dir  = PLUGIN_PATH .. "icons"
    if lfs.attributes(src_dir, "mode") ~= "directory" then return end
    mkdir_p(dest_dir)
    for entry in lfs.dir(src_dir) do
        if entry:match("%.svg$") then
            local dest_file = dest_dir .. "/" .. entry
            if lfs.attributes(dest_file, "mode") ~= "file" then
                os.execute('cp "' .. src_dir .. "/" .. entry .. '" "' .. dest_file .. '"')
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

    self:initializeGameLogic()
    self:initializeEngine()
    self:loadOpenings()
    self:buildUILayout()  -- initializeBoard is called inside buildUILayout
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
    self:restoreGameState()  -- load saved PGN/timers if available
    self.board:updateBoard()
    -- Ensure we're not already on the stack before showing (prevents duplicate
    -- entries that cause ghost gesture handlers after closing)
    UIManager:close(self)
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

    -- Restore the game from saved PGN
    local ok = pcall(function() self.game.load_pgn(pgn) end)
    if not ok then
        -- saved PGN was invalid, start fresh
        self:setSetting("saved_pgn", "")
        return
    end

    local tw = self:getSetting("saved_time_white", nil)
    local tb = self:getSetting("saved_time_black", nil)
    if tw then self.timer.time[Chess.WHITE] = tw end
    if tb then self.timer.time[Chess.BLACK] = tb end

    self.timer.currentPlayer = self.game.turn()
    self.running = self:getSetting("saved_running", false)

    -- Sync engine to restored position
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

-- Load openings database
function Kochess:loadOpenings()
    if self.openings then return end  -- cache

    self.openings = {}
    local path = PLUGIN_PATH .. "data/aperturas.json"

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

-- Initialize UCI engine
function Kochess:initializeEngine()

    -- Casual preset defaults
    local CASUAL = {
        skill_level     = 0,
        engine_depth    = 2,
        engine_movetime = 1,
        blunder_chance  = 0.20,
    }

    -- Detect missing keys — if any engine setting is absent, write all
    -- Casual defaults so older installs are migrated cleanly.
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
    -- Only load these if not already set (e.g. from a previous session in memory)
    if self.engine_movetime == nil then
        self.engine_movetime = self:getSetting("engine_movetime", CASUAL.engine_movetime)
    end
    if self.engine_depth == nil then
        self.engine_depth = self:getSetting("engine_depth", CASUAL.engine_depth)
    end
    if self.blunder_chance == nil then
        self.blunder_chance = self:getSetting("blunder_chance", CASUAL.blunder_chance)
    end
    -- Keep weakening instance in sync in case blunder_chance was just loaded
    if self.weakening then
        self.weakening:setChance(self.blunder_chance)
    end
    self.human_white = self:getSetting("human_white", true)
    self.human_black = self:getSetting("human_black", false)
    self.last_cp = nil

    if not UCI_ENGINE_PATH then

        UIManager:show(InfoMessage:new{
            text = "Stockfish engine not found.\nCopy the engine binary to:\n" .. ENGINES_DIR,
        })
        return
    end

    self.engine = Uci.UCIEngine.spawn(UCI_ENGINE_PATH, {})

    
    if not self.engine then

        UIManager:show(InfoMessage:new{ text = "Engine failed to start." })
        return
    end

    self.engine:on("read", function(data)
        if data then
            local clean = data:gsub("\r", "")

            -- parse score cp/mate from info lines (multipv 1 only)
            for line in tostring(data):gmatch("[^\r\n]+") do
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

        if not self:getSetting("saved_pgn", "") or self:getSetting("saved_pgn", "") == "" then
            self:updatePgnLogInitialText()
        end

        -- conservative settings for e-reader hardware
        self.engine.send("setoption name Hash value 8")
        self.engine.send("setoption name Threads value 1")
        self.engine.send("setoption name Skill Level value " .. defaultSkill)
        self.engine.send("setoption name Move Overhead value 150")
        self.engine.send("setoption name Ponder value false")
        self.engine.send("setoption name Slow Mover value 90")
        self.current_skill = defaultSkill

        self.engine:ucinewgame()

        -- If we restored a CvC game that was in progress, sync the position
        -- and resume. restoreGameState() ran before uciok fired so the game
        -- state is already loaded; the engine just wasn't ready yet.
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
    
    -- Send uci immediately; Stockfish buffers stdin so the command
    -- will be ready when the process starts. The uci() polling loop
    -- waits asynchronously for uciok without blocking the UI.

    self.engine:uci()
end

function Kochess:initializeGameLogic()
    self.game = Chess:new()
    self.game.reset()
    self.game.initial_fen = self.game.fen()
    -- Apply persisted player types
    local human_white = self:getSetting("human_white", true)
    local human_black = self:getSetting("human_black", false)
    self.game.set_human(Chess.WHITE, human_white)
    self.game.set_human(Chess.BLACK, human_black)
    -- Apply persisted time controls
    local base_w = self:getSetting("time_base_white", 900)
    local base_b = self:getSetting("time_base_black", 900)
    local incr_w = self:getSetting("time_incr_white", 10)
    local incr_b = self:getSetting("time_incr_black", 10)
    self.timer = Timer:new(
        {[Chess.WHITE]=base_w, [Chess.BLACK]=base_b},
        {[Chess.WHITE]=incr_w, [Chess.BLACK]=incr_b},
        function() self:updateTimerDisplay() end)
    self.running = false
    -- Weakening module: intercepts engine moves and optionally replaces with
    -- a random legal move. Chance is loaded from settings (default 0 = off).
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
    }
end

function Kochess:buildUILayout()
    -- Build layout bottom-up:
    -- 1. Status bar  (fixed, measured)
    -- 2. Log section (fixed, exact content height)
    -- 3. Board       (fills remaining space, constrained to square)
    local status_bar = self:createStatusBar()
    local status_h   = status_bar:getSize().h

    -- Log section dimensions
    local pad           = Screen:scaleBySize(8)
    local line_h        = Screen:scaleBySize(PGN_LOG_FONT_SIZE) + 4
    local pgn_h         = line_h
    local eval_h        = line_h
    local log_border    = Screen:scaleBySize(1)
    local toolbar_btn_h = Screen:scaleBySize(32)  -- fixed comfortable toolbar height
    local text_frame_h  = log_border * 2 + pad + pgn_h + eval_h + pad
    local min_log_h     = text_frame_h + toolbar_btn_h  -- min = 1 pgn line + eval + toolbar

    -- Board: square, fitted into remaining space above log+status.
    -- Board padding (top/left/right) is accounted for in board.lua cell calculation.
    local BOARD_SIZE    = 8
    local board_pad     = Screen:scaleBySize(8)
    local available_h   = self.full_height - status_h - min_log_h
    -- cell uses usable area (subtract board padding)
    local usable_w      = self.full_width - 2 * board_pad
    local cell          = math.floor(math.min(usable_w, available_h - board_pad) / BOARD_SIZE)
    local board_h       = cell * BOARD_SIZE + board_pad  -- widget height includes top padding
    -- log_h = everything remaining; pgn_log expands to fill extra space
    local log_h         = self.full_height - status_h - board_h
    local pgn_h         = log_h - text_frame_h + line_h  -- expands: base frame minus eval line

    self:initializeBoard(board_h)
    local toolbar_btn_w = math.floor(self.full_width / 5)
    local inner_w       = self.full_width - 2 * pad

    -- pgn_log expands to fill any extra space above the fixed frame content.
    -- Minimum = 1 line. Extra space comes from board being width-constrained.
    local frame_fixed_h = log_border * 2 + pad + eval_h + pad  -- frame without pgn
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
    -- Use direct assignment (not CenterContainer) so the layout always
    -- anchors to y=0. CenterContainer shifts content up when total height
    -- exceeds screen height, clipping the title bar above the screen top.
    self[1] = main_vgroup
end

function Kochess:updatePgnLogInitialText()
    if self.pgn_log then self.pgn_log:setText(""); UIManager:setDirty(self, "ui") end
end

-- Detect opening from move history
function Kochess:detectOpening()
    if not self.openings then return nil end

    -- get SAN history
    local hist = self.game.history and self.game:history() or nil
    if type(hist) ~= "table" or #hist == 0 then
        -- fallback: try functional-style call
        hist = self.game.history and self.game.history() or {}
    end

    local moves = {}
    for i, san in ipairs(hist) do
        if type(san) == "string" and san ~= "" then
            -- strip check/annotation symbols
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

    -- update PGN log
    self:updatePgnLog()

    -- detect opening
    local opening = self:detectOpening()

    -- update eval/opening line
    if self.eval_line then
        local eval_txt = formatEval(self)
        if opening then
            self.eval_line:setText(string.format("%s (%s) · %s", opening.name, opening.eco or "?", eval_txt))
        else
            self.eval_line:setText(eval_txt)
        end
    end

    -- checkmate: show dialog and stop
    local san = tostring(move.san or "")
    if san:find("#", 1, true) then
        -- turn already flipped; winner is the side that just moved
        local winner_color = (self.game.turn() == Chess.WHITE) and Chess.BLACK or Chess.WHITE
        self:showMateDialog(winner_color)
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

    -- When both sides are computer, insert a 1-second pause so UIManager can
    -- drain user input (close dialogs, settings taps, etc.) before the next
    -- engine search starts. Without the pause the polling loop re-queues so
    -- fast that user gestures are never serviced, locking the UI.
    local is_cvc = not self.game.is_human(Chess.WHITE) and not self.game.is_human(Chess.BLACK)
    if not is_cvc then
        -- At least one human side: no delay needed, fire immediately.
        self:launchUCI()
    else
        -- Computer vs Computer: schedule with a token so we can cancel if the
        -- user resets, undoes, or closes before the delay expires.
        local token = {}
        self._pending_launch = token
        UIManager:scheduleIn(1, function()
            if self._pending_launch ~= token then return end  -- cancelled
            self._pending_launch = nil
            self:launchUCI()
        end)
    end
end

function Kochess:uciMove(str)
    -- Optionally replace engine move with a random legal move
    if self.weakening then
        str = self.weakening:maybeWeaken(str)
    end
    local m = self.game.move({from=str:sub(1,2), to=str:sub(3,4), promotion=(#str==5 and str:sub(5,5) or nil)})
    if m then self.board:handleGameMove(m) end
end

function Kochess:launchUCI()
    -- guard against re-entry
    if self.engine_busy then return end
    self.engine_busy = true

    -- Build the move list from game history
    local moves = {}
    for _, m in ipairs(self.game.history({ verbose = true })) do
        moves[#moves + 1] = m.from .. m.to .. (m.promotion or "")
    end
    self.engine:position({ moves = table.concat(moves, " ") })

    self.eval_turn = self.game.turn()

    -- Send clock values and a hard movetime cap; engine_movetime is adjustable via Settings.
    local movetime_ms = (self.engine_movetime or 1) * 1000
    local wtime = math.max(100, self.timer:getRemainingTime(Chess.WHITE) * 1000)
    local btime = math.max(100, self.timer:getRemainingTime(Chess.BLACK) * 1000)

    -- Apply depth limit if configured (1-3); 0 means unlimited
    local d = tonumber(self.engine_depth) or 0
    local depth_limit = (d >= 1 and d <= 3) and d or nil

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
    self._pending_launch = nil  -- cancel any CvC inter-move delay
    if self.engine and self.engine.state.uciok then self.engine.send("stop") end
end

function Kochess:updatePgnLog()
    local moves = self.game:history()
    local txt = ""
    for i, m in ipairs(moves) do
        if i%2==1 then txt = txt .. " " .. (math.floor(i/2)+1) .. "." end
        txt = txt .. " " .. m
    end
    self.pgn_log:setText(txt)

    -- scroll to end
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
    -- Clear saved game so next launch starts fresh
    self:setSetting("saved_pgn", "")
    self.running = false
    self:updateTimerDisplay(); self:updatePlayerDisplay(); self.board:updateBoard(); UIManager:setDirty(self, "ui")
end

function Kochess:showMateDialog(winner_color)
    local winner = (winner_color == Chess.WHITE) and _("White") or _("Black")

    UIManager:show(ConfirmBox:new{
        text = string.format(_("Checkmate!\n%s wins."), winner),
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

            -- trigger engine move if computer plays first
            self:launchNextMove()
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
                    if not self.game.is_human(self.game.turn()) then self:launchUCI() end
                    self.timer:reset()
                    self:updatePlayerDisplay()
                    self:updateTimerDisplay()
                end,
            }:show()
        end,
        close_callback = function()
            UIManager:show(ConfirmBox:new{
                text        = _("Exit Chess?"),
                ok_text     = _("Exit"),
                ok_callback = function()
                    self.timer:stop()
                    if self.engine then self.engine:stop() end
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

                -- stop engine and timer
                self:stopUCI()
                self.timer:stop()

                self.game.reset()
                self.game.load_pgn(pgn_data)

                self.board:updateBoard()
                self:updatePgnLog()
                self:updateTimerDisplay()
                self:updatePlayerDisplay()

                -- sync engine to new position
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

    -- ensure .pgn extension
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