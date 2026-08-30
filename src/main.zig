const std = @import("std");

const bitman = @import("bitman");
const Individual = bitman.Individual;

// ============================================================================
// BITMAN SNAKE
//
// One-file evolutionary Snake experiment for Haeryu/bitman.
//
// Genome evaluation:
//   - 128 genomes
//   - 8 shared episodes per generation: 3 anchors + 5 rotating seeds
//   - 25 -> 256 -> 256 -> 3 ternary network
//   - outputs: TURN LEFT / GO STRAIGHT / TURN RIGHT
//   - top 8 genomes are copied unchanged (elitism)
//   - remaining children use roulette + uniform crossover + mutation
//
// Sensors (25 i8 inputs):
//   - 8 world-space rays x (wall proximity, body proximity)
//   - separate absolute head and food coordinates
//   - absolute heading vector
//   - hunger, length, and an explicit +1 constant
//
// Fitness:
//   +1       every non-collision step
//   +20      per NEW best distance unit toward the current food
//   +6000    when food is eaten
//   +400*N   food-chain bonus for the Nth food in an episode
//   +100000  if the board is completely filled
//
// The progress reward is monotonic per food: moving away and coming back can
// no longer farm shaping reward. Rotating episode seeds also make memorizing a
// tiny fixed training set much less useful.
//
// Episodes terminate on wall/body collision, starvation, or tick limit.
//
// Controls:
//   1 slow
//   2 normal
//   3 fast
//   4 turbo
//   5 warp
//   Q replay the recorded parents[0] action stream
//   Esc quit and print full history + graph
// ============================================================================

// ============================================================================
// RAW WIN32 CONSOLE
// ============================================================================

const BOOL = i32;
const DWORD = u32;
const WORD = u16;
const SHORT = i16;
const WCHAR = u16;
const HANDLE = *anyopaque;

const COORD = extern struct {
    x: SHORT,
    y: SHORT,
};

const SMALL_RECT = extern struct {
    left: SHORT,
    top: SHORT,
    right: SHORT,
    bottom: SHORT,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    size: COORD,
    cursor_position: COORD,
    attributes: WORD,
    window: SMALL_RECT,
    maximum_window_size: COORD,
};

const CONSOLE_CURSOR_INFO = extern struct {
    size: DWORD,
    visible: BOOL,
};

const CHAR_UNION = extern union {
    UnicodeChar: WCHAR,
    AsciiChar: u8,
};

const CHAR_INFO = extern struct {
    char: CHAR_UNION,
    attributes: WORD,
};

const KEY_EVENT_RECORD = extern struct {
    key_down: BOOL,
    repeat_count: WORD,
    virtual_key_code: WORD,
    virtual_scan_code: WORD,
    char: extern union {
        unicode_char: WCHAR,
        ascii_char: u8,
    },
    control_key_state: DWORD,
};

const INPUT_RECORD = extern struct {
    event_type: WORD,
    event: extern union {
        key_event: KEY_EVENT_RECORD,
        raw: [16]u8,
    },
};

const STD_INPUT_HANDLE: DWORD = 0xfffffff6;
const STD_OUTPUT_HANDLE: DWORD = 0xfffffff5;

const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const FILE_SHARE_READ: DWORD = 0x00000001;
const FILE_SHARE_WRITE: DWORD = 0x00000002;
const CONSOLE_TEXTMODE_BUFFER: DWORD = 1;

const KEY_EVENT: WORD = 0x0001;
const VK_ESCAPE: WORD = 0x1b;

const FG_BLUE: WORD = 0x0001;
const FG_GREEN: WORD = 0x0002;
const FG_RED: WORD = 0x0004;
const FG_INTENSITY: WORD = 0x0008;

const COLOR_DIM: WORD = FG_BLUE | FG_GREEN;
const COLOR_WHITE: WORD = FG_RED | FG_GREEN | FG_BLUE | FG_INTENSITY;
const COLOR_GREEN: WORD = FG_GREEN | FG_INTENSITY;
const COLOR_YELLOW: WORD = FG_RED | FG_GREEN | FG_INTENSITY;
const COLOR_CYAN: WORD = FG_GREEN | FG_BLUE | FG_INTENSITY;
const COLOR_RED: WORD = FG_RED | FG_INTENSITY;

extern "kernel32" fn GetStdHandle(
    nStdHandle: DWORD,
) callconv(.winapi) ?HANDLE;

extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: HANDLE,
    lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.winapi) BOOL;

extern "kernel32" fn GetConsoleCursorInfo(
    hConsoleOutput: HANDLE,
    lpConsoleCursorInfo: *CONSOLE_CURSOR_INFO,
) callconv(.winapi) BOOL;

extern "kernel32" fn SetConsoleCursorInfo(
    hConsoleOutput: HANDLE,
    lpConsoleCursorInfo: *const CONSOLE_CURSOR_INFO,
) callconv(.winapi) BOOL;

extern "kernel32" fn CreateConsoleScreenBuffer(
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*const anyopaque,
    dwFlags: DWORD,
    lpScreenBufferData: ?*anyopaque,
) callconv(.winapi) ?HANDLE;

extern "kernel32" fn SetConsoleActiveScreenBuffer(
    hConsoleOutput: HANDLE,
) callconv(.winapi) BOOL;

