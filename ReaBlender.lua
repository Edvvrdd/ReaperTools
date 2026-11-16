-- @description ReaBlender
-- @author Ed
-- @version 1.0.0
-- @provides [main] .
-- [effect] SoundDesignTools/ReaBlender_Filter.jsfx
-- [effect] SoundDesignTools/ReaBlender_Brain.jsfx
-- [effect] SoundDesignTools/ReaBlender_Visualizer.jsfx
-- @about
--   # ReaBlender — Sound/Dev/Ed sound design suite
--
--   One-button multiband rig + granular whoosh generator, unified in one UI:
--
--   Run on ONE selected plain track: it becomes a "[ReaBlender] <name>" folder
--   with 4 bucket children ([Sub], [Low-Mid], [High-Mid], [Air]), each filtered
--   by a phase-coherent Linkwitz-Riley 4th-order (24 dB/oct) JSFX and holding a
--   [Grains] sub-track (sub-tracks you add inside a bucket inherit its routing).
--   The parent keeps your FX chain plus ReaBlender_Brain (live whoosh envelope +
--   doppler) and ReaBlender_Visualizer (scope + band meters).
--
--   Two playback modes:
--     Auto-Whoosh  — time selection + Generate: grains scattered from each
--                    bucket's ingredients onto its [Grains] track, envelope and
--                    doppler baked per grain.
--     Live         — looping transport + virtual playhead slider drive the
--                    Brain's master envelope/doppler in real time.
--
--   Crossover sliders locate band filters by walking the rig folder and
--   matching both the FX filename and description name (no GUID storage), and
--   send NATIVE values (Hz) — see find_fx()/apply_crossovers().
--
--   Requires: ReaImGui (install via ReaPack).
-- @changelog
--   v1.0.0
--   - Unified the multiband rig (Create_Or_Sync_Multiband_Rig) and the granular
--     whoosh engine (QikWhoosh) under the ReaBlender suite UI
--   - Robust band-FX identification: exact filename + description matching with
--     ValidatePtr2 guards; TrackFX_SetParam always gets native values
--   - 4-way LR4 split (Sub/Low-Mid/High-Mid/Air), 3 crossovers, live-apply
--   - ReaBlender_Brain.jsfx: master whoosh envelope + doppler over gmem
--   - Auto-Whoosh and Live performance modes; preset + ExtState persistence

local r = reaper

if not r.ImGui_CreateContext then
  r.ShowMessageBox("This script requires ReaImGui (install via ReaPack).", "ReaImGui not found", 0)
  return
end

---------------------------------------------------------------------
-- Config
---------------------------------------------------------------------

local JSFX_DIR    = "/Effects/SoundDesignTools"
local FILTER_FILE = "ReaBlender_Filter.jsfx"
local BRAIN_FILE  = "ReaBlender_Brain.jsfx"
local VISUAL_FILE = "ReaBlender_Visualizer.jsfx"

-- P_EXT keys stored on tracks
local EXT_PARENT = "P_EXT:RB_PARENT"   -- "1" on the rig parent
local EXT_BUCKET = "P_EXT:RB_BUCKET"   -- band mode 0..3 on bucket tracks
local EXT_GRAINS = "P_EXT:RB_GRAINS"   -- "1" on per-bucket grains tracks
local EXT_F1     = "P_EXT:RB_F1"       -- crossovers persist on the parent
local EXT_F2     = "P_EXT:RB_F2"
local EXT_F3     = "P_EXT:RB_F3"

-- ReaBlender_Filter.jsfx slider ranges (must match the JSFX)
local F_MIN = { 20, 100, 1000 }
local F_MAX = { 500, 5000, 20000 }

-- ReaBlender_Brain.jsfx parameter indices (must match its sliders)
local BRAIN_IDX = {
  playhead = 0, peak_pos = 1, hold = 2, rise = 3, fall = 4,
  peak_db = 5, floor_db = 6, doppler = 7, amount = 8,
}

local BANDS = {
  { name = "[Sub]",      mode = 0, u1 = true,  u2 = false, u3 = false,
    rgb = { 110, 90, 230 },  ui = 0x8C74F0FF }, -- violet
  { name = "[Low-Mid]",  mode = 1, u1 = true,  u2 = true,  u3 = false,
    rgb = { 45, 92, 200 },   ui = 0x2D5CC8FF }, -- navy
  { name = "[High-Mid]", mode = 2, u1 = false, u2 = true,  u3 = true,
    rgb = { 230, 160, 40 },  ui = 0xE6A028FF }, -- amber
  { name = "[Air]",      mode = 3, u1 = false, u2 = false, u3 = true,
    rgb = { 64, 217, 242 },  ui = 0x40D9F2FF }, -- cyan
}

-- which crossovers each band mode needs (matched in apply_crossovers)

local PLAYBACK_MODES = { "Forward", "Reverse", "Ping-Pong", "Random" }

---------------------------------------------------------------------
-- Self-deploying JSFX (keep in sync with the standalone .jsfx files)
---------------------------------------------------------------------

local FILTER_SOURCE = [==[
desc:ReaBlender Filter Band (LR4 24 dB/oct 4-way splitter)
//tags: filter multiband crossover sound design band-split reablender
//author: ReaperTools

slider1:0<0,3,1{Sub (LP),Low-Mid (BP),High-Mid (BP),Air (HP)}>Band Mode
slider2:150<20,500,1>Sub/Low-Mid Crossover (Hz)
slider3:2000<100,5000,1>Low-Mid/High-Mid Crossover (Hz)
slider4:8000<1000,20000,1>High-Mid/Air Crossover (Hz)

in_pin:Left Input
in_pin:Right Input
out_pin:Left Output
out_pin:Right Output

// ReaBlender bucket filter. One instance per bucket track. Four modes
// (slider1) build a flat-summing 4-way Linkwitz-Riley split:
//
//   Sub      : LP4  @ f1
//   Low-Mid  : HP4  @ f1  -> LP4 @ f2
//   High-Mid : HP4  @ f2  -> LP4 @ f3
//   Air      : HP4  @ f3
//
// LR4 = two cascaded 2nd-order Butterworth sections (Q = 0.70710678).
// Adjacent bands sharing a cutoff are magnitude-complementary and
// phase-coherent there (-6 dB each, 0 deg relative phase) and sum flat.
//
// gmem layout (shared with ReaBlender_Brain.jsfx / ReaBlender_Visualizer.jsfx):
//   gmem[8192 + mode] : this band's RMS level, updated every 1024 samples
//   gmem[8200..8202]  : Brain playhead / gain / pan (Brain writes)
//
// ponytail: coefficients jump on slider move (can zipper); add smoothing
// only if it audibly matters in the rig.

function bq_run(c, s, x) local(y) (
  // transposed direct-form II biquad
  // c = [b0 b1 b2 a1 a2] (a0-normalized), s = [x1 x2 y1 y2]
  y = c[0]*x + c[1]*s[0] + c[2]*s[1] - c[3]*s[2] - c[4]*s[3];
  s[1] = s[0]; s[0] = x;
  s[3] = s[2]; s[2] = y;
  y;
);

function bq2(c, s, x) (
  // two cascaded biquad stages = 4th order
  x = bq_run(c, s, x);
  bq_run(c, s + 4, x);
);

function mk(c, f, is_lp) local(w0, cw, sw, al, a0) (
  // one 2nd-order Butterworth section (Q = 0.70710678) into c[]
  w0 = 2*$pi*f/srate; cw = cos(w0); sw = sin(w0);
  al = sw*0.70710678; a0 = 1 + al;
  is_lp ? (
    c[0] = (1-cw)*0.5/a0; c[1] = (1-cw)/a0; c[2] = c[0];
  ) : (
    c[0] = (1+cw)*0.5/a0; c[1] = -(1+cw)/a0; c[2] = c[0];
  );
  c[3] = -2*cw/a0; c[4] = (1-al)/a0;
);

function coeffs() local(f1, f2, f3) (
  // keep crossovers ordered no matter how the sliders were dragged
  f1 = slider2;
  f2 = max(slider3, f1);
  f3 = max(slider4, f2);
  slider1 == 0 ? mk(c1, f1, 1)
  : slider1 == 1 ? ( mk(c1, f1, 0); mk(c2, f2, 1); )
  : slider1 == 2 ? ( mk(c1, f2, 0); mk(c2, f3, 1); )
  : mk(c1, f3, 0);
);

@init
c1  = 0;  // stage coefficients [b0 b1 b2 a1 a2]
c2  = 8;
st1 = 16; // stage state: [ch*8 + section*4] -> [x1 x2 y1 y2], 16 words per filter
st2 = 48;
gsum = 0; gcnt = 0;
coeffs(); // re-run here: @slider does not fire on sample-rate changes

@slider
coeffs();

@sample
slider1 == 0 ? ( // Sub: LP4 @ f1
  spl0 = bq2(c1, st1, spl0);
  spl1 = bq2(c1, st1 + 8, spl1);
) : slider1 == 1 ? ( // Low-Mid: HP4 @ f1 -> LP4 @ f2
  spl0 = bq2(c1, st1, spl0);
  spl1 = bq2(c1, st1 + 8, spl1);
  spl0 = bq2(c2, st2, spl0);
  spl1 = bq2(c2, st2 + 8, spl1);
) : slider1 == 2 ? ( // High-Mid: HP4 @ f2 -> LP4 @ f3
  spl0 = bq2(c1, st1, spl0);
  spl1 = bq2(c1, st1 + 8, spl1);
  spl0 = bq2(c2, st2, spl0);
  spl1 = bq2(c2, st2 + 8, spl1);
) : ( // Air: HP4 @ f3
  spl0 = bq2(c1, st1, spl0);
  spl1 = bq2(c1, st1 + 8, spl1);
);

// band energy meter -> gmem[8192 + mode], read by ReaBlender_Visualizer.jsfx
// ponytail: fixed gmem block 8192..8202; move if it ever collides
gsum += spl0*spl0 + spl1*spl1;
gcnt += 1;
gcnt >= 1024 ? (
  gmem[8192 + slider1] = sqrt(gsum * 0.00048828125); // rms over both ch, 1024 samples
  gsum = 0; gcnt = 0;
);
]==]

