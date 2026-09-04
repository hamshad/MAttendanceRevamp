import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.mattendance.mattendance_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    signingConfigs {
        getByName("debug") {
            keyAlias = "mattendance"
            keyPassword = "android"
            storeFile = file("${System.getProperty("user.home")}/.android/mattendance_debug.keystore")
            storePassword = "android"
        }
        create("release") {
            keyAlias = "mattendance"
            keyPassword = "android"
            storeFile = file("${System.getProperty("user.home")}/.android/mattendance_debug.keystore")
            storePassword = "android"
        }
    }

    defaultConfig {
        applicationId = "com.mattendance.mattendance_mobile"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

// Patch flutter_background_service_android v6.3.1 BackgroundService.java:
// PendingIntent needs FLAG_IMMUTABLE on API 31+ or Android 12+ crashes.
// Runs before build — works on any machine.
val patchBgService by tasks.registering {
    doLast {
        val cacheDir = File(System.getProperty("user.home"), ".pub-cache/hosted/pub.dev")
        val pkg = cacheDir.listFiles()?.firstOrNull { it.name.startsWith("flutter_background_service_android-") }
        if (pkg == null) { logger.warn("bg service pkg not found"); return@doLast }
        val file = File(pkg, "android/src/main/java/id/flutter/flutter_background_service/BackgroundService.java")
        if (!file.exists()) { logger.warn("BackgroundService.java not found"); return@doLast }

        var text = file.readText()
        val oldLine = "int flags = PendingIntent.FLAG_CANCEL_CURRENT;"
        val newLine = "int flags = PendingIntent.FLAG_CANCEL_CURRENT | PendingIntent.FLAG_IMMUTABLE;"
        if (text.contains(oldLine) && !text.contains("FLAG_IMMUTABLE")) {
            text = text.replace(oldLine, newLine)
            file.writeText(text)
            logger.lifecycle("Patched BackgroundService.java — added FLAG_IMMUTABLE")
        } else {
            logger.lifecycle("BackgroundService.java already patched or unrecognized")
        }
    }
}
afterEvaluate {
    tasks.matching { it.name.contains("compile") && it.name.contains("Java") }.configureEach {
        dependsOn(patchBgService)
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // Direct access to androidx.work from app Kotlin (ContainmentAlarmReceiver
    // enqueues the workmanager plugin's BackgroundWorker headlessly).
    // Version must match the workmanager plugin's (workmanager_android 0.9.0+2 → 2.10.2).
    implementation("androidx.work:work-runtime:2.10.2")
}