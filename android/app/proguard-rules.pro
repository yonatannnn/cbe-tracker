# The app bundles only ML Kit's Latin text recognizer. The plugin's initialize()
# references the other language recognizers too — Chinese, Devanagari, Japanese,
# Korean — whose classes we don't ship, so R8 aborts the release build over the
# missing references. We never call those recognizers (CBE receipts are Latin),
# so tell R8 not to warn about them rather than pulling in four unused models.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
