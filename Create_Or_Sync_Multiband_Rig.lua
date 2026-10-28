--[[
  Create_Or_Sync_Multiband_Rig.lua — track-based multiband splitting rig
  (free, flexible alternative to Kilohearts Multipass).

  Run on ONE selected track:
    * Plain track          -> becomes "[MB Rig] <name>" folder parent with
                              [SOURCE IN], [LOW], [MID], [HIGH] children.
                              Each band child gets MB_Filter_Band.jsfx
                              (LR4 24 dB/oct split), fed by pre-fader post-FX
                              sends from [SOURCE IN]; bands sum to unity in
                              the parent folder.
    * Rig parent or child  -> prompts for new crossovers and syncs slider2 /
                              slider3 on every band filter simultaneously.

  Self-deploys its JSFX to <ResourcePath>/Effects/SoundDesignTools/
  MB_Filter_Band.jsfx on first run. Rig state (child GUIDs + cutoffs) is
  stored on the parent track via P_EXT strings.
]]

local r = reaper

local JSFX_REL_DIR  = "/Effects/SoundDesignTools"
local JSFX_FILENAME = "MB_Filter_Band.jsfx"

-- P_EXT keys stored on the rig parent track
local EXT_PARENT = "P_EXT:MB_RIG_PARENT"
local EXT_LOW    = "P_EXT:MB_RIG_LOW"
local EXT_MID    = "P_EXT:MB_RIG_MID"
local EXT_HIGH   = "P_EXT:MB_RIG_HIGH"
local EXT_F1     = "P_EXT:MB_RIG_F1"
local EXT_F2     = "P_EXT:MB_RIG_F2"

-- JSFX slider ranges (must match MB_Filter_Band.jsfx: slider2 / slider3)
local S2_MIN, S2_MAX = 20, 2000
local S3_MIN, S3_MAX = 1000, 20000

local JSFX_SOURCE = [==[
desc:MB Filter Band (LR4 24 dB/oct Band Splitter)
//tags: filter multiband crossover sound design band-split
//author: ReaperTools

slider1:0<0,2,1{Low Band (LP),Mid Band (BP),High Band (HP)}>Band Mode
slider2:250<20,2000,1>Low/Mid Crossover (Hz)
slider3:3500<1000,20000,1>Mid/High Crossover (Hz)

in_pin:Left Input
in_pin:Right Input
out_pin:Left Output
out_pin:Right Output

// 4th-order Linkwitz-Riley (24 dB/oct) built from two cascaded 2nd-order
// Butterworth sections (Q = 0.70710678). LR4 pairs are magnitude-complementary
// and phase-coherent at the crossover (-6 dB each, 0 deg relative phase),
// so adjacent bands sum flat. Put one instance per band track and set the
// same cutoffs on neighboring bands for a flat-summing split.
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

function coeffs() local(f1, f2, w0, cw, sw, al, a0) (
  f1 = slider2;
  f2 = slider3;
  f2 < f1 ? f2 = f1; // keep Mid band sane if f2 dragged below f1
  // filter A @ f1: LP in Low mode, HP otherwise
  w0 = 2*$pi*f1/srate; cw = cos(w0); sw = sin(w0);
  al = sw*0.70710678; a0 = 1 + al; // alpha = sin/(2*Q), Q = 0.70710678
  slider1 == 0 ? (
    c1[0] = (1-cw)*0.5/a0; c1[1] = (1-cw)/a0; c1[2] = c1[0];
  ) : (
    c1[0] = (1+cw)*0.5/a0; c1[1] = -(1+cw)/a0; c1[2] = c1[0];
  );
  c1[3] = -2*cw/a0; c1[4] = (1-al)/a0;
  // filter B @ f2: LP in Mid mode, HP otherwise
  w0 = 2*$pi*f2/srate; cw = cos(w0); sw = sin(w0);
  al = sw*0.70710678; a0 = 1 + al;
  slider1 == 1 ? (
    c2[0] = (1-cw)*0.5/a0; c2[1] = (1-cw)/a0; c2[2] = c2[0];
  ) : (
    c2[0] = (1+cw)*0.5/a0; c2[1] = -(1+cw)/a0; c2[2] = c2[0];
  );
  c2[3] = -2*cw/a0; c2[4] = (1-al)/a0;
);

@init
c1  = 0;  // filter A coefficients [b0 b1 b2 a1 a2]
c2  = 8;  // filter B coefficients
st1 = 16; // filter A state: [ch*8 + stage*4] -> [x1 x2 y1 y2]
st2 = 32; // filter B state
coeffs(); // re-run here: @slider does not fire on sample-rate changes

@slider
coeffs();

@sample
slider1 == 0 ? ( // Low Band: LR4 low-pass @ f1
  spl0 = bq2(c1, st1, spl0);
  spl1 = bq2(c1, st1 + 8, spl1);
) : slider1 == 2 ? ( // High Band: LR4 high-pass @ f2
  spl0 = bq2(c2, st2, spl0);
  spl1 = bq2(c2, st2 + 8, spl1);
) : ( // Mid Band: LR4 high-pass @ f1 -> LR4 low-pass @ f2
  spl0 = bq2(c1, st1, spl0);
  spl1 = bq2(c1, st1 + 8, spl1);
  spl0 = bq2(c2, st2, spl0);
  spl1 = bq2(c2, st2 + 8, spl1);
);
]==]

