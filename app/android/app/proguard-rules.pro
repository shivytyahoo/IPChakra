# IPChakra ProGuard / R8 rules (release builds only)
#
# Pattern copied from YouGlideTube (youglidetube-v2/app/build.gradle.kts
# + app/proguard-rules.pro): minify + shrinkResources ON for release,
# no obfuscation so release stack traces stay readable without a
# mapping file, and Log.v/d stripped from release binaries.
# https://developer.android.com/build/shrink-code

## Open-source readable stack traces (no de-obfuscation pipeline required)
-dontobfuscate
-keepattributes SourceFile,LineNumberTable

## Strip debug and verbose logging from release binaries
-assumenosideeffects class android.util.Log {
    public static boolean isLoggable(java.lang.String, int);
    public static int v(...);
    public static int d(...);
}

## Flutter engine: the engine reaches these classes from native code
## (libflutter.so) via JNI, so static references alone cannot prove
## they are alive. Standard rules from the Flutter deployment docs.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }

## App entry point: MainActivity is named in the manifest, and its
## MethodChannel handler ("ipchakra/system_settings") is invoked by
## the engine, so keep the whole class.
-keep class com.ipchakra.ipchakra.MainActivity { *; }

## flutter_v2ray_client (vendored): Xray core over Go mobile bind.
## libv2ray.aar already ships the go./libv2ray. rules in its own
## proguard.txt (AGP applies AAR consumer rules automatically); they
## are repeated here so the tunnel survives even if the AAR is swapped.
## Go calls back into Java through go.Seq proxies (CoreCallbackHandler)
## and native libv2jni.so resolves libv2ray.* by name from JNI.
-keep class go.** { *; }
-keep class libv2ray.** { *; }
-keep class dev.amirzr.flutter_v2ray_client.** { *; }

## openvpn_flutter (vendored, ics-openvpn fork via JitPack): the plugin
## calls de.blinkt.openvpn statically, but the OpenVPN core reaches its
## own classes from native code (libopenvpn.so) and its services are
## started by the system. Keep the whole tree; the native methods
## themselves are also kept by proguard-android-optimize.txt.
-keep class de.blinkt.openvpn.** { *; }
-keep class id.laskarmedia.openvpn_flutter.** { *; }

## wireguard_flutter (vendored): GoBackend (com.wireguard.android:tunnel)
## bridges to libwg-go.so through JNI, and Config.parse is driven by
## the plugin. Keep the tunnel library and the plugin package whole.
-keep class com.wireguard.** { *; }
-keep class billion.group.wireguard_flutter.** { *; }

## Play Core split-install (from R8's generated missing_rules.txt,
## 2026-11-07): the Flutter engine's deferred-components code
## references these classes, but the app ships no Play Core library
## and never uses deferred components / Play Store splits, so there
## is nothing to keep — suppress the warnings only.
-dontwarn com.google.android.play.core.**

## Warning suppressions for the kept native-bridge libraries (their
## internals are kept above; these only silence R8 noise).
-dontwarn com.wireguard.**
-dontwarn de.blinkt.openvpn.**
-dontwarn libv2ray.**
-dontwarn go.**
