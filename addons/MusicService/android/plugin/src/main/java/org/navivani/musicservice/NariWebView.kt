package org.navivani.musicservice

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Presentation
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebStorage
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

object NariWebView {
    private const val RESHOW_DELAY = 400L
    private const val PROFILE_PREFIX = "nari_incognito_"
    private const val TAG = "NariWebView"
    private val views = ConcurrentHashMap<Int, Entry>()
    private val ids = AtomicInteger()
    private val handler = Handler(Looper.getMainLooper())

    private class Entry(val id: Int) {
        var view: WebView? = null
        var host: FrameLayout? = null
        var presentation: Presentation? = null
        var visible = true
        var zoom = 1.0
        var incognito = false
        val scripts = mutableListOf<String>()
        val events = JSONArray()

        fun push(event: String, text: String?, id: Int = 0) {
            synchronized(events) { events.put(JSONObject().put("event", event).put("text", text ?: "").put("id", id)) }
        }
    }

    fun handle(activity: Activity?, request: String): String {
        val message = JSONObject(request)
        message.optJSONObject("create")?.let { options ->
            activity ?: return "{}"
            val entry = Entry(ids.incrementAndGet())
            views[entry.id] = entry
            ui(activity) { build(activity, entry, options) }
            return JSONObject().put("handle", entry.id).toString()
        }
        val entry = views[message.optInt("handle")] ?: return "null"
        message.optString("cookies").takeIf { it.isNotEmpty() }?.let { url ->
            activity ?: return "\"\""
            return JSONObject.quote(onUi(activity) { cookies(entry).getCookie(url) } ?: "")
        }
        if (message.optBoolean("destroy")) {
            views.remove(entry.id)
            activity?.let { ui(it) { release(entry) } }
            return "null"
        }
        if (message.keys().asSequence().any { it != "poll" && it != "handle" }) activity?.let { ui(it) { apply(entry, message) } }
        if (!message.optBoolean("poll")) return "null"
        return synchronized(entry.events) {
            val reply = entry.events.toString()
            while (entry.events.length() > 0) entry.events.remove(0)
            reply
        }
    }

    fun pause() {
        handler.removeCallbacksAndMessages(null)
        views.values.forEach { it.presentation?.dismiss() }
    }

