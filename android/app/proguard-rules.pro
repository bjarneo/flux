-keepattributes *Annotation*, InnerClasses, Signature

# kotlinx.serialization
-dontnote kotlinx.serialization.**
-keepclassmembers class kotlinx.serialization.json.** { *; }

# BouncyCastle maps algorithm names to classes as strings.
-keep class org.bouncycastle.jce.provider.** { *; }
-keep class org.bouncycastle.jcajce.provider.** { *; }
-dontwarn org.bouncycastle.**
-dontwarn net.schmizz.**
-dontwarn com.hierynomus.**
-keep class uk.uuid.slf4j.android.** { *; }