local function msg(s) r.ShowConsoleMsg(s .. "\n") end

-- ---------------------------------------------------------------------------
-- Self-deploying JSFX
-- ---------------------------------------------------------------------------

local function ensure_jsfx()
  local dir  = r.GetResourcePath() .. JSFX_REL_DIR
  local path = dir .. "/" .. JSFX_FILENAME
  local f = io.open(path, "r")
  if f then f:close() return path end
  r.RecursiveCreateDirectory(dir, 0)
  f = io.open(path, "w")
  if not f then
    msg("Could not write " .. path)
    return nil
  end
  f:write(JSFX_SOURCE)
  f:close()
  return path
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function get_ext(tr, key)
  local _, v = r.GetSetMediaTrackInfo_String(tr, key, "", false)
  return v
end

local function set_ext(tr, key, val)
  r.GetSetMediaTrackInfo_String(tr, key, val, true)
end

local function find_track_by_guid(guid)
  if not guid or guid == "" then return nil end
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if r.GetTrackGUID(tr) == guid then return tr end
  end
end

local function find_mb_fx(tr)
  for i = 0, r.TrackFX_GetCount(tr) - 1 do
    local _, name = r.TrackFX_GetFXName(tr, i, "")
    if name:lower():find("mb_filter_band", 1, true) then return i end
  end
  return -1
end

-- slider index -> normalized param value
local function set_slider(tr, fx, idx, hz, vmin, vmax)
  local n = (hz - vmin) / (vmax - vmin)
  if n < 0 then n = 0 elseif n > 1 then n = 1 end
  r.TrackFX_SetParam(tr, fx, idx, n)
end

local function ask_freqs(def1, def2)
  local ok, csv = r.GetUserInputs("Multiband Crossovers", 2,
    "Low/Mid Hz (20-2000),Mid/High Hz (1000-20000)",
    tostring(def1) .. "," .. tostring(def2))
  if not ok then return nil end
  local a, b = csv:match("^%s*([%d%.]+)%s*,%s*([%d%.]+)%s*$")
  local f1, f2 = tonumber(a), tonumber(b)
  if not f1 or not f2 then
    msg("Invalid input: enter two numbers, e.g. 250,3500.")
    return nil
  end
  if f1 < S2_MIN or f1 > S2_MAX or f2 < S3_MIN or f2 > S3_MAX or f2 <= f1 then
    msg(("Out of range: Low/Mid %.1f, Mid/High %.1f (Mid/High must be above Low/Mid).")
      :format(f1, f2))
    return nil
  end
  return f1, f2
end

-- ---------------------------------------------------------------------------
-- Sync mode: update crossovers on every band filter of an existing rig
-- ---------------------------------------------------------------------------

local function sync_rig(parent)
  local f1, f2 = ask_freqs(tonumber(get_ext(parent, EXT_F1)) or 250,
                           tonumber(get_ext(parent, EXT_F2)) or 3500)
  if not f1 then return end

  r.Undo_BeginBlock2(0)

  -- {GUID ext key, mode, uses f1 (slider2), uses f2 (slider3)}
  local bands = {
    { EXT_LOW,  0, true,  false },
    { EXT_MID,  1, true,  true  },
    { EXT_HIGH, 2, false, true  },
  }
  local n = 0
  for _, b in ipairs(bands) do
    local tr = find_track_by_guid(get_ext(parent, b[1]))
    if not tr then
      msg("Warning: band track missing (GUID not found), skipped.")
    else
      local fx = find_mb_fx(tr)
      if fx < 0 then
        msg("Warning: no MB_Filter_Band FX found on a band track, skipped.")
      else
        if b[3] then set_slider(tr, fx, 1, f1, S2_MIN, S2_MAX) end
        if b[4] then set_slider(tr, fx, 2, f2, S3_MIN, S3_MAX) end
        n = n + 1
      end
    end
  end

  set_ext(parent, EXT_F1, string.format("%.2f", f1))
  set_ext(parent, EXT_F2, string.format("%.2f", f2))

  r.Undo_EndBlock2(0, "Sync multiband rig crossovers", -1)
  msg(("Synced %d band filter(s): Low/Mid %.1f Hz, Mid/High %.1f Hz.")
    :format(n, f1, f2))
end

-- ---------------------------------------------------------------------------
-- Create mode: build the rig on a plain selected track
-- ---------------------------------------------------------------------------

