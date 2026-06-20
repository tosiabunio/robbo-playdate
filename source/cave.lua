-- Cave grid model + gameplay engine, ported from ROBBO_C/PLAY.CPP (+ CAVES.CPP).
--
-- The original keeps three parallel arrays over the same 16x31 cells:
--   map[]    -> object type at the cell (OBJ.*)
--   status[] -> per-object state / facing direction (STAT.*)
--   call[]   -> per-cell scheduling flag for the update pass
-- We mirror that here. Cells are addressed by a single index `pos = y*X_SIZE + x`,
-- exactly as the C code does, so logic ports across 1:1.
--
-- STAGE 3 SCOPE: this file hosts the full per-frame engine — robo() (player),
-- epilog(), the play() update loop as Cave:step(), and every proc_tab entry
-- (enemies, weapons, shots, bombs, barriers, explosions, the create() stager).
-- Only SCREW/MAGNET/E_LIFE remain empty_proc, matching the original (they have
-- no per-frame behaviour; pickup/interaction happens in robo()).

import "constants"
import "objects"   -- EXPLODE/SHOOT/KILL + EXTRAS/EXTRA_SOUNDS
import "sounds"    -- SOUND() (no-op until Stage 4) + SFX ids
import "caves"     -- baked Caves[n] = {robo_pos, map, status} (1-based, full edition)

-- play() return reasons (ROBBO_C `enum reason`). Exposed for game.lua's
-- end-of-cave transition. Concrete values are arbitrary but stable.
REASON = { STOP = 0, DONE = 1, DEAD = 2 }

-- Cell-offset directions (PLAY.CPP:94-98). UP/DOWN are +/- one row.
local UP    <const> = -X_SIZE
local DOWN  <const> =  X_SIZE
local LEFT  <const> = -1
local RIGHT <const> =  1
local CENTRE <const> = 0

-- stat_val direction aliases (constants.lua STAT) used as table indices below.
local U, R, D, L = STAT.U, STAT.R, STAT.D, STAT.L

-- Direction lookup tables (PLAY.CPP:101-105), indexed by a direction stat_val.
local REALS     = { [U]=UP,    [R]=RIGHT, [D]=DOWN,  [L]=LEFT  }
local RIGHTS    = { [U]=R,     [R]=D,     [D]=L,     [L]=U     }
local LEFTS     = { [U]=L,     [R]=U,     [D]=R,     [L]=D     }
local OPPOSITES = { [U]=D,     [R]=L,     [D]=U,     [L]=R     }
-- Maps a cell-offset direction back to its stat_val (for PUT_SHOT).
local DIR_TO_STAT = { [UP]=U, [RIGHT]=R, [DOWN]=D, [LEFT]=L }

-- tele_dirs[4*4] (PLAY.CPP:772-776): exit-direction priority per entry dir.
local TELE_DIRS = {
    [0]=U, R, L, D,
         R, U, D, L,
         D, L, R, U,
         L, D, U, R,
}

-- Tunables from PLAY.CPP.
local POST_MORTEM   <const> = 12
local PHASE_DELAY   <const> = 12
local FRQ_MAX       <const> = 10
local FRQ_MIN       <const> = 3
local MAX_DEL       <const> = 10
local EXPLOSION_LEN <const> = 6
local AUX           <const> = STAT.AUX   -- 128

-- Deterministic PRNG. Runtime randomness need NOT match Borland's rand() (only
-- the offline level decode did); it just has to be reproducible across hardware
-- so the sim stays deterministic. random(n) in C returns 0..n-1; random(1)==0.
local rngState = 0x2A6F5C3D
local function rnd(n)
    rngState = (rngState * 1103515245 + 12345) & 0x7fffffff
    if n <= 1 then return 0 end
    return (rngState >> 16) % n
end

class("Cave").extends()

function Cave:init()
    self.map    = {}
    self.status = {}
    self.call   = {}
    self.robo_pos = 0
    self.current  = 0
    self.game     = nil   -- set by Game (shared run-state: ammo/keys/screws/lives)
    self:clear()
    self:initPlayState()
end

function Cave:clear()
    for i = 0, MAP_SIZE - 1 do
        self.map[i]    = OBJ.SPACE
        self.status[i] = STAT.NORMAL
        self.call[i]   = 0
    end
end

-- Per-cave loop state (the file-scope globals at the top of PLAY.CPP, reset in
-- play()/robo()). Reset on every cave (re)load.
function Cave:initPlayState()
    self.tele_phase = 0
    self.tele_dest  = 0
    self.tele_ret   = 0
    self.tele_num   = 0
    self.tele_dir   = 0
    self.reload     = 0
    self.phase_delay = 0
    self.counter    = 1     -- PLAY.CPP:1143 (play() sets counter=1)
    self.cntr       = 0
    self.post_mortem = 0
    self.stop_cond  = REASON.STOP
    self.cont       = 1
    self.robo_present = 0
    self.robo_step  = 0
    self.frq        = FRQ_MAX
    self.hm_del     = MAX_DEL
    self.barrier_mem = 0    -- C `static word memory` in barrier() (PLAY.CPP:673)
    resetQueue()            -- play() resets the sound queue per cave (RSOUNDS.CPP)
