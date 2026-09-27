# 高德 SDK 11.3.100：内部可选引用（gnss 软定位 / FastMath），运行时按需加载
-dontwarn com.amap.ams.gnss.GnssSoftLocator
-dontwarn net.jafama.FastMath

# 高德 SDK 的 native 库通过 JNI 按类名反射 Java 类（.so 的 JNI_OnLoad 里
# FindClass/GetStaticMethodID）。R8 混淆改名后 FindClass 返回 null，
# 地图库加载即 SIGABRT：GLThread「java_class == null in call to
# GetStaticMethodID」，表现为打开轨迹详情进程立即死亡（debug 无 R8 不触发）。
# 按高德官方要求对相关包整体 keep，禁止混淆与裁剪。
-keep class com.amap.** {*;}
-keep class com.autonavi.** {*;}