extern "kernel32" fn SetConsoleScreenBufferSize(
    hConsoleOutput: HANDLE,
    dwSize: COORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn WriteConsoleOutputW(
    hConsoleOutput: HANDLE,
    lpBuffer: [*]const CHAR_INFO,
    dwBufferSize: COORD,
    dwBufferCoord: COORD,
    lpWriteRegion: *SMALL_RECT,
) callconv(.winapi) BOOL;

extern "kernel32" fn GetNumberOfConsoleInputEvents(
    hConsoleInput: HANDLE,
    lpcNumberOfEvents: *DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn ReadConsoleInputW(
    hConsoleInput: HANDLE,
    lpBuffer: [*]INPUT_RECORD,
    nLength: DWORD,
    lpNumberOfEventsRead: *DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn CloseHandle(
    hObject: HANDLE,
) callconv(.winapi) BOOL;

const render_width = 128;
const render_height = 43;

const Frame = struct {
    cells: [render_width * render_height]CHAR_INFO,

    fn init() Frame {
        var frame: Frame = undefined;
        frame.clear(COLOR_WHITE);
        return frame;
    }

    fn clear(self: *Frame, attributes: WORD) void {
        for (&self.cells) |*cell| {
            cell.* = .{
                .char = .{ .UnicodeChar = ' ' },
                .attributes = attributes,
            };
        }
    }

    fn put(
        self: *Frame,
        x: usize,
        y: usize,
        ch: u8,
        attributes: WORD,
    ) void {
        if (x >= render_width or y >= render_height) return;

        self.cells[y * render_width + x] = .{
            .char = .{ .UnicodeChar = @intCast(ch) },
            .attributes = attributes,
        };
    }

    fn write(
        self: *Frame,
        x: usize,
        y: usize,
        text: []const u8,
        attributes: WORD,
    ) void {
        if (y >= render_height) return;

        for (text, 0..) |ch, i| {
            if (x + i >= render_width) break;
            self.put(x + i, y, ch, attributes);
        }
    }

    fn writeFmt(
        self: *Frame,
        x: usize,
        y: usize,
        attributes: WORD,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.write(x, y, text, attributes);
    }
};

const SpeedMode = enum {
    slow,
    normal,
    fast,
    turbo,
    warp,

    fn ticksPerFrame(self: SpeedMode) usize {
        return switch (self) {
            .slow => 1,
            .normal => 1,
            .fast => 32,
            .turbo => 512,
            .warp => 4096,
        };
    }

    fn delayMs(self: SpeedMode) i64 {
        return switch (self) {
            .slow => 80,
            .normal => 25,
            .fast => 1,
            .turbo => 0,
            .warp => 0,
        };
    }

    fn name(self: SpeedMode) []const u8 {
        return switch (self) {
            .slow => "slow",
            .normal => "normal",
            .fast => "fast",
            .turbo => "turbo",
            .warp => "warp",
        };
    }
};

const InputAction = struct {
    quit: bool = false,
    mode: ?SpeedMode = null,
    replay: bool = false,
    replay_toggle: bool = false,
    replay_restart: bool = false,
    replay_seek_percent: ?usize = null,
    replay_step: i8 = 0,
    replay_speed_delta: i8 = 0,
};

const WinConsole = struct {
    input: HANDLE,
    original: HANDLE,
    render_buffer: HANDLE,
    original_cursor: CONSOLE_CURSOR_INFO,

    pub fn init() !WinConsole {
        const input = GetStdHandle(STD_INPUT_HANDLE) orelse
            return error.NoConsole;
        const original = GetStdHandle(STD_OUTPUT_HANDLE) orelse
            return error.NoConsole;

        if (isInvalidHandle(input) or isInvalidHandle(original)) {
            return error.NoConsole;
        }

        var screen_info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (GetConsoleScreenBufferInfo(original, &screen_info) == 0) {
            return error.NoConsole;
        }

        var cursor_info: CONSOLE_CURSOR_INFO = undefined;
        if (GetConsoleCursorInfo(original, &cursor_info) == 0) {
            cursor_info = .{
                .size = 25,
                .visible = 1,
            };
        }

        const render_buffer =
            CreateConsoleScreenBuffer(
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                null,
                CONSOLE_TEXTMODE_BUFFER,
                null,
            ) orelse return error.NoConsole;

        if (isInvalidHandle(render_buffer)) {
            return error.NoConsole;
        }

        errdefer _ = CloseHandle(render_buffer);

        const visible_width =
            screen_info.window.right - screen_info.window.left + 1;
        const visible_height =
            screen_info.window.bottom - screen_info.window.top + 1;

        const desired_width: SHORT = @max(
            visible_width,
            @as(SHORT, @intCast(render_width)),
        );
        const desired_height: SHORT = @max(
            visible_height,
            @as(SHORT, @intCast(render_height)),
        );

        _ = SetConsoleScreenBufferSize(
            render_buffer,
            .{
                .x = desired_width,
                .y = desired_height,
            },
        );

        var hidden_cursor = cursor_info;
        hidden_cursor.visible = 0;
        _ = SetConsoleCursorInfo(render_buffer, &hidden_cursor);

        return .{
            .input = input,
            .original = original,
            .render_buffer = render_buffer,
            .original_cursor = cursor_info,
        };
    }

    pub fn begin(self: *WinConsole) void {
        _ = SetConsoleActiveScreenBuffer(self.render_buffer);
    }

    pub fn end(self: *WinConsole) void {
        _ = SetConsoleActiveScreenBuffer(self.original);
        _ = SetConsoleCursorInfo(self.original, &self.original_cursor);
        _ = CloseHandle(self.render_buffer);
    }

    pub fn present(
        self: *WinConsole,
        frame: *const Frame,
    ) void {
        var region = SMALL_RECT{
            .left = 0,
            .top = 0,
            .right = @intCast(render_width - 1),
            .bottom = @intCast(render_height - 1),
        };

        _ = WriteConsoleOutputW(
            self.render_buffer,
            frame.cells[0..].ptr,
            .{
                .x = @intCast(render_width),
                .y = @intCast(render_height),
            },
            .{ .x = 0, .y = 0 },
            &region,
        );
    }

    pub fn pollInput(self: *WinConsole) InputAction {
        var action = InputAction{};

        var pending: DWORD = 0;
        if (GetNumberOfConsoleInputEvents(self.input, &pending) == 0) {
            return action;
        }

        while (pending != 0) {
            var records: [32]INPUT_RECORD = undefined;
            const request: DWORD = @min(
                pending,
                @as(DWORD, @intCast(records.len)),
            );

            var read: DWORD = 0;
            if (ReadConsoleInputW(
                self.input,
                records[0..].ptr,
                request,
                &read,
            ) == 0) {
                break;
            }

            for (records[0..@intCast(read)]) |record| {
                if (record.event_type != KEY_EVENT) continue;

                const key = record.event.key_event;
                if (key.key_down == 0) continue;

                if (key.virtual_key_code == VK_ESCAPE) {
                    action.quit = true;
                    continue;
                }

                const ch = key.char.ascii_char;
                switch (ch) {
                    'q', 'Q' => action.replay = true,
                    '1' => {
                        action.mode = .slow;
                        action.replay_seek_percent = 10;
                    },
                    '2' => {
                        action.mode = .normal;
                        action.replay_seek_percent = 20;
                    },
                    '3' => {
                        action.mode = .fast;
                        action.replay_seek_percent = 30;
                    },
                    '4' => {
                        action.mode = .turbo;
                        action.replay_seek_percent = 40;
                    },
                    '5' => {
                        action.mode = .warp;
                        action.replay_seek_percent = 50;
                    },
                    '6' => action.replay_seek_percent = 60,
                    '7' => action.replay_seek_percent = 70,
                    '8' => action.replay_seek_percent = 80,
                    '9' => action.replay_seek_percent = 90,
                    '0' => action.replay_seek_percent = 100,
                    ' ' => action.replay_toggle = true,
                    'r', 'R' => action.replay_restart = true,
                    ',' => action.replay_step = -1,
                    '.' => action.replay_step = 1,
                    '[' => action.replay_speed_delta = -1,
                    ']' => action.replay_speed_delta = 1,
                    else => {},
                }
            }

            if (GetNumberOfConsoleInputEvents(self.input, &pending) == 0) {
                break;
            }
        }

        return action;
    }

    fn isInvalidHandle(handle: HANDLE) bool {
        return @intFromPtr(handle) == std.math.maxInt(usize);
    }
};

// ============================================================================
// SNAKE WORLD
// ============================================================================

const board_width = 28;
const board_height = 18;
const board_cells = board_width * board_height;

const population_size = 128;
const elite_count = 8;
const episode_count = 8;
const anchor_episode_count = 3;

// There is deliberately no global episode tick limit. A productive snake may
// run until it collides or fills the board. The only anti-infinite-loop guard
// is "hunger", and that budget grows with body length so late-game routing is
// not killed by the old fixed 200-step cap.
const starvation_base = 200;
const starvation_per_body_cell = 3;

// The replay stream records one champion track without allocating in the
// simulation step. This upper bound covers eight episodes with a conservative
// starvation budget for every possible body length.
const replay_max_ticks_per_episode =
    (board_cells - 3) *
    (starvation_base + board_cells * starvation_per_body_cell) +
    1;
const replay_action_capacity = episode_count * replay_max_ticks_per_episode;
const replay_segment_capacity = 4096;

// 8 absolute rays * 2 channels + head xy + food xy + heading xy
// + hunger + length + constant.
const ray_count = 8;
const ray_channel_count = 2;
const ray_input_count = ray_count * ray_channel_count;
const head_x_input = ray_input_count;
const head_y_input = head_x_input + 1;
const food_x_input = head_y_input + 1;
const food_y_input = food_x_input + 1;
const direction_x_input = food_y_input + 1;
const direction_y_input = direction_x_input + 1;
const hunger_input = direction_y_input + 1;
const length_input = hunger_input + 1;
const constant_input = length_input + 1;
const input_count = constant_input + 1;
const hidden0 = 256;
const hidden1 = 256;
const output_count = 3;

const input_gain: f32 = 1.0 / 127.0;

// 72,704 ternary weights. At 0.25%, roughly 182 weights mutate per child.
const mutation_chance: f32 = 0.0025;
const mutation_coeff: f32 = 1.0;

const food_reward: u64 = 6000;
const food_chain_reward: u64 = 400;
const progress_reward: u64 = 20;
const survival_reward: u64 = 1;
const board_clear_reward: u64 = 100000;

const history_capacity = 30;
const stats_capacity_initial = 128;
const evaluation_episode_count = 1000;
const evaluation_seed_namespace: u64 = 0x4556_414c_5541_5445;

const checkpoint_path = "bitman_snake.chk";
const checkpoint_snapshot_interval: usize = 50;
const checkpoint_snapshot_name_capacity = 64;
const checkpoint_snapshot_prefix = "bitman_snake_";
const checkpoint_snapshot_suffix = ".chk";
const checkpoint_magic = "BMSNKCP1";
const checkpoint_version: u64 = 1;

const random_baseline_count: usize = 100;
const replay_file_path = "snake_replay.rep";
const replay_file_magic = "BMSNKRP1";
const replay_file_version: u64 = 1;
const replay_record_magic = "SEGM";

const anchor_episode_seeds = [anchor_episode_count]u64{
    0x1111_2222_3333_4444,
    0x94d0_49bb_1331_11eb,
    0x6a09_e667_f3bc_c909,
};

const Pos = struct {
    x: i16,
    y: i16,

    fn eql(a: Pos, b: Pos) bool {
        return a.x == b.x and a.y == b.y;
    }
};

const Direction = enum(u2) {
    up,
    righ,
    down,
    lef,

    fn left(self: Direction) Direction {
        return switch (self) {
            .up => .lef,
            .lef => .down,
            .down => .righ,
            .righ => .up,
        };
    }

    fn right(self: Direction) Direction {
        return switch (self) {
            .up => .righ,
            .righ => .down,
            .down => .lef,
            .lef => .up,
        };
    }

    fn delta(self: Direction) Pos {
        return switch (self) {
            .up => .{ .x = 0, .y = -1 },
            .righ => .{ .x = 1, .y = 0 },
            .down => .{ .x = 0, .y = 1 },
            .lef => .{ .x = -1, .y = 0 },
        };
    }

    fn name(self: Direction) []const u8 {
        return switch (self) {
            .up => "up",
            .righ => "right",
            .down => "down",
            .lef => "left",
        };
    }
};

const RelativeAction = enum(u2) {
    left,
    straight,
    right,

    fn name(self: RelativeAction) []const u8 {
        return switch (self) {
            .left => "LEFT",
            .straight => "STRAIGHT",
            .right => "RIGHT",
        };
    }
};

const GameStatus = enum {
    active,
    collision,
    starved,
    cleared,

    fn name(self: GameStatus) []const u8 {
        return switch (self) {
            .active => "active",
            .collision => "collision",
            .starved => "starved",
            .cleared => "cleared",
        };
    }
};

const StepEvents = struct {
    ate_food: bool = false,
    progress_units: u16 = 0,
    cleared: bool = false,
};

const SnakeGame = struct {
    snake: [board_cells]Pos,
    length: usize,
    direction: Direction,
    food: Pos,

    ticks: usize,
    steps_since_food: usize,
    foods: u64,

    rng_state: u64,
    closest_food_distance: i32,
    status: GameStatus,

    fn init(seed: u64) SnakeGame {
        var game = SnakeGame{
            .snake = undefined,
            .length = 3,
            .direction = @enumFromInt(@as(u2, @truncate(seed >> 8))),
            .food = undefined,
            .ticks = 0,
            .steps_since_food = 0,
            .foods = 0,
            .rng_state = if (seed == 0) 0x9e37_79b9_7f4a_7c15 else seed,
            .closest_food_distance = std.math.maxInt(i32),
            .status = .active,
        };

        // Randomize the whole legal start region, not just a tiny center patch.
        // The bounds account for the two body cells behind the head.
        const min_x: i16 = if (game.direction == .righ) 2 else 0;
        const max_x: i16 = if (game.direction == .lef)
            @intCast(board_width - 3)
        else
            @intCast(board_width - 1);
        const min_y: i16 = if (game.direction == .down) 2 else 0;
        const max_y: i16 = if (game.direction == .up)
            @intCast(board_height - 3)
        else
            @intCast(board_height - 1);

        const span_x: u64 = @intCast(max_x - min_x + 1);
        const span_y: u64 = @intCast(max_y - min_y + 1);

        const h = Pos{
            .x = min_x + @as(i16, @intCast((seed >> 16) % span_x)),
            .y = min_y + @as(i16, @intCast((seed >> 32) % span_y)),
        };

        game.snake[0] = h;

        const back = game.direction.delta();
        game.snake[1] = .{
            .x = h.x - back.x,
            .y = h.y - back.y,
        };
        game.snake[2] = .{
            .x = h.x - back.x * 2,
            .y = h.y - back.y * 2,
        };

        game.spawnFood();

        return game;
    }

    fn head(self: *const SnakeGame) Pos {
        return self.snake[0];
    }

    fn step(
        self: *SnakeGame,
        action: RelativeAction,
    ) StepEvents {
        if (self.status != .active) return .{};

        var events = StepEvents{};

        self.direction = switch (action) {
            .left => self.direction.left(),
            .straight => self.direction,
            .right => self.direction.right(),
        };

        const delta = self.direction.delta();
        const next = Pos{
            .x = self.head().x + delta.x,
            .y = self.head().y + delta.y,
        };

        self.ticks += 1;
        self.steps_since_food += 1;

        const eating = Pos.eql(next, self.food);

        if (!insideBoard(next) or self.collidesWithBody(next, eating)) {
            self.status = .collision;
            return events;
        }

        if (eating) {
            if (self.length == board_cells) {
                self.status = .cleared;
                events.cleared = true;
                return events;
            }

            var i = self.length;
            while (i > 0) : (i -= 1) {
                self.snake[i] = self.snake[i - 1];
            }
            self.snake[0] = next;
            self.length += 1;

            self.foods += 1;
            self.steps_since_food = 0;
            events.ate_food = true;

            if (self.length == board_cells) {
                self.status = .cleared;
                events.cleared = true;
                return events;
            }

            self.spawnFood();
        } else {
            var i = self.length - 1;
            while (i > 0) : (i -= 1) {
                self.snake[i] = self.snake[i - 1];
            }
            self.snake[0] = next;

            const new_distance = manhattanDistance(
                self.head(),
                self.food,
            );

            // Potential-like shaping without the classic oscillation exploit:
            // only reward a distance that has never been reached for this food.
            if (new_distance < self.closest_food_distance) {
                const d = self.closest_food_distance - new_distance;
                events.progress_units = @intCast(d);
                self.closest_food_distance = new_distance;
            }
        }

        if (self.steps_since_food >= self.starvationBudget()) {
            self.status = .starved;
        }

        return events;
    }

    fn starvationBudget(self: *const SnakeGame) usize {
        // Near a full board, reaching a randomly spawned food can legitimately
        // require hundreds of steps. Grow the budget with the snake instead of
        // imposing a global episode duration.
        return starvation_base + self.length * starvation_per_body_cell;
    }

    fn collidesWithBody(
        self: *const SnakeGame,
        next: Pos,
        eating: bool,
    ) bool {
        // When not eating, the tail moves away in the same tick. It is legal
        // for the new head to enter that old tail cell.
        const check_len =
            if (eating)
                self.length
            else
                self.length - 1;

        for (self.snake[0..check_len]) |part| {
            if (Pos.eql(part, next)) return true;
        }

        return false;
    }

    fn contains(self: *const SnakeGame, pos: Pos) bool {
        for (self.snake[0..self.length]) |part| {
            if (Pos.eql(part, pos)) return true;
        }
        return false;
    }

    fn spawnFood(self: *SnakeGame) void {
        const max_attempts = board_cells * 2;

        for (0..max_attempts) |_| {
            const index: usize = @intCast(
                nextRandom(&self.rng_state) %
                    @as(u64, @intCast(board_cells)),
            );

            const candidate = Pos{
                .x = @intCast(index % board_width),
                .y = @intCast(index / board_width),
            };

            if (!self.contains(candidate)) {
                self.food = candidate;
                self.closest_food_distance = manhattanDistance(
                    self.head(),
                    candidate,
                );
                return;
            }
        }

        // Deterministic fallback for a nearly-full board.
        for (0..board_cells) |index| {
            const candidate = Pos{
                .x = @intCast(index % board_width),
                .y = @intCast(index / board_width),
            };

            if (!self.contains(candidate)) {
                self.food = candidate;
                self.closest_food_distance = manhattanDistance(
                    self.head(),
                    candidate,
                );
                return;
            }
        }

        self.status = .cleared;
    }
};

const Agent = struct {
    game: SnakeGame,
    episode_index: usize,

    fitness: u64,
    total_foods: u64,
    total_steps: u64,
    clears: u64,

    done: bool,
    last_action: RelativeAction,
    last_action_valid: bool,

    fn init(seeds: *const [episode_count]u64) Agent {
        return .{
            .game = SnakeGame.init(seeds[0]),
            .episode_index = 0,
            .fitness = 0,
            .total_foods = 0,
            .total_steps = 0,
            .clears = 0,
            .done = false,
            .last_action = .straight,
            .last_action_valid = false,
        };
    }

    fn finishCurrentEpisode(
        self: *Agent,
        seeds: *const [episode_count]u64,
    ) void {
        self.total_foods += self.game.foods;
        self.total_steps += self.game.ticks;

        if (self.game.status == .cleared) {
            self.clears += 1;
        }

        if (self.episode_index + 1 >= episode_count) {
            self.done = true;
            return;
        }

        self.episode_index += 1;
        self.game = SnakeGame.init(
            seeds[self.episode_index],
        );
    }
};

const ReplaySegment = struct {
    generation: usize,
    episode_index: usize,
    seed: u64,
    start: usize,
    len: usize,
};

const ReplayLog = struct {
    actions: []RelativeAction,
    segments: []ReplaySegment,
    segment_count: usize,
    action_count: usize,
    persisted_segment_count: usize,
    recording_enabled: bool,
    truncated: bool,

    fn init(
        actions: []RelativeAction,
        segments: []ReplaySegment,
    ) ReplayLog {
        return .{
            .actions = actions,
            .segments = segments,
            .segment_count = 0,
            .action_count = 0,
            .persisted_segment_count = 0,
            .recording_enabled = true,
            .truncated = false,
        };
    }

    fn deinit(self: *ReplayLog, allocator: std.mem.Allocator) void {
        allocator.free(self.actions);
        allocator.free(self.segments);
        self.* = undefined;
    }

    fn reset(self: *ReplayLog) void {
        self.segment_count = 0;
        self.action_count = 0;
        self.persisted_segment_count = 0;
        self.recording_enabled = true;
        self.truncated = false;
    }

    // Training only needs unpersisted replay data in memory. Once completed
    // generations are appended to snake_replay.rep, compact them away so the
    // hot simulation path can keep using fixed preallocated storage forever.
    fn discardPersisted(self: *ReplayLog) void {
        const discard_segments = self.persisted_segment_count;
        if (discard_segments == 0) return;

        std.debug.assert(discard_segments <= self.segment_count);

        const first_kept_action = if (discard_segments < self.segment_count)
            self.segments[discard_segments].start
        else
            self.action_count;

        const kept_action_count = self.action_count - first_kept_action;
        if (kept_action_count != 0) {
            std.mem.copyForwards(
                RelativeAction,
                self.actions[0..kept_action_count],
                self.actions[first_kept_action..self.action_count],
            );
        }

        const kept_segment_count = self.segment_count - discard_segments;
        for (0..kept_segment_count) |i| {
            var segment = self.segments[discard_segments + i];
            segment.start -= first_kept_action;
            self.segments[i] = segment;
        }

        self.segment_count = kept_segment_count;
        self.action_count = kept_action_count;
        self.persisted_segment_count = 0;

        // Capacity exhaustion should not normally happen because the action
        // buffer is sized for a full generation. If it ever does, recover for
        // subsequent generations after compaction rather than disabling replay
        // forever.
        self.recording_enabled = true;
        self.truncated = false;
    }

    fn beginSegment(
        self: *ReplayLog,
        generation: usize,
        episode_index: usize,
        seed: u64,
    ) void {
        if (!self.recording_enabled) return;

        if (self.segment_count >= self.segments.len) {
            self.recording_enabled = false;
            self.truncated = true;
            return;
        }

        self.segments[self.segment_count] = .{
            .generation = generation,
            .episode_index = episode_index,
            .seed = seed,
            .start = self.action_count,
            .len = 0,
        };
        self.segment_count += 1;
    }

    fn append(self: *ReplayLog, action: RelativeAction) void {
        if (!self.recording_enabled or self.segment_count == 0) return;

        if (self.action_count >= self.actions.len) {
            self.recording_enabled = false;
            self.truncated = true;
            return;
        }

        self.actions[self.action_count] = action;
        self.action_count += 1;
        self.segments[self.segment_count - 1].len += 1;
    }

    fn totalActions(self: *const ReplayLog) usize {
        return self.action_count;
    }
};

const GenerationStats = struct {
    generation: usize = 0,
    global_ticks: usize = 0,

    best_fitness: u64 = 0,
    best_index: usize = 0,
    average_fitness: f64 = 0.0,

    best_foods: u64 = 0,
    average_foods: f64 = 0.0,

    best_steps: u64 = 0,
    total_clears: u64 = 0,
};

const Simulation = struct {
    agents: [population_size]Agent,

    parents: []Individual,
    children: []Individual,

    // One scratch buffer per parallel evaluation chunk. Individual.forward()
    // mutates its scratch buffer, so sharing one here would be a data race.
    eval_buffers: []Individual.PerThreadBuffer,
    ga_buffer: Individual.PerThreadBuffer,
    worker_count: usize,

    allocator: std.mem.Allocator,

    generation: usize,
    global_ticks: usize,

    last_stats: GenerationStats,
    best_ever_fitness: u64,
    best_ever_foods: u64,

    stats_log: []GenerationStats,
    stats_len: usize,

    history: [history_capacity]f64,
    history_len: usize,

    episode_seeds: [episode_count]u64,
    replay_log: ReplayLog,

    pub fn init(
        allocator: std.mem.Allocator,
        random: std.Random,
    ) !Simulation {
        const layer_settings = [_]Individual.LayerSetting{
            .{ .cols = input_count, .rows = hidden0 },
            .{ .cols = hidden0, .rows = hidden1 },
            .{ .cols = hidden1, .rows = output_count },
        };

        const population_a = try allocPopulation(
            allocator,
            random,
            &layer_settings,
            population_size,
            .random,
        );
        errdefer freePopulation(allocator, population_a);

        const population_b = try allocPopulation(
            allocator,
            random,
            &layer_settings,
            population_size,
            .empty,
        );
        errdefer freePopulation(allocator, population_b);

        // activation_pfns[1] == leakyReLU8.
        // Signed hidden values are useful; the final action is categorical
        // argmax so there is no need to squash the output into [-1, 1].
        for (population_a) |*brain| {
            brain.activation_pfn_index = 1;
        }
        for (population_b) |*brain| {
            brain.activation_pfn_index = 1;
        }

        const logical_cpus = std.Thread.getCpuCount() catch 1;
        const worker_count = @max(
            1,
            @min(population_size, @min(logical_cpus, 16)),
        );

        const eval_buffers = try allocator.alloc(
            Individual.PerThreadBuffer,
            worker_count,
        );
        errdefer allocator.free(eval_buffers);

        var eval_buffers_initialized: usize = 0;
        errdefer {
            for (eval_buffers[0..eval_buffers_initialized]) |*buffer| {
                buffer.deinit(allocator);
            }
        }

        for (eval_buffers) |*buffer| {
            buffer.* = try Individual.PerThreadBuffer.init(
                allocator,
                population_a[0].maxRowColLen(),
                population_a[0].maxElementsLen(),
            );
            eval_buffers_initialized += 1;
        }

        var ga_buffer = try Individual.PerThreadBuffer.init(
            allocator,
            population_a[0].maxRowColLen(),
            population_a[0].maxElementsLen(),
        );
        errdefer ga_buffer.deinit(allocator);

        const stats_log = try allocator.alloc(
            GenerationStats,
            stats_capacity_initial,
        );
        errdefer allocator.free(stats_log);

        const replay_actions = try allocator.alloc(
            RelativeAction,
            replay_action_capacity,
        );
        errdefer allocator.free(replay_actions);

        const replay_segments = try allocator.alloc(
            ReplaySegment,
            replay_segment_capacity,
        );
        errdefer allocator.free(replay_segments);

        var sim = Simulation{
            .agents = undefined,
            .parents = population_a,
            .children = population_b,
            .eval_buffers = eval_buffers,
            .ga_buffer = ga_buffer,
            .worker_count = worker_count,
            .allocator = allocator,
            .generation = 0,
            .global_ticks = 0,
            .last_stats = .{},
            .best_ever_fitness = 0,
            .best_ever_foods = 0,
            .stats_log = stats_log,
            .stats_len = 0,
            .history = @splat(0.0),
            .history_len = 0,
            .episode_seeds = undefined,
            .replay_log = ReplayLog.init(
                replay_actions,
                replay_segments,
            ),
        };

        sim.resetAgents();

        return sim;
    }

    pub fn deinit(
        self: *Simulation,
        allocator: std.mem.Allocator,
    ) void {
        for (self.eval_buffers) |*buffer| {
            buffer.deinit(allocator);
        }
        allocator.free(self.eval_buffers);
        self.ga_buffer.deinit(allocator);
        freePopulation(allocator, self.parents);
        freePopulation(allocator, self.children);
        allocator.free(self.stats_log);
        self.replay_log.deinit(allocator);
        self.* = undefined;
    }

    pub fn step(
        self: *Simulation,
        io: std.Io,
        random: std.Random,
    ) !?GenerationStats {
        const replay_episode_index = self.agents[0].episode_index;
        const replay_was_done = self.agents[0].done;

        self.global_ticks += 1;
        try self.stepPopulationParallel(io);

        if (!replay_was_done and
            self.agents[0].last_action_valid)
        {
            self.replay_log.append(self.agents[0].last_action);

            if (self.agents[0].episode_index != replay_episode_index) {
                self.replay_log.beginSegment(
                    self.generation,
                    self.agents[0].episode_index,
                    self.episode_seeds[self.agents[0].episode_index],
                );
            }
        }

        if (self.allDone()) {
            return self.evolve(random);
        }

        return null;
    }

    fn stepPopulationParallel(self: *Simulation, io: std.Io) !void {
        var group: std.Io.Group = .init;
        defer group.cancel(io);

        const chunk_size =
            (population_size + self.worker_count - 1) / self.worker_count;

        for (0..self.worker_count) |worker_index| {
            const begin = worker_index * chunk_size;
            if (begin >= population_size) break;
            const end = @min(begin + chunk_size, population_size);

            group.concurrent(
                io,
                stepPopulationRange,
                .{ self, worker_index, begin, end },
            ) catch {
                // Keep the experiment portable to Io implementations which do
                // not provide real concurrency. Ranges are disjoint, so doing
                // this one inline is safe while other chunks are running.
                stepPopulationRange(self, worker_index, begin, end);
            };
        }

        try group.await(io);
    }

    fn stepPopulationRange(
        self: *Simulation,
        worker_index: usize,
        begin: usize,
        end: usize,
    ) void {
        const buffer = &self.eval_buffers[worker_index];

        for (begin..end) |i| {
            const agent = &self.agents[i];
            const brain = &self.parents[i];
            agent.last_action_valid = false;
            if (agent.done) continue;

            const input = makeInput(&agent.game);

            _ = brain.forward(
                &input,
                input_gain,
                buffer,
            );

            const action = chooseAction(brain.out);
            agent.last_action = action;
            agent.last_action_valid = true;
            const events = agent.game.step(action);

            if (agent.game.status != .collision) {
                agent.fitness += survival_reward;
            }

            agent.fitness +=
                @as(u64, events.progress_units) * progress_reward;

            if (events.ate_food) {
                agent.fitness += food_reward;
                agent.fitness +=
                    agent.game.foods * food_chain_reward;
            }

            if (events.cleared) {
                agent.fitness += board_clear_reward;
            }

            if (agent.game.status != .active) {
                agent.finishCurrentEpisode(&self.episode_seeds);
            }
        }
    }

    fn evolve(
        self: *Simulation,
        random: std.Random,
    ) GenerationStats {
        const stats = self.currentStats();

        for (
            self.agents,
            self.parents,
        ) |agent, *brain| {
            brain.fitness = agent.fitness + 1;
        }

        const elite_indices = self.eliteIndices();

        // Breed only the non-elite slots.
        bitman.genetic_algorithm.evolve(
            random,
            self.parents,
            self.children[elite_count..],
            &self.ga_buffer,
            .roulette_wheel,
            .uniform_crossover,
            .{
                .uniform_mutation = .{
                    .chance = mutation_chance,
                    .coeff = mutation_coeff,
                },
            },
        );

        // Exact preservation of the best genomes.
        for (0..elite_count) |i| {
            copyGenome(
                &self.parents[elite_indices[i]],
                &self.children[i],
            );
        }

        for (self.children) |*brain| {
            brain.activation_pfn_index = 1;
            brain.fitness = 0;
        }

        const temp = self.parents;
        self.parents = self.children;
        self.children = temp;

        self.last_stats = stats;
        self.best_ever_fitness = @max(
            self.best_ever_fitness,
            stats.best_fitness,
        );
        self.best_ever_foods = @max(
            self.best_ever_foods,
            stats.best_foods,
        );

        self.appendStats(stats);
        self.pushHistory(stats.average_foods);

        self.generation += 1;
        self.global_ticks = 0;
        self.resetAgents();

        return stats;
    }

    fn resetAgents(self: *Simulation) void {
        self.refreshEpisodeSeeds();

        for (&self.agents) |*agent| {
            agent.* = Agent.init(&self.episode_seeds);
        }

        self.replay_log.beginSegment(
            self.generation,
            0,
            self.episode_seeds[0],
        );
    }

    fn refreshEpisodeSeeds(self: *Simulation) void {
        for (0..episode_count) |i| {
            if (i < anchor_episode_count) {
                self.episode_seeds[i] = anchor_episode_seeds[i];
                continue;
            }

            // Every genome in the generation receives the same episodes, but
            // most episodes change between generations. This preserves fair
            // selection while resisting memorization of a tiny seed set.
            const g: u64 = @intCast(self.generation + 1);
            const j: u64 = @intCast(i + 1);
            const seed =
                0x534e_414b_455f_4556 ^
                (g *% 0x9e37_79b9_7f4a_7c15) ^
                (j *% 0xbf58_476d_1ce4_e5b9);

            self.episode_seeds[i] = splitMix64(seed);
        }
    }

    fn allDone(self: *const Simulation) bool {
        for (self.agents) |agent| {
            if (!agent.done) return false;
        }
        return true;
    }

    fn bestIndex(self: *const Simulation) usize {
        var best_index: usize = 0;
        var best_fitness = self.agents[0].fitness;

        for (self.agents[1..], 1..) |agent, i| {
            if (agent.fitness > best_fitness) {
                best_fitness = agent.fitness;
                best_index = i;
            }
        }

        return best_index;
    }

    fn displayIndex(self: *const Simulation) usize {
        var found = false;
        var result: usize = 0;
        var best_fitness: u64 = 0;

        for (self.agents, 0..) |agent, i| {
            if (agent.done) continue;

            if (!found or agent.fitness > best_fitness) {
                found = true;
                result = i;
                best_fitness = agent.fitness;
            }
        }

        return if (found) result else self.bestIndex();
    }

    fn eliteIndices(self: *const Simulation) [elite_count]usize {
        var result: [elite_count]usize = undefined;
        var selected: [population_size]bool = @splat(false);

        for (0..elite_count) |rank| {
            var found = false;
            var best_index: usize = 0;
            var best_fitness: u64 = 0;

            for (self.agents, 0..) |agent, i| {
                if (selected[i]) continue;

                if (!found or agent.fitness > best_fitness) {
                    found = true;
                    best_index = i;
                    best_fitness = agent.fitness;
                }
            }

            std.debug.assert(found);
            result[rank] = best_index;
            selected[best_index] = true;
        }

        return result;
    }

    fn currentStats(self: *const Simulation) GenerationStats {
        var total_fitness: u64 = 0;
        var total_foods: u64 = 0;
        var total_clears: u64 = 0;

        var best_fitness: u64 = 0;
        var best_index: usize = 0;
        var best_foods: u64 = 0;
        var best_steps: u64 = 0;

        for (self.agents, 0..) |agent, i| {
            const live_foods =
                agent.total_foods +
                if (!agent.done) agent.game.foods else 0;

            const live_steps =
                agent.total_steps +
                if (!agent.done)
                    @as(u64, @intCast(agent.game.ticks))
                else
                    0;

            total_fitness += agent.fitness;
            total_foods += live_foods;
            total_clears += agent.clears;

            if (agent.fitness > best_fitness) {
                best_fitness = agent.fitness;
                best_index = i;
            }

            best_foods = @max(best_foods, live_foods);
            best_steps = @max(best_steps, live_steps);
        }

        const count = @as(f64, @floatFromInt(population_size));

        return .{
            .generation = self.generation,
            .global_ticks = self.global_ticks,
            .best_fitness = best_fitness,
            .best_index = best_index,
            .average_fitness = @as(f64, @floatFromInt(total_fitness)) / count,
            .best_foods = best_foods,
            .average_foods = @as(f64, @floatFromInt(total_foods)) / count,
            .best_steps = best_steps,
            .total_clears = total_clears,
        };
    }

    fn appendStats(
        self: *Simulation,
        stats: GenerationStats,
    ) void {
        if (self.stats_len == self.stats_log.len) {
            const new_capacity = @max(self.stats_log.len * 2, 1);
            self.stats_log = self.allocator.realloc(
                self.stats_log,
                new_capacity,
            ) catch @panic("out of memory while growing generation history");
        }

        self.stats_log[self.stats_len] = stats;
        self.stats_len += 1;
    }

    fn pushHistory(
        self: *Simulation,
        value: f64,
    ) void {
        if (self.history_len < history_capacity) {
            self.history[self.history_len] = value;
            self.history_len += 1;
            return;
        }

        for (0..history_capacity - 1) |i| {
            self.history[i] = self.history[i + 1];
        }
        self.history[history_capacity - 1] = value;
    }
};

const replay_speed_steps = [_]usize{
    1,
    16,
    256,
    4096,
    65536,
    1048576,
};

const ReplayPlayer = struct {
    log: *const ReplayLog,
    game: SnakeGame,
    cursor: usize,
    segment_index: usize,
    action_index: usize,
    speed_index: usize,
    playing: bool,

    fn init(log: *const ReplayLog) ReplayPlayer {
        var player = ReplayPlayer{
            .log = log,
            .game = SnakeGame.init(0),
            .cursor = 0,
            .segment_index = 0,
            .action_index = 0,
            .speed_index = 0,
            .playing = false,
        };
        player.seek(0);
        return player;
    }

    fn restart(self: *ReplayPlayer) void {
        self.seek(0);
        self.playing = true;
    }

    fn seekPercent(self: *ReplayPlayer, percent: usize) void {
        const clamped = @min(percent, 100);
        const target = self.log.totalActions() * clamped / 100;
        self.seek(target);
    }

    fn seek(self: *ReplayPlayer, target: usize) void {
        const clamped = @min(target, self.log.totalActions());
        self.cursor = clamped;

        if (self.log.segment_count == 0) {
            self.game = SnakeGame.init(0);
            self.segment_index = 0;
            self.action_index = 0;
            return;
        }

        var remaining = clamped;

        for (
            self.log.segments[0..self.log.segment_count],
            0..,
        ) |segment, segment_index| {
            if (remaining <= segment.len) {
                self.segment_index = segment_index;
                self.action_index = remaining;
                self.game = SnakeGame.init(segment.seed);

                for (0..remaining) |offset| {
                    _ = self.game.step(
                        self.log.actions[segment.start + offset],
                    );
                }
                return;
            }

            remaining -= segment.len;
        }

        const last_index = self.log.segment_count - 1;
        const last = self.log.segments[last_index];
        self.segment_index = last_index;
        self.action_index = last.len;
        self.game = SnakeGame.init(last.seed);

        for (0..last.len) |offset| {
            _ = self.game.step(self.log.actions[last.start + offset]);
        }
    }

    fn advance(self: *ReplayPlayer, steps: usize) void {
        var remaining = steps;

        while (remaining > 0 and
            self.cursor < self.log.totalActions())
        {
            if (self.segment_index >= self.log.segment_count) break;

            const segment = self.log.segments[self.segment_index];
            if (self.action_index >= segment.len) {
                self.segment_index += 1;
                self.action_index = 0;

                if (self.segment_index < self.log.segment_count) {
                    self.game = SnakeGame.init(
                        self.log.segments[self.segment_index].seed,
                    );
                }
                continue;
            }

            _ = self.game.step(
                self.log.actions[segment.start + self.action_index],
            );
            self.action_index += 1;
            self.cursor += 1;
            remaining -= 1;
        }

        if (self.cursor >= self.log.totalActions()) {
            self.playing = false;
        }
    }

    fn stepBackward(self: *ReplayPlayer) void {
        if (self.cursor == 0) {
            self.playing = false;
            return;
        }

        self.seek(self.cursor - 1);
        self.playing = false;
    }

    fn stepForward(self: *ReplayPlayer) void {
        self.advance(1);
        self.playing = false;
    }

    fn adjustSpeed(self: *ReplayPlayer, delta: i8) void {
        if (delta < 0) {
            if (self.speed_index != 0) self.speed_index -= 1;
        } else if (delta > 0) {
            if (self.speed_index + 1 < replay_speed_steps.len) {
                self.speed_index += 1;
            }
        }
    }

    fn ticksPerFrame(self: *const ReplayPlayer) usize {
        return replay_speed_steps[self.speed_index];
    }

    fn delayMs(self: *const ReplayPlayer) i64 {
        return if (self.speed_index == 0) 25 else 0;
    }

    fn progressPercent(self: *const ReplayPlayer) usize {
        const total = self.log.totalActions();
        if (total == 0) return 0;
        return self.cursor * 100 / total;
    }

    fn generation(self: *const ReplayPlayer) usize {
        if (self.log.segment_count == 0) return 0;
        return self.log.segments[
            @min(self.segment_index, self.log.segment_count - 1)
        ].generation;
    }

    fn nextActionName(self: *const ReplayPlayer) []const u8 {
        var segment_index = self.segment_index;
        var action_index = self.action_index;

        while (segment_index < self.log.segment_count) {
            const segment = self.log.segments[segment_index];
            if (action_index < segment.len) {
                return self.log.actions[
                    segment.start + action_index
                ].name();
            }

            segment_index += 1;
            action_index = 0;
        }

        return "END";
    }
};

test "replay log compacts persisted generations" {
    var actions: [4]RelativeAction = undefined;
    var segments: [3]ReplaySegment = undefined;
    var log = ReplayLog.init(actions[0..], segments[0..]);

    log.beginSegment(0, 0, 0x1111);
    log.append(.left);
    log.append(.straight);

    log.beginSegment(1, 0, 0x2222);
    log.append(.right);

    log.persisted_segment_count = 1;
    log.discardPersisted();

    try std.testing.expectEqual(@as(usize, 1), log.segment_count);
    try std.testing.expectEqual(@as(usize, 1), log.action_count);
    try std.testing.expectEqual(@as(usize, 0), log.persisted_segment_count);
    try std.testing.expectEqual(@as(usize, 0), log.segments[0].start);
    try std.testing.expectEqual(@as(usize, 1), log.segments[0].generation);
    try std.testing.expectEqual(RelativeAction.right, log.actions[0]);
}

test "replay player seeks across recorded segments" {
    var actions: [3]RelativeAction = undefined;
    var segments: [2]ReplaySegment = undefined;
    var log = ReplayLog.init(actions[0..], segments[0..]);
    log.beginSegment(0, 0, 0x1111);
    log.append(.straight);
    log.append(.left);
    log.beginSegment(0, 1, 0x2222);
    log.append(.right);

    var player = ReplayPlayer.init(&log);
    player.restart();
    player.advance(2);

    try std.testing.expectEqual(@as(usize, 2), player.cursor);
    try std.testing.expectEqual(@as(usize, 0), player.segment_index);
    try std.testing.expectEqual(@as(usize, 2), player.action_index);

    player.advance(1);
    try std.testing.expectEqual(@as(usize, 3), player.cursor);
    try std.testing.expectEqual(@as(usize, 1), player.segment_index);
    try std.testing.expectEqual(@as(usize, 1), player.action_index);

    player.seekPercent(50);
    try std.testing.expectEqual(@as(usize, 1), player.cursor);
    try std.testing.expectEqual(@as(usize, 0), player.segment_index);
    try std.testing.expectEqual(@as(usize, 1), player.action_index);
}

// ============================================================================
// NETWORK INPUT / OUTPUT
// ============================================================================

const RaySense = struct {
    wall_proximity: f32,
    body_proximity: f32,
};

fn makeInput(game: *const SnakeGame) [input_count]i8 {
    var result: [input_count]i8 = @splat(0);

    // World-space order: N, NE, E, SE, S, SW, W, NW. The action remains
    // body-relative, so the network must combine these rays with the heading.
    const ray_deltas = [_]Pos{
        .{ .x = 0, .y = -1 },
        .{ .x = 1, .y = -1 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 1 },
        .{ .x = -1, .y = 1 },
        .{ .x = -1, .y = 0 },
        .{ .x = -1, .y = -1 },
    };
    comptime std.debug.assert(ray_deltas.len == ray_count);

    for (ray_deltas, 0..) |delta, ray_index| {
        const sense = senseRay(game, delta);
        const base = ray_index * ray_channel_count;

        result[base + 0] = quantizeZeroOne(sense.wall_proximity);
        result[base + 1] = quantizeZeroOne(sense.body_proximity);
    }

    const head = game.head();
    const direction = game.direction.delta();
    const max_x: f32 = @floatFromInt(board_width - 1);
    const max_y: f32 = @floatFromInt(board_height - 1);

    // Positions are kept separate and in board coordinates. Computing the food
    // delta and rotating it into the snake's frame is now network work.
    result[head_x_input] = quantizeZeroOne(
        @as(f32, @floatFromInt(head.x)) / max_x,
    );
    result[head_y_input] = quantizeZeroOne(
        @as(f32, @floatFromInt(head.y)) / max_y,
    );
    result[food_x_input] = quantizeZeroOne(
        @as(f32, @floatFromInt(game.food.x)) / max_x,
    );
    result[food_y_input] = quantizeZeroOne(
        @as(f32, @floatFromInt(game.food.y)) / max_y,
    );

    result[direction_x_input] = quantizeUnit(
        @as(f32, @floatFromInt(direction.x)),
    );
    result[direction_y_input] = quantizeUnit(
        @as(f32, @floatFromInt(direction.y)),
    );

    result[hunger_input] = quantizeZeroOne(
        @as(f32, @floatFromInt(game.steps_since_food)) /
            @as(f32, @floatFromInt(game.starvationBudget())),
    );
    result[length_input] = quantizeZeroOne(
        @as(f32, @floatFromInt(game.length)) /
            @as(f32, @floatFromInt(board_cells)),
    );

    // Explicit affine offset instead of BitLinear bias.
    result[constant_input] = 127;

    return result;
}

fn senseRay(game: *const SnakeGame, delta: Pos) RaySense {
    std.debug.assert(delta.x != 0 or delta.y != 0);

    var pos = game.head();
    var distance: usize = 0;
    var body_proximity: f32 = 0.0;

    while (true) {
        distance += 1;
        pos.x += delta.x;
        pos.y += delta.y;

        const inv_distance = 1.0 / @as(f32, @floatFromInt(distance));

        if (!insideBoard(pos)) {
            return .{
                .wall_proximity = inv_distance,
                .body_proximity = body_proximity,
            };
        }

        if (body_proximity == 0.0 and game.contains(pos)) {
            body_proximity = inv_distance;
        }
    }
}

fn quantizeUnit(value: f32) i8 {
    const x = std.math.clamp(value, -1.0, 1.0);
    const q: i32 = @intFromFloat(@round(x * 127.0));
    return @intCast(std.math.clamp(q, -127, 127));
}

fn quantizeZeroOne(value: f32) i8 {
    const x = std.math.clamp(value, 0.0, 1.0);
    const q: i32 = @intFromFloat(@round(x * 127.0));
    return @intCast(std.math.clamp(q, 0, 127));
}

test "makeInput keeps obstacle rays in world frame" {
    var game = SnakeGame.init(0x1234_5678_9abc_def0);
    game.length = 3;
    game.snake[0] = .{ .x = 10, .y = 8 };
    game.snake[1] = .{ .x = 9, .y = 8 };
    game.snake[2] = .{ .x = 8, .y = 8 };
    game.food = .{ .x = 20, .y = 10 };
    game.direction = .righ;
    game.steps_since_food = 0;

    const facing_right = makeInput(&game);

    game.direction = .up;
    const facing_up = makeInput(&game);

    try std.testing.expectEqualSlices(
        i8,
        facing_right[0..ray_input_count],
        facing_up[0..ray_input_count],
    );
    try std.testing.expectEqual(@as(i8, 127), facing_right[direction_x_input]);
    try std.testing.expectEqual(@as(i8, 0), facing_right[direction_y_input]);
    try std.testing.expectEqual(@as(i8, 0), facing_up[direction_x_input]);
    try std.testing.expectEqual(@as(i8, -127), facing_up[direction_y_input]);

    try std.testing.expectEqual(
        quantizeZeroOne(10.0 / @as(f32, board_width - 1)),
        facing_right[head_x_input],
    );
    try std.testing.expectEqual(
        quantizeZeroOne(8.0 / @as(f32, board_height - 1)),
        facing_right[head_y_input],
    );
    try std.testing.expectEqual(
        quantizeZeroOne(20.0 / @as(f32, board_width - 1)),
        facing_right[food_x_input],
    );
    try std.testing.expectEqual(
        quantizeZeroOne(10.0 / @as(f32, board_height - 1)),
        facing_right[food_y_input],
    );
    try std.testing.expectEqual(@as(i8, 127), facing_right[constant_input]);
}

fn chooseAction(output: []const i8) RelativeAction {
    std.debug.assert(output.len >= 3);

    // Prefer STRAIGHT on exact ties. This makes an all-zero newborn controller
    // less pathological than always turning left.
    var action: RelativeAction = .straight;
    var best = output[1];

    if (output[0] > best) {
        best = output[0];
        action = .left;
    }

    if (output[2] > best) {
        action = .right;
    }

    return action;
}

const EvalResult = struct {
    foods: u64,
    steps: u64,
    cleared: bool,
};

const EvaluationSummary = struct {
    average_foods_per_episode: f64,
    best_foods: u64,
    average_steps: f64,
    clears: u64,
};

fn evaluationSeed(index: usize) u64 {
    return splitMix64(
        evaluation_seed_namespace +% @as(u64, @intCast(index)),
    );
}

fn evaluateOne(
    brain: *Individual,
    seed: u64,
    buffer: *Individual.PerThreadBuffer,
) EvalResult {
    var game = SnakeGame.init(seed);

    while (game.status == .active) {
        const input = makeInput(&game);

        _ = brain.forward(
            &input,
            input_gain,
            buffer,
        );

        const action = chooseAction(brain.out);
        _ = game.step(action);
    }

    return .{
        .foods = game.foods,
        .steps = @intCast(game.ticks),
        .cleared = game.status == .cleared,
    };
}

fn evaluateChampion(
    brain: *Individual,
    buffer: *Individual.PerThreadBuffer,
) EvaluationSummary {
    var total_foods: u64 = 0;
    var total_steps: u64 = 0;
    var best_foods: u64 = 0;
    var clears: u64 = 0;

    for (0..evaluation_episode_count) |i| {
        const result = evaluateOne(
            brain,
            evaluationSeed(i),
            buffer,
        );

        total_foods += result.foods;
        total_steps += result.steps;
        best_foods = @max(best_foods, result.foods);

        if (result.cleared) {
            clears += 1;
        }
    }

    const count: f64 = @floatFromInt(evaluation_episode_count);

    return .{
        .average_foods_per_episode = @as(f64, @floatFromInt(total_foods)) / count,
        .best_foods = best_foods,
        .average_steps = @as(f64, @floatFromInt(total_steps)) / count,
        .clears = clears,
    };
}

fn foodPerEpisode(average_foods_per_genome: f64) f64 {
    return average_foods_per_genome /
        @as(f64, @floatFromInt(episode_count));
}

fn evaluateRandomBaselineRange(
    brains: []Individual,
    buffer: *Individual.PerThreadBuffer,
    begin: usize,
    end: usize,
    result: *EvaluationSummary,
) void {
    std.debug.assert(begin <= end);
    std.debug.assert(end <= brains.len);

    var average_foods_sum: f64 = 0.0;
    var average_steps_sum: f64 = 0.0;
    var best_foods: u64 = 0;
    var clears: u64 = 0;

    for (brains[begin..end]) |*brain| {
        const summary = evaluateChampion(brain, buffer);
        average_foods_sum += summary.average_foods_per_episode;
        average_steps_sum += summary.average_steps;
        best_foods = @max(best_foods, summary.best_foods);
        clears += summary.clears;
    }

    const count: f64 = @floatFromInt(end - begin);

    result.* = .{
        .average_foods_per_episode = average_foods_sum / count,
        .best_foods = best_foods,
        .average_steps = average_steps_sum / count,
        .clears = clears,
    };
}

fn evaluateRandomBaseline(
    brains: []Individual,
    buffers: []Individual.PerThreadBuffer,
    worker_count: usize,
    io: std.Io,
) !EvaluationSummary {
    std.debug.assert(brains.len >= random_baseline_count);
    std.debug.assert(buffers.len >= worker_count);
    std.debug.assert(worker_count != 0);

    var partials: [population_size]EvaluationSummary = undefined;
    var group: std.Io.Group = .init;
    defer group.cancel(io);

    const chunk_size =
        (random_baseline_count + worker_count - 1) / worker_count;
    var worker_used: usize = 0;

    for (0..worker_count) |worker_index| {
        const begin = worker_index * chunk_size;
        if (begin >= random_baseline_count) break;
        const end = @min(begin + chunk_size, random_baseline_count);

        group.concurrent(
            io,
            evaluateRandomBaselineRange,
            .{
                brains,
                &buffers[worker_index],
                begin,
                end,
                &partials[worker_index],
            },
        ) catch {
            evaluateRandomBaselineRange(
                brains,
                &buffers[worker_index],
                begin,
                end,
                &partials[worker_index],
            );
        };
        worker_used += 1;
    }

    try group.await(io);

    var average_foods_sum: f64 = 0.0;
    var average_steps_sum: f64 = 0.0;
    var best_foods: u64 = 0;
    var clears: u64 = 0;

    for (partials[0..worker_used], 0..) |partial, worker_index| {
        const begin = worker_index * chunk_size;
        const end = @min(begin + chunk_size, random_baseline_count);
        const network_count: f64 = @floatFromInt(end - begin);

        average_foods_sum +=
            partial.average_foods_per_episode * network_count;
        average_steps_sum += partial.average_steps * network_count;
        best_foods = @max(best_foods, partial.best_foods);
        clears += partial.clears;
    }

    const count: f64 = @floatFromInt(random_baseline_count);

    return .{
        .average_foods_per_episode = average_foods_sum / count,
        .best_foods = best_foods,
        .average_steps = average_steps_sum / count,
        .clears = clears,
    };
}

fn realOutput(value: i8, out_gain: f32) f32 {
    return @as(f32, @floatFromInt(value)) * out_gain;
}

// ============================================================================
// WORLD HELPERS
// ============================================================================

fn insideBoard(pos: Pos) bool {
    return pos.x >= 0 and
        pos.y >= 0 and
        pos.x < board_width and
        pos.y < board_height;
}

fn manhattanDistance(a: Pos, b: Pos) i32 {
    const dx = @abs(@as(i32, a.x) - @as(i32, b.x));
    const dy = @abs(@as(i32, a.y) - @as(i32, b.y));
    return @intCast(dx + dy);
}

fn nextRandom(state: *u64) u64 {
    // xorshift64*; state must be nonzero.
    var x = state.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.* = x;
    return x *% 0x2545_f491_4f6c_dd1d;
}

fn splitMix64(seed: u64) u64 {
    var z = seed +% 0x9e37_79b9_7f4a_7c15;
    z = (z ^ (z >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    z = (z ^ (z >> 27)) *% 0x94d0_49bb_1331_11eb;
    return z ^ (z >> 31);
}

// ============================================================================
// POPULATION HELPERS
// ============================================================================

fn allocPopulation(
    allocator: std.mem.Allocator,
    random: std.Random,
    layer_settings: []const Individual.LayerSetting,
    count: usize,
    comptime init_method: Individual.InitMethods,
) ![]Individual {
    const population = try allocator.alloc(
        Individual,
        count,
    );
    errdefer allocator.free(population);

    var initialized: usize = 0;
    errdefer {
        for (population[0..initialized]) |*individual| {
            individual.deinit(allocator);
        }
    }

    for (population) |*individual| {
        individual.* = try Individual.init(
            allocator,
            random,
            layer_settings,
            init_method,
            false,
        );
        initialized += 1;
    }

    return population;
}

fn freePopulation(
    allocator: std.mem.Allocator,
    population: []Individual,
) void {
    for (population) |*individual| {
        individual.deinit(allocator);
    }
    allocator.free(population);
}

fn copyGenome(
    src: *const Individual,
    dst: *Individual,
) void {
    std.debug.assert(src.layers.len == dst.layers.len);
    std.debug.assert(src.out.len == dst.out.len);

    for (src.layers, dst.layers) |src_layer, *dst_layer| {
        std.debug.assert(src_layer.rows == dst_layer.rows);
        std.debug.assert(src_layer.cols == dst_layer.cols);
        std.debug.assert(src_layer.weights.len == dst_layer.weights.len);
        std.debug.assert(src_layer.biases.len == dst_layer.biases.len);

        @memcpy(dst_layer.weights, src_layer.weights);
        if (dst_layer.biases.len != 0) {
            @memcpy(dst_layer.biases, src_layer.biases);
        }

        dst_layer.weights_gain = src_layer.weights_gain;
    }

    dst.activation_pfn_index = src.activation_pfn_index;
    dst.out_gain = 1.0;
    dst.fitness = 0;
    @memset(dst.out, 0);
}

// ============================================================================
// CHECKPOINT SAVE / LOAD
// ============================================================================

const CheckpointEncoder = struct {
    buffer: []u8,
    pos: usize = 0,

    fn putBytes(self: *CheckpointEncoder, bytes: []const u8) void {
        std.debug.assert(self.pos + bytes.len <= self.buffer.len);
        @memcpy(self.buffer[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }

    fn putU64(self: *CheckpointEncoder, value: u64) void {
        std.debug.assert(self.pos + 8 <= self.buffer.len);
        inline for (0..8) |i| {
            self.buffer[self.pos + i] = @truncate(value >> (i * 8));
        }
        self.pos += 8;
    }

    fn putF32(self: *CheckpointEncoder, value: f32) void {
        const bits: u32 = @bitCast(value);
        self.putU64(@as(u64, bits));
    }

    fn putF64(self: *CheckpointEncoder, value: f64) void {
        self.putU64(@bitCast(value));
    }
};

const CheckpointDecoder = struct {
    buffer: []const u8,
    pos: usize = 0,

    fn takeBytes(self: *CheckpointDecoder, out: []u8) !void {
        if (self.pos + out.len > self.buffer.len) {
            return error.TruncatedCheckpoint;
        }
        @memcpy(out, self.buffer[self.pos..][0..out.len]);
        self.pos += out.len;
    }

    fn takeU64(self: *CheckpointDecoder) !u64 {
        if (self.pos + 8 > self.buffer.len) {
            return error.TruncatedCheckpoint;
        }

        var result: u64 = 0;
        inline for (0..8) |i| {
            result |= @as(u64, self.buffer[self.pos + i]) << (i * 8);
        }
        self.pos += 8;
        return result;
    }

    fn takeF32(self: *CheckpointDecoder) !f32 {
        const bits64 = try self.takeU64();
        if (bits64 > std.math.maxInt(u32)) {
            return error.BadCheckpoint;
        }
        const bits: u32 = @intCast(bits64);
        return @bitCast(bits);
    }

    fn takeF64(self: *CheckpointDecoder) !f64 {
        return @bitCast(try self.takeU64());
    }
};

const replay_file_header_size = replay_file_magic.len + (5 * 8);
const replay_record_header_size = replay_record_magic.len + (4 * 8);

fn makeReplayFileHeader() [replay_file_header_size]u8 {
    var data: [replay_file_header_size]u8 = undefined;
    var enc = CheckpointEncoder{ .buffer = &data };

    enc.putBytes(replay_file_magic);
    enc.putU64(replay_file_version);
    enc.putU64(board_width);
    enc.putU64(board_height);
    enc.putU64(episode_count);
    enc.putU64(1); // RelativeAction is encoded as one byte: 0, 1, or 2.

    std.debug.assert(enc.pos == data.len);
    return data;
}

fn validateReplayFileHeader(data: []const u8) !void {
    if (data.len < replay_file_header_size) {
        return error.TruncatedReplayFile;
    }

    var dec = CheckpointDecoder{
        .buffer = data[0..replay_file_header_size],
    };
    var magic: [replay_file_magic.len]u8 = undefined;
    try dec.takeBytes(&magic);

    if (!std.mem.eql(u8, &magic, replay_file_magic)) {
        return error.BadReplayFileMagic;
    }
    if (try dec.takeU64() != replay_file_version) {
        return error.UnsupportedReplayFileVersion;
    }
    if (try dec.takeU64() != board_width or
        try dec.takeU64() != board_height or
        try dec.takeU64() != episode_count or
        try dec.takeU64() != 1)
    {
        return error.ReplayConfigurationMismatch;
    }
}

fn openReplayAppendFile(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().openFile(
        io,
        path,
        .{
            .mode = .read_write,
            .allow_directory = false,
        },
    ) catch |err| switch (err) {
        error.FileNotFound => std.Io.Dir.cwd().createFile(
            io,
            path,
            .{
                .read = true,
                .truncate = false,
            },
        ),
        else => |e| return e,
    };
}

fn appendReplayFile(
    log: *ReplayLog,
    io: std.Io,
    path: []const u8,
    end_segment_count: usize,
) !void {
    const end = @min(end_segment_count, log.segment_count);
    if (end <= log.persisted_segment_count) return;

    var file = try openReplayAppendFile(io, path);
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > std.math.maxInt(usize)) {
        return error.ReplayFileTooLarge;
    }

    var writer = file.writer(io, &.{});

    if (stat.size == 0) {
        const header = makeReplayFileHeader();
        try writer.interface.writeAll(&header);
    } else {
        if (stat.size < replay_file_header_size) {
            return error.TruncatedReplayFile;
        }

        var header: [replay_file_header_size]u8 = undefined;
        const read = try file.readPositionalAll(io, &header, 0);
        if (read != header.len) return error.TruncatedReplayFile;
        try validateReplayFileHeader(&header);
        try writer.seekTo(stat.size);
    }

    for (log.segments[log.persisted_segment_count..end]) |segment| {
        if (segment.len == 0) continue;

        var record_header: [replay_record_header_size]u8 = undefined;
        var enc = CheckpointEncoder{ .buffer = &record_header };
        enc.putBytes(replay_record_magic);
        enc.putU64(@intCast(segment.generation));
        enc.putU64(@intCast(segment.episode_index));
        enc.putU64(segment.seed);
        enc.putU64(@intCast(segment.len));
        std.debug.assert(enc.pos == record_header.len);
        try writer.interface.writeAll(&record_header);

        var action_bytes: [4096]u8 = undefined;
        var written: usize = 0;
        while (written < segment.len) {
            const count = @min(
                action_bytes.len,
                segment.len - written,
            );

            for (0..count) |i| {
                action_bytes[i] = @intCast(@intFromEnum(
                    log.actions[segment.start + written + i],
                ));
            }

            try writer.interface.writeAll(action_bytes[0..count]);
            written += count;
        }
    }

    try writer.end();
    log.persisted_segment_count = end;
}

fn appendCompletedReplay(
    sim: *Simulation,
    io: std.Io,
) !void {
    var end = sim.replay_log.persisted_segment_count;

    while (end < sim.replay_log.segment_count and
        sim.replay_log.segments[end].generation < sim.generation)
    {
        end += 1;
    }

    try appendReplayFile(&sim.replay_log, io, replay_file_path, end);
    sim.replay_log.discardPersisted();

    // Normally resetAgents() already created the current generation's first
    // segment before we compact the completed generation. If recording was
    // disabled by an unexpected capacity exhaustion, begin it here after the
    // old data has been freed so future generations keep recording.
    if (sim.replay_log.segment_count == 0) {
        sim.replay_log.beginSegment(
            sim.generation,
            sim.agents[0].episode_index,
            sim.episode_seeds[sim.agents[0].episode_index],
        );
    }
}

const ReplayFileShape = struct {
    segment_count: usize,
    action_count: usize,
};

fn inspectReplayFile(data: []const u8) !ReplayFileShape {
    try validateReplayFileHeader(data);

    var dec = CheckpointDecoder{ .buffer = data };
    dec.pos = replay_file_header_size;

    var segment_count: usize = 0;
    var action_count: usize = 0;

    while (dec.pos < data.len) {
        if (data.len - dec.pos < replay_record_header_size) {
            return error.TruncatedReplayFile;
        }

        var record_magic: [replay_record_magic.len]u8 = undefined;
        try dec.takeBytes(&record_magic);
        if (!std.mem.eql(u8, &record_magic, replay_record_magic)) {
            return error.BadReplayRecord;
        }

        const generation_u64 = try dec.takeU64();
        const episode_index_u64 = try dec.takeU64();
        _ = try dec.takeU64(); // seed
        const segment_action_count_u64 = try dec.takeU64();

        if (generation_u64 > std.math.maxInt(usize) or
            episode_index_u64 >= episode_count or
            segment_action_count_u64 > std.math.maxInt(usize))
        {
            return error.BadReplayRecord;
        }

        const segment_action_count: usize =
            @intCast(segment_action_count_u64);

        if (segment_action_count > data.len - dec.pos) {
            return error.TruncatedReplayFile;
        }

        const action_end = dec.pos + segment_action_count;
        for (data[dec.pos..action_end]) |action_byte| {
            if (action_byte > @intFromEnum(RelativeAction.right)) {
                return error.BadReplayRecord;
            }
        }
        dec.pos = action_end;

        if (segment_count == std.math.maxInt(usize)) {
            return error.ReplayTooLong;
        }
        segment_count += 1;

        if (segment_action_count > std.math.maxInt(usize) - action_count) {
            return error.ReplayTooLong;
        }
        action_count += segment_action_count;
    }

    return .{
        .segment_count = segment_count,
        .action_count = action_count,
    };
}

fn loadReplayFile(
    log: *ReplayLog,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    var file = std.Io.Dir.cwd().openFile(
        io,
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return error.ReplayFileNotFound,
        else => |e| return e,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size == 0 or stat.size > std.math.maxInt(usize)) {
        return error.BadReplayFile;
    }

    const data = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(data);

    var reader = file.reader(io, &.{});
    reader.interface.readSliceAll(data) catch |err| switch (err) {
        error.EndOfStream => return error.TruncatedReplayFile,
        error.ReadFailed => return reader.err orelse error.BadReplayFile,
    };

    const shape = try inspectReplayFile(data);

    const replay_actions = try allocator.alloc(
        RelativeAction,
        shape.action_count,
    );
    errdefer allocator.free(replay_actions);

    const replay_segments = try allocator.alloc(
        ReplaySegment,
        shape.segment_count,
    );
    errdefer allocator.free(replay_segments);

    var loaded = ReplayLog.init(
        replay_actions,
        replay_segments,
    );

    var dec = CheckpointDecoder{ .buffer = data };
    dec.pos = replay_file_header_size;

    while (dec.pos < data.len) {
        var record_magic: [replay_record_magic.len]u8 = undefined;
        try dec.takeBytes(&record_magic);
        std.debug.assert(
            std.mem.eql(u8, &record_magic, replay_record_magic),
        );

        const generation: usize = @intCast(try dec.takeU64());
        const episode_index: usize = @intCast(try dec.takeU64());
        const seed = try dec.takeU64();
        const segment_action_count: usize =
            @intCast(try dec.takeU64());

        const segment_index = loaded.segment_count;
        loaded.segments[segment_index] = .{
            .generation = generation,
            .episode_index = episode_index,
            .seed = seed,
            .start = loaded.action_count,
            .len = segment_action_count,
        };
        loaded.segment_count += 1;

        for (0..segment_action_count) |_| {
            var action_byte: [1]u8 = undefined;
            try dec.takeBytes(&action_byte);
            loaded.actions[loaded.action_count] =
                @enumFromInt(action_byte[0]);
            loaded.action_count += 1;
        }
    }

    std.debug.assert(loaded.segment_count == shape.segment_count);
    std.debug.assert(loaded.action_count == shape.action_count);

    loaded.persisted_segment_count = loaded.segment_count;
    loaded.recording_enabled = false;

    log.deinit(allocator);
    log.* = loaded;
}

test "replay file round trips segmented actions" {
    const test_path = "snake_replay_roundtrip_test.rep";
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};

    var actions: [3]RelativeAction = undefined;
    var segments: [1]ReplaySegment = undefined;
    var log = ReplayLog.init(actions[0..], segments[0..]);
    log.beginSegment(7, 0, 0x1111);
    log.append(.left);
    log.append(.straight);
    try appendReplayFile(
        &log,
        std.testing.io,
        test_path,
        log.segment_count,
    );

    const loaded_actions = try std.testing.allocator.alloc(
        RelativeAction,
        1,
    );
    const loaded_segments = try std.testing.allocator.alloc(
        ReplaySegment,
        1,
    );
    var loaded = ReplayLog.init(
        loaded_actions,
        loaded_segments,
    );
    defer loaded.deinit(std.testing.allocator);

    try loadReplayFile(
        &loaded,
        std.testing.allocator,
        std.testing.io,
        test_path,
    );

    try std.testing.expectEqual(@as(usize, 1), loaded.segment_count);
    try std.testing.expectEqual(@as(usize, 2), loaded.action_count);
    try std.testing.expectEqual(@as(usize, 7), loaded.segments[0].generation);
    try std.testing.expectEqual(@as(usize, 0), loaded.segments[0].episode_index);
    try std.testing.expectEqual(RelativeAction.left, loaded.actions[0]);
    try std.testing.expectEqual(RelativeAction.straight, loaded.actions[1]);
}

fn checkpointSize(sim: *const Simulation) usize {
    // magic + version + 7 configuration values + generation + stats_len + PRNG state
    var size: usize = checkpoint_magic.len + (14 * 8);

    // GenerationStats is serialized as nine 64-bit words.
    size += sim.stats_len * (9 * 8);

    for (sim.parents) |brain| {
        // activation function index + layer count
        size += 2 * 8;

        for (brain.layers) |layer| {
            const weight_bytes = std.mem.sliceAsBytes(layer.weights);
            const bias_bytes = std.mem.sliceAsBytes(layer.biases);

            // rows, cols, weight byte count, gain bits, bias element count
            size += 5 * 8;
            size += weight_bytes.len;
            size += bias_bytes.len;
        }
    }

    return size;
}

fn saveCheckpointToPath(
    sim: *const Simulation,
    io: std.Io,
    prng: *const std.Random.DefaultPrng,
    path: []const u8,
) !void {
    const size = checkpointSize(sim);
    const data = try sim.allocator.alloc(u8, size);
    defer sim.allocator.free(data);

    var enc = CheckpointEncoder{ .buffer = data };

    enc.putBytes(checkpoint_magic);
    enc.putU64(checkpoint_version);
    enc.putU64(population_size);
    enc.putU64(episode_count);
    enc.putU64(input_count);
    enc.putU64(hidden0);
    enc.putU64(hidden1);
    enc.putU64(output_count);
    enc.putU64(elite_count);
    enc.putU64(sim.generation);
    enc.putU64(sim.stats_len);

    for (prng.s) |state_word| {
        enc.putU64(state_word);
    }

    for (sim.stats_log[0..sim.stats_len]) |stats| {
        enc.putU64(stats.generation);
        enc.putU64(stats.global_ticks);
        enc.putU64(stats.best_fitness);
        enc.putU64(stats.best_index);
        enc.putF64(stats.average_fitness);
        enc.putU64(stats.best_foods);
        enc.putF64(stats.average_foods);
        enc.putU64(stats.best_steps);
        enc.putU64(stats.total_clears);
    }

    for (sim.parents) |brain| {
        enc.putU64(brain.activation_pfn_index);
        enc.putU64(brain.layers.len);

        for (brain.layers) |layer| {
            const weight_bytes = std.mem.sliceAsBytes(layer.weights);
            const bias_bytes = std.mem.sliceAsBytes(layer.biases);

            enc.putU64(layer.rows);
            enc.putU64(layer.cols);
            enc.putU64(weight_bytes.len);
            enc.putF32(layer.weights_gain);
            enc.putU64(layer.biases.len);
            enc.putBytes(weight_bytes);
            enc.putBytes(bias_bytes);
        }
    }

    std.debug.assert(enc.pos == data.len);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
    });
}

fn saveCheckpoint(
    sim: *const Simulation,
    io: std.Io,
    prng: *const std.Random.DefaultPrng,
) !void {
    return saveCheckpointToPath(
        sim,
        io,
        prng,
        checkpoint_path,
    );
}

fn checkpointSnapshotPath(
    buffer: *[checkpoint_snapshot_name_capacity]u8,
    generation: usize,
) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{s}{d}{s}",
        .{
            checkpoint_snapshot_prefix,
            generation,
            checkpoint_snapshot_suffix,
        },
    ) catch unreachable;
}

fn saveCheckpointSnapshot(
    sim: *const Simulation,
    io: std.Io,
    prng: *const std.Random.DefaultPrng,
) !void {
    var path_buffer: [checkpoint_snapshot_name_capacity]u8 = undefined;
    const path = checkpointSnapshotPath(&path_buffer, sim.generation);

    try saveCheckpointToPath(
        sim,
        io,
        prng,
        path,
    );
}

fn ensureStatsCapacity(sim: *Simulation, needed: usize) !void {
    if (needed <= sim.stats_log.len) return;

    var new_capacity = @max(sim.stats_log.len, 1);
    while (new_capacity < needed) {
        new_capacity *= 2;
    }

    sim.stats_log = try sim.allocator.realloc(
        sim.stats_log,
        new_capacity,
    );
}

fn rebuildDerivedCheckpointState(sim: *Simulation) void {
    sim.last_stats = .{};
    sim.best_ever_fitness = 0;
    sim.best_ever_foods = 0;
    sim.history_len = 0;
    sim.history = @splat(0.0);

    for (sim.stats_log[0..sim.stats_len]) |stats| {
        sim.last_stats = stats;
        sim.best_ever_fitness = @max(
            sim.best_ever_fitness,
            stats.best_fitness,
        );
        sim.best_ever_foods = @max(
            sim.best_ever_foods,
            stats.best_foods,
        );
        sim.pushHistory(stats.average_foods);
    }
}

fn loadCheckpointAtPath(
    sim: *Simulation,
    io: std.Io,
    prng: *std.Random.DefaultPrng,
    path: []const u8,
) !bool {
    var file = std.Io.Dir.cwd().openFile(
        io,
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size == 0 or stat.size > std.math.maxInt(usize)) {
        return error.BadCheckpoint;
    }

    const data = try sim.allocator.alloc(u8, @intCast(stat.size));
    defer sim.allocator.free(data);

    var reader = file.reader(io, &.{});
    reader.interface.readSliceAll(data) catch |err| switch (err) {
        error.EndOfStream => return error.TruncatedCheckpoint,
        error.ReadFailed => return reader.err orelse error.BadCheckpoint,
    };

    var dec = CheckpointDecoder{ .buffer = data };

    var magic: [checkpoint_magic.len]u8 = undefined;
    try dec.takeBytes(&magic);
    if (!std.mem.eql(u8, &magic, checkpoint_magic)) {
        return error.BadCheckpointMagic;
    }

    if (try dec.takeU64() != checkpoint_version) {
        return error.UnsupportedCheckpointVersion;
    }
    if (try dec.takeU64() != population_size or
        try dec.takeU64() != episode_count or
        try dec.takeU64() != input_count or
        try dec.takeU64() != hidden0 or
        try dec.takeU64() != hidden1 or
        try dec.takeU64() != output_count or
        try dec.takeU64() != elite_count)
    {
        return error.CheckpointConfigurationMismatch;
    }

    const saved_generation_u64 = try dec.takeU64();
    const saved_stats_len_u64 = try dec.takeU64();
    if (saved_generation_u64 > std.math.maxInt(usize) or
        saved_stats_len_u64 > std.math.maxInt(usize))
    {
        return error.BadCheckpoint;
    }

    const saved_generation: usize = @intCast(saved_generation_u64);
    const saved_stats_len: usize = @intCast(saved_stats_len_u64);

    // A checkpoint always represents the boundary immediately before the
    // generation named by `generation` starts.
    if (saved_generation != saved_stats_len) {
        return error.BadCheckpoint;
    }

    var saved_prng_state: [4]u64 = undefined;
    for (&saved_prng_state) |*state_word| {
        state_word.* = try dec.takeU64();
    }

    try ensureStatsCapacity(sim, saved_stats_len);

    for (sim.stats_log[0..saved_stats_len]) |*stats| {
        const generation_u64 = try dec.takeU64();
        const global_ticks_u64 = try dec.takeU64();
        const best_fitness = try dec.takeU64();
        const best_index_u64 = try dec.takeU64();
        const average_fitness = try dec.takeF64();
        const best_foods = try dec.takeU64();
        const average_foods = try dec.takeF64();
        const best_steps = try dec.takeU64();
        const total_clears = try dec.takeU64();

        if (generation_u64 > std.math.maxInt(usize) or
            global_ticks_u64 > std.math.maxInt(usize) or
            best_index_u64 >= population_size or
            !std.math.isFinite(average_fitness) or
            !std.math.isFinite(average_foods))
        {
            return error.BadCheckpoint;
        }

        stats.* = .{
            .generation = @intCast(generation_u64),
            .global_ticks = @intCast(global_ticks_u64),
            .best_fitness = best_fitness,
            .best_index = @intCast(best_index_u64),
            .average_fitness = average_fitness,
            .best_foods = best_foods,
            .average_foods = average_foods,
            .best_steps = best_steps,
            .total_clears = total_clears,
        };
    }

    for (sim.parents) |*brain| {
        const activation_index_u64 = try dec.takeU64();
        const layer_count_u64 = try dec.takeU64();

        if (activation_index_u64 != 1 or
            layer_count_u64 != brain.layers.len)
        {
            return error.CheckpointConfigurationMismatch;
        }

        brain.activation_pfn_index = 1;

        for (brain.layers) |*layer| {
            const rows = try dec.takeU64();
            const cols = try dec.takeU64();
            const weight_bytes_len = try dec.takeU64();
            const weights_gain = try dec.takeF32();
            const bias_count = try dec.takeU64();

            const weight_bytes = std.mem.sliceAsBytes(layer.weights);
            const bias_bytes = std.mem.sliceAsBytes(layer.biases);

            if (rows != layer.rows or
                cols != layer.cols or
                weight_bytes_len != weight_bytes.len or
                bias_count != layer.biases.len or
                !std.math.isFinite(weights_gain) or
                weights_gain <= 0.0)
            {
                return error.CheckpointConfigurationMismatch;
            }

            try dec.takeBytes(weight_bytes);
            try dec.takeBytes(bias_bytes);
            layer.weights_gain = weights_gain;
        }

        brain.out_gain = 1.0;
        brain.fitness = 0;
        @memset(brain.out, 0);
    }

    if (dec.pos != data.len) {
        return error.BadCheckpoint;
    }

    sim.generation = saved_generation;
    sim.global_ticks = 0;
    sim.stats_len = saved_stats_len;
    rebuildDerivedCheckpointState(sim);

    prng.s = saved_prng_state;

    // Partial episodes are deliberately not persisted. Resume from the clean
    // generation boundary represented by the saved parent population.
    sim.replay_log.reset();
    sim.resetAgents();

    return true;
}

fn loadCheckpoint(
    sim: *Simulation,
    io: std.Io,
    prng: *std.Random.DefaultPrng,
) !bool {
    return loadCheckpointAtPath(
        sim,
        io,
        prng,
        checkpoint_path,
    );
}

const EvaluationCheckpoint = struct {
    generation: usize,
    name: [checkpoint_snapshot_name_capacity]u8,
    name_len: usize,

    fn path(self: *const EvaluationCheckpoint) []const u8 {
        return self.name[0..self.name_len];
    }
};

fn parseCheckpointSnapshotGeneration(name: []const u8) ?usize {
    if (!std.mem.startsWith(u8, name, checkpoint_snapshot_prefix) or
        !std.mem.endsWith(u8, name, checkpoint_snapshot_suffix))
    {
        return null;
    }

    const digits = name[checkpoint_snapshot_prefix.len .. name.len - checkpoint_snapshot_suffix.len];

    if (digits.len == 0) return null;

    for (digits) |digit| {
        if (digit < '0' or digit > '9') return null;
    }

    const generation = std.fmt.parseInt(usize, digits, 10) catch return null;
    return if (generation == 0) null else generation;
}

fn collectEvaluationCheckpoints(
    allocator: std.mem.Allocator,
    io: std.Io,
) ![]EvaluationCheckpoint {
    var checkpoints: std.ArrayList(EvaluationCheckpoint) = .empty;
    errdefer checkpoints.deinit(allocator);

    var dir = try std.Io.Dir.cwd().openDir(
        io,
        ".",
        .{ .iterate = true },
    );
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const generation =
            parseCheckpointSnapshotGeneration(entry.name) orelse continue;

        if (entry.name.len > checkpoint_snapshot_name_capacity) continue;

        var checkpoint = EvaluationCheckpoint{
            .generation = generation,
            .name = undefined,
            .name_len = entry.name.len,
        };
        @memcpy(checkpoint.name[0..entry.name.len], entry.name);

        try checkpoints.append(allocator, checkpoint);
    }

    if (checkpoints.items.len > 1) {
        for (1..checkpoints.items.len) |i| {
            var j = i;
            while (j > 0 and
                checkpoints.items[j - 1].generation >
                    checkpoints.items[j].generation)
            {
                const temp = checkpoints.items[j - 1];
                checkpoints.items[j - 1] = checkpoints.items[j];
                checkpoints.items[j] = temp;
                j -= 1;
            }
        }
    }

    return checkpoints.toOwnedSlice(allocator);
}

