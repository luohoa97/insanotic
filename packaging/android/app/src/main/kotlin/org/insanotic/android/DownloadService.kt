// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.text.format.Formatter
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.sample
import kotlinx.coroutines.launch

/**
 * Keeps the process alive, with a notification, while the game data
 * downloads, so leaving the app or turning the screen off does not stop it.
 * The work itself is in [SetupModel]; this only hosts it and shows progress.
 */
@OptIn(FlowPreview::class)
class DownloadService : Service() {
	private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
	private var wakeLock: PowerManager.WakeLock? = null
	private var watcher: Job? = null

	override fun onBind(intent: Intent?): IBinder? = null

	override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
		if (intent?.action == ACTION_CANCEL) {
			SetupModel.cancel(this)
			return START_NOT_STICKY
		}
		// a null intent is the system restarting us after the process died
		val music = intent?.getBooleanExtra(EXTRA_MUSIC, false) ?: SetupModel.pendingMusic(this)
		if (intent == null && !SetupModel.pending(this)) {
			stopSelf()
			return START_NOT_STICKY
		}
		startAsForeground(buildNotification(SetupModel.state.value))
		if (wakeLock == null) {
			val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
			wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "insanotic:download").apply { acquire(4 * 60 * 60 * 1000L) }
		}
		SetupModel.launch(applicationContext, music)
		if (watcher == null) watcher = scope.launch {
			SetupModel.state.sample(1000).collect { s ->
				when (s) {
					is Setup.Downloading, is Setup.Verifying, Setup.Installing ->
						getSystemService(NotificationManager::class.java).notify(ID, buildNotification(s))
					else -> {
						finish(s)
					}
				}
			}
		}
		return START_STICKY
	}

	private fun finish(s: Setup) {
		stopForeground(STOP_FOREGROUND_REMOVE)
		if (s == Setup.Done)
			getSystemService(NotificationManager::class.java).notify(ID_DONE, doneNotification())
		stopSelf()
	}

	/** Android 15 ends a data-sync service after about six hours a day; the next open of the app resumes. */
	override fun onTimeout(startId: Int, fgsType: Int) {
		SetupModel.pause()
		stopSelf()
	}

	override fun onDestroy() {
		scope.cancel()
		wakeLock?.let { if (it.isHeld) it.release() }
		super.onDestroy()
	}

	private fun startAsForeground(n: Notification) {
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
			startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
		else
			startForeground(ID, n)
	}

	private fun ensureChannel() {
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			val nm = getSystemService(NotificationManager::class.java)
			if (nm.getNotificationChannel(CHANNEL) == null)
				nm.createNotificationChannel(
					NotificationChannel(CHANNEL, getString(R.string.notification_channel), NotificationManager.IMPORTANCE_LOW),
				)
		}
	}

	private fun openApp(): PendingIntent = PendingIntent.getActivity(
		this, 0, Intent(this, SetupActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
	)

	private fun buildNotification(s: Setup): Notification {
		ensureChannel()
		val b = NotificationCompat.Builder(this, CHANNEL)
			.setSmallIcon(R.drawable.ic_launcher)
			.setContentTitle(getString(R.string.setup_download))
			.setContentIntent(openApp())
			.setOngoing(true)
			.setOnlyAlertOnce(true)
			.setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
			.addAction(
				0,
				getString(R.string.setup_cancel),
				PendingIntent.getService(
					this, 1, Intent(this, DownloadService::class.java).setAction(ACTION_CANCEL),
					PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
				),
			)
		when (s) {
			is Setup.Downloading -> {
				if (s.total > 0)
					b.setProgress(1000, (s.done * 1000 / s.total).toInt(), false)
				else
					b.setProgress(0, 0, true)
				b.setContentText(
					getString(
						R.string.setup_progress,
						Formatter.formatFileSize(this, s.done),
						Formatter.formatFileSize(this, s.total),
					),
				)
			}
			is Setup.Verifying -> b.setProgress(0, 0, true).setContentText(getString(R.string.setup_verify, s.file))
			else -> b.setProgress(0, 0, true)
		}
		return b.build()
	}

	private fun doneNotification(): Notification {
		ensureChannel()
		return NotificationCompat.Builder(this, CHANNEL)
			.setSmallIcon(R.drawable.ic_launcher)
			.setContentTitle(getString(R.string.setup_ready_title))
			.setContentText(getString(R.string.setup_ready_text))
			.setContentIntent(openApp())
			.setAutoCancel(true)
			.build()
	}

	companion object {
		const val EXTRA_MUSIC = "music"
		const val ACTION_CANCEL = "org.insanotic.android.CANCEL_DOWNLOAD"
		private const val CHANNEL = "download"
		private const val ID = 1
		private const val ID_DONE = 2
	}
}
