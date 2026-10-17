import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

val pluginName = "AynThor"
val pluginPackageName = "org.godot.plugins.aynthor"

android {
    namespace = pluginPackageName
    compileSdk = 36

    defaultConfig {
        minSdk = 24
        manifestPlaceholders["godotPluginName"] = pluginName
        manifestPlaceholders["godotPluginPackageName"] = pluginPackageName
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
    compileOnly("org.godotengine:godot:4.5.1.stable")
}

val copyDebugAARToAddons by tasks.registering(Copy::class) {
    from("build/outputs/aar")
    include("plugin-debug.aar")
    rename("plugin-debug.aar", "$pluginName-debug.aar")
    into("../../bin/debug")
}

val copyReleaseAARToAddons by tasks.registering(Copy::class) {
    from("build/outputs/aar")
    include("plugin-release.aar")
    rename("plugin-release.aar", "$pluginName-release.aar")
    into("../../bin/release")
}

tasks.named("assemble").configure {
    finalizedBy(copyDebugAARToAddons)
    finalizedBy(copyReleaseAARToAddons)
}
