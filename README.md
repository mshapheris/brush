# Brush

A [ScreenBrush](https://screenbrush.app)-style presentation layer for [Hammerspoon](https://www.hammerspoon.org).

One hotkey turns on a full-screen layer with two modes:

- **Spotlight.** The screen dims except for a circle that follows the cursor.
  Pinch on the trackpad (or press `=` / `-`) to resize the circle. Clicks still
  reach whatever is underneath.
- **Draw.** Drag the cursor to draw on the screen. Each stroke fades out a few
  seconds after you lift the mouse. Pinch to change the stroke width.

Press `d` inside the layer to switch between the two, `c` to clear strokes, and
`escape` to leave.

## Install

```sh
git clone https://github.com/mshapheris/brush.git
ln -s "$PWD/brush/Brush.spoon" ~/.hammerspoon/Spoons/Brush.spoon
```

Then in `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("Brush")
spoon.Brush:bindHotkeys({
  toggle = { { "ctrl", "alt", "cmd", "shift" }, "b" },
  -- optional: jump straight into a mode
  -- draw      = { { "ctrl", "alt", "cmd", "shift" }, "d" },
  -- spotlight = { { "ctrl", "alt", "cmd", "shift" }, "s" },
})
```

Hammerspoon needs Accessibility access (System Settings > Privacy & Security >
Accessibility) for the mouse and pinch capture to work. If you already use
Hammerspoon hotkeys you have this.

## Keys inside the layer

| Key | Action |
| --- | --- |
| `d` | Toggle draw / spotlight |
| `c` | Clear all strokes |
| `=` / `-` | Grow / shrink the spotlight (or stroke width in draw mode); hold to repeat |
| pinch | Same as `=` / `-`, continuously |
| `escape` | Leave the layer |

Change any of them before `bindHotkeys`:

```lua
spoon.Brush.keys.toggleDraw = { {}, "space" }
```

## Configuration

Set these on `spoon.Brush` after `hs.loadSpoon("Brush")`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `dimColor` | black, alpha 0.65 | Dim layer colour; alpha is how dark it gets |
| `drawDimAlpha` | 0 | Dim alpha while drawing (0 = no dim) |
| `spotlightRadius` | 140 | Starting circle radius, points |
| `minRadius` / `maxRadius` | 30 / 1200 | Radius bounds |
| `radiusStep` | 20 | Points per `=` / `-` press |
| `pinchSensitivity` | 1.0 | Multiplier on trackpad magnification |
| `strokeColor` | red | Stroke colour |
| `strokeWidth` | 6 | Starting stroke width, points |
| `fadeDelay` | 2.5 | Seconds a stroke stays solid after mouse-up |
| `fadeDuration` | 1.0 | Seconds a stroke takes to fade out |
| `fps` | 30 | Fade animation rate |
| `layerFadeTime` | 0.15 | Fade in/out of the layer itself |
| `showHint` | true | Show the key hint at the top of the screen |
| `startMode` | `"spotlight"` | Mode the layer opens in; `nil` remembers the last one |

## API

- `spoon.Brush:toggle()`, `:enter([mode])`, `:exit()`, `:isActive()`
- `spoon.Brush:setMode("draw" | "spotlight")`, `:toggleMode()`
- `spoon.Brush:setRadius(points)`, `:setStrokeWidth(points)`
- `spoon.Brush:clear()`

## How it works

One transparent `hs.canvas` per screen sits at screen-saver level. The dim is a
filled rectangle; the spotlight is a circle drawn with the `destinationOut`
composite rule, which punches a hole in the rectangle. An `hs.eventtap` follows
the cursor and reads trackpad magnify gestures. In draw mode the same tap
consumes left-button events and turns them into `segments` elements; a timer
lowers each stroke's alpha until it is removed. A `hs.hotkey.modal` holds the
in-layer keys so they only exist while the layer is on.

## License

MIT