local BRAIN_SOURCE = [==[
desc:ReaBlender Brain (whoosh envelope + doppler engine)
//tags: envelope doppler automation whoosh sound design reablender
//author: ReaperTools

slider1:0<0,1,0.001>Playhead (0-1)
slider2:0.5<0,1,0.001>Peak Position
slider3:0.08<0,0.5,0.001>Hold
slider4:0.5<-1,1,0.01>Rise Tension
slider5:0.5<-1,1,0.01>Fall Tension
slider6:0<-24,0,0.1>Peak Level (dB)
slider7:-60<-90,-12,0.1>Floor Level (dB)
slider8:0.7<0,1,0.01>Doppler Depth
slider9:1<0,1,0.01>Envelope Amount (0 = transparent)

in_pin:Left Input
in_pin:Right Input
out_pin:Left Output
out_pin:Right Output

// ReaBlender live-performance engine. One instance on the [ReaBlender] parent,
// FIRST in the FX chain (processes the summed bands). Audio passes through the
// master whoosh envelope + doppler pan computed from the playhead slider:
//
//   gain(t) = dB(floor + (peak - floor) * shape(t))   shape = power curve
//   pan(t)  = depth * clamp(2*(t - peak_pos), -1, 1)  (passes L -> R through peak)
//
// Envelope Amount (slider9) bypasses everything when 0: Auto-Whoosh grains
// already carry the baked curve; Live mode sets it to 1.
//
// The ReaBlender.lua UI writes the shape sliders (2..8) when the curve changes
// and drives the playhead (1) every frame, so Lua owns the curve and the Brain
// renders it sample-accurate — no zipper, no per-sample Lua.
//
// gmem layout (shared with ReaBlender_Filter.jsfx / ReaBlender_Visualizer.jsfx):
//   gmem[8192..8195]  : band RMS levels (filters write)
//   gmem[8200]        : playhead 0..1
//   gmem[8201]        : envelope gain (linear)
//   gmem[8202]        : doppler pan -1..1
//
// ponytail: power-curve shape (exponent from tension) not cubic beziers —
// one line in Lua AND EEL, same result; switch if curves ever need an S-bend.

function env_shape(t) local(ps, pe, ea, er) (
  // identical curve to ReaBlender.lua's env_shape()
  ps = max(0, slider2 - slider3*0.5);
  pe = min(1, slider2 + slider3*0.5);
  ea = 2^(slider4*1.5);
  er = 2^(slider5*1.5);
  t <= ps ? ( ps > 0 ? pow(t/ps, ea) : 1 )
  : t >= pe ? ( pe < 1 ? pow((1-t)/(1-pe), er) : 0 )
  : 1;
);

@init
g = 0;  p = 0; // smoothed gain / pan state

@slider
// nothing precomputed; env_shape() is evaluated per sample from sliders

@sample
t = slider1; // playhead 0..1
shape = env_shape(t);
amt = slider9;
gain_db = amt < 0.001 ? 0 : (slider7 + (slider6 - slider7) * shape);
tgt_g = 10^(gain_db * (1/20)); // dB -> linear
tgt_p = amt * slider8 * min(1, max(-1, (t - slider2) * 2));
g += (tgt_g - g) * 0.002; // ~10 ms one-pole, kills param-update zipper
p += (tgt_p - p) * 0.002;

// linear pan: p = +1 hard right, -1 hard left
spl0 = spl0 * g * (1 - max(p, 0));
spl1 = spl1 * g * (1 - max(-p, 0));

gmem[8200] = t;
gmem[8201] = g;
gmem[8202] = p;
]==]

local VISUAL_SOURCE = [==[
desc:ReaBlender Visualizer (band meters + output scope + playhead)
//tags: analyzer visualizer multiband sound design reablender
//author: ReaperTools

in_pin:Left Input
in_pin:Right Input
out_pin:Left Output
out_pin:Right Output

// Place on the [ReaBlender] parent folder, LAST in the FX chain. Audio passes
// through untouched. Reads shared gmem:
//   gmem[8192..8195]  band RMS levels written by ReaBlender_Filter.jsfx
//   gmem[8200..8202]  playhead / envelope gain / doppler pan from ReaBlender_Brain.jsfx
//
// Top: scrolling peak scope of the summed output.
// Middle: band bars  [SUB] violet, [LOW-MID] navy, [HIGH-MID] amber, [AIR] cyan.
// Bottom: live playhead cursor + envelope gain dot.

@init
sc_pos = 0; sc_pk = 0; sc_cnt = 0; // scope ring-buffer state
// disp[3] band-bar display decay, auto-zeroed

@sample
// passthrough: spl read-only, never written
sc_pk = max(sc_pk, max(abs(spl0), abs(spl1)));
sc_cnt += 1;
sc_cnt >= 256 ? (
  buf[sc_pos] = sc_pk;
  sc_pos = (sc_pos + 1) % 256;
  sc_pk = 0; sc_cnt = 0;
);

@gfx
gfx_set(0.08, 0.09, 0.12, 1);
gfx_rect(0, 0, gfx_w, gfx_h, 1);

// -- summed-output scope -------------------------------------------------
scope_h = gfx_h * 0.42;
gfx_set(0.75, 0.82, 0.9, 0.9);
i = 0;
loop(256,
  v = buf[(sc_pos + i) % 256];
  x = (i / 256) * gfx_w;
  gfx_line(x, scope_h - v * scope_h, x, scope_h + v * scope_h);
  i += 1;
);

// -- band bars ------------------------------------------------------------
bar_y = gfx_h * 0.52;
bar_h = min(14, (gfx_h - bar_y - 26) / 4 - 3);
lbl_w = 52;
i = 0;
loop(4,
  v = max(gmem[8192 + i], disp[i] * 0.92); // peak-hold with decay
  disp[i] = v;
  db = 20 * log10(max(v, 0.00001));
  frac = (db + 60) / 60;
  frac < 0 ? frac = 0;
  y = bar_y + i * (bar_h + 3);
  i == 0 ? gfx_set(0.55, 0.45, 0.95, 1)   // SUB     violet
  : i == 1 ? gfx_set(0.18, 0.35, 0.78, 1) // LOW-MID navy
  : i == 2 ? gfx_set(0.92, 0.66, 0.16, 1) // HIGH-MID amber
  : gfx_set(0.25, 0.85, 0.95, 1);         // AIR     cyan
  gfx_rect(0, y, frac * (gfx_w - lbl_w), bar_h, 1);
  gfx_set(0.85, 0.88, 0.92, 0.9);
  gfx_x = gfx_w - lbl_w + 6;
  gfx_y = y + bar_h * 0.5 - 6;
  gfx_drawnumber(db, 1);
  i += 1;
);

// -- live playhead + envelope ---------------------------------------------
ph = min(max(gmem[8200], 0), 1);
env = min(max(gmem[8201], 0), 4);
pan = min(max(gmem[8202], -1), 1);
py = gfx_h - 14;
env_y = py - min(env, 1.2) * (gfx_h - bar_y - 30);

gfx_set(1, 1, 1, 0.35);
gfx_line(ph * gfx_w, bar_y - 6, ph * gfx_w, py + 4); // playhead cursor
gfx_set(0.45, 0.93, 0.75, 0.9);
gfx_rect(ph * gfx_w - 1, env_y, 3, 3, 1);            // env gain dot
gfx_set(0.45, 0.93, 0.75, 0.5);
gfx_line((1 + pan) * 0.5 * gfx_w, py - 2, (1 + pan) * 0.5 * gfx_w, py + 2); // doppler pan
gfx_set(0.6, 0.6, 0.6, 0.5);
gfx_x = 4; gfx_y = py - 6;
gfx_drawnumber(ph, 2);
]==]

