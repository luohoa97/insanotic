# SPDX-License-Identifier: GPL-3.0-or-later
#
# Insanotic build and run targets, included from the top-level Makefile.
# Recipes are plain POSIX sh, so they work the same from fish, bash or zsh.
#
#   make run              build client + QC and start Insanotic (menu)
#   make run-server       build engine + QC, fetch the map, start a dedicated
#                         server with Lua plugins on (g_lua 1) and some bots
#   make test-plugins     end-to-end test of the plugin sandbox
#   make test-rml         click through the RmlUi main menu (needs a display)
#   make insanotic        build the dedicated engine and the QC
#   make insanotic-client build the SDL client
#   make insanotic-hooks  regenerate docs/hooks.md and the QC hook forwarders
#   make launcher         build the desktop launcher (launcher/)
#   make launcher-install install the launcher into ~/.local
#
# Knobs: INSANOTIC_MAP, INSANOTIC_PORT, INSANOTIC_BOTS, INSANOTIC_DP_FLAGS.

INSANOTIC_GOALS := run insanotic insanotic-server insanotic-client insanotic-qc \
	insanotic-gmqcc insanotic-map insanotic-hooks run-server test-plugins test-rml \
	launcher launcher-install

INSANOTIC_MAP ?= stormkeep
INSANOTIC_PORT ?= 26000
INSANOTIC_BOTS ?= 3
# libjpeg is loaded at runtime so the build does not need its headers
INSANOTIC_DP_FLAGS ?= DP_LINK_JPEG=dlopen
# keep the client QC watermark equal to the release so csprogs.dat matches
# what stock 0.8.6 clients already have and nothing has to be downloaded
INSANOTIC_WATERMARK ?= xonotic-v0.8.6

# "make" and "make help" in a git checkout should not hit the release-only error
ifneq ($(filter $(INSANOTIC_GOALS) help,$(or $(MAKECMDGOALS),help)),)
INSANOTIC_BUILD := 1
# the release-tarball settings above (d0_blind_id static link, -march=native
# in CC) do not apply to a git checkout
unexport CC DP_LINK_CRYPTO CFLAGS_CRYPTO LIB_CRYPTO DP_LINK_CRYPTO_RIJNDAEL
endif

.PHONY: $(INSANOTIC_GOALS)

insanotic: insanotic-server insanotic-qc

insanotic-gmqcc:
	$(MAKE) -C gmqcc gmqcc

insanotic-qc: insanotic-gmqcc
	$(MAKE) -C data/xonotic-data.pk3dir/qcsrc qc \
		QCC=../../../../gmqcc/gmqcc QCCFLAGS_WATERMARK=$(INSANOTIC_WATERMARK)

# the engine shows it as insanotic_version; CI sets the release name
INSANOTIC_VERSION ?= dev-$(shell git rev-parse --short HEAD 2>/dev/null)

insanotic-server:
	$(MAKE) -C darkplaces sv-release CFLAGS_EXTRA='$(CFLAGS_EXTRA) -DINSANOTIC_VERSION=$(INSANOTIC_VERSION)' $(INSANOTIC_DP_FLAGS)

insanotic-client:
	$(MAKE) -C darkplaces sdl-release CFLAGS_EXTRA='$(CFLAGS_EXTRA) -DINSANOTIC_VERSION=$(INSANOTIC_VERSION)' $(INSANOTIC_DP_FLAGS)

# official 0.8.6 map pack from an installed Xonotic when there is one (maps
# with textures), otherwise just the compiled map from the autobuild server
# (link-release-data.sh only links missing packs' targets; repack-stored.sh
# then makes local uncompressed copies once, for fast loading)
insanotic-map:
	if [ ! -f data/xonotic-20230620-data.pk3 ] || [ -L data/xonotic-20230620-data.pk3 ]; then \
		sh misc/insanotic/link-release-data.sh 2>/dev/null && sh misc/insanotic/repack-stored.sh \
		|| sh misc/insanotic/fetch-map.sh $(INSANOTIC_MAP); \
	fi

insanotic-hooks:
	sh misc/insanotic/gen-lua-hooks.sh

run: insanotic-client insanotic-qc insanotic-map
	./darkplaces/darkplaces-sdl -xonotic

run-server: insanotic-server insanotic-qc insanotic-map
	./darkplaces/darkplaces-dedicated -xonotic -userdir build/userdir \
		+port $(INSANOTIC_PORT) +exec insanotic-server.cfg \
		+set bot_number $(INSANOTIC_BOTS) +map $(INSANOTIC_MAP)

test-plugins: insanotic-server insanotic-qc insanotic-map
	sh misc/insanotic/test-plugins.sh

test-rml: insanotic-client insanotic-qc insanotic-map
	sh misc/insanotic/test-rml.sh

# Desktop launcher (Rust, GTK 4 + libadwaita), see launcher/
#   make launcher           build launcher/target/release/insanotic-launcher
#   make launcher-install   install it, its icon and .desktop file into ~/.local
INSANOTIC_CARGO ?= cargo
INSANOTIC_PREFIX ?= $(HOME)/.local

launcher:
	cd launcher && $(INSANOTIC_CARGO) build --release

launcher-install: launcher
	install -Dm755 launcher/target/release/insanotic-launcher $(INSANOTIC_PREFIX)/bin/insanotic-launcher
	install -Dm644 launcher/data/icons/hicolor/scalable/apps/io.github.luohoa97.Insanotic.svg \
		$(INSANOTIC_PREFIX)/share/icons/hicolor/scalable/apps/io.github.luohoa97.Insanotic.svg
	mkdir -p $(INSANOTIC_PREFIX)/share/applications
	sed 's|^Exec=.*|Exec=$(INSANOTIC_PREFIX)/bin/insanotic-launcher|' \
		launcher/data/io.github.luohoa97.Insanotic.desktop \
		> $(INSANOTIC_PREFIX)/share/applications/io.github.luohoa97.Insanotic.desktop
	install -Dm644 launcher/data/io.github.luohoa97.Insanotic.metainfo.xml \
		$(INSANOTIC_PREFIX)/share/metainfo/io.github.luohoa97.Insanotic.metainfo.xml
	-gtk-update-icon-cache -q -t $(INSANOTIC_PREFIX)/share/icons/hicolor
	-update-desktop-database -q $(INSANOTIC_PREFIX)/share/applications
