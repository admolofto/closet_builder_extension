# Closet Builder — SketchUp Extension

Parametric closet system builder. Spawn drawer banks, closet sections (2 folding
doors with hanging rod), and cubbies with shelves — then re-edit any unit in
place. Every part is a named group with its own material role, ready for
cutlist extensions.

## Install

1. Download `closet_builder.rbz` (or build it — see Development)
2. SketchUp: **Window → Extension Manager → Install Extension** → pick the `.rbz`
3. **Restart SketchUp** (required when upgrading — loaded Ruby is not replaced)
4. Open via **Extensions → Closet Builder → Build Unit...**

## Usage

- Pick a unit type tab (**Drawers / Closet / Cubby**), set dimensions
  (decimals or fractions like `32 1/2`), options, and materials per part role.
- **Build** places the unit; the dialog switches to editing mode so **Update**
  rebuilds it in place. *"Build a new copy instead"* starts another unit.
- **Re-edit later:** right-click a unit → **Edit Closet Unit...** Parameters are
  stored on the component. Scale-tool resizes are detected and folded back into
  the dimensions on edit; Update rebuilds cleanly at true size.

## Features

**Shared construction**
- Frameless / euro-style, inches; fractions accepted everywhere
- Carcass thickness presets or any custom value; back thickness matches the
  carcass by default (or explicit/custom)
- Full back by default (covers side & top rear edges), or captured inset back
- Top panel rests on the sides (default) or captured between them
- Base: riser with top panel (default), toe kick, or none
- Face edge gaps: independent left / right / top / bottom — for reveals where
  cabinets sit beside each other or stack
- Per-role materials: carcass, faces/doors, drawer boxes, drawer bottoms,
  backs, shelves

**Drawer banks**
- 1–12 drawers; equal, graduated, or custom heights (`4, 4, *, *, *`,
  top→bottom, `*` shares remaining space)
- Overlay or inset fronts; face reveal and face–carcass stand-off (default 1/4")
- Drawer boxes: own wall thickness (default 1/2") and bottom thickness +
  material (default 1/2"); independent left/right/rear clearances to the
  carcass; bottom box keeps 1" hardware space below, top box 5/8" above

**Closet sections**
- 2 full-overlay doors, optional bifold leaf split
- Door–carcass stand-off gap (default 1/4")
- Hanging rod at any height, optional shelf above

**Cubbies**
- Evenly spaced shelves and vertical dividers

## Development

```
closet_builder.rb            extension loader
closet_builder/
  main.rb                    menus, context menu, attribute helpers
  builders.rb                all parametric geometry + param normalization
  materials.rb               material presets per part role
  dialog.rb                  HtmlDialog <-> Ruby bridge (scale detection)
  ui/dialog.html             the dialog UI (vanilla JS)
```

Build the installable package from the repo root:

- Windows: `powershell -ExecutionPolicy Bypass -File build.ps1`
- macOS/Linux: `./build.sh`

For fast iteration, copy `closet_builder.rb` + `closet_builder/` into your
SketchUp `Plugins` folder and reload with the Ruby console.

Unit params are stored as JSON in the `AJL_ClosetBuilder` attribute dictionary
on each component instance, so units survive save/reload and copy/paste, and
old units migrate forward when params gain new options.

## License

MIT — see [LICENSE](LICENSE).
