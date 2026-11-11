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

The APK holds only Insanotic's own files. The first time you start the app it
downloads the official Xonotic 0.8.6 release (about 1 GB) and unpacks the data
packs, so keep roughly 3 GB free and use Wi-Fi. The download resumes if it is
interrupted.

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

## Releases

Pushing a `v*` tag runs the `Release` workflow, which builds a Linux tarball
(engine, game code and mods; start it with `./insanotic.sh`, which links the
Xonotic 0.8.6 data packs from an installed Xonotic), the Flatpak bundle and the
Android APK, and publishes them on the GitHub release of that tag:

```sh
git tag v0.1.0 && git push github v0.1.0
```

## Credits

Insanotic is made by Neil Luo, on top of Xonotic by Team Xonotic and
DarkPlaces by Forest "LordHavoc" Hale and contributors.

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

