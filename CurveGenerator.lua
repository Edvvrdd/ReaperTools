-- CurveGenerator.lua
-- Turns a REAPER audio item into a haptic feedback curve and exports it for:
--   Unreal (Time,Value CSV) / Unity (AnimationCurve JSON) / Godot 4 (Curve .tres)
-- UI: curve preview, drag points to edit, right-click to add/delete, Export button.
-- Controls: left-drag = move point | right-click point = delete | right-click empty = add | Esc = close
-- Sliders: resolution (samples/sec) and total curve duration (time-stretch)

local M = {}

local function n(x) return string.format("%g", x) end

function M.clamp(x, lo, hi) return x < lo and lo or (x > hi and hi or x) end

function M.render_csv(points)
  local out = { "Time,Value" }
  for i, p in ipairs(points) do out[i + 1] = n(p.t) .. "," .. n(p.v) end
  return table.concat(out, "\n") .. "\n"
end

function M.render_unity(points)
  local keys = {}
  for i, p in ipairs(points) do
    keys[i] = string.format('{"time":%s,"value":%s,"inTangent":0,"outTangent":0}', n(p.t), n(p.v))
  end
  return '{"keys":[' .. table.concat(keys, ",") .. "]}\n"
end

-- Godot Curve resources are normalized to x in 0..1; absolute duration goes in a comment.
function M.render_godot(points)
  local tmax = points[#points].t
  if tmax <= 0 then tmax = 1 end
  local buf = {}
  for i, p in ipairs(points) do
    buf[i] = string.format("%s, %s, 0, 0, 0", n(p.t / tmax), n(p.v))
  end
  return string.format(
    '; Haptic curve, duration %ss (x normalized 0..1)\n[gd_resource type="Curve" format=3]\n\n[resource]\n_data = {\n"points": PackedFloat32Array(%s),\n"point_count": %d\n}\n',
    n(tmax), table.concat(buf, ", "), #points)
end

-- Outside REAPER this module just returns the renderers (for CurveGenerator_test.lua).
if not reaper then return M end

-------------------------------------------------------------------------------
-- REAPER below
-------------------------------------------------------------------------------

local rate = 60 -- Hz, standard for responsive haptics

local function show_err(msg) reaper.ShowMessageBox(msg, "CurveGenerator", 0) end

-- Sample the take's peak envelope into editable {t=, v=} points.
local function sample_points(take, hz)
  local item = reaper.GetMediaItemTake_Item(take)
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local step = 1 / hz
  local total = math.max(1, math.floor(item_len * hz))

  local accessor = reaper.CreateTakeAudioAccessor(take)
  local src = reaper.GetMediaItemTake_Source(take)
  local sr = reaper.GetMediaSourceSampleRate(src)
  local nch = reaper.GetMediaSourceNumChannels(src)
  local window = math.max(1, math.floor(sr * step))
  local buffer = reaper.new_array(window * nch)

  local points = {}
  for i = 0, total do
    local t = i * step
    buffer.clear()
    reaper.GetAudioAccessorSamples(accessor, sr, nch, t, window, buffer)
    local peak = 0
    for _, s in ipairs(buffer.table()) do
      local a = s < 0 and -s or s
      if a > peak then peak = a end
    end
    points[#points + 1] = { t = t, v = M.clamp(peak, 0, 1) }
  end
  reaper.DestroyAudioAccessor(accessor)
  return points, item_len
end

local take = reaper.GetSelectedMediaItem(0, 0) and reaper.GetActiveTake(reaper.GetSelectedMediaItem(0, 0))
if not take or reaper.TakeIsMIDI(take) then
  show_err("Please select an audio item first.")
  return
end

local points, item_len = sample_points(take, rate)
local duration = item_len -- curve span in seconds, adjustable via slider

-------------------------------------------------------------------------------
-- UI
-------------------------------------------------------------------------------

local W, H, BAR = 960, 540, 100
local PL = { x = 80, y = BAR + 30, w = W - 120, h = H - BAR - 100 }
local fmt = 1
local drag_idx, drag_slider
local prev_left, prev_right = false, false
local mx, my = 0, 0

local FORMATS = {
  { name = "Unreal (CSV)", ext = ".csv", file = "force_feedback_curve.csv",
    filter = "CSV files (*.csv)\0*.csv\0All files (*.*)\0*.*\0", render = function() return M.render_csv(points) end },
  { name = "Unity (JSON)", ext = ".json", file = "haptic_curve.json",
    filter = "JSON files (*.json)\0*.json\0All files (*.*)\0*.*\0", render = function() return M.render_unity(points) end },
  { name = "Godot 4 (.tres)", ext = ".tres", file = "haptic_curve.tres",
    filter = "Godot resource (*.tres)\0*.tres\0All files (*.*)\0*.*\0", render = function() return M.render_godot(points) end },
}

local BUTTONS = {
  { id = "fmt", x = 12, y = 10, w = 190, h = 32 },
  { id = "export", x = 214, y = 10, w = 130, h = 32 },
  { id = "rescan", x = 356, y = 10, w = 140, h = 32 },
}

local function set_duration(newd)
  newd = math.max(0.01, newd)
  local s = newd / duration
  for _, p in ipairs(points) do p.t = p.t * s end
  duration = newd
end

local function resample()
  local pts
  pts, item_len = sample_points(take, rate)
  local s = duration / item_len
  for _, p in ipairs(pts) do p.t = p.t * s end
  points = pts
end

local SLIDERS = {
  { id = "rate", label = "Resolution", x = 12, y = 68, w = 380,
    min = 5, max = 240, get = function() return rate end,
    set = function(v) rate = math.floor(v + 0.5) end,
    display = function(v) return string.format("%d Hz", math.floor(v + 0.5)) end },
  { id = "dur", label = "Duration", x = 420, y = 68, w = 380,
    min = item_len * 0.25, max = item_len * 4,
    get = function() return duration end, set = set_duration,
    display = function(v) return n(v) .. "s" end },
}

local function to_x(t) return PL.x + (t / duration) * PL.w end
local function to_y(v) return PL.y + (1 - v) * PL.h end
local function from_x(x) return (x - PL.x) / PL.w * duration end
local function from_y(y) return 1 - (y - PL.y) / PL.h end

local function nearest(x, y, max_dist)
  local best, bd = nil, max_dist or 12
  for i, p in ipairs(points) do
    local px, py = to_x(p.t), to_y(p.v)
    local d = ((px - x) ^ 2 + (py - y) ^ 2) ^ 0.5
    if d < bd then best, bd = i, d end
  end
  return best
end

local function move_point(i, x, y)
  local lo = (points[i - 1] and points[i - 1].t or 0) + 0.001
  local hi = (points[i + 1] and points[i + 1].t or duration) - 0.001
  points[i].t = M.clamp(from_x(x), math.max(0, lo), math.min(duration, hi))
  points[i].v = M.clamp(from_y(y), 0, 1)
end

local function add_point(t, v)
  t = M.clamp(t, 0, duration)
  v = M.clamp(v, 0, 1)
  local idx = #points + 1
  for i, p in ipairs(points) do
    if t < p.t then idx = i break end
  end
  table.insert(points, idx, { t = t, v = v })
end

local function do_export()
  local f = FORMATS[fmt]
  local filename
  if reaper.JS_Dialog_BrowseForSaveFile then
    local ret, fn = reaper.JS_Dialog_BrowseForSaveFile("Export " .. f.name, "", f.file, f.filter)
    if ret and fn ~= "" then filename = fn end
  end
  if not filename then
    local ok, input = reaper.GetUserInputs("Export " .. f.name, 1, "Save Path (" .. f.ext .. "):",
      reaper.GetProjectPath("") .. "/" .. f.file)
    if not ok then return end
    filename = input
  end
  if filename:sub(-#f.ext):lower() ~= f.ext then filename = filename .. f.ext end

  local file = io.open(filename, "w")
  if not file then return show_err("Could not open file for writing.") end
  file:write(f.render())
  file:close()
  show_err(f.name .. " curve exported to:\n" .. filename)
end

local function hit(b) return mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h end

local function slider_value(sl)
  return sl.min + M.clamp((mx - sl.x) / sl.w, 0, 1) * (sl.max - sl.min)
end

local function handle_mouse(left, right)
  if left and not prev_left then
    for _, b in ipairs(BUTTONS) do
      if hit(b) then
        if b.id == "fmt" then fmt = fmt % #FORMATS + 1
        elseif b.id == "export" then do_export()
        elseif b.id == "rescan" then resample() end
        return
      end
    end
    for _, sl in ipairs(SLIDERS) do
      if mx >= sl.x - 8 and mx <= sl.x + sl.w + 8 and my >= sl.y - 24 and my <= sl.y + 26 then
        drag_slider = sl
        sl.set(slider_value(sl))
        return
      end
    end
    if my > BAR then drag_idx = nearest(mx, my) end
  elseif left and drag_slider then
    drag_slider.set(slider_value(drag_slider))
  elseif left and drag_idx then
    move_point(drag_idx, mx, my)
  elseif not left then
    if drag_slider then
      if drag_slider.id == "rate" then resample() end -- resample once on release, not per tick
      drag_slider = nil
    end
    drag_idx = nil
  end

  if right and not prev_right and my > BAR then
    local i = nearest(mx, my)
    if i then
      if #points > 2 then table.remove(points, i) end
    else
      add_point(from_x(mx), from_y(my))
    end
  end
end

local function draw()
  local hover = drag_idx or nearest(mx, my)

  gfx.set(0.11, 0.11, 0.13, 1)
  gfx.rect(0, 0, W, H, true)
  gfx.set(0.16, 0.16, 0.19, 1)
  gfx.rect(PL.x, PL.y, PL.w, PL.h, true)

  gfx.set(0.25, 0.25, 0.3, 1)
  for i = 0, 4 do
    local y = PL.y + i * PL.h / 4
    gfx.line(PL.x, y, PL.x + PL.w, y)
  end

  gfx.set(0.7, 0.7, 0.75, 1)
  gfx.x, gfx.y = 30, PL.y - 6
  gfx.drawstr("1.0")
  gfx.x, gfx.y = 30, PL.y + PL.h - 8
  gfx.drawstr("0.0")
  gfx.x, gfx.y = PL.x, PL.y + PL.h + 10
  gfx.drawstr("0s")
  local lbl = n(duration) .. "s"
  gfx.x, gfx.y = PL.x + PL.w - gfx.measurestr(lbl), PL.y + PL.h + 10
  gfx.drawstr(lbl)

  gfx.set(0.35, 0.75, 1, 1)
  for i = 1, #points - 1 do
    gfx.line(to_x(points[i].t), to_y(points[i].v), to_x(points[i + 1].t), to_y(points[i + 1].v))
  end

  for i, p in ipairs(points) do
    local hot = (i == hover)
    gfx.set(hot and 1 or 0.4, hot and 0.8 or 0.6, 1, 1)
    gfx.circle(to_x(p.t), to_y(p.v), hot and 7 or 5, true, true)
  end

  local labels = { fmt = "Format: " .. FORMATS[fmt].name, export = "Export...", rescan = "Rescan audio" }
  for _, b in ipairs(BUTTONS) do
    gfx.set(hit(b) and 0.32 or 0.24, 0.28, 0.34, 1)
    gfx.rect(b.x, b.y, b.w, b.h, true)
    gfx.set(0.85, 0.9, 1, 1)
    local tw, th = gfx.measurestr(labels[b.id])
    gfx.x, gfx.y = b.x + (b.w - tw) / 2, b.y + (b.h - th) / 2
    gfx.drawstr(labels[b.id])
  end

  for _, sl in ipairs(SLIDERS) do
    local val = sl.get()
    gfx.set(0.7, 0.7, 0.75, 1)
    gfx.x, gfx.y = sl.x, sl.y - 22
    gfx.drawstr(sl.label .. ": " .. sl.display(val))
    local f = M.clamp((val - sl.min) / (sl.max - sl.min), 0, 1)
    gfx.set(0.25, 0.25, 0.3, 1)
    gfx.rect(sl.x, sl.y, sl.w, 10, true)
    gfx.set(0.35, 0.75, 1, 1)
    gfx.rect(sl.x, sl.y, sl.w * f, 10, true)
    gfx.set(0.85, 0.9, 1, 1)
    gfx.circle(sl.x + sl.w * f, sl.y + 5, 8, true, true)
  end

  gfx.set(0.7, 0.7, 0.75, 1)
  gfx.x, gfx.y = 12, H - 22
  local info = string.format("%d points @ %dHz  |  L-drag: move  |  R-click point: delete  |  R-click empty: add  |  Esc: close",
    #points, rate)
  if hover and points[hover] then
    info = string.format("t=%ss v=%s   %s", n(points[hover].t), n(points[hover].v), info)
  end
  gfx.drawstr(info)
end

local function frame()
  mx, my = gfx.mouse_x, gfx.mouse_y
  local left = gfx.mouse_cap % 2 >= 1
  local right = gfx.mouse_cap % 4 >= 2
  handle_mouse(left, right)
  draw()
  prev_left, prev_right = left, right
  local ch = gfx.getchar()
  if ch >= 0 and ch ~= 27 then reaper.defer(frame) end
end

gfx.init("CurveGenerator", W, H)
gfx.setfont(1, "Segoe UI", 15)
frame()
