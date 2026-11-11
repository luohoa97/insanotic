// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.text.format.Formatter
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/**
 * Launcher activity: makes sure the Xonotic data packs and Insanotic's own
 * pk3 are installed (asking first, with progress), then starts the engine in
 * [GameActivity]. The work itself lives in [SetupModel].
 */
class SetupActivity : ComponentActivity() {
	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		enableEdgeToEdge()
		val ready = GameData.isReady(this)
		// a returning player goes straight into the game, unless there is an update
		if (ready)
			UpdateModel.check(this, force = false)
		setContent {
			InsanoticTheme {
				val update by UpdateModel.state.collectAsStateWithLifecycle()
				if (ready) {
					LaunchedEffect(update) {
						if (update == Update.UpToDate || update == Update.CheckFailed)
							startGame()
					}
					Shell { Gate(update) { startGame() } }
				} else {
					val state by SetupModel.state.collectAsStateWithLifecycle()
					LaunchedEffect(Unit) { SetupModel.prepare(this@SetupActivity) }
					LaunchedEffect(state) {
						if (state == Setup.Done)
							startGame()
					}
					SetupScreen(state, update)
				}
			}
		}
	}

	private fun startGame() {
		startActivity(Intent(this, GameActivity::class.java))
		finish()
	}
}

/** The frame every screen shares: the title, centred, at most 480 dp wide. */
@Composable
private fun Shell(content: @Composable ColumnScope.() -> Unit) {
	Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
		Column(
			modifier = Modifier
				.safeDrawingPadding()
				.verticalScroll(rememberScrollState())
				.fillMaxSize()
				.padding(24.dp),
			horizontalAlignment = Alignment.CenterHorizontally,
			verticalArrangement = Arrangement.Center,
		) {
			Column(
				modifier = Modifier.widthIn(max = 480.dp).fillMaxWidth(),
				horizontalAlignment = Alignment.CenterHorizontally,
				verticalArrangement = Arrangement.spacedBy(16.dp),
			) {
				Text(
					stringResource(R.string.setup_title),
					style = MaterialTheme.typography.displaySmall,
					color = MaterialTheme.colorScheme.primary,
				)
				content()
			}
		}
	}
}

@Composable
private fun SetupScreen(state: Setup, update: Update) {
	val ctx = LocalContext.current
	var withMusic by rememberSaveable { mutableStateOf(false) }
	val notifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
		SetupModel.start(ctx, withMusic)
	}
	Shell {
		when (state) {
			Setup.Choose -> Choose(withMusic, { withMusic = it }) {
				// the notification permission only decides whether the progress
				// notification is shown; the download starts either way
				if (Build.VERSION.SDK_INT >= 33 &&
					ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
				)
					notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
				else
					SetupModel.start(ctx, withMusic)
			}
			is Setup.Verifying -> Waiting(stringResource(R.string.setup_verify, state.file))
			Setup.Installing -> Waiting(stringResource(R.string.setup_install))
			Setup.Done -> Waiting(stringResource(R.string.setup_done))
			is Setup.Downloading -> Downloading(ctx, state)
			is Setup.OutOfSpace -> Problem(
				stringResource(
					R.string.setup_no_space,
					Formatter.formatFileSize(ctx, state.needed),
					Formatter.formatFileSize(ctx, state.available),
				),
			) { SetupModel.start(ctx, withMusic) }
			is Setup.Failed -> Problem(stringResource(R.string.setup_failed, state.message)) {
				SetupModel.start(ctx, withMusic)
			}
		}
		// updating is for a player who is not in the middle of the download
		if (state == Setup.Choose || state is Setup.Failed || state is Setup.OutOfSpace)
			UpdateSection(update, onPlay = null)
	}
}

/** Shown on start-up while the app looks for an update, and when there is one. */
@Composable
private fun Gate(update: Update, onPlay: () -> Unit) {
	when (update) {
		Update.Idle, Update.Checking, Update.UpToDate, Update.CheckFailed ->
			Waiting(stringResource(R.string.update_checking))
		else -> UpdateSection(update, onPlay)
	}
}

/**
 * The update card. With [onPlay] (start-up) the player may skip the update;
 * without it (setup screen) there is a button to check by hand.
 */
