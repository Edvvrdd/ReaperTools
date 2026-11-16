-- @description FX Randomizer & Modulator (ReaRandomMod)
-- @author Ed
-- @version 1.0.0
-- @provides [main] .
-- @about
--   # FX Randomizer & Modulator
--
--   Randomizes the parameters of the focused (or last-touched) track FX in one
--   click, and can wire up REAPER's native parameter-modulation LFOs on a few
--   of the rolled parameters at the same time.
--
--   - Amount: how far each parameter moves from its current value toward a
--     random target (100% = fully random).
--   - Avoid extremes: random targets stay inside [margin, 1 - margin].
--   - Guardrails: bypass/delta/oversampling/preset-style params are never
--     touched; wet/dry/mix and gain/volume/output params are protected by
--     default.
--   - Lock any parameter (a happy accident) and re-roll the rest.
--   - Every roll is one undo point (Undo button or Ctrl+Z).
--   - Hotkey: R = roll (while the window is focused).
--
--   Requires REAPER 7.0+ and ReaImGui 0.9+ (install via ReaPack).
-- @changelog
--   v1.0.0
--   - Initial release

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.ShowMessageBox("FX Randomizer & Modulator requires ReaImGui.\n\n" ..
    "Install it via Extensions > ReaPack > Browse packages > " ..
    "\"ReaImGui: ReaScript binding for Dear ImGui\", then restart REAPER.",
    "ReaImGui not found", 0)
  return
end
if not r.GetTouchedOrFocusedFX then
  r.ShowMessageBox("FX Randomizer & Modulator requires REAPER 7.0 or newer.", "REAPER too old", 0)
  return
end

package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.9'

math.randomseed(os.time() + math.floor((r.time_precise() % 1) * 1000000))
math.random()

---------------------------------------------------------------------
-- Settings (ExtState "ReaRandomMod")
---------------------------------------------------------------------

local SECTION = "ReaRandomMod"
local cfg = {
  amount       = 0.5,   -- 0..1 blend from current value toward a random target
  margin       = 0.05,  -- random targets stay inside [margin, 1 - margin]
  protect_mix  = true,  -- skip wet/dry/mix
  protect_gain = true,  -- skip gain/volume/output/level
  mod_count    = 0,     -- LFOs added per roll (0 = off)
  mod_shape    = 6,     -- index into SHAPES; last entry = random shape per LFO
  mod_speed    = 2.0,   -- max LFO speed (Hz)
  mod_depth    = 0.3,   -- max LFO strength (0..1)
}

for k, v in pairs(cfg) do
  local s = r.GetExtState(SECTION, k)
  if s ~= "" then
    if type(v) == "boolean" then cfg[k] = (s == "1") else cfg[k] = tonumber(s) or v end
  end
end

local function save_cfg()
  for k, v in pairs(cfg) do
    if type(v) == "boolean" then v = v and "1" or "0" end
    r.SetExtState(SECTION, k, tostring(v), true)
  end
end
r.atexit(save_cfg)

-- REAPER LFO shape values, in the order of REAPER's own shape dropdown
local SHAPES = "Sine\0Square\0Saw L\0Saw R\0Triangle\0Random\0Any (per LFO)\0"
local SHAPE_ANY = 6

---------------------------------------------------------------------
-- Guardrails (plain, case-insensitive substring match on param names)
---------------------------------------------------------------------

local GUARD_SYSTEM = { "bypass", "delta", "mute", "solo", "oversampl", "quality",
                       "latency", "preset", "program", "midi" }
local GUARD_MIX    = { "wet", "dry", "mix" }
local GUARD_GAIN   = { "gain", "volume", "output", "level", "master", "makeup",
                       "trim", "input", "ceiling" }

local function matches(lname, list)
  for _, w in ipairs(list) do
    if lname:find(w, 1, true) then return true end
  end
  return false
end

-- returns why a param is protected, or nil if it may be randomized
local function guard_reason(lname)
  if matches(lname, GUARD_SYSTEM) then return "system" end
  if cfg.protect_mix and matches(lname, GUARD_MIX) then return "mix" end
  if cfg.protect_gain and matches(lname, GUARD_GAIN) then return "gain" end
end

---------------------------------------------------------------------
-- Target FX (focused window first, then last-touched parameter)
---------------------------------------------------------------------

local T = { track = nil, fx = -1, guid = nil, name = "", params = {} }
local locks = {}   -- [fx guid] = { [param index] = true }  (session only)
local pin = false
local status = "Open or touch a track FX to start."

