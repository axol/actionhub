plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "li.taurusag.actionhub.keyboard"
    compileSdk = 34

    defaultConfig {
        applicationId = "li.taurusag.actionhub.keyboard"
        minSdk = 28
        targetSdk = 34
        versionCode = 1
        versionName = "0.1"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.yubico.yubikit:android:2.8.0")
    implementation("com.yubico.yubikit:fido:2.8.0")
}
