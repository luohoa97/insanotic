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
import androidx.core.app.NotificationCompat

/**
 * Keeps a paused game alive. A game in the background is a big process,
 * and Android (some phone makers' builds within minutes) kills it to free
 * memory: coming back then starts the game over, out of the match. While
 * the game is in the background this foreground service, with a quiet
 * "paused" notification that brings it back, tells Android the app is
 * still in use. It stops as soon as the game is in front again.
 */
class PausedService : Service() {
	override fun onBind(intent: Intent?): IBinder? = null

	override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
		val n = notification()
		try {
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
				startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
			else
				startForeground(ID, n)
		} catch (e: Exception) {
			// Android may refuse a foreground service at this moment (limits
			// on starting one from the background): then the game simply
			// has no protection, as before
			stopSelf()
		}
		return START_NOT_STICKY
	}

	private fun notification(): Notification {
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			val nm = getSystemService(NotificationManager::class.java)
			if (nm.getNotificationChannel(CHANNEL) == null)
				nm.createNotificationChannel(
					NotificationChannel(CHANNEL, getString(R.string.paused_channel), NotificationManager.IMPORTANCE_MIN),
				)
		}
		val back = PendingIntent.getActivity(
			this, 0,
			Intent(this, GameActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
			PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
		)
		return NotificationCompat.Builder(this, CHANNEL)
			.setSmallIcon(R.drawable.ic_launcher)
			.setContentTitle(getString(R.string.paused_title))
			.setContentText(getString(R.string.paused_text))
			.setContentIntent(back)
			.setOngoing(true)
			.setSilent(true)
			.setPriority(NotificationCompat.PRIORITY_MIN)
			.build()
	}

	companion object {
		private const val CHANNEL = "paused"
		private const val ID = 2

		fun start(ctx: Context) {
			val i = Intent(ctx, PausedService::class.java)
			try {
				if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i) else ctx.startService(i)
			} catch (e: Exception) {
				// see onStartCommand
			}
		}

		fun stop(ctx: Context) {
			ctx.stopService(Intent(ctx, PausedService::class.java))
		}
	}
}