local function load_target(tr, fx, guid)
  T.track, T.fx, T.guid = tr, fx, guid
  T.name = select(2, r.TrackFX_GetFXName(tr, fx))
  T.params = {}
  for p = 0, r.TrackFX_GetNumParams(tr, fx) - 1 do
    local _, name = r.TrackFX_GetParamName(tr, fx, p)
    local _, _, _, _, toggle = r.TrackFX_GetParameterStepSizes(tr, fx, p)
    T.params[p + 1] = { name = name, lname = name:lower(), toggle = toggle }
  end
  locks[guid] = locks[guid] or {}
end

-- re-find the FX by GUID after the chain was reordered
-- ponytail: top-level chain only; container / rec-input FX are re-found
-- only while their index is unchanged
local function current_fx(tr, fx, guid)
  if not r.ValidatePtr2(0, tr, 'MediaTrack*') then return nil end
  if r.TrackFX_GetFXGUID(tr, fx) == guid then return fx end
  for i = 0, r.TrackFX_GetCount(tr) - 1 do
    if r.TrackFX_GetFXGUID(tr, i) == guid then return i end
  end
end

local function refresh_target()
  if not pin then
    for _, mode in ipairs({ 1, 0 }) do -- 1 = focused FX, 0 = last-touched param
      local ok, ti, ii, _, fi = r.GetTouchedOrFocusedFX(mode)
      local tr = ok and ii == -1 and (ti == -1 and r.GetMasterTrack(0) or r.GetTrack(0, ti))
      local guid = tr and r.TrackFX_GetFXGUID(tr, fi)
      if guid then
        if guid ~= T.guid then load_target(tr, fi, guid) else T.track, T.fx = tr, fi end
        break
      end
    end
  end
  -- keep the current target while our own window has focus (or when pinned)
  if T.guid then
    local fx = current_fx(T.track, T.fx, T.guid)
    if not fx then
      T.guid, pin, status = nil, false, "Target FX was removed."
    elseif r.TrackFX_GetNumParams(T.track, fx) ~= #T.params then
      load_target(T.track, fx, T.guid) -- plug-in changed its parameter list
    else
      T.fx = fx
    end
  end
end

---------------------------------------------------------------------
-- Parameter modulation (native REAPER LFO via named config params)
---------------------------------------------------------------------

local function pm_get(i, key)
  local ok, v = r.TrackFX_GetNamedConfigParm(T.track, T.fx, ("param.%d.%s"):format(i, key))
  return ok and v or nil
end

local function pm_set(i, key, v)
  r.TrackFX_SetNamedConfigParm(T.track, T.fx, ("param.%d.%s"):format(i, key), tostring(v))
end

local function is_modulated(i)
  return pm_get(i, "mod.active") == "1"
end

local function clear_mod(i)
  pm_set(i, "lfo.active", 0)
  pm_set(i, "mod.active", 0)
end

local function add_lfo(i, baseline)
  local shape = cfg.mod_shape == SHAPE_ANY and math.random(0, SHAPE_ANY - 1) or cfg.mod_shape
  local max_hz = math.max(0.06, cfg.mod_speed)
  pm_set(i, "mod.active", 1)
  pm_set(i, "mod.visible", 0)               -- don't pop up the modulation window
  pm_set(i, "mod.baseline", baseline)
  pm_set(i, "lfo.active", 1)
  pm_set(i, "lfo.shape", shape)
  pm_set(i, "lfo.dir", 0)                   -- centered: swings around the baseline
  pm_set(i, "lfo.temposync", 0)
  pm_set(i, "lfo.speed", 0.05 * (max_hz / 0.05) ^ math.random()) -- log-uniform 0.05..max Hz
  pm_set(i, "lfo.strength", cfg.mod_depth * (0.25 + 0.75 * math.random()))
  pm_set(i, "lfo.phase", math.random())
end

---------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------

