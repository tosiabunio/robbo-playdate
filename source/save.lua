-- Progress persistence. Robbo's "caves" are planets; we persist the number of
-- the last *finished* planet so a new game resumes at the first unfinished one.
-- Backed by playdate.datastore (a small JSON blob in the game's save folder).
--
-- Exposes a global `Save` table (the project uses globals, not module returns --
-- `import` does not capture return values the way `require` would).

import "constants"

local datastore <const> = playdate.datastore

local SAVE_FILE <const> = "robbo"   -- -> Data/<bundleid>/robbo.json on device

Save = {}

-- Read-modify-write so independent fields (progress, settings) don't clobber
-- each other in the shared save blob.
local function load()
    local data = datastore.read(SAVE_FILE)
    if type(data) ~= "table" then data = {} end
    return data
end

local function store(key, value)
    local data = load()
    data[key] = value
    datastore.write(data, SAVE_FILE)
end

-- Last finished cave/planet number (0 == nothing finished yet / no save).
function Save.lastFinished()
    local data = load()
    if type(data.lastFinished) == "number" then
        -- Clamp defensively against a corrupt/edited save.
        return math.max(0, math.min(CAVES, math.floor(data.lastFinished)))
    end
    return 0
end

-- The first cave a new game should start on: the planet right after the last
-- finished one, wrapping back to cave 1 once every planet has been cleared.
function Save.firstUnfinished()
    local next = Save.lastFinished() + 1
    if next > CAVES then return 1 end
    return next
end

-- Record that `caveNum` was completed. Monotonic: a replay of an earlier planet
-- never lowers the saved high-water mark.
function Save.markFinished(caveNum)
    if caveNum > Save.lastFinished() then
        store("lastFinished", caveNum)
    end
end

-- Wipe progress (the "Reset progress" system-menu item).
function Save.reset()
    store("lastFinished", 0)
end

-- "Invert display" system-menu setting (persisted across launches).
function Save.inverted()
    return load().inverted == true
end

function Save.setInverted(on)
    store("inverted", on == true)
end