end

-- Convert between (x, y) and the linear position used throughout the engine.
function Cave.xy(pos)  return pos % X_SIZE, pos // X_SIZE end
function Cave.pos(x, y) return y * X_SIZE + x end

-- load(num): populate this cave from the pre-baked Caves[num] table produced by
-- tools/decode_caves.py (a faithful port of CAVES.CPP::get_cave()). `num` is
-- 1-based. The baked table is 0-based map/status matching OBJ/STAT; copy straight
-- in and reset loop state.
function Cave:load(num)
    local src = Caves[num]
    assert(src, "Cave:load: no baked cave " .. tostring(num))
    for i = 0, MAP_SIZE - 1 do
        self.map[i]    = src.map[i + 1]     -- baked table is 1-based Lua
        self.status[i] = src.status[i + 1]
        self.call[i]   = 0
    end
    self.robo_pos = src.robo_pos
    self:initPlayState()
end

------------------------------------------------------------------------------
-- Cell access + move/put macros (PLAY.CPP:107-146). All operate relative to
-- self.current, exactly like the C macros relative to the `current` global.
------------------------------------------------------------------------------

function Cave:obj_at(dir)  return self.map[self.current + dir] end
function Cave:stat_at(dir) return self.status[self.current + dir] end

function Cave:moveObject(dir)               -- MOVE_OBJECT
    local c = self.current
    self.map[c + dir]    = self.map[c]
    self.status[c + dir] = self.status[c]
    self.map[c]    = OBJ.SPACE
    self.status[c] = STAT.NORMAL
    self.call[c + dir] = 0
    self.call[c]       = 0
end

function Cave:pushObject(dir)               -- PUSH_OBJECT (push a chain of two)
    local c = self.current
    self.map[c + 2*dir]    = self.map[c + dir]
    self.status[c + 2*dir] = self.status[c + dir]
    self.map[c + dir]    = OBJ.SPACE
    self.status[c + dir] = STAT.NORMAL
    self.call[c + 2*dir] = 0
    self.call[c + dir]   = 0
    self.map[c + dir]    = self.map[c]
    self.status[c + dir] = self.status[c]
    self.map[c]    = OBJ.SPACE
    self.status[c] = STAT.NORMAL
    self.call[c + dir] = 0
    self.call[c]       = 0
end

function Cave:putObject(dir, object, statval)   -- PUT_OBJECT
    local c = self.current
    self.map[c + dir]    = object
    self.status[c + dir] = statval
    self.call[c + dir]   = 0
end

function Cave:setStatus(dir, val)            -- SET_STATUS
    local c = self.current
    self.status[c + dir] = val
    self.call[c + dir]   = 0
end

function Cave:putExplosion(dir)              -- PUT_EXPLOSION
    self:putObject(dir, OBJ.EXPLOSION, rnd(3) + 2)
end

-- CREATE_OBJECT: stages an object that materialises 3 frames later via create().
-- status word = what | (random(1)<<12) | (statval<<8); random(1) is always 0.
function Cave:createObject(dir, what, statval)
    self:putObject(dir, OBJ.CREATE, what | (statval << 8))
end

function Cave:putShot(dir, shot)             -- PUT_SHOT
    if self:obj_at(dir) == OBJ.SPACE then
        self:putObject(dir, shot, DIR_TO_STAT[dir])
    else
        self:test_to_kill(dir)
    end
end

------------------------------------------------------------------------------
-- test_to_kill (PLAY.CPP:162-241): resolve a shot/contact against OBJECT(dir).
-- Returns 1 if the target was consumed/handled, 0 otherwise.
------------------------------------------------------------------------------
function Cave:test_to_kill(dir)
    local obj = self:obj_at(dir)

    if obj == OBJ.EXTRA then
        local xtr = rnd(32)
        SOUND(EXTRA_SOUNDS[xtr])
        xtr = EXTRAS[xtr]
        if xtr == OBJ.ROBO then
            -- "super" surprise: drop an extra life and sweep the cave clear of
            -- doors/eyes/bats/guards, turn magnets to walls, dissolve barriers.
            local tmp = self.current
            self:createObject(dir, OBJ.E_LIFE, STAT.NORMAL)
            for c = 0, MAP_SIZE - 1 do
                self.current = c
                local o = self:obj_at(CENTRE)
                if o == OBJ.MAGNET then
                    self:createObject(CENTRE, OBJ.WALL, STAT.NORMAL)
                elseif o == OBJ.DOOR or o == OBJ.EYES or o == OBJ.MOV_BAT
                    or o == OBJ.PIF_BAT or o == OBJ.L_GUARD or o == OBJ.R_GUARD then
                    self:createObject(CENTRE, OBJ.SPACE, STAT.NORMAL)
                elseif o == OBJ.BARRIER then
                    if self:stat_at(CENTRE) == STAT.NORMAL then
                        self:createObject(CENTRE, OBJ.SPACE, STAT.NORMAL)
                    else
                        self:putObject(CENTRE, OBJ.WALL, STAT.NORMAL)
                    end
                end
            end
            self.current = tmp
        elseif xtr == OBJ.EXPLOSION then
            self:putExplosion(dir)
        elseif xtr == OBJ.EXIT then
            self:createObject(dir, OBJ.EXIT, STAT.E_OPEN)
        else
            self:createObject(dir, xtr, STAT.NORMAL)
        end
        return 1

    elseif obj == OBJ.BOMB then
        self:setStatus(dir, STAT.FIRED)
        return 1

    elseif obj == OBJ.BARRIER then
        if self:stat_at(dir) == STAT.NORMAL then
            self:putObject(dir, OBJ.SPACE, STAT.NORMAL)
        end
        return 1

    else
        if SHOOT[obj] == 1 then
            SOUND(SFX.STWUR_BUM)
            self:putExplosion(dir)
            return 1
        end
        return 0
    end