local function msg(s) r.ShowConsoleMsg(s .. "\n") end

local function write_jsfx(filename, content)
  local dir  = r.GetResourcePath() .. JSFX_DIR
  local path = dir .. "/" .. filename
  local f = io.open(path, "r")
  if f then f:close() return path end
  r.RecursiveCreateDirectory(dir, 0)
  f = io.open(path, "w")
  if not f then msg("Could not write " .. path) return nil end
  f:write(content)
  f:close()
  return path
end

local function ensure_jsfx_files()
  return write_jsfx(FILTER_FILE, FILTER_SOURCE)
     and write_jsfx(BRAIN_FILE, BRAIN_SOURCE)
     and write_jsfx(VISUAL_FILE, VISUAL_SOURCE)
end

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------

local function get_ext(tr, key)
  local _, v = r.GetSetMediaTrackInfo_String(tr, key, "", false)
  return v
end

local function set_ext(tr, key, val)
  r.GetSetMediaTrackInfo_String(tr, key, val, true)
end

-- ── FX identification (the bugfix core) ────────────────────────────────────
-- Matches BOTH the canonical filename ("ReaBlender_Filter") and the FX
-- description ("ReaBlender Filter Band"), normalized by stripping every
-- non-alphanumeric character. Validates the track pointer first, so stale
-- handles from a previous frame can never be dereferenced.

local function strip(s) return (s:lower():gsub("[^%w]", "")) end

local FILTER_CANDIDATES = { strip("ReaBlender_Filter"),        strip("ReaBlender Filter Band") }
local BRAIN_CANDIDATES  = { strip("ReaBlender_Brain"),         strip("ReaBlender Brain") }

local function find_fx(tr, candidates)
  if not r.ValidatePtr2(0, tr, "MediaTrack*") then return -1 end
  for i = 0, r.TrackFX_GetCount(tr) - 1 do
    local _, name = r.TrackFX_GetFXName(tr, i, "")
    local n = strip(name)
    for _, w in ipairs(candidates) do
      if n:find(w, 1, true) then return i end
    end
  end
  return -1
end

-- TrackFX_SetParam takes the parameter's NATIVE value (Hz for the cutoff
-- sliders, 0..3 for the mode slider) — NOT a normalized 0..1.
local function set_param_if_changed(tr, fx, idx, val)
  local v = r.TrackFX_GetParam(tr, fx, idx)
  if math.abs(v - val) > 0.0005 then r.TrackFX_SetParam(tr, fx, idx, val) end
end

-- Read the band mode range-safely: works whether GetParam hands back native
-- (v = 0..3, min 0, max 3) or normalized (v = 0..1, min 0, max 1) values.
local function read_band_mode(tr, fx)
  local v, mn, mx = r.TrackFX_GetParam(tr, fx, 0)
  local span = (mx - mn)
  if span <= 0 then return 0 end
  local m = math.floor((v - mn) / span * 3 + 0.5)
  if m < 0 then m = 0 elseif m > 3 then m = 3 end
  return m
end

local function time_selection()
  local s, e = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  return (e > s + 0.01), s, e
end

