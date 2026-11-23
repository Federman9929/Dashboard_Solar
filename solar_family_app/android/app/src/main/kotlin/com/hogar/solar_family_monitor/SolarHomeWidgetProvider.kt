package com.hogar.solar_family_monitor

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

class SolarHomeWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.solar_widget_layout).apply {
                val socText = widgetData.getString("soc_text", "--%") ?: "--%"
                val socHex = widgetData.getString("soc_color", "#00E676") ?: "#00E676"
                val battState = widgetData.getString("battery_state_text", "En espera") ?: "En espera"
                val battPower = widgetData.getString("battery_power_text", "0 W • -- V") ?: "0 W • -- V"
                val pvPower = widgetData.getString("pv_power_text", "0 W") ?: "0 W"
                val loadPower = widgetData.getString("load_power_text", "0 W") ?: "0 W"
                val savings = widgetData.getString("today_savings_text", "\$0 COP") ?: "\$0 COP"
                val updatedAt = widgetData.getString("updated_at_text", "--:--") ?: "--:--"

                setTextViewText(R.id.widget_soc_value, socText)
                setTextColor(R.id.widget_soc_value, parseSafeColor(socHex))
                setTextViewText(R.id.widget_battery_state, battState)
                setTextViewText(R.id.widget_battery_power, battPower)
                setTextViewText(R.id.widget_pv_power, pvPower)
                setTextViewText(R.id.widget_load_power, loadPower)
                setTextViewText(R.id.widget_today_savings, savings)
                setTextViewText(R.id.widget_updated_at, updatedAt)

                val launchIntent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                )
                setOnClickPendingIntent(R.id.widget_root, launchIntent)

                val refreshIntent = HomeWidgetBackgroundIntent.getBroadcast(
                    context,
                    Uri.parse("solarwidget://refresh"),
                )
                setOnClickPendingIntent(R.id.widget_refresh_btn, refreshIntent)
            }
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    private fun parseSafeColor(hex: String): Int {
        return try {
            Color.parseColor(hex)
        } catch (_: Exception) {
            Color.parseColor("#00E676")
        }
    }
}
