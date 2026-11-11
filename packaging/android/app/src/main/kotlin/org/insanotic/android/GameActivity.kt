// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import java.io.File
import org.libsdl.app.SDLActivity

/**
 * Runs the engine. SDLActivity (SDL2's Java glue, fetched by the Gradle
 * build) loads libSDL2.so and libmain.so and calls SDL_main in the latter.
 */
class GameActivity : SDLActivity() {
	override fun getArguments(): Array<String> {
		val base = GameData.baseDir(this)
		val user = GameData.userDir(this)
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