end

------------------------------------------------------------------------------
-- proc_tab procedures (PLAY.CPP). Stage-2 subset; the rest are empty_proc.
------------------------------------------------------------------------------

function Cave:empty_proc()                   -- empty_proc (PLAY.CPP:243)
    self.call[self.current] = 0
end

function Cave:robo_short()                   -- robo_short (PLAY.CPP:248)
    self.robo_pos = self.current
    self.robo_present = 1
end

function Cave:exit_()                        -- exit_ (PLAY.CPP:578)
    if self.game.screws == 0 and self:stat_at(CENTRE) == STAT.E_CLOSED then
        self:setStatus(CENTRE, STAT.E_OPEN)
    end
end

function Cave:explosion()                    -- explosion (PLAY.CPP:331)
    if self:stat_at(CENTRE) < EXPLOSION_LEN then
        self:setStatus(CENTRE, self:stat_at(CENTRE) + 1)
    else
        self:putObject(CENTRE, OBJ.SPACE, STAT.NORMAL)
    end
end

function Cave:create()                       -- create (PLAY.CPP:512)
    local stat = self:stat_at(CENTRE)
    local phase = stat & 0xf000
    if phase < 0x3000 then
        phase = phase + 0x1000
        self:setStatus(CENTRE, (stat & 0x0fff) | phase)
    else
        self:putObject(CENTRE, stat & 0x00ff, (stat & 0x0f00) >> 8)
    end
end

function Cave:gun_shot()                     -- gun_shot (PLAY.CPP:381)
    if self:stat_at(CENTRE) == AUX then
        self:putObject(CENTRE, OBJ.SPACE, STAT.NORMAL)
        return
    end
    local dir = REALS[self:stat_at(CENTRE)]
    if self:obj_at(dir) == OBJ.SPACE then
        self:moveObject(dir)
    else
        if self:test_to_kill(dir) == 1 then
            self:putObject(CENTRE, OBJ.SPACE, STAT.NORMAL)
        else
            self:setStatus(CENTRE, AUX)
        end
    end
end

function Cave:push()                         -- push (PLAY.CPP:584)
    if self:stat_at(CENTRE) ~= STAT.BOX_S then
        local dir = REALS[self:stat_at(CENTRE)]
        if self:obj_at(dir) == OBJ.SPACE then
            self:moveObject(dir)
        else
            self:test_to_kill(dir)
            self:putObject(CENTRE, OBJ.PUSH, STAT.BOX_S)
        end
    end
end

function Cave:extra_proc()                   -- extra_proc (PLAY.CPP:699)
    self:setStatus(CENTRE, self:stat_at(CENTRE) + 1)
end

------------------------------------------------------------------------------
-- Stage 3: enemy / weapon-emitter / shot procs (PLAY.CPP). Each is a verbatim
-- port of the C `near` function; the cell-offset directions and the
-- LEFTS/RIGHTS/OPPOSITES/REALS tables above stand in for the C macros.
------------------------------------------------------------------------------

-- 3x3 neighbourhood offsets for bomb() (PLAY.CPP:343-345), raster order:
-- UL U UR / L C R / DL D DR. UP/DOWN are +/- X_SIZE (a row), LEFT/RIGHT +/- 1.
local NDIRS = {
    UP-1, UP, UP+1,
    LEFT, CENTRE, RIGHT,
    DOWN-1, DOWN, DOWN+1,
}

function Cave:bomb()                         -- bomb (PLAY.CPP:347)
    if self:stat_at(CENTRE) == STAT.FIRED then
        SOUND(SFX.BUM)
        for i = 1, 9 do                      -- C: for i=0; i<9; i++
            local dir = NDIRS[i]
            local obj = self:obj_at(dir)
            if obj == OBJ.BOMB then
                self:setStatus(dir, STAT.FIRED)
            elseif obj == OBJ.BARRIER then
                if self:stat_at(dir) == STAT.NORMAL then
                    self:putObject(dir, OBJ.SPACE, STAT.NORMAL)
                end
            else
                if EXPLODE[obj] == 1 then
                    self:putObject(dir, OBJ.EXPLOSION, ((i - 1) & 1))
                end
            end
        end
        self:putObject(CENTRE, OBJ.EXPLOSION, 2)
    end
