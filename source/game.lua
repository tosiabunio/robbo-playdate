-- Top-level game state machine, ported from ROBBO_C/ROBBO.CPP (robbo_main)
-- and PLAY.CPP (play). Drives the screen flow: title -> play -> complete/over.
--
-- Run state (cave number, ammo, keys, screws, lives) mirrors the globals in
-- ROBBO.CPP and is shared with the engine via cave.game. The per-frame cave
-- simulation lives in cave.lua (Cave:step); this object owns the high-level
-- flow, input, timing, and the inter-cave transitions from robbo_main's loop.

import "constants"
import "cave"
import "render"
import "sounds"
import "title"
import "save"

local pd <const> = playdate
local gfx <const> = pd.graphics

-- Screen states (cf. the title/play branches of robbo_main(); copy-protection /
-- code-entry screens from the original are dropped — full edition, no protection).
STATE = { TITLE = 1, PLAY = 2, COMPLETE = 3, GAME_OVER = 4 }

local START_LIVES <const> = 4   -- ROBBO.CPP:1634 (lives=4 on new game)

-- "Press any button to play": the d-pad + A/B (the crank/menu are not gameplay).
local START_BUTTONS <const> = {
    pd.kButtonA, pd.kButtonB,
    pd.kButtonUp, pd.kButtonDown, pd.kButtonLeft, pd.kButtonRight,
}

local function anyButtonJustPressed()
    for _, b in ipairs(START_BUTTONS) do
        if pd.buttonJustPressed(b) then return true end
    end
    return false
end

class("Game").extends()

function Game:init()
    self.cave     = Cave()
    self.renderer = Renderer()
    self.cave.game = self            -- engine reads/writes ammo/keys/screws/lives

    self.caveNum    = 0
    self.ammo       = 0
    self.keys       = 0
    self.screws     = 0
    self.lives      = START_LIVES
    self.extraTaken = false          -- E_LIFE collected this cave (extra_taken)

    self.simFrame = 0                -- fixed-timestep divider counter
    self.restartRequested = false    -- "Restart level" menu item -> self-destruct
    self.crankAccum = 0              -- accumulated crank rotation for debug cave-skip
    self.state = STATE.TITLE
    self.titleSong = nil             -- chosen randomly on each title visit
    self.titleCredits = TitleCredits(self.renderer)   -- title + fly-in credits
    self.endImg = { complete = nil, over = nil }      -- loaded lazily
    loadSounds()
    self:setupMenu()
end

-- System-menu (the Playdate menu button) extras.
function Game:setupMenu()
    if not pd.getSystemMenu then return end           -- absent in headless runs
    local menu = pd.getSystemMenu()
    -- "Reset progress" clears the saved planet so the next new game starts back on
    -- cave 1. Does not interrupt a cave in progress -- only where the *next* run begins.
    menu:addMenuItem("Reset progress", function()
        Save.reset()
    end)
    -- "Restart level" replaces the old B-button self-destruct (Esc): blow up Robbo,
    -- lose a life, replay the cave (game over at 0 lives). Only meaningful mid-play;
    -- the flag is consumed by updatePlay's next sim step.
    menu:addMenuItem("Restart level", function()
        if self.state == STATE.PLAY then self.restartRequested = true end
    end)
end

function Game:update()
    if self.state == STATE.TITLE then
        self:updateTitle()
    elseif self.state == STATE.PLAY then
        self:updatePlay()
    elseif self.state == STATE.COMPLETE then
        playSong("complete")     -- song(3) in robbo_main on finishing the game
        self:updateEndScreen("complete", "CONGRATULATIONS!  Press A")
    elseif self.state == STATE.GAME_OVER then
        playSong("over")         -- song(2) in robbo_main on game over
        self:updateEndScreen("over", "Press A")
    end
end

-- The title screen alternates between the title tune and the (otherwise unused)
-- kodowa tune. The original toggled them deterministically (mus_num, ROBBO.CPP
-- :1236); we pick randomly, once per title visit (titleSong cleared on cave start
-- so the next visit re-rolls). playSong is idempotent, so holding on the title
-- screen does not restart the chosen song.
local TITLE_SONGS <const> = { "title", "kodowa" }

