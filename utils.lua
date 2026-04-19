-- utils.lua: subprocess and I/O utilities for KoChess
-- Uses raw POSIX FFI (fork/exec/pipe/poll) because KOReader does not expose
-- a public API for bidirectional subprocess I/O with non-blocking reads.
-- KOReader's own ffi/util and io.popen only support one-directional pipes,
-- which is insufficient for a UCI chess engine (stdin + stdout + stderr).

local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local C = ffi.C
-- FFI declarations (wrapped in pcall to survive duplicate-definition across reloads)
pcall(ffi.cdef, [[
    typedef long ssize_t;
    int pipe(int[2]);
    int fork(void);
    int execvp(const char *, char *const argv[]);
    void _exit(int);
    int waitpid(int, int *, int);
    int dup2(int, int);
    int close(int);
    int setpgid(int, int);
    int setpriority(int, int, int);
    ssize_t read(int, void *, size_t);
    ssize_t write(int, const void *, size_t);
    char *strerror(int);
    int errno;
]])

pcall(ffi.cdef, [[
    struct pollfd { int fd; short events; short revents; };
    int poll(struct pollfd *fds, unsigned long nfds, int timeout);
]])

-- Linux-only: run Stockfish at batch priority so it doesn't compete with the UI
pcall(ffi.cdef, [[
    int sched_setscheduler(int, int, void *);
]])

local PRIO_PROCESS = 0
local SCHED_BATCH  = 3
local POLLIN       = 0x001
local BUF_SZ       = 4096

local Utils = {}

-- ---------------------------------------------------------------------------
-- pollingLoop(interval_s, action, condition)
-- Schedules `action` via UIManager every `interval_s` seconds for as long as
-- `condition()` returns true. Action always runs at least once on the first
-- tick. This is fully async — it never blocks the UI event loop.
-- ---------------------------------------------------------------------------
function Utils.pollingLoop(interval_s, action, condition)
    local loop
    loop = function()
        action()  -- read whatever is available
        if condition and condition() then
            UIManager:scheduleIn(interval_s, loop)
        end
    end
    UIManager:nextTick(loop)  -- first tick immediately, without a frame delay
end

-- ---------------------------------------------------------------------------
-- execInSubProcess(cmd, args, with_pipes, double_fork)
-- Forks a child process running `cmd` with `args`.
-- Returns: pid, read_fd, write_fd  on success
--          false, error_string      on failure
-- with_pipes=true  : sets up stdin/stdout pipes (required for UCI)
-- double_fork=true : grandchild is detached from our process group so it
--                    survives if KOReader is killed (Stockfish keeps running)
-- ---------------------------------------------------------------------------
function Utils.execInSubProcess(cmd, args, with_pipes, double_fork)
    local p2c_r, p2c_w, c2p_r, c2p_w

    if with_pipes then
        local p1 = ffi.new("int[2]")
        if C.pipe(p1) ~= 0 then
            return false, "pipe1: " .. ffi.string(C.strerror(C.errno))
        end
        p2c_r, p2c_w = p1[0], p1[1]

        local p2 = ffi.new("int[2]")
        if C.pipe(p2) ~= 0 then
            C.close(p2c_r); C.close(p2c_w)
            return false, "pipe2: " .. ffi.string(C.strerror(C.errno))
        end
        c2p_r, c2p_w = p2[0], p2[1]
    end

    local pid = C.fork()
    if pid < 0 then
        if with_pipes then
            C.close(p2c_r); C.close(p2c_w)
            C.close(c2p_r); C.close(c2p_w)
        end
        return false, "fork: " .. ffi.string(C.strerror(C.errno))
    end

    if pid == 0 then
        -- Child (or intermediate for double-fork)
        if double_fork and C.fork() ~= 0 then C._exit(0) end

        -- Detach from our process group
        C.setpgid(0, 0)

        -- Run engine at low priority so the KOReader UI stays responsive
        pcall(function() C.sched_setscheduler(0, SCHED_BATCH, nil) end)
        C.setpriority(PRIO_PROCESS, 0, 5)

        if with_pipes then
            C.close(p2c_w)
            C.dup2(p2c_r, 0); C.close(p2c_r)   -- stdin  ← parent write end
            C.close(c2p_r)
            C.dup2(c2p_w, 1)                     -- stdout → parent read end
            C.dup2(c2p_w, 2)                     -- stderr → same pipe
            C.close(c2p_w)
        end

        local argc = #args
        local argv = ffi.new("char *[?]", argc + 2)
        argv[0] = ffi.cast("char *", cmd)
        for i = 1, argc do
            argv[i] = ffi.cast("char *", args[i])
        end
        argv[argc + 1] = nil

        C.execvp(cmd, argv)

        -- execvp only returns on failure
        local msg = "execvp failed: " .. ffi.string(C.strerror(C.errno)) .. "\n"
        C.write(2, msg, #msg)
        C._exit(127)
    end

    -- Parent
    if double_fork then
        -- Reap the intermediate child immediately
        C.waitpid(pid, ffi.new("int[1]"), 0)
    end
    if with_pipes then
        C.close(p2c_r)   -- parent doesn't read its own write-end
        C.close(c2p_w)   -- parent doesn't write its own read-end
    end
    return pid, c2p_r, p2c_w
end

-- ---------------------------------------------------------------------------
-- reader(fd, action)
-- Returns a function that, when called, does a non-blocking poll on `fd`,
-- reads any available data, splits on newlines, and calls action(line) for
-- each complete line. Partial lines are buffered until the next call.
-- ---------------------------------------------------------------------------
function Utils.reader(fd, action)
    local buffer = ""
    local pollfds = ffi.new("struct pollfd[1]")
    pollfds[0].fd = fd
    pollfds[0].events = POLLIN

    return function()
        -- Non-blocking check: timeout=0 means return immediately
        local ret = C.poll(pollfds, 1, 0)
        if ret <= 0 then return end                       -- nothing ready or error
        if pollfds[0].revents == 0 then return end

        local c_buf = ffi.new("char[?]", BUF_SZ)
        local n = C.read(fd, c_buf, BUF_SZ - 1)
        if n <= 0 then return end

        buffer = buffer .. ffi.string(c_buf, n)

        while true do
            local line, rest = buffer:match("^(.-)\n(.*)$")
            if line then
                action(line)
                buffer = rest
            else
                break
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- writer(fd)
-- Returns a function that writes a line (appending \n) to fd.
-- ---------------------------------------------------------------------------
function Utils.writer(fd)
    return function(cmd)
        local line = cmd .. "\n"
        local n = C.write(fd, line, #line)
        if n ~= #line then return false end
        return true
    end
end

return Utils