local function free_params() -- unlocked, unguarded param indices
  local out, lk = {}, locks[T.guid]
  for p, info in ipairs(T.params) do
    local i = p - 1
    if not lk[i] and not guard_reason(info.lname) then out[#out + 1] = i end
  end
  return out
end

local function roll()
  local tr, fx = T.track, T.fx
  local pool, newv = free_params(), {}
  if #pool == 0 then status = "Nothing to roll — everything is locked or protected." return end

  r.Undo_BeginBlock2(0)
  for _, i in ipairs(pool) do
    local cur = r.TrackFX_GetParamNormalized(tr, fx, i)
    local v
    if T.params[i + 1].toggle then
      v = math.random() < cfg.amount and (math.random() < 0.5 and 0 or 1) or cur
    else
      local target = cfg.margin + math.random() * (1 - 2 * cfg.margin)
      v = cur + (target - cur) * cfg.amount
    end
    newv[i] = v
    r.TrackFX_SetParamNormalized(tr, fx, i, v)
    if is_modulated(i) then
      if cfg.mod_count > 0 then clear_mod(i) else pm_set(i, "mod.baseline", v) end
    end
  end

  -- LFOs on N random continuous params from the rolled pool
  local added = 0
  if cfg.mod_count > 0 then
    for k = #pool, 2, -1 do
      local j = math.random(k)
      pool[k], pool[j] = pool[j], pool[k]
    end
    for _, i in ipairs(pool) do
      if added >= cfg.mod_count then break end
      if not T.params[i + 1].toggle then
        add_lfo(i, newv[i])
        added = added + 1
      end
    end
  end
  r.Undo_EndBlock2(0, "ReaRandomMod: roll " .. T.name, 2) -- 2 = track FX state

  status = string.format("Rolled %d param(s)%s.", #pool,
    added > 0 and string.format(", %d LFO(s)", added) or "")
end

local function clear_all_mod()
  local n = 0
  r.Undo_BeginBlock2(0)
  for _, i in ipairs(free_params()) do
    if is_modulated(i) then clear_mod(i) n = n + 1 end
  end
  r.Undo_EndBlock2(0, "ReaRandomMod: clear modulation", 2)
  status = "Cleared modulation on " .. n .. " unlocked param(s)."
end

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------

local ctx = ImGui.CreateContext("ReaRandomMod")
local clipper = ImGui.CreateListClipper(ctx)
ImGui.Attach(ctx, clipper)

local filter = ""
local COL_ROLL, COL_ROLL_HOV = 0x2D6D8CFF, 0x33A07CFF
local COL_LFO = 0x40E080FF

local function tooltip(text)
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, text) end
end

local function slider(label, v, lo, hi, fmt, tip)
  ImGui.SetNextItemWidth(ctx, 150)
  local _, nv = ImGui.SliderDouble(ctx, label, v, lo, hi, fmt)
  tooltip(tip)
  return nv
end

local function draw_controls()
  cfg.amount = slider("Amount", cfg.amount * 100, 0, 100, "%.0f%%",
    "How far each parameter moves toward its random target.\n100% = fully random.") / 100
  ImGui.SameLine(ctx)
  cfg.margin = slider("Avoid extremes", cfg.margin * 100, 0, 40, "%.0f%%",
    "Random targets stay this far away from 0% and 100%.") / 100

  local _
  _, cfg.protect_mix = ImGui.Checkbox(ctx, "Protect wet/dry/mix", cfg.protect_mix)
  ImGui.SameLine(ctx)
  _, cfg.protect_gain = ImGui.Checkbox(ctx, "Protect gain/volume/output", cfg.protect_gain)
  tooltip("Prevents level blow-ups. Bypass, delta, oversampling and\npreset-style parameters are always protected.")

  ImGui.SeparatorText(ctx, "Modulation (native REAPER LFO)")
  ImGui.SetNextItemWidth(ctx, 150)
  _, cfg.mod_count = ImGui.SliderInt(ctx, "LFOs per roll", cfg.mod_count, 0, 16)
  tooltip("Adds an LFO to this many randomly picked rolled parameters.\n" ..
    "0 = off (existing modulation is kept, its baseline follows the roll).\n" ..
    "Above 0, modulation on unlocked parameters is re-rolled.")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 150)
  _, cfg.mod_shape = ImGui.Combo(ctx, "Shape", cfg.mod_shape, SHAPES)
  cfg.mod_speed = slider("Max speed", cfg.mod_speed, 0.1, 8, "%.2f Hz",
    "Each LFO gets a random speed between 0.05 Hz and this.")
  ImGui.SameLine(ctx)
  cfg.mod_depth = slider("Max depth", cfg.mod_depth * 100, 1, 100, "%.0f%%",
    "Each LFO gets a random strength up to this.") / 100
end

local function draw_actions()
  ImGui.Separator(ctx)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, COL_ROLL)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, COL_ROLL_HOV)
  if ImGui.Button(ctx, "ROLL  (R)", 160, 36) then roll() end
  ImGui.PopStyleColor(ctx, 2)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Undo", 80, 36) then r.Main_OnCommand(40029, 0) end -- Edit: Undo
  tooltip("Undo: " .. (r.Undo_CanUndo2(0) or "nothing"))
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Clear mod", 90, 36) then clear_all_mod() end
  tooltip("Remove parameter modulation from all unlocked, unprotected parameters.")
end

local function draw_params()
  local lk = locks[T.guid]
  local fl = filter:lower()
  local rows, n_locked = {}, 0
  for p, info in ipairs(T.params) do
    if lk[p - 1] then n_locked = n_locked + 1 end
    if fl == "" or info.lname:find(fl, 1, true) then rows[#rows + 1] = p - 1 end
  end

  ImGui.SeparatorText(ctx, string.format("Parameters (%d locked / %d)", n_locked, #T.params))
  ImGui.SetNextItemWidth(ctx, 160)
  local _
  _, filter = ImGui.InputText(ctx, "##filter", filter)
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, "filter")
  -- bulk lock ops apply to the filtered, unprotected rows
  local function bulk(fn)
    for _, i in ipairs(rows) do
      if not guard_reason(T.params[i + 1].lname) then lk[i] = fn(lk[i]) end
    end
  end
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, "Lock all") then bulk(function() return true end) end
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, "Unlock all") then bulk(function() return nil end) end
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, "Invert") then bulk(function(v) return not v or nil end) end

  local flags = ImGui.TableFlags_ScrollY | ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerV
  if ImGui.BeginTable(ctx, "params", 3, flags, 0, -ImGui.GetFrameHeightWithSpacing(ctx)) then
    ImGui.TableSetupScrollFreeze(ctx, 0, 1)
    ImGui.TableSetupColumn(ctx, "Lock", ImGui.TableColumnFlags_WidthFixed, 36)
    ImGui.TableSetupColumn(ctx, "Parameter", ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableSetupColumn(ctx, "Value", ImGui.TableColumnFlags_WidthFixed, 150)
    ImGui.TableHeadersRow(ctx)
    ImGui.ListClipper_Begin(clipper, #rows)
    while ImGui.ListClipper_Step(clipper) do
      local first, last = ImGui.ListClipper_GetDisplayRange(clipper)
      for row = first + 1, last do
        local i = rows[row]
        local info = T.params[i + 1]
        local why = guard_reason(info.lname)
        ImGui.TableNextRow(ctx)
        ImGui.TableNextColumn(ctx)
        if why then
          ImGui.TextDisabled(ctx, "--")
        else
          local changed, v = ImGui.Checkbox(ctx, "##lk" .. i, lk[i] == true)
          if changed then lk[i] = v or nil end
        end
        ImGui.TableNextColumn(ctx)
        if why then
          ImGui.TextDisabled(ctx, info.name .. "  [protected: " .. why .. "]")
        else
          ImGui.Text(ctx, info.name)
        end
        ImGui.TableNextColumn(ctx)
        local _, val = r.TrackFX_GetFormattedParamValue(T.track, T.fx, i)
        if is_modulated(i) then
          ImGui.TextColored(ctx, COL_LFO, "~ " .. val)
          tooltip("Parameter modulation active")
        else
          ImGui.Text(ctx, val)
        end
      end
    end
    ImGui.EndTable(ctx)
  end
end

local function loop()
  refresh_target()

  ImGui.SetNextWindowSize(ctx, 560, 640, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "FX Randomizer & Modulator", true)
  if visible then
    if T.guid then
      local _, tname = r.GetTrackName(T.track)
      ImGui.Text(ctx, tname .. "  >  " .. T.name)
    else
      ImGui.TextDisabled(ctx, "No target — open or touch a parameter of a track FX.")
    end
    ImGui.SameLine(ctx)
    ImGui.BeginDisabled(ctx, not T.guid)
    local _
    _, pin = ImGui.Checkbox(ctx, "Pin", pin)
    tooltip("Keep this FX as the target even when another FX is focused/touched.")
    ImGui.EndDisabled(ctx)

    ImGui.Separator(ctx)
    draw_controls()

    ImGui.BeginDisabled(ctx, not T.guid)
    draw_actions()
    ImGui.EndDisabled(ctx)

    if T.guid then
      draw_params()
      if ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows)
         and not ImGui.IsAnyItemActive(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_R, false) then
        roll()
      end
    end

    ImGui.TextDisabled(ctx, status)
    ImGui.End(ctx)
  end

  if open then r.defer(loop) end
end

r.defer(loop)