fn evaluateSavedCheckpoints(
    sim: *Simulation,
    io: std.Io,
    random: std.Random,
    prng: *std.Random.DefaultPrng,
) !void {
    const checkpoints = try collectEvaluationCheckpoints(
        sim.allocator,
        io,
    );
    defer sim.allocator.free(checkpoints);

    if (checkpoints.len == 0) {
        std.debug.print(
            "[evaluation] no numbered checkpoints matching {s}<generation>{s}\n",
            .{ checkpoint_snapshot_prefix, checkpoint_snapshot_suffix },
        );
        return;
    }

    const champion = &sim.parents[0];
    var buffer = try Individual.PerThreadBuffer.init(
        sim.allocator,
        champion.maxRowColLen(),
        champion.maxElementsLen(),
    );
    defer buffer.deinit(sim.allocator);

    std.debug.print(
        "[evaluation] random baseline: {d} networks x {d} fixed seeds\n",
        .{ random_baseline_count, evaluation_episode_count },
    );
    const baseline = evaluateRandomBaseline(
        sim.parents[0..random_baseline_count],
        sim.eval_buffers,
        sim.worker_count,
        io,
    ) catch |err| return err;

    std.debug.print(
        "\n================ CHECKPOINT EVALUATION ================\n",
        .{},
    );
    std.debug.print(
        "found {d} checkpoints; fixed seeds {d}\n\n",
        .{ checkpoints.len, evaluation_episode_count },
    );
    std.debug.print(
        "random baseline: avg food/episode {d:.3} | best food {d} | avg steps/episode {d:.1} | clears {d}\n\n",
        .{
            baseline.average_foods_per_episode,
            baseline.best_foods,
            baseline.average_steps,
            baseline.clears,
        },
    );
    std.debug.print(
        " generation | avg food/episode | best food | avg steps | clears | checkpoint\n",
        .{},
    );
    std.debug.print(
        "------------+------------------+-----------+-----------+--------+------------\n",
        .{},
    );

    var evaluated_count: usize = 0;

    for (checkpoints) |checkpoint| {
        const loaded = loadCheckpointAtPath(
            sim,
            io,
            prng,
            checkpoint.path(),
        ) catch |err| {
            std.debug.print(
                "[evaluation] skip {s}: {s}\n",
                .{ checkpoint.path(), @errorName(err) },
            );

            const allocator = sim.allocator;
            sim.deinit(allocator);
            sim.* = try Simulation.init(allocator, random);
            continue;
        };

        if (!loaded) {
            std.debug.print(
                "[evaluation] skip {s}: file disappeared\n",
                .{checkpoint.path()},
            );
            continue;
        }

        if (sim.generation != checkpoint.generation) {
            std.debug.print(
                "[evaluation] skip {s}: header generation {d} != filename generation {d}\n",
                .{
                    checkpoint.path(),
                    sim.generation,
                    checkpoint.generation,
                },
            );
            continue;
        }

        const summary = evaluateChampion(
            &sim.parents[0],
            &buffer,
        );

        std.debug.print(
            "{d:>11} | {d:>16.3} | {d:>9} | {d:>9.1} | {d:>6} | {s}\n",
            .{
                sim.generation,
                summary.average_foods_per_episode,
                summary.best_foods,
                summary.average_steps,
                summary.clears,
                checkpoint.path(),
            },
        );
        evaluated_count += 1;
    }

    if (evaluated_count == 0) {
        std.debug.print(
            "[evaluation] no valid numbered checkpoints were evaluated\n",
            .{},
        );
    }
}

