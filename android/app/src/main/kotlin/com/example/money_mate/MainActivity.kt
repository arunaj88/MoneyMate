package com.example.money_mate

import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "shareFile" -> try {
                        shareFile(
                            path = call.argument<String>("path")!!,
                            mimeType = call.argument<String>("mimeType")!!,
                            subject = call.argument<String>("subject"),
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("share_failed", e.message, null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Opens the share sheet with one file.
     *
     * Some share sheets (MIUI's, for one) start the chosen app as the
     * system, and Android then drops the read permission carried by the
     * intent, so the app cannot open the file ("Unable to share" in
     * Slack). Every app that can receive the file is therefore given read
     * access explicitly before the sheet opens.
     */
    private fun shareFile(path: String, mimeType: String, subject: String?) {
        val dir = File(cacheDir, SHARE_DIR).apply { mkdirs() }
        // Statements shared earlier are only kept for a while.
        val cutoff = System.currentTimeMillis() - KEEP_MS
        dir.listFiles()?.forEach { if (it.lastModified() < cutoff) it.delete() }

        val source = File(path)
        val file = File(dir, source.name)
        source.copyTo(file, overwrite = true)
        val uri: Uri = FileProvider.getUriForFile(this, "$packageName.statement_provider", file)

        val send = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            if (!subject.isNullOrBlank()) putExtra(Intent.EXTRA_SUBJECT, subject)
            clipData = ClipData.newRawUri(source.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val receivers = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryIntentActivities(
                send,
                PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.queryIntentActivities(send, PackageManager.MATCH_DEFAULT_ONLY)
        }
        for (info in receivers) {
            grantUriPermission(
                info.activityInfo.packageName,
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
        startActivity(Intent.createChooser(send, null))
    }

    private companion object {
        const val CHANNEL = "money_mate/share"
        const val SHARE_DIR = "shared_statements"
        const val KEEP_MS = 24L * 60 * 60 * 1000
    }
}
