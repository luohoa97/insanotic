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