// ============================================================================
// RENDERING
// ============================================================================

const cell_width = 2;
const world_draw_width = board_width * cell_width;

fn render(
    console: *WinConsole,
    sim: *const Simulation,
    mode: SpeedMode,
) void {
    var frame = Frame.init();

    const current = sim.currentStats();
    const display_index = sim.displayIndex();
    const best_index = sim.bestIndex();

    const agent = &sim.agents[display_index];
    const brain = &sim.parents[display_index];
    const game = &agent.game;

    const have_output =
        sim.global_ticks != 0 and
        brain.out.len >= 3;

    const q_left: i8 = if (have_output) brain.out[0] else 0;
    const q_straight: i8 = if (have_output) brain.out[1] else 0;
    const q_right: i8 = if (have_output) brain.out[2] else 0;
    const out_gain: f32 = if (have_output) brain.out_gain else 1.0;

    const action =
        if (have_output)
            chooseAction(brain.out)
        else
            RelativeAction.straight;

    frame.write(
        0,
        0,
        "BITMAN SNAKE // evolutionary controller // Win32 console",
        COLOR_CYAN,
    );

    frame.writeFmt(
        0,
        1,
        COLOR_WHITE,
        "generation {d:<5} tick {d:<5} population {d} episodes {d} speed-mode {s}",
        .{
            sim.generation,
            sim.global_ticks,
            population_size,
            episode_count,
            mode.name(),
        },
    );

    frame.writeFmt(
        0,
        2,
        COLOR_WHITE,
        "current: best fitness {d:<9} avg fitness {d:<10.1} best food {d:<4} avg food/genome {d:<6.2} food/episode {d:<6.3} best steps {d}",
        .{
            current.best_fitness,
            current.average_fitness,
            current.best_foods,
            current.average_foods,
            foodPerEpisode(current.average_foods),
            current.best_steps,
        },
    );

    frame.writeFmt(
        0,
        3,
        COLOR_DIM,
        "previous: best fitness {d:<9} avg food/genome {d:<6.2} food/episode {d:<6.3} best food {d:<4} | best-ever food/genome {d}",
        .{
            sim.last_stats.best_fitness,
            sim.last_stats.average_foods,
            foodPerEpisode(sim.last_stats.average_foods),
            sim.last_stats.best_foods,
            sim.best_ever_foods,
        },
    );

    frame.writeFmt(
        0,
        4,
        COLOR_DIM,
        "brain {d}->{d}->{d}->{d} | workers {d} | elite {d} | mutation {d:.3}%",
        .{
            input_count,
            hidden0,
            hidden1,
            output_count,
            sim.worker_count,
            elite_count,
            mutation_chance * 100.0,
        },
    );

    frame.write(
        0,
        5,
        "keys: [1] slow  [2] normal  [3] fast  [4] turbo  [5] WARP  [Q] replay  [Esc] save + quit",
        COLOR_YELLOW,
    );

    const grid_x: usize = 1;
    const grid_y: usize = 7;

    drawWorldBorder(
        &frame,
        grid_x,
        grid_y,
    );

    drawGame(
        &frame,
        game,
        grid_x,
        grid_y,
    );

    const panel_x: usize = 64;

    frame.write(
        panel_x,
        7,
        "VIEWED AGENT",
        COLOR_YELLOW,
    );

    frame.writeFmt(
        panel_x,
        9,
        COLOR_WHITE,
        "index       {d}   best-index {d}",
        .{ display_index, best_index },
    );

    frame.writeFmt(
        panel_x,
        10,
        COLOR_WHITE,
        "episode     {d}/{d}",
        .{ agent.episode_index + 1, episode_count },
    );

    frame.writeFmt(
        panel_x,
        11,
        COLOR_WHITE,
        "status      {s}",
        .{game.status.name()},
    );

    frame.writeFmt(
        panel_x,
        12,
        COLOR_WHITE,
        "fitness     {d}",
        .{agent.fitness},
    );

    frame.writeFmt(
        panel_x,
        13,
        COLOR_WHITE,
        "food(ep)    {d}   total {d}",
        .{ game.foods, agent.total_foods },
    );

    frame.writeFmt(
        panel_x,
        14,
        COLOR_WHITE,
        "length      {d}",
        .{game.length},
    );

    frame.writeFmt(
        panel_x,
        15,
        COLOR_WHITE,
        "ticks       {d}   hungry {d}/{d}",
        .{
            game.ticks,
            game.steps_since_food,
            game.starvationBudget(),
        },
    );

    frame.writeFmt(
        panel_x,
        16,
        COLOR_WHITE,
        "direction   {s}",
        .{game.direction.name()},
    );

    frame.write(
        panel_x,
        18,
        "BRAIN OUTPUT",
        COLOR_CYAN,
    );

    frame.writeFmt(
        panel_x,
        20,
        COLOR_WHITE,
        "q L/S/R     {d:>4} {d:>4} {d:>4}",
        .{ q_left, q_straight, q_right },
    );

    frame.writeFmt(
        panel_x,
        21,
        COLOR_WHITE,
        "out gain    {d:.6}",
        .{out_gain},
    );

    frame.writeFmt(
        panel_x,
        22,
        COLOR_WHITE,
        "real L/S/R  {d:>6.2} {d:>6.2} {d:>6.2}",
        .{
            realOutput(q_left, out_gain),
            realOutput(q_straight, out_gain),
            realOutput(q_right, out_gain),
        },
    );

    frame.writeFmt(
        panel_x,
        23,
        COLOR_YELLOW,
        "action      {s}",
        .{action.name()},
    );

    const input = makeInput(game);

    frame.write(
        panel_x,
        25,
        "INPUT (WORLD FRAME)",
        COLOR_CYAN,
    );

    frame.writeFmt(
        panel_x,
        27,
        COLOR_WHITE,
        "ray N wall/body {d:>4} {d:>4}",
        .{ input[0], input[1] },
    );

    frame.writeFmt(
        panel_x,
        28,
        COLOR_WHITE,
        "head x/y {d:>4} {d:>4}  food x/y {d:>4} {d:>4}",
        .{
            input[head_x_input],
            input[head_y_input],
            input[food_x_input],
            input[food_y_input],
        },
    );

    frame.writeFmt(
        panel_x,
        29,
        COLOR_WHITE,
        "dir x/y {d:>4} {d:>4}  hunger/len {d:>4} {d:>4}",
        .{
            input[direction_x_input],
            input[direction_y_input],
            input[hunger_input],
            input[length_input],
        },
    );

    frame.write(
        panel_x,
        31,
        "AVG FOOD / GENOME",
        COLOR_CYAN,
    );

    drawHistory(
        &frame,
        panel_x,
        33,
        &sim.history,
        sim.history_len,
    );

    console.present(&frame);
}

