package com.mattendance.mattendance_mobile

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build

class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)

            // Channel for flutter_background_service field tracking foreground service.
            // Must exist before the service calls startForeground(), including when
            // Android auto-restarts the sticky service after process death.
            manager.createNotificationChannel(
                NotificationChannel(
                    "mattendance_field_tracking",
                    "Field Tracking",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Background location tracking for field employees"
                    setShowBadge(false)
                }
            )
        }
    }
}
