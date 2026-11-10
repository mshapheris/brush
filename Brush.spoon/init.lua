--- === Brush ===
---
--- A ScreenBrush-style presentation layer for Hammerspoon.
---
--- Toggle a full-screen layer that has two modes:
---
---  * **Spotlight**: the screen is dimmed except for a circle that follows the
---    cursor. The circle is resized with a trackpad pinch, or with `=` / `-`.
---    Clicks pass through to whatever is underneath.
---  * **Draw**: drag the cursor to draw. Each stroke fades out a few seconds
---    after you lift the mouse. A pinch adjusts the stroke width.
---
--- Default keys inside the layer: `d` toggles draw/spotlight, `c` clears
--- strokes, `=` / `-` resize, `escape` leaves the layer.
---
--- Download: https://github.com/mshapheris/brush

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "Brush"
obj.version = "0.1.0"
obj.author = "mshapheris"
obj.homepage = "https://github.com/mshapheris/brush"
obj.license = "MIT - https://opensource.org/licenses/MIT"

---------------------------------------------------------------------------
-- Configuration (override after hs.loadSpoon("Brush"), before :start())
---------------------------------------------------------------------------

--- Brush.dimColor
--- Variable
--- Colour of the dimming layer in spotlight mode. The alpha is how dark it gets.
obj.dimColor = { red = 0, green = 0, blue = 0, alpha = 0.65 }

--- Brush.sweepDuration
--- Variable
--- Seconds the dim takes to sweep in from the screen edges to the spotlight
--- (and back out) when the layer is toggled or the mode changes.
obj.sweepDuration = 0.22

--- Brush.sweepFps
--- Variable
--- Frame rate of the sweep animation.
obj.sweepFps = 60

--- Brush.spotlightRadius
--- Variable
--- Starting radius of the spotlight circle, in points.
obj.spotlightRadius = 140

--- Brush.minRadius / Brush.maxRadius
--- Variable
--- Bounds for the spotlight radius.
obj.minRadius = 30
obj.maxRadius = 1200

--- Brush.radiusStep
--- Variable
--- How many points `=` / `-` change the radius by.
obj.radiusStep = 20

--- Brush.pinchSensitivity
--- Variable
--- Multiplier applied to trackpad magnification deltas. 1.0 means a pinch that
--- macOS reports as "double" roughly doubles the radius.
obj.pinchSensitivity = 1.0

--- Brush.strokeColor
--- Variable
--- Colour of drawn strokes.
obj.strokeColor = { red = 1, green = 0.25, blue = 0.2, alpha = 1 }

--- Brush.strokeWidth
--- Variable
--- Starting stroke width, in points.
obj.strokeWidth = 6
obj.minStrokeWidth = 1
obj.maxStrokeWidth = 60

--- Brush.fadeDelay
--- Variable
--- Seconds a finished stroke stays fully visible before it starts to fade.
obj.fadeDelay = 2.5

--- Brush.fadeDuration
--- Variable
--- Seconds a stroke takes to fade from fully visible to gone.
obj.fadeDuration = 1.0

--- Brush.fps
--- Variable
--- Frames per second for the fade animation.
obj.fps = 30

--- Brush.showHint
--- Variable
--- Show a small mode/keys hint at the top of each screen while the layer is on.
obj.showHint = true

--- Brush.startMode
--- Variable
--- Mode the layer starts in: "spotlight" or "draw". Set to nil to remember the
--- last mode used.
obj.startMode = "spotlight"

--- Brush.keys
--- Variable
--- Keys that are active while the layer is on. Each entry is {mods, key}.
obj.keys = {
  exit = { {}, "escape" },
  toggleDraw = { {}, "d" },
  clear = { {}, "c" },
  bigger = { {}, "=" },
  smaller = { {}, "-" },
}

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------

obj._active = false
obj._mode = "spotlight"
obj._radius = nil
obj._width = nil
obj._modal = nil
obj._tap = nil
obj._fadeTimer = nil
obj._sweep = nil -- { from, to, startedAt, duration, onDone }
obj._sweepTimer = nil
obj._holeRadius = nil -- radius currently drawn (differs from _radius mid-sweep)
obj._layers = {} -- list of { canvas, frame, strokes = {...}, base = n }
obj._current = nil -- stroke currently being drawn