fn renderReplay(
    console: *WinConsole,
    player: *const ReplayPlayer,
) void {
    var frame = Frame.init();

    const total = player.log.totalActions();
    const percent = player.progressPercent();
    const playback = if (player.playing) "PLAYING" else "PAUSED";
    const recording = if (player.log.truncated)
        "TRUNCATED"
    else if (player.log.recording_enabled)
        "RECORDING"
    else
        "STOPPED";
    const segment = if (player.log.segment_count == 0)
        0
    else
        @min(player.segment_index + 1, player.log.segment_count);

    frame.write(
        0,
        0,
        "BITMAN SNAKE // action replay // parents[0] track",
        COLOR_CYAN,
    );

    frame.writeFmt(
        0,
        1,
        COLOR_WHITE,
        "{s}  generation {d}  actions {d}/{d}  ({d}%)  segment {d}/{d}",
        .{
            playback,
            player.generation(),
            player.cursor,
            total,
            percent,
            segment,
            player.log.segment_count,
        },
    );

    frame.writeFmt(
        0,
        2,
        COLOR_WHITE,
        "speed {d} ticks/frame  next {s}  {s}",
        .{
            player.ticksPerFrame(),
            player.nextActionName(),
            recording,
        },
    );

    const progress_width: usize = 62;
    const filled = if (total == 0)
        0
    else
        percent * progress_width / 100;

    for (0..progress_width) |i| {
        frame.put(
            1 + i,
            4,
            if (i < filled) '#' else '-',
            if (i < filled) COLOR_GREEN else COLOR_DIM,
        );
    }

    frame.write(
        0,
        5,
        "keys: [Space] play/pause  [R] restart  [1-0] seek  [,/.] step  [[/]] speed  [Q] back/quit  [Esc] save + quit",
        COLOR_YELLOW,
    );

    const grid_x: usize = 1;
    const grid_y: usize = 7;
    drawWorldBorder(&frame, grid_x, grid_y);
    drawGame(&frame, &player.game, grid_x, grid_y);

    const panel_x: usize = 64;

    frame.write(
        panel_x,
        7,
        "REPLAY STATE",
        COLOR_YELLOW,
    );

    frame.writeFmt(
        panel_x,
        9,
        COLOR_WHITE,
        "status      {s}",
        .{player.game.status.name()},
    );

    frame.writeFmt(
        panel_x,
        10,
        COLOR_WHITE,
        "food        {d}   length {d}",
        .{ player.game.foods, player.game.length },
    );

    frame.writeFmt(
        panel_x,
        11,
        COLOR_WHITE,
        "ticks       {d}",
        .{player.game.ticks},
    );

    frame.writeFmt(
        panel_x,
        12,
        COLOR_WHITE,
        "direction   {s}",
        .{player.game.direction.name()},
    );

    frame.writeFmt(
        panel_x,
        14,
        COLOR_DIM,
        "track stores actions only; game state is deterministic",
        .{},
    );

    console.present(&frame);
}

