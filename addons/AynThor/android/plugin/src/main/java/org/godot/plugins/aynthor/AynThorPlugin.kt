package org.godot.plugins.aynthor

import android.app.Presentation
import android.content.Context
import android.graphics.Color
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot

class AynThorPlugin(godot: Godot) : GodotPlugin(godot) {
    private val TAG = "AynThor"
    private var presentation: SecondScreenPresentation? = null
    private var isScreenActive = false
    private var touchLogging = false
    private var displayListenerRegistered = false
    private var appBarsWatched = false
    private var lightBars = false

    private external fun nativeSetSurface(surface: Surface)
    private external fun nativeRemoveSurface()

    companion object {
        private const val TYPE_INTERNAL = 1
        private const val TYPE_EXTERNAL = 2

        init {
            System.loadLibrary("aynthor_native")
        }
    }

    override fun getPluginName() = "AynThor"

    override fun getPluginSignals(): Set<SignalInfo> {
        return setOf(
            SignalInfo("second_screen_connected"),
            SignalInfo("second_screen_disconnected"),
            SignalInfo(
                "second_screen_resized",
                Int::class.javaObjectType,
                Int::class.javaObjectType
            ),
            SignalInfo(
                "second_screen_input",
                Int::class.javaObjectType,
                Float::class.javaObjectType,
                Float::class.javaObjectType,
                Int::class.javaObjectType
            )
        )
    }

    private val displayManager: DisplayManager?
        get() = activity?.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager

    private fun findSecondDisplay(): Display? {
        val screens = displayManager?.displays?.filter(::isScreen) ?: return null
        return screens.firstOrNull { it.flags and Display.FLAG_PRESENTATION != 0 } ?: screens.firstOrNull()
    }

    private fun isScreen(display: Display): Boolean {
        val type = runCatching { Display::class.java.getMethod("getType").invoke(display) as Int }.getOrNull()
        return display.displayId != Display.DEFAULT_DISPLAY &&
            display.isValid &&
            display.flags and Display.FLAG_PRIVATE == 0 &&
            (type == null || type == TYPE_INTERNAL || type == TYPE_EXTERNAL)
    }

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {
            if (isScreenActive && presentation == null) {
                init_screen()
            }
        }

        override fun onDisplayRemoved(displayId: Int) {
            if (presentation?.display?.displayId != displayId) return
            presentation?.dismiss()
            presentation = null
            emitSignal("second_screen_disconnected")
        }

