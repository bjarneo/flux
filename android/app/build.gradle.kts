plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

val releaseKeystore = providers.environmentVariable("KEYSTORE_FILE").orNull
val releaseStorePassword = providers.environmentVariable("KEYSTORE_PASSWORD").orNull
val releaseKeyAlias = providers.environmentVariable("KEY_ALIAS").orNull
val releaseKeyPassword = providers.environmentVariable("KEY_PASSWORD").orNull
val releaseCredentials = listOf(releaseKeystore, releaseStorePassword, releaseKeyAlias, releaseKeyPassword)
require(releaseCredentials.all { it.isNullOrBlank() } || releaseCredentials.all { !it.isNullOrBlank() }) {
    "Set KEYSTORE_FILE, KEYSTORE_PASSWORD, KEY_ALIAS, and KEY_PASSWORD together."
}
val fluxVersionCode = providers.environmentVariable("FLUX_VERSION_CODE").orElse("1").get().toInt()
require(fluxVersionCode in 1..2100000000) { "FLUX_VERSION_CODE must be between 1 and 2100000000." }

// The userspace tailnet node is a Go executable. It ships as
// libflux_tsnet.so so that Android extracts it and the app can run it.
val tsnetDir = rootProject.layout.projectDirectory.dir("tsnet")
val tsnetJniLibs = layout.buildDirectory.dir("tsnet/jniLibs").get().asFile
val buildTsnet by tasks.registering(Exec::class) {
    inputs.dir(tsnetDir)
    outputs.dir(tsnetJniLibs)
    commandLine(
        "sh",
        tsnetDir.file("build.sh").asFile.absolutePath,
        tsnetJniLibs.absolutePath,
        "arm64-v8a",
    )
}

android {
    namespace = "org.omarchy.flux"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.omarchy.flux"
        minSdk = 29
        targetSdk = 36
        versionCode = fluxVersionCode
        versionName = providers.environmentVariable("FLUX_VERSION").orElse("0.1.0").get()
    }

    signingConfigs {
        if (!releaseKeystore.isNullOrBlank()) {
            create("release") {
                storeFile = rootProject.file(releaseKeystore)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
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

    sourceSets.getByName("main").jniLibs.srcDir(tsnetJniLibs)

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
        resources.excludes += "/META-INF/versions/9/OSGI-INF/MANIFEST.MF"
        // The tailnet node is an executable, not a library that the app
        // links. Android runs it from the native library directory, so the
        // APK must keep the file extracted.
        jniLibs.useLegacyPackaging = true
    }
}

tasks.named("preBuild") { dependsOn(buildTsnet) }

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
