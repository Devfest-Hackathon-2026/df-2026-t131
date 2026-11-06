plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// google-services.json（メンバー1から受け取る。コミットしない）があるときだけ Firebase の設定を読む。
// 無くてもビルドはでき、アプリは FCM の警報を受けずに動く。
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// ずんだもんの声（VOICEVOX CORE）。tool/fetch_voicevox.sh で app/mobile/vendor/voicevox に取ってあるときだけ入れる。
// 無ければ代わりの部品（src/novoicevox）が入り、端末の声（Google）で話す。大きいファイルは Git に入れない。
val voicevoxDir = file("../../vendor/voicevox")
val hasVoicevox = file("${voicevoxDir}/maven").isDirectory

repositories {
    if (hasVoicevox) {
        maven { url = uri("${voicevoxDir}/maven") }
    }
}

android {
    namespace = "jp.dfhack26.mobile"

    sourceSets["main"].apply {
        if (hasVoicevox) {
            java.srcDir("src/voicevox/kotlin")
            jniLibs.srcDir("${voicevoxDir}/jniLibs")
            assets.srcDir("${voicevoxDir}/assets")
        } else {
            java.srcDir("src/novoicevox/kotlin")
        }
    }

    packaging {
        // VOICEVOX と Flutter の部品が同じ C++ の実行用ライブラリを持っている
        jniLibs.pickFirsts += "**/libc++_shared.so"
        // VOICEVOX が使う jakarta の部品どうしで、同じ名前の説明書きが重なる
        resources.pickFirsts += listOf("META-INF/NOTICE.md", "META-INF/LICENSE.md")
    }
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "jp.dfhack26.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // リーダー決定（11/5）：minSdk 26
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // VOICEVOX のクラスを縮小で消さない（proguard-rules.pro）
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    if (hasVoicevox) {
        implementation("jp.hiroshiba.voicevoxcore:voicevoxcore-android:0.17.1")
    }
    testImplementation("junit:junit:4.13.2")
}
