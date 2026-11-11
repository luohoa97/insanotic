// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** What the setup screen shows. */
sealed interface Setup {
	/** waiting for the player to start the download */
	data object Choose : Setup

	data object Installing : Setup

	data class Downloading(
		val done: Long,
		val total: Long,
		val file: String,
		val index: Int,
		val count: Int,
		val bytesPerSecond: Long,
	) : Setup

	/** checking a finished pack against its checksum */
	data class Verifying(val file: String) : Setup

	data class OutOfSpace(val needed: Long, val available: Long) : Setup

	data class Failed(val message: String) : Setup

	data object Done : Setup
}

/**
 * The setup work and its state. The process owns it, not an activity, so
 * recreating the activity does not restart the download, and
 * [DownloadService] keeps the process in the foreground while it runs.
 *
 * "Download wanted" is also saved in the preferences: if the process is
 * killed mid-download, the next start of the service or the activity picks
 * the download up again from the bytes already on disk.
 */
object SetupModel {
	private const val TAG = "InsanoticSetup"
	private const val PREFS = "setup"
	private const val PENDING = "pending"
	private const val MUSIC = "music"
	private const val UPGRADE = "upgrade"
	private const val DECLINED = "upgrade_declined"

	private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
	private var job: Job? = null
	private val mutableState = MutableStateFlow<Setup>(Setup.Choose)
	val state: StateFlow<Setup> = mutableState

	val running: Boolean get() = job?.isActive == true

	/** Bytes of the repacked packs offered to a player who has the official ones; null: no offer. */
	val upgradeOffer = MutableStateFlow<Long?>(null)

	/** the offer has been looked for (it needs the network, so it takes a moment) */
	val upgradeChecked = MutableStateFlow(false)

	/** the running or pending work replaces the official packs */
	val upgrading = MutableStateFlow(false)

	/**
	 * Looks whether to offer the repacked packs: the official ones are
	 * installed, the GPU takes ASTC, the release is reachable, and the player
	 * has not said no. Also picks an interrupted upgrade up again.
	 */
	fun checkUpgrade(ctx: Context) {
		val app = ctx.applicationContext
		if (prefs(app).getBoolean(UPGRADE, false) && pending(app)) {
			upgrading.value = true
			startService(app, pendingMusic(app))
			upgradeChecked.value = true
			return
		}
		scope.launch {
			try {
				if (!GameData.packsInstalled(app) || GameData.packsRepacked(app) || prefs(app).getBoolean(DECLINED, false))
					return@launch
				val bytes = withTimeoutOrNull(8000) {
					PackDownloader(GameData.dataDir(app), GameData.musicInstalled(app), ProgressListener(), upgrade = true).upgradeBytes()
				}
				upgradeOffer.value = bytes
			} catch (e: Exception) {
				Log.w(TAG, "no upgrade offer", e)
			} finally {
				upgradeChecked.value = true
			}
		}
	}

	/** The player asked for the offer again (the app icon's shortcut). */
	fun reofferUpgrade(ctx: Context) {
		prefs(ctx).edit().putBoolean(DECLINED, false).apply()
	}

	/** The player does not want the repacked packs (asked once). */
	fun declineUpgrade(ctx: Context) {
		prefs(ctx).edit().putBoolean(DECLINED, true).apply()
		upgradeOffer.value = null
	}

	/** The player accepted: download the repacked packs, then swap them in. */
	fun startUpgrade(ctx: Context) {
		if (running)
			return
		val withMusic = GameData.musicInstalled(ctx)
		prefs(ctx).edit().putBoolean(PENDING, true).putBoolean(MUSIC, withMusic).putBoolean(UPGRADE, true).apply()
		upgrading.value = true
		upgradeOffer.value = null
		startService(ctx.applicationContext, withMusic)
	}

	private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

	/** A download the player asked for that has not finished or been cancelled. */
	fun pending(ctx: Context): Boolean = prefs(ctx).getBoolean(PENDING, false)

	fun pendingMusic(ctx: Context): Boolean = prefs(ctx).getBoolean(MUSIC, false)

	/**
	 * Called when the setup screen opens: installs Insanotic's pk3 when the
	 * packs are already there, and resumes a download that was interrupted.
	 */
	fun prepare(ctx: Context) {
		if (running || mutableState.value == Setup.Done)
			return
		when {
			GameData.packsInstalled(ctx) -> launch(ctx.applicationContext, withMusic = false)
			pending(ctx) -> startService(ctx.applicationContext, pendingMusic(ctx))
		}
	}

