// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android;

import org.libsdl.app.SDLActivity;

import java.io.File;

/**
 * Runs the engine. SDLActivity (SDL2's Java glue, fetched by the Gradle
 * build) loads libSDL2.so and libmain.so and calls SDL_main in the latter.
 */
public class GameActivity extends SDLActivity {
	@Override
	protected String[] getArguments() {
		File base = GameData.baseDir(this);
		File user = GameData.userDir(this);
		boolean firstRun = !new File(user, "data/config.cfg").isFile();

		java.util.List<String> args = new java.util.ArrayList<>();
		// SDL's argv[0] is not a game name, so name the game explicitly
		args.add("-xonotic");
		args.add("-basedir");
		args.add(base.getPath());
		args.add("-userdir");
		args.add(user.getPath() + "/");
		// platform settings every launch; saved defaults only before the
		// player has a config.cfg of their own
		args.add("+exec");
		args.add("insanotic-android.cfg");
		if (firstRun) {
			args.add("+exec");
			args.add("insanotic-android-defaults.cfg");
		}
		return args.toArray(new String[0]);
	}
}
