// Pushify: open-source, self-hostable alternative to RevenueCat. Same SDK API.
// This file: builds the native Android Purchase Test Lab sample without committing app keys.
// Docs: https://pushify.app/docs/sdks/android   Migrate from RevenueCat: https://pushify.app/docs/migrate
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val publicKey = providers.gradleProperty("PUSHIFY_PUBLIC_APP_KEY").orElse("").get()
    .replace("\\", "\\\\").replace("\"", "\\\"")
val apiBaseUrl = providers.gradleProperty("PUSHIFY_API_BASE_URL").orElse("https://api.pushify.app").get()
    .replace("\\", "\\\\").replace("\"", "\\\"")

android {
    namespace = "app.pushify.testlab"
    compileSdk = 36
    defaultConfig {
        applicationId = "app.pushify.testlab"
        minSdk = 23
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("String", "PUSHIFY_PUBLIC_APP_KEY", "\"$publicKey\"")
        buildConfigField("String", "PUSHIFY_API_BASE_URL", "\"$apiBaseUrl\"")
    }
    buildFeatures { buildConfig = true }
}

dependencies { implementation(project(":pushify")) }
