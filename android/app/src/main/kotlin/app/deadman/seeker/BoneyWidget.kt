package app.deadman.seeker

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.SizeF
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
import org.json.JSONException
import kotlin.math.floor
import kotlin.math.max

/**
 * Renders Boney from the keys the Dart side writes through home_widget:
 * - boney_state: checking, checked_in, on_track, check_in_soon, tier_due, last_tier, released, no_plan
 * - boney_title: the small widget's line, and the big text when no timer runs ("Plan released")
 * - boney_caption, boney_sticker, boney_count ("" hides the heart counter)
 * - boney_due_at: epoch (seconds or millis) of the next release, or of the release that is due
 * - boney_tiers: JSON list of up to three {label, value}
 * - boney_button: check_in, check_in_to_stop, open_app or none
 * - optional boney_timeline (`[{"at": epoch ms, <the text keys>}]`, the latest passed entry wins)
 *   and boney_updated_at (epoch ms of the last push)
 *
 * The timer runs in the launcher (Chronometer) so it never goes stale: down to boney_due_at while
 * alive, up from it while a tier is due; past a day it reads "Nd HHh". If the app has not pushed
 * the next state in time, on_track turns into check_in_soon inside the last hour, checked_in falls
 * back after five minutes, a passed release shows as tier due and a stuck check-in gives the
 * button back after three minutes. One non-wakeup alarm drives those changes.
 */
internal object BoneyWidget {
    const val ACTION_TICK = "app.deadman.seeker.boney.TICK"

    private const val KEY_STATE = "boney_state"
    private const val KEY_TITLE = "boney_title"
    private const val KEY_CAPTION = "boney_caption"
    private const val KEY_STICKER = "boney_sticker"
    private const val KEY_DUE_AT = "boney_due_at"
    private const val KEY_COUNT = "boney_count"
    private const val KEY_TIERS = "boney_tiers"
    private const val KEY_BUTTON = "boney_button"
    private const val KEY_TIMELINE = "boney_timeline"
    private const val KEY_UPDATED_AT = "boney_updated_at"
    private const val DOUBLE_PREFIX = "home_widget.double."

    private const val NATIVE_PREFS = "BoneyWidgetNative"
    private const val SEEN_STAMP = "seen"
    private const val SEEN_SINCE = "since"

    private val CHECK_IN_URI: Uri = Uri.parse("deadman://boney/checkin")
    private val OPEN_URI: Uri = Uri.parse("deadman://boney/open")

    private const val MINUTE_MS = 60_000L
    private const val HOUR_MS = 60 * MINUTE_MS
    private const val DAY_MS = 24 * HOUR_MS
    private const val CHECKED_IN_HOLD_MS = 5 * MINUTE_MS
    private const val CHECKING_TIMEOUT_MS = 3 * MINUTE_MS
    private const val SOON_MS = HOUR_MS
    private const val TIMER_MAX_MS = DAY_MS
    private const val TICK_WINDOW_MS = MINUTE_MS
    private const val TICK_SLACK_MS = 1_000L

    // Epoch values at or above this are milliseconds, below it seconds (until the year 5138).
    private const val EPOCH_MILLIS_FROM = 100_000_000_000L

    // Art grids (pixels in the source drawings); the PNGs are 4x of these.
    private const val BONEY_W = 26
    private const val BONEY_H = 24
    private const val HEART_W = 11
    private const val HEART_H = 10
    private const val HEART_DP_PER_PIXEL = 2f

    private const val MAX_TIERS = 3
    private const val MEDIUM_CAPTION_MIN_DP = 160f
    private const val MAX_SIZES = 8

    // Launchers that do not report sizes get one layout per breakpoint.
    private val DEFAULT_SIZES =
        listOf(SizeF(110f, 110f), SizeF(250f, 110f), SizeF(250f, 340f))

