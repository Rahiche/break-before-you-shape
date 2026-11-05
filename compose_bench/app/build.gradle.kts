plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "dev.breakfirst.compose"
    compileSdk = 37

    defaultConfig {
        applicationId = "dev.breakfirst.compose"
        minSdk = 24
        targetSdk = 37
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Benchmarks only: signed with the debug key.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    androidResources {
        noCompress += listOf("txt", "ttf", "bfw", "bfm")
    }
}

dependencies {
    // TextMeasurer and the font resolver are all the harness needs.
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui.text)
}
