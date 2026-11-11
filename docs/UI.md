# Insanotic UI components

Menus and dialogs of Insanotic can be written as RML (an HTML-like markup) and
RCSS (CSS with a few differences) documents, drawn by the engine through
[RmlUi](https://github.com/mikke89/RmlUi). They live in `ui/` of a game
directory or pk3: `ui/<name>.rml` is shown with `rml_show <name>`, hidden
with `rml_hide <name>`, and `rml_reload` loads every document and stylesheet
again, so a designer can edit a file and look at the result without
restarting.

There is no scripting. A document is wired up with attributes:

| Attribute | On | Does |
|---|---|---|
| `data-cmd="..."` | any element | Click or tap runs that console command. |
| `data-close` | any element | Click or tap closes the document it is in. |
| `data-cvar="name"` | `input`, `select`, `textarea` | Shows the cvar when the document opens and writes it when the player changes the control. |
| `data-cvar="name"` | any other element | Shows the cvar's value as the element's text. |
| `data-reply="action"` | any element | Only in pages from a server, see [MODDING.md](MODDING.md#pages-from-a-server). |

Read-only and private cvars are never written. A control can say how its value
relates to the cvar's:

- `data-on="2" data-off="0"` on a checkbox: it writes these instead of 1 and
  0, and is checked while the cvar is not the off value (for an inverted
  option use `data-on="0" data-off="1"`);
- `data-map="db"` on a slider: a volume in decibels (`min="-40" max="0"`),
  where the cvar is a factor and the lowest value is silence.

A dropdown whose options come from a data model (`<option data-for=...>`)
finds its value as soon as the options exist. The two files that give
documents their look:

- `ui/common.rcss` — what RmlUi does not assume (it has no built-in
  stylesheet): blocks, the font, thin scroll bars.
- `ui/components.rcss` — the widgets below.

The **dialog template** links both and makes the dark veil and the window, so
a dialog is mostly its content:

```xml
<rml>
<head>
	<title>Quit</title>
	<link type="text/template" href="templates/dialog.rml"/>
</head>
<body template="dialog">
	<div class="dialog-bar">
		<div class="dialog-title">Quit</div>
		<div class="dialog-close" data-close>&#215;</div>
	</div>
	<div class="dialog-body">Are you sure you want to quit?</div>
	<div class="dialog-buttons">
		<div class="button danger" data-cmd="quit">Yes</div>
		<div class="button primary" data-close>No</div>
	</div>
</body>
</rml>
```

`ui/quit.rml` is this dialog; the Quit button of the main menu opens it.
`ui/quicksettings.rml` uses most of the components below with real cvars.
Add `class="wide"` to the `.dialog` (write the template's window yourself, or
override its width in your own stylesheet) for the 760 dp variant.

## Sizes

Sizes are in `dp`. The engine picks how many pixels a dp is from the short
side of the window: 720 dp on a monitor, 450 dp with `vid_touchscreen 1` (so
things are bigger on a phone). `rml_scale` overrides this. Every control that
can be touched is at least 48 dp high; a `.button.small` is smaller on a
monitor and grows to full size on a phone.

Phone layouts are media queries in the stylesheet:

```css
@media (max-height: 500dp) { /* a phone held sideways */ }
@media (orientation: portrait) { /* a phone held upright */ }
```

RmlUi's media queries have no `or`: write the rules twice.

## Components

**Dialog** — `.backdrop` > `.dialog` > `.dialog-bar` (`.dialog-title`,
`.dialog-close` with `data-close`), `.dialog-body` (add `.scroll` for a body
that scrolls), `.dialog-buttons`. The close button is 56 dp wide and always
in the same place.

**Buttons** — `<div class="button">`, with `primary` (blue), `danger` (red),
`small`, `block` (full width). `data-cmd` runs a command, `data-close` closes.

**Checkbox and switch** — a `label` that wraps the input and its text is one
big target:

```xml
<label class="check"><input type="checkbox" class="checkbox" data-cvar="showfps"/> Show frames per second</label>
<label class="check sw"><input type="checkbox" class="checkbox switch" data-cvar="menu_sounds"/> Menu sounds</label>
```

A checked box writes `1`, an unchecked one `0`.

**Radio group** — radios with the same `name`; each has a `value`. The cvar
is set to the value of the one that is checked:

```xml
<label class="check"><input type="radio" class="radio" name="sw" value="0" data-cvar="cl_autoswitch"/> Never</label>
<label class="check"><input type="radio" class="radio" name="sw" value="1" data-cvar="cl_autoswitch"/> On pickup</label>
```

**Slider** — `<input type="range" class="range" min="0" max="1" step="0.05" data-cvar="volume"/>`.
The 48 dp strip is the target: touching anywhere puts the knob there, and a
drag keeps working however far the finger drifts up or down. A slider inside
a scrolling list is dragged, not scrolled.

**Text field** — `<input type="text" class="text" data-cvar="_cl_name"/>`
(also `password`, `number`, and `<textarea>`). Tapping it opens the
on-screen keyboard on touch devices. While it has focus, a change of the cvar
does not overwrite what is being typed.

**Dropdown** — `<select data-cvar="gl_picmip"><option value="0">High</option>...</select>`.
The list drags like any other list.

**Tabs**:

```xml
<tabset>
	<tab>Audio</tab><panel>...</panel>
	<tab>Video</tab><panel>...</panel>
</tabset>
```

**List and table** — `.list` (give it a height) holds `.item`s; `table.table`
has `th` and `td`. Anything with `overflow-y: auto` or `scroll` scrolls by the
wheel, by dragging it with a finger (a fling keeps it going with friction, and
past the ends it stretches like rubber and springs back; a tap stops it), and
by the scroll bar.

**Rows** — `.row` with a `.caption` and a `.control` puts a label and a
control on one line, and stacks them on a phone held upright.
`.section` is a small blue heading, `.hint` small muted text.

**Progress bar** — `<progress class="bar" value="0.4"/>`.

**Image card** — `.card` with a background image and a `.caption`:

```css
#stormkeep { decorator: image(/maps/stormkeep.jpg cover center center); }
```

**Tooltips** — there are none: a finger has no hover. Put the explanation in
a `.hint` line instead.

## Lists from the engine (data models)

Some lists are rows the engine knows. They are bound with RmlUi's data
models, still without scripting: the body says `data-model="..."`, a row is
repeated with `data-for`, and `data-event-click="name(args)"` calls a
function of the model. Only documents of the game can use them: a page from
a server that names a data model is refused. They are made in
`darkplaces/ui_rml_models.cpp`.

| Model | Variables | Events |
|---|---|---|
| `servers` | `rows` (`address`, `name`, `map`, `type`, `players`, `ping`), `filter`, `address`, `selected`, `status`, `sort`, `show_empty`, `show_full`, `show_laggy` | `select(address)`, `join()`, `refresh()`, `sort(column)`, `toggled()`, `filter_changed()` |
| `settings` | `resolutions`, `resolution`, `skins`, `binds` (`label`, `command`, `key1`, `key2`, `header`, `bindable`, `capturing1`, `capturing2`), `capture_text` | `resolution_changed()`, `bind(row, slot)`, `unbind(row)` |
| `campaign` | `levels` (`number`, `title`, `desc`, `map`, `mode`, `image`, `locked`, `done`, `current`), `title`, `has_prev`, `has_next`, `progress`, `selected` | `select(index)`, `play(index)`, `play_selected()`, `instant()`, `next()`, `prev()` |

`ui/servers.rml` (the server browser, reading the list the network code
fills; opening it asks the master servers; a tap on a row opens a panel with
the map picture, the players and Join, and a button to add the server to the
favorites, which stay on top of the list) and `ui/singleplayer.rml`
(instant action and the campaign, started through `menu_cmd instantaction`
and `menu_cmd campaign <name> <level>` of the menu code) are the examples.
`ui/lists.rcss` makes a dialog fill the window with a scrolling list in it.
A `data-for` row is an ordinary element: it gets the drag scrolling, and
`data-class-selected="..."` and `data-style-decorator="..."` style it from
the data.

## The Settings page

`ui/settings.rml` is the Settings dialog of the QuakeC menu in RML: tabs for
Video, Effects, Audio, Game, Input (with the key binder), User and Misc. It
has the options people change most, one line a control, bound to cvars with
`data-cvar`; "More settings..." opens the QuakeC dialog for the rest (HUD
layout, language, ...). Binding a key: tap one of the two key buttons of an
action, then press the new key or mouse button (Escape cancels); the engine
hands that press to the page instead of anywhere else
(`UIE_CaptureKeys` in `ui_rml_engine.c`).

## What the engine's renderer cannot do

Gradient decorators (`linear-gradient`, `radial-gradient`) do not work;
`vertical-gradient` and `horizontal-gradient` (two colors) do. Use thick
borders for small marks (`components.rcss` draws check marks that way).
Text is not translated: the strings in a document are what is shown.

## Input

Mouse, wheel, keyboard (Tab and the arrow keys move between elements with
`tab-index: auto` and `nav: auto`; Enter and Space press), text input and
touch all work. On a touch screen fingers arrive as mouse events and a tap
hits exactly the element under it. Escape closes a document opened with
`rml_show`.
