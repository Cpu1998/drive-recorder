allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// AGP 8 起强制要求 namespace，但老插件（如 amap_flutter_location 3.0.0）未声明。
// 统一从插件 AndroidManifest 的 package 属性自动回填，避免改动 pub cache 受管文件。
// 同时把老插件的 compileSdk 抬到与 app 一致：老值（<31）在 release 的
// verifyReleaseResources 链接 android:attr/lStar（API 31 新增）时直接失败。
// 注意：:app 已被上面 evaluationDependsOn 强制求值，不能注册 afterEvaluate。
subprojects {
    if (project.path == ":app" || project.state.executed) return@subprojects
    afterEvaluate {
        val androidExt = extensions.findByName("android")
        if (androidExt is com.android.build.gradle.LibraryExtension) {
            androidExt.compileSdk = 36
            if (androidExt.namespace == null) {
                val manifest = file("src/main/AndroidManifest.xml")
                if (manifest.exists()) {
                    Regex("package=\"([^\"]+)\"").find(manifest.readText())?.groupValues?.get(1)?.let {
                        androidExt.namespace = it
                    }
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
