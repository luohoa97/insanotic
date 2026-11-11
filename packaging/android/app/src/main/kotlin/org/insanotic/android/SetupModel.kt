// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import android.content.Context
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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

	data class OutOfSpace(val needed: Long, val available: Long) : Setup

	data class Failed(val message: String) : Setup

	data object Done : Setup
}

/**
 * The setup work and its state, owned by the process rather than by an
 * activity so that rotating the screen does not restart the download.
 */
object SetupModel {
	private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
	private var job: Job? = null
	private val mutableState = MutableStateFlow<Setup>(Setup.Choose)
	val state: StateFlow<Setup> = mutableState

	val running: Boolean get() = job?.isActive == true

	/** Installs Insanotic's pk3 when the packs are already there; otherwise waits for [start]. */
	fun prepare(ctx: Context) {
		if (running || mutableState.value == Setup.Done)
			return
		if (GameData.packsInstalled(ctx))
			launch(ctx.applicationContext, withMusic = false)
	}

	fun start(ctx: Context, withMusic: Boolean) {
		if (!running)
			launch(ctx.applicationContext, withMusic)
	}

	fun cancel() {
		job?.cancel()
	}

	private fun launch(ctx: Context, withMusic: Boolean) {
		job = scope.launch {
			try {
				if (!GameData.packsInstalled(ctx)) {
					val listener = object : DownloadListener {
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
					mutableState.value = Setup.Downloading(0, 0, "", 0, 0, 0)
					PackDownloader(GameData.dataDir(ctx), withMusic, listener).run()
					GameData.markPacksInstalled(ctx, withMusic)
				}
				if (!GameData.ownPk3Current(ctx)) {
					mutableState.value = Setup.Installing
					withContext(Dispatchers.IO) { GameData.installOwnPk3(ctx) }
				}
				mutableState.value = Setup.Done
			} catch (e: CancellationException) {
				mutableState.value = Setup.Choose
				throw e
			} catch (e: NoSpace) {
				mutableState.value = Setup.OutOfSpace(e.needed, e.available)
			} catch (e: Exception) {
				mutableState.value = Setup.Failed(e.message ?: e.toString())
			}
		}
	}
}