local function create_rig(src)
  -- guard: don't nest the rig inside an existing folder structure
  if r.GetMediaTrackInfo_Value(src, "I_FOLDERDEPTH") == 1 then
    msg("Selected track is already a folder parent — select a plain (non-folder) track.")
    return
  end

  local _, orig = r.GetTrackName(src)
  if orig == "" then orig = "Track" end
  local f1, f2 = ask_freqs(250, 3500)
  if not f1 then return end

  -- 1-based IP_TRACKNUMBER -> 0-based index (recompute here, insertions shift it)
  local idx = math.floor(r.GetMediaTrackInfo_Value(src, "IP_TRACKNUMBER")) - 1

  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)

  -- turn the source track into the rig folder parent
  r.SetMediaTrackInfo_Value(src, "I_FOLDERDEPTH", 1)
  r.GetSetMediaTrackInfo_String(src, "P_NAME", "[MB Rig] " .. orig, true)

  -- [SOURCE IN]: holds the source audio/FX, feeds the band tracks via sends
  r.InsertTrackAtIndex(idx + 1, false)
  local srcIn = r.GetTrack(0, idx + 1)
  r.GetSetMediaTrackInfo_String(srcIn, "P_NAME", "[SOURCE IN]", true)
  r.SetMediaTrackInfo_Value(srcIn, "I_FOLDERDEPTH", 0)
  r.SetMediaTrackInfo_Value(srcIn, "B_MAINSEND", 0) -- route via sends only

  -- move items + track FX down to [SOURCE IN]
  for i = r.CountTrackMediaItems(src) - 1, 0, -1 do
    r.MoveMediaItemToTrack(r.GetTrackMediaItem(src, i), srcIn)
  end
  for i = r.TrackFX_GetCount(src) - 1, 0, -1 do
    r.TrackFX_CopyToTrack(src, i, srcIn, -1, true)
  end

  -- band child tracks; last one closes the folder (I_FOLDERDEPTH = -1)
  local NAVY  = r.ColorToNative(25, 45, 90)   | 0x1000000 -- deep navy: low
  local AMBER = r.ColorToNative(230, 160, 40) | 0x1000000 -- amber: mid
  local CYAN  = r.ColorToNative(60, 220, 240) | 0x1000000 -- bright cyan: high
  local bands = {
    { name = "[LOW]",  color = NAVY,  mode = 0, u1 = true,  u2 = false },
    { name = "[MID]",  color = AMBER, mode = 1, u1 = true,  u2 = true  },
    { name = "[HIGH]", color = CYAN,  mode = 2, u1 = false, u2 = true  },
  }
  local bandTr = {}
  for i, b in ipairs(bands) do
    r.InsertTrackAtIndex(idx + 1 + i, false)
    local tr = r.GetTrack(0, idx + 1 + i)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", b.name, true)
    r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", i == #bands and -1 or 0)
    r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", b.color)
    bandTr[i] = tr

    local fx = r.TrackFX_AddByName(tr, "SoundDesignTools/MB_Filter_Band", false, -1)
    if fx < 0 then fx = r.TrackFX_AddByName(tr, "MB_Filter_Band", false, -1) end
    if fx < 0 then
      msg("Failed to insert MB_Filter_Band.jsfx on " .. b.name ..
          " (if the file was just written, restart REAPER and run again).")
    else
      r.TrackFX_SetParam(tr, fx, 0, b.mode) -- slider1: band mode
      if b.u1 then set_slider(tr, fx, 1, f1, S2_MIN, S2_MAX) end
      if b.u2 then set_slider(tr, fx, 2, f2, S3_MIN, S3_MAX) end
    end

    -- feed the band from [SOURCE IN]: pre-fader, post-FX send, unity gain
    local send = r.CreateTrackSend(srcIn, tr)
    r.SetTrackSendInfo_Value(srcIn, 0, send, "I_SENDMODE", 1)
    r.SetTrackSendInfo_Value(srcIn, 0, send, "D_VOL", 1.0)
    r.SetTrackSendInfo_Value(srcIn, 0, send, "D_PAN", 0.0)
  end

  -- persist rig state on the parent
  set_ext(src, EXT_PARENT, "1")
  set_ext(src, EXT_LOW,  r.GetTrackGUID(bandTr[1]))
  set_ext(src, EXT_MID,  r.GetTrackGUID(bandTr[2]))
  set_ext(src, EXT_HIGH, r.GetTrackGUID(bandTr[3]))
  set_ext(src, EXT_F1, string.format("%.2f", f1))
  set_ext(src, EXT_F2, string.format("%.2f", f2))

  r.Undo_EndBlock2(0, "Create multiband rig", -1)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  msg(string.format(
    "Multiband rig created on '[MB Rig] %s' (Low/Mid %.1f Hz, Mid/High %.1f Hz).",
    orig, f1, f2))
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function main()
  if not ensure_jsfx() then return end

  if r.CountSelectedTracks(0) ~= 1 then
    msg("Select exactly one track: a source track to build the rig, " ..
        "or a [MB Rig] parent/child to sync crossovers.")
    return
  end

  local tr = r.GetSelectedTrack(0, 0)
  if get_ext(tr, EXT_PARENT) == "1" then
    sync_rig(tr)
    return
  end

  -- running on a band/SOURCE child of an existing rig also syncs
  local par = r.GetParentTrack(tr)
  if par and get_ext(par, EXT_PARENT) == "1" then
    sync_rig(par)
    return
  end

  create_rig(tr)
end

main()