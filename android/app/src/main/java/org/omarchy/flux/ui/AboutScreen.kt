package org.omarchy.flux.ui

import android.content.Context
import android.content.Intent
import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import org.omarchy.flux.BuildConfig
import org.omarchy.flux.core.FluxCore

/** The web pages that the About page opens. */
internal object AboutLinks {
    const val RELEASE = "https://github.com/bjarneo/flux/releases/latest"
    const val WEBSITE = "https://bjarneo.github.io/flux/"
    const val SOURCE = "https://github.com/bjarneo/flux"
    const val DOCS = "https://github.com/bjarneo/flux/blob/master/docs/README.md"
    const val ISSUES = "https://github.com/bjarneo/flux/issues"
    const val X = "https://x.com/iamdothash"
    const val LICENSE = "https://github.com/bjarneo/flux/blob/master/LICENSE"
}

/**
 * The version line of this app, for example "Version 0.13.0". A debug
 * build says so, because a release APK cannot replace it.
 */
internal fun aboutVersion(version: String, debug: Boolean): String =
    if (debug) "Version $version, debug build" else "Version $version"

/** Opens [url] in the browser. Without an app for web links, Flux shows a message. */
internal fun openLink(context: Context, url: String) {
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, url.toUri())) }
        .onFailure { FluxCore.toast("No app on this phone opens web links") }
}

/**
 * The About page: the version of this app, the latest release, and the
 * pages of the project. Flux is not in the Play Store, so this page tells
 * where the updates and the project live. Each row opens the browser. The
 * page makes no network request.
 */
@Composable
fun AboutScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    CappedScrollColumn(bottom = 48.dp) {
        TiledTopBar("About Flux", onBack)
        Tile(Modifier.fillMaxWidth(), padding = PaddingValues(16.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                FluxMark(40.dp, fg = Tn.text, accent = Tn.blue)
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    T("Flux for Android", size = 18, weight = FontWeight.SemiBold)
                    T(aboutVersion(BuildConfig.VERSION_NAME, BuildConfig.DEBUG), size = 13, color = Tn.sub, family = Mono)
                }
            }
        }
        SectionLabel("Updates")
        LinkRow(Ic.download, "Latest release", "The newest APK and its changes on GitHub.") { openLink(context, AboutLinks.RELEASE) }
        // A debug build gets no update offer from fluxd, see the update section of docs/android.md.
        T(
            if (BuildConfig.DEBUG) {
                "A release APK has another signing key than this debug build. Uninstall this app before you install a release APK."
            } else {
                "When a newer version exists, the Flux window on a paired computer shows Send to phone. It sends the APK to this phone."
            },
            Modifier.padding(start = 4.dp, end = 4.dp, top = 8.dp),
            size = 13, color = Tn.sub, lineHeight = 1.35f,
        )
        SectionLabel("Project")
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            LinkRow(Ic.web, "Website", "bjarneo.github.io/flux") { openLink(context, AboutLinks.WEBSITE) }
            LinkRow(Ic.codeFile, "Source code", "github.com/bjarneo/flux") { openLink(context, AboutLinks.SOURCE) }
            LinkRow(Ic.docs, "Documentation", "Install, pair, and use Flux.") { openLink(context, AboutLinks.DOCS) }
            LinkRow(Ic.bug, "Report an issue", "Bugs and feature requests on GitHub.") { openLink(context, AboutLinks.ISSUES) }
            LinkRow(Ic.handle, "Follow on X", "@iamdothash") { openLink(context, AboutLinks.X) }
            LinkRow(Ic.license, "License", "MIT") { openLink(context, AboutLinks.LICENSE) }
        }
    }
}

/** A row that opens a web page: an icon, a label, a detail line, and the open icon. */
@Composable
private fun LinkRow(@DrawableRes icon: Int, label: String, detail: String, onClick: () -> Unit) {
    Tile(
        Modifier.fillMaxWidth().heightIn(min = 56.dp),
        onClick = onClick,
        padding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(icon, tint = Tn.blue, size = 22.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(label, size = 15, weight = FontWeight.SemiBold)
                T(detail, size = 13, color = Tn.sub, lineHeight = 1.3f)
            }
            Sym(Ic.openInNew, tint = Tn.sub, size = 20.dp)
        }
    }
}