end

function Cave:gun()                          -- gun (PLAY.CPP:409)
    if rnd(256) < 12 then
        self:putShot(REALS[self:stat_at(CENTRE)], OBJ.GUN_SHOT)
    end
end

function Cave:blaster_shot()                 -- blaster_shot (PLAY.CPP:418)
    local dir = REALS[self:stat_at(CENTRE)]
    local obj = self:obj_at(dir)
    if obj == OBJ.SPACE or obj == OBJ.GRASS then
        self:moveObject(dir)
        self:putObject(CENTRE, OBJ.EXPLOSION, 1)
    else
        -- C: `if (!test_to_kill(dir));` — note the stray semicolon: the if has
        -- an empty body, so test_to_kill ALWAYS runs and the explosion ALWAYS
        -- follows. We reproduce that (test then explode), not the apparent intent.
        self:test_to_kill(dir)
        self:putObject(CENTRE, OBJ.EXPLOSION, 1)
    end
end

function Cave:blaster()                      -- blaster (PLAY.CPP:435)
    if rnd(256) < 12 then
        self:putShot(REALS[self:stat_at(CENTRE)], OBJ.BLASTER_SHOT)
    end
end

function Cave:laser_shot()                   -- laser_shot (PLAY.CPP:444)
    local stat = self:stat_at(CENTRE)
    -- Phase A: the trailing/returning half of a two-cell laser pulse.
    if (stat & 0x8800) == 0x0800 then
        local dir = REALS[stat & 0x00ff]
        if self:obj_at(dir) == OBJ.LASER then
            self:putObject(CENTRE, OBJ.SPACE, STAT.NORMAL)
        else
            self:moveObject(dir)
        end
        return
    end
    -- Phase B: the leading half. Advances into SPACE and spawns its trailing
    -- twin behind it (status|0x8000). On contact, kills/reverses.
    if (stat & 0x8800) == 0x0000 then
        local dir = REALS[stat]
        if self:obj_at(dir) == OBJ.SPACE then
            self:moveObject(dir)
            self:putObject(CENTRE, OBJ.LASER_SHOT, stat | 0x8000)
        else
            self:test_to_kill(dir)
            self:setStatus(CENTRE, (OPPOSITES[stat]) | 0x0800)
        end
    end
end

function Cave:laser()                        -- laser (PLAY.CPP:481)
    if rnd(256) < 12 then
        self:putShot(REALS[self:stat_at(CENTRE)], OBJ.LASER_SHOT)
    end
end

function Cave:l_guard()                      -- l_guard (PLAY.CPP:255)
    -- Left-handed wall follower: prefer the cell to its left, else ahead, else
    -- turn right. Left of a facing dir is LEFTS[stat].
    local stat = self:stat_at(CENTRE)
    local dir = REALS[LEFTS[stat]]
    if self:obj_at(dir) == OBJ.SPACE then
        self:setStatus(CENTRE, LEFTS[stat])
        self:moveObject(dir)
    else
        dir = REALS[stat]
        if self:obj_at(dir) == OBJ.SPACE then
            self:moveObject(dir)
        else
            self:setStatus(CENTRE, RIGHTS[stat])
        end
    end
end

function Cave:r_guard()                      -- r_guard (PLAY.CPP:281)
    -- Right-handed wall follower: prefer the cell to its right, else ahead,
    -- else turn left. Mirror of l_guard.
    local stat = self:stat_at(CENTRE)
    local dir = REALS[RIGHTS[stat]]
    if self:obj_at(dir) == OBJ.SPACE then
        self:setStatus(CENTRE, RIGHTS[stat])
        self:moveObject(dir)
    else
        dir = REALS[stat]
        if self:obj_at(dir) == OBJ.SPACE then
            self:moveObject(dir)
        else
            self:setStatus(CENTRE, LEFTS[stat])
        end
    end
end

function Cave:mov_bat()                      -- mov_bat (PLAY.CPP:307)
    -- Patrols a straight line; on a blocked cell it flips direction and sets a
    -- one-frame "reversal" flag (0x8000) so it doesn't bounce back immediately.
    local stat = self:stat_at(CENTRE)
    if (stat & 0x8000) == 0 then
        local dir = REALS[stat]
        if self:obj_at(dir) == OBJ.SPACE then
            self:moveObject(dir)
        else
            self:setStatus(CENTRE, (OPPOSITES[stat]) | 0x8000)
        end
    else
        self:setStatus(CENTRE, stat & 0x7fff)
    end
end