fn drawWorldBorder(
    frame: *Frame,
    x: usize,
    y: usize,
) void {
    frame.put(x, y, '+', COLOR_DIM);

    for (0..world_draw_width) |ix| {
        frame.put(
            x + 1 + ix,
            y,
            '-',
            COLOR_DIM,
        );
    }

    frame.put(
        x + world_draw_width + 1,
        y,
        '+',
        COLOR_DIM,
    );

    for (0..board_height) |iy| {
        frame.put(
            x,
            y + 1 + iy,
            '|',
            COLOR_DIM,
        );

        frame.put(
            x + world_draw_width + 1,
            y + 1 + iy,
            '|',
            COLOR_DIM,
        );
    }

    const bottom = y + board_height + 1;

    frame.put(
        x,
        bottom,
        '+',
        COLOR_DIM,
    );

    for (0..world_draw_width) |ix| {
        frame.put(
            x + 1 + ix,
            bottom,
            '-',
            COLOR_DIM,
        );
    }

    frame.put(
        x + world_draw_width + 1,
        bottom,
        '+',
        COLOR_DIM,
    );
}

fn drawGame(
    frame: *Frame,
    game: *const SnakeGame,
    grid_x: usize,
    grid_y: usize,
) void {
    // Food first.
    putCell(
        frame,
        grid_x,
        grid_y,
        game.food,
        "**",
        COLOR_RED,
    );

    // Body tail-to-head so the head always wins overlaps.
    var i = game.length;
    while (i > 1) {
        i -= 1;
        putCell(
            frame,
            grid_x,
            grid_y,
            game.snake[i],
            "oo",
            COLOR_GREEN,
        );
    }

    putCell(
        frame,
        grid_x,
        grid_y,
        game.head(),
        "@@",
        COLOR_YELLOW,
    );
}

