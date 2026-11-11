// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.pm.PackageInfoCompat
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject

/** A newer APK on the release page. */
data class UpdateInfo(val versionCode: Long, val versionName: String, val apkUrl: String)

sealed interface Update {
	/** nothing checked yet */
	data object Idle : Update

	data object Checking : Update

	data object UpToDate : Update

	/** the check itself failed (offline, no release yet): not worth bothering the player */
	data object CheckFailed : Update

	data class Available(val info: UpdateInfo) : Update

	/** Android has to be told once that this app may install apps */
	data class NeedsPermission(val info: UpdateInfo) : Update

	data class Downloading(val info: UpdateInfo, val done: Long, val total: Long) : Update

	/** handed to the system installer, which may ask the player to confirm */
	data object Installing : Update

	data class InstallFailed(val message: String) : Update
}

/**
 * Self-update from the GitHub release called "nightly": version.json says
 * which build is there, insanotic-android.apk is the build. The APK is
 * streamed into a PackageInstaller session, so it is never stored. Android
 * only accepts it when it is signed with the same key as the installed app.
 */
object UpdateModel {
	private const val BASE = "https://github.com/luohoa97/insanotic/releases/download/nightly/"
	private const val PREFS = "update"
	private const val LAST_CHECK = "lastCheck"
	private const val CHECK_EVERY_MS = 6L * 60 * 60 * 1000
	const val ACTION_RESULT = "org.insanotic.android.UPDATE_RESULT"

	private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
	private var job: Job? = null
	private val mutableState = MutableStateFlow<Update>(Update.Idle)
	val state: StateFlow<Update> = mutableState

	fun installedCode(ctx: Context): Long =
		PackageInfoCompat.getLongVersionCode(ctx.packageManager.getPackageInfo(ctx.packageName, 0))

	fun installedName(ctx: Context): String =
		ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: "?"

	/**
	 * Looks for a newer build. Unless forced, at most every few hours, so that
	 * starting the game is not held up by the network every time.
	 */
	fun check(ctx: Context, force: Boolean) {
		val app = ctx.applicationContext
		val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
		if (job?.isActive == true)
			return
		if (!force && System.currentTimeMillis() - prefs.getLong(LAST_CHECK, 0) < CHECK_EVERY_MS) {
			mutableState.value = Update.UpToDate
			return
		}
		mutableState.value = Update.Checking
		job = scope.launch {
			mutableState.value = try {
				val info = fetchInfo()
				prefs.edit().putLong(LAST_CHECK, System.currentTimeMillis()).apply()
				if (info.versionCode > installedCode(app)) Update.Available(info) else Update.UpToDate
			} catch (e: IOException) {
				Update.CheckFailed
			} catch (e: org.json.JSONException) {
				Update.CheckFailed
			}
		}
	}

	private fun fetchInfo(): UpdateInfo {
		val c = URL(BASE + "version.json").openConnection() as HttpURLConnection
		c.connectTimeout = 4000
		c.readTimeout = 4000
		try {
			if (c.responseCode != 200)
				throw IOException("HTTP ${c.responseCode}")
			val json = JSONObject(c.inputStream.use { it.readBytes().toString(Charsets.UTF_8) })
			return UpdateInfo(json.getLong("versionCode"), json.optString("versionName", "?"), BASE + "insanotic-android.apk")
		} finally {
			c.disconnect()
		}
	}

	/** Downloads the APK into an install session and commits it. */
	fun install(ctx: Context, info: UpdateInfo) {
		val app = ctx.applicationContext
		if (Build.VERSION.SDK_INT >= 26 && !app.packageManager.canRequestPackageInstalls()) {
			mutableState.value = Update.NeedsPermission(info)
			return
		}
		if (job?.isActive == true)
			return
		job = scope.launch {
			try {
				mutableState.value = Update.Downloading(info, 0, 0)
				stream(app, info)
				mutableState.value = Update.Installing
			} catch (e: CancellationException) {
				throw e
			} catch (e: Exception) {
				mutableState.value = Update.InstallFailed(e.message ?: e.toString())
			}
		}
	}

	/** Opens the system screen where the player allows this app to install apps. */
	fun permissionIntent(ctx: Context): Intent =
		Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}"))
			.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

	/** Called by [UpdateReceiver] when the installer reports back. */
	fun failed(message: String) {
		mutableState.value = Update.InstallFailed(message)
	}

	private fun stream(app: Context, info: UpdateInfo) {
		val installer = app.packageManager.packageInstaller
		val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
		params.setAppPackageName(app.packageName)
		val id = installer.createSession(params)
		val session = installer.openSession(id)
		var committed = false
		val c = URL(info.apkUrl).openConnection() as HttpURLConnection
		c.connectTimeout = 15000
		c.readTimeout = 30000
		try {
			if (c.responseCode != 200)
				throw IOException("HTTP ${c.responseCode} for the update")
			val total = c.contentLengthLong
			session.openWrite("insanotic.apk", 0, total).use { out ->
				c.inputStream.use { input ->
					val buf = ByteArray(64 * 1024)
					var done = 0L
					var last = 0L
					while (true) {
						val n = input.read(buf)
						if (n < 0) break
						out.write(buf, 0, n)
						done += n
						val now = System.nanoTime()
						if (now - last > 200_000_000L) {
							last = now
							mutableState.value = Update.Downloading(info, done, total)
						}
					}
				}
				session.fsync(out)
			}
			val intent = Intent(app, UpdateReceiver::class.java).setAction(ACTION_RESULT)
			// the installer adds its result to the intent, so it must be mutable
			val flags = PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
			session.commit(PendingIntent.getBroadcast(app, id, intent, flags).intentSender)
			committed = true
		} finally {
			c.disconnect()
			session.close()
			if (!committed)
				installer.abandonSession(id)
		}
	}
}