function Cave:pif_bat()                      -- pif_bat (PLAY.CPP:490)
    -- Mostly patrols like a bat; 1/8 chance per step to fire a shot downward.
    if rnd(8) == 0 then
        self:putShot(DOWN, OBJ.GUN_SHOT)
    else
        local dir = REALS[self:stat_at(CENTRE)]
        if self:obj_at(dir) == OBJ.SPACE then
            self:moveObject(dir)
        else
            self:setStatus(CENTRE, OPPOSITES[self:stat_at(CENTRE)])
        end
    end
end

function Cave:eyes()                         -- eyes (PLAY.CPP:603)
    -- The "eyes" monster homes toward Robbo. First set its facing toward him
    -- via the look_dir[] 11-entry LUT, then maybe step toward him.
    local look_dir = { 0,7,6,0,1,0,5,0,2,3,4 }   -- PLAY.CPP:608 (index (lx+1)*4+(ly+1))
    local robo = self.robo_pos
    local hy = robo // X_SIZE
    local hx = robo %  X_SIZE
    local ey = self.current // X_SIZE
    local ex = self.current %  X_SIZE
    local look_x = hx - ex
    local look_y = hy - ey
    if look_x ~= 0 then
        if math.abs(look_x) > math.abs(look_y) * 4 then look_y = 0 end
        look_x = look_x > 0 and 1 or -1
    end
    if look_y ~= 0 then
        if math.abs(look_y) > math.abs(look_x) * 4 then look_x = 0 end
        look_y = look_y > 0 and 1 or -1
    end
    self:setStatus(CENTRE, look_dir[((look_x + 1) * 4) + (look_y + 1) + 1])

    if rnd(2) == 0 then
        -- Try vertical then horizontal approach toward Robbo.
        if ey ~= hy then
            local dir = ey < hy and DOWN or UP
            if self:obj_at(dir) == OBJ.SPACE then
                self:moveObject(dir); return
            end
        end
        if ex ~= hx then
            local dir = ex < hx and RIGHT or LEFT
            if self:obj_at(dir) == OBJ.SPACE then
                self:moveObject(dir); return
            end
        end
        -- Rare random wander.
        if rnd(32) == 0 then
            local dir = REALS[U + rnd(4)]
            if self:obj_at(dir) == OBJ.SPACE then
                self:moveObject(dir)
            end
        end
    elseif rnd(2) == 0 then
        -- Idle jitter: nudge facing and maybe drift.
        NEAR_SOUND(SFX.OCZY_PISK, self.current, self.robo_pos)   -- proximity-gated (PLAY.CPP:661)
        self:setStatus(CENTRE, (self:stat_at(CENTRE) + rnd(3) - 1) & 0x07)
        local dir = REALS[U + rnd(4)]
        if self:obj_at(dir) == OBJ.SPACE then
            self:moveObject(dir)
        end
    end
end

function Cave:rot_gun()                      -- rot_gun (PLAY.CPP:553)
    -- Rotating gun: every 4th frame may turn left/right; otherwise occasionally fires.
    local stat = self:stat_at(CENTRE)
    if (self.cntr % 4) == 0 then
        if rnd(4) == 0 then
            if rnd(2) == 0 then
                self:setStatus(CENTRE, LEFTS[stat])
            else
                self:setStatus(CENTRE, RIGHTS[stat])
            end
        end
    elseif rnd(8) == 0 then
        self:putShot(REALS[stat], OBJ.GUN_SHOT)
    end
end

function Cave:mov_gun()                      -- mov_gun (PLAY.CPP:528)
    -- Moving gun: acts only on odd cntr. Patrols straight, firing upward.
    if (self.cntr & 1) == 1 then
        local stat = self:stat_at(CENTRE)
        local dir = REALS[stat]
        if self:obj_at(dir) == OBJ.SPACE then
            self:moveObject(dir)
        else
            self:setStatus(CENTRE, OPPOSITES[stat])
        end
        if rnd(256) < 12 then
            self:putShot(UP, OBJ.GUN_SHOT)
        end
    end
end

function Cave:barrier()                      -- barrier (PLAY.CPP:671)
    -- Sliding barrier block. Moves left across SPACE; a facing-L barrier leaves
    -- a wall behind (R status), an R-status one reopens the cell to its left.
    -- Uses a persistent cell `memory` (C: `static word memory`); we store it on
    -- self so it survives across calls within a run.
    local stat = self:stat_at(CENTRE)
    if stat == STAT.NORMAL then
        if self:obj_at(LEFT) ~= OBJ.BARRIER then
            self:moveObject(LEFT)
        end
    elseif stat == L then
        self.barrier_mem = self:obj_at(RIGHT)
        if self.barrier_mem == OBJ.BARRIER then
            self:putObject(RIGHT, OBJ.SPACE, STAT.NORMAL)
        end
    elseif stat == R then
        if self.barrier_mem == OBJ.BARRIER then
            self:putObject(LEFT, OBJ.BARRIER, STAT.NORMAL)
        end
    end
end