fn putCell(
    frame: *Frame,
    grid_x: usize,
    grid_y: usize,
    pos: Pos,
    text: []const u8,
    color: WORD,
) void {
    if (!insideBoard(pos)) return;

    const x =
        grid_x + 1 +
        @as(usize, @intCast(pos.x)) * cell_width;
    const y =
        grid_y + 1 +
        @as(usize, @intCast(pos.y));

    frame.write(
        x,
        y,
        text,
        color,
    );
}

fn drawHistory(
    frame: *Frame,
    x: usize,
    y: usize,
    history: *const [history_capacity]f64,
    history_len: usize,
) void {
    const graph_height: usize = 7;

    if (history_len == 0) {
        frame.write(
            x,
            y + 2,
            "finish generation 0...",
            COLOR_DIM,
        );
        return;
    }

    var max_value: f64 = 1.0;

    for (history[0..history_len]) |value| {
        max_value = @max(max_value, value);
    }

    for (0..history_len) |i| {
        const normalized = std.math.clamp(
            history[i] / max_value,
            0.0,
            1.0,
        );

        const height_f =
            normalized *
            @as(f64, @floatFromInt(graph_height - 1));

        const graph_y =
            graph_height - 1 -
            @as(usize, @intFromFloat(@round(height_f)));

        frame.put(
            x + i,
            y + graph_y,
            '*',
            COLOR_GREEN,
        );
    }

    frame.writeFmt(
        x,
        y + graph_height,
        COLOR_DIM,
        "max avg/genome {d:.2}",
        .{max_value},
    );
}