    private enum class Action(val key: String, val label: Int) {
        CHECK_IN("check_in", R.string.boney_button_check_in),
        CHECK_IN_TO_STOP("check_in_to_stop", R.string.boney_button_check_in_to_stop),
        OPEN_APP("open_app", R.string.boney_button_open_app),
        NONE("none", R.string.boney_checking);

        companion object {
            fun from(key: String?) = entries.firstOrNull { it.key == key }
        }
    }

    private enum class Mood(
        val key: String,
        val art: Int,
        val png: Int,
        val color: Int,
        val background: Int,
        val label: Int,
        val sticker: Int,
        val action: Action,
    ) {
        CHECKED_IN(
            "checked_in", R.drawable.boney_px_checked_in, R.drawable.boney_checked_in,
            R.color.boney_pulse, R.drawable.boney_bg_alive, R.string.boney_label_checked_in,
            R.string.boney_sticker_alive, Action.CHECK_IN,
        ),
        ON_TRACK(
            "on_track", R.drawable.boney_px_on_track, R.drawable.boney_on_track,
            R.color.boney_pulse, R.drawable.boney_bg_alive, R.string.boney_label_on_track,
            R.string.boney_sticker_alive, Action.CHECK_IN,
        ),
        CHECK_IN_SOON(
            "check_in_soon", R.drawable.boney_px_check_in_soon, R.drawable.boney_check_in_soon,
            R.color.boney_pulse, R.drawable.boney_bg_grave, R.string.boney_label_check_in_soon,
            R.string.boney_sticker_alive, Action.CHECK_IN,
        ),
        TIER_DUE(
            "tier_due", R.drawable.boney_px_tier_due, R.drawable.boney_tier_due,
            R.color.boney_flatline, R.drawable.boney_bg_flatline, R.string.boney_label_tier_due,
            R.string.boney_sticker_tier_due, Action.CHECK_IN_TO_STOP,
        ),
        LAST_TIER(
            "last_tier", R.drawable.boney_px_last_tier, R.drawable.boney_last_tier,
            R.color.boney_flatline, R.drawable.boney_bg_void, R.string.boney_label_last_tier,
            R.string.boney_sticker_last_tier, Action.CHECK_IN_TO_STOP,
        ),
        RELEASED(
            "released", R.drawable.boney_px_released, R.drawable.boney_released,
            R.color.boney_ash, R.drawable.boney_bg_grave, R.string.boney_label_released,
            R.string.boney_sticker_released, Action.OPEN_APP,
        ),
        NO_PLAN(
            "no_plan", R.drawable.boney_px_no_plan, R.drawable.boney_no_plan,
            R.color.boney_ash, R.drawable.boney_bg_void, R.string.boney_label_no_plan,
            R.string.boney_sticker_no_plan, Action.OPEN_APP,
        ),
        CHECKING(
            "checking", R.drawable.boney_px_front, R.drawable.boney_front,
            R.color.boney_pulse, R.drawable.boney_bg_alive, R.string.boney_checking,
            R.string.boney_sticker_alive, Action.CHECK_IN,
        );

        val counting get() = this == CHECKED_IN || this == ON_TRACK || this == CHECK_IN_SOON || this == CHECKING
        val settled get() = this == RELEASED || this == NO_PLAN
        val due get() = this == TIER_DUE || this == LAST_TIER

        companion object {
            fun from(key: String?) = entries.firstOrNull { it.key == key }
        }
    }

    private enum class Layout(val res: Int) {
        SMALL(R.layout.boney_widget_small),
        MEDIUM(R.layout.boney_widget_medium),
        LARGE(R.layout.boney_widget_large),
    }

    private class Snapshot(
        val mood: Mood,
        /** The small widget's line, and the big text when no timer runs ("On track", "Plan released"). */
        val title: String,
        val caption: String,
        val sticker: String,
        val count: String,
        val tiers: List<Pair<String, String>>,
        val action: Action,
        /** Epoch millis the timer counts down to, or 0. */
        val countdownTo: Long,
        /** Epoch millis a due release has been counting up from, or 0. */
        val countUpFrom: Long,
        /** Epoch millis of the next time-driven change, or null when nothing changes on its own. */
        val nextTick: Long?,
    )