-- active[] (PLAY.CPP:704) — which objects get a proc pass. 0-keyed by OBJ.
local ACTIVE = {}
do
    local a = {
        1,0,0,0,0,0,0,1,   -- ROBO SPACE WALL B_WALL GRASS BOX KEY BOMB
        1,1,0,1,0,1,1,1,   -- EXTRA SCREW AMMO PUSH DOOR TELE L_GUARD R_GUARD
        1,1,1,1,1,1,1,1,   -- MOV_BAT PIF_BAT EYES GUN LASER BLASTER ROT_GUN MOV_GUN
        1,1,1,1,1,1,1,1,   -- EXPLOSION MAGNET EXIT GUN_SHOT LASER_SHOT BLASTER_SHOT E_LIFE BARRIER
        1,                 -- CREATE
    }
    for i = 1, #a do ACTIVE[i - 1] = a[i] end
end

-- proc_tab[] (PLAY.CPP:716). Methods invoked as PROC[obj](cave). Static/pickup
-- objects (SCREW, MAGNET, E_LIFE) map to empty_proc just as in the original;
-- every active enemy/weapon/shot now has its real proc.
local PROC = {
    [OBJ.ROBO]      = Cave.robo_short,
    [OBJ.BOMB]      = Cave.bomb,
    [OBJ.EXTRA]     = Cave.extra_proc,
    [OBJ.SCREW]     = Cave.empty_proc,
    [OBJ.PUSH]      = Cave.push,
    [OBJ.TELE]      = Cave.empty_proc,
    [OBJ.L_GUARD]   = Cave.l_guard,
    [OBJ.R_GUARD]   = Cave.r_guard,
    [OBJ.MOV_BAT]   = Cave.mov_bat,
    [OBJ.PIF_BAT]   = Cave.pif_bat,
    [OBJ.EYES]      = Cave.eyes,
    [OBJ.GUN]       = Cave.gun,
    [OBJ.LASER]     = Cave.laser,
    [OBJ.BLASTER]   = Cave.blaster,
    [OBJ.ROT_GUN]   = Cave.rot_gun,
    [OBJ.MOV_GUN]   = Cave.mov_gun,
    [OBJ.EXPLOSION] = Cave.explosion,
    [OBJ.MAGNET]    = Cave.empty_proc,
    [OBJ.EXIT]      = Cave.exit_,
    [OBJ.GUN_SHOT]  = Cave.gun_shot,
    [OBJ.LASER_SHOT]   = Cave.laser_shot,
    [OBJ.BLASTER_SHOT] = Cave.blaster_shot,
    [OBJ.E_LIFE]    = Cave.empty_proc,
    [OBJ.BARRIER]   = Cave.barrier,
    [OBJ.CREATE]    = Cave.create,
}

