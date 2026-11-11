# Insanotic

**Insanotic** is a fork of [Xonotic](https://xonotic.org) 0.8.6 that adds
Lua scripting. Server **plugins** (`plugins/<name>/init.lua`) hook every
gameplay event of the dedicated server, in a sandbox that disables a
misbehaving plugin instead of crashing the server. Players connect with an
unmodified Xonotic 0.8.6 client. Client-side Lua **mods**, touch controls
and a launcher are in progress.

The project is three repositories, like upstream Xonotic:

| Repository | Contents |
|---|---|
| [insanotic](https://github.com/luohoa97/insanotic) | this one: build scripts, docs, example plugins |
| [insanotic-darkplaces](https://github.com/luohoa97/insanotic-darkplaces) | engine (DarkPlaces) with the Lua runtime |
| [insanotic-data](https://github.com/luohoa97/insanotic-data) | game code (QuakeC) and data |

### Build and run

Needs git, a C compiler, make, curl and SDL2 development files for the
client. Every command below is plain POSIX sh, so it works from fish too.

```sh
git clone https://github.com/luohoa97/insanotic.git
cd insanotic
misc/insanotic/checkout.sh   # engine, game code, compiler
make run-server              # build everything, start a server with plugins
make test-plugins            # sandbox tests
```

Docs: [docs/MODDING.md](docs/MODDING.md) (plugin quickstart, API, sandbox
limits) and [docs/hooks.md](docs/hooks.md) (every server hook).

Insanotic is free software under the GNU GPL version 3 or later, like
Xonotic. The vendored Lua 5.4 is MIT licensed (`darkplaces/lua/LICENSE`).

---

# Xonotic

![Xonotic Logo](https://xonotic.org/static/img/xonotic_logo_web.svg)

Xonotic is an addictive, arena-style first person shooter with crisp movement and a wide array of weapons. It combines intuitive mechanics with in-your-face action to elevate your heart rate.

## Launcher

A desktop launcher (Rust, GTK 4 + libadwaita) starts the game, hosts a local
server with a live console and per-plugin switches for its server plugins,
lists client mods with enable switches, and passes the quick toggles (aim
assist, touch controls) to the game.

```sh
make launcher            # build launcher/target/release/insanotic-launcher
make launcher-install    # install it, its icon and .desktop file into ~/.local
```

It needs the GTK 4 and libadwaita development files and a Rust toolchain. It
finds the game in the directory it was built from; set `INSANOTIC_DIR` or the
game directory in its Settings page to use another checkout. Settings are kept
in `~/.config/insanotic/launcher.json`. The game keeps its configs, saves and
your own mods in `~/.insanotic` (mods go in `~/.insanotic/data/mods`, which the
Mods page's "Open Mods Folder" button opens).

### Flatpak

`packaging/flatpak/` builds the launcher, the engine and the Insanotic data as
a Flatpak (`io.github.luohoa97.Insanotic`). The large Xonotic 0.8.6 packs are not
bundled: on first run the launcher links them from an installed
`org.xonotic.Xonotic` Flatpak or downloads the official release. Build it with

```sh
flatpak-builder --user --install --force-clean --jobs=2 \
    --state-dir=build/flatpak-state build/flatpak-app \
    packaging/flatpak/io.github.luohoa97.Insanotic.yml
```

After changing `launcher/Cargo.lock`, regenerate `cargo-sources.json` with
`packaging/flatpak/gen-cargo-sources.sh`.

### Android

Insanotic runs on Android 5.0 or newer (arm64-v8a and x86_64; OpenGL ES 2.0).
Touch controls come from the `touch_controls` mod. It has not been tested on
many devices yet, so expect rough edges.

To install, download `insanotic-<version>-android.apk` from the
[Releases](https://github.com/luohoa97/insanotic/releases) page on the phone,
open it and allow installing from this source when Android asks (the APK is
not from the Play Store, and release builds are signed with a debug key unless
the maintainers configured a keystore, so Android may warn). Or install it
from a computer with `adb install insanotic-<version>-android.apk`.

The APK holds only Insanotic's own files. On first start the app downloads the
data packs (about 950 MB) from the official Xonotic 0.8.6 release straight into
the game folder, so it needs about 1 GB of free storage. Wi-Fi is recommended.
The download uses several connections at once, runs in a foreground service
with a progress notification, and survives leaving the app, rotating the screen
or the system killing the app: it continues from the bytes already on disk.
The music pack (111 MB) is optional: a checkbox on the setup screen, off by
default.

The app updates itself: when it starts (at most every six hours) and from the
"Check for updates" button on the setup screen it looks at the `nightly`
release (`version.json`), and if there is a newer build offers to download and
install it. Android asks once to allow Insanotic to install apps. Updates only
install over an app signed with the same key, which is the case for APKs from
the releases page once the maintainers have configured a signing key.

To build the APK yourself you need a JDK 17, the Android SDK with platform 35,
build-tools 36.0.0, NDK 28.2.13676358 and CMake 3.22.1, and the compiled QC
(`make insanotic-qc` after `misc/insanotic/checkout.sh`). Then, from the
repository root:

```sh
export ANDROID_HOME=$HOME/Android/Sdk
packaging/android/gradlew -p packaging/android assembleRelease
```

The APK is `packaging/android/app/build/outputs/apk/release/app-release.apk`.
Useful options are `-Pabis=arm64-v8a` (one ABI builds faster),
`-Pversion_name=...` and `-Pversion_code=...`. SDL2 and the other third-party
libraries are downloaded and built from source on the first build. Set
`ANDROID_KEYSTORE`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and
`ANDROID_KEY_PASSWORD` to sign with your own key.

## Repacked game data

The official 0.8.6 packs are big and slow for a phone, so Insanotic can use
repacked copies, published as assets of a GitHub release (`assets-0.8.6-r2`;
not stored in git). `misc/insanotic/repack-assets.sh` makes them, and the
"Repack assets" workflow runs it and uploads the result with a table of sizes
before and after in its job summary. Sizes of the published android set: data
400 MB (official 318), maps 581 MB (626), music 71 MB (111); desktop set: data
285 MB, maps 595 MB.

- Entries are compressed with zstd (zip method 93) instead of deflate, which
  the engine decodes several times faster; files that are compressed already
  (jpg, Ogg, ...) stay stored.
- Ogg Vorbis sound becomes Ogg Opus (`.opus`). The engine plays `.opus` next
  to `.ogg` (libopusfile, loaded at run time on desktop, built in on Android),
  and a request for `foo.ogg` or `foo.wav` finds `foo.opus`.
- The `android` set also turns S3TC textures (`dds/foo.dds`) into ASTC in a
  KTX 1 file with all mip levels (`dds/foo.ktx`): 8x8 blocks for color, 6x6
  for normal maps and 2D graphics in the published set (`ASTC_COLOR` and
  `ASTC_DETAIL` change that; the script's own defaults, 6x6 and 4x4, make a
  better looking set that is half as big again as the official packs). The engine uploads them as they are when the GPU has
  `GL_KHR_texture_compression_astc_ldr`, and otherwise reads the `.dds`
  (`r_texture_astc_load 0` turns ASTC off).

The Android app asks the GPU for ASTC, and when it is there and the release
is reachable downloads the `android-*` packs (listed in `manifest-android.txt`
of the release); otherwise it takes the official packs from dl.xonotic.org as
before. A player who already has the official packs is offered, once, to replace them
("Optimize game data for this device", with the download size): the repacked
packs are downloaded next to the old ones as `.new` files, checked against their
CRC32, and only when all are complete do they replace the old ones (the music
pack only if it was installed). Otherwise a pack that is already in the data
directory is never replaced or deleted. Run `misc/insanotic/test-repack.sh` to test the repacker.

## Nightly builds

Every change to the main branch is built and published:

- Android and Linux: the [nightly release](https://github.com/luohoa97/insanotic/releases/tag/nightly)
  (`insanotic-android.apk`, `insanotic-linux-x86_64.tar.gz`, `insanotic.flatpak`).
- Flatpak repository on GitHub Pages:

  ```sh
  flatpak remote-add --if-not-exists insanotic https://luohoa97.github.io/insanotic/insanotic.flatpakrepo
  flatpak install insanotic io.github.luohoa97.Insanotic
  ```

  `flatpak update` then picks up new builds.

## Releases

Pushing a `v*` tag runs the `Release` workflow, which builds a Linux tarball
(engine, game code and mods; start it with `./insanotic.sh`, which links the
Xonotic 0.8.6 data packs from an installed Xonotic), the Flatpak bundle and the
Android APK, and publishes them on the GitHub release of that tag:

```sh
git tag v0.1.0 && git push github v0.1.0
```

## RmlUi menus

The engine carries [RmlUi](https://github.com/mikke89/RmlUi), which lays out
documents written in RML (HTML-like) and RCSS (CSS-like). The main menu is
`data/insanotic.pk3dir/ui/mainmenu.rml` and `mainmenu.rcss`; it replaces the
QuakeC main screen while the cvar `menu_rmlui` is 1 (the default), and the
buttons still open the QuakeC dialogs. With `menu_rmlui 0` the menu is as it
was. Sizes are in dp: 720 dp is the short side of the window on a monitor and
450 dp on a touch screen (`rml_scale` sets pixels per dp by hand); phone
layouts are RCSS media queries.

In a document, `data-cmd="..."` on an element runs that console command when
it is clicked or tapped, and `data-cvar="name"` shows a cvar, or on a form
control shows it and writes changes back. The widget set (dialogs, buttons,
switches, sliders, dropdowns, tabs, lists) is described in
[docs/UI.md](docs/UI.md). A server can open its own pages in the players'
game, which can only answer that server: see "Pages from a server" in
[docs/MODDING.md](docs/MODDING.md). Console commands:
`rml_show <name>` (shows `ui/<name>.rml` above everything), `rml_hide [name]`,
`rml_reload` (documents, stylesheets and images again, for editing),
`rml_list`. `make test-rml` clicks through the main menu (it needs a display).

## Credits

Insanotic is made by Neil Luo, on top of Xonotic by Team Xonotic and
DarkPlaces by Forest "LordHavoc" Hale and contributors.

The menus are drawn by [RmlUi](https://github.com/mikke89/RmlUi) (MIT,
Copyright 2008-2014 CodePoint Ltd, Shift Technology Ltd, and contributors;
2019-2026 The RmlUi Team, and contributors), vendored in `darkplaces/rmlui/`
with its license. Its text is set in the Xolonium font by Severin Meyer
(GPL with the font exception, `data/insanotic.pk3dir/ui/fonts/README.txt`).

The repacking pipeline uses [ASTC Encoder](https://github.com/ARM-software/astc-encoder)
(Apache-2.0, Arm Limited), FFmpeg and libopus (Xiph.Org) at build time only, and
the engine decodes zstd with the Zstandard library (BSD, Meta; `darkplaces/zstd/`)
and Opus with libopus and opusfile (BSD, Xiph.Org).

The menu music is a darker mix (a semitone lower, softer highs, light reverb)
of Xonotic's "Rising of the Phoenix", made for Insanotic
(`data/insanotic.pk3dir/sound/cdtracks/rising-of-the-phoenix.ogg`).

## License

Xonotic is and will always be free and open source. It is available under the [copyleft](https://www.gnu.org/copyleft/)-style [GPLv3+](https://www.gnu.org/licenses/gpl-3.0.html) license (see the [COPYING](COPYING) file for details).

## Download

Stable releases and related info are available at https://xonotic.org/download

[Beta builds](https://gitlab.com/xonotic/xonotic/-/wikis/Autobuilds) are available at https://beta.xonotic.org/autobuild

The source code included in stable releases and autobuilds can be [compiled as described on the wiki](https://gitlab.com/xonotic/xonotic/-/wikis/Compiling).  This is much "lighter" than a full git clone.

*Please note, [Gitlab](https://gitlab.com/xonotic/) is our home for repositories, issue tracking, wikis, etc. The repositories on GitHub are mirrors of GitLab's unless specified otherwise.*

## Community

The community is primarily active in the [forums](https://forums.xonotic.org/) and [chat rooms](https://gitlab.com/xonotic/xonotic/-/wikis/Chat-Rooms).

## Documentation

[Halogene's Newbie Guide](https://xonotic.org/guide) gives gameplay and client configuration advice.  
[Frequently Asked Questions](https://xonotic.org/faq) cover common tech support topics.  
[The GitLab wiki](https://gitlab.com/xonotic/xonotic/-/wikis/home) has detailed articles and links for many relevant topics.  
[Command Alias & Cvar Search](https://xonotic.org/tools/cacs) is a web interface to browse Xonotic console features.  
[Doxygen](https://xonotic.org/doxygen) makes it easier to discover details and dependencies in the code.  

## Developing

To compile the latest revision from git, [follow this guide](https://gitlab.com/xonotic/xonotic/wikis/Repository_Access). Learn more about the [directory structure here](https://gitlab.com/xonotic/xonotic/wikis/Git). Check out [our project page on GitLab](https://gitlab.com/groups/xonotic) to see [development activity](https://gitlab.com/groups/xonotic/-/activity) and code ([xonotic-data.pk3dir](https://gitlab.com/xonotic/xonotic-data.pk3dir) is where most development takes place).

Please ensure you've read and understood [Contributing and Getting Write Access](https://gitlab.com/xonotic/xonotic/-/wikis/Repository_Access#contributing-and-getting-write-access) before pushing commits or opening merge requests.

## Contributing

We're looking for help in the following areas:

- [Translations](https://www.transifex.com/team-xonotic/xonotic/)
  - More info [on the wiki](https://gitlab.com/xonotic/xonotic/-/wikis/home#translating)
- [Modeling and texturing](https://gitlab.com/xonotic/xonotic-data.pk3dir/issues?label_name=Area%3A+Assets)
- Documentation
  - Some of it is still scattered in [Docs](https://gitlab.com/xonotic/xonotic/tree/master/Docs) instead of being on our [wiki](https://gitlab.com/xonotic/xonotic/wikis/home)
  - Some [wiki](https://gitlab.com/xonotic/xonotic/wikis/home) pages are slightly out of date or contain links to empty pages
  - Fixing typos everywhere and anywhere - attention to detail is important to make a good impression on potential players
  - Even if you're new, just letting us know what you're struggling with helps so we can focus on improving those areas first
- Testing
  - If you're running a server or play off-line often, please consider using the [autobuild](https://gitlab.com/xonotic/xonotic/wikis/Autobuilds) or [git](https://gitlab.com/xonotic/xonotic/wikis/Repository_Access) versions to help us find bugs (when playing online, the server's version of the gamecode is downloaded and used by all clients so you have to play offline or run your own server for testing)
- PR
  - Please don't create anything that looks official (social media accounts, entries on pages like steam, etc.) without contacting us, we like to manage things ourselves to keep the information up to date
  - All other kinds of PR are very welcome - make videos or articles, share links, spread the word

