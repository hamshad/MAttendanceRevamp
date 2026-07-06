# Flutter wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# ucrop uses okhttp3/okio optionally — suppress missing class warnings
-dontwarn okhttp3.Call
-dontwarn okhttp3.Dispatcher
-dontwarn okhttp3.OkHttpClient
-dontwarn okhttp3.Request$Builder
-dontwarn okhttp3.Request
-dontwarn okhttp3.Response
-dontwarn okhttp3.ResponseBody
-dontwarn okio.BufferedSource
-dontwarn okio.Okio
-dontwarn okio.Sink

# Flutter deferred components (Play Store split install) — not used in this app
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task



# Google Sign-In added by Arshad
-keep class com.google.android.gms.** { *; }
-keep class com.google.firebase.** { *; }
-dontwarn com.google.android.gms.**
-keep class com.google.android.gms.auth.** { *; }
-keep class com.google.android.gms.common.** { *; }