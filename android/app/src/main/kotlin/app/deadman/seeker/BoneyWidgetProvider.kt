package app.deadman.seeker

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Boney, the home-screen widget. One provider serves the small (2x2), medium (4x2) and large
 * (4x4) layouts; Dart refreshes it with `HomeWidget.updateWidget(androidName: 'BoneyWidgetProvider')`.
 */
class BoneyWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        BoneyWidget.render(context, appWidgetManager, appWidgetIds, widgetData)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        BoneyWidget.render(
            context,
            appWidgetManager,
            intArrayOf(appWidgetId),
            HomeWidgetPlugin.getData(context),
        )
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == BoneyWidget.ACTION_TICK) {
            BoneyWidget.renderAll(context)
            return
        }
        super.onReceive(context, intent)
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        BoneyWidget.cancelTick(context)
    }
}
