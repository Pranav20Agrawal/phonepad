package com.pranav.phonepad_app

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.app.*
import android.content.*
import android.graphics.*
import android.graphics.drawable.*
import android.os.*
import android.util.DisplayMetrics
import android.view.*
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.*
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import kotlin.math.*

// ── Top-level helpers (Kotlin forbids class/enum inside an inner class) ──────

private class TpEma(private val alpha: Float = 0.18f) {
    private var prev: Float? = null
    fun smooth(v: Float): Float {
        prev = alpha * v + (1f - alpha) * (prev ?: v)
        return prev!!
    }
    fun reset() { prev = null }
}

private data class TpPtr(
    var x: Float, var y: Float,
    val downX: Float, val downY: Float,
    val downTime: Long
)

private enum class TpAxis { NONE, VERT, HORIZ }

// ─────────────────────────────────────────────────────────────────────────────
// OverlayService  —  PhonePad floating touchpad
//
// COLLAPSED  →  60 dp circular gradient FAB, draggable.  Tap → expand.
// EXPANDED   →  full panel: title-bar drag, sliders, touchpad, L/M/R buttons,
//               "▼ Collapse" button, resize handle.
//
// Open  animation : scale 0.40 → 1.0, alpha 0 → 1, OvershootInterpolator, 380 ms
// Close animation : scale 1.0  → 0.35, alpha 1 → 0, DecelerateInterpolator, 280 ms
// WindowManager params.width/height animated every frame so shadow/clip follow.
// ─────────────────────────────────────────────────────────────────────────────

class OverlayService : Service() {

    // ── Binder ────────────────────────────────────────────────────────
    inner class LocalBinder : Binder() {
        fun getService(): OverlayService = this@OverlayService
    }
    private val binder = LocalBinder()
    override fun onBind(intent: Intent?): IBinder = binder

    // ── Event callback → Flutter ──────────────────────────────────────
    private var eventCallback: ((String) -> Unit)? = null
    fun setEventCallback(cb: (String) -> Unit) { eventCallback = cb }
    private fun sendEvent(type: String, extra: Map<String, Any> = emptyMap()) {
        try {
            val obj = JSONObject().apply {
                put("type", type)
                extra.forEach { (k, v) -> put(k, v) }
            }
            eventCallback?.invoke(obj.toString())
        } catch (_: Exception) {}
    }

    // ── Config ────────────────────────────────────────────────────────
    private var sensitivity   = 2.5f
    private var scrollSpeed   = 5.0f
    private var naturalScroll = false

    // ── WindowManager ─────────────────────────────────────────────────
    private lateinit var wm: WindowManager
    private lateinit var params: WindowManager.LayoutParams
    private lateinit var containerRoot: FrameLayout

    // ── Sizing ────────────────────────────────────────────────────────
    private var screenW   = 1080
    private var screenH   = 1920
    private var fabSizePx = 0
    private var panelW    = 0
    private var panelH    = 0

    // ── State ─────────────────────────────────────────────────────────
    private var expanded       = false
    private var animating      = false
    var         touchpadLocked = false          // read by TouchpadView
    private var activeAnimator: ValueAnimator? = null

    private lateinit var fabView:   View
    private lateinit var panelView: View

    private val mainHandler = Handler(Looper.getMainLooper())

    // ═════════════════════════════════════════════════════════════════
    // Lifecycle
    // ═════════════════════════════════════════════════════════════════

    override fun onCreate() {
        super.onCreate()
        wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val dm = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getMetrics(dm)
        screenW   = dm.widthPixels
        screenH   = dm.heightPixels
        fabSizePx = dp(60)
        panelW    = (screenW * 0.54f).toInt().coerceIn(dp(270), dp(400))
        panelH    = (screenH * 0.40f).toInt().coerceIn(dp(300), dp(500))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.let {
            sensitivity   = it.getFloatExtra("sensitivity",   2.5f)
            scrollSpeed   = it.getFloatExtra("scrollSpeed",   5.0f)
            naturalScroll = it.getBooleanExtra("naturalScroll", false)
        }
        startForegroundNotification()
        buildAndAddWindow()
        showFabInstant()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        activeAnimator?.cancel()
        try { wm.removeView(containerRoot) } catch (_: Exception) {}
        super.onDestroy()
    }

