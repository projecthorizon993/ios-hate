package com.example.lumaframe.design

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Design tokens. Every value here comes from `docs/DESIGN_SPEC.md`, which is the
 * contract shared with the iOS implementation. If a value is not in the spec, it does
 * not belong in this file.
 */
object Tokens {
    // Color
    val SurfaceBase = Color(0xFF0B0B0C)
    val SurfaceRaised = Color(0xFF17181A)
    val StrokeSubtle = Color(0xFF2A2C30)
    val StrokeStrong = Color(0xFF4A4D53)
    val TextPrimary = Color(0xFFF2F3F5)
    val TextSecondary = Color(0xFF9BA0A8)
    val TextDisabled = Color(0xFF5C6068)
    val AccentActive = Color(0xFFF2C14E)
    val AccentCompare = Color(0xFF6FA8FF)
    val StateWarn = Color(0xFFE8804A)
    val StateError = Color(0xFFE2564C)
    val StateLock = Color(0xFF8F7BD8)

    // Spacing
    val SpaceXXS = 2.dp
    val SpaceXS = 4.dp
    val SpaceS = 8.dp
    val SpaceM = 12.dp
    val SpaceL = 16.dp
    val SpaceXL = 24.dp
    val SpaceXXL = 32.dp

    /** Minimum interactive size (48dp on Android, 44pt on iOS). */
    val MinTouch = 48.dp

    // Radius
    val RadiusControl = 10.dp
    val RadiusPanel = 16.dp
    val RadiusPill = 999.dp
}

private val LumaColorScheme = darkColorScheme(
    primary = Tokens.AccentActive,
    onPrimary = Tokens.SurfaceBase,
    background = Tokens.SurfaceBase,
    onBackground = Tokens.TextPrimary,
    surface = Tokens.SurfaceRaised,
    onSurface = Tokens.TextPrimary,
    surfaceVariant = Tokens.SurfaceRaised,
    onSurfaceVariant = Tokens.TextSecondary,
    outline = Tokens.StrokeStrong,
    outlineVariant = Tokens.StrokeSubtle,
    error = Tokens.StateError,
    onError = Tokens.SurfaceBase
)

private val LumaTypography = Typography(
    titleLarge = TextStyle(
        fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold
    ),
    bodyMedium = TextStyle(fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.Normal),
    labelMedium = TextStyle(fontSize = 13.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium),
    labelSmall = TextStyle(fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.Medium)
)

/** Fixed token sizes from the design spec. */
object TokensSize {
    const val typeValue = 17f
    const val typeTitle = 17f
    const val typeLabel = 13f
    const val typeCaption = 11f
    const val typeMono = 13f
}

@Composable
fun LumaFrameTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = LumaColorScheme,
        typography = LumaTypography,
        content = content
    )
}

/** Monospaced style for EXIF, diagnostics and log output. */
val MonoStyle = TextStyle(
    fontFamily = FontFamily.Monospace,
    fontSize = TokensSize.typeMono.sp,
    lineHeight = 18.sp
)