function Game:updateTitle()
    if not self.titleSong then
        self.titleSong = TITLE_SONGS[math.random(#TITLE_SONGS)]
    end
    playSong(self.titleSong)
    -- Drive the credits animation (fly-in/fly-out port of scroll_in/scroll_out).
    self.titleCredits:update()
    self.titleCredits:draw()
    -- "Press any button to play": any button aborts the credits at any point and
    -- starts a new game from the first unfinished planet (Save.firstUnfinished).
    if anyButtonJustPressed() then
        self.lives = START_LIVES
        self:startNewCave(Save.firstUnfinished())
    end
end

-- DONE path (robbo_main): fresh cave, extra_taken cleared, run-state reset.
function Game:startNewCave(num)
    self.caveNum = num
    self.cave:load(num)
    self.extraTaken = false
    self.titleSong = nil             -- re-roll the title tune for the next visit
    self:resetRunState()
end

-- DEAD path (robbo_main else-branch): restore the cave-start snapshot; if an
-- extra life was taken this attempt, that E_LIFE stays gone (ROBBO.CPP:1687).
-- Lives are decremented by the caller; run-state is otherwise reset.
function Game:replayCave()
    self.cave:load(self.caveNum)
    if self.extraTaken then
        local map = self.cave.map
        for i = 0, MAP_SIZE - 1 do
            if map[i] == OBJ.E_LIFE then map[i] = OBJ.SPACE end
        end
    end
    self:resetRunState()
end

-- Per-cave run-state init (ROBBO.CPP:1702-1709): ammo/keys reset to 0; screws =
-- count of SCREW objects in the cave (collect them all to open the exit). Lives
-- persist. Caves 27 & 52 legitimately start at 0 screws (hidden in EXTRAs).
function Game:resetRunState()
    self.ammo = 0
    self.keys = 0
    self.screws = 0
    for i = 0, MAP_SIZE - 1 do
        if self.cave.map[i] == OBJ.SCREW then
            self.screws = self.screws + 1
        end
    end
    self.renderer:setCaveGroup(self.caveNum)
    self.renderer:initScroll(self.cave.robo_pos)
    self.simFrame = 0
    self.restartRequested = false    -- drop any pending menu restart on a fresh cave
    self.state = STATE.PLAY

    -- Wipe the title/credits art: the play renderer only repaints the centered
    -- playfield and status panel, so the side/top margins keep whatever was on
    -- screen unless we clear the whole framebuffer once on entering gameplay.
    gfx.clear(gfx.kColorBlack)

    -- Music is menu-only: stop it as gameplay begins (the original lets the first
    -- cave SFX cut the song off on the shared channel; we stop it explicitly).
    stopSong()

    -- Cave-start prompt (play(), PLAY.CPP:1151): "collect all bolts" if any are
    -- present, else "find the way out" (the 0-screw caves 27/52).
    SOUND(self.screws > 0 and SFX.ZBIERZ_SRUBY or SFX.ODSZUKAJ)
end

-- Debug-only cave jump (crank). Clamps to [1, CAVES] and (re)starts that cave
-- fresh, preserving lives. Does NOT mark caves finished, so the save's
-- first-unfinished pointer is untouched -- a dev shortcut, not progression.
function Game:debugSwitchCave(delta)
    local target = math.max(1, math.min(CAVES, self.caveNum + delta))
    if target ~= self.caveNum then self:startNewCave(target) end
end

-- One debug cave-skip per full crank revolution (360 deg; clockwise = +1,
-- counter-clockwise = -1). The crank is otherwise unused in gameplay.
local CRANK_STEP_DEG <const> = 360

function Game:updatePlay()
    -- Debug level-skip via the crank (otherwise unused in gameplay): rotate to
    -- jump caves, one per full revolution (CRANK_STEP_DEG, clockwise = +1, ccw = -1).
    -- getCrankChange is absent in headless runs, so guard on it.
    if pd.getCrankChange and not (pd.isCrankDocked and pd.isCrankDocked()) then
        self.crankAccum = self.crankAccum + pd.getCrankChange()
        local step = 0
        while self.crankAccum >=  CRANK_STEP_DEG do self.crankAccum = self.crankAccum - CRANK_STEP_DEG; step = step + 1 end
        while self.crankAccum <= -CRANK_STEP_DEG do self.crankAccum = self.crankAccum + CRANK_STEP_DEG; step = step - 1 end
        if step ~= 0 then
            self:debugSwitchCave(step)
            return
        end
    end

    -- Fixed timestep: step the sim once every SIM_FRAME_DIV display frames so
    -- movement cadence is deterministic regardless of render fps.
    self.simFrame = self.simFrame + 1
    if self.simFrame >= SIM_FRAME_DIV then
        self.simFrame = 0
        local input = {
            up    = pd.buttonIsPressed(pd.kButtonUp),
            right = pd.buttonIsPressed(pd.kButtonRight),
            down  = pd.buttonIsPressed(pd.kButtonDown),
            left  = pd.buttonIsPressed(pd.kButtonLeft),
            fire  = pd.buttonIsPressed(pd.kButtonA),          -- SpaceBar/Ins
            selfdestruct = self.restartRequested,             -- "Restart level" menu item
        }
        self.restartRequested = false
        self.cave:step(input)
        if self.cave.cont == 0 then
            self:endCave(self.cave.stop_cond)
            return
        end
    end

    -- Render every display frame; scroll advances 2px/frame (decoupled from the
    -- 7.5 Hz sim) for smooth panning.
    self.renderer.counter   = self.cave.counter
    self.renderer.robo_step = self.cave.robo_step
    self.renderer:updateScroll(self.cave.robo_pos)
    self.renderer:draw(self.cave)
    self.renderer:drawStatus(self)
end

-- End-of-cave transition (robbo_main's switch on game_status, ROBBO.CPP:1722).
function Game:endCave(reason)
    if reason == REASON.DONE then
        Save.markFinished(self.caveNum)   -- persist the just-cleared planet
        self.caveNum = self.caveNum + 1
        if self.caveNum > CAVES then
            self.state = STATE.COMPLETE
        else
            self:startNewCave(self.caveNum)
        end
    else  -- DEAD / ESC
        if self.lives > 0 then
            self.lives = self.lives - 1
            self:replayCave()
        else
            self.state = STATE.GAME_OVER
        end
    end
end

function Game:updateEndScreen(image, headline)
    -- End-screen art (COMPLETE.BMP / OVER.BMP, dithered) + a centered headline.
    if image and not self.endImg[image] then
        self.endImg[image] = gfx.image.new("images/" .. image)
    end
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
    if self.endImg[image] then self.endImg[image]:draw(8, 0) end
    if headline and headline ~= "" then
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        gfx.drawTextAligned(headline, SCREEN_W // 2, SCREEN_H // 2 + 30,
                            kTextAlignment.center)
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
    end
    if pd.buttonJustPressed(pd.kButtonA) then
        self.titleCredits:reset()        -- replay credits on the next title visit
        self.state = STATE.TITLE
    end
end

