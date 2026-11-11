// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build

/** Receives the system installer's verdict on an update session. */
class UpdateReceiver : BroadcastReceiver() {
	override fun onReceive(context: Context, intent: Intent) {
		when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
			PackageInstaller.STATUS_PENDING_USER_ACTION -> {
				// Android wants the player to confirm; the app is in the foreground here
				val confirm = if (Build.VERSION.SDK_INT >= 33)
					intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
				else
					@Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
				if (confirm != null)
					context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
			}
			PackageInstaller.STATUS_SUCCESS -> Unit // the app is replaced and restarted by the system
			PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> UpdateModel.failed(
				context.getString(R.string.update_wrong_key),
			)
			else -> UpdateModel.failed(
				intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: context.getString(R.string.update_failed_generic),
			)
		}
	}
}
