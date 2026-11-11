// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

// Insanotic's orange on a dark blue-grey, used where Material You colours
// are not available (before Android 12).
private val DarkColors = darkColorScheme(
	primary = Color(0xFFFF8A4C),
	onPrimary = Color(0xFF3A1500),
	primaryContainer = Color(0xFF8A3A00),
	onPrimaryContainer = Color(0xFFFFDBC8),
	background = Color(0xFF101820),
	onBackground = Color(0xFFE2E6EA),
	surface = Color(0xFF101820),
	onSurface = Color(0xFFE2E6EA),
	surfaceVariant = Color(0xFF2A3540),
	onSurfaceVariant = Color(0xFFC0C8D0),
)

private val LightColors = lightColorScheme(
	primary = Color(0xFFB24500),
	onPrimary = Color.White,
	primaryContainer = Color(0xFFFFDBC8),
	onPrimaryContainer = Color(0xFF3A1500),
	background = Color(0xFFFBFCFE),
	onBackground = Color(0xFF181C20),
	surface = Color(0xFFFBFCFE),
	onSurface = Color(0xFF181C20),
	surfaceVariant = Color(0xFFDDE3EA),
	onSurfaceVariant = Color(0xFF41484F),
)

/** Material 3: Material You colours on Android 12+, light or dark as the system is. */
@Composable
fun InsanoticTheme(content: @Composable () -> Unit) {
	val dark = isSystemInDarkTheme()
	val ctx = LocalContext.current
	val colors = when {
		Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
			if (dark) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
		dark -> DarkColors
		else -> LightColors
	}
	MaterialTheme(colorScheme = colors, content = content)
}