    // ── Foreground notification ───────────────────────────────────────
    private fun startForegroundNotification() {
        val channelId = "phonepad_overlay"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(channelId, "PhonePad Overlay",
                NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) }
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(ch)
        }
        val n = NotificationCompat.Builder(this, channelId)
            .setContentTitle("PhonePad overlay active")
            .setContentText("Tap the floating button to open")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        startForeground(42, n)
    }

    // ═════════════════════════════════════════════════════════════════
    // Window construction
    // ═════════════════════════════════════════════════════════════════

    @SuppressLint("ClickableViewAccessibility")
    private fun buildAndAddWindow() {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE

        params = WindowManager.LayoutParams(
            fabSizePx, fabSizePx, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = screenW - fabSizePx - dp(16)
            y = (screenH * 0.30f).toInt()
        }

        containerRoot = FrameLayout(this)
        fabView       = buildFab()
        panelView     = buildPanel()

        panelView.alpha      = 0f
        panelView.scaleX     = 0.4f
        panelView.scaleY     = 0.4f
        panelView.visibility = View.INVISIBLE

        containerRoot.addView(fabView,
            FrameLayout.LayoutParams(fabSizePx, fabSizePx, Gravity.CENTER))
        containerRoot.addView(panelView,
            FrameLayout.LayoutParams(panelW, panelH, Gravity.CENTER))

        wm.addView(containerRoot, params)
    }

    // ── FAB ───────────────────────────────────────────────────────────
    @SuppressLint("ClickableViewAccessibility", "SetTextI18n")
    private fun buildFab(): View {
        val fab = FrameLayout(this)
        fab.background = GradientDrawable().apply {
            shape  = GradientDrawable.OVAL
            colors = intArrayOf(0xFF3B7BF5.toInt(), 0xFF7B5CF5.toInt())
            orientation = GradientDrawable.Orientation.TL_BR
        }
        fab.elevation = dp(8).toFloat()
        fab.addView(TextView(this).apply {
            text     = "⌨"
            textSize = 22f
            setTextColor(0xFFFFFFFF.toInt())
            gravity  = Gravity.CENTER
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
        })

        var dragRawX = 0f; var dragRawY = 0f
        var winX = 0;      var winY = 0
        var hasDragged = false
        val dragThresh = dp(6).toFloat()

        fab.setOnTouchListener { _, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    dragRawX = e.rawX; dragRawY = e.rawY
                    winX = params.x;   winY = params.y
                    hasDragged = false
                    fab.animate().scaleX(0.88f).scaleY(0.88f).setDuration(80).start()
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - dragRawX; val dy = e.rawY - dragRawY
                    if (!hasDragged && hypot(dx, dy) > dragThresh) hasDragged = true
                    if (hasDragged) {
                        params.x = (winX + dx).toInt().coerceIn(0, screenW - fabSizePx)
                        params.y = (winY + dy).toInt().coerceIn(0, screenH - fabSizePx)
                        wm.updateViewLayout(containerRoot, params)
                        fab.animate().scaleX(1f).scaleY(1f).setDuration(60).start()
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    fab.animate().scaleX(1f).scaleY(1f).setDuration(120).start()
                    if (!hasDragged) animateExpand()
                }
            }
            true
        }
        return fab
    }

    // ── Panel ─────────────────────────────────────────────────────────
    @SuppressLint("ClickableViewAccessibility", "SetTextI18n")
    private fun buildPanel(): View {
        val panel = FrameLayout(this)
        panel.background = GradientDrawable().apply {
            setColor(0xFF0F1420.toInt())
            cornerRadius = dp(20).toFloat()
            setStroke(dp(1), 0xFF1E2740.toInt())
        }
        panel.elevation = dp(12).toFloat()
        panel.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setRoundRect(0, 0, view.width, view.height, dp(20).toFloat())
            }
        }
        panel.clipToOutline = true

        val vBox = LinearLayout(this).apply {
            orientation  = LinearLayout.VERTICAL
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
        }
        fun hLine() = View(this).apply {
            setBackgroundColor(0xFF1E2740.toInt())
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, 1)
        }

        vBox.addView(buildTitleBar())
        vBox.addView(hLine())
        vBox.addView(buildSettingsRow())
        vBox.addView(hLine())
        vBox.addView(TouchpadView(this).also {
            it.layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f)
        })
        vBox.addView(hLine())
        vBox.addView(buildButtonRow())
        vBox.addView(hLine())
        vBox.addView(buildCollapseButton())

        panel.addView(vBox)
        panel.addView(buildResizeHandle())
        return panel
    }

    // ── Title bar ─────────────────────────────────────────────────────
    @SuppressLint("ClickableViewAccessibility", "SetTextI18n")
    private fun buildTitleBar(): View {
        val bar = FrameLayout(this).apply {
            setBackgroundColor(0xFF141928.toInt())
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, dp(40))
        }
        bar.addView(View(this).apply {
            background = GradientDrawable().apply {
                setColor(0xFF404868.toInt()); cornerRadius = dp(2).toFloat()
            }
            layoutParams = FrameLayout.LayoutParams(dp(32), dp(4), Gravity.CENTER)
        })
        bar.addView(TextView(this).apply {
            text = "PhonePad"
            setTextColor(0xFF8A95B8.toInt())
            textSize = 11f; gravity = Gravity.CENTER
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
        })

        var dRawX = 0f; var dRawY = 0f; var wX = 0; var wY = 0
        bar.setOnTouchListener { _, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    dRawX = e.rawX; dRawY = e.rawY
                    wX = params.x; wY = params.y
                }
                MotionEvent.ACTION_MOVE -> {
                    params.x = (wX + (e.rawX - dRawX)).toInt()
                        .coerceIn(0, screenW - params.width)
                    params.y = (wY + (e.rawY - dRawY)).toInt()
                        .coerceIn(0, screenH - params.height)
                    wm.updateViewLayout(containerRoot, params)
                }
            }
            true
        }
        return bar
    }

    // ── Settings row ─────────────────────────────────────────────────
    @SuppressLint("SetTextI18n")
    private fun buildSettingsRow(): View {
        val row = LinearLayout(this).apply {
            orientation  = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, dp(46))
            setPadding(dp(10), 0, dp(10), 0)
            gravity      = Gravity.CENTER_VERTICAL
            setBackgroundColor(0xFF0F1420.toInt())
        }
        fun lbl(t: String) = TextView(this).apply {
            text = t; setTextColor(0xFF8A95B8.toInt()); textSize = 9f
            layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT)
            setPadding(0, 0, dp(4), 0)
        }
        fun bar(prog: Int, color: Int, onChange: (Int) -> Unit) =
            SeekBar(this).apply {
                max = 100; progress = prog
                layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f)
                progressTintList =
                    android.content.res.ColorStateList.valueOf(color)
                thumbTintList =
                    android.content.res.ColorStateList.valueOf(color)
                setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                    override fun onProgressChanged(sb: SeekBar, p: Int, u: Boolean) {
                        if (u) onChange(p)
                    }
                    override fun onStartTrackingTouch(sb: SeekBar) { touchpadLocked = true }
                    override fun onStopTrackingTouch(sb: SeekBar)  { touchpadLocked = false }
                })
            }

        row.addView(lbl("Spd"))
        row.addView(bar(
            ((sensitivity - 0.5f) / 5.5f * 100).toInt().coerceIn(0, 100),
            0xFF3B7BF5.toInt()) { p -> sensitivity = 0.5f + p / 100f * 5.5f })
        row.addView(View(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(8), 1)
        })
        row.addView(lbl("Scr"))
        row.addView(bar(
            ((scrollSpeed - 1f) / 9f * 100).toInt().coerceIn(0, 100),
            0xFF3BF5C0.toInt()) { p -> scrollSpeed = 1f + p / 100f * 9f })
        return row
    }

    // ── Button row ────────────────────────────────────────────────────
    @SuppressLint("SetTextI18n", "ClickableViewAccessibility")
    private fun buildButtonRow(): View {
        val row = LinearLayout(this).apply {
            orientation  = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, dp(46))
            setBackgroundColor(0xFF0F1420.toInt())
        }
        fun vDiv() = View(this).apply {
            setBackgroundColor(0xFF1E2740.toInt())
            layoutParams = LinearLayout.LayoutParams(1, MATCH_PARENT)
        }
        fun btn(label: String, accentColor: Int, onTap: () -> Unit): View =
            TextView(this).apply {
                text = label; gravity = Gravity.CENTER
                setTextColor(0xFF8A95B8.toInt()); textSize = 12f
                layoutParams = LinearLayout.LayoutParams(0, MATCH_PARENT, 1f).also {
                    it.setMargins(dp(5), dp(5), dp(5), dp(5))
                }
                background = GradientDrawable().apply {
                    cornerRadius = dp(10).toFloat()
                    setColor(0xFF141928.toInt())
                    setStroke(dp(1), 0xFF1E2740.toInt())
                }
                setOnTouchListener { v, e ->
                    val bg = v.background as? GradientDrawable
                    when (e.action) {
                        MotionEvent.ACTION_DOWN ->
                            bg?.setColor((accentColor and 0x00FFFFFF) or 0x33000000)
                        MotionEvent.ACTION_UP,
                        MotionEvent.ACTION_CANCEL ->
                            bg?.setColor(0xFF141928.toInt())
                    }
                    false
                }
                setOnClickListener { onTap() }
            }

        row.addView(btn("Left",  0xFF3B7BF5.toInt()) { sendEvent("left_click") })
        row.addView(vDiv())
        row.addView(btn("Mid",   0xFF7B5CF5.toInt()) { sendEvent("middle_click") })
        row.addView(vDiv())
        row.addView(btn("Right", 0xFF3BF5C0.toInt()) { sendEvent("right_click") })
        return row
    }

    // ── Collapse button ───────────────────────────────────────────────
    @SuppressLint("SetTextI18n", "ClickableViewAccessibility")
    private fun buildCollapseButton(): View {
        return FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, dp(40))
            setBackgroundColor(0xFF0C101A.toInt())
            val tv = TextView(this@OverlayService).apply {
                text = "▼   Collapse"
                setTextColor(0xFF8A95B8.toInt())
                textSize = 11f; gravity = Gravity.CENTER
                layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
                letterSpacing = 0.04f
            }
            addView(tv)
            setOnClickListener { animateCollapse() }
            setOnTouchListener { _, e ->
                when (e.action) {
                    MotionEvent.ACTION_DOWN ->
                        tv.setTextColor(0xFF3B7BF5.toInt())
                    MotionEvent.ACTION_UP,
                    MotionEvent.ACTION_CANCEL ->
                        tv.setTextColor(0xFF8A95B8.toInt())
                }
                false
            }
        }
    }

    // ── Resize handle ─────────────────────────────────────────────────
    @SuppressLint("ClickableViewAccessibility")
    private fun buildResizeHandle(): View {
        val handle = View(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                dp(28), dp(28), Gravity.BOTTOM or Gravity.END)
            background = object : Drawable() {
                override fun draw(c: Canvas) {
                    val p = Paint().apply {
                        color = 0xFF404868.toInt()
                        isAntiAlias = true; style = Paint.Style.FILL
                    }
                    val b = bounds
                    c.drawPath(Path().apply {
                        moveTo(b.right.toFloat(), b.top.toFloat() + dp(6))
                        lineTo(b.right.toFloat(), b.bottom.toFloat())
                        lineTo(b.left.toFloat() + dp(6), b.bottom.toFloat())
                        close()
                    }, p)
                }
                override fun setAlpha(a: Int) {}
                override fun setColorFilter(cf: ColorFilter?) {}
                @Deprecated("Deprecated")
                override fun getOpacity() = PixelFormat.TRANSLUCENT
            }
        }
        var rsx = 0f; var rsy = 0f; var rsw = panelW; var rsh = panelH
        handle.setOnTouchListener { _, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    rsx = e.rawX; rsy = e.rawY
                    rsw = params.width; rsh = params.height
                    touchpadLocked = true
                }
                MotionEvent.ACTION_MOVE -> {
                    val nw = (rsw + (e.rawX - rsx)).toInt()
                        .coerceIn(dp(220), (screenW * 0.85f).toInt())
                    val nh = (rsh + (e.rawY - rsy)).toInt()
                        .coerceIn(dp(260), (screenH * 0.75f).toInt())
                    params.width = nw; params.height = nh
                    panelW = nw; panelH = nh
                    wm.updateViewLayout(containerRoot, params)
                    (panelView.layoutParams as? FrameLayout.LayoutParams)?.let {
                        it.width = nw; it.height = nh
                        panelView.layoutParams = it
                    }
                }
                MotionEvent.ACTION_UP,
                MotionEvent.ACTION_CANCEL -> touchpadLocked = false
            }
            true
        }
        return handle
    }

    // ═════════════════════════════════════════════════════════════════
    // Animation
    // ═════════════════════════════════════════════════════════════════

    private fun showFabInstant() {
        fabView.alpha = 1f; fabView.scaleX = 1f; fabView.scaleY = 1f
        panelView.alpha = 0f; panelView.scaleX = 0.4f; panelView.scaleY = 0.4f
        panelView.visibility = View.INVISIBLE
        params.width = fabSizePx; params.height = fabSizePx
        wm.updateViewLayout(containerRoot, params)
        expanded = false
    }

    /** FAB → panel: spring overshoot, 380 ms */
    private fun animateExpand() {
        if (expanded || animating) return
        animating = true

        val targetX = (params.x - (panelW - fabSizePx) / 2)
            .coerceIn(0, (screenW - panelW).coerceAtLeast(0))
        val targetY = (params.y - (panelH - fabSizePx) / 2)
            .coerceIn(0, (screenH - panelH).coerceAtLeast(0))

        panelView.visibility = View.VISIBLE
        panelView.scaleX = 0.40f; panelView.scaleY = 0.40f; panelView.alpha = 0f
        panelView.pivotX = panelW / 2f; panelView.pivotY = panelH / 2f

        params.width = panelW; params.height = panelH
        params.x = targetX;   params.y = targetY
        wm.updateViewLayout(containerRoot, params)

        activeAnimator?.cancel()
        ValueAnimator.ofFloat(0f, 1f).apply {
            duration     = 380
            interpolator = OvershootInterpolator(1.6f)
            addUpdateListener { va ->
                val t  = va.animatedValue as Float
                val tL = t.coerceIn(0f, 1f)
                panelView.scaleX = 0.40f + t * 0.60f
                panelView.scaleY = 0.40f + t * 0.60f
                panelView.alpha  = tL
                val ft = (tL * 2f).coerceIn(0f, 1f)
                fabView.alpha  = 1f - ft
                fabView.scaleX = 1f - ft * 0.30f
                fabView.scaleY = 1f - ft * 0.30f
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    fabView.alpha      = 0f
                    fabView.visibility = View.INVISIBLE
                    panelView.scaleX   = 1f; panelView.scaleY = 1f; panelView.alpha = 1f
                    expanded = true; animating = false
                }
                override fun onAnimationCancel(animation: Animator) { animating = false }
            })
            start()
            activeAnimator = this
        }
    }

    /** panel → FAB: decelerate, 280 ms */
    private fun animateCollapse() {
        if (!expanded || animating) return
        animating = true

        val targetX = (params.x + (panelW - fabSizePx) / 2)
            .coerceIn(0, screenW - fabSizePx)
        val targetY = (params.y + (panelH - fabSizePx) / 2)
            .coerceIn(0, screenH - fabSizePx)

        fabView.visibility = View.VISIBLE
        fabView.alpha = 0f; fabView.scaleX = 0.7f; fabView.scaleY = 0.7f

        panelView.pivotX = panelW / 2f; panelView.pivotY = panelH / 2f

        val startX = params.x; val startY = params.y

        activeAnimator?.cancel()
        ValueAnimator.ofFloat(0f, 1f).apply {
            duration     = 280
            interpolator = DecelerateInterpolator(2f)
            addUpdateListener { va ->
                val t = va.animatedValue as Float
                val pSc = 1f - t * 0.65f
                panelView.scaleX = pSc; panelView.scaleY = pSc; panelView.alpha = 1f - t
                val ft = ((t - 0.4f) / 0.6f).coerceIn(0f, 1f)
                fabView.alpha  = ft
                fabView.scaleX = 0.7f + ft * 0.3f
                fabView.scaleY = 0.7f + ft * 0.3f
                params.width  = (panelW  + (fabSizePx - panelW)  * t).toInt()
                params.height = (panelH  + (fabSizePx - panelH)  * t).toInt()
                params.x      = (startX  + (targetX   - startX)  * t).toInt()
                params.y      = (startY  + (targetY   - startY)  * t).toInt()
                wm.updateViewLayout(containerRoot, params)
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    panelView.visibility = View.INVISIBLE
                    panelView.scaleX = 0.4f; panelView.scaleY = 0.4f; panelView.alpha = 0f
                    fabView.alpha = 1f; fabView.scaleX = 1f; fabView.scaleY = 1f
                    params.width = fabSizePx; params.height = fabSizePx
                    params.x = targetX; params.y = targetY
                    wm.updateViewLayout(containerRoot, params)
                    expanded = false; animating = false
                }
                override fun onAnimationCancel(animation: Animator) { animating = false }
            })
            start()
            activeAnimator = this
        }
    }

    // ── dp helper ─────────────────────────────────────────────────────
    fun dp(v: Int) = (v * resources.displayMetrics.density + 0.5f).toInt()

    // ═════════════════════════════════════════════════════════════════
    // TOUCHPAD VIEW
    // ═════════════════════════════════════════════════════════════════

    @SuppressLint("ViewConstructor", "ClickableViewAccessibility")
    inner class TouchpadView(context: Context) : View(context) {

        private val smX = TpEma(); private val smY = TpEma()
        private val ptrs   = mutableMapOf<Int, TpPtr>()
        private val ignore = mutableSetOf<Int>()

        private var dragging    = false
        private var waitDblDrag = false
        private var lastTapMs   = 0L
        private var committed   = 0
        private var lastChgMs   = 0L
        private val intentMs    = 5L

        private var axis    = TpAxis.NONE
        private var scAccX  = 0f; private var scAccY = 0f
        private var lastScMs = 0L
        private val scThMs  = 16L
        private val axThr   = 1.5f
        private var lastD   = 0f; private var dH = false

        // Momentum
        private val h = Handler(Looper.getMainLooper())
        private var mV = 0f; private var mH = false
        private val mTick: Runnable = object : Runnable {
            override fun run() {
                mV *= 0.80f
                if (abs(mV) < 0.08f) { mV = 0f; return }
                if (mH) sendEvent("scroll_x",
                    mapOf("dx" to mV.toDouble(), "natural" to naturalScroll))
                else    sendEvent("scroll",
                    mapOf("dy" to mV.toDouble(), "natural" to naturalScroll))
                h.postDelayed(this, 16)
            }
        }
        private fun startMom(v: Float, horiz: Boolean) {
            h.removeCallbacks(mTick)
            if (abs(v) < 0.24f) return
            mV = v; mH = horiz; h.post(mTick)
        }
        private fun stopMom() { h.removeCallbacks(mTick); mV = 0f }

        // Pinch
        private var pDist = 0f; private var pAcc = 0f; private var pActive = false
        private val pStep = 40f

        // Long press
        private val lpMs = 400L; private var lpSched = false
        private val lpRun = Runnable {
            if (ptrs.size == 1 && !waitDblDrag && !dragging) {
                dragging = true; invalidate(); sendEvent("mouse_down")
            }
            lpSched = false
        }

        private val dblWin  = 280L
        private val tapMove = dp(10).toFloat()
        private val tapDur  = 220L

        // Paint objects
        private val pBg  = Paint().apply { color = 0xFF111827.toInt() }
        private val pBd  = Paint().apply { style = Paint.Style.STROKE; isAntiAlias = true }
        private val pDot = Paint().apply { color = 0xFF252E42.toInt(); isAntiAlias = true }
        private val pTxt = Paint().apply { textAlign = Paint.Align.CENTER; isAntiAlias = true }
        private val pRip = Paint().apply { isAntiAlias = true }
        private var rX = 0f; private var rY = 0f; private var rR = 0f; private var rA = 0

        private fun ripple(x: Float, y: Float) { rX = x; rY = y; rR = 0f; rA = 150; tickRip() }
        private fun tickRip() {
            if (rA <= 0) return
            rR += dp(7).toFloat(); rA = (rA * 0.85f).toInt()
            invalidate(); h.postDelayed({ tickRip() }, 16)
        }

        override fun onDraw(canvas: Canvas) {
            val w = width.toFloat(); val ht = height.toFloat()
            canvas.drawRect(0f, 0f, w, ht, pBg)
            val sp = dp(20).toFloat(); var gx = sp
            while (gx < w) {
                var gy = sp
                while (gy < ht) { canvas.drawCircle(gx, gy, dp(1).toFloat(), pDot); gy += sp }
                gx += sp
            }
            pBd.color = if (dragging) 0xFF3B7BF5.toInt() else 0xFF1E2740.toInt()
            pBd.strokeWidth = if (dragging) dp(2).toFloat() else dp(1).toFloat()
            canvas.drawRect(1f, 1f, w - 1f, ht - 1f, pBd)
            if (rA > 0) {
                pRip.color = (rA shl 24) or 0x3B7BF5
                canvas.drawCircle(rX, rY, rR, pRip)
            }
            if (dragging) {
                pTxt.color = 0xCC3B7BF5.toInt(); pTxt.textSize = dp(26).toFloat()
                canvas.drawText("✥", w / 2f, ht / 2f + dp(10), pTxt)
                pTxt.textSize = dp(11).toFloat(); pTxt.color = 0xAA3B7BF5.toInt()
                canvas.drawText("Dragging", w / 2f, ht / 2f + dp(32), pTxt)
            } else {
                pTxt.color = 0xFF404868.toInt(); pTxt.textSize = dp(26).toFloat()
                canvas.drawText("◎", w / 2f, ht / 2f + dp(10), pTxt)
                pTxt.textSize = dp(11).toFloat()
                canvas.drawText("Touchpad", w / 2f, ht / 2f + dp(32), pTxt)
            }
        }

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(e: MotionEvent): Boolean {
            if (touchpadLocked) return true
            val now = SystemClock.uptimeMillis()

            when (e.actionMasked) {

                MotionEvent.ACTION_DOWN,
                MotionEvent.ACTION_POINTER_DOWN -> {
                    stopMom()
                    val i = e.actionIndex; val id = e.getPointerId(i)
                    val rx = e.getX(i); val ry = e.getY(i)
                    ptrs[id] = TpPtr(rx, ry, rx, ry, now)
                    ignore.remove(id); committed = 0; lastChgMs = now
                    if (ptrs.size == 1) {
                        axis = TpAxis.NONE; scAccX = 0f; scAccY = 0f
                        pDist = 0f; pAcc = 0f; pActive = false
                        smX.reset(); smY.reset()
                        if (lastTapMs > 0 && (now - lastTapMs) < dblWin) {
                            waitDblDrag = true; lastTapMs = 0
                        }
                        if (!waitDblDrag && !dragging) {
                            lpSched = true
                            h.postDelayed(lpRun, lpMs)
                        }
                    } else if (ptrs.size >= 2) {
                        h.removeCallbacks(lpRun); lpSched = false
                        if (dragging) { dragging = false; sendEvent("mouse_up"); invalidate() }
                    }
                }

                MotionEvent.ACTION_MOVE -> {
                    for (idx in 0 until e.pointerCount) {
                        val id = e.getPointerId(idx)
                        val info = ptrs[id] ?: continue
                        if (ignore.contains(id)) continue
                        val nx = e.getX(idx); val ny = e.getY(idx)
                        val dx = nx - info.x; val dy = ny - info.y
                        ptrs[id] = info.copy(x = nx, y = ny)
                        if (now - lastChgMs < intentMs) continue
                        if (committed != ptrs.size) {
                            committed = ptrs.size; scAccX = 0f; scAccY = 0f
                            axis = TpAxis.NONE; pDist = 0f; pAcc = 0f; pActive = false
                            smX.reset(); smY.reset()
                        }
                        when (committed) {
                            1 -> {
                                if (lpSched) {
                                    val mv = hypot(nx - info.downX, ny - info.downY)
                                    if (mv > tapMove) {
                                        h.removeCallbacks(lpRun); lpSched = false
                                    }
                                }
                                if (waitDblDrag && !dragging) {
                                    val mv = hypot(nx - info.downX, ny - info.downY)
                                    if (mv > tapMove) {
                                        waitDblDrag = false; dragging = true
                                        invalidate()
                                        sendEvent("double_click_drag_start")
                                    }
                                    continue
                                }
                                if (!waitDblDrag)
                                    sendEvent("move", mapOf(
                                        "dx" to smX.smooth(dx * sensitivity).toDouble(),
                                        "dy" to smY.smooth(dy * sensitivity).toDouble()))
                            }
                            2 -> {
                                val ids  = ptrs.keys.toList()
                                val p0   = ptrs[ids[0]] ?: continue
                                val p1   = ptrs[ids[1]] ?: continue
                                val dist = hypot(p0.x - p1.x, p0.y - p1.y)
                                if (pDist == 0f) {
                                    pDist = dist
                                    if (!pActive) { pActive = true; sendEvent("zoom_start") }
                                    continue
                                }
                                val pd = dist - pDist; pDist = dist; pAcc += pd
                                if (abs(pAcc) >= pStep) {
                                    sendEvent(if (pAcc > 0) "zoom_in" else "zoom_out")
                                    pAcc = 0f
                                }
                                if (abs(pd) > 4f) continue
                                if (axis == TpAxis.NONE) {
                                    scAccY += dy; scAccX += dx
                                    if (abs(scAccY) >= axThr || abs(scAccX) >= axThr) {
                                        axis = if (abs(scAccX) > abs(scAccY) * 1.3f)
                                            TpAxis.HORIZ else TpAxis.VERT
                                        scAccX = 0f; scAccY = 0f
                                    }
                                } else if (now - lastScMs >= scThMs) {
                                    if (axis == TpAxis.VERT) {
                                        scAccY += dy
                                        val v = scAccY * (scrollSpeed / 50f)
                                        if (abs(v) > 0.1f) {
                                            lastD = -v; dH = false
                                            sendEvent("scroll", mapOf(
                                                "dy" to (-v).toDouble(),
                                                "natural" to naturalScroll))
                                        }
                                        scAccY = 0f
                                    } else {
                                        scAccX += dx
                                        val v = scAccX * (scrollSpeed / 50f)
                                        if (abs(v) > 0.03f) {
                                            lastD = -v; dH = true
                                            sendEvent("scroll_x", mapOf(
                                                "dx" to (-v).toDouble(),
                                                "natural" to naturalScroll))
                                        }
                                        scAccX = 0f
                                    }
                                    lastScMs = now
                                }
                            }
                        }
                    }
                }

                MotionEvent.ACTION_UP,
                MotionEvent.ACTION_POINTER_UP -> {
                    h.removeCallbacks(lpRun); lpSched = false
                    val i    = e.actionIndex; val id = e.getPointerId(i)
                    val info = ptrs[id];      val fc = ptrs.size

                    if (waitDblDrag && !dragging) {
                        waitDblDrag = false
                        ripple(info?.x ?: 0f, info?.y ?: 0f)
                        sendEvent("double_click")
                        ptrs.remove(id); committed = 0; lastChgMs = now
                        return true
                    }

                    if (info != null) {
                        val mv  = hypot(e.getX(i) - info.downX, e.getY(i) - info.downY)
                        val dur = now - info.downTime
                        val tap = mv < tapMove && dur < tapDur
                        if (tap && fc == 2) {
                            sendEvent("right_click")
                            for (oid in ptrs.keys) if (oid != id) {
                                ignore.add(oid)
                                h.postDelayed({ ignore.remove(oid) }, 300)
                            }
                        } else if (tap && fc == 1 && !ignore.contains(id)) {
                            ripple(e.getX(i), e.getY(i))
                            if (lastTapMs > 0 && (now - lastTapMs) < dblWin) {
                                lastTapMs = 0; waitDblDrag = true
                                sendEvent("double_click")
                            } else {
                                lastTapMs = now; sendEvent("left_click")
                            }
                        }
                    }

                    if (dragging) {
                        dragging = false; waitDblDrag = false
                        invalidate(); sendEvent("mouse_up")
                    }
                    if (fc == 2 && pActive) {
                        sendEvent("zoom_end")
                        pActive = false; pDist = 0f; pAcc = 0f
                    }
                    if (fc == 2 && axis != TpAxis.NONE)
                        startMom(lastD * (scrollSpeed / 50f) * 0.8f, dH)

                    if (fc == 2) for (oid in ptrs.keys) if (oid != id) {
                        ignore.add(oid)
                        h.postDelayed({ ignore.remove(oid) }, intentMs + 20)
                    }

                    ptrs.remove(id)
                    if (ptrs.isEmpty()) {
                        committed = 0; lastChgMs = now
                        scAccX = 0f; scAccY = 0f; axis = TpAxis.NONE
                        pDist = 0f; pAcc = 0f; pActive = false
                        smX.reset(); smY.reset()
                    } else {
                        committed = 0; lastChgMs = now
                    }
                    invalidate()
                }

                MotionEvent.ACTION_CANCEL -> {
                    h.removeCallbacks(lpRun); stopMom()
                    if (dragging) { sendEvent("mouse_up"); dragging = false }
                    if (pActive) { sendEvent("zoom_end"); pActive = false }
                    ptrs.clear(); ignore.clear(); committed = 0
                    axis = TpAxis.NONE; waitDblDrag = false
                    smX.reset(); smY.reset(); invalidate()
                }
            }
            return true
        }
    }

    companion object {
        private const val MATCH_PARENT = ViewGroup.LayoutParams.MATCH_PARENT
    }
}