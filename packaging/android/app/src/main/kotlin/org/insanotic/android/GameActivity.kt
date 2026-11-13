// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import java.io.File
import org.libsdl.app.SDLActivity

/**
 * Runs the engine. SDLActivity (SDL2's Java glue, fetched by the Gradle
 * build) loads libSDL2.so and libmain.so and calls SDL_main in the latter.
 */
class GameActivity : SDLActivity() {
	companion object {
		/** the newest insanotic-android-update-N.cfg in src/gamedata */
		private const val UPDATES = 2
	}

	override fun onPause() {
		super.onPause()
		// the game may stay in the background for a while: keep it alive
		if (!isFinishing) PausedService.start(this)
	}

	override fun onResume() {
		super.onResume()
		PausedService.stop(this)
		requestFastestDisplayMode()
	}

	/**
	 * Many tablets (Xiaomi Pad 5: 60/90/120 Hz) start apps at 60 Hz. Ask for
	 * the highest refresh rate at the current resolution so vsync can hit 100+.
	 */
	private fun requestFastestDisplayMode() {
		if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.M) return
		try {
			val display = windowManager.defaultDisplay
			val cur = display.mode
			val best = display.supportedModes
				.filter { it.physicalWidth == cur.physicalWidth && it.physicalHeight == cur.physicalHeight }
				.maxByOrNull { it.refreshRate } ?: return
			val attrs = window.attributes
			if (attrs.preferredDisplayModeId != best.modeId) {
				attrs.preferredDisplayModeId = best.modeId
				window.attributes = attrs
			}
		} catch (e: Exception) {
			// a refresh rate hint is never worth a crash
		}
	}

	override fun onDestroy() {
		PausedService.stop(this)
		super.onDestroy()
	}

	override fun getArguments(): Array<String> {
		val base = GameData.baseDir(this)
		val user = GameData.userDir(this)
		GameData.removeDebugAutoexec(this)
		val firstRun = !File(user, "data/config.cfg").isFile

		// SDL's argv[0] is not a game name, so name the game explicitly
		val args = mutableListOf("-xonotic", "-basedir", base.path, "-userdir", user.path + "/")
		// platform settings every launch; saved defaults only before the
		// player has a config.cfg of their own
		args += listOf("+exec", "insanotic-android.cfg")
		if (firstRun)
			args += listOf("+exec", "insanotic-android-defaults.cfg")
		// settings changes for players who already have a config.cfg: each
		// insanotic-android-update-N.cfg runs once (first run: the defaults
		// above already have them)
		val prefs = getSharedPreferences("game", MODE_PRIVATE)
		val done = if (firstRun) UPDATES else prefs.getInt("settings_updates", 0)
		for (n in done + 1..UPDATES)
			args += listOf("+exec", "insanotic-android-update-$n.cfg")
		prefs.edit().putInt("settings_updates", UPDATES).apply()
		// dev hook for A/B tests, e.g. adb shell am start -n <pkg>/.GameActivity
		// --es engine_args "-angle +r_viewfbo 1"
		intent?.getStringExtra("engine_args")?.trim()?.split(Regex("\\s+"))?.filter { it.isNotEmpty() }?.let { args += it }
		return args.toTypedArray()
	}
}
