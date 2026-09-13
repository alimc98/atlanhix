package com.example.nexus.vpn

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject

/**
 * v0.4.1 §11/§15 — Installed-application inventory for the app picker.
 *
 * Lists launchable packages from the REAL PackageManager (never a hardcoded
 * list), with caching so the picker does not rescan per frame. Icons are
 * delivered as the app's label + package only — the Flutter side renders a
 * generated avatar (avoids shipping bitmaps over the channel).
 */
object InstalledAppsSource {

    /** Cached inventory — invalidated when the package list fingerprint changes. */
    private var cache: JSONArray? = null
    private var fingerprint: Int = -1

    @Synchronized
    fun list(pm: PackageManager): JSONArray {
        val current = fingerprintOf(pm)
        cache?.let { if (current == fingerprint) return it }

        val flags = PackageManager.GET_META_DATA
        val apps = if (Build.VERSION.SDK_INT >= 33) {
            pm.getInstalledApplications(PackageManager.ApplicationInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.getInstalledApplications(flags)
        }

        val out = JSONArray()
        for (app in apps.sortedBy { pm.getApplicationLabel(it).toString().lowercase() }) {
            // Launchable user apps only (picker semantics); system services are noise.
            if (pm.getLaunchIntentForPackage(app.packageName) == null && !app.enabled) continue
            val isSystem = (app.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            val o = JSONObject()
                .put("package", app.packageName)
                .put("name", pm.getApplicationLabel(app).toString())
                .put("system", isSystem)
            out.put(o)
        }
        cache = out
        fingerprint = current
        return out
    }

    private fun fingerprintOf(pm: PackageManager): Int = try {
        @Suppress("DEPRECATION")
        pm.getInstalledPackages(0).sumOf { it.packageName.hashCode() }
    } catch (_: Exception) {
        System.identityHashCode(pm)
    }

    fun invalidate() {
        cache = null
        fingerprint = -1
    }
}