local FIXED_ELEMENTS = 3 -- dim, hole, hint

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function withAlpha(color, alpha)
  return { red = color.red or 0, green = color.green or 0, blue = color.blue or 0, alpha = alpha }
end

---------------------------------------------------------------------------
-- Layer construction
---------------------------------------------------------------------------

function obj:_hintText()
  local k = self.keys
  local mode = self._mode == "draw" and "DRAW" or "SPOTLIGHT"
  local other = self._mode == "draw" and "spotlight" or "draw"
  return string.format("%s    %s: %s    %s: clear    pinch / %s %s: size    %s: exit",
    mode, k.toggleDraw[2], other, k.clear[2], k.bigger[2], k.smaller[2], k.exit[2])
end

function obj:_buildLayers()
  self:_destroyLayers()
  for _, screen in ipairs(hs.screen.allScreens()) do
    local f = screen:fullFrame()
    local c = hs.canvas.new(f)
    c:level(hs.canvas.windowLevels.screenSaver)
    c:behavior({ "canJoinAllSpaces", "stationary", "ignoresCycle" })
    c:clickActivating(false)

    c[1] = {
      id = "dim", type = "rectangle", action = "fill",
      fillColor = self.dimColor,
      frame = { x = 0, y = 0, w = f.w, h = f.h },
    }
    c[2] = {
      id = "hole", type = "circle", action = "fill",
      fillColor = { red = 0, green = 0, blue = 0, alpha = 1 },
      compositeRule = "destinationOut",
      center = { x = f.w / 2, y = f.h / 2 },
      radius = self._holeRadius,
    }
    c[3] = {
      id = "hint", type = "text", action = self.showHint and "fill" or "skip",
      text = "",
      textSize = 13, textAlignment = "center",
      textColor = { red = 1, green = 1, blue = 1, alpha = 0.85 },
      frame = { x = 0, y = 8, w = f.w, h = 20 },
    }

    table.insert(self._layers, { canvas = c, frame = f, strokes = {} })
    c:show()
  end
  self:_applyMode()
end

function obj:_destroyLayers()
  for _, layer in ipairs(self._layers) do
    layer.canvas:delete()
  end
  self._layers = {}
  self._current = nil
  self._sweep = nil
  if self._sweepTimer then self._sweepTimer:stop(); self._sweepTimer = nil end
end

function obj:_layerAt(point)
  for _, layer in ipairs(self._layers) do
    local f = layer.frame
    if point.x >= f.x and point.x < f.x + f.w and point.y >= f.y and point.y < f.y + f.h then
      return layer
    end
  end
  return nil
end

function obj:_applyMode()
  local hint = self:_hintText()
  for _, layer in ipairs(self._layers) do
    layer.canvas:elementAttribute(3, "text", hint)
  end
  self:_updateSpotlight(hs.mouse.absolutePosition())
end

-- Show or hide the dim rectangle and hole on every layer. While the dim is
-- hidden (draw mode, after the sweep has finished) nothing is redrawn on
-- mouse moves.
function obj:_setDimVisible(visible)
  local action = visible and "fill" or "skip"
  for _, layer in ipairs(self._layers) do
    layer.canvas:elementAttribute(1, "action", action)
    layer.canvas:elementAttribute(2, "action", action)
  end
  self._dimVisible = visible
end

