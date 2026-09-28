# LiteRT resolves delegates and model files reflectively in places. Keep the
# interpreter API and the GPU delegate entry points.
-keep class org.tensorflow.lite.** { *; }
-keep class com.google.ai.edge.litert.** { *; }
-dontwarn org.tensorflow.lite.**
-dontwarn com.google.ai.edge.litert.**