// ============================================================================
// FULL EVOLUTION GRAPH
// ============================================================================

const final_graph_width = 100;
const final_graph_height = 18;

fn printFoodGraph(sim: *const Simulation) void {
    if (sim.stats_len == 0) return;

    const columns = @min(sim.stats_len, final_graph_width);
    var avg_series: [final_graph_width]f64 = @splat(0.0);
    var best_series: [final_graph_width]f64 = @splat(0.0);

    for (0..columns) |column| {
        const begin = column * sim.stats_len / columns;
        var end = (column + 1) * sim.stats_len / columns;
        if (end <= begin) end = begin + 1;

        var avg_sum: f64 = 0.0;
        var bucket_best: f64 = 0.0;

        for (sim.stats_log[begin..end]) |stats| {
            avg_sum += stats.average_foods;
            bucket_best = @max(
                bucket_best,
                @as(f64, @floatFromInt(stats.best_foods)),
            );
        }

        avg_series[column] =
            avg_sum / @as(f64, @floatFromInt(end - begin));
        best_series[column] = bucket_best;
    }

    var max_value: f64 = 1.0;
    for (best_series[0..columns]) |value| {
        max_value = @max(max_value, value);
    }

    std.debug.print(
        "\n================ EVOLUTION CURVE: FOOD / GENOME ================\n",
        .{},
    );
    std.debug.print(
        "# best food/genome   + avg food/genome   @ overlap   ({d} generations -> {d} columns)\n\n",
        .{ sim.stats_len, columns },
    );

    for (0..final_graph_height) |row| {
        const y_value =
            max_value *
            @as(f64, @floatFromInt(final_graph_height - 1 - row)) /
            @as(f64, @floatFromInt(final_graph_height - 1));

        if (row == 0 or row == final_graph_height / 2 or row + 1 == final_graph_height) {
            std.debug.print("{d:>7.1} |", .{y_value});
        } else {
            std.debug.print("        |", .{});
        }

        for (0..columns) |column| {
            const best_normalized = std.math.clamp(
                best_series[column] / max_value,
                0.0,
                1.0,
            );
            const avg_normalized = std.math.clamp(
                avg_series[column] / max_value,
                0.0,
                1.0,
            );

            const best_row =
                final_graph_height - 1 -
                @as(
                    usize,
                    @intFromFloat(@round(
                        best_normalized *
                            @as(f64, @floatFromInt(final_graph_height - 1)),
                    )),
                );
            const avg_row =
                final_graph_height - 1 -
                @as(
                    usize,
                    @intFromFloat(@round(
                        avg_normalized *
                            @as(f64, @floatFromInt(final_graph_height - 1)),
                    )),
                );

            const ch: u8 = if (row == best_row and row == avg_row)
                '@'
            else if (row == best_row)
                '#'
            else if (row == avg_row)
                '+'
            else
                ' ';

            std.debug.print("{c}", .{ch});
        }

        std.debug.print("\n", .{});
    }

    std.debug.print("        +", .{});
    for (0..columns) |_| {
        std.debug.print("-", .{});
    }
    std.debug.print("\n", .{});

    const first_generation = sim.stats_log[0].generation;
    const last_generation = sim.stats_log[sim.stats_len - 1].generation;
    std.debug.print(
        "         gen {d} -> {d}\n",
        .{ first_generation, last_generation },
    );

    const first_avg = sim.stats_log[0].average_foods;
    const last_avg = sim.stats_log[sim.stats_len - 1].average_foods;

    if (first_avg > 0.0) {
        std.debug.print(
            "avg-food multiplier: x{d:.2}   ({d:.3} -> {d:.3})\n",
            .{ last_avg / first_avg, first_avg, last_avg },
        );
    }

    std.debug.print(
        "=================================================================\n",
        .{},
    );
}

// ============================================================================
// FINAL REPORT
// ============================================================================

fn printFinalReport(sim: *const Simulation) void {
    const current = sim.currentStats();

    std.debug.print(
        "\n\n================ BITMAN SNAKE: EVOLUTION HISTORY ================\n",
        .{},
    );

    std.debug.print(
        "brain {d}->{d}->{d}->{d} | population {d} | episodes/genome {d} (anchors {d})\n",
        .{
            input_count,
            hidden0,
            hidden1,
            output_count,
            population_size,
            episode_count,
            anchor_episode_count,
        },
    );

    std.debug.print(
        "input_gain={d:.8} | 8 absolute wall/body rays | raw position + heading | leakyReLU8 | no bias\n",
        .{input_gain},
    );

    std.debug.print(
        "elitism={d} unchanged | mutation={d:.3}% coeff={d:.3} | no hard tick cap | workers={d}\n",
        .{
            elite_count,
            mutation_chance * 100.0,
            mutation_coeff,
            sim.worker_count,
        },
    );

    std.debug.print(
        "hunger budget={d}+{d}*length | rotating seeds | board clear ends episode\n\n",
        .{ starvation_base, starvation_per_body_cell },
    );

    if (sim.stats_len == 0) {
        std.debug.print("No generation finished before quit.\n", .{});
    } else {
        std.debug.print(
            " gen | best fitness | avg fitness | best food/genome | avg food/genome | food/episode | best steps | clears | ticks\n",
            .{},
        );
        std.debug.print(
            "-----+--------------+-------------+------------------+-----------------+--------------+------------+--------+------\n",
            .{},
        );

        for (sim.stats_log[0..sim.stats_len]) |stats| {
            std.debug.print(
                "{d:>4} | {d:>12} | {d:>11.1} | {d:>16} | {d:>15.2} | {d:>12.3} | {d:>10} | {d:>6} | {d}\n",
                .{
                    stats.generation,
                    stats.best_fitness,
                    stats.average_fitness,
                    stats.best_foods,
                    stats.average_foods,
                    foodPerEpisode(stats.average_foods),
                    stats.best_steps,
                    stats.total_clears,
                    stats.global_ticks,
                },
            );
        }

        const first = sim.stats_log[0];
        const last = sim.stats_log[sim.stats_len - 1];

        std.debug.print(
            "\nfirst avg food/genome {d:.3} ({d:.3}/episode) -> last {d:.3} ({d:.3}/episode)\n",
            .{
                first.average_foods,
                foodPerEpisode(first.average_foods),
                last.average_foods,
                foodPerEpisode(last.average_foods),
            },
        );

        std.debug.print(
            "best-ever fitness {d} | best-ever food/genome {d}\n",
            .{
                sim.best_ever_fitness,
                sim.best_ever_foods,
            },
        );
    }

    std.debug.print(
        "\ncurrent partial gen {d}: best fitness {d}, avg fitness {d:.1}, best food {d}, avg food/genome {d:.2}, food/episode {d:.3}\n",
        .{
            sim.generation,
            current.best_fitness,
            current.average_fitness,
            current.best_foods,
            current.average_foods,
            foodPerEpisode(current.average_foods),
        },
    );

    std.debug.print(
        "=================================================================\n",
        .{},
    );

    printFoodGraph(sim);
}

// ============================================================================
// MAIN
// ============================================================================

pub fn main(
    init: std.process.Init,
) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(
        init.arena.allocator(),
    );

    var mode: SpeedMode = .normal;
    var eval_mode = false;
    var replay_file_mode = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--eval")) {
            eval_mode = true;
        } else if (std.mem.eql(u8, arg, "--replay")) {
            replay_file_mode = true;
        } else if (std.mem.eql(u8, arg, "--slow")) {
            mode = .slow;
        } else if (std.mem.eql(u8, arg, "--fast")) {
            mode = .fast;
        } else if (std.mem.eql(u8, arg, "--turbo")) {
            mode = .turbo;
        } else if (std.mem.eql(u8, arg, "--warp")) {
            mode = .warp;
        }
    }

    const initial_prng_seed: u64 = 0x534e_414b_455f_4249;

    var prng: std.Random.DefaultPrng =
        .init(initial_prng_seed);

    const random = prng.random();

    var sim = try Simulation.init(
        allocator,
        random,
    );
    defer sim.deinit(allocator);

    if (eval_mode and replay_file_mode) {
        std.debug.print(
            "[args] --eval and --replay are mutually exclusive\n",
            .{},
        );
        return;
    }

    if (eval_mode) {
        evaluateSavedCheckpoints(
            &sim,
            io,
            random,
            &prng,
        ) catch |err| {
            std.debug.print(
                "[evaluation] failed: {s}\n",
                .{@errorName(err)},
            );
        };
        return;
    }

    if (replay_file_mode) {
        loadReplayFile(
            &sim.replay_log,
            allocator,
            io,
            replay_file_path,
        ) catch |err| {
            std.debug.print(
                "[replay] failed to load {s}: {s}\n",
                .{ replay_file_path, @errorName(err) },
            );
            return;
        };
    } else {
        const checkpoint_loaded = loadCheckpoint(
            &sim,
            io,
            &prng,
        ) catch |err| blk: {
            std.debug.print(
                "[checkpoint] ignored {s}: {s}\n",
                .{ checkpoint_path, @errorName(err) },
            );

            // loadCheckpoint may have already copied some bytes before discovering
            // corruption. Rebuild a pristine simulation instead of continuing from
            // a half-loaded population.
            sim.deinit(allocator);
            prng = .init(initial_prng_seed);
            sim = try Simulation.init(allocator, random);
            break :blk false;
        };

        if (checkpoint_loaded) {
            std.debug.print(
                "[checkpoint] loaded {s}: resume at generation {d}\n",
                .{ checkpoint_path, sim.generation },
            );
        }
    }

    var console = try WinConsole.init();

    console.begin();
    var console_active = true;

    defer {
        if (console_active) {
            console.end();
        }
    }

    var replay_mode = replay_file_mode;
    var replay_player = ReplayPlayer.init(&sim.replay_log);

    if (replay_mode) {
        replay_player.restart();
        renderReplay(&console, &replay_player);
    } else {
        render(
            &console,
            &sim,
            mode,
        );
    }

    var running = true;

    while (running) {
        const action = console.pollInput();

        if (action.quit) {
            if (!replay_file_mode) {
                saveCheckpoint(&sim, io, &prng) catch |err| {
                    std.debug.print(
                        "\n[checkpoint] save failed: {s}\n",
                        .{@errorName(err)},
                    );
                };

                appendCompletedReplay(&sim, io) catch |err| {
                    std.debug.print(
                        "\n[replay] append failed: {s}\n",
                        .{@errorName(err)},
                    );
                };
            }
            running = false;
            break;
        }

        if (replay_mode) {
            if (action.replay) {
                if (replay_file_mode) {
                    running = false;
                    break;
                }

                replay_mode = false;
                render(&console, &sim, mode);
                continue;
            }

            if (action.replay_restart) {
                replay_player.restart();
            }

            if (action.replay_seek_percent) |percent| {
                replay_player.seekPercent(percent);
            }

            if (action.replay_speed_delta != 0) {
                replay_player.adjustSpeed(action.replay_speed_delta);
            }

            if (action.replay_toggle) {
                replay_player.playing = !replay_player.playing;
            }

            if (action.replay_step < 0) {
                replay_player.stepBackward();
            } else if (action.replay_step > 0) {
                replay_player.stepForward();
            }

            if (replay_player.playing) {
                replay_player.advance(replay_player.ticksPerFrame());
            }

            renderReplay(&console, &replay_player);

            const replay_delay_ms = replay_player.delayMs();
            if (replay_delay_ms != 0) {
                io.sleep(
                    .fromMilliseconds(replay_delay_ms),
                    .awake,
                ) catch {};
            }
            continue;
        }

        if (action.replay) {
            replay_mode = true;
            replay_player.restart();
            renderReplay(&console, &replay_player);
            continue;
        }

        if (action.mode) |new_mode| {
            mode = new_mode;
        }

        for (0..mode.ticksPerFrame()) |_| {
            if (try sim.step(io, random)) |_| {
                // Save only after evolve() has swapped the new parent
                // population in and advanced `generation`. This checkpoint is
                // therefore a clean generation boundary.
                saveCheckpoint(&sim, io, &prng) catch |err| {
                    std.debug.print(
                        "\n[checkpoint] save failed: {s}\n",
                        .{@errorName(err)},
                    );
                };

                if (sim.generation % checkpoint_snapshot_interval == 0) {
                    saveCheckpointSnapshot(&sim, io, &prng) catch |err| {
                        std.debug.print(
                            "\n[checkpoint] snapshot generation {d} save failed: {s}\n",
                            .{ sim.generation, @errorName(err) },
                        );
                    };
                }

                appendCompletedReplay(&sim, io) catch |err| {
                    std.debug.print(
                        "\n[replay] append failed: {s}\n",
                        .{@errorName(err)},
                    );
                };
            }
        }

        render(
            &console,
            &sim,
            mode,
        );

        const delay_ms = mode.delayMs();
        if (delay_ms != 0) {
            io.sleep(
                .fromMilliseconds(delay_ms),
                .awake,
            ) catch {};
        }
    }

    console.end();
    console_active = false;

    if (!replay_file_mode) {
        printFinalReport(&sim);
    }
}
