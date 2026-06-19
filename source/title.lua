-- Title screen: the converted TITLE.BMP art (the ROBBO robot scene) with the
-- fly-in credits over a black bar at the bottom. Ported from ROBBO.CPP
-- scroll_in/scroll_out (749-997) + disp_line (711-732).
--
-- The original flew each credit's LETTERS in from above with per-letter random
-- velocities, OVER the colour title picture (CRT colour kept them legible). In
-- 1-bit the dithered picture and white glyphs collide, and the original DOS rest
-- rows (y=168/196 on a 200px screen) fall off the 240px Playdate screen. So the
-- port keeps the fly-in animation and the original velocity formulas, draws the
-- title art as the backdrop, and lands the two credit lines on a black readability
-- bar across the bottom (robot stays fully visible above it). The glyph font is
-- rendered solid into its own 24x24 imagetable (build_playdate_assets.py) at the
-- font's native cell size, so the letters keep their full height.

import "CoreLibs/graphics"
import "constants"
import "defs"     -- LETTER_BASE, CHAR_TO_SPRITE

local gfx <const> = playdate.graphics

-- Layout (mirrors tools/preview_title_credits.py).
local STRIDE      <const> = 24                   -- px between letter cells (24x24 glyphs)
local REST_Y0     <const> = 140                  -- top credit line rest Y
local REST_Y1     <const> = 170                  -- bottom credit line rest Y
local MAX_CHARS   <const> = 24
local OFF_X       <const> = SCREEN_W + 16
local OFF_Y       <const> = SCREEN_H + 16
local HOLD_FRAMES <const> = 75                   -- ~2.5s @30fps hold per credit

-- 8 credit pairs (ENGLISH.TXT !title!..!title_end!). Lowercase: the glyph bank
-- maps a-z (char_to_sprite lowercases; the credits text is lowercase).
local CREDITS <const> = {
    { "a puzzle game",     ""      },
    { "designed by",      "janusz pelc"      },
    { "programmed by",    "maciej miasik"    },
    { "and",              "janusz pelc"      },
    { "graphics by",      "janusz pelc"      },
    { "music by",         "boguslaw pezda"   },
    { "produced by",      "marek kubowicz"   },
    { "voice",            "marty jastrebsky" },
}
local FINAL_SCREEN <const> = { "press any button", "to play" }

local function rnd(n) return math.random(n) - 1 end   -- 0..n-1

-- disp_line (ROBBO.CPP:711): centre a line and set each letter's rest position.
-- Letters with sprite<=1 (space/blank) are excluded from the active list.
local function dispLine(line, isBottom)
    local n = #line
    local x0 = (SCREEN_W - n * STRIDE) // 2
    local restY = isBottom and REST_Y1 or REST_Y0
    local active = {}
    for i = 1, math.min(n, MAX_CHARS) do
        local sp = CHAR_TO_SPRITE[line:byte(i) + 1] or 0
        if sp > 1 then
            table.insert(active, {
                sprite = sp,
                x = x0 + (i - 1) * STRIDE,
                restY = restY,
                xs = 0, ys = 0,
            })
        end
    end
    return active
end

-- Seed velocities per ROBBO.CPP:765-770, then negate (so the letter moves toward
-- its rest row from off-screen-up). The C runs a no-draw phase-A then negates; we
-- negate immediately for the visible settle-only motion.
local function seedForFlyIn(letters)
    for _, lt in ipairs(letters) do
        local sign = (rnd(2) == 1) and 1 or -1
        lt.xs = -(sign * (4 * rnd(5) + 16) * (rnd(5) ~= 0 and 1 or 0))
        lt.ys = 16 + 4 * rnd(5)          -- negated -> positive (downward)
        lt.x = lt.x - lt.xs * 8          -- start several steps above the rest row
        lt.y = lt.restY - lt.ys * 8      -- so it flies down into place
    end
end

-- Seed for fly-OUT (ROBBO.CPP:917-920, un-negated): letters leave upward/sideways.
local function seedForFlyOut(letters)
    for _, lt in ipairs(letters) do
        local sign = (rnd(2) == 1) and 1 or -1
        lt.xs = sign * (4 * rnd(5) + 16) * (rnd(5) ~= 0 and 1 or 0)
        lt.ys = -16 - 4 * rnd(5)         -- upward
    end
