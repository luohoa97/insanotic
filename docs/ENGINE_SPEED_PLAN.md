# Insanotic engine speed plan (target: 100 fps on Xiaomi Pad 5)

Honest baseline: ~50 fps. We do not yet know if that is GPU or CPU. Every item below is ordered by
"cheapest way to find out" first. Step 0 decides the rest.

## Step 0. Measure (blocks everything, needs Neil's Pad, 10 minutes)
docs/PERFORMANCE.md in insanotic PR #3. One number matters most: fps at r_viewscale 1 / 0.75 / 0.5.
- Jumps with scale: GPU fill bound. Work on items A.
- Flat: CPU/driver bound. Work on items B.

## A. If GPU bound (most likely at 2560x1600 on Adreno 640)
1. Render scale + FXAA-free upscaling (done, PR #3). Cheapest, biggest.
2. GLES shader diet: DarkPlaces uberShader permutations; strip specular/gloss/offsetmapping/
   deluxemap/reflectcube permutations when running on GLES (force cvars + mask permutation bits).
   Use mediump in fragment shaders where the platform allows.
3. Kill overdraw: r_depthfirst is wrong for tilers; Adreno is tile-based (binning) so avoid
   FBO readbacks and extra passes. Check r_water portal pass, r_viewfbo copies, sky.
4. Texture bandwidth: ASTC 6x6 + mipmaps (other thread), no uncompressed lightmaps.
5. Transparent particles: cl_particles_quality, smaller particle quads, no per-particle blend state flips.

## B. If CPU bound (SD860 big core is ~Cortex-A76, DarkPlaces is mostly single threaded)
1. Draw call / state change count: r_speeds 1 first. Batch same-material surfaces
   (r_batch_multidraw already on), merge dynamic geometry into one buffer (r_batch_dynamicbuffer),
   cache shader permutation lookups.
2. Culling: PVS + frustum are fine in DP; worth checking r_cullentities_*, per-entity
   visibility cost with many players/projectiles, lightmap/dlight work per frame.
3. Particles and effects CPU: biggest per-frame cost in Xonotic fights. Cap counts, simplify per type.
4. QuakeC (CSQC HUD) cost: profile with prof_* / csqc profiling; HUD is heavy QC.
5. Threading: DP has threading primitives (Thread_*), but render/game split is a rewrite,
   huge and risky. Only moves if profile proves one core is pegged while others idle.
   Realistic wins: audio mixing and file/texture decoding off the main thread.
6. NEON SIMD: compilers already auto-vectorise the matrix/vertex transforms with -O3 + NEON;
   explicit intrinsics only after a profile names a loop.
7. GLES3 features: persistent mapped buffers need GL_EXT_buffer_storage (Adreno 640 has it, not
   guaranteed): use for dynamic VBOs if present. Instancing for static props via GLES3.

## What "greedy rendering" would mean here
Rendering less when frame time is high: dynamic resolution (r_viewscale_fpsscaling exists in this
engine), distance-culling decals/particles, lower tick of far entities. That is the right instinct and
is cheap. Add as preset: r_viewscale_fpsscaling 1 targeting 100 fps.

## What not to do
- Rewrite renderer / multithread whole client before profiling. Months of work, often 0 gain if GPU bound.
- Port the engine (Rust/Daemon): already decided no.

## Order of work
1. PR #3 (preset, 120Hz, cap) -> Neil measures.
2. Dynamic resolution on by default for Android (small).
3. GLES shader permutation diet on new DP base (other thread landing the upgrade first).
4. Particle/CSQC cost caps from the profile.
5. Larger engine work only if the profile demands it.
