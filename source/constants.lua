-- Game constants, ported from ROBBO_C/ROBBO.H.
--
-- VIEWPORT (gameplay-critical — see PORTING_PLAN.md "VIEWPORT SPEC"):
-- The DOS playfield is 320x160 px = 16 cols x 10 ROWS of 16px tiles
-- (ROBBO.CPP:638 init_screen(DISPLAY,...,320,10*16,320)). Only 10 of the 31
-- cave rows are visible at once; the cave scrolls vertically. This is
-- deliberate level design — showing >10 rows reveals hazards/enemies/exits
-- the puzzles intend to hide.
--
-- LAYOUT (16px tiles, 1:1 with original art):
--   Playfield = 16col x 10row x 16px = 256 x 160, centered horizontally
--   (72px margins each side). Vertically the 160px playfield leaves 80px:
--   16px top margin + 64px bottom status panel (4 tile-rows). The bottom
--   panel hosts the HUD (screws/ammo/cave/lives/keys) — see render.lua.

X_SIZE   = 16          -- cave width  in tiles  (ROBBO.H X_SIZE)
Y_SIZE   = 31          -- cave height in tiles  (ROBBO.H Y_SIZE)
MAP_SIZE = X_SIZE * Y_SIZE

CAVES    = 60          -- full edition (ROBBO.H CAVES, non-SHAREWARE build)
VIEW_ROWS = 10         -- visible rows (DOS DISPLAY screen = 10*16 px tall)
TILE      = 16         -- px per tile; 1:1 with original 16x16 sprite art
SCREEN_W  = 400
SCREEN_H  = 240

-- Screen layout regions (all in pixels).
PLAYFIELD_W = X_SIZE * TILE         -- 256
PLAYFIELD_H = VIEW_ROWS * TILE      -- 160
PLAYFIELD_X = (SCREEN_W - PLAYFIELD_W) // 2   -- 72 (horizontal centering)
PLAYFIELD_Y = 16                     -- top margin: one tile
STATUS_Y    = PLAYFIELD_Y + PLAYFIELD_H       -- 176 (start of bottom panel)
STATUS_H    = SCREEN_H - STATUS_Y             -- 64 (4 tile-rows)

MAX_LIVES = 99         -- ROBBO.H MAX_LIVES

-- Timing. The DOS in-game loop is NOT uncapped — it is V-synced to the VGA
-- vertical retrace. display_time=0 (ROBBO.CPP:619) only disables the *extra*
-- sound-timer wait in play() (get_timer/reset_timer are sound-library function
-- pointers, SOUNDS30.H:35-36, used for title/menu/music pacing, not gameplay).
-- The real frame cap lives in scroll() (DISPLAY.CPP:173): is_vbl() polls VGA
-- reg 0x3DA bit 3, and display_map() ends with `while(scrl>0) scroll()` where
-- scrl = 16/scroll_step = 8. So EACH logic frame waits exactly 8 vertical
-- retraces; the view pans 2px (scroll_step) per retrace = one tile/frame.
-- Mode X 320x240 retrace is ~60 Hz, so logic runs at 60/8 = ~7.5 Hz on capable
-- hardware (slower CPUs drop below it — why VGA wasn't "full speed").
--
-- We reproduce that as a deterministic fixed timestep (PORTING_PLAN risk #3):
-- render at REFRESH_RATE, step the sim every SIM_FRAME_DIV frames. 30/4 = 7.5 Hz
-- matches the original's 60Hz/8 logic rate. Robbo moves one cell per sim step
-- while a direction is held (no per-move gate in robo()).
-- NOTE: the original's smooth 2px-per-retrace scroll is the *same* clock as the
-- sim; we currently scroll discretely (render.lua topRow) and will layer the
-- smooth pan on top later — it changes presentation, not the 7.5 Hz logic rate.
REFRESH_RATE  = 30     -- Playdate display refresh (fps)
SIM_FRAME_DIV = 4      -- sim every 4th frame -> 7.5 Hz logic (== DOS 60Hz/8)

-- Object types. Order MUST match `enum objects` in ROBBO.H — level data and
-- the interaction tables in objects.lua are indexed by these values.
-- Lua tables are 1-based, so we assign the original 0-based values explicitly.
OBJ = {
    ROBO         = 0,
    SPACE        = 1,
    WALL         = 2,
    B_WALL       = 3,
    GRASS        = 4,
    BOX          = 5,
    KEY          = 6,
    BOMB         = 7,
    EXTRA        = 8,
    SCREW        = 9,
    AMMO         = 10,
    PUSH         = 11,
    DOOR         = 12,
    TELE         = 13,
    L_GUARD      = 14,
    R_GUARD      = 15,
    MOV_BAT      = 16,
    PIF_BAT      = 17,
    EYES         = 18,
    GUN          = 19,
    LASER        = 20,
    BLASTER      = 21,
    ROT_GUN      = 22,
    MOV_GUN      = 23,
    EXPLOSION    = 24,
    MAGNET       = 25,
    EXIT         = 26,
    GUN_SHOT     = 27,
    LASER_SHOT   = 28,
    BLASTER_SHOT = 29,
    E_LIFE       = 30,
    BARRIER      = 31,
    CREATE       = 32,
}
MAX_OBJECTS = 33

-- Per-object status values (ROBBO.H enum stat_val): direction + sub-state.
STAT = {
    NORMAL = 0, U = 0, R = 1, D = 2, L = 3,
    ROBO_S = 4, ROBO_L = 5, ROBO_R = 6, ROBO_MRUK = 7,
    BOX_S = 8, E_CLOSED = 9, E_OPEN = 10, E_ROBO = 11,
    T_0 = 0, FIRED = 1, AUX = 128,
}
