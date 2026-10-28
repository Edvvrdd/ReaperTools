-- @description Create_Or_Sync_Multiband_Rig
-- @author Ed
-- @version 1.1.1
-- @provides [main] .
-- @about
--   # Multiband Splitting Rig — LR4 band-split folder (Multipass-style)
--
--   Run on ONE selected track. A plain track becomes a "[MB Rig] <name>"
--   folder: its items are cloned into color-coded [LOW]/[MID]/[HIGH] child
--   tracks (the "buckets"), each filtered by a phase-coherent Linkwitz-Riley
--   4th-order (24 dB/oct) JSFX. Bands sum flat into the parent, which also
--   keeps your original FX chain (now post-split) and an output visualizer.
--
--   Re-run the script on the rig (parent or any child) to open the control
--   window: two live crossover sliders that sync every band filter at once.
--   Crossover values persist on the parent track (P_EXT).
--
--   Requires: ReaImGui (install via ReaPack).
--   Note: the bucket design duplicates items — live/incoming input should be
--   recorded to the band tracks directly.
-- @changelog
--   v1.1.1
--   - Fixed crossover sync: FX lookup now matches both the JSFX path and
--     description name forms (v1.1 sliders appeared to do nothing)
--   v1.1
--   - Bucket redesign: no [SOURCE IN]; items are cloned into each band child
--   - ReaImGui control window with live crossover sliders (persistent values)
--   - MB_Visualizer.jsfx output scope + band meters on the rig parent
--   - Fixed band-mode param (must be normalized: mode/2)
--   v1.0
--   - Initial release (SOURCE IN + send-based routing)

local r = reaper

if not r.ImGui_CreateContext then
  r.ShowMessageBox("This script requires ReaImGui (install via ReaPack).", "ReaImGui not found", 0)
  return
end

local JSFX_DIR     = "/Effects/SoundDesignTools"
local FILTER_FILE  = "MB_Filter_Band.jsfx"
local VISUAL_FILE  = "MB_Visualizer.jsfx"

-- P_EXT keys stored on the rig parent track
local EXT_PARENT = "P_EXT:MB_RIG_PARENT"
local EXT_LOW    = "P_EXT:MB_RIG_LOW"
local EXT_MID    = "P_EXT:MB_RIG_MID"
local EXT_HIGH   = "P_EXT:MB_RIG_HIGH"
local EXT_F1     = "P_EXT:MB_RIG_F1"
local EXT_F2     = "P_EXT:MB_RIG_F2"

-- MB_Filter_Band.jsfx slider ranges (must match the JSFX)
local S2_MIN, S2_MAX = 20, 2000
local S3_MIN, S3_MAX = 1000, 20000

local BANDS = {
  { key = EXT_LOW,  name = "[LOW]",  mode = 0, u1 = true,  u2 = false,
    rgb = { 25, 45, 90 },   ui = 0x192D5AFF }, -- deep navy
  { key = EXT_MID,  name = "[MID]",  mode = 1, u1 = true,  u2 = true,
    rgb = { 230, 160, 40 }, ui = 0xE6A028FF }, -- amber
  { key = EXT_HIGH, name = "[HIGH]", mode = 2, u1 = false, u2 = true,
    rgb = { 60, 220, 240 }, ui = 0x3CDCF0FF }, -- bright cyan
}

-- ---------------------------------------------------------------------------
-- Self-deploying JSFX
-- ---------------------------------------------------------------------------

local FILTER_SOURCE = [==[
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
gsum = 0; // band-meter accumulator
gcnt = 0;
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

// band energy meter -> shared gmem[4096 + mode], read by MB_Visualizer.jsfx
// ponytail: fixed gmem slot 4096..4098; move if it ever collides
gsum += spl0*spl0 + spl1*spl1;
gcnt += 1;
gcnt >= 1024 ? (
  gmem[4096 + slider1] = sqrt(gsum * 0.00048828125); // rms over both ch, 1024 samples
  gsum = 0; gcnt = 0;
);
]==]