@Composable
private fun UpdateSection(update: Update, onPlay: (() -> Unit)?) {
	val ctx = LocalContext.current
	Text(
		stringResource(R.string.update_installed, UpdateModel.installedName(ctx)),
		style = MaterialTheme.typography.bodySmall,
		color = MaterialTheme.colorScheme.onSurfaceVariant,
	)
	when (update) {
		Update.Idle, Update.UpToDate, Update.CheckFailed -> {
			if (update == Update.UpToDate && onPlay == null)
				Text(stringResource(R.string.update_uptodate), style = MaterialTheme.typography.bodyMedium)
			TextButton(onClick = { UpdateModel.check(ctx, force = true) }) { Text(stringResource(R.string.update_check)) }
		}
		Update.Checking -> Waiting(stringResource(R.string.update_checking))
		is Update.Available -> {
			Text(stringResource(R.string.update_available, update.info.versionName), style = MaterialTheme.typography.titleMedium)
			Button(onClick = { UpdateModel.install(ctx, update.info) }, modifier = Modifier.fillMaxWidth()) {
				Text(stringResource(R.string.update_now))
			}
		}
		is Update.NeedsPermission -> {
			Text(stringResource(R.string.update_permission), style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center)
			Button(onClick = { ctx.startActivity(UpdateModel.permissionIntent(ctx)) }, modifier = Modifier.fillMaxWidth()) {
				Text(stringResource(R.string.update_permission_button))
			}
			OutlinedButton(onClick = { UpdateModel.install(ctx, update.info) }, modifier = Modifier.fillMaxWidth()) {
				Text(stringResource(R.string.update_now))
			}
		}
		is Update.Downloading -> {
			Text(stringResource(R.string.update_downloading), style = MaterialTheme.typography.titleMedium)
			if (update.total > 0)
				LinearProgressIndicator(progress = { update.done.toFloat() / update.total }, modifier = Modifier.fillMaxWidth())
			else
				LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
		}
		Update.Installing -> Waiting(stringResource(R.string.update_installing))
		is Update.InstallFailed -> {
			Text(
				stringResource(R.string.update_failed, update.message),
				style = MaterialTheme.typography.bodyMedium,
				color = MaterialTheme.colorScheme.error,
				textAlign = TextAlign.Center,
			)
			TextButton(onClick = { UpdateModel.check(ctx, force = true) }) { Text(stringResource(R.string.update_check)) }
		}
	}
	if (onPlay != null && update !is Update.Downloading && update != Update.Installing)
		OutlinedButton(onClick = onPlay) { Text(stringResource(R.string.update_later)) }
}

@Composable
private fun Choose(withMusic: Boolean, onMusic: (Boolean) -> Unit, onStart: () -> Unit) {
	Text(
		stringResource(R.string.setup_first_run),
		style = MaterialTheme.typography.bodyLarge,
		textAlign = TextAlign.Center,
	)
	Row(
		modifier = Modifier
			.fillMaxWidth()
			.clickable(role = Role.Checkbox) { onMusic(!withMusic) },
		verticalAlignment = Alignment.CenterVertically,
	) {
		Checkbox(checked = withMusic, onCheckedChange = null)
		Column(modifier = Modifier.padding(start = 12.dp)) {
			Text(stringResource(R.string.setup_music), style = MaterialTheme.typography.bodyLarge)
			Text(
				stringResource(R.string.setup_music_hint),
				style = MaterialTheme.typography.bodySmall,
				color = MaterialTheme.colorScheme.onSurfaceVariant,
			)
		}
	}
	Button(onClick = onStart, modifier = Modifier.fillMaxWidth()) {
		Text(stringResource(R.string.setup_start))
	}
}

@Composable
private fun Waiting(text: String) {
	Text(text, style = MaterialTheme.typography.bodyLarge)
	LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
}

@Composable
private fun Downloading(ctx: Context, s: Setup.Downloading) {
	Text(stringResource(R.string.setup_download), style = MaterialTheme.typography.titleMedium)
	if (s.total > 0)
		LinearProgressIndicator(progress = { s.done.toFloat() / s.total }, modifier = Modifier.fillMaxWidth())
	else
		LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
	Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
		Text(
			stringResource(
				R.string.setup_progress,
				Formatter.formatFileSize(ctx, s.done),
				Formatter.formatFileSize(ctx, s.total),
			),
			style = MaterialTheme.typography.bodyMedium,
		)
		if (s.bytesPerSecond > 0)
			Text(
				stringResource(R.string.setup_speed, Formatter.formatFileSize(ctx, s.bytesPerSecond)),
				style = MaterialTheme.typography.bodyMedium,
			)
	}
	if (s.count > 0)
		Text(
			stringResource(R.string.setup_file, s.file, s.index, s.count),
			style = MaterialTheme.typography.bodySmall,
			color = MaterialTheme.colorScheme.onSurfaceVariant,
		)
	Spacer(Modifier.height(8.dp))
	Text(
		stringResource(R.string.setup_background),
		style = MaterialTheme.typography.bodySmall,
		color = MaterialTheme.colorScheme.onSurfaceVariant,
		textAlign = TextAlign.Center,
	)
	OutlinedButton(onClick = { SetupModel.cancel(ctx) }) { Text(stringResource(R.string.setup_cancel)) }
}

@Composable
private fun Problem(message: String, onRetry: () -> Unit) {
	Text(message, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center)
	Button(onClick = onRetry) { Text(stringResource(R.string.setup_retry)) }
}
