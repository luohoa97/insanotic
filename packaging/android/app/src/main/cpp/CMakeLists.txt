# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds libmain.so (the DarkPlaces SDL2 client with the Insanotic Lua
# runtime) plus everything it links, for Android.
#
# The approach (build the engine as the SDL "main" library that SDL's Java
# glue loads, with the third-party libraries compiled from source in the same
# CMake project) follows the layout of dixonSolutions/Xonotic-Touch's Android
# port; the file lists and the dependency handling here are written for the
# Insanotic engine tree.
#
# Inputs (passed by Gradle, see app/build.gradle):
#   INSANOTIC_ENGINE_DIR  the darkplaces/ checkout
#   SDL2_SOURCE_DIR       an unpacked SDL2 source release
#   INSANOTIC_DEPS_DIR    where third-party tarballs are cached (optional)
#   INSANOTIC_VERSION     string reported by the engine as its build type

cmake_minimum_required(VERSION 3.22)
project(insanotic C CXX)

# Newer CMake refuses the old minimum versions some tarballs declare.
set(CMAKE_POLICY_VERSION_MINIMUM 3.5)

set(INSANOTIC_ENGINE_DIR "" CACHE PATH "path of the darkplaces checkout")
set(SDL2_SOURCE_DIR "" CACHE PATH "path of an unpacked SDL2 source release")
set(INSANOTIC_DEPS_DIR "${CMAKE_BINARY_DIR}/deps" CACHE PATH "download cache for third-party sources")
set(INSANOTIC_VERSION "dev" CACHE STRING "version string baked into the engine")

foreach(var INSANOTIC_ENGINE_DIR SDL2_SOURCE_DIR)
	if(NOT EXISTS "${${var}}")
		message(FATAL_ERROR "${var} is not set or does not exist: '${${var}}'")
	endif()
endforeach()
if(NOT EXISTS "${INSANOTIC_ENGINE_DIR}/sys_sdl.c")
	message(FATAL_ERROR "${INSANOTIC_ENGINE_DIR} does not look like a darkplaces checkout")
endif()

set(CMAKE_C_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF)

# ---------------------------------------------------------------------------
# Third-party libraries, all built from pinned source tarballs.
# zlib comes from the NDK. libjpeg is linked in because DarkPlaces refuses to
# dlopen it on Android (jpeg.c). libpng is the one library the engine does
# dlopen on every platform, so it is built as a shared libpng.so that the
# APK ships next to libmain.so (see the "pngdl" target below).
# libcurl is not built: libcurl.c answers the engine's curl calls with Java's
# HttpURLConnection (HttpFetch.kt) over JNI, which does HTTPS with the system's
# certificate authorities, so map and pk3 downloads from servers work.
# ---------------------------------------------------------------------------
include(FetchContent)
set(FETCHCONTENT_BASE_DIR "${INSANOTIC_DEPS_DIR}")
set(FETCHCONTENT_QUIET ON)

FetchContent_Declare(ogg
	URL https://github.com/xiph/ogg/releases/download/v1.3.5/libogg-1.3.5.tar.gz
	URL_HASH SHA256=0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664)
FetchContent_Declare(vorbis
	URL https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz
		https://github.com/xiph/vorbis/releases/download/v1.3.7/libvorbis-1.3.7.tar.gz
	URL_HASH SHA256=0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab)
FetchContent_Declare(opus
	URL https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
		https://github.com/xiph/opus/releases/download/v1.5.2/opus-1.5.2.tar.gz
	URL_HASH SHA256=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1)
FetchContent_Declare(opusfile
	URL https://downloads.xiph.org/releases/opus/opusfile-0.12.tar.gz
		https://github.com/xiph/opusfile/releases/download/v0.12/opusfile-0.12.tar.gz
	URL_HASH SHA256=118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b)
FetchContent_Declare(freetype
	URL https://download.savannah.gnu.org/releases/freetype/freetype-2.13.2.tar.xz
		https://download-mirror.savannah.gnu.org/releases/freetype/freetype-2.13.2.tar.xz
	URL_HASH SHA256=12991c4e55c506dd7f9b765933e62fd2be2e06d421505d7950a132e4f1bb484d)
FetchContent_Declare(png
	URL https://download.sourceforge.net/libpng/libpng-1.6.43.tar.xz
	URL_HASH SHA256=6a5ca0652392a2d7c9db2ae5b40210843c0bbc081cbd410825ab00cc59f14a6c)

# The hosts of some tarballs drop connections now and then, so those carry a
# second URL (same file, same hash).

# --- SDL2 (shared: SDLActivity loads libSDL2.so) ---
set(SDL_SHARED ON CACHE BOOL "" FORCE)
set(SDL_STATIC OFF CACHE BOOL "" FORCE)
set(SDL_TEST OFF CACHE BOOL "" FORCE)
set(SDL_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory("${SDL2_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/sdl2" EXCLUDE_FROM_ALL)

# --- ogg + vorbis (static, for snd_ogg.c LINK_TO_LIBVORBIS) ---
set(INSTALL_DOCS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(INSTALL_CMAKE_PACKAGE_MODULE OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(ogg)
# libvorbis finds libogg through find_package(Ogg); hand it the target.
set(OGG_INCLUDE_DIRS "${ogg_SOURCE_DIR}/include" "${ogg_BINARY_DIR}/include" CACHE STRING "" FORCE)
set(OGG_LIBRARIES ogg CACHE STRING "" FORCE)
set(OGG_LIBRARY ogg CACHE STRING "" FORCE)
set(OGG_INCLUDE_DIR "${ogg_SOURCE_DIR}/include" CACHE STRING "" FORCE)
if(NOT TARGET Ogg::Ogg)
	add_library(Ogg::Ogg ALIAS ogg)
endif()
file(MAKE_DIRECTORY "${ogg_BINARY_DIR}/include")
FetchContent_GetProperties(vorbis)
if(NOT vorbis_POPULATED)
	FetchContent_Populate(vorbis)
	# libvorbis 1.3.7 calls find_package(Ogg REQUIRED); satisfy it with a
	# stub module instead of installing libogg.
	file(WRITE "${vorbis_BINARY_DIR}/FindOgg.cmake" "set(Ogg_FOUND TRUE)\n")
	list(APPEND CMAKE_MODULE_PATH "${vorbis_BINARY_DIR}")
	add_subdirectory("${vorbis_SOURCE_DIR}" "${vorbis_BINARY_DIR}" EXCLUDE_FROM_ALL)
endif()

# --- opus + opusfile (static, for snd_ogg.c LINK_TO_LIBOPUS). libopus builds
# with its own CMake project; opusfile ships only autotools, so its four
# source files are compiled directly (without HTTP streaming, which the
# engine does not use: sounds come from the packs). ---
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(opus)
FetchContent_GetProperties(opusfile)
if(NOT opusfile_POPULATED)
	FetchContent_Populate(opusfile)
endif()
add_library(opusfile STATIC
	"${opusfile_SOURCE_DIR}/src/opusfile.c"
	"${opusfile_SOURCE_DIR}/src/info.c"
	"${opusfile_SOURCE_DIR}/src/internal.c"
	"${opusfile_SOURCE_DIR}/src/stream.c")
target_include_directories(opusfile PRIVATE
	"${opusfile_SOURCE_DIR}/include" "${opusfile_SOURCE_DIR}/src"
	"${ogg_SOURCE_DIR}/include" "${ogg_BINARY_DIR}/include"
	"${opus_SOURCE_DIR}/include")
target_compile_options(opusfile PRIVATE -w)
target_link_libraries(opusfile PUBLIC opus ogg)

# --- freetype (static; fonts are TTF, DP_FREETYPE_STATIC on Android) ---
set(FT_DISABLE_ZLIB OFF CACHE BOOL "" FORCE)
set(FT_DISABLE_BZIP2 ON CACHE BOOL "" FORCE)
set(FT_DISABLE_PNG ON CACHE BOOL "" FORCE)
set(FT_DISABLE_HARFBUZZ ON CACHE BOOL "" FORCE)
set(FT_DISABLE_BROTLI ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(freetype)

# --- libjpeg-turbo (static). Its build system refuses add_subdirectory(), so
# it is an ExternalProject configured with the same NDK toolchain. NASM is not
# assumed, so x86 builds skip SIMD. ---
include(ExternalProject)
set(JPEG_PREFIX "${CMAKE_BINARY_DIR}/jpeg-install")
set(JPEG_SIMD ON)
if(ANDROID_ABI MATCHES "^(x86|x86_64)$")
	set(JPEG_SIMD OFF)
endif()
file(MAKE_DIRECTORY "${JPEG_PREFIX}/include")
ExternalProject_Add(jpeg_ext
	URL https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.0.3/libjpeg-turbo-3.0.3.tar.gz
	URL_HASH SHA256=343e789069fc7afbcdfe44dbba7dbbf45afa98a15150e079a38e60e44578865d
	DOWNLOAD_DIR "${INSANOTIC_DEPS_DIR}/jpeg-dl"
	CMAKE_ARGS
		-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
		-DANDROID_ABI=${ANDROID_ABI}
		-DANDROID_PLATFORM=${ANDROID_PLATFORM}
		-DCMAKE_BUILD_TYPE=Release
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5
		-DCMAKE_INSTALL_PREFIX=${JPEG_PREFIX}
		-DCMAKE_INSTALL_LIBDIR=lib
		-DENABLE_SHARED=OFF
		-DENABLE_STATIC=ON
		-DWITH_TURBOJPEG=OFF
		-DWITH_JAVA=OFF
		-DWITH_SIMD=${JPEG_SIMD}
	BUILD_BYPRODUCTS "${JPEG_PREFIX}/lib/libjpeg.a")
add_library(jpeg-static STATIC IMPORTED GLOBAL)
set_target_properties(jpeg-static PROPERTIES
	IMPORTED_LOCATION "${JPEG_PREFIX}/lib/libjpeg.a"
	INTERFACE_INCLUDE_DIRECTORIES "${JPEG_PREFIX}/include")
add_dependencies(jpeg-static jpeg_ext)

# --- libpng: the engine dlopen()s it (image_png.c tries libpng16.so.16 ...
# and finally plain "libpng.so"). Android packages only lib*.so names, so the
# static libpng is re-linked as a shared libpng.so shipped next to libmain.so. ---
set(PNG_SHARED OFF CACHE BOOL "" FORCE)
set(PNG_STATIC ON CACHE BOOL "" FORCE)
set(PNG_TESTS OFF CACHE BOOL "" FORCE)
set(PNG_TOOLS OFF CACHE BOOL "" FORCE)
set(PNG_FRAMEWORK OFF CACHE BOOL "" FORCE)
set(PNG_HARDWARE_OPTIMIZATIONS ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(png)
file(WRITE "${CMAKE_BINARY_DIR}/png_stub.c" "/* libpng.so is the static libpng, whole-archived */\n")
add_library(pngdl SHARED "${CMAKE_BINARY_DIR}/png_stub.c")
target_link_libraries(pngdl PRIVATE
	-Wl,--whole-archive png_static -Wl,--no-whole-archive z m)
set_target_properties(pngdl PROPERTIES OUTPUT_NAME png)

# ---------------------------------------------------------------------------
# The engine. This list is OBJ_SDL (+ OBJ_COMMON, OBJ_MENU, OBJ_SND_COMMON,
# OBJ_LUA, OBJ_RML) from darkplaces/makefile.inc with the Android choices applied:
# no CD audio (cd_null), no video capture (cap_*), sys_sdl/vid_sdl/thread_sdl.
# ---------------------------------------------------------------------------
set(DP "${INSANOTIC_ENGINE_DIR}")

set(LUA_SOURCES
	lapi lcode lctype ldebug ldo ldump lfunc lgc llex lmem lobject lopcodes
	lparser lstate lstring ltable ltm lundump lvm lzio lauxlib lbaselib
	lcorolib lmathlib lstrlib ltablib lutf8lib)
set(ENGINE_SOURCES
	builddate.c sys_sdl.c vid_sdl.c thread_sdl.c
	menu.c mvm_cmds.c ui_rml_engine.c
	snd_main.c snd_mem.c snd_mix.c snd_ogg.c snd_wav.c snd_sdl.c
	cd_shared.c cd_null.c
	bih.c crypto.c cl_collision.c cl_demo.c cl_dyntexture.c cl_input.c
	cl_main.c cl_parse.c cl_particles.c cl_screen.c cl_video.c clvm_cmds.c
	cmd.c collision.c common.c console.c csprogs.c curves.c cvar.c
	dpsoftrast.c dpvsimpledecode.c filematch.c fractalnoise.c fs.c ft2.c
	utf8lib.c gl_backend.c gl_draw.c gl_rmain.c gl_rsurf.c gl_textures.c
	hmac.c host.c host_cmd.c image.c image_png.c jpeg.c keys.c lhnet.c
	libcurl.c mathlib.c matrixlib.c mdfour.c meshqueue.c
	mod_skeletal_animatevertices_sse.c mod_skeletal_animatevertices_generic.c
	model_alias.c model_brush.c model_shared.c model_sprite.c netconn.c
	palette.c polygon.c portals.c protocol.c prvm_cmds.c prvm_edict.c
	prvm_exec.c r_explosion.c r_lerpanim.c r_lightning.c r_modules.c
	r_shadow.c r_sky.c r_sprites.c sbar.c sv_demo.c sv_lua.c lua_sandbox.c
	cl_lua.c sv_main.c sv_move.c sv_phys.c sv_user.c svbsp.c svvm_cmds.c
	sys_shared.c vid_shared.c view.c wad.c world.c zone.c)

set(SRC)
foreach(f ${ENGINE_SOURCES})
	list(APPEND SRC "${DP}/${f}")
endforeach()
foreach(f ${LUA_SOURCES})
	list(APPEND SRC "${DP}/lua/${f}.c")
endforeach()
# zstd decoder for method-93 pk3 entries (vendored in darkplaces/zstd)
list(APPEND SRC "${DP}/zstd/zstddeclib.c")

# RmlUi (vendored in darkplaces/rmlui) and its glue are C++17; the sources are
# the same directories OBJ_RMLUI in makefile.inc lists.
file(GLOB RMLUI_SOURCES CONFIGURE_DEPENDS
	"${DP}/rmlui/Source/Core/*.cpp"
	"${DP}/rmlui/Source/Core/Elements/*.cpp"
	"${DP}/rmlui/Source/Core/FontEngineDefault/*.cpp"
	"${DP}/rmlui/Source/Core/Layout/*.cpp")
list(APPEND SRC "${DP}/ui_rml.cpp" "${DP}/ui_rml_models.cpp" ${RMLUI_SOURCES})
foreach(f ${SRC})
	if(NOT EXISTS "${f}")
		message(FATAL_ERROR "engine source missing: ${f}")
	endif()
endforeach()

# libmain.so: SDLActivity dlopens it and calls SDL_main (sys_sdl.c includes
# SDL.h, which renames main() to SDL_main on Android).
add_library(main SHARED ${SRC})

# Source-compatible shims for headers the engine tree does not carry.
target_include_directories(main PRIVATE
	"${CMAKE_CURRENT_SOURCE_DIR}/shim"
	"${DP}"
	"${DP}/rmlui/Include")

target_compile_definitions(main PRIVATE
	_FILE_OFFSET_BITS=64
	__KERNEL_STRICT_NAMES
	CONFIG_MENU
	CONFIG_CD
	LINK_TO_LIBJPEG
	"BUILDTYPE=android-${INSANOTIC_VERSION}"
	"INSANOTIC_VERSION=${INSANOTIC_VERSION}"
	RMLUI_STATIC_LIB
	RMLUI_FONT_ENGINE_FREETYPE
	NO_BUILD_TIMESTAMPS)
target_compile_options(main PRIVATE
	$<$<COMPILE_LANGUAGE:C>:-std=gnu11>
	$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++17>
	-O3 -fno-strict-aliasing -fno-math-errno -fno-trapping-math
	-Wno-everything)

# gl_textures.c names desktop-GL enums its GLES2 header lacks (the code paths
# that use them are never taken on the GLES2 renderpath).
set_source_files_properties("${DP}/gl_textures.c" PROPERTIES COMPILE_DEFINITIONS
	"GL_RGBA16F=0x881A;GL_RGBA32F=0x8814;GL_HALF_FLOAT_ARB=0x140B")

target_include_directories(main PRIVATE
	"${ogg_SOURCE_DIR}/include" "${ogg_BINARY_DIR}/include"
	"${vorbis_SOURCE_DIR}/include"
	"${freetype_SOURCE_DIR}/include")

target_link_libraries(main PRIVATE
	SDL2::SDL2
	opusfile vorbisfile vorbis ogg
	freetype
	jpeg-static
	z m dl log android GLESv2)
