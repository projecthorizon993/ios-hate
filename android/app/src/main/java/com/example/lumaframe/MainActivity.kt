package com.example.lumaframe

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.example.lumaframe.design.LumaFrameTheme
import com.example.lumaframe.design.Tokens
import com.example.lumaframe.diagnostics.ReportScreen
import com.example.lumaframe.diagnostics.ReportViewModel
import com.example.lumaframe.support.AppLog

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppLog.note("MainActivity created")
        setContent {
            LumaFrameTheme {
                AppRoot()
            }
        }
    }
}

/**
 * Step 0 has one screen, but it still needs the camera permission: manual sensor
 * ranges, RAW support and the OEM camera extensions are all meaningless without it.
 */
@Composable
private fun AppRoot() {
    val context = LocalContext.current

    var granted by remember { mutableStateOf(hasCameraPermission(context)) }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { result ->
        granted = result
        AppLog.note("camera permission result: $result")
    }
    val shareLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { /* the receiving app handles the text; nothing to read back */ }

    if (granted) {
        val viewModel: ReportViewModel = viewModel(
            factory = remember {
                ViewModelProvider.Factory.from(
                    viewModelFactory {
                        initializer { ReportViewModel(context.applicationContext) }
                    }
                )
            }
        )
        LaunchedEffect(Unit) { viewModel.run() }
        ReportScreen(viewModel) {
            viewModel.shareIntent()?.let(shareLauncher::launch)
        }
        return
    }

    if (ActivityCompat.shouldShowRequestPermissionRationale(context as android.app.Activity, Manifest.permission.CAMERA)) {
        PermissionPrompt(
            title = stringResource(R.string.permission_title),
            body = stringResource(R.string.permission_body),
            actionLabel = stringResource(R.string.permission_allow),
            onAction = { permissionLauncher.launch(Manifest.permission.CAMERA) }
        )
    } else {
        PermissionPrompt(
            title = stringResource(R.string.permission_denied_title),
            body = stringResource(R.string.permission_denied_body),
            actionLabel = stringResource(R.string.permission_settings),
            onAction = { context.openAppSettings() }
        )
    }
}

@Composable
private fun PermissionPrompt(title: String, body: String, actionLabel: String, onAction: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Tokens.SurfaceBase)
            .padding(Tokens.SpaceXL),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(text = title, style = MaterialTheme.typography.titleLarge, color = Tokens.TextPrimary)
        Text(
            text = body,
            style = MaterialTheme.typography.labelMedium,
            color = Tokens.TextSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(vertical = Tokens.SpaceL)
        )
        Button(
            onClick = onAction,
            colors = ButtonDefaults.buttonColors(
                containerColor = Tokens.AccentActive,
                contentColor = Tokens.SurfaceBase
            ),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = Tokens.MinTouch)
        ) {
            Text(actionLabel, style = MaterialTheme.typography.labelMedium)
        }
    }
}

private fun hasCameraPermission(context: android.content.Context): Boolean =
    ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

private fun android.content.Context.openAppSettings() {
    startActivity(
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", packageName, null)
        }
    )
}