local VISUAL_SOURCE = [==[
desc:MB Rig Visualizer (band meters + output scope)
//tags: analyzer visualizer multiband sound design
//author: ReaperTools

in_pin:Left Input
in_pin:Right Input
out_pin:Left Output
out_pin:Right Output

// Place on the [MB Rig] parent folder. Audio passes through untouched.
// Top: scrolling peak scope of the summed band output.
// Bottom: one bar per band (navy = LOW, amber = MID, cyan = HIGH), fed via
// shared gmem by the MB_Filter_Band.jsfx instances on the band tracks
// (gmem[4096 + mode]). Bands without a running filter show as decayed-out.

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
mid = gfx_h * 0.34;
gfx_set(0.75, 0.82, 0.9, 0.9);
i = 0;
loop(256,
  v = buf[(sc_pos + i) % 256];
  x = (i / 256) * gfx_w;
  gfx_line(x, mid - v * mid, x, mid + v * mid);
  i += 1;
);

// -- band bars ------------------------------------------------------------
bar_y = gfx_h * 0.62;
bar_h = min(16, (gfx_h - bar_y - 8) / 3 - 4);
lbl_w = 52;
i = 0;
loop(3,
  v = max(gmem[4096 + i], disp[i] * 0.92); // peak-hold with decay
  disp[i] = v;
  db = 20 * log10(max(v, 0.00001));
  frac = (db + 60) / 60;
  frac < 0 ? frac = 0;
  y = bar_y + i * (bar_h + 4);
  i == 0 ? gfx_set(0.10, 0.18, 0.35, 1)   // LOW  navy
  : i == 1 ? gfx_set(0.90, 0.63, 0.16, 1) // MID  amber
  : gfx_set(0.24, 0.86, 0.94, 1);         // HIGH cyan
  gfx_rect(0, y, frac * (gfx_w - lbl_w), bar_h, 1);
  gfx_set(0.85, 0.88, 0.92, 0.9);
  gfx_x = gfx_w - lbl_w + 6;
  gfx_y = y;
  gfx_drawnumber(db, 1);
  i += 1;
);
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
     and write_jsfx(VISUAL_FILE, VISUAL_SOURCE)
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

local function find_fx(tr, needle)
  -- match path ("...MB_Filter_Band") and desc ("MB Filter Band (...)") forms:
  -- strip all non-alphanumerics from both before comparing
  local want = needle:lower():gsub("[^%w]", "")
  for i = 0, r.TrackFX_GetCount(tr) - 1 do
    local _, name = r.TrackFX_GetFXName(tr, i, "")
    if name:lower():gsub("[^%w]", ""):find(want, 1, true) then return i end
  end
  return -1
end

-- hz -> normalized FX param for slider2/slider3
local function set_slider(tr, fx, idx, hz, vmin, vmax)
  local n = (hz - vmin) / (vmax - vmin)
  if n < 0 then n = 0 elseif n > 1 then n = 1 end
  r.TrackFX_SetParam(tr, fx, idx, n)
end

-- ---------------------------------------------------------------------------
-- Item cloning (audio items; MIDI can't be cloned via source copy)
-- ---------------------------------------------------------------------------

local ITEM_PROPS = {
  "D_POSITION", "D_LENGTH", "D_VOL", "D_PAN", "D_PLAYRATE", "S_OFFS",
  "B_LOOPSRC", "B_MUTE", "D_FADEINLEN", "D_FADEOUTLEN",
  "D_FADEINLEN_AUTO", "D_FADEOUTLEN_AUTO", "C_FADEINSHAPE", "C_FADEOUTSHAPE",
  "D_SNAPOFFSET", "I_CUSTOMCOLOR",
}

-- ponytail: clones active take only, take FX/envs not copied; MIDI items are
-- left on the parent (warned) — upgrade path: copy/paste actions or take copies
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

-- ---------------------------------------------------------------------------
-- Create mode: bucket rig on a plain selected track
-- ---------------------------------------------------------------------------

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
  -- (now post-split, processing the summed bands) and gains the visualizer
  r.SetMediaTrackInfo_Value(src, "I_FOLDERDEPTH", 1)
  r.GetSetMediaTrackInfo_String(src, "P_NAME", "[MB Rig] " .. orig, true)

  local idx = math.floor(r.GetMediaTrackInfo_Value(src, "IP_TRACKNUMBER")) - 1

  -- collect items once (originals are removed after cloning)
  local items = {}
  for i = 0, r.CountTrackMediaItems(src) - 1 do
    items[#items + 1] = r.GetTrackMediaItem(src, i)
  end

  local bandTr, midi_left = {}, 0
  for i, b in ipairs(BANDS) do
    r.InsertTrackAtIndex(idx + i, false)
    local tr = r.GetTrack(0, idx + i)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", b.name, true)
    r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", i == #BANDS and -1 or 0)
    r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR",
      r.ColorToNative(b.rgb[1], b.rgb[2], b.rgb[3]) | 0x1000000)
    bandTr[i] = tr

    -- bucket: clone every item into this band
    for _, it in ipairs(items) do
      if not clone_item(it, tr) then midi_left = midi_left + 1 end
    end

    -- band filter (defaults 250 / 3500 Hz, adjustable in the control window)
    local fx = r.TrackFX_AddByName(tr, "SoundDesignTools/MB_Filter_Band", false, -1)
    if fx < 0 then fx = r.TrackFX_AddByName(tr, "MB_Filter_Band", false, -1) end
    if fx < 0 then
      msg("Failed to insert MB_Filter_Band.jsfx on " .. b.name ..
          " (if the file was just written, restart REAPER and run again).")
    else
      r.TrackFX_SetParam(tr, fx, 0, b.mode / 2)   -- slider1: mode, normalized
      if b.u1 then set_slider(tr, fx, 1, 250, S2_MIN, S2_MAX) end
      if b.u2 then set_slider(tr, fx, 2, 3500, S3_MIN, S3_MAX) end
    end
  end

  -- originals: remove cloned ones, leave unclonable (MIDI) items on the parent
  for _, it in ipairs(items) do
    local tk = r.GetActiveTake(it)
    local ok = tk and r.GetMediaSourceType(r.GetMediaItemTake_Source(tk))
    if ok and ok ~= 2 and ok ~= -1 then r.DeleteTrackMediaItem(src, it) end
  end

  -- visualizer on the parent (passthrough): scope + per-band meters
  local vfx = r.TrackFX_AddByName(src, "SoundDesignTools/MB_Visualizer", false, -1)
  if vfx < 0 then
    msg("Failed to insert MB_Visualizer.jsfx on the rig parent.")
  end

  -- persist rig state on the parent
  set_ext(src, EXT_PARENT, "1")
  set_ext(src, EXT_LOW,  r.GetTrackGUID(bandTr[1]))
  set_ext(src, EXT_MID,  r.GetTrackGUID(bandTr[2]))
  set_ext(src, EXT_HIGH, r.GetTrackGUID(bandTr[3]))
  set_ext(src, EXT_F1, "250.00")
  set_ext(src, EXT_F2, "3500.00")

  r.Undo_EndBlock2(0, "Create multiband rig", -1)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()

  if midi_left > 0 then
    msg(string.format("Warning: %d MIDI item(s) can't be cloned into buckets — " ..
      "they were left on the parent (they play unfiltered). Move/copy them manually.", midi_left))
  end
  msg("Multiband rig created on '[MB Rig] " .. orig .. "' (250 Hz / 3500 Hz — adjust in the control window).")
  return src
end

-- ---------------------------------------------------------------------------
-- Crossover sync (used by the control window)
-- ---------------------------------------------------------------------------

local parent      -- rig parent track (GUI target)
local f1, f2 = 250, 3500

local function apply_crossovers(commit)
  for _, b in ipairs(BANDS) do
    local tr = find_track_by_guid(get_ext(parent, b.key))
    if tr then
      local fx = find_fx(tr, "MB_Filter_Band")
      if fx >= 0 then
        if b.u1 then set_slider(tr, fx, 1, f1, S2_MIN, S2_MAX) end
        if b.u2 then set_slider(tr, fx, 2, f2, S3_MIN, S3_MAX) end
      end
    end
  end
  if commit then
    set_ext(parent, EXT_F1, string.format("%.2f", f1))
    set_ext(parent, EXT_F2, string.format("%.2f", f2))
  end
end

-- ---------------------------------------------------------------------------
-- ReaImGui control window
-- ---------------------------------------------------------------------------

local ctx = r.ImGui_CreateContext("MBRig")

-- trimmed QikWhoosh theme (0xRRGGBBAA)
local theme = {
  WindowBg = 0x1A1A1AFF, Border = 0x444444FF,
  Text = 0xE0E0E0FF, TextDisabled = 0x888888FF,
  FrameBg = 0x00000060, SliderGrab = 0x2D6D8CFF, SliderGrabActive = 0x33A07CFF,
  WindowRounding = 6, FrameRounding = 4, GrabRounding = 3,
  WindowPaddingX = 10, WindowPaddingY = 8, FramePaddingX = 6, FramePaddingY = 4,
}

local function push_theme()
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), theme.WindowPaddingX, theme.WindowPaddingY)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(),  theme.FramePaddingX,  theme.FramePaddingY)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(), theme.WindowRounding)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), theme.FrameRounding)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabRounding(),  theme.GrabRounding)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(),           theme.WindowBg)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(),             theme.Border)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),               theme.Text)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TextDisabled(),       theme.TextDisabled)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(),            theme.FrameBg)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SliderGrab(),         theme.SliderGrab)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SliderGrabActive(),   theme.SliderGrabActive)
end

