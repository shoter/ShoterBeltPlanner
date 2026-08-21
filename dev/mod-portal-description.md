Plan a whole belt run in a couple of clicks: several lanes at once, around corners, forwards or backwards, placed as ghosts you can undo in one go.

**This is a beta.** It works and it is tested, but it has not had many hours on it in a real save yet. Please report anything that looks off.

## What it does

You mark where the belts start and how wide the bundle is, then click where you want them to reach. The tool lays every lane, keeps them parallel, and re-anchors at the far end so the next click carries on from there.

- **Several lanes at once.** The opening gesture sets the width, and every lane keeps its spacing for the whole run.
- **Corners.** Click off to one side and the run heads out along its own axis, then turns once. The lanes turn at staggered points, so the bundle comes out of the corner still parallel and still the same width — and the anchor turns with it, so you can just keep clicking.
- **Backwards.** Press R and the belts face the other way, so you can build a run from its destination back towards its source.
- **Splitters.** Shift + right-drag finishes a run with a row of splitters instead of belts, pairing lanes 1-2, 3-4 and so on.
- **Ghosts only.** Nothing is built for real and nothing is taken from your inventory. One press of undo removes an entire run — landfill, felled trees and all.
- **A preview that means it.** What you see under the cursor is drawn from the same list the click commits, so it is not an impression of the result, it is the result. Blocked tiles are outlined in red before you commit to anything.
- **Landfill over water,** as tile ghosts — or whatever the terrain's own cover is: foundation on lava and oil, ice platform on Aquilo, platform foundation in space. The water itself is never modified.
- **Any belt.** Tiers are read from the prototypes, so modded belts are picked up automatically. Shift+B steps through them without leaving the tool.

## How to use it

Take the tool with **Alt+B** or from the shortcut bar.

1. **Click** where the belts should start. The marked area then follows your pointer as a line one tile deep — its length is how many lanes wide the run will be, and the short side is the direction it sets off in.
2. **Click again** to accept it. Dragging a 1×N rectangle instead does both at once.
3. **Click** where you want the belts to reach. Every click continues from where the last one ended.

Controls:

- **Alt + B** — take the tool
- **Left click** — start a run, set its width, extend it
- **R** — flip which way the belts face
- **Shift + B** — next belt tier
- **Shift + right-drag** — end the run with splitters
- **Right-drag** — cancel

There is a Tips and Tricks entry with all of this in it, if you would rather read it in game.

## What it deliberately will not do

The point of this tool is to be predictable rather than clever, so it never guesses on your behalf:

- **It will not tunnel for you.** Anything in the way stops the run and names it, instead of picking an underground length you did not ask for. A deliberate "put an underground here" gesture is on the list.
- **It will not touch your factory unasked.** Trees, rocks and wild plants are always cleared, the same as stamping a blueprint over them. Your own buildings are only marked for deconstruction if you switch **Clear my buildings** on in the tool window; otherwise the run is refused and tells you what is in the way. A crop planted by your agricultural tower counts as one of your buildings.
- **It will not wander.** The belts go where you drew them and nowhere else.

## Settings

- **Maximum tiles per click** (map setting) — a run is planned in a single tick, so this caps how much work one click can ask for. Anything over the limit is refused rather than executed.
- **Landfill over water** (per player) — the value the switch in the tool window starts at. Change it in the window to change it now.
- **Blow up cliffs** (per player) — likewise, for the switch that marks cliffs in the way for deconstruction. It only does anything once cliff explosives are researched; until then cliffs stop the run.

## Made with AI

The code in this mod was largely written by Claude, Anthropic's AI. I directed it, made the design calls, and tested it in game, but I would rather say so here than have you work it out from the commit history.

For what it is worth, it ships with a headless test suite of just over a hundred assertions that runs against real Factorio before every build, and a fair number of them exist because they caught something. That is not a substitute for the mod being played, though, which is exactly why it is marked beta.

## Compatibility

- Factorio 2.0. Works with Space Age.
- Requires **flib**.
- Belt tiers come from the prototypes, so any mod adding an ordinary belt family works without a patch. A tier's splitter is matched by throughput; if a modded belt has nothing matching, the splitter gesture just says so rather than guessing.
- The tool is cursor-only. There is no recipe, nothing is added to your inventory or to Factoriopedia, and if you remove the mod you are left with plain vanilla ghosts.

## Known limitations

- Factorio does not tell mods where the mouse is, so the preview works it out indirectly. It usually keeps up, but after a very large jump it can take a moment to catch up.
- In multiplayer, other players **on your force** may notice stray selection boxes near where you are pointing while you have the tool out. That is the cursor tracking, and it cannot be hidden from them — visibility in Factorio is a property of the force, not the player.
- No manual underground gesture yet.

## Feedback

Bug reports are very welcome. Most of all, tell me about anything the preview shows that the click then does not build — that is the one thing this tool is meant to guarantee.
