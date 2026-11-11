// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.text.format.Formatter
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
		if (GameData.isReady(this)) {
			startGame()
			return
		}
		setContent {
			InsanoticTheme {
				val state by SetupModel.state.collectAsStateWithLifecycle()
				LaunchedEffect(Unit) { SetupModel.prepare(this@SetupActivity) }
				LaunchedEffect(state) {
					if (state == Setup.Done)
						startGame()
				}
				SetupScreen(state)
			}
		}
	}

	private fun startGame() {
		startActivity(Intent(this, GameActivity::class.java))
		finish()
	}
}

@Composable
private fun SetupScreen(state: Setup) {
	val ctx = LocalContext.current
	var withMusic by rememberSaveable { mutableStateOf(false) }
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
				when (state) {
					Setup.Choose -> Choose(withMusic, { withMusic = it }) { SetupModel.start(ctx, withMusic) }
					Setup.Installing -> Waiting(R.string.setup_install)
					Setup.Done -> Waiting(R.string.setup_done)
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
			}
		}
	}
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
private fun Waiting(text: Int) {
	Text(stringResource(text), style = MaterialTheme.typography.bodyLarge)
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
	OutlinedButton(onClick = { SetupModel.cancel() }) { Text(stringResource(R.string.setup_cancel)) }
}

@Composable
private fun Problem(message: String, onRetry: () -> Unit) {
	Text(message, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center)
	Button(onClick = onRetry) { Text(stringResource(R.string.setup_retry)) }
}
