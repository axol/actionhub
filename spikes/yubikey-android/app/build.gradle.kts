plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "li.taurusag.yubikeyspike"
    compileSdk = 34

    defaultConfig {
        applicationId = "li.taurusag.yubikeyspike"
        minSdk = 26
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
    implementation("com.yubico.yubikit:android:2.8.0")
    implementation("com.yubico.yubikit:fido:2.8.0")
}
