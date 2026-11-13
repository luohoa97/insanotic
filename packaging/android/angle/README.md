<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# ANGLE for the Android build

ANGLE (BSD-3-Clause, https://github.com/google/angle) translates GLES to
Vulkan, so the game does not depend on the phone's own GLES driver (the
Adreno drivers that black-screen). The engine picks it up when the app
contains `libEGL_angle.so` and `libGLESv2_angle.so`.

## Bundling

Put a pinned ANGLE build here (not committed, ~10 MB per ABI):

    packaging/android/angle/prebuilt/arm64-v8a/libEGL_angle.so
    packaging/android/angle/prebuilt/arm64-v8a/libGLESv2_angle.so

or point Gradle elsewhere with `-Pangle_dir=/path`. Build ANGLE yourself with
`gn args`: `target_os="android" target_cpu="arm64" is_debug=false
angle_enable_vulkan=true angle_enable_gl=false angle_enable_null=false
is_component_build=false`, targets `libEGL` and `libGLESv2`, then rename the
outputs to the `_angle` names. Record the ANGLE commit used in the commit
message of whatever adds the binaries. Keep ANGLE's LICENSE next to them.

Only `arm64-v8a` matters for phones.

## Switching (A/B)

- `-angle` / `-noangle` engine argument, or the saved cvar `vid_android_angle 1`
  (takes effect on the next app start).
- From adb without touching the config:
  `adb shell am start -n org.insanotic.android.dev/org.insanotic.android.GameActivity --es engine_args "-angle"`
- The console prints `GL backend: ANGLE|native (renderer ...)` after
  `GL_RENDERER:`; with ANGLE the renderer string starts with `ANGLE (`.
- If the libraries are missing or fail to load the engine logs why and keeps
  the native driver.