local function pop_theme()
  r.ImGui_PopStyleVar(ctx, 5)
  r.ImGui_PopStyleColor(ctx, 7)
end

local started, hidden_frames = false, 0

local function crossover_slider(label, val, vmin, vmax, is_f1)
  local changed, nv = r.ImGui_SliderDouble(ctx, label, val, vmin, vmax, "%.0f Hz")
  if changed then
    if is_f1 then
      f1 = nv
      if f2 <= f1 then f2 = math.min(S3_MAX, f1 + 1) end
    else
      f2 = nv
      if f2 <= f1 then f1 = math.max(S2_MIN, f2 - 1) end
    end
    apply_crossovers(false) -- live while dragging
  end
  if r.ImGui_IsItemDeactivatedAfterEdit(ctx) then
    r.Undo_BeginBlock2(0)
    apply_crossovers(true)  -- persist to P_EXT on release
    r.Undo_EndBlock2(0, "MB rig crossovers", -1)
  end
end

local function loop()
  -- cached parent handle may go stale (delete/undo) — validate before use
  if not r.ValidatePtr2(0, parent, "MediaTrack*") then return end

  r.ImGui_SetNextWindowSize(ctx, 380, 230, r.ImGui_Cond_FirstUseEver())
  push_theme()
  local vis, open = r.ImGui_Begin(ctx, "MB Rig Control", true,
    r.ImGui_WindowFlags_NoCollapse())
  if vis then
    local _, pname = r.GetTrackName(parent)
    r.ImGui_Text(ctx, pname)
    r.ImGui_Separator(ctx)

    for _, b in ipairs(BANDS) do
      r.ImGui_TextColored(ctx, b.ui, "■ " .. b.name)
      if b.u2 then r.ImGui_SameLine(ctx) end
    end
    r.ImGui_Spacing(ctx)

    crossover_slider("Low/Mid Crossover",  f1, S2_MIN, S2_MAX, true)
    crossover_slider("Mid/High Crossover", f2, S3_MIN, S3_MAX, false)

    r.ImGui_Spacing(ctx)
    r.ImGui_TextDisabled(ctx, "Filters update live while dragging.")
    r.ImGui_TextDisabled(ctx, "Values persist on the rig parent track.")
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
    if r.ImGui_DestroyContext then
      r.defer(function() r.ImGui_DestroyContext(ctx) end)
    end
    return
  end
  r.defer(loop)
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function main()
  if not ensure_jsfx_files() then return end

  if r.CountSelectedTracks(0) ~= 1 then
    msg("Select exactly one track: a source track to build the rig, " ..
        "or a [MB Rig] parent/child to open the control window.")
    return
  end

  local tr = r.GetSelectedTrack(0, 0)
  if get_ext(tr, EXT_PARENT) == "1" then
    parent = tr
  else
    local par = r.GetParentTrack(tr)
    if par and get_ext(par, EXT_PARENT) == "1" then
      parent = par -- run on a band child: open the rig's control window
    else
      parent = create_rig(tr)
    end
  end
  if not parent then return end

  f1 = tonumber(get_ext(parent, EXT_F1)) or f1
  f2 = tonumber(get_ext(parent, EXT_F2)) or f2
  r.defer(loop)
end

main()