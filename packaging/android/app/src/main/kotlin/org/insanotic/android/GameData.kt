// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import android.content.Context
import java.io.File
import java.io.IOException

/**
 * Where the game files live. The APK carries only Insanotic's own files
 * (compiled QC, Lua mods, cfgs) as one pk3; the Xonotic 0.8.6 data packs are
 * fetched by [PackDownloader] into [dataDir].
 */
object GameData {
	const val RELEASE_URL = "https://dl.xonotic.org/xonotic-0.8.6.zip"

	/** the repacked packs (misc/insanotic/repack-assets.sh, workflow "Repack assets") */
	const val ASSETS_URL = "https://github.com/luohoa97/insanotic/releases/download/assets-0.8.6-r2"

	/** the pk3 inside the APK assets; named to sort after every official pack so it wins */
	const val OWN_PK3 = "zzz-insanotic-android.pk3"

	private const val PACKS_MARKER = ".xonotic-0.8.6-packs"
	private const val MUSIC_MARKER = ".xonotic-0.8.6-music"
	private const val OWN_MARKER = ".insanotic-pk3-stamp"

	/** -basedir: large data goes to the app's external files dir (no permission needed). */
	fun baseDir(ctx: Context): File {
		val ext = ctx.getExternalFilesDir(null)
		return File(ext ?: ctx.filesDir, "xonotic").also { it.mkdirs() }
	}

	/** -userdir: configs, saves, downloads; private storage. */
	fun userDir(ctx: Context): File = File(ctx.filesDir, "userdir").also { it.mkdirs() }

	fun dataDir(ctx: Context): File = File(baseDir(ctx), "data").also { it.mkdirs() }

	/**
	 * Development builds were debugged by pushing an autoexec.cfg over adb
	 * that sends the console to a computer on the network (log_dest_udp)
	 * and checks every GL call (gl_paranoid, very slow). Players never
	 * write such a file; remove it so a test device plays normally again.
	 */
	fun removeDebugAutoexec(ctx: Context) {
		val f = File(dataDir(ctx), "autoexec.cfg")
		if (f.isFile && f.length() < 4096) {
			val text = runCatching { f.readText() }.getOrDefault("")
			if (text.contains("log_dest_udp") || text.contains("gl_paranoid"))
				f.delete()
		}
	}

	fun packsInstalled(ctx: Context): Boolean = File(dataDir(ctx), PACKS_MARKER).isFile

	fun markPacksInstalled(ctx: Context, withMusic: Boolean) {
		File(dataDir(ctx), PACKS_MARKER).writeText("xonotic-0.8.6\n")
		if (withMusic)
			File(dataDir(ctx), MUSIC_MARKER).writeText("xonotic-0.8.6\n")
	}

	/** True when the packs and this build's own pk3 are both in place. */
	fun isReady(ctx: Context): Boolean = packsInstalled(ctx) && ownPk3Current(ctx)

	@Suppress("DEPRECATION")
	private fun stamp(ctx: Context): String {
		val pi = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
		return "${pi.versionName}/${pi.lastUpdateTime}"
	}

	fun ownPk3Current(ctx: Context): Boolean {
		val data = dataDir(ctx)
		val marker = File(data, OWN_MARKER)
		return try {
			marker.isFile && File(data, OWN_PK3).isFile && marker.readText() == stamp(ctx)
		} catch (e: IOException) {
			false
		}
	}

	/** Copies Insanotic's pk3 out of the APK. Blocking; call it off the main thread. */
	fun installOwnPk3(ctx: Context) {
		val data = dataDir(ctx)
		val tmp = File(data, "$OWN_PK3.part")
		ctx.assets.open(OWN_PK3).use { input -> tmp.outputStream().use { input.copyTo(it) } }
		val dst = File(data, OWN_PK3)
		dst.delete()
		if (!tmp.renameTo(dst))
			throw IOException("cannot install $OWN_PK3")
		File(data, OWN_MARKER).writeText(stamp(ctx))
	}
}