---------------------------------------------------------------------
-- Item cloning (audio only; MIDI can't be cloned via source copy)
---------------------------------------------------------------------

local ITEM_PROPS = {
  "D_POSITION", "D_LENGTH", "D_VOL", "D_PAN", "D_PLAYRATE", "S_OFFS",
  "B_LOOPSRC", "B_MUTE", "D_FADEINLEN", "D_FADEOUTLEN",
  "D_FADEINLEN_AUTO", "D_FADEOUTLEN_AUTO", "C_FADEINSHAPE", "C_FADEOUTSHAPE",
  "D_SNAPOFFSET", "I_CUSTOMCOLOR",
}

-- ponytail: clones active take only, take FX/envs not copied; MIDI items are
-- left in place (warned) — upgrade path: copy/paste actions or take copies
local function clone_item(it, dest)
  local src_tk = r.GetActiveTake(it)
  if not src_tk then return false end
  local source = r.GetMediaItemTake_Source(src_tk)
  local stype = r.GetMediaSourceType(source)
  if stype == 2 or stype == -1 then return false end -- MIDI/unknown

  local new = r.AddMediaItemToTrack(dest)
  local tk = r.AddTakeToMediaItem(new)
  r.SetMediaItemTake_Source(tk, source)
  for _, k in ipairs(ITEM_PROPS) do
    r.SetMediaItemInfo_Value(new, k, r.GetMediaItemInfo_Value(it, k))
  end
  r.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS",  r.GetMediaItemTakeInfo_Value(src_tk, "D_STARTOFFS"))
  r.SetMediaItemTakeInfo_Value(tk, "D_VOL",        r.GetMediaItemTakeInfo_Value(src_tk, "D_VOL"))
  r.SetMediaItemTakeInfo_Value(tk, "D_PAN",        r.GetMediaItemTakeInfo_Value(src_tk, "D_PAN"))
  r.SetMediaItemTakeInfo_Value(tk, "D_PLAYRATE",   r.GetMediaItemTakeInfo_Value(src_tk, "D_PLAYRATE"))
  r.SetMediaItemTakeInfo_Value(tk, "B_PPITCH",     r.GetMediaItemTakeInfo_Value(src_tk, "B_PPITCH"))
  local _, name = r.GetSetMediaItemTakeInfo_String(src_tk, "P_NAME", "", false)
  if name ~= "" then r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", name, true) end
  return true
end

---------------------------------------------------------------------
-- State + persistence (ExtState "ReaBlender")
---------------------------------------------------------------------

local state = {
  -- crossovers
  f1 = 150, f2 = 2000, f3 = 8000,
  -- whoosh envelope (mirrored by the Brain)
  peak_pos = 0.5, hold = 0.08, rise = 0.5, fall = 0.5,
  peak_db = 0, floor_db = -60, doppler_depth = 0.7,
  -- granular engine
  grain_size = 0.12, density = 60, grain_pitch_rand = 15, grain_vol_rand = 10,
  playback_mode = 0,
  -- modes / options
  live = false, auto_sync = true,
  playhead = 0.5,
  -- runtime
  status_msg = "Ready",
  curve_dirty = true,
  is_mono = false,
}

local SETTINGS_SECTION = "ReaBlender"
local MAX_PRESETS = 5
local PRESET_KEYS = {
  "f1", "f2", "f3", "peak_pos", "hold", "rise", "fall", "peak_db", "floor_db",
  "doppler_depth", "grain_size", "density", "grain_pitch_rand", "grain_vol_rand",
  "playback_mode",
}

local function serialize_state()
  local str = ""
  for _, k in ipairs(PRESET_KEYS) do
    str = str .. k .. "=" .. tostring(state[k]) .. "|"
  end
  return str
end

local function apply_state_str(str)
  for k, v in string.gmatch(str or "", "([^=]+)=([^|]+)|") do
    if state[k] ~= nil then state[k] = tonumber(v) or state[k] end
  end
end

local function save_settings()
  r.SetExtState(SETTINGS_SECTION, "state", serialize_state(), true)
end

local function load_settings()
  apply_state_str(r.GetExtState(SETTINGS_SECTION, "state"))
end

local function has_preset(slot)
  return r.GetExtState(SETTINGS_SECTION, "preset_" .. slot) ~= ""
end

local function load_preset(slot)
  apply_state_str(r.GetExtState(SETTINGS_SECTION, "preset_" .. slot))
  state.curve_dirty = true
  state.status_msg = "Loaded preset " .. slot
end

local function save_preset(slot)
  r.SetExtState(SETTINGS_SECTION, "preset_" .. slot, serialize_state(), true)
  state.status_msg = "Saved preset " .. slot
end

---------------------------------------------------------------------
-- Rig engine
---------------------------------------------------------------------

local parent   -- rig parent track (the UI target)

-- direct children of a folder parent, walking I_FOLDERDEPTH (no GUID storage)
local function folder_children(par)
  local pidx = math.floor(r.GetMediaTrackInfo_Value(par, "IP_TRACKNUMBER")) - 1
  local kids, level = {}, 0
  for i = pidx + 1, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if level == 0 then kids[#kids + 1] = tr end
    level = level + r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    if level <= 0 then break end
  end
  return kids
end

-- the 4 bucket tracks, keyed by band mode 0..3, found via P_EXT marker
local function rig_buckets(par)
  local out = {}
  for _, tr in ipairs(folder_children(par)) do
    local mode = tonumber(get_ext(tr, EXT_BUCKET))
    if mode and mode >= 0 and mode <= 3 then out[mode] = tr end
  end
  return out
end

local function find_or_make_grains_track(bucket, is_last_band)
  local bidx = math.floor(r.GetMediaTrackInfo_Value(bucket, "IP_TRACKNUMBER")) - 1
  if r.GetMediaTrackInfo_Value(bucket, "I_FOLDERDEPTH") == 1 then
    local level = 0
    for i = bidx + 1, r.CountTracks(0) - 1 do
      local tr = r.GetTrack(0, i)
      if level == 0 and get_ext(tr, EXT_GRAINS) == "1" then return tr end
      level = level + r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
      if level <= 0 then break end
    end
    r.InsertTrackAtIndex(bidx + 1, false) -- first child, existing terminator unchanged
    local g = r.GetTrack(0, bidx + 1)
    r.GetSetMediaTrackInfo_String(g, "P_NAME", "[Grains]", true)
    set_ext(g, EXT_GRAINS, "1")
    return g
  end
  -- childless bucket: turn it into a folder with [Grains] as terminator
  r.SetMediaTrackInfo_Value(bucket, "I_FOLDERDEPTH", 1)
  r.InsertTrackAtIndex(bidx + 1, false)
  local g = r.GetTrack(0, bidx + 1)
  r.GetSetMediaTrackInfo_String(g, "P_NAME", "[Grains]", true)
  set_ext(g, EXT_GRAINS, "1")
  -- the last band's terminator must close its folder AND the rig folder
  r.SetMediaTrackInfo_Value(g, "I_FOLDERDEPTH", is_last_band and -2 or -1)
  return g
end

-- push f1/f2/f3 to every band filter under the rig folder; the filter's own
-- mode (slider1) decides which cutoffs it needs, so names/GUIDs don't matter
local function apply_crossovers()
  if not r.ValidatePtr2(0, parent, "MediaTrack*") then return 0 end
  local applied = 0
  for mode = 0, 3 do
    local tr = rig_buckets(parent)[mode]
    if tr then
      local fx = find_fx(tr, FILTER_CANDIDATES)
      if fx >= 0 then
        local m = read_band_mode(tr, fx)
        if m == 0 then
          set_param_if_changed(tr, fx, 1, state.f1)
        elseif m == 1 then
          set_param_if_changed(tr, fx, 1, state.f1)
          set_param_if_changed(tr, fx, 2, state.f2)
        elseif m == 2 then
          set_param_if_changed(tr, fx, 2, state.f2)
          set_param_if_changed(tr, fx, 3, state.f3)
        else
          set_param_if_changed(tr, fx, 3, state.f3)
        end
        applied = applied + 1
      end
    end
  end
  set_ext(parent, EXT_F1, string.format("%.2f", state.f1))
  set_ext(parent, EXT_F2, string.format("%.2f", state.f2))
  set_ext(parent, EXT_F3, string.format("%.2f", state.f3))
  return applied
end

-- write the whoosh curve to the Brain; values are the Brain's NATIVE slider
-- values, indices per BRAIN_IDX (must match the JSFX slider declarations)
local function apply_brain_curve()
  if not r.ValidatePtr2(0, parent, "MediaTrack*") then return false end
  local fx = find_fx(parent, BRAIN_CANDIDATES)
  if fx < 0 then return false end
  local p = BRAIN_IDX
  set_param_if_changed(parent, fx, p.peak_pos, state.peak_pos)
  set_param_if_changed(parent, fx, p.hold,     state.hold)
  set_param_if_changed(parent, fx, p.rise,     state.rise)
  set_param_if_changed(parent, fx, p.fall,     state.fall)
  set_param_if_changed(parent, fx, p.peak_db,  state.peak_db)
  set_param_if_changed(parent, fx, p.floor_db, state.floor_db)
  set_param_if_changed(parent, fx, p.doppler,  state.doppler_depth)
  set_param_if_changed(parent, fx, p.amount,   state.live and 1 or 0)
  return true
end

local function sync_rig()
  local n = apply_crossovers()
  if apply_brain_curve() then state.curve_dirty = false end
  state.status_msg = n > 0
    and ("Synced — " .. n .. " band filter(s) at " ..
         string.format("%.0f/%.0f/%.0f Hz", state.f1, state.f2, state.f3))
    or "No band filters found on the rig's bucket tracks."
end

-- Create mode: bucket rig on a plain selected track
local function create_rig(src)
  -- guard: don't nest the rig inside an existing folder structure
  if r.GetMediaTrackInfo_Value(src, "I_FOLDERDEPTH") == 1 then
    msg("Selected track is already a folder parent — select a plain (non-folder) track.")
    return nil
  end

  local _, orig = r.GetTrackName(src)
  if orig == "" then orig = "Track" end

  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)

  -- the source track becomes the rig folder parent: it keeps its FX chain
  -- (now post-split) and gains Brain + Visualizer
  r.SetMediaTrackInfo_Value(src, "I_FOLDERDEPTH", 1)
  r.GetSetMediaTrackInfo_String(src, "P_NAME", "[ReaBlender] " .. orig, true)

  local idx = math.floor(r.GetMediaTrackInfo_Value(src, "IP_TRACKNUMBER")) - 1

  local items = {}
  for i = 0, r.CountTrackMediaItems(src) - 1 do
    items[#items + 1] = r.GetTrackMediaItem(src, i)
  end

  local midi_left = 0
  for i, b in ipairs(BANDS) do
    local is_last = (i == #BANDS)
    r.InsertTrackAtIndex(idx + i, false)
    local tr = r.GetTrack(0, idx + i)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", b.name, true)
    set_ext(tr, EXT_BUCKET, tostring(b.mode))

    -- bucket holds its [Grains] child, so it is a folder from the start;
    -- sub-tracks added later inherit the bucket's routing
    r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", 1)
    r.InsertTrackAtIndex(idx + i + 1, false)
    local g = r.GetTrack(0, idx + i + 1)
    r.GetSetMediaTrackInfo_String(g, "P_NAME", "[Grains]", true)
    set_ext(g, EXT_GRAINS, "1")
    r.SetMediaTrackInfo_Value(g, "I_FOLDERDEPTH", is_last and -2 or -1)
    r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR",
      r.ColorToNative(b.rgb[1], b.rgb[2], b.rgb[3]) | 0x1000000)

    -- band filter (defaults 150 / 2000 / 8000 Hz, adjustable live in the UI)
    local fx = r.TrackFX_AddByName(tr, "SoundDesignTools/ReaBlender_Filter", false, -1)
    if fx < 0 then fx = r.TrackFX_AddByName(tr, "ReaBlender_Filter", false, -1) end
    if fx < 0 then
      msg("Failed to insert ReaBlender_Filter.jsfx on " .. b.name ..
          " (if the files were just written, restart REAPER and run again).")
    else
      r.TrackFX_SetParam(tr, fx, 0, b.mode) -- slider1: mode (native 0..3)
      if b.u1 then r.TrackFX_SetParam(tr, fx, 1, state.f1) end
      if b.u2 then r.TrackFX_SetParam(tr, fx, 2, state.f2) end
      if b.u3 then r.TrackFX_SetParam(tr, fx, 3, state.f3) end
    end

    -- bucket ingredients: clone every audio item into this band
    for _, it in ipairs(items) do
      if not clone_item(it, tr) then midi_left = midi_left + 1 end
    end
    idx = idx + 1 -- account for the grains track we just inserted
  end

  -- originals: remove cloned ones, leave unclonable (MIDI) items on the parent
  for _, it in ipairs(items) do
    local tk = r.GetActiveTake(it)
    local ok = tk and r.GetMediaSourceType(r.GetMediaItemTake_Source(tk))
    if ok and ok ~= 2 and ok ~= -1 then r.DeleteTrackMediaItem(src, it) end
  end

  -- Brain (live envelope/doppler) first, Visualizer last, on the parent
  local bfx = r.TrackFX_AddByName(src, "SoundDesignTools/ReaBlender_Brain", false, -1)
  if bfx < 0 then bfx = r.TrackFX_AddByName(src, "ReaBlender_Brain", false, -1) end
  if bfx < 0 then msg("Failed to insert ReaBlender_Brain.jsfx on the rig parent.") end
  local vfx = r.TrackFX_AddByName(src, "SoundDesignTools/ReaBlender_Visualizer", false, -1)
  if vfx < 0 then msg("Failed to insert ReaBlender_Visualizer.jsfx on the rig parent.") end

  -- persist rig state on the parent
  set_ext(src, EXT_PARENT, "1")
  set_ext(src, EXT_F1, string.format("%.2f", state.f1))
  set_ext(src, EXT_F2, string.format("%.2f", state.f2))
  set_ext(src, EXT_F3, string.format("%.2f", state.f3))

  r.Undo_EndBlock2(0, "Create ReaBlender rig", -1)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()

  if midi_left > 0 then
    msg(string.format("Warning: %d MIDI item(s) can't be cloned into buckets — " ..
      "they were left on the parent (they play unfiltered). Move/copy them manually.", midi_left))
  end
  msg("ReaBlender rig created on '[ReaBlender] " .. orig .. "'.")
  return src
end

---------------------------------------------------------------------
-- Generation: Auto-Whoosh (grains scattered into each bucket's [Grains])
---------------------------------------------------------------------

-- the envelope curve shared with ReaBlender_Brain.jsfx (power-curve shape)
local function env_shape(t, pk, hold, rise, fall)
  local ps = math.max(0, pk - hold * 0.5)
  local pe = math.min(1, pk + hold * 0.5)
  if t <= ps then
    local lt = ps > 0 and t / ps or 0
    return lt ^ (2 ^ (rise * 1.5))
  elseif t >= pe then
    local lt = pe < 1 and (1 - t) / (1 - pe) or 0
    return lt ^ (2 ^ (fall * 1.5))
  end
  return 1
end

-- doppler pan curve shared with the Brain
local function doppler_pan(t, pk, depth)
  local p = depth * (t - pk) * 2
  return math.max(-1, math.min(1, p))
end

local function collect_bucket_sources(btr)
  local sources = {}
  for i = 0, r.CountTrackMediaItems(btr) - 1 do
    local it = r.GetTrackMediaItem(btr, i)
    local tk = r.GetActiveTake(it)
    if tk then
      local src = r.GetMediaItemTake_Source(tk)
      local st = r.GetMediaSourceType(src)
      if st ~= 2 and st ~= -1 then
        -- returns (length_seconds, is_in_quarter_notes); MIDI is filtered out above
        local len = r.GetMediaSourceLength(src)
        sources[#sources + 1] = {
          src = src, len = len or 0,
          offs = r.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"),
        }
      end
    end
  end
  return sources
end

-- scatter grains for one bucket onto its [Grains] track, glued into one item
local function scatter_bucket(btr, gtr, sel_s, sel_e)
  local sources = collect_bucket_sources(btr)
  if #sources == 0 then return 0 end

  local win_dur = sel_e - sel_s
  local t = sel_s
  local read_head = 0
  local count = 0
  local grain_items = {}

  while t < sel_e do
    local grain_s = state.grain_size * (0.8 + math.random() * 0.4)

    -- pitch randomization via D_PLAYRATE keeps item_len = grain_s / rate
    -- (slice alignment), never D_PITCH (varispeed changes duration)
    local rate = 1.0
    if state.grain_pitch_rand > 0 then
      rate = 1.0 + (math.random() - 0.5) * 2.0 * (state.grain_pitch_rand / 100.0)
    end
    local item_len = grain_s / rate
    if t + item_len > sel_e then break end

    -- density remapped to a safe overlap window: 0% -> 15%, 100% -> 75%
    -- (a 15% floor guarantees a crossfade at every grain join, no clicks)
    local dn = state.density / 100.0
    local overlap_s = item_len * (0.15 + dn * 0.60)
    local hop_s = math.max(0.001, item_len - overlap_s)

    local s = sources[math.random(#sources)]
    local max_offs = math.max(0.0, s.len - grain_s)
    local base_pos

    local m = state.playback_mode
    if m == 1 then        -- Reverse: sweep the source backwards
      read_head = math.min(1.0, read_head + (hop_s / win_dur))
      base_pos = (1.0 - read_head) * max_offs
    elseif m == 2 then    -- Ping-Pong
      read_head = math.min(1.0, read_head + (hop_s / win_dur))
      local ph = (read_head * 2.0) % 2.0
      base_pos = (ph < 1.0 and ph or 2.0 - ph) * max_offs
    elseif m == 3 then    -- Random
      base_pos = math.random() * max_offs
    else                  -- Forward
      read_head = math.min(1.0, read_head + (hop_s / win_dur))
      base_pos = read_head * max_offs
    end
    base_pos = math.max(0.0, math.min(max_offs, base_pos))

    local tnorm = (t - sel_s) / win_dur
    local v = env_shape(tnorm, state.peak_pos, state.hold, state.rise, state.fall)
    if state.grain_vol_rand > 0 then
      v = v * (1.0 + (math.random() - 0.5) * 2.0 * (state.grain_vol_rand / 100.0))
    end
    v = math.max(0.0, v)

    local ni = r.AddMediaItemToTrack(gtr)
    r.SetMediaItemInfo_Value(ni, "D_POSITION", t)
    r.SetMediaItemInfo_Value(ni, "D_LENGTH", item_len)
    r.SetMediaItemInfo_Value(ni, "B_LOOPSRC", 0)
    r.SetMediaItemInfo_Value(ni, "D_VOL", v)
    r.SetMediaItemInfo_Value(ni, "D_PAN", doppler_pan(tnorm, state.peak_pos, state.doppler_depth))

    local mf = item_len * 0.49
    r.SetMediaItemInfo_Value(ni, "D_FADEINLEN",  math.min(overlap_s * 0.5, mf))
    r.SetMediaItemInfo_Value(ni, "D_FADEOUTLEN", math.min(overlap_s * 0.5, mf))

    local tk = r.AddTakeToMediaItem(ni)
    r.SetMediaItemTake_Source(tk, s.src)
    r.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", s.offs + base_pos)
    if rate ~= 1.0 then r.SetMediaItemTakeInfo_Value(tk, "D_PLAYRATE", rate) end

    grain_items[#grain_items + 1] = ni
    count = count + 1
    t = t + hop_s
  end

  -- glue this bucket's grains into one item
  if #grain_items > 1 then
    r.SelectAllMediaItems(0, false)
    for _, gi in ipairs(grain_items) do r.SetMediaItemSelected(gi, true) end
    r.Main_OnCommand(40362, 0) -- Item: Glue items
  end
  return count
end

local function generate_whoosh()
  if not r.ValidatePtr2(0, parent, "MediaTrack*") then return end
  local has_ts, sel_s, sel_e = time_selection()
  if not has_ts then
    state.status_msg = "Error — make a time selection first"
    return
  end

  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)

  local total, buckets_used = 0, 0
  local bks = rig_buckets(parent)
  for mode = 0, 3 do
    local btr = bks[mode]
    if btr and r.CountTrackMediaItems(btr) > 0 then
      local gtr = find_or_make_grains_track(btr, mode == 3)
      local n = scatter_bucket(btr, gtr, sel_s, sel_e)
      total = total + n
      if n > 0 then buckets_used = buckets_used + 1 end
    end
  end

  r.Undo_EndBlock2(0, "ReaBlender: generate whoosh", -1)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()

  state.status_msg = total > 0
    and string.format("Done — %d grains across %d bucket(s)", total, buckets_used)
    or "Error — no bucket has audio ingredients to granulate"
end

-- remove every [Grains] track from the rig; flatten a bucket that only held one
local function clear_grains()
  if not r.ValidatePtr2(0, parent, "MediaTrack*") then return end
  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  local removed = 0
  for mode = 0, 3 do
    local btr = rig_buckets(parent)[mode]
    if btr then
      local grains = {}
      if r.GetMediaTrackInfo_Value(btr, "I_FOLDERDEPTH") == 1 then
        for _, tr in ipairs(folder_children(btr)) do
          if get_ext(tr, EXT_GRAINS) == "1" then grains[#grains + 1] = tr end
        end
      end
      for _, gtr in ipairs(grains) do
        r.DeleteTrack(gtr)
        removed = removed + 1
      end
      -- bucket that only held grains: un-folder it (last band closes the rig folder)
      if #grains > 0 and r.GetMediaTrackInfo_Value(btr, "I_FOLDERDEPTH") == 1
         and #folder_children(btr) == 0 then
        r.SetMediaTrackInfo_Value(btr, "I_FOLDERDEPTH", mode == 3 and -1 or 0)
      end
    end
  end
  r.Undo_EndBlock2(0, "ReaBlender: clear grains", -1)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  state.status_msg = removed > 0 and ("Cleared " .. removed .. " grains track(s).")
                     or "No grains tracks found."
end

-- move selected media items into a bucket track (clone + delete: robust
-- across items on any track, including items inside the rig)
local function move_selection_to_bucket(mode)
  local btr = rig_buckets(parent)[mode]
  if not btr then return end
  local n = r.CountSelectedMediaItems(0)
  if n == 0 then
    state.status_msg = "Select some media items first"
    return
  end
  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  local moved = 0
  for i = 0, n - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    local src_tr = r.GetMediaItem_Track(it)
    if src_tr ~= btr and clone_item(it, btr) then
      r.DeleteTrackMediaItem(src_tr, it)
      moved = moved + 1
    end
  end
  r.Undo_EndBlock2(0, "ReaBlender: add ingredients to bucket", -1)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  state.status_msg = "Added " .. moved .. " item(s) to " .. BANDS[mode + 1].name
end

---------------------------------------------------------------------
-- Live performance mode
---------------------------------------------------------------------

local function arm_live()
  local has_ts, sel_s, sel_e = time_selection()
  if not has_ts then
    state.status_msg = "Error — make a time selection first"
    return
  end
  r.GetSet_LoopTimeRange(true, true, sel_s, sel_e, true)
  r.GetSetRepeat(1)     -- repeat on
  r.OnPlayButton()
  state.live = true
  state.curve_dirty = true
  state.status_msg = "Live — transport looping, playhead follows"
end

local function stop_live()
  r.OnStopButton()
  state.live = false
  state.curve_dirty = true
  state.status_msg = "Stopped — back to Auto-Whoosh"
end

-- playhead for this frame: follow transport in live mode, else the slider
local function current_playhead()
  local playing = (r.GetPlayState() & 1) == 1
  if state.live and playing then
    local _, sel_s, sel_e = r.GetSet_LoopTimeRange(false, true, 0, 0, false)
    local pos = r.GetPlayPosition()
    if sel_e > sel_s and pos >= sel_s and pos <= sel_e then
      state.playhead = (pos - sel_s) / (sel_e - sel_s)
    end
  end
  return state.playhead
end

---------------------------------------------------------------------
-- Stem rendering (Stereo / Mono) via REAPER's render engine
---------------------------------------------------------------------

local function render_stem(mono)
  if not r.ValidatePtr2(0, parent, "MediaTrack*") then return end
  local has_ts = time_selection()

  r.SetOnlyTrackSelected(parent)

  -- remember and restore the user's render settings we touch
  local old_bounds  = r.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false)
  local old_settings = r.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false)
  local old_chan    = r.GetSetProjectInfo(0, "RENDER_CHANNELS", 0, false)

  r.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", has_ts and 1 or 0, true) -- time sel / project
  r.GetSetProjectInfo(0, "RENDER_SETTINGS", 1, true)                   -- stems (selected tracks)
  r.GetSetProjectInfo(0, "RENDER_CHANNELS", mono and 1 or 2, true)
  r.GetSetProjectInfo_String(0, "RENDER_DIR", r.GetProjectPath(""), true)
  r.GetSetProjectInfo_String(0, "RENDER_PATTERN", "ReaBlender stem", true)

  r.Main_OnCommand(41824, 0) -- render using the (just-set) settings, auto-close dialog

  r.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", old_bounds, true)
  r.GetSetProjectInfo(0, "RENDER_SETTINGS", old_settings, true)
  r.GetSetProjectInfo(0, "RENDER_CHANNELS", old_chan, true)

  state.is_mono = mono
  state.status_msg = "Rendering " .. (mono and "mono" or "stereo") .. " stem to " .. r.GetProjectPath("")
end

---------------------------------------------------------------------
-- Theme (QikWhoosh style, 0xRRGGBBAA)
---------------------------------------------------------------------

local ctx = r.ImGui_CreateContext("ReaBlender")

local theme = {
  WindowBg        = 0x1A1A1AFF,
  ChildBg         = 0x1A1A1AFF,
  PopupBg         = 0x202020FF,
  Border          = 0x444444FF,
  Separator       = 0x444444FF,
  Text            = 0xE0E0E0FF,
  TextDisabled    = 0x888888FF,
  Button          = 0x202020FF,
  ButtonHovered   = 0x333333FF,
  ButtonActive    = 0x2D6D8CFF,
  SliderGrab      = 0x2D6D8CFF,
  CheckMark       = 0x2D6D8CFF,
  Header          = 0x202020FF,
  HeaderHovered   = 0x2D6D8CFF,
  FrameBg         = 0x00000060,
  FrameBgHovered  = 0x00000080,
  WindowRounding  = 6,
  FrameRounding   = 4,
  GrabRounding    = 3,
  ItemSpacingX    = 8,
  ItemSpacingY    = 6,
  FramePaddingX   = 6,
  FramePaddingY   = 4,
  WindowPaddingX  = 10,
  WindowPaddingY  = 10,
}

local function push_theme()
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), theme.WindowPaddingX, theme.WindowPaddingY)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(),  theme.FramePaddingX,  theme.FramePaddingY)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(),   theme.ItemSpacingX,   theme.ItemSpacingY)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(),theme.WindowRounding)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), theme.FrameRounding)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabRounding(),  theme.GrabRounding)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(),       theme.WindowBg)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(),        theme.ChildBg)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(),        theme.PopupBg)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(),         theme.Border)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Separator(),      theme.Separator)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),           theme.Text)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TextDisabled(),   theme.TextDisabled)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),         theme.Button)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(),  theme.ButtonHovered)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(),   theme.ButtonActive)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SliderGrab(),     theme.SliderGrab)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_CheckMark(),      theme.CheckMark)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Header(),         theme.Header)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(),  theme.HeaderHovered)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(),        theme.FrameBg)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), theme.FrameBgHovered)
end