end

class("TitleCredits").extends()

function TitleCredits:init(renderer)
    -- The credit font lives in its OWN 24x24 imagetable (letters-table-24-24.png),
    -- not the 16x16 game bank -- the glyphs are authored at the full 24x24 cell.
    self.glyphs = gfx.imagetable.new("images/letters")
    self.titleImg = gfx.image.new("images/title")   -- converted TITLE.BMP scene
    self:reset()
end

function TitleCredits:reset()
    self.pairIdx = 1
    self.phase = "settle"            -- settle -> hold -> flyout -> next
    self.holdTimer = 0
    self.finalScreen = false
    self.letters = {}
    self:startPair()
end

function TitleCredits:startPair()
    local pair = self.finalScreen and FINAL_SCREEN or CREDITS[self.pairIdx]
    if not pair then self.phase = "final"; return end
    self.letters = {}
    for _, l in ipairs(dispLine(pair[1], false)) do table.insert(self.letters, l) end
    for _, l in ipairs(dispLine(pair[2], true))  do table.insert(self.letters, l) end
    seedForFlyIn(self.letters)
    self.phase = "settle"
    self.holdTimer = 0
end

-- Advance one animation frame. Call :draw() afterward.
function TitleCredits:update()
    if self.phase == "final" then return end

    if self.phase == "settle" then
        local allSettled = true
        for _, lt in ipairs(self.letters) do
            local prevY = lt.y
            lt.x = lt.x + lt.xs
            lt.y = lt.y + lt.ys
            -- Settle on reaching/passing the rest row (clamp so we never overshoot).
            if lt.y == lt.restY or (prevY < lt.restY and lt.y >= lt.restY) then
                lt.y = lt.restY
                lt.xs, lt.ys = 0, 0
            else
                allSettled = false
            end
        end
        if allSettled then
            self.phase = self.finalScreen and "final" or "hold"
        end
        return
    end

    if self.phase == "hold" then
        self.holdTimer = self.holdTimer + 1
        if self.holdTimer >= HOLD_FRAMES then
            if self.finalScreen then     -- final screen holds until a button (game.lua)
                self.phase = "final"
            else
                seedForFlyOut(self.letters)
                self.phase = "flyout"
            end
        end
        return
    end

    if self.phase == "flyout" then
        local anyVisible = false
        for _, lt in ipairs(self.letters) do
            lt.x = lt.x + lt.xs
            lt.y = lt.y + lt.ys
            if lt.x >= OFF_X or lt.y >= OFF_Y or lt.y < -16 or lt.x < -16 then
                lt.sprite = 0            -- retire (sprite<=1 = inactive)
            else
                anyVisible = true
            end
        end
        if not anyVisible then self:advance() end
    end
end

function TitleCredits:advance()
    self.pairIdx = self.pairIdx + 1
    if self.pairIdx > #CREDITS then
        -- Final hold screen ("press any button to play"): fly in, settle, hold.
        self.finalScreen = true
        self.letters = {}
        for _, l in ipairs(dispLine(FINAL_SCREEN[1], false)) do table.insert(self.letters, l) end
        for _, l in ipairs(dispLine(FINAL_SCREEN[2], true))  do table.insert(self.letters, l) end
        seedForFlyIn(self.letters)
        self.phase = "settle"
        self.holdTimer = 0
    else
        self:startPair()
    end
end

-- Draw the title art + the current credit letters (solid black glyphs over the
-- art). Clears to black first so the art's transparent (black) areas don't keep
-- stale pixels and moving letters leave no trails.
function TitleCredits:draw()
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
    if self.titleImg then self.titleImg:draw(8, 0) end   -- 384-wide art, centred

    for _, lt in ipairs(self.letters) do
        if lt.sprite > 1 then
            local img = self.glyphs:getImage(LETTER_BASE + lt.sprite + 1)
            if img then img:draw(lt.x, lt.y) end
        end
    end
end
