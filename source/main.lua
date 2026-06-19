-- Robbo for Playdate — entry point.
--
-- Boots the CoreLibs we rely on, then hands control to the game state machine
-- in game.lua. Keep this file thin: bootstrapping only, no game logic.

import "CoreLibs/object"
import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/timer"

import "constants"
import "game"

local pd <const> = playdate

pd.display.setRefreshRate(REFRESH_RATE)   -- fixed render rate; sim steps off it

-- Seed Lua's RNG so the random title-tune pick (title vs kodowa) varies across
-- boots. getSecondsSinceEpoch is the device wall clock; guard for headless runs.
if pd.getSecondsSinceEpoch then
    math.randomseed(pd.getSecondsSinceEpoch())
end

local game = Game()

function pd.update()
    game:update()
    pd.timer.updateTimers()
end