    /** The overridable text fields, from the top-level keys or a passed timeline entry. */
    private class Fields(
        val state: String,
        val title: String,
        val caption: String,
        val sticker: String,
        val button: String,
    )

    fun renderAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, BoneyWidgetProvider::class.java))
        if (ids.isEmpty()) {
            cancelTick(context)
            return
        }
        render(context, manager, ids, HomeWidgetPlugin.getData(context))
    }

    fun render(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
        prefs: SharedPreferences,
    ) {
        val now = System.currentTimeMillis()
        val snapshot = resolve(context, prefs, now)
        for (id in ids) {
            manager.updateAppWidget(id, views(context, manager.getAppWidgetOptions(id), snapshot, now))
        }
        scheduleTick(context, snapshot.nextTick)
    }

    fun cancelTick(context: Context) = scheduleTick(context, null)

    private fun resolve(context: Context, prefs: SharedPreferences, now: Long): Snapshot {
        val pushed =
            Fields(
                state = prefs.text(KEY_STATE),
                title = prefs.text(KEY_TITLE),
                caption = prefs.text(KEY_CAPTION),
                sticker = prefs.text(KEY_STICKER),
                button = prefs.text(KEY_BUTTON),
            )
        val timeline = parseTimeline(prefs.text(KEY_TIMELINE), pushed)
        val entry = timeline.lastOrNull { it.first <= now }
        val fields = entry?.second ?: pushed
        val dueAt = prefs.epochMillis(KEY_DUE_AT)
        val since =
            entry?.first
                ?: prefs.epochMillis(KEY_UPDATED_AT).takeIf { it > 0 }
                ?: observedSince(context, fields.state, dueAt, now)

        val shown = Mood.from(fields.state.trim().lowercase()) ?: Mood.NO_PLAN
        var mood = shown
        var title = fields.title
        var caption = fields.caption
        var sticker = fields.sticker
        var action = Action.from(fields.button.trim()) ?: mood.action

        // Fallbacks for when the app has not pushed (or could not push) the next state in time.
        if (mood == Mood.CHECKING && now - since >= CHECKING_TIMEOUT_MS) {
            mood = Mood.ON_TRACK
            caption = if (dueAt > 0) context.getString(R.string.boney_until_next_release) else ""
            action = Action.CHECK_IN
        }
        if (mood == Mood.CHECKED_IN && now - since >= CHECKED_IN_HOLD_MS) mood = Mood.ON_TRACK
        val counting = mood.counting && dueAt > 0
        val overdue = counting && now >= dueAt
        if (overdue && mood != Mood.CHECKING) {
            mood = Mood.TIER_DUE
            sticker = context.getString(R.string.boney_sticker_tier_due)
            caption = context.getString(R.string.boney_due_caption)
            if (action == Action.CHECK_IN) action = Action.CHECK_IN_TO_STOP
        } else if (counting && mood == Mood.ON_TRACK && dueAt - now <= SOON_MS) {
            mood = Mood.CHECK_IN_SOON
        }
        if (mood != shown) title = ""

        val tiers = parseTiers(prefs.text(KEY_TIERS))
        val countdownTo = if (counting && !overdue) dueAt else 0L
        val countUpFrom = if (mood.due && dueAt in 1..now) dueAt else 0L

        val ticks = mutableListOf<Long>()
        timeline.firstOrNull { it.first > now }?.let { ticks += it.first }
        if (shown == Mood.CHECKED_IN) ticks += since + CHECKED_IN_HOLD_MS
        if (shown == Mood.CHECKING) ticks += since + CHECKING_TIMEOUT_MS
        if (countdownTo > 0) {
            val left = countdownTo - now
            ticks += countdownTo
            ticks += countdownTo - SOON_MS
            // Above a day the timer is "Nd HHh": refresh it when the hour digit changes.
            if (left > TIMER_MAX_MS) ticks += countdownTo - (left / HOUR_MS) * HOUR_MS + TICK_SLACK_MS
        }
        if (countUpFrom > 0) {
            val elapsed = now - countUpFrom
            ticks += countUpFrom + (if (elapsed < TIMER_MAX_MS) TIMER_MAX_MS else (elapsed / HOUR_MS + 1) * HOUR_MS)
        }

        val dueTier = tiers.firstOrNull { it.second.trim().equals("due", ignoreCase = true) }?.first
        val fallbackLine =
            if (mood == Mood.TIER_DUE && dueTier != null) {
                context.getString(R.string.boney_label_tier_releasing, dueTier)
            } else {
                context.getString(mood.label)
            }

        return Snapshot(
            mood = mood,
            title = title.ifBlank { fallbackLine },
            caption = caption,
            sticker = sticker.ifBlank { context.getString(mood.sticker) },
            count = prefs.text(KEY_COUNT).trim(),
            tiers = tiers,
            action = action,
            countdownTo = countdownTo,
            countUpFrom = countUpFrom,
            nextTick = ticks.filter { it > now }.minOrNull(),
        )
    }

    /** `boney_timeline`: `[{"at": epoch ms, "boney_state", ...}]`, earliest first; missing fields keep [base]. */
    private fun parseTimeline(json: String, base: Fields): List<Pair<Long, Fields>> {
        if (json.isBlank()) return emptyList()
        return try {
            val array = JSONArray(json)
            (0 until array.length())
                .mapNotNull { i ->
                    val o = array.optJSONObject(i) ?: return@mapNotNull null
                    val at = toEpochMillis(o.optLong("at", 0L))
                    if (at <= 0) return@mapNotNull null
                    at to
                        Fields(
                            state = o.optString(KEY_STATE, base.state),
                            title = o.optString(KEY_TITLE, base.title),
                            caption = o.optString(KEY_CAPTION, base.caption),
                            sticker = o.optString(KEY_STICKER, base.sticker),
                            button = o.optString(KEY_BUTTON, base.button),
                        )
                }.sortedBy { it.first }
        } catch (_: JSONException) {
            emptyList()
        }
    }

    /** When this exact (state, due) pair was first rendered; persisted across process deaths. */
    private fun observedSince(context: Context, state: String, dueAt: Long, now: Long): Long {
        val native = context.getSharedPreferences(NATIVE_PREFS, Context.MODE_PRIVATE)
        val stamp = "$state@$dueAt"
        if (native.getString(SEEN_STAMP, null) == stamp) return native.getLong(SEEN_SINCE, now)
        native.edit().putString(SEEN_STAMP, stamp).putLong(SEEN_SINCE, now).apply()
        return now
    }

    private fun views(context: Context, options: Bundle, s: Snapshot, now: Long): RemoteViews {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            @Suppress("DEPRECATION")
            val reported = options.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES)
            val sizes = reported?.takeIf { it.isNotEmpty() }?.distinct()?.take(MAX_SIZES) ?: DEFAULT_SIZES
            return RemoteViews(sizes.associateWith { build(context, s, it.width, it.height, now) })
        }
        // Portrait size: narrowest width, tallest height.
        val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH).takeIf { it > 0 } ?: 110
        val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT).takeIf { it > 0 } ?: 110
        return build(context, s, width.toFloat(), height.toFloat(), now)
    }

    private fun layoutFor(widthDp: Float, heightDp: Float) =
        when {
            widthDp >= 220f && heightDp >= 320f -> Layout.LARGE
            widthDp >= 220f -> Layout.MEDIUM
            else -> Layout.SMALL
        }

    /** Device pixels per art pixel: the largest whole number that fits Boney's slot. */
    private fun boneyScale(layout: Layout, widthDp: Float, heightDp: Float, tierRows: Int, density: Float): Int {
        val (slotW, slotH, capDp) =
            when (layout) {
                Layout.SMALL -> Triple(widthDp - 24f, heightDp - 24f - 50f, 4.5f)
                Layout.MEDIUM -> Triple((widthDp - 40f) * 0.42f, heightDp - 32f, 5f)
                Layout.LARGE ->
                    Triple((widthDp - 44f) * 0.45f, heightDp - 36f - 28f - 16f - tierRows * 37f - 56f, 6f)
            }
        val dpPerPixel = minOf(slotW / BONEY_W, slotH / BONEY_H, capDp)
        return max(1, floor(dpPerPixel * density).toInt())
    }

    private fun build(context: Context, s: Snapshot, widthDp: Float, heightDp: Float, now: Long): RemoteViews {
        val layout = layoutFor(widthDp, heightDp)
        val rv = RemoteViews(context.packageName, layout.res)
        val color = context.getColor(s.mood.color)
        val density = context.resources.displayMetrics.density
        val tierRows = minOf(s.tiers.size, MAX_TIERS)

        rv.setInt(android.R.id.background, "setBackgroundResource", s.mood.background)
        rv.setOnClickPendingIntent(android.R.id.background, openApp(context))

        setPixelArt(
            context, rv, R.id.boney_image, s.mood.art, s.mood.png, BONEY_W, BONEY_H,
            boneyScale(layout, widthDp, heightDp, tierRows, density),
        )
        rv.setContentDescription(
            R.id.boney_image,
            context.getString(R.string.boney_image_description, s.title),
        )

        when (layout) {
            Layout.SMALL -> {
                bindCount(context, rv, s, color, density)
                rv.setTextViewText(R.id.boney_label, s.title)
            }
            Layout.MEDIUM -> {
                bindStatus(context, rv, s, color, now, showCaption = heightDp >= MEDIUM_CAPTION_MIN_DP)
                bindButton(context, rv, s)
            }
            Layout.LARGE -> {
                bindCount(context, rv, s, color, density)
                bindStatus(context, rv, s, color, now, showCaption = true)
                bindTiers(context, rv, s)
                bindButton(context, rv, s)
            }
        }
        return rv
    }

    private fun bindCount(context: Context, rv: RemoteViews, s: Snapshot, color: Int, density: Float) {
        if (s.count.isEmpty()) {
            rv.setViewVisibility(R.id.boney_count_row, View.GONE)
            return
        }
        rv.setViewVisibility(R.id.boney_count_row, View.VISIBLE)
        rv.setTextViewText(R.id.boney_count, s.count)
        rv.setContentDescription(
            R.id.boney_count_row,
            context.resources.getQuantityString(
                R.plurals.boney_count_description, s.count.toIntOrNull() ?: 0, s.count,
            ),
        )
        setPixelArt(
            context, rv, R.id.boney_heart, R.drawable.boney_px_heart, R.drawable.boney_heart,
            HEART_W, HEART_H, max(1, floor(HEART_DP_PER_PIXEL * density).toInt()),
        )
        rv.setInt(R.id.boney_heart, "setColorFilter", color)
    }

    private fun bindStatus(
        context: Context,
        rv: RemoteViews,
        s: Snapshot,
        color: Int,
        now: Long,
        showCaption: Boolean,
    ) {
        rv.setTextViewText(R.id.boney_sticker, s.sticker)
        rv.setTextColor(R.id.boney_sticker, color)
        rv.setInt(
            R.id.boney_sticker,
            "setBackgroundResource",
            if (s.mood.settled) R.drawable.boney_pill_raised else R.drawable.boney_pill_void,
        )

        // Counting down to the next release, or up since a due one, live in the launcher.
        val timerFrom = if (s.countdownTo > 0) s.countdownTo else s.countUpFrom
        val span = if (s.countdownTo > 0) s.countdownTo - now else now - s.countUpFrom
        if (timerFrom > 0 && span < TIMER_MAX_MS) {
            rv.setChronometer(R.id.boney_chrono, SystemClock.elapsedRealtime() + (timerFrom - now), null, true)
            rv.setChronometerCountDown(R.id.boney_chrono, s.countdownTo > 0)
            rv.setTextColor(R.id.boney_chrono, color)
            rv.setViewVisibility(R.id.boney_chrono, View.VISIBLE)
            rv.setViewVisibility(R.id.boney_title, View.GONE)
        } else {
            val title =
                if (timerFrom > 0) {
                    context.getString(R.string.boney_days_hours, span / DAY_MS, (span % DAY_MS) / HOUR_MS)
                } else {
                    s.title
                }
            rv.setChronometer(R.id.boney_chrono, SystemClock.elapsedRealtime(), null, false)
            rv.setViewVisibility(R.id.boney_chrono, View.GONE)
            rv.setViewVisibility(R.id.boney_title, View.VISIBLE)
            rv.setTextViewText(R.id.boney_title, title)
            rv.setTextColor(R.id.boney_title, color)
        }
        val hasTitle = timerFrom > 0 || s.title.isNotBlank()
        rv.setViewVisibility(R.id.boney_title_box, if (hasTitle) View.VISIBLE else View.GONE)

        rv.setTextViewText(R.id.boney_caption, s.caption)
        rv.setViewVisibility(
            R.id.boney_caption,
            if (showCaption && s.caption.isNotBlank()) View.VISIBLE else View.GONE,
        )
    }

    private fun bindTiers(context: Context, rv: RemoteViews, s: Snapshot) {
        val rows = intArrayOf(R.id.boney_tier_row_1, R.id.boney_tier_row_2, R.id.boney_tier_row_3)
        val labels = intArrayOf(R.id.boney_tier_label_1, R.id.boney_tier_label_2, R.id.boney_tier_label_3)
        val values = intArrayOf(R.id.boney_tier_value_1, R.id.boney_tier_value_2, R.id.boney_tier_value_3)
        val due = context.getColor(R.color.boney_flatline)
        val muted = context.getColor(R.color.boney_ash)
        for (i in 0 until MAX_TIERS) {
            val tier = s.tiers.getOrNull(i)
            if (tier == null) {
                rv.setViewVisibility(rows[i], View.GONE)
                continue
            }
            rv.setViewVisibility(rows[i], View.VISIBLE)
            rv.setTextViewText(labels[i], tier.first)
            rv.setTextViewText(values[i], tier.second)
            rv.setTextColor(values[i], if (tier.second.trim().equals("due", ignoreCase = true)) due else muted)
        }
    }

    private fun bindButton(context: Context, rv: RemoteViews, s: Snapshot) {
        val checking = s.mood == Mood.CHECKING
        if (!checking && s.action == Action.NONE) {
            rv.setViewVisibility(R.id.boney_button, View.GONE)
            return
        }
        rv.setViewVisibility(R.id.boney_button, View.VISIBLE)
        val primary = !checking && s.action != Action.OPEN_APP
        rv.setTextViewText(
            R.id.boney_button,
            context.getString(if (checking) R.string.boney_checking else s.action.label),
        )
        rv.setInt(
            R.id.boney_button,
            "setBackgroundResource",
            if (primary) R.drawable.boney_button_pulse else R.drawable.boney_button_raised,
        )
        rv.setTextColor(
            R.id.boney_button,
            context.getColor(
                when {
                    primary -> R.color.boney_void
                    checking -> R.color.boney_sub
                    else -> R.color.boney_bone
                },
            ),
        )
        rv.setOnClickPendingIntent(
            R.id.boney_button,
            if (primary) HomeWidgetBackgroundIntent.getBroadcast(context, CHECK_IN_URI) else openApp(context),
        )
    }

    private fun openApp(context: Context): PendingIntent =
        HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, OPEN_URI)

    /**
     * Shows pixel art at exactly [scale] device pixels per art pixel. Android 12+ sizes the view in
     * pixels and draws the resource unfiltered (no bitmap crosses the binder); older versions get a
     * pre-scaled bitmap the view shows 1:1.
     */
    private fun setPixelArt(
        context: Context,
        rv: RemoteViews,
        viewId: Int,
        unfilteredRes: Int,
        pngRes: Int,
        gridW: Int,
        gridH: Int,
        scale: Int,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            rv.setImageViewResource(viewId, unfilteredRes)
            rv.setViewLayoutWidth(viewId, (gridW * scale).toFloat(), TypedValue.COMPLEX_UNIT_PX)
            rv.setViewLayoutHeight(viewId, (gridH * scale).toFloat(), TypedValue.COMPLEX_UNIT_PX)
        } else {
            rv.setImageViewBitmap(viewId, scaledArt(context, pngRes, gridW, gridH, scale))
        }
    }

    private fun scaledArt(context: Context, pngRes: Int, gridW: Int, gridH: Int, scale: Int): Bitmap {
        val src = BitmapFactory.decodeResource(context.resources, pngRes, BitmapFactory.Options().apply { inScaled = false })
        val cell = src.width / gridW
        val width = gridW * scale
        val height = gridH * scale
        val pixels = IntArray(width * height)
        for (gy in 0 until gridH) {
            for (gx in 0 until gridW) {
                val argb = src.getPixel(gx * cell + cell / 2, gy * cell + cell / 2)
                if (Color.alpha(argb) == 0) continue
                for (y in gy * scale until (gy + 1) * scale) {
                    pixels.fill(argb, y * width + gx * scale, y * width + (gx + 1) * scale)
                }
            }
        }
        src.recycle()
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888).apply {
            density = context.resources.displayMetrics.densityDpi
        }
    }

    private fun parseTiers(json: String): List<Pair<String, String>> {
        if (json.isBlank()) return emptyList()
        return try {
            val array = JSONArray(json)
            (0 until minOf(array.length(), MAX_TIERS)).mapNotNull { i ->
                array.optJSONObject(i)?.let { it.optString("label") to it.optString("value") }
            }
        } catch (_: JSONException) {
            emptyList()
        }
    }

    private fun scheduleTick(context: Context, at: Long?) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val intent = Intent(context, BoneyWidgetProvider::class.java).setAction(ACTION_TICK)
        val pending =
            PendingIntent.getBroadcast(
                context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        if (at == null) {
            alarms.cancel(pending)
        } else {
            // RTC (not RTC_WAKEUP): delivered once the phone is awake, which is when the widget is seen.
            alarms.setWindow(AlarmManager.RTC, at, TICK_WINDOW_MS, pending)
        }
    }

    private fun SharedPreferences.text(key: String): String =
        when (val value = all[key]) {
            null -> ""
            is String -> value
            else -> value.toString()
        }

    /** An epoch timestamp in millis; Dart may write seconds or millis, as an int, double or string. */
    private fun SharedPreferences.epochMillis(key: String): Long {
        val raw =
            when (val value = all[key]) {
                is Long ->
                    if (getBoolean(DOUBLE_PREFIX + key, false)) {
                        java.lang.Double.longBitsToDouble(value).toLong()
                    } else {
                        value
                    }
                is Int -> value.toLong()
                is Float -> value.toLong()
                is String -> value.trim().toDoubleOrNull()?.toLong() ?: 0L
                else -> 0L
            }
        return toEpochMillis(raw)
    }

    private fun toEpochMillis(value: Long): Long =
        when {
            value <= 0 -> 0L
            value >= EPOCH_MILLIS_FROM -> value
            else -> value * 1000
        }
}
