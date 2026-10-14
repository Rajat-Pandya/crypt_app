plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.example.crypt_app"
    compileSdk = 36
    
    // ✅ 16 KB Page Size Support: Use NDK r28 or later
    ndkVersion = "28.0.12433566"

    compileOptions {
        // ✅ FIX: MATCH KOTLIN
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17

        isCoreLibraryDesugaringEnabled = true
    }

    // Fixed: Use compilerOptions DSL instead of deprecated kotlinOptions
    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    defaultConfig {
        applicationId = "com.example.crypt_app"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        // ✅ 16 KB Page Size Support: Enable 16 KB ELF alignment
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
        
        // Add linker flags for 16 KB alignment
        externalNativeBuild {
            cmake {
                cppFlags += "-Wl,-z,max-page-size=16384"
                cFlags += "-Wl,-z,max-page-size=16384"
            }
        }
    }
    
    // ✅ 16 KB Page Size Support: Configure native library packaging
    // Fixed: Use packaging instead of deprecated packagingOptions
    packaging {
        jniLibs {
            useLegacyPackaging = false
            // Fixed: Use proper Kotlin DSL syntax with listOf
            pickFirsts += listOf("**/libc++_shared.so")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}

flutter {
    source = "../.."
}
apply(plugin = "com.google.gms.google-services")