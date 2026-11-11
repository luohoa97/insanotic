# Insanotic scripting

Insanotic runs Lua 5.4 scripts in two places:

| | Runs in | Folder | Who installs it | Status |
|---|---|---|---|---|
| **Plugins** | the server | `plugins/<name>/` | server admin | available |
| **Mods** | the Insanotic client | `mods/<name>/` | player | in progress |

Plugins change what the server simulates (damage, spawns, items, rules).
Players connect with any client, including a stock Xonotic 0.8.6 client,
and need to install nothing. This document covers plugins.

## Quickstart

```sh
make run-server
```

That builds the engine and the game code, downloads the `stormkeep` map,
and starts a dedicated server on port 26000 with plugins on and three bots.
Connect with any Xonotic 0.8.6 client: `connect localhost`.

A plugin is a folder with an `init.lua` in the game's virtual filesystem,
for example `data/insanotic.pk3dir/plugins/hello/init.lua`:

```lua
xon.on("PlayerSpawn", function(ev)
	local player = ev[0]
	xon.print(player.netname .. " spawned")
end)
```

Edit it while the server runs, then type `sv_lua_reload` in the server
console. The match keeps going.

### plugin.json (optional)

```json
{ "name": "hello", "version": "1.0.0", "order": 0 }
```

- `name`, `version`: shown by `sv_lua_plugins`. Default: folder name, `0`.
- `order`: load order, lower first (default 0). Ties load by folder name.
  Handlers run in load order.

The file must be a flat JSON object; nested values are not read.

## Server settings

| Cvar / command | Default | Meaning |
|---|---|---|
| `g_lua` | `0` | `1` loads plugins. Read at map start. With `0` the game code adds no hook callbacks at all, so gameplay is exactly stock 0.8.6. |
| `sv_lua_instruction_limit` | `2000000` | Lua instructions one plugin may run per entry (loading, or one hook call). |
| `sv_lua_memory_limit` | `32` | MB of memory one plugin may hold. |
| `sv_lua_plugins` | | Lists plugins: version, handler count, memory, or why one was disabled. |
| `sv_lua_reload` | | Closes every plugin and loads `plugins/*` again (new folders included) without restarting the map. |

## Hooks

`xon.on(hook, fn)` registers `fn(ev)` for one of the server hooks listed in
[hooks.md](hooks.md) (163 hooks, generated from the game code).

- `ev[n]` is hook argument `n`, numbered as in hooks.md. `ev.hook` is the
  hook name.
- Arguments marked **out** are written back after all handlers ran:
  assign `ev[n] = value` to change them, e.g. damage in `Damage_Calculate`.
- Return `true` to set the hook's result. hooks.md says, per hook, whether
  the game looks at it and the description says what `true` does
  (usually "block this" or "handled").
- Handlers run in plugin load order, then in registration order. Each
  plugin sees the out-values left by the one before.

Example, from `plugins/hello`:

```lua
xon.on("Damage_Calculate", function(ev)
	local inflictor = ev[0]
	if inflictor and inflictor.classname == "rocket" then
		ev[4] = ev[4] * 2 -- damage
	end
end)
```

## The `xon` API

### Core

| Function | Returns | |
|---|---|---|
| `xon.on(hook, fn)` | | Register a hook handler. |
| `xon.print(...)` | | Print to the server console, prefixed with the plugin name. `print` does the same. |
| `xon.time()` | number | Server time in seconds. |
| `xon.cvar(name)` | number or nil | Cvar value. |
| `xon.cvar_string(name)` | string or nil | Cvar string. |
| `xon.cvar_set(name, value)` | | Set an existing cvar. |
| `xon.cvar_register(name, default [, description])` | number | Create a cvar if missing and return its value. Use it for every setting of your plugin. |
| `xon.script_name`, `xon.script_version`, `xon.script_dir`, `xon.script_kind` | string | This plugin's name, version, folder and `"plugin"`. |

Cvars marked private (such as `rcon_password`) cannot be read; private and
read-only cvars cannot be set.

### World

| Function | Returns | |
|---|---|---|
| `xon.players()` | list of entities | Every connected client (players, spectators, bots). |
| `xon.find(classname)` | list of entities | Every entity with that classname. |
| `xon.entity(number)` | entity or nil | Entity by edict number. |
| `xon.traceline(from, to [, nomonsters [, ignore]])` | table | Trace a line. `nomonsters` true ignores entities. Result: `fraction`, `endpos`, `normal`, `ent`, `startsolid`, `allsolid`. |

### Vectors

`xon.vec(x, y, z)` makes a vector: a table with `x`, `y`, `z` that supports
`+`, `-`, unary `-`, `*` with a number (scale) or a vector (dot product),
`/` by a number, `==` and `tostring`, plus `v:len()`, `v:normalize()`,
`v:dot(w)`, `v:cross(w)`, `v:copy()`. Any table with `x, y, z` or `[1], [2],
[3]` is accepted where a vector is expected.

`xon.forward(angles)` turns view angles (pitch, yaw, roll; positive pitch
looks down) into a unit direction; `xon.vectoangles(dir)` does the reverse.

### Entities

Entities are handles. World and "no entity" are `nil`.

Any QuakeC field of type float, vector, string or entity can be read and
written by name: `e.health`, `e.origin`, `e.velocity`, `e.angles`,
`e.v_angle`, `e.team`, `e.netname`, `e.classname`, `e.button0`, ... Writing
`origin` also relinks the entity into the world. Unknown fields read as
`nil`; writing one is an error.

Convenience names:

| Name | |
|---|---|
| `e.armor` | Same as `e.armorvalue`. |
| `e.alive` | Read-only boolean: not dead and health above 0. |
| `e.weapon` | Read-only: name of the weapon in the first slot, e.g. `"devastator"`. |

Methods:

| Method | |
|---|---|
| `e:valid()` | False once the entity was removed. |
| `e:num()` | Edict number. |
| `e:is_client()`, `e:is_bot()` | Connected client / bot client. |
| `e:userinfo(key)` | Value a client sent with `setinfo` (players can send one with `cmd setinfo key value`), or nil. |
| `e:sprint(text)` | Print to that client's console. |
| `e:centerprint(text)` | Print in the middle of that client's screen. |

**Stale handles.** A handle remembers which entity it was made for. Once that
entity is removed (even if its slot is reused by a new entity) the handle
reads every field as `nil`, `e:valid()` is false, and writing to it raises an
error. Check `e:valid()` before using a handle you kept from an earlier hook.

## Pages from a server

A server can open its own page (a menu, a shop, a rules screen) in the
players' game. The page is an RML document in a pk3 the server sends (a
download, like a map), written with the same components as the game's own
dialogs, see [UI.md](UI.md). Players need an Insanotic client; other clients
ignore the command.

**Open** a page from a plugin, or from game code with `stuffcmd`:

```lua
player:show_page("ui/myserver/shop.rml")   -- Lua plugin
player:close_page()
```

```c
stuffcmd(player, "rml_show_server ui/myserver/shop.rml\n");   // QuakeC
```

The path has to be `ui/<folder>/<name>.rml`: the page needs a folder of its
own, with letters, digits, `_`, `-` and `.` only.

**Answer.** A button with `data-reply="action"` sends the server the page's
name, the action and every named form field of the page (`name="..."`):

```xml
<input type="text" class="text" name="note"/>
<div class="button primary" data-reply="send">Send</div>
```

Plugins get this as the `PageReply` hook. It is not a game hook: it comes
from the engine, and runs only for plugins that register it:

```lua
xon.on("PageReply", function(ev)
	-- ev[0] the player, ev[1] the page, ev[2] the action,
	-- ev.values the named fields by name, all strings
	if ev[2] == "send" then
		xon.print(ev[0].netname .. ": " .. (ev.values.note or ""))
		ev[0]:close_page()
	end
end)
```