	/** The player pressed Download (or Retry). */
	fun start(ctx: Context, withMusic: Boolean) {
		if (running)
			return
		prefs(ctx).edit().putBoolean(PENDING, true).putBoolean(MUSIC, withMusic).apply()
		startService(ctx.applicationContext, withMusic)
	}

	/** The player cancelled: the bytes stay on disk, but nothing resumes by itself. */
	fun cancel(ctx: Context) {
		prefs(ctx).edit().putBoolean(PENDING, false).putBoolean(UPGRADE, false).apply()
		upgrading.value = false
		pause()
	}

	/** Stops the work but keeps "download wanted", e.g. when the system ends the service. */
	fun pause() {
		job?.cancel()
	}

	private fun startService(ctx: Context, withMusic: Boolean) {
		val intent = Intent(ctx, DownloadService::class.java).putExtra(DownloadService.EXTRA_MUSIC, withMusic)
		try {
			ContextCompat.startForegroundService(ctx, intent)
		} catch (e: RuntimeException) {
			// not allowed to start a foreground service right now (app in the
			// background after a restart): download without one, the next
			// time the app is opened it will be able to
			Log.w(TAG, "cannot start the download service", e)
			launch(ctx, withMusic)
		}
	}

	/** Runs the setup work unless it is already running. Called by the service. */
	fun launch(ctx: Context, withMusic: Boolean) {
		if (running)
			return
		val upgrade = prefs(ctx).getBoolean(UPGRADE, false)
		upgrading.value = upgrade
		// set before the job starts, so a watcher never sees a stale state
		if (upgrade || !GameData.packsInstalled(ctx))
			mutableState.value = Setup.Downloading(0, 0, "", 0, 0, 0)
		job = scope.launch {
			try {
				if (upgrade) {
					PackDownloader(GameData.dataDir(ctx), withMusic, ProgressListener(), upgrade = true).run()
					GameData.markPacksRepacked(ctx)
					prefs(ctx).edit().putBoolean(UPGRADE, false).apply()
				} else if (!GameData.packsInstalled(ctx)) {
					val downloader = PackDownloader(GameData.dataDir(ctx), withMusic, ProgressListener())
					downloader.run()
					GameData.markPacksInstalled(ctx, withMusic)
					if (downloader.usedRepacked)
						GameData.markPacksRepacked(ctx)
				}
				if (!GameData.ownPk3Current(ctx)) {
					mutableState.value = Setup.Installing
					withContext(Dispatchers.IO) { GameData.installOwnPk3(ctx) }
				}
				prefs(ctx).edit().putBoolean(PENDING, false).apply()
				mutableState.value = Setup.Done
			} catch (e: CancellationException) {
				mutableState.value = Setup.Choose
				throw e
			} catch (e: NoSpace) {
				prefs(ctx).edit().putBoolean(PENDING, false).putBoolean(UPGRADE, false).apply()
				mutableState.value = Setup.OutOfSpace(e.needed, e.available)
			} catch (e: Exception) {
				Log.w(TAG, "setup failed", e)
				prefs(ctx).edit().putBoolean(PENDING, false).putBoolean(UPGRADE, false).apply()
				mutableState.value = Setup.Failed(e.message ?: e.toString())
			}
		}
	}

	private class ProgressListener : DownloadListener {
		private var file = ""
		private var index = 0
		private var count = 0
		private var lastTime = System.nanoTime()
		private var lastDone = 0L
		private var speed = 0L

		override fun onFile(name: String, index: Int, count: Int) {
			file = name
			this.index = index
			this.count = count
		}

		override fun onVerify(name: String) {
			mutableState.value = Setup.Verifying(name)
		}

		override fun onProgress(done: Long, total: Long) {
			val now = System.nanoTime()
			if (now - lastTime >= 1_000_000_000L) {
				val rate = (done - lastDone) * 1_000_000_000L / (now - lastTime)
				speed = if (speed == 0L) rate else (speed * 3 + rate) / 4
				lastTime = now
				lastDone = done
			}
			mutableState.value = Setup.Downloading(done, total, file, index, count, speed)
		}
	}
}
