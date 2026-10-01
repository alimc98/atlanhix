package com.atlanhix.app.vpn

import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File

/**
 * v0.6.0 §in-app-update — the user asked for the WHOLE update to live inside
 * the app: "وقتی دانلود رو میزنیم همونجا دانلود کنه توی خود برنامه و بعد
 * اتوماتیک نصبش کنه — اصلا فازِ رفتن توی مرورگر و دانلود دستی گیت‌هاب نباشه."
 *
 * Channel: `dev.atlanhix/updater`
 *   download  {url, version} → {ok, downloadId?}
 *   status    {downloadId}   → {ok, status: pending|running|done|failed, progress?}
 *   install   {version}      → {ok}  (launches ACTION_INSTALL_PACKAGE)
 *
 * Flow: [download] hands the APK URL to Android's own DownloadManager (it
 * streams in the background, survives app switches, and notifies us via a
 * broadcast). When the download completes, [install] exposes the file
 * through a FileProvider and fires ACTION_INSTALL_PACKAGE — Android then
 * shows its standard one-tap "install this update" consent (there is no
 * silent-install API for sideloaded APKs; this is the closest honest
 * automatic path). The old flow opened a BROWSER on the GitHub release page
 * — exactly the manual step the user wanted gone.
 */
class AtlanhixUpdaterChannel(private val activity: Activity) {

    companion object {
        const val CHANNEL = "dev.atlanhix/updater"
        private const val UPDATES_DIR = "updates"
        private const val AUTHORITY = "com.atlanhix.app.fileprovider"
    }

    fun handle(method: String, arg: JSONObject?): JSONObject = when (method) {
        "download" -> download(arg ?: JSONObject())
        "status" -> status(arg ?: JSONObject())
        "install" -> install(arg ?: JSONObject())
        else -> JSONObject().put("error", "unknown method: $method")
    }

    private fun apkFile(version: String): File {
        val dir = File(activity.filesDir, UPDATES_DIR).apply { mkdirs() }
        // Keep the file name boring and unique per version — the installer
        // only cares about content; human readability is a bonus.
        val safe = version.replace(Regex("[^A-Za-z0-9._-]"), "_")
        return File(dir, "atlanhix-$safe.apk")
    }

    private fun download(arg: JSONObject): JSONObject {
        val url = arg.optString("url").orEmpty()
        if (url.isEmpty()) return JSONObject().put("ok", false).put("error", "no url")
        val version = arg.optString("version", "update")
        val dest = apkFile(version)
        // Fresh file — a stale previous download must never be installed.
        dest.delete()
        return try {
            val req = DownloadManager.Request(Uri.parse(url))
                .setTitle("Atlanhix $version")
                .setDescription("Downloading the Atlanhix update")
                .setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                .setDestinationUri(Uri.fromFile(dest))
                .setAllowedOverMetered(true)
                .setAllowedOverRoaming(true)
            val id = downloadManager().enqueue(req)
            JSONObject().put("ok", true).put("downloadId", id).put("path", dest.absolutePath)
        } catch (e: Exception) {
            JSONObject().put("ok", false).put("error", "${e.message}")
        }
    }

    private fun status(arg: JSONObject): JSONObject {
        val id = arg.optLong("downloadId", -1)
        if (id < 0) return JSONObject().put("ok", false).put("error", "no downloadId")
        return try {
            val q = DownloadManager.Query().setFilterById(id)
            val c = downloadManager().query(q)
            c.use { cursor ->
                if (!cursor.moveToFirst()) {
                    return JSONObject().put("ok", true).put("status", "gone")
                }
                val state = cursor.getInt(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                val bytes = cursor.getLong(cursor.getColumnIndexOrThrow(
                    DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                val total = cursor.getLong(cursor.getColumnIndexOrThrow(
                    DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                val reason = cursor.getInt(cursor.getColumnIndexOrThrow(
                    DownloadManager.COLUMN_REASON))
                val st = when (state) {
                    DownloadManager.STATUS_SUCCESSFUL -> "done"
                    DownloadManager.STATUS_FAILED -> "failed"
                    DownloadManager.STATUS_PAUSED -> "paused"
                    DownloadManager.STATUS_PENDING -> "pending"
                    else -> "running"
                }
                JSONObject()
                    .put("ok", true)
                    .put("status", st)
                    .put("bytes", bytes)
                    .put("total", if (total > 0) total else JSONObject.NULL)
                    .put("progress", if (total > 0) (bytes * 100 / total).toInt() else JSONObject.NULL)
                    .put("reason", if (st == "failed") reason else JSONObject.NULL)
            }
        } catch (e: Exception) {
            JSONObject().put("ok", false).put("error", "${e.message}")
        }
    }

    private fun install(arg: JSONObject): JSONObject {
        val version = arg.optString("version", "update")
        val file = apkFile(version)
        if (!file.exists() || file.length() == 0L) {
            return JSONObject().put("ok", false).put("error", "apk not downloaded")
        }
        return try {
            val uri: Uri = FileProvider.getUriForFile(activity, AUTHORITY, file)
            val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            JSONObject().put("ok", true)
        } catch (e: Exception) {
            JSONObject().put("ok", false).put("error", "${e.message}")
        }
    }

    private fun downloadManager(): DownloadManager =
        activity.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
}