Treat the values like any other input from a player: the client is not
trusted. A checkbox sends `"1"` or `"0"`, a radio group its checked value.
Quotes and control characters are removed, a value is at most 200
characters, and a page sends at most 16 fields. A client can send at most 20
answers a second. When no plugin listens, the line `rml_reply ...` goes to
the game code like any client command (`SV_ParseClientCommand`).

`data-cmd="cmd something"` in a page sends `something` to the server like the
`cmd` console command does; that is the only command a page can give.

`plugins/example_page/` and `ui/example_page/page.rml` are a complete
example: type `cmd page` in the console of a game on a server that runs it.

**What a page cannot do** (the player's computer is theirs, whatever the
server sends):

- Run a local command, or set a local cvar. `data-cmd` with anything but
  `cmd ...` is refused, and so is anything the page tries to run in a way
  that is not an attribute.
- Read a cvar: `data-cvar` does nothing in a page from a server, so a field
  never shows or sends a setting of the player.
- Choose where it is loaded from: the page itself must be `ui/<folder>/<name>.rml`;
  stylesheets and images it links are read from the game's file system like
  those of any document, and a path with `..` is refused.
- Hide where it comes from: the engine draws a band on top of the page
  that says "Page from the server" and has a Close button, and Escape
  closes the page whatever the page does.
- Be large: a file of at most 256 KB, at most 2000 elements, one page at
  a time (a new one replaces the one before), at most two opened a second,
  and it closes by itself after `cl_server_page_timeout` seconds (600).

A player who does not want pages sets `cl_allow_server_pages 0`: every
request is ignored. A page lives in the same RmlUi context as the game's own
documents but is marked as untrusted (separate rules above, enforced in
`darkplaces/ui_rml.cpp`); it is not a separate sandbox process.

## Sandbox limits

Every plugin runs in its own Lua state.

- **Libraries**: `base`, `coroutine`, `table`, `string`, `math`, `utf8`.
  `io`, `os`, `debug` and `package` do not exist (they are not compiled into
  the engine). `dofile`, `loadfile` and `string.dump` are removed.
- **`load`** accepts only source text, never precompiled bytecode.
- **`require(name)`** loads `plugins/<this plugin>/<name>.lua` from the
  virtual filesystem, with dots as folder separators (`require("lib.util")`
  loads `lib/util.lua`). Names may only contain letters, digits, `_` and
  single dots, so nothing outside the plugin's folder is reachable.
- **Instructions**: each entry into a plugin (running `init.lua`, or one hook
  call) may run `sv_lua_instruction_limit` VM instructions. An endless loop
  hits the limit within milliseconds.
- **Memory**: a plugin may hold `sv_lua_memory_limit` MB.
- **Failure**: any error, the instruction limit or the memory limit disables
  only that plugin. The error and a traceback go to the server console, the
  plugin's handlers are removed and its Lua state is closed. The server
  keeps running. `sv_lua_reload` gives it another try.
- A plugin cannot hide its own death: once killed, `pcall`, `xpcall` and
  `coroutine.resume` re-raise the error instead of catching it.

`make test-plugins` runs plugins in `tests/plugins/` that try each of these
(endless loop, `pcall` escape, memory hog, error, sandbox probes) and checks
that the server survives.

## How it fits together

| Layer | Where |
|---|---|
| Engine | `darkplaces/lua_sandbox.c` (sandbox), `darkplaces/sv_lua.c` (server API, builtins `lua_load` #680, `lua_hook` #681, `lua_hookcount` #682, extension `XON_LUA`) |
| Game code | `qcsrc/common/mutators/mutator/lua/` in the data repo: the `lua` mutator scans `plugins/*/init.lua` and forwards every hook; `sv_lua_hooks.qc` is generated |
| Generator | `misc/insanotic/gen-lua-hooks.sh` (`make insanotic-hooks`) rebuilds the forwarders and hooks.md from the `MUTATOR_HOOKABLE` declarations |