    fun resume() {
        handler.postDelayed({ views.values.forEach { entry -> entry.presentation?.takeIf { entry.visible }?.show() } }, RESHOW_DELAY)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun build(activity: Activity, entry: Entry, options: JSONObject) {
        val view = WebView(activity)
        entry.incognito = options.optBoolean("incognito") && WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
        if (entry.incognito) {
            val store = ProfileStore.getInstance()
            store.allProfileNames.filter { it.startsWith(PROFILE_PREFIX) }.forEach(::forget)
            store.getOrCreateProfile(profile(entry))
            WebViewCompat.setProfile(view, profile(entry))
        }
        val desktop = options.optBoolean("desktop")
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            useWideViewPort = desktop
            loadWithOverviewMode = desktop
            builtInZoomControls = true
            displayZoomControls = false
            mediaPlaybackRequiresUserGesture = !options.optBoolean("autoplay")
            userAgentString = options.optString("user_agent").ifEmpty { if (desktop) desktopAgent(userAgentString) else userAgentString }
        }
        cookies(entry).setAcceptThirdPartyCookies(view, true)
        if (options.optBoolean("transparent")) view.setBackgroundColor(Color.TRANSPARENT)
        if (options.optBoolean("devtools")) WebView.setWebContentsDebuggingEnabled(true)
        val scripts = options.optJSONArray("scripts") ?: JSONArray()
        for (index in 0 until scripts.length()) {
            val script = scripts.optString(index)
            if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                WebViewCompat.addDocumentStartJavaScript(view, script, setOf("*"))
            } else {
                entry.scripts.add(script)
            }
        }
        view.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                entry.scripts.forEach { view.evaluateJavascript(it, null) }
                entry.push("started", url)
            }
            override fun onPageFinished(view: WebView, url: String?) = entry.push("finished", url)
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = request.url.scheme?.startsWith("http") != true
        }
        view.webChromeClient = object : WebChromeClient() {
            override fun onReceivedTitle(view: WebView, title: String?) = entry.push("title", title)
        }
        view.addJavascriptInterface(object {
            @JavascriptInterface
            fun postMessage(text: String) = entry.push("message", text)
        }, "ipc")
        val host = FrameLayout(activity)
        host.addView(view, FrameLayout.LayoutParams(1, 1, Gravity.CENTER))
        entry.view = view
        entry.host = host
        val display = (activity.getSystemService(DisplayManager::class.java))
            ?.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
            ?.getOrNull(options.optInt("screen") - 1)
        if (display == null) {
            activity.findViewById<ViewGroup>(android.R.id.content).addView(host, FrameLayout.LayoutParams(1, 1))
        } else {
            entry.presentation = Presentation(activity, display, android.R.style.Theme_Translucent_NoTitleBar).apply {
                setContentView(host)
                window?.apply {
                    setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
                    clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
                    addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL)
                    setGravity(Gravity.TOP or Gravity.START)
                }
            }
        }
        apply(entry, options)
    }

    private fun apply(entry: Entry, message: JSONObject) {
        val view = entry.view ?: return
        val host = entry.host ?: return
        message.optJSONArray("bounds")?.let { bounds ->
            val (x, y) = bounds.getDouble(0).toInt() to bounds.getDouble(1).toInt()
            val (width, height) = bounds.getDouble(2).toInt().coerceAtLeast(1) to bounds.getDouble(3).toInt().coerceAtLeast(1)
            val window = entry.presentation?.window
            if (window != null) {
                window.attributes = window.attributes.apply {
                    this.x = x
                    this.y = y
                    this.width = width
                    this.height = height
                }
            } else {
                host.layoutParams = (host.layoutParams as FrameLayout.LayoutParams).apply {
                    leftMargin = x
                    topMargin = y
                    this.width = width
                    this.height = height
                }
            }
        }
        message.optJSONArray("view")?.let { size ->
            view.layoutParams = (view.layoutParams as FrameLayout.LayoutParams).apply {
                width = size.getDouble(0).toInt().coerceAtLeast(1)
                height = size.getDouble(1).toInt().coerceAtLeast(1)
            }
        }
        if (message.has("rotation")) view.rotation = message.optDouble("rotation").toFloat()
        if (message.has("visible")) {
            entry.visible = message.optBoolean("visible")
            host.visibility = if (entry.visible) View.VISIBLE else View.GONE
            entry.presentation?.let { if (entry.visible) it.show() else it.hide() }
        }
        message.optString("url").takeIf { it.isNotEmpty() }?.let(view::loadUrl)
        message.optString("html").takeIf { it.isNotEmpty() }?.let { view.loadDataWithBaseURL(null, it, "text/html", "utf-8", null) }
        message.optString("eval").takeIf { it.isNotEmpty() }?.let { script ->
            val id = message.optInt("id")
            view.evaluateJavascript(script) { entry.push("result", it, id) }
        }
        if (message.optBoolean("clear")) {
            cookies(entry).removeAllCookies(null)
            storage(entry).deleteAllData()
            view.clearCache(true)
        }
        if (message.has("zoom")) {
            val zoom = message.optDouble("zoom", 1.0)
            view.zoomBy((zoom / entry.zoom).toFloat())
            entry.zoom = zoom
        }
        if (message.optBoolean("reload")) view.reload()
        if (message.optBoolean("back") && view.canGoBack()) view.goBack()
        if (message.optBoolean("forward") && view.canGoForward()) view.goForward()
        if (message.has("focus")) if (message.optBoolean("focus")) view.requestFocus() else view.clearFocus()
    }

    private fun release(entry: Entry) {
        entry.presentation?.dismiss()
        entry.host?.let { (it.parent as? ViewGroup)?.removeView(it) }
        if (entry.incognito) {
            cookies(entry).removeAllCookies(null)
            storage(entry).deleteAllData()
        }
        entry.view?.destroy()
        entry.view = null
        if (entry.incognito) handler.postDelayed({ forget(profile(entry)) }, RESHOW_DELAY)
    }

    private fun forget(name: String) {
        runCatching { ProfileStore.getInstance().deleteProfile(name) }
    }

    private fun desktopAgent(default: String): String {
        val chrome = Regex("Chrome/[\\d.]+").find(default)?.value ?: "Chrome"
        return "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) $chrome Safari/537.36"
    }

    private fun profile(entry: Entry) = "$PROFILE_PREFIX${entry.id}"

    private fun cookies(entry: Entry): CookieManager =
        if (entry.incognito) ProfileStore.getInstance().getOrCreateProfile(profile(entry)).cookieManager else CookieManager.getInstance()

    private fun storage(entry: Entry): WebStorage =
        if (entry.incognito) ProfileStore.getInstance().getOrCreateProfile(profile(entry)).webStorage else WebStorage.getInstance()

    private fun ui(activity: Activity, block: () -> Unit) {
        activity.runOnUiThread { runCatching(block).onFailure { Log.w(TAG, "WebView call failed", it) } }
    }

    private fun <T> onUi(activity: Activity, block: () -> T): T? {
        val task = FutureTask(block)
        activity.runOnUiThread(task)
        return runCatching { task.get(2, TimeUnit.SECONDS) }.getOrNull()
    }
}
