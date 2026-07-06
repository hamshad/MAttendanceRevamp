allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Force all library plugins that declare compileSdk < 34 to use 34.
// This avoids needing an android-31 SDK platform which may be incomplete.
subprojects {
    pluginManager.withPlugin("com.android.library") {
        extensions.configure<com.android.build.gradle.LibraryExtension> {
            if (compileSdk != null && compileSdk!! < 34) {
                compileSdk = 34
            }
        }
    }
}

// Kotlin 2.0+ elevated String.toLowerCase(Locale) to DeprecationLevel.ERROR,
// breaking older Flutter plugins (e.g. nfc_manager 3.5.0). Pin subprojects to
// language version 1.9 so deprecated APIs are warnings, not errors.
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            languageVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_1_9)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
