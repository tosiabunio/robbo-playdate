-- Map rendering and viewport scrolling, ported from ROBBO_C/DISPLAY.CPP.
--
-- VIEWPORT MODEL (gameplay-critical — see PORTING_PLAN.md "VIEWPORT SPEC").
-- The cave is 16x31 but only VIEW_ROWS(10) rows are on screen at once. The view
-- scrolls vertically, in discrete top-row steps, advancing only when Robbo
-- crosses a 2-row margin — exactly like DISPLAY.CPP::scroll(). This stillness
-- is itself a puzzle mechanic; do NOT replace with pixel-centering on Robbo.
--
-- LAYOUT: 16px tiles. Playfield 256x160 at (PLAYFIELD_X, PLAYFIELD_Y);
-- bottom STATUS_H panel for the HUD. See constants.lua.

import "CoreLibs/graphics"
import "constants"
import "defs"     -- DEFS[obj] = base bank-tile index (from load_defs)

local gfx <const> = playdate.graphics

local MARGIN <const> = 2               -- DISPLAY.CPP MARGIN (scroll trigger band, tiles)
local SCROLL_STEP <const> = 2          -- px advanced per render frame (DOS scroll_step, 2px/retrace)
local SCROLL_SIZE <const> = 3          -- tiles panned per triggered scroll (DISPLAY.CPP SCROLL_SIZE)
local SCROLL_COUNT_INIT <const> = (SCROLL_SIZE * TILE) // SCROLL_STEP  -- 24 steps == 3 tiles
local MAX_SCROLL <const> = (Y_SIZE - VIEW_ROWS) * TILE  -- 336 px (== DOS cur_pos 21*16 max)

-- stat_val aliases (avoid magic numbers in the resolver below).
local U, R, D, L = 0, 1, 2, 3
local ROBO_S, ROBO_L, ROBO_R, ROBO_MRUK = 4, 5, 6, 7
local E_CLOSED, E_OPEN, E_ROBO = 9, 10, 11
local AUX = 128

class("Renderer").extends()

function Renderer:init()
    self.scrollPx   = 0                   -- cur_pos: viewport top in cave pixels (0..MAX_SCROLL)
    self.scrollDir  = 0                   -- scroll_dir: -1 up / +1 down / 0 idle
    self.scrollCount = 0                  -- scroll_count: steps remaining in the current pan
    self.counter = 0                      -- global anim tick (cf. PLAY.CPP cntr)
    self.robo_step = 0                    -- Robbo walk-cycle phase (PLAY.CPP robo_step)
    self.group = "a"                      -- cave group letter for WALL/BOX art
    self.tiles = gfx.imagetable.new("images/bank")   -- bank-table-16-16.png
    self.font = nil                       -- set lazily in drawStatus
end

-- Cave group letter for per-level themed WALL/BOX art (update_defs() in DOS):
-- group = chr('a' + (cave-1)//4). Full edition: caves 1-4 -> 'a', ... 57-60 -> 'o'.
-- 15 groups (a..o) baked into the bank; GroupDefs in defs.lua holds their offsets.
function Renderer:setCaveGroup(caveNum)
    local idx = ((caveNum - 1) // 4) % 15     -- a..o for the 60-cave full edition
    self.group = string.char(string.byte("a") + idx)
end

-- initScroll(pos): snap the viewport so Robbo starts roughly centred at cave
-- load (no catch-up pan). pos is Robbo's cell index — the DOS margin test uses
-- robo_pos directly as a scanline value (roboRow*16 + roboCol), so we do too.
-- Aligned to SCROLL_STEP so the pan always lands exactly on 0 / MAX_SCROLL.
function Renderer:initScroll(pos)
    local px = pos - (VIEW_ROWS * TILE) // 2
    px = math.max(0, math.min(MAX_SCROLL, px))
    self.scrollPx = px - (px % SCROLL_STEP)
    self.scrollDir = 0
    self.scrollCount = 0
end

-- updateScroll(pos): one render-frame tick of DISPLAY.CPP::scroll(). When Robbo
-- enters the MARGIN band it triggers a SCROLL_SIZE-tile pan; each frame then
-- advances scrollPx by SCROLL_STEP px toward it — smooth 2px-per-frame scroll.
-- Faithful to the DOS cur_pos / scroll_dir / scroll_count state machine (minus
-- the VGA vblank gate, which is the render frame here).
function Renderer:updateScroll(pos)
    if self.scrollCount == 0 then
        if pos < self.scrollPx + MARGIN * TILE then
            self.scrollDir = -1
            self.scrollCount = SCROLL_COUNT_INIT
        elseif pos > self.scrollPx + VIEW_ROWS * TILE - MARGIN * TILE then
            self.scrollDir = 1
            self.scrollCount = SCROLL_COUNT_INIT
        end
    end
    if self.scrollCount > 0 then
        if self.scrollDir == -1 and self.scrollPx <= 0 then
            self.scrollPx = 0; self.scrollCount = 0
        elseif self.scrollDir == 1 and self.scrollPx >= MAX_SCROLL then
            self.scrollPx = MAX_SCROLL; self.scrollCount = 0
        else
            self.scrollPx = self.scrollPx + self.scrollDir * SCROLL_STEP
            self.scrollCount = self.scrollCount - 1
        end
    end
end

-- frameFor(obj, status, counter, group, robo_step): resolve the bank-tile index
-- for one cell, porting DISPLAY.CPP's displays[] procedures. counter is the anim
-- tick; robo_step is Robbo's walk-cycle phase. `group` is the cave-group letter
-- selecting per-level WALL/BOX themed art (GroupDefs[group][2]/[5]); other
-- objects use the base DEFS table. Returns nil if no tile is available.
local function frameFor(obj, status, counter, group, robo_step)
    -- Base index for an object: group-themed for WALL/BOX, DEFS otherwise.
    local function base(objKey)
        if (objKey == OBJ.WALL or objKey == OBJ.BOX) and group then
            local gd = GroupDefs[group]
            if gd then return gd[objKey] end
        end
        return DEFS[objKey]
    end
    local function frame(objKey, frameIdx)
        local b = base(objKey)
        if not b then return nil end
        return b + frameIdx
    end

    if obj == OBJ.ROBO then                                   -- robocik()
        if status == ROBO_S then return frame(0, 0) end
        if status == ROBO_L then return frame(0, 20) end      -- 5*4
        if status == ROBO_R then return frame(0, 21) end      -- 5*4+1
        if ROBO_MRUK <= status and status <= ROBO_MRUK + 3 then
            return frame(0, status - ROBO_MRUK)
        end
        return frame(0, 4 + status * 4 + (robo_step & 3))      -- robocik() default
    end

    -- The displays[] table: each entry is the frame arg to PUT_SPRITE(obj, f).
    -- std_proc -> f=0; gun_/next -> f=status; stwor -> status*4+(counter&3); etc.
    if obj == OBJ.B_WALL then return frame(obj, status) end    -- next()
    if obj == OBJ.BOX   then return frame(obj, status) end     -- gun_()
    if obj == OBJ.EXTRA then return frame(obj, status & 7) end -- extra_()
    if obj == OBJ.TELE  then                                   -- ping_pong()
        local f = (counter & 4) ~= 0 and (3 - (counter & 3)) or (counter & 3)
        return frame(obj, f)
    end
    if obj == OBJ.L_GUARD or obj == OBJ.R_GUARD then           -- stwor()
        return frame(obj, status * 4 + (counter & 3))
    end
    if obj == OBJ.MOV_BAT or obj == OBJ.PIF_BAT then           -- ping_pong()
        local f = (counter & 4) ~= 0 and (3 - (counter & 3)) or (counter & 3)
        return frame(obj, f)
    end
    if obj == OBJ.EYES then return frame(obj, status) end      -- eyes_()
    if obj == OBJ.GUN or obj == OBJ.LASER or obj == OBJ.BLASTER
        or obj == OBJ.ROT_GUN then return frame(obj, status) end  -- gun_()
    if obj == OBJ.MOV_GUN then return frame(obj, 0) end        -- mov_gun_()
    if obj == OBJ.EXPLOSION then return frame(obj, status & 0xFF) end  -- explo()
    if obj == OBJ.MAGNET then                                  -- magnet()
        return frame(obj, status == L and 0 or 1)
    end
    if obj == OBJ.EXIT then                                   -- exit_proc()
        if status == E_CLOSED then return frame(obj, 0) end
        if status == E_ROBO then return frame(obj, 1 + 4 + (counter & 7)) end
        return frame(obj, 1 + (counter & 3))
    end
    if obj == OBJ.GUN_SHOT then                               -- gunshot_()
        return frame(obj, status == AUX and 0 or 1)
    end
    if obj == OBJ.LASER_SHOT then return frame(obj, status & 1) end  -- las()
    if obj == OBJ.BLASTER_SHOT then return frame(OBJ.EXPLOSION, 0) end -- blast_head()
    if obj == OBJ.CREATE then                                  -- creat_()
        return frame(OBJ.EXPLOSION, (status & 0xF000) >> 12)
    end
    if obj == OBJ.E_LIFE then                                  -- ping_pong()
        local f = (counter & 4) ~= 0 and (3 - (counter & 3)) or (counter & 3)
        return frame(obj, f)
    end
    if obj == OBJ.BARRIER then                                -- bariera()
        if status == L or status == R then return frame(OBJ.WALL, 0) end
        return frame(obj, counter & 7)
    end
    -- WALL: std_proc -> frame 0 of the per-level themed wall set.
    if obj == OBJ.WALL then return frame(obj, 0) end
    -- Everything else (GRASS, KEY, BOMB, SCREW, AMMO, PUSH, DOOR, CREATE):
    -- std_proc / frame 0.
    return frame(obj, 0)
end

-- draw(cave): blit every visible cell into the playfield region.
function Renderer:draw(cave)
    -- Clear only the playfield region (the status panel is drawn separately).
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(PLAYFIELD_X, PLAYFIELD_Y, PLAYFIELD_W, PLAYFIELD_H)

    local counter = self.counter
    local group = self.group
    local robo_step = self.robo_step
    local firstRow = self.scrollPx // TILE
    local subOff   = self.scrollPx % TILE         -- 0..15: how far the top row is scrolled off

    -- Full redraw of all visible non-SPACE cells. (The DOS engine only redrew
    -- !call cells, relying on a persistent WORK buffer; we clear+redraw each
    -- frame, so the call[] flag must NOT gate drawing — it's a sim flag only.)
    -- Draw VIEW_ROWS+1 rows shifted up by subOff for sub-tile smooth scroll;
    -- clip to the playfield so partial top/bottom rows don't bleed into the top
    -- margin or the status panel.
    gfx.setClipRect(PLAYFIELD_X, PLAYFIELD_Y, PLAYFIELD_W, PLAYFIELD_H)
    for vy = 0, VIEW_ROWS do
        local row = firstRow + vy
        if row >= 0 and row < Y_SIZE then
            local screenY = PLAYFIELD_Y + vy * TILE - subOff
            local base = row * X_SIZE
            for x = 0, X_SIZE - 1 do
                local obj = cave.map[base + x]
                if obj ~= OBJ.SPACE then
                    local idx = frameFor(obj, cave.status[base + x], counter, group, robo_step)
                    if idx then
                        -- bank tile indices are 0-based; Playdate imagetable is 1-based.
                        local img = self.tiles:getImage(idx + 1)
                        if img then
                            img:draw(PLAYFIELD_X + x * TILE, screenY)
                        end
                    end
                end
            end
        end
    end
    gfx.clearClipRect()
end

-- drawStatus(game): text-only HUD in the bottom panel (STATUS_H=64). Full
-- icon-based display_info() port is a later polish stage; for now, text lines.
function Renderer:drawStatus(game)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, STATUS_Y, SCREEN_W, STATUS_H)
    if not self.font then self.font = gfx.getFont() end
    gfx.setFont(self.font)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)

    local line1 = string.format("CAVE %02d   SCREWS %02d   AMMO %02d",
                                game.caveNum, game.screws, game.ammo)
    local line2 = string.format("KEYS %d   LIVES %d", game.keys, game.lives)
    gfx.drawText(line1, PLAYFIELD_X, STATUS_Y + 10)
    gfx.drawText(line2, PLAYFIELD_X, STATUS_Y + 30)

    gfx.setImageDrawMode(gfx.kDrawModeCopy)   -- reset
end
