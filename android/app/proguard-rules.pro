# The app bundles only ML Kit's Latin text recognizer. The plugin's initialize()
# references the other language recognizers too — Chinese, Devanagari, Japanese,
# Korean — whose classes we don't ship, so R8 aborts the release build over the
# missing references. We never call those recognizers (CBE receipts are Latin),
# so tell R8 not to warn about them rather than pulling in four unused models.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# ML Kit discovers registrars by class name and invokes their no-argument
# constructors reflectively. R8 full mode otherwise strips those constructors,
# leaving OCR unable to initialize in release builds.
# https://developer.android.com/topic/performance/app-optimization/full-mode
-keep class com.google.mlkit.** implements com.google.firebase.components.ComponentRegistrar {
    public <init>();
}