------------------------------------------------------------------------------
-- robo (PLAY.CPP:781) — the player. Reads `input` {up,right,down,left,fire,
-- selfdestruct}; mutates the shared run-state via self.game. The many scroll()
-- calls in the original (DOS smooth-scroll interleave) are dropped — scrolling
-- is the renderer's discrete topRow model.
------------------------------------------------------------------------------
function Cave:robo(input)
    local run = self.game

    -- Teleport state machine (3 -> 2 -> 1 -> 0). Runs in place; robo does
    -- nothing else while teleporting, and returns each frame.
    if self.tele_phase > 0 then
        if self.tele_phase == 3 then
            -- Find the partner teleporter with the same number.
            self.current = self.tele_ret
            while true do
                self.current = self.current + 1
                if self.current == MAP_SIZE then self.current = 0 end
                if self:obj_at(CENTRE) == OBJ.TELE and self:stat_at(CENTRE) == self.tele_num then
                    self.tele_dest = self.current
                    self.tele_phase = self.tele_phase - 1
                    break
                end
            end
            return
        elseif self.tele_phase == 2 then
            -- Try to deposit Robbo on a free cell around the partner, in the
            -- priority order encoded by tele_dirs for the entry direction.
            self.current = self.tele_dest
            for slot = 0, 3 do
                local dir = REALS[ TELE_DIRS[self.tele_dir * 4 + slot] ]
                if self:obj_at(dir) == OBJ.SPACE then
                    self:createObject(dir, OBJ.ROBO, STAT.ROBO_S)
                    self.tele_phase = 1
                    return
                end
            end
            -- Boxed in: flip direction and search again from here.
            self.tele_dir = OPPOSITES[self.tele_dir]
            self.tele_ret = self.current
            self.tele_phase = 3
            return
        elseif self.tele_phase == 1 then
            if self.robo_present == 0 then return end
            self.tele_phase = 0
        end
        return
    end

    self.current = self.robo_pos

    -- Robbo gone (destroyed last frame): register death.
    if self.robo_present == 0 or self:obj_at(CENTRE) ~= OBJ.ROBO then
        self.post_mortem = POST_MORTEM
        self.stop_cond = REASON.DEAD
        SOUND(SFX.BIEDNY)
        return
    end

    -- Death by adjacent lethal object (no stop_cond here — Robbo becomes an
    -- explosion; next frame the check above registers DEAD). Faithful to C:866.
    if KILL[self:obj_at(UP)] == 1 or KILL[self:obj_at(RIGHT)] == 1
        or KILL[self:obj_at(DOWN)] == 1 or KILL[self:obj_at(LEFT)] == 1 then
        self:putExplosion(CENTRE)
        SOUND(SFX.ROBBO_BUM)
        return
    end

    -- Magnet auto-slide: once caught, Robbo slides toward the magnet until he
    -- reaches it (death) or hits a gap.
    if self:stat_at(CENTRE) == STAT.ROBO_L then
        if self:obj_at(LEFT) == OBJ.SPACE then
            self:moveObject(LEFT); self.robo_pos = self.robo_pos + LEFT
        elseif self:obj_at(LEFT) == OBJ.MAGNET then
            self:putExplosion(CENTRE)
            self.post_mortem = POST_MORTEM; self.stop_cond = REASON.DEAD; SOUND(SFX.BIEDNY)
        end
        return
    end
    if self:stat_at(CENTRE) == STAT.ROBO_R then
        if self:obj_at(RIGHT) == OBJ.SPACE then
            self:moveObject(RIGHT); self.robo_pos = self.robo_pos + RIGHT
        elseif self:obj_at(RIGHT) == OBJ.MAGNET then
            self:putExplosion(CENTRE)
            self.post_mortem = POST_MORTEM; self.stop_cond = REASON.DEAD; SOUND(SFX.BIEDNY)
        end
        return
    end

    -- Magnet pull preamble: a magnet facing Robbo across a clear corridor grabs
    -- him (sets ROBO_L/ROBO_R, which the slide above then acts on next frames).
    self.current = self.robo_pos - 1
    while true do
        if self:obj_at(CENTRE) == OBJ.SPACE then
            self.current = self.current - 1
        elseif self:obj_at(CENTRE) == OBJ.MAGNET and self:stat_at(CENTRE) == L then
            self.current = self.robo_pos
            self:setStatus(CENTRE, STAT.ROBO_L); SOUND(SFX.MAGNES); return
        else
            break
        end
    end
    self.current = self.robo_pos + 1
    while true do
        if self:obj_at(CENTRE) == OBJ.SPACE then
            self.current = self.current + 1
        elseif self:obj_at(CENTRE) == OBJ.MAGNET and self:stat_at(CENTRE) == R then
            self.current = self.robo_pos
            self:setStatus(CENTRE, STAT.ROBO_R); SOUND(SFX.MAGNES); return
        else
            break
        end
    end

    self.current = self.robo_pos

    -- Read input into a direction key (ROBO_S = none) + fire flag.
    local key = STAT.ROBO_S
    if input.up then key = U
    elseif input.right then key = R
    elseif input.down then key = D
    elseif input.left then key = L end
    local fire = input.fire

    if key == STAT.ROBO_S then
        -- Idle: drive the "mruk" (humming) idle animation. Sound deferred.
        if self.phase_delay == 0 then
            self.robo_step = 0
            if (self.counter & 15) == 0 and self.hm_del ~= 0 then self.hm_del = self.hm_del - 1 end
            if (self.counter & 15) == 0 and rnd(self.frq) == 0 and self.hm_del == 0 then
                if self.frq > FRQ_MIN then self.frq = self.frq - 1 end
                local r = rnd(3)
                self:setStatus(CENTRE, STAT.ROBO_MRUK + r + 1)
                -- Idle "humming" voice (PLAY.CPP:975): the mruk==2 variant draws
                -- from the first 6 voices, others from all 12 (files 34..45).
                local h = (r == 2) and rnd(6) or rnd(12)
                SOUND(SFX.HMHMHM + h)
            else
                self:setStatus(CENTRE, STAT.ROBO_S)
            end
        else
            self.robo_step = 0
            self:setStatus(CENTRE, self:stat_at(CENTRE))
            self.phase_delay = self.phase_delay - 1
        end
    else
        self.frq = FRQ_MAX
        self.hm_del = MAX_DEL
        local dir = REALS[key]
        local obj = self:obj_at(dir)
        if fire then
            if key ~= STAT.ROBO_S and self.reload == 0 then
                if run.ammo > 0 then
                    SOUND(SFX.STRZAL)
                    self:setStatus(CENTRE, key)
                    self.phase_delay = PHASE_DELAY
                    if obj == OBJ.SPACE then
                        self:putShot(dir, OBJ.GUN_SHOT)
                    else
                        self:test_to_kill(dir)
                    end
                    run.ammo = run.ammo - 1
                    self.reload = 3
                else
                    SOUND(SFX.BATERIA_LOW)
                end
            end
        else
            self.robo_step = self.robo_step + 1
            self:setStatus(CENTRE, key)
            self.phase_delay = PHASE_DELAY
            if obj == OBJ.SPACE then
                self:moveObject(dir); self.robo_pos = self.robo_pos + dir
            elseif obj == OBJ.TELE then
                SOUND(SFX.TELEPORT)
                self:putExplosion(CENTRE)
                self.tele_dir  = key
                self.tele_num  = self:stat_at(dir)
                self.tele_phase = 3
                self.tele_dest = self.current + dir
                self.tele_ret  = self.current + dir
            elseif obj == OBJ.AMMO then
                SOUND(SFX.BATERIA)
                run.ammo = math.min(run.ammo + 9, 99)
                self:moveObject(dir); self.robo_pos = self.robo_pos + dir
            elseif obj == OBJ.KEY then
                SOUND(SFX.KLUCZ)
                run.keys = math.min(run.keys + 1, 4)
                self:moveObject(dir); self.robo_pos = self.robo_pos + dir
            elseif obj == OBJ.SCREW then
                if run.screws > 1 then SOUND(SFX.SRUBKA) else SOUND(SFX.ODSZUKAJ) end
                if run.screws > 0 then run.screws = run.screws - 1 end
                self:moveObject(dir); self.robo_pos = self.robo_pos + dir
            elseif obj == OBJ.E_LIFE then
                SOUND(SFX.EXTRA_ROBO)
                run.extraTaken = true
                run.lives = math.min(run.lives + 1, 10)
                self:moveObject(dir); self.robo_pos = self.robo_pos + dir
            elseif obj == OBJ.PUSH then
                if self:obj_at(2 * dir) == OBJ.SPACE then self:setStatus(dir, key) end
            elseif obj == OBJ.DOOR then
                if run.keys > 0 then
                    SOUND(SFX.DRZWI_OPEN)
                    run.keys = run.keys - 1
                    self:putObject(dir, OBJ.SPACE, STAT.NORMAL)
                else
                    SOUND(SFX.KLUCZ_TRZA)
                end
            elseif obj == OBJ.EXIT then
                if self:stat_at(dir) == STAT.E_OPEN then
                    SOUND(SFX.BRAWO)
                    self:putObject(CENTRE, OBJ.SPACE, STAT.NORMAL)
                    self:setStatus(dir, STAT.E_ROBO)
                    self.robo_pos = self.robo_pos + dir
                    self.stop_cond = REASON.DONE
                    self.post_mortem = POST_MORTEM
                    return
                elseif self:obj_at(2 * dir) == OBJ.SPACE then
                    -- Closed exit falls through to the push group (C switch
                    -- fall-through, PLAY.CPP:1100-1120): a closed exit is pushable.
                    self:pushObject(dir); self.robo_pos = self.robo_pos + dir
                end
            elseif obj == OBJ.EXTRA or obj == OBJ.BOX or obj == OBJ.BOMB or obj == OBJ.MOV_GUN then
                if self:obj_at(2 * dir) == OBJ.SPACE then
                    self:pushObject(dir); self.robo_pos = self.robo_pos + dir
                end
            end
        end
    end

    -- Bottom death check after any move (PLAY.CPP:1125).
    self.current = self.robo_pos
    if KILL[self:obj_at(UP)] == 1 or KILL[self:obj_at(RIGHT)] == 1
        or KILL[self:obj_at(DOWN)] == 1 or KILL[self:obj_at(LEFT)] == 1 then
        self:putExplosion(CENTRE)
        SOUND(SFX.ROBBO_BUM)
        return
    end