local function pop_theme()
  r.ImGui_PopStyleVar(ctx, 6)
  r.ImGui_PopStyleColor(ctx, 16)
end

-- ── UI helpers ──
local function show_tooltip(text)
  if r.ImGui_IsItemHovered(ctx) then
    r.ImGui_BeginTooltip(ctx)
    r.ImGui_PushTextWrapPos(ctx, r.ImGui_GetFontSize(ctx) * 35.0)
    r.ImGui_Text(ctx, text)
    r.ImGui_PopTextWrapPos(ctx)
    r.ImGui_EndTooltip(ctx)
  end
end

local function section_header(label)
  if r.ImGui_SeparatorText then
    r.ImGui_SeparatorText(ctx, label)
  else
    r.ImGui_Text(ctx, label)
    r.ImGui_Separator(ctx)
  end
end

local function labeled_slider(label, value, min, max, format, tooltip)
  r.ImGui_Text(ctx, label)
  r.ImGui_SetNextItemWidth(ctx, -1)
  local changed, new_value = r.ImGui_SliderDouble(ctx, '##' .. label, value, min, max, format)
  if changed then value = new_value end
  if tooltip then show_tooltip(tooltip) end
  return value
end

---------------------------------------------------------------------
-- Interactive curve canvas (QikWhoosh-style drag handles)
---------------------------------------------------------------------

