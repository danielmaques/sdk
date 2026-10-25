plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.pushify.sdk"
    compileSdk = 36
    defaultConfig { minSdk = 23 }
}

dependencies {
    implementation("com.android.billingclient:billing:9.1.0")
    implementation("com.android.installreferrer:installreferrer:2.2")
}
