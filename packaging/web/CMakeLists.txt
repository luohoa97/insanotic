# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds insanotic.js + insanotic.wasm: the DarkPlaces SDL2 client with the
# Insanotic Lua runtime and RmlUi, for the browser (Emscripten, WebGL).
#
# The engine runs on the GLES2 renderpath (the one the Android build uses),
# which WebGL implements. Libraries that Emscripten ships as ports (SDL2, zlib,
# libpng, libjpeg, FreeType, Ogg, Vorbis) come from there; Opus is built from
# source like in the Android build. No threads (a GitHub Pages site cannot send
# the headers SharedArrayBuffer needs), so thread_null.c; no sockets to other
# hosts (a browser has none), so a game is a local one.
#
# Use packaging/web/build.sh, which sets this up.
#
# A browser build also exists in dixonSolutions/Xonotic-Touch
# (GPL-3.0-or-later); nothing here is copied from it, this is written for the
# Insanotic engine tree.
#
# Input:
#   INSANOTIC_ENGINE_DIR  the darkplaces/ checkout
#   INSANOTIC_VERSION     string reported by the engine as its build type

cmake_minimum_required(VERSION 3.22)
project(insanotic-web C CXX)

if(NOT EMSCRIPTEN)
	message(FATAL_ERROR "this project is for Emscripten: use packaging/web/build.sh")
endif()
set(CMAKE_POLICY_VERSION_MINIMUM 3.5)

set(INSANOTIC_ENGINE_DIR "" CACHE PATH "path of the darkplaces checkout")
set(INSANOTIC_VERSION "dev" CACHE STRING "version string baked into the engine")
set(INSANOTIC_DEPS_DIR "${CMAKE_BINARY_DIR}/deps" CACHE PATH "download cache for third-party sources")
if(NOT EXISTS "${INSANOTIC_ENGINE_DIR}/sys_sdl.c")
	message(FATAL_ERROR "INSANOTIC_ENGINE_DIR is not a darkplaces checkout: '${INSANOTIC_ENGINE_DIR}'")
endif()
set(DP "${INSANOTIC_ENGINE_DIR}")

set(CMAKE_C_STANDARD 11)

# Emscripten ports. These flags go to every compile and to the link.
set(PORTS -sUSE_SDL=2 -sUSE_ZLIB=1 -sUSE_LIBPNG=1 -sUSE_LIBJPEG=1
	-sUSE_FREETYPE=1 -sUSE_OGG=1 -sUSE_VORBIS=1)
add_compile_options(${PORTS})

include(FetchContent)
set(FETCHCONTENT_BASE_DIR "${INSANOTIC_DEPS_DIR}")
set(FETCHCONTENT_QUIET ON)

# --- Opus + opusfile (same pinned sources as the Android build) ---
FetchContent_Declare(opus
	URL https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
		https://github.com/xiph/opus/releases/download/v1.5.2/opus-1.5.2.tar.gz
	URL_HASH SHA256=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1)
FetchContent_Declare(opusfile
	URL https://downloads.xiph.org/releases/opus/opusfile-0.12.tar.gz
		https://github.com/xiph/opusfile/releases/download/v0.12/opusfile-0.12.tar.gz
	URL_HASH SHA256=118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_DISABLE_INTRINSICS ON CACHE BOOL "" FORCE)
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
	"${opus_SOURCE_DIR}/include")
target_compile_options(opusfile PRIVATE -w)
target_link_libraries(opusfile PUBLIC opus)

# --- the engine: OBJ_SDL + OBJ_COMMON + OBJ_MENU + OBJ_SND_COMMON + OBJ_LUA +
# OBJ_RML from darkplaces/makefile.inc, with thread_null and cd_null ---
set(LUA_SOURCES
	lapi lcode lctype ldebug ldo ldump lfunc lgc llex lmem lobject lopcodes
	lparser lstate lstring ltable ltm lundump lvm lzio lauxlib lbaselib
	lcorolib lmathlib lstrlib ltablib lutf8lib)
set(ENGINE_SOURCES
	builddate.c sys_sdl.c vid_sdl.c thread_null.c
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
list(APPEND SRC "${DP}/zstd/zstddeclib.c")
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

add_executable(insanotic ${SRC})
target_include_directories(insanotic PRIVATE "${DP}" "${DP}/rmlui/Include")
target_compile_definitions(insanotic PRIVATE
	_FILE_OFFSET_BITS=64
	CONFIG_MENU
	CONFIG_CD
	"BUILDTYPE=web-${INSANOTIC_VERSION}"
	"INSANOTIC_VERSION=${INSANOTIC_VERSION}"
	RMLUI_STATIC_LIB
	RMLUI_FONT_ENGINE_FREETYPE
	NO_BUILD_TIMESTAMPS)
target_compile_options(insanotic PRIVATE
	$<$<COMPILE_LANGUAGE:C>:-std=gnu11>
	$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++17>
	-O3 -fno-strict-aliasing -fno-math-errno -fno-trapping-math -w)
# gl_textures.c names desktop-GL enums the GLES2 header lacks (never used on
# the GLES2 renderpath)
set_source_files_properties("${DP}/gl_textures.c" PROPERTIES COMPILE_DEFINITIONS
	"GL_RGBA16F=0x881A;GL_RGBA32F=0x8814;GL_HALF_FLOAT_ARB=0x140B")
target_link_libraries(insanotic PRIVATE opusfile opus idbfs.js m)

# WebGL 1 or 2 (whichever the browser gives: the engine asks for GLES 2);
# FULL_ES2 emulates the client-side vertex arrays the GLES2 path may use.
# Memory grows on demand up to the 32 bit limit; the stack is large because
# the engine keeps big buffers on it. The page starts main() itself, after the
# game data is staged into the virtual file system (loader.js).
target_link_options(insanotic PRIVATE ${PORTS}
	-sMIN_WEBGL_VERSION=1 -sMAX_WEBGL_VERSION=2 -sFULL_ES2=1
	-sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=268435456 -sMAXIMUM_MEMORY=2147483648
	-sSTACK_SIZE=4194304
	-sFORCE_FILESYSTEM=1 -sINVOKE_RUN=0 -sEXIT_RUNTIME=0
	-sMODULARIZE=1 -sEXPORT_NAME=InsanoticEngine -sENVIRONMENT=web
	-sEXPORTED_RUNTIME_METHODS=FS,IDBFS,callMain,ccall,cwrap,UTF8ToString
	-sEXPORTED_FUNCTIONS=_main,_malloc,_free
	-O3)
set_target_properties(insanotic PROPERTIES SUFFIX ".js")
