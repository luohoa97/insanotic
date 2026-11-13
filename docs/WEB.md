# Insanotic in the browser

`packaging/web/` builds the engine as WebAssembly (Emscripten, WebGL) and a
page that runs it. The release workflow publishes it at
<https://luohoa97.github.io/insanotic/play/>, next to the Flatpak repository.

```sh
# with the Emscripten SDK (3.1.74) active: source emsdk_env.sh
misc/insanotic/checkout.sh          # engine, game data, QC compiler
packaging/web/build.sh              # -> packaging/web/dist/{insanotic.js,insanotic.wasm,index.html,loader.js}
cd packaging/web/dist && python3 -m http.server 8000   # then open http://localhost:8000/
```

How it fits together

- The engine uses its GLES2 renderpath, the one the Android build uses. SDL2,
  zlib, libpng, libjpeg, FreeType, Ogg and Vorbis are Emscripten ports; Opus is
  built from source. No threads (a Pages site cannot send the headers that
  `SharedArrayBuffer` needs) and no network to other hosts: a game is a local one.
- The browser owns the main loop: `Host_OneFrame()` runs once per animation frame.
- `loader.js` mounts two IndexedDB-backed directories (`/game/data` for packs,
  `/userdata` for configs), downloads the packs named in `manifest.json` that
  are not there yet, and starts the engine when Play is pressed. A player can
  also add `.pk3` files from an installed Xonotic with the "Add" button; they
  are kept in the browser.
- The deployed `manifest.json` lists one pack, `zzz-insanotic.pk3` (the game code,
  configs and Lua/UI that Insanotic adds). The Xonotic release packs are
  400 MB and up, more than a browser tab can hold and more than Pages can
  host, so a trimmed web data set (one map and what it needs) is the next step.
  `?manifest=<url>` points the page at another manifest.

Not done yet: touch controls in the browser, a trimmed data set, running a
server (browsers cannot listen), player-ID crypto (`d0_blind_id` is not linked).
