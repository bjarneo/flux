plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "org.omarchy.flux"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.omarchy.flux"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
        resources.excludes += "/META-INF/versions/9/OSGI-INF/MANIFEST.MF"
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    debugImplementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)

    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)

    // sshj declares bouncycastle at runtime scope. Name bcprov again so that
    // the certificate code can compile against it.
    implementation(libs.sshj)
    implementation(libs.bouncycastle)
    implementation(libs.bouncycastle.pkix)
    implementation(libs.slf4j.android)

    // Scan text: CameraX for the preview and the frames, and the ML Kit Latin
    // model bundled in the APK, so recognition runs on the phone.
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(libs.androidx.camera.mlkit.vision)
    implementation(libs.mlkit.text.recognition)
    // QR and barcodes with the bundled model, and the Play services document scanner.
    implementation(libs.mlkit.barcode.scanning)
    implementation(libs.mlkit.document.scanner)

    // Approve sudo with a fingerprint: BiometricPrompt signs with a key in
    // the Android Keystore. docs/approve.md is the design.
    implementation(libs.androidx.biometric)
    implementation(libs.androidx.fragment.ktx)

    testImplementation(libs.junit)
    testImplementation(libs.slf4j.nop)
}

configurations.matching { it.name == "testRuntimeClasspath" }.configureEach {
    exclude(group = "uk.uuid.slf4j", module = "slf4j-android")
}
