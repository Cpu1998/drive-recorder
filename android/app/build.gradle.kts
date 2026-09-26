plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 高德 SDK 强制升级到最新（2026-09-23 发布）。
// 背景：amap_map 1.0.15 插件捆绑 3dmap 10.1.200（老引擎），在新 Android
// 上地图原生视图创建/首帧渲染时 native 崩溃（进程静默死亡，无 Dart 异常）。
// 11.3.100 包含 16KB page 对齐与 Android 15/16 适配。插件 Java 侧只用
// 稳定公开 API（TextureMapView/AMap/BitmapDescriptorFactory 等），
// 强升后由编译期验证兼容性。
configurations.all {
    resolutionStrategy {
        force("com.amap.api:3dmap-location-search:11.3.100_loc11.3.000_sea9.8.1")
    }
}

android {
    namespace = "com.zhangkeyou.drive_recorder"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.zhangkeyou.drive_recorder"
        // firebase_core 3.x 要求 minSdk >= 23；高德地图/定位 SDK 同样兼容
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // ForegroundService 的 NotificationCompat 依赖
    implementation("androidx.core:core-ktx:1.13.1")
}