-- The hole is drawn on every layer, centred on the cursor's absolute position
-- (which may be off that layer's canvas). That way the spotlight can cross a
-- screen boundary, and the sweep animation is coherent across screens.
function obj:_updateSpotlight(point)
  if not self._dimVisible then return end
  local r = self._holeRadius or self._radius
  for _, layer in ipairs(self._layers) do
    local c = layer.canvas
    c:elementAttribute(2, "center", { x = point.x - layer.frame.x, y = point.y - layer.frame.y })
    c:elementAttribute(2, "radius", r)
  end
end

---------------------------------------------------------------------------
-- Sweep animation (dim moves in from the edges to the spotlight, or back out)
---------------------------------------------------------------------------

-- Radius at which a hole centred on `point` clears every corner of every
-- layer, so the dim is completely invisible.
function obj:_coverRadius(point)
  local frames = {}
  for _, layer in ipairs(self._layers) do table.insert(frames, layer.frame) end
  return self:_coverRadiusForFrames(point, frames)
end

function obj:_coverRadiusForScreens(point)
  local frames = {}
  for _, screen in ipairs(hs.screen.allScreens()) do table.insert(frames, screen:fullFrame()) end
  return self:_coverRadiusForFrames(point, frames)
end

function obj:_coverRadiusForFrames(point, frames)
  local r = 0
  for _, f in ipairs(frames) do
    for _, cx in ipairs({ f.x, f.x + f.w }) do
      for _, cy in ipairs({ f.y, f.y + f.h }) do
        local d = math.sqrt((cx - point.x) ^ 2 + (cy - point.y) ^ 2)
        if d > r then r = d end
      end
    end
  end
  return r * 1.1 + (self._width or self.strokeWidth) -- margin for cursor movement
end

local function easeOutCubic(t)
  local u = 1 - t
  return 1 - u * u * u
end

function obj:_startSweep(from, to, onDone)
  self._sweep = {
    from = from, to = to, onDone = onDone,
    startedAt = hs.timer.secondsSinceEpoch(),
    duration = self.sweepDuration,
  }
  self:_setDimVisible(true)
  self._holeRadius = from
  self:_updateSpotlight(hs.mouse.absolutePosition())
  if not self._sweepTimer then
    self._sweepTimer = hs.timer.doEvery(1 / self.sweepFps, function() self:_sweepTick() end)
  end
end

function obj:_sweepTick()
  local sw = self._sweep
  if not sw then
    if self._sweepTimer then self._sweepTimer:stop(); self._sweepTimer = nil end
    return
  end
  local t = (hs.timer.secondsSinceEpoch() - sw.startedAt) / sw.duration
  if t >= 1 then
    self._holeRadius = sw.to
    self:_updateSpotlight(hs.mouse.absolutePosition())
    self._sweep = nil
    if self._sweepTimer then self._sweepTimer:stop(); self._sweepTimer = nil end
    if sw.onDone then sw.onDone() end
    return
  end
  self._holeRadius = sw.from + (sw.to - sw.from) * easeOutCubic(t)
  self:_updateSpotlight(hs.mouse.absolutePosition())
end

-- Dim sweeps in from the screen edges to the spotlight.
function obj:_sweepIn()
  local cover = self:_coverRadius(hs.mouse.absolutePosition())
  self:_startSweep(cover, self._radius, nil)
end

-- Dim sweeps out from the spotlight past the screen edges, then `onDone`.
function obj:_sweepOut(onDone)
  local cover = self:_coverRadius(hs.mouse.absolutePosition())
  local from = self._sweep and self._holeRadius or self._radius
  self:_startSweep(from, cover, onDone)
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

function obj:_strokeStyle(alpha)
  return {
    type = "segments", action = "stroke",
    strokeColor = withAlpha(self.strokeColor, alpha or self.strokeColor.alpha or 1),
    strokeWidth = self._width,
    strokeCapStyle = "round", strokeJoinStyle = "round",
    closed = false,
  }
end

function obj:_beginStroke(point)
  local layer = self:_layerAt(point)
  if not layer then return end
  local local_ = { x = point.x - layer.frame.x, y = point.y - layer.frame.y }
  local element = self:_strokeStyle()
  -- Two nearly identical points so a click without a drag still leaves a dot.
  element.coordinates = { local_, { x = local_.x + 0.1, y = local_.y } }
  layer.canvas:appendElements(element)
  local stroke = { layer = layer, points = element.coordinates, doneAt = nil }
  table.insert(layer.strokes, stroke)
  self._current = stroke
end

function obj:_extendStroke(point)
  local stroke = self._current
  if not stroke then return end
  local layer = stroke.layer
  if layer ~= self:_layerAt(point) then return end -- ignore while cursor is on another screen
  table.insert(stroke.points, { x = point.x - layer.frame.x, y = point.y - layer.frame.y })
  local idx = FIXED_ELEMENTS + self:_strokeIndex(stroke)
  layer.canvas:elementAttribute(idx, "coordinates", stroke.points)
end

function obj:_endStroke()
  local stroke = self._current
  if not stroke then return end
  stroke.doneAt = hs.timer.secondsSinceEpoch()
  self._current = nil
  self:_ensureFadeTimer()
end

function obj:_strokeIndex(stroke)
  for i, s in ipairs(stroke.layer.strokes) do
    if s == stroke then return i end
  end
  return nil
end

function obj:_ensureFadeTimer()
  if self._fadeTimer then return end
  self._fadeTimer = hs.timer.doEvery(1 / self.fps, function() self:_fadeTick() end)
end

function obj:_fadeTick()
  local now = hs.timer.secondsSinceEpoch()
  local remaining = 0
  for _, layer in ipairs(self._layers) do
    -- Walk backwards so removing an element does not shift the indices we
    -- have yet to visit.
    for i = #layer.strokes, 1, -1 do
      local stroke = layer.strokes[i]
      if stroke.doneAt then
        local age = now - stroke.doneAt
        if age >= self.fadeDelay then
          local alpha = 1 - (age - self.fadeDelay) / self.fadeDuration
          if alpha <= 0 then
            layer.canvas:removeElement(FIXED_ELEMENTS + i)
            table.remove(layer.strokes, i)
          else
            layer.canvas:elementAttribute(FIXED_ELEMENTS + i, "strokeColor",
              withAlpha(self.strokeColor, alpha * (self.strokeColor.alpha or 1)))
          end
        end
      end
    end
    remaining = remaining + #layer.strokes
  end
  if remaining == 0 and self._fadeTimer then
    self._fadeTimer:stop()
    self._fadeTimer = nil
  end
end

--- Brush:clear()
--- Method
--- Remove every stroke immediately.
function obj:clear()
  for _, layer in ipairs(self._layers) do
    for i = #layer.strokes, 1, -1 do
      layer.canvas:removeElement(FIXED_ELEMENTS + i)
    end
    layer.strokes = {}
  end
  self._current = nil
  if self._fadeTimer then
    self._fadeTimer:stop()
    self._fadeTimer = nil
  end
  return self
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

function obj:_handleEvent(e)
  local t = hs.eventtap.event.types
  local kind = e:getType()

  if kind == t.gesture then
    if e:getType(true) == t.magnify then
      local details = e:getTouchDetails()
      local mag = details and details.magnification or 0
      self:_pinch(mag)
      return true
    end
    return false
  end

  local point = e:location()

  if self._mode == "draw" then
    if kind == t.leftMouseDown then
      self:_beginStroke(point)
      return true
    elseif kind == t.leftMouseDragged then
      self:_extendStroke(point)
      return true
    elseif kind == t.leftMouseUp then
      self:_endStroke()
      return true
    end
    return false
  end

  -- Spotlight: follow the cursor, let everything else through.
  if kind == t.mouseMoved or kind == t.leftMouseDragged then
    self:_updateSpotlight(point)
  end
  return false
end

function obj:_pinch(magnification)
  local factor = 1 + magnification * self.pinchSensitivity
  if self._mode == "draw" then
    self:setStrokeWidth(self._width * factor)
  else
    self:setRadius(self._radius * factor)
  end
end

--- Brush:setRadius(radius)
--- Method
--- Set the spotlight radius in points. Clamped to minRadius..maxRadius.
function obj:setRadius(radius)
  self._radius = clamp(radius, self.minRadius, self.maxRadius)
  if self._sweep then
    if self._sweep.from == self._sweep.to then return self end
    -- A sweep that is heading for the spotlight should land on the new size.
    if self._sweep.onDone == nil then self._sweep.to = self._radius end
    return self
  end
  self._holeRadius = self._radius
  self:_updateSpotlight(hs.mouse.absolutePosition())
  return self
end

--- Brush:setStrokeWidth(width)
--- Method
--- Set the stroke width for new strokes, in points.
function obj:setStrokeWidth(width)
  self._width = clamp(width, self.minStrokeWidth, self.maxStrokeWidth)
  return self
end

function obj:_step(direction)
  if self._mode == "draw" then
    self:setStrokeWidth(self._width + direction * 2)
  else
    self:setRadius(self._radius + direction * self.radiusStep)
  end
end

---------------------------------------------------------------------------
-- Mode / lifecycle
---------------------------------------------------------------------------

--- Brush:setMode(mode)
--- Method
--- Switch the layer to "spotlight" or "draw".
function obj:setMode(mode)
  if mode ~= "draw" and mode ~= "spotlight" then
    error("Brush: mode must be 'draw' or 'spotlight'", 2)
  end
  local was = self._mode
  if was == "draw" and mode ~= "draw" then
    self:_endStroke()
  end
  self._mode = mode
  if not self._active then return self end
  self:_applyMode()
  if mode == "draw" and (was ~= "draw" or self._dimVisible) then
    self:_sweepOut(function() self:_setDimVisible(false) end)
  elseif mode == "spotlight" and (was ~= "spotlight" or not self._dimVisible) then
    self:_sweepIn()
  end
  return self
end

--- Brush:toggleMode()
--- Method
--- Flip between spotlight and draw mode.
function obj:toggleMode()
  return self:setMode(self._mode == "draw" and "spotlight" or "draw")
end

--- Brush:enter([mode])
--- Method
--- Turn the layer on. `mode` ("spotlight" or "draw") overrides Brush.startMode.
function obj:enter(mode)
  if self._active then
    if mode then self:setMode(mode) end
    return self
  end
  self._active = true
  self._radius = self._radius or self.spotlightRadius
  self._width = self._width or self.strokeWidth
  self._mode = mode or self.startMode or self._mode

  -- Layers come up with the hole covering everything, so the dim is invisible
  -- until the sweep brings it in.
  self._holeRadius = self:_coverRadiusForScreens(hs.mouse.absolutePosition())
  self._dimVisible = true
  self:_buildLayers()
  if self._mode == "draw" then
    self:_setDimVisible(false)
  else
    self:_sweepIn()
  end

  local t = hs.eventtap.event.types
  self._tap = hs.eventtap.new(
    { t.mouseMoved, t.leftMouseDown, t.leftMouseDragged, t.leftMouseUp, t.gesture },
    function(e) return self:_handleEvent(e) end
  )
  self._tap:start()
  self._modal:enter()
  return self
end

--- Brush:exit()
--- Method
--- Turn the layer off. The dim sweeps out past the screen edges first; strokes
--- are removed straight away.
function obj:exit()
  if not self._active then return self end
  self._active = false
  self._modal:exit()
  if self._tap then
    self._tap:stop()
    self._tap = nil
  end
  self:clear()
  if self._dimVisible then
    self:_sweepOut(function() self:_destroyLayers() end)
  else
    self:_destroyLayers()
  end
  return self
end

--- Brush:toggle()
--- Method
--- Turn the layer on if it is off, and off if it is on.
function obj:toggle()
  if self._active then return self:exit() end
  return self:enter()
end

--- Brush:isActive()
--- Method
--- Returns true while the layer is on.
function obj:isActive()
  return self._active
end

function obj:init()
  self._modal = hs.hotkey.modal.new()
  return self
end

--- Brush:start()
--- Method
--- Bind the in-layer keys from Brush.keys. Called for you by bindHotkeys().
function obj:start()
  if self._started then return self end
  self._started = true
  local k = self.keys
  local bind = function(spec, fn, repeatFn)
    if spec then self._modal:bind(spec[1], spec[2], fn, nil, repeatFn) end
  end
  bind(k.exit, function() self:exit() end)
  bind(k.toggleDraw, function() self:toggleMode() end)
  bind(k.clear, function() self:clear() end)
  local bigger = function() self:_step(1) end
  local smaller = function() self:_step(-1) end
  bind(k.bigger, bigger, bigger)
  bind(k.smaller, smaller, smaller)
  return self
end

--- Brush:stop()
--- Method
--- Turn the layer off. Hotkeys stay bound.
function obj:stop()
  return self:exit()
end

--- Brush:bindHotkeys(mapping)
--- Method
--- Binds hotkeys for Brush.
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for:
---    * toggle - turn the layer on or off
---    * draw   - turn the layer on directly in draw mode (optional)
---    * spotlight - turn the layer on directly in spotlight mode (optional)
function obj:bindHotkeys(mapping)
  self:start()
  local spec = {
    toggle = function() self:toggle() end,
    draw = function() self:enter("draw") end,
    spotlight = function() self:enter("spotlight") end,
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  return self
end

return obj
