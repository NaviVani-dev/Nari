import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

val pluginName = "NariBridge"
val archiveName = "MusicService"
val pluginPackageName = "org.navivani.musicservice"

android {
    namespace = pluginPackageName
    compileSdk = 36
    buildFeatures {
        buildConfig = true
        aidl = true
    }

    defaultConfig {
        minSdk = 26
        manifestPlaceholders["godotPluginName"] = pluginName
        manifestPlaceholders["godotPluginPackageName"] = pluginPackageName
        buildConfigField("String", "GODOT_PLUGIN_NAME", "\"${pluginName}\"")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }
}

dependencies {
    implementation("org.godotengine:godot:4.5.1.stable")
    implementation("androidx.media3:media3-session:1.8.0")
    implementation("androidx.webkit:webkit:1.14.0")
}

val copyDebugAARToAddons by tasks.registering(Copy::class) {
    from("build/outputs/aar")
    include("plugin-debug.aar")
    rename("plugin-debug.aar", "$archiveName-debug.aar")
    into("../../bin/debug")
}

val copyReleaseAARToAddons by tasks.registering(Copy::class) {
    from("build/outputs/aar")
    include("plugin-release.aar")
    rename("plugin-release.aar", "$archiveName-release.aar")
    into("../../bin/release")
}

tasks.named("assemble").configure {
    finalizedBy(copyDebugAARToAddons)
    finalizedBy(copyReleaseAARToAddons)
}
