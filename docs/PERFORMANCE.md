# Profiling Insanotic on a phone or tablet (target: 100+ fps on a Xiaomi Pad 5)

Run these on the device (console `~`, or `adb shell`), in a real match with bots
(`map <name>`, then `addbot` a few times). Write down the numbers before and after
every change.

## 1. Is it the CPU or the GPU?

    r_speeds 1                  // draw calls, triangles, lights per frame
    showfps 1                   // or cl_showfps 1
    r_viewscale 0.5             // with r_viewfbo 1: if fps jumps, you're fill-rate bound
    vid_width / r_viewscale     // lower resolution = same test

- fps jumps at lower `r_viewscale`: GPU fill bound. Keep scale 0.75 or lower, drop effects.
- fps does not move: CPU or driver bound (draw calls, particles, QuakeC). Look at step 2.

## 2. Where does the CPU time go?

    r_timereport_active 1       // per stage times (world, models, particles, ...)
    r_timereport_background 0
    cl_particles 0              // fps jump = particles are the cost
    r_drawentities 0            // fps jump = models/players are the cost
    r_drawworld 0               // fps jump = BSP/world draw is the cost
    r_batch_dynamicbuffer 1     // try: VBO for dynamic batches

Android system profile (no root, gives GPU frame times):

    adb shell setprop debug.hwui.profile visual_bars   // only for UI; for GL use:
    adb shell dumpsys SurfaceFlinger --latency "SurfaceView[org.insanotic.android/org.insanotic.android.GameActivity]"
    adb shell dumpsys gfxinfo org.insanotic.android framestats
    adb logcat -s SDL DarkPlaces

Snapdragon Profiler (free, Qualcomm) shows Adreno 640 GPU time, overdraw and
bandwidth per draw call; use it for the real answer on GPU bound scenes.

## 3. Display refresh

    adb shell dumpsys display | grep -i "mode"

The app now requests the highest refresh mode. If `cl_showfps` caps at 60, check the
Pad's Settings > Display > Refresh rate is not locked to 60.

## 4. What to send back

`r_speeds 1` lines, the fps with `r_viewscale 1 / 0.75 / 0.5`, and the
`r_timereport_active 1` output from one busy fight.
