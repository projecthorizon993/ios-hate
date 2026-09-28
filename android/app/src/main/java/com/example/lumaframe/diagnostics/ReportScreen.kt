package com.example.lumaframe.diagnostics

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.example.lumaframe.R
import com.example.lumaframe.design.MonoStyle
import com.example.lumaframe.design.Tokens

/**
 * Step 0 debug screen. Run it on the Galaxy S21 Ultra, copy the text, and paste it
 * back. Every later step is gated on what it says.
 */
@Composable
fun ReportScreen(viewModel: ReportViewModel, onShare: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Tokens.SurfaceBase)
    ) {
        TopBar(viewModel, onShare)

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(Tokens.SpaceL),
            verticalArrangement = Arrangement.spacedBy(Tokens.SpaceM)
        ) {
            HeaderCard(viewModel)
            viewModel.errorMessage?.let { ErrorBanner(it) }
            viewModel.report?.sections.orEmpty().forEach { ReportSectionCard(it) }
            LogToggle(viewModel)
            SavedNote(viewModel)
        }
    }
}

@Composable
private fun TopBar(viewModel: ReportViewModel, onShare: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Tokens.SurfaceRaised)
            .padding(horizontal = Tokens.SpaceL, vertical = Tokens.SpaceS),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Tokens.SpaceS)
    ) {
        Text(
            text = stringResource(R.string.report_title),
            style = MaterialTheme.typography.titleLarge,
            color = Tokens.TextPrimary,
            modifier = Modifier
                .weight(1f)
                .semantics { heading() }
        )
        OutlinedButton(
            onClick = viewModel::copyToClipboard,
            enabled = viewModel.isShareable,
            modifier = Modifier.heightIn(min = Tokens.MinTouch)
        ) {
            Text(stringResource(R.string.report_copy), style = MaterialTheme.typography.labelMedium)
        }
        OutlinedButton(
            onClick = {
                // Save first: the share sheet sends a content URI, not raw text.
                if (viewModel.save()) onShare()
            },
            enabled = viewModel.isShareable,
            modifier = Modifier.heightIn(min = Tokens.MinTouch)
        ) {
            Text(stringResource(R.string.report_save), style = MaterialTheme.typography.labelMedium)
        }
    }
}

@Composable
private fun HeaderCard(viewModel: ReportViewModel) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(Tokens.SurfaceRaised, RoundedCornerShape(Tokens.RadiusPanel))
            .padding(Tokens.SpaceL),
        verticalArrangement = Arrangement.spacedBy(Tokens.SpaceS)
    ) {
        Text(
            text = viewModel.summary,
            style = MonoStyle,
            color = Tokens.TextPrimary
        )
        Button(
            onClick = viewModel::run,
            enabled = viewModel.canRun,
            colors = ButtonDefaults.buttonColors(
                containerColor = Tokens.AccentActive,
                contentColor = Tokens.SurfaceBase
            ),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = Tokens.MinTouch)
        ) {
            Text(
                text = if (viewModel.canRun) stringResource(R.string.report_run)
                else stringResource(R.string.report_running),
                style = MaterialTheme.typography.labelMedium
            )
        }
    }
}

@Composable
private fun ErrorBanner(message: String) {
    Text(
        text = message,
        style = MaterialTheme.typography.labelMedium,
        color = Tokens.StateError,
        modifier = Modifier
            .fillMaxWidth()
            .background(Tokens.SurfaceRaised, RoundedCornerShape(Tokens.RadiusControl))
            .padding(Tokens.SpaceM)
            .semantics { contentDescription = "Error: $message" }
    )
}

@Composable
private fun ReportSectionCard(section: ReportSection) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(Tokens.SurfaceRaised, RoundedCornerShape(Tokens.RadiusPanel))
            .padding(Tokens.SpaceL),
        verticalArrangement = Arrangement.spacedBy(Tokens.SpaceS)
    ) {
        Text(
            text = section.title,
            style = MaterialTheme.typography.titleLarge,
            color = Tokens.TextPrimary,
            modifier = Modifier.semantics { heading() }
        )
        if (section.entries.isEmpty()) {
            Text("No entries", style = MaterialTheme.typography.labelMedium, color = Tokens.TextDisabled)
        } else {
            section.entries.forEach { ReportEntryRow(it) }
        }
    }
}

/**
 * One line. The value can be long (a format list, an error string), so the row
 * stacks rather than truncating: a truncated capability value is worse than a tall row.
 */
@Composable
private fun ReportEntryRow(entry: ReportEntry) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) { contentDescription = "${entry.label}, ${entry.value}" }
    ) {
        if (entry.level.marker.isNotEmpty()) {
            Text(
                text = entry.level.marker,
                style = MonoStyle,
                color = levelColor(entry.level),
                modifier = Modifier
                    .padding(end = Tokens.SpaceS)
                    .clearAndSetSemantics { }
            )
        }
        Column(modifier = Modifier.fillMaxWidth()) {
            Text(text = entry.label, style = MonoStyle, color = Tokens.TextSecondary)
            Text(text = entry.value, style = MonoStyle, color = Tokens.TextPrimary)
        }
    }
}

@Composable
private fun LogToggle(viewModel: ReportViewModel) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = Tokens.MinTouch),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            text = stringResource(R.string.report_include_log),
            style = MaterialTheme.typography.labelMedium,
            color = Tokens.TextSecondary
        )
        Switch(
            checked = viewModel.includeLog,
            onCheckedChange = { viewModel.includeLog = it },
            enabled = viewModel.logLines.isNotEmpty()
        )
    }
}

@Composable
private fun SavedNote(viewModel: ReportViewModel) {
    val name = viewModel.savedFile?.name ?: return
    Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Text(
            text = "Saved to Android/data/com.example.lumaframe/files/reports/$name",
            style = MonoStyle,
            color = Tokens.AccentActive,
            textAlign = TextAlign.Center
        )
    }
}

private fun levelColor(level: ReportLevel): Color = when (level) {
    ReportLevel.INFO -> Tokens.TextSecondary
    ReportLevel.GOOD -> Tokens.AccentActive
    ReportLevel.NOTE -> Tokens.AccentCompare
    ReportLevel.WARN -> Tokens.StateWarn
    ReportLevel.FAIL -> Tokens.StateError
}