        override fun onDisplayChanged(displayId: Int) {}
    }

    @UsedByGodot
    fun has_second_screen(): Boolean {
        return findSecondDisplay() != null
    }

    @UsedByGodot
    fun set_touch_logging(enabled: Boolean) {
        touchLogging = enabled
    }

    @UsedByGodot
    fun navigation_buttons_insets(): IntArray {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return IntArray(4)
        val metrics = activity?.windowManager?.currentWindowMetrics ?: return IntArray(4)
        val insets = metrics.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.tappableElement())
        return intArrayOf(insets.left, insets.top, insets.right, insets.bottom)
    }

    @UsedByGodot
    fun system_bar_insets(): IntArray {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val metrics = activity?.windowManager?.currentWindowMetrics ?: return IntArray(4)
            val nav = metrics.windowInsets.getInsets(WindowInsets.Type.navigationBars())
            val tap = metrics.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.tappableElement())
            return intArrayOf(maxOf(nav.left, tap.left), nav.top, maxOf(nav.right, tap.right), maxOf(nav.bottom, tap.bottom))
        }
        @Suppress("DEPRECATION")
        val insets = activity?.window?.decorView?.rootWindowInsets ?: return IntArray(4)
        @Suppress("DEPRECATION")
        return intArrayOf(insets.systemWindowInsetLeft, 0, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
    }

    @UsedByGodot
    fun display_cutout_insets(): IntArray {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return IntArray(4)
        val cutout = activity?.window?.decorView?.rootWindowInsets?.displayCutout ?: return IntArray(4)
        return intArrayOf(cutout.safeInsetLeft, cutout.safeInsetTop, cutout.safeInsetRight, cutout.safeInsetBottom)
    }

    @UsedByGodot
    fun set_light_system_bars(light: Boolean) {
        lightBars = light
        activity?.runOnUiThread { applyBarAppearance() }
    }

    private fun applyBarAppearance() {
        val window = activity?.window ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val mask = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
            window.insetsController?.setSystemBarsAppearance(if (lightBars) mask else 0, mask)
            return
        }
        var flags = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            @Suppress("DEPRECATION")
            flags = flags or View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            flags = flags or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        }
        @Suppress("DEPRECATION")
        val current = window.decorView.systemUiVisibility
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = if (lightBars) current or flags else current and flags.inv()
    }

    private fun keepAppBars() {
        val decor = activity?.window?.decorView ?: return
        if (!appBarsWatched) {
            decor.viewTreeObserver.addOnWindowFocusChangeListener { hasFocus ->
                if (hasFocus) decor.post { applyAppBars() }
            }
            @Suppress("DEPRECATION")
            decor.setOnSystemUiVisibilityChangeListener { visibility ->
                if ((visibility and View.SYSTEM_UI_FLAG_FULLSCREEN) == 0) decor.post { applyAppBars() }
            }
            appBarsWatched = true
        }
        decor.post { applyAppBars() }
    }

    private fun applyAppBars() {
        val window = activity?.window ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.statusBars())
                it.show(WindowInsets.Type.navigationBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_FULLSCREEN)
        }
        @Suppress("DEPRECATION")
        window.statusBarColor = Color.TRANSPARENT
        @Suppress("DEPRECATION")
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        applyBarAppearance()
    }

    private fun applyImmersiveLogic(targetView: View) {
        val uiOptions = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_FULLSCREEN)

        targetView.systemUiVisibility = uiOptions

        targetView.setOnSystemUiVisibilityChangeListener { visibility ->
            if ((visibility and View.SYSTEM_UI_FLAG_FULLSCREEN) == 0) {
                targetView.systemUiVisibility = uiOptions
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            targetView.post {
                val exclusionWidth = 200
                val exclusionRects = listOf(
                    Rect(0, 0, exclusionWidth, targetView.height),
                    Rect(targetView.width - exclusionWidth, 0, targetView.width, targetView.height)
                )
                targetView.systemGestureExclusionRects = exclusionRects
            }
        }
    }

    @UsedByGodot
    fun init_screen() {
        isScreenActive = true
        activity?.runOnUiThread {
            keepAppBars()

            if (!displayListenerRegistered) {
                displayManager?.registerDisplayListener(
                    displayListener,
                    Handler(Looper.getMainLooper())
                )
                displayListenerRegistered = displayManager != null
            }

            val targetDisplay = findSecondDisplay()
            if (targetDisplay != null) {
                if (presentation?.isShowing != true) showPresentation(targetDisplay)
            } else {
                Log.i(TAG, "No secondary display available")
                emitSignal("second_screen_disconnected")
            }
        }
    }

    private fun showPresentation(display: Display) {
        presentation?.dismiss()
        presentation = SecondScreenPresentation(activity!!, display).apply {
            window?.setFlags(
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
            )
            show()
        }
        emitSignal("second_screen_connected")
    }

    @UsedByGodot
    fun destroy_screen() {
        isScreenActive = false
        activity?.runOnUiThread {
            if (displayListenerRegistered) {
                displayManager?.unregisterDisplayListener(displayListener)
                displayListenerRegistered = false
            }
            presentation?.dismiss()
            presentation = null
            emitSignal("second_screen_disconnected")
        }
    }

    override fun onMainPause() {
        super.onMainPause()
        activity?.runOnUiThread {
            presentation?.dismiss()
            presentation = null
        }
    }

    override fun onMainResume() {
        super.onMainResume()
        activity?.runOnUiThread {
            keepAppBars()
        }
        if (isScreenActive) {
            init_screen()
        }
    }

    private inner class SecondScreenPresentation(
        outerContext: Context,
        display: Display
    ) : Presentation(outerContext, display) {
        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)

            val surfaceView = SurfaceView(context)
            surfaceView.isClickable = true

            surfaceView.setOnTouchListener { view, event ->
                val action = event.actionMasked

                if (touchLogging) {
                    Log.d(
                        TAG,
                        "touch action=$action pointers=${event.pointerCount} " +
                                "x=${event.x} y=${event.y} view=${view.width}x${view.height}"
                    )
                }

                if (action == MotionEvent.ACTION_MOVE) {
                    for (i in 0 until event.pointerCount) {
                        emitSignal("second_screen_input", 2, event.getX(i), event.getY(i), event.getPointerId(i))
                    }
                } else {
                    val idx = event.actionIndex
                    emitSignal("second_screen_input", action, event.getX(idx), event.getY(idx), event.getPointerId(idx))
                }
                true
            }

            surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    nativeSetSurface(holder.surface)
                }

                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                    val inputWidth = if (surfaceView.width > 0) surfaceView.width else width
                    val inputHeight = if (surfaceView.height > 0) surfaceView.height else height
                    emitSignal("second_screen_resized", inputWidth, inputHeight)
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    nativeRemoveSurface()
                }
            })

            setContentView(surfaceView)
            window?.decorView?.let { applyImmersiveLogic(it) }
        }
    }

    override fun onMainDestroy() {
        destroy_screen()
        super.onMainDestroy()
    }
}
