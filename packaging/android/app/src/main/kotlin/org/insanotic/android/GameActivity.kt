// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import java.io.File
import org.libsdl.app.SDLActivity

/**
 * Runs the engine. SDLActivity (SDL2's Java glue, fetched by the Gradle
 * build) loads libSDL2.so and libmain.so and calls SDL_main in the latter.
 */
class GameActivity : SDLActivity() {
	override fun onPause() {
		super.onPause()
		// the game may stay in the background for a while: keep it alive
		if (!isFinishing) PausedService.start(this)
	}

	override fun onResume() {
		super.onResume()
		PausedService.stop(this)
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
		return args.toTypedArray()
	}
}
