import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing material, deliberately kept out of the repository: either a
// keystore.properties next to settings.gradle.kts, or the matching MDS_
// environment variables for a build server. Both are read the same way, the file
// winning where it has a value.
//
// A checkout with neither still builds. The release APK simply comes out as
// app-release-unsigned.apk, which is honest about what it is, and nobody needs a
// keystore to compile the project or run the tests. See README, "Signing".
val signingProperties = Properties().apply {
    val file = rootProject.file("keystore.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun signingSetting(key: String, variable: String): String? =
    (signingProperties.getProperty(key) ?: System.getenv(variable))?.takeIf { it.isNotBlank() }

val releaseStore = signingSetting("storeFile", "MDS_STORE_FILE")
val releaseStorePassword = signingSetting("storePassword", "MDS_STORE_PASSWORD")
val releaseKeyAlias = signingSetting("keyAlias", "MDS_KEY_ALIAS")
// Left out means "the same as the keystore password", which is what keytool
// itself offers when it says "RETURN if same as keystore password". Asking for it
// twice would only put a second copy of the same secret in the same file.
val releaseKeyPassword = signingSetting("keyPassword", "MDS_KEY_PASSWORD") ?: releaseStorePassword
val canSignRelease = releaseStore != null &&
    releaseStorePassword != null &&
    releaseKeyAlias != null &&
    releaseKeyPassword != null

android {
    namespace = "pl.wojas.macdroidsync"
    compileSdk = 36

    defaultConfig {
        applicationId = "pl.wojas.macdroidsync"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
    }

    buildFeatures {
        viewBinding = true
        // BuildConfig.DEBUG gates the share intent diagnostics.
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        // Only registered when there is something to put in it, so that the
        // absence of a keystore is not a configuration error.
        if (canSignRelease) {
            create("release") {
                storeFile = rootProject.file(releaseStore!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Signed when the material is there, left alone when it is not:
            // an unsigned APK that says so beats a build that refuses to run.
            if (canSignRelease) signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.security:security-crypto:1.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    testImplementation("junit:junit:4.13.2")
    // android.jar ships stubbed org.json classes, so unit tests need a real one.
    testImplementation("org.json:json:20250107")
}