local viz_h = 190
local peak_dragging, rise_dragging, fall_dragging = false, false, false
local rise_start_mx, rise_start_val = 0, 0
local fall_start_mx, fall_start_val = 0, 0

local function curve_dirty()
  state.curve_dirty = true
end

local function draw_curve()
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local W = r.ImGui_GetContentRegionAvail(ctx)
  local H = viz_h

  r.ImGui_InvisibleButton(ctx, '##curve', W, H)
  local cx, cy = r.ImGui_GetItemRectMin(ctx)
  local mx, my = r.ImGui_GetMousePos(ctx)
  local mouse_down = r.ImGui_IsMouseDown(ctx, 0)
  local clicked = r.ImGui_IsMouseClicked(ctx, 0)

  r.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + W, cy + H, 0x000000FF, 4)
  r.ImGui_DrawList_AddRect(dl, cx, cy, cx + W, cy + H, theme.Border, 4)

  local x0, x1 = cx + 14, cx + W - 14
  local mid = cy + H * 0.5
  local half = H * 0.5 - 16
  local function tx(t) return x0 + (x1 - x0) * t end

  local ps = math.max(0, state.peak_pos - state.hold * 0.5)
  local pe = math.min(1, state.peak_pos + state.hold * 0.5)

  -- ── filled silhouette (top edge = envelope, mirrored bottom) ──
  r.ImGui_DrawList_PushClipRect(dl, cx, cy, cx + W, cy + H, true)
  local N = 64
  local fill_col = 0x4488CC38
  local line_col = 0x4488CCCC
  local top, bot = {}, {}
  for i = 0, N do
    local t = i / N
    local v = env_shape(t, state.peak_pos, state.hold, state.rise, state.fall)
    top[#top + 1] = tx(t); top[#top + 1] = mid - half * v
    bot[#bot + 1] = tx(t); bot[#bot + 1] = mid + half * v
  end
  for i = 1, N do
    local ax, ay, ab = top[i*2-1], top[i*2], bot[i*2]
    local bx, by, bb = top[i*2+1], top[i*2+2], bot[i*2+2]
    r.ImGui_DrawList_AddTriangleFilled(dl, ax, ay, ax, ab, bx, by, fill_col)
    r.ImGui_DrawList_AddTriangleFilled(dl, ax, ab, bx, bb, bx, by, fill_col)
  end
  r.ImGui_DrawList_AddPolyline(dl, r.new_array(top), line_col, 0, 2.0)
  r.ImGui_DrawList_AddPolyline(dl, r.new_array(bot), line_col, 0, 2.0)
  r.ImGui_DrawList_PopClipRect(dl)

  -- ── peak dot (drag: position + level) ──
  local pk_lvl = (state.peak_db - (-24)) / 24 -- -24 dB -> 0, 0 dB -> 1
  local dot_x, dot_y = tx(state.peak_pos), mid - half * pk_lvl
  r.ImGui_DrawList_AddCircleFilled(dl, dot_x, dot_y, 8, 0xFF2D6D8C)
  r.ImGui_DrawList_AddCircle(dl, dot_x, dot_y, 10, 0x2D6D8C88, 1.5)
  if clicked and math.abs(mx - dot_x) < 12 and math.abs(my - dot_y) < 12 then
    peak_dragging = true
  end
  if peak_dragging and mouse_down then
    state.peak_pos = math.max(0, math.min(1, (mx - x0) / (x1 - x0)))
    local lvl = math.max(0, math.min(1, (mid - my) / half))
    state.peak_db = -24 + lvl * 24
    curve_dirty()
  end
  if not mouse_down then peak_dragging = false end
  if (math.abs(mx - dot_x) < 12 and math.abs(my - dot_y) < 12) or peak_dragging then
    show_tooltip("Whoosh peak — drag to set position and level.\n" ..
      string.format("pos %.2f  level %.1f dB", state.peak_pos, state.peak_db))
  end

  -- ── rise / fall tension triangles (drag horizontally) ──
  local tri_s = 6
  local function tri(x, col)
    r.ImGui_DrawList_AddTriangleFilled(dl, x, mid - tri_s, x - tri_s, mid, x, mid + tri_s, col)
  end
  local rise_x, fall_x = tx(ps), tx(pe)
  tri(rise_x, 0xFF2D6D8C)
  tri(fall_x, 0xFF33A07C)
  if clicked and math.abs(my - mid) < 10 then
    if math.abs(mx - rise_x) < 10 then
      rise_dragging, rise_start_mx, rise_start_val = true, mx, state.rise
    elseif math.abs(mx - fall_x) < 10 then
      fall_dragging, fall_start_mx, fall_start_val = true, mx, state.fall
    end
  end
  if rise_dragging and mouse_down then
    state.rise = math.max(-1, math.min(1, rise_start_val + (mx - rise_start_mx) / 80))
    curve_dirty()
  end
  if fall_dragging and mouse_down then
    state.fall = math.max(-1, math.min(1, fall_start_val + (mx - fall_start_mx) / 80))
    curve_dirty()
  end
  if not mouse_down then rise_dragging, fall_dragging = false, false end
  if math.abs(mx - rise_x) < 10 and math.abs(my - mid) < 10 then
    show_tooltip("Rise tension — drag right to slow the build-up")
  elseif math.abs(mx - fall_x) < 10 and math.abs(my - mid) < 10 then
    show_tooltip("Fall tension — drag right to slow the tail")
  end

  -- ── hover readout ──
  if mx >= x0 and mx <= x1 and my >= cy and my <= cy + H
     and not (peak_dragging or rise_dragging or fall_dragging) then
    local t = (mx - x0) / (x1 - x0)
    local v = env_shape(t, state.peak_pos, state.hold, state.rise, state.fall)
    local db = -90 + v * (state.peak_db + 90) -- floor..peak
    r.ImGui_DrawList_AddLine(dl, mx, cy, mx, cy + H, 0x88FFFFFF, 1.0)
    r.ImGui_DrawList_AddText(dl, mx + 8, cy + 6, 0xFFCCCCCC,
      string.format("t %.2f   %.1f dB", t, math.max(state.floor_db, math.min(state.peak_db, db))))
  end
end

---------------------------------------------------------------------
-- Panels
---------------------------------------------------------------------

local LEFT_W, GEN_W = 250, 260
local CENTER_MIN_W = 380

local function panel_identity()
  r.ImGui_Text(ctx, "ReaBlender")
  if r.ImGui_IsItemHovered(ctx) then
    show_tooltip("Multiband LR4 splitting rig + granular whoosh engine.\n" ..
      "Ingredients live on the bucket tracks; the whoosh is generated per bucket.")
  end
  r.ImGui_TextDisabled(ctx, "Sound / Dev / Ed suite")
  r.ImGui_Separator(ctx)

  section_header("Status")
  local err = state.status_msg:find("Error") ~= nil
  r.ImGui_TextColored(ctx, err and 0xE06060FF or 0x8CD08CFF, state.status_msg)

  section_header("Buckets")
  local bks = r.ValidatePtr2(0, parent, "MediaTrack*") and rig_buckets(parent) or {}
  for mode = 0, 3 do
    local b = BANDS[mode + 1]
    r.ImGui_TextColored(ctx, b.ui, "■")
    r.ImGui_SameLine(ctx)
    local tr = bks[mode]
    if tr then
      local n = r.CountTrackMediaItems(tr)
      r.ImGui_Text(ctx, string.format("%s  %d item%s", b.name, n, n == 1 and "" or "s"))
    else
      r.ImGui_TextDisabled(ctx, b.name .. "  (missing)")
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Add##" .. mode) then move_selection_to_bucket(mode) end
    if r.ImGui_IsItemHovered(ctx) then
      show_tooltip("Move the selected media items into " .. b.name)
    end
  end

  if r.ImGui_Button(ctx, "Sync Rig", -1, 0) then sync_rig() end
  if r.ImGui_IsItemHovered(ctx) then
    show_tooltip("Re-apply crossovers + whoosh curve to every band filter.\n" ..
      "Fixes a rig whose FX were renamed, reordered or edited by hand.")
  end

  local _, autosync = r.ImGui_Checkbox(ctx, "Live-update crossovers", state.auto_sync)
  state.auto_sync = autosync
  show_tooltip("When on, moving a crossover slider updates the band\n" ..
    "filters immediately. When off, use Sync Rig to apply.")
end

local function panel_presets()
  section_header("Presets")
  for slot = 1, MAX_PRESETS do
    local id = tostring(slot)
    if r.ImGui_Button(ctx, id .. "##load" .. id, 26, 0) then load_preset(slot) end
    if r.ImGui_IsItemHovered(ctx) then
      show_tooltip(has_preset(slot) and ("Load preset " .. id) or ("Slot " .. id .. " is empty"))
    end
    if slot < MAX_PRESETS then r.ImGui_SameLine(ctx) end
  end
  for slot = 1, MAX_PRESETS do
    if r.ImGui_SmallButton(ctx, "s" .. slot .. "##save" .. slot) then save_preset(slot) end
    if r.ImGui_IsItemHovered(ctx) then show_tooltip("Save current settings to preset " .. slot) end
    if slot < MAX_PRESETS then r.ImGui_SameLine(ctx) end
  end
end

local function panel_crossovers()
  local changed = false
  local v
  v = labeled_slider("Sub / Low-Mid", state.f1, F_MIN[1], F_MAX[1], "%.0f Hz",
    "Crossover between the Sub and Low-Mid buckets")
  if v ~= state.f1 then state.f1, changed = v, true end
  v = labeled_slider("Low-Mid / High-Mid", state.f2, F_MIN[2], F_MAX[2], "%.0f Hz",
    "Crossover between the Low-Mid and High-Mid buckets")
  if v ~= state.f2 then state.f2, changed = v, true end
  v = labeled_slider("High-Mid / Air", state.f3, F_MIN[3], F_MAX[3], "%.0f Hz",
    "Crossover between the High-Mid and Air buckets")
  if v ~= state.f3 then state.f3, changed = v, true end

  -- keep the crossovers ordered no matter how they were dragged
  state.f2 = math.max(state.f2, state.f1)
  state.f3 = math.max(state.f3, state.f2)

  if changed then
    if state.auto_sync then
      apply_crossovers()
      state.status_msg = string.format("Crossovers applied — %.0f / %.0f / %.0f Hz",
        state.f1, state.f2, state.f3)
    else
      state.status_msg = "Crossovers staged — press Sync Rig to apply"
    end
  end
end

local function panel_grain_controls()
  section_header("Granular Engine")
  state.grain_size = labeled_slider("Grain size", state.grain_size, 0.05, 0.5, "%.2f s",
    "Length of each grain. Pitch shifts stretch/shrink grains via D_PLAYRATE\n" ..
    "so source slices stay aligned (item_len = grain_s / rate).")
  state.density = labeled_slider("Density", state.density, 0, 100, "%.0f %%",
    "Grain overlap. 0% = 15% overlap (guaranteed crossfade), 100% = 75%.")
  state.grain_pitch_rand = labeled_slider("Pitch random", state.grain_pitch_rand, 0, 100, "%.0f %%",
    "Random playback-rate spread per grain (keeps slice alignment).")
  state.grain_vol_rand = labeled_slider("Level random", state.grain_vol_rand, 0, 100, "%.0f %%",
    "Random per-grain level spread around the envelope value.")

  r.ImGui_Text(ctx, "Sampling direction")
  for i, name in ipairs(PLAYBACK_MODES) do
    if state.playback_mode == i - 1 then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_CheckMark(), theme.SliderGrab)
    end
    if r.ImGui_RadioButton(ctx, name .. (i < #PLAYBACK_MODES and "##pm" or ""), state.playback_mode == i - 1) then
      state.playback_mode = i - 1
    end
    if state.playback_mode == i - 1 then r.ImGui_PopStyleColor(ctx, 1) end
    if i < #PLAYBACK_MODES then r.ImGui_SameLine(ctx) end
  end
  show_tooltip("How grains read through the source: Forward sweeps start→end,\n" ..
    "Reverse end→start, Ping-Pong bounces, Random jumps.")

  state.doppler_depth = labeled_slider("Doppler depth", state.doppler_depth, 0, 1, "%.2f",
    "Pan trajectory strength: source passes L → R through the whoosh peak.\n" ..
    "Baked into generated grains; live in Live mode via the Brain.")
end

local function panel_generation()
  section_header("Playback")
  if r.ImGui_RadioButton(ctx, "Auto-Whoosh (time selection)", not state.live) then
    if state.live then stop_live() end
  end
  show_tooltip("Generate the whoosh onto each bucket's [Grains] track with\n" ..
    "the envelope and doppler baked in.")
  if r.ImGui_RadioButton(ctx, "Live Performance", state.live) then
    if not state.live then arm_live() end
  end
  show_tooltip("Loop the time selection; the playhead drives the Brain's\n" ..
    "master envelope + doppler in real time (gmem -> Visualizer).")

  r.ImGui_Spacing(ctx)
  state.playhead = labeled_slider("Playhead", state.playhead, 0, 1, "%.2f",
    state.live and "Virtual playhead — follows the looping transport (stop to scrub manually)"
                or "Brain playhead (used when Live Performance is on)")
  state.hold = labeled_slider("Envelope hold", state.hold, 0, 0.5, "%.2f",
    "Flat time around the whoosh peak (also mirrored in the canvas)")

  r.ImGui_Spacing(ctx)
  section_header("Generate")
  if r.ImGui_Button(ctx, "Generate Whoosh", -1, 0) then generate_whoosh() end
  show_tooltip("Scatter grains from every bucket's ingredients onto its [Grains]\n" ..
    "track, with envelope + doppler baked per grain, then glue.")
  if r.ImGui_Button(ctx, "Clear Grains", -1, 0) then clear_grains() end
  show_tooltip("Delete every [Grains] track under the rig.")

  r.ImGui_Spacing(ctx)
  section_header("Render Stems")
  if r.ImGui_Button(ctx, "Render Stem (Stereo)", -1, 0) then render_stem(false) end
  show_tooltip("Render the rig parent through all FX over the time selection\n" ..
    "(or the whole project if none) as a stereo WAV.")
  if r.ImGui_Button(ctx, "Render Stem (Mono)", -1, 0) then render_stem(true) end
  show_tooltip("Same, downmixed to mono.")
end

---------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------

local started, hidden_frames = false, 0

function loop()
  -- cached parent handle may go stale (delete/undo) — validate before use
  if not r.ValidatePtr2(0, parent, "MediaTrack*") then
    msg("ReaBlender rig track was deleted — closing the window.")
    save_settings()
    if r.ImGui_DestroyContext then
      r.defer(function() r.ImGui_DestroyContext(ctx) end)
    end
    return
  end

  -- live mode: keep the Brain's playhead tracking the transport
  if state.live then
    local ph = current_playhead()
    local fx = find_fx(parent, BRAIN_CANDIDATES)
    if fx >= 0 then
      local v = r.TrackFX_GetParam(parent, fx, BRAIN_IDX.playhead)
      if math.abs(v - ph) > 0.0005 then r.TrackFX_SetParam(parent, fx, BRAIN_IDX.playhead, ph) end
    end
  end

  -- push curve changes to the Brain (native slider values)
  if state.curve_dirty then
    apply_brain_curve()
    state.curve_dirty = false
  end

  r.ImGui_SetNextWindowSize(ctx, 1240, 520, r.ImGui_Cond_FirstUseEver())
  push_theme()
  local win_flags = r.ImGui_WindowFlags_NoCollapse() | r.ImGui_WindowFlags_HorizontalScrollbar()
  local vis, open = r.ImGui_Begin(ctx, "ReaBlender v1.0.0", true, win_flags)

  if vis then
    local avail_w, avail_h = r.ImGui_GetContentRegionAvail(ctx)
    local center_w = math.max(CENTER_MIN_W, avail_w - LEFT_W - GEN_W - 16)

    -- LEFT: identity / status / buckets / presets
    if r.ImGui_BeginChild(ctx, '##col_left', LEFT_W, avail_h, 1) then
      panel_identity()
      r.ImGui_Separator(ctx)
      panel_presets()
      r.ImGui_EndChild(ctx)
    end
    r.ImGui_SameLine(ctx)

    -- CENTER: curve canvas + crossovers + granular engine
    if r.ImGui_BeginChild(ctx, '##col_center', center_w, avail_h, 1) then
      -- band chips
      for i, b in ipairs(BANDS) do
        r.ImGui_TextColored(ctx, b.ui, "■ " .. b.name)
        if i < #BANDS then r.ImGui_SameLine(ctx) end
      end
      r.ImGui_Spacing(ctx)
      draw_curve()
      r.ImGui_Separator(ctx)
      panel_crossovers()
      r.ImGui_Separator(ctx)
      panel_grain_controls()
      r.ImGui_EndChild(ctx)
    end
    r.ImGui_SameLine(ctx)

    -- RIGHT: playback modes + generation + rendering
    if r.ImGui_BeginChild(ctx, '##col_gen', -1, avail_h, 1) then
      panel_generation()
      r.ImGui_EndChild(ctx)
    end

    r.ImGui_End(ctx)
  end
  pop_theme()

  -- window-gone detection (close button / docked tab dismissed)
  if vis then
    started = true
    hidden_frames = 0
  else
    hidden_frames = hidden_frames + 1
  end
  local closed = (not open) or (started and hidden_frames > 15)
  if closed then
    save_settings()
    if r.ImGui_DestroyContext then
      r.defer(function() r.ImGui_DestroyContext(ctx) end)
    end
    return
  end
  r.defer(loop)
end

---------------------------------------------------------------------
-- Main
---------------------------------------------------------------------

local function main()
  if not ensure_jsfx_files() then return end
  load_settings() -- global defaults first; rig-specific P_EXT values override below

  if r.CountSelectedTracks(0) ~= 1 then
    msg("Select exactly one track: a source track to build the rig, " ..
        "or a [ReaBlender] parent/bucket to open the control window.")
    return
  end

  local tr = r.GetSelectedTrack(0, 0)
  -- walk up the folder chain looking for the rig marker
  local p = tr
  while p and get_ext(p, EXT_PARENT) ~= "1" do
    local up = r.GetParentTrack(p)
    p = up
  end

  if p then
    parent = p
  else
    parent = create_rig(tr)
  end
  if not parent then return end

  state.f1 = tonumber(get_ext(parent, EXT_F1)) or state.f1
  state.f2 = tonumber(get_ext(parent, EXT_F2)) or state.f2
  state.f3 = tonumber(get_ext(parent, EXT_F3)) or state.f3
  r.defer(loop)
end

main()