end

-- epilog (PLAY.CPP:738). F10(STOP)/Tab(DONE) dev keys dropped; Esc(self-destruct)
-- is driven by the "Restart level" system-menu item (game.lua) via input.selfdestruct.
function Cave:epilog(input)
    if input.selfdestruct and self.post_mortem == 0 then
        self.current = self.robo_pos
        self:putExplosion(CENTRE)
        self.post_mortem = POST_MORTEM
        self.stop_cond = REASON.DEAD
        SOUND(SFX.BIEDNY)
    end
    if self.post_mortem == 1 then self.cont = 0 end
    if self.reload > 0 then self.reload = self.reload - 1 end
    self.cntr = self.cntr + 1
end

-- step(input): one iteration of the play() do-loop (PLAY.CPP:1155-1194). When
-- self.cont drops to 0 the cave is over; the caller reads self.stop_cond.
function Cave:step(input)
    self.robo_present = 0                    -- prolog()

    for i = 0, MAP_SIZE - 1 do self.call[i] = 1 end   -- setmem(call, 1)

    for i = 0, MAP_SIZE - 1 do
        self.current = i
        local object = self.map[i]
        if ACTIVE[object] == 1 and self.call[i] == 1 then
            PROC[object](self)
        end
    end

    self.current = self.robo_pos
    if self.post_mortem == 0 and self.cont == 1 then
        self:robo(input)
    end

    self:epilog(input)

    playQueue()              -- pump the voice queue once per sim step (play())

    if self.post_mortem > 0 then self.post_mortem = self.post_mortem - 1 end
    self.counter = self.counter + 1
end
