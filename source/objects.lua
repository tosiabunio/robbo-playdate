-- Per-object interaction tables, ported from the top of ROBBO_C/PLAY.CPP.
--
-- These are indexed by object type (OBJ.*). The original C arrays are 0-based
-- and dense; here we build 0-keyed Lua tables so OBJ values index directly.
--
-- explode[o] : does this object blow up when caught in an explosion?
-- shoot[o]   : can this object be destroyed by a shot?
-- kill[o]    : does this object kill Robbo on contact?

import "constants"
import "sounds"     -- SFX ids used by EXTRA_SOUNDS below

local function tbl(values)
    -- values is the original 0..MAX_OBJECTS-1 sequence, written 1-based here.
    local t = {}
    for i = 1, #values do t[i - 1] = values[i] end
    return t
end

-- ROBO SPACE WALL B_WALL GRASS BOX KEY BOMB EXTRA SCREW AMMO PUSH DOOR TELE
-- L_GUARD R_GUARD MOV_BAT PIF_BAT EYES GUN LASER BLASTER ROT_GUN MOV_GUN
-- EXPLOSION MAGNET EXIT GUN_SHOT LASER_SHOT BLASTER_SHOT E_LIFE BARRIER CREATE

EXPLODE = tbl{
    1,1,0,0,1,1,1,1,
    1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,
    0,0,1,0,0,0,1,1,
    0,
}

SHOOT = tbl{
    1,0,0,0,1,0,0,1,
    1,0,1,0,0,0,1,1,
    1,1,1,0,0,0,0,0,
    0,0,0,0,0,0,1,1,
    0,
}

KILL = tbl{
    0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,1,1,
    1,1,1,0,0,0,0,0,
    0,0,0,0,0,0,0,0,
    0,
}

-- Contents of a randomly-revealed EXTRA / surprise (PLAY.CPP extras[32], lines
-- 40-52). test_to_kill() rolls random(32) and reveals EXTRAS[roll]. Logic-
-- critical, so ported now. 0-keyed to match the C array's random(32) index.
-- ROBO ROBO EXTRA EXTRA AMMO*4 KEY*3 SCREW*5 EYES*2 BOMB*2 E_LIFE*5
-- EXPLOSION*2 EXIT ROT_GUN*4
EXTRAS = tbl{
    OBJ.ROBO, OBJ.ROBO,
    OBJ.EXTRA, OBJ.EXTRA,
    OBJ.AMMO, OBJ.AMMO, OBJ.AMMO, OBJ.AMMO,
    OBJ.KEY, OBJ.KEY, OBJ.KEY,
    OBJ.SCREW, OBJ.SCREW, OBJ.SCREW, OBJ.SCREW, OBJ.SCREW,
    OBJ.EYES, OBJ.EYES,
    OBJ.BOMB, OBJ.BOMB,
    OBJ.E_LIFE, OBJ.E_LIFE, OBJ.E_LIFE, OBJ.E_LIFE, OBJ.E_LIFE,
    OBJ.EXPLOSION, OBJ.EXPLOSION,
    OBJ.EXIT,
    OBJ.ROT_GUN, OBJ.ROT_GUN, OBJ.ROT_GUN, OBJ.ROT_GUN,
}

-- extra_sounds[32] (PLAY.CPP:54-66) — the SFX id played for each EXTRA reveal,
-- in lockstep with EXTRAS above (same random(32) roll indexes both). test_to_kill
-- plays SOUND(EXTRA_SOUNDS[xtr]); 0-keyed to match the C array's index.
EXTRA_SOUNDS = tbl{
    SFX.N_SUPER, SFX.N_SUPER,
    SFX.N_NIES, SFX.N_NIES,
    SFX.N_BAT, SFX.N_BAT, SFX.N_BAT, SFX.N_BAT,
    SFX.N_KLUCZ, SFX.N_KLUCZ, SFX.N_KLUCZ,
    SFX.N_SRUBA, SFX.N_SRUBA, SFX.N_SRUBA, SFX.N_SRUBA, SFX.N_SRUBA,
    SFX.N_OKO, SFX.N_OKO,
    SFX.N_BOMBA, SFX.N_BOMBA,
    SFX.N_EXTRA, SFX.N_EXTRA, SFX.N_EXTRA, SFX.N_EXTRA, SFX.N_EXTRA,
    SFX.N_HLE, SFX.N_HLE,
    SFX.N_EXIT,
    SFX.N_GUN, SFX.N_GUN, SFX.N_GUN, SFX.N_GUN,
}
