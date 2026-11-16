// FMOD-Android JNI bootstrap for Project.Keynes.
//
// FMOD's Android core caches the JavaVM in `JNI_OnLoad`, which only fires when the
// library is loaded via Java's System.loadLibrary(). Godot loads GDExtension
// dependencies with dlopen, so `FMOD_Studio_System_Create` aborts with
//   "JNI_OnLoad has not run, should have occurred during System.LoadLibrary,
//    or during FMOD_Android_JNI_Init if using NativeActivity."
//
// This module performs both halves that FMOD documents, without needing the FMOD
// SDK headers (everything is resolved with dlsym at runtime):
//   1. JNI_OnLoad(java_vm)                      -> caches the JavaVM inside libfmod
//   2. FMOD_Android_JNI_Init(jni_env, activity) -> hands FMOD the current Activity
//
// `prime()` returns a status code so the GDScript side can log exactly where it
// stopped: 0 = ok, negative = failure step (see `StatusCode`).

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/string.hpp>

#include <dlfcn.h>
#include <jni.h>

using namespace godot;

namespace {

typedef jint (*GetCreatedJavaVMsFn)(JavaVM **, jsize, jsize *);
typedef jint (*JniOnLoadFn)(JavaVM *, void *);
typedef jint (*AndroidJniInitFn)(JNIEnv *, jobject);

constexpr int STATUS_OK = 0;
constexpr int STATUS_NO_JAVA_VM = -1;
constexpr int STATUS_LIBRARY_NOT_FOUND = -2;
constexpr int STATUS_NO_JNI_ON_LOAD = -3;
constexpr int STATUS_JNI_ON_LOAD_FAILED = -4;
constexpr int STATUS_NO_ENV = -5;
constexpr int STATUS_NO_ACTIVITY = -6;
constexpr int STATUS_ACTIVITY_INIT_FAILED = -7;
/// FMOD 的 JNI_OnLoad 第一件事就是 FindClass("org/fmod/FMOD")；类不存在时它会在
/// 挂起异常的情况下再次 FindClass，CheckJNI 直接 abort 整个进程。所以这里先探测，
/// 缺类就干净地失败，让 GDScript 回退到 portable 混音并打印原因。
constexpr int STATUS_MISSING_JAVA_CLASS = -8;

JavaVM *find_java_vm() {
	GetCreatedJavaVMsFn get_vms = (GetCreatedJavaVMsFn)dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs");
	if (get_vms == nullptr) {
		// libnativehelper is the public NDK surface that exports this symbol.
		void *helper = dlopen("libnativehelper.so", RTLD_NOW);
		if (helper != nullptr) {
			get_vms = (GetCreatedJavaVMsFn)dlsym(helper, "JNI_GetCreatedJavaVMs");
		}
	}
	if (get_vms == nullptr) {
		return nullptr;
	}
	JavaVM *vm = nullptr;
	jsize count = 0;
	if (get_vms(&vm, 1, &count) != JNI_OK || count < 1) {
		return nullptr;
	}
	return vm;
}

void clear_exception(JNIEnv *env) {
	if (env->ExceptionCheck() == JNI_TRUE) {
		env->ExceptionClear();
	}
}

// Walks android.app.ActivityThread#mActivities to find the live Activity.
// Best effort: any reflection surprise just clears the pending exception and
// returns nullptr, leaving FMOD in its JNI_OnLoad-only mode.
jobject find_activity(JNIEnv *env) {
	jclass activity_thread = env->FindClass("android/app/ActivityThread");
	if (activity_thread == nullptr) {
		clear_exception(env);
		return nullptr;
	}
	jmethodID current = env->GetStaticMethodID(activity_thread, "currentActivityThread",
			"()Landroid/app/ActivityThread;");
	if (current == nullptr) {
		clear_exception(env);
		return nullptr;
	}
	jobject thread = env->CallStaticObjectMethod(activity_thread, current);
	if (thread == nullptr) {
		clear_exception(env);
		return nullptr;
	}
	jfieldID activities_field = env->GetFieldID(activity_thread, "mActivities",
			"Landroid/util/SparseArray;");
	if (activities_field == nullptr) {
		clear_exception(env);
		return nullptr;
	}
	jobject activities = env->GetObjectField(thread, activities_field);
	if (activities == nullptr) {
		clear_exception(env);
		return nullptr;
	}
	jclass sparse_class = env->GetObjectClass(activities);
	jmethodID size_method = env->GetMethodID(sparse_class, "size", "()I");
	jmethodID value_at = env->GetMethodID(sparse_class, "valueAt", "(I)Ljava/lang/Object;");
	if (size_method == nullptr || value_at == nullptr) {
		clear_exception(env);
		return nullptr;
	}
	jint size = env->CallIntMethod(activities, size_method);
	jobject activity = nullptr;
	for (jint i = 0; i < size && activity == nullptr; ++i) {
		jobject record = env->CallObjectMethod(activities, value_at, i);
		if (record == nullptr) {
			clear_exception(env);
			continue;
		}
		jclass record_class = env->GetObjectClass(record);
		jfieldID activity_field = env->GetFieldID(record_class, "activity",
				"Landroid/app/Activity;");
		if (activity_field != nullptr) {
			jobject candidate = env->GetObjectField(record, activity_field);
			if (candidate != nullptr) {
				activity = env->NewLocalRef(candidate);
			}
		}
		clear_exception(env);
		env->DeleteLocalRef(record);
	}
	clear_exception(env);
	return activity;
}

}  // namespace

class FmodJniBootstrap : public Object {
	GDCLASS(FmodJniBootstrap, Object)

protected:
	static void _bind_methods() {
		ClassDB::bind_static_method("FmodJniBootstrap", D_METHOD("prime", "library"),
				&FmodJniBootstrap::prime);
	}

public:
	/// `p_library` is the FMOD core shared object actually shipped in the APK
	/// (`libfmodL.so` for debug builds, `libfmod.so` for release).
	static int prime(const String &p_library) {
		JavaVM *vm = find_java_vm();
		if (vm == nullptr) {
			return STATUS_NO_JAVA_VM;
		}

		void *handle = dlopen(p_library.utf8().get_data(), RTLD_NOW | RTLD_GLOBAL);
		if (handle == nullptr) {
			return STATUS_LIBRARY_NOT_FOUND;
		}
		JNIEnv *env = nullptr;
		if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
			if (vm->AttachCurrentThread(&env, nullptr) != JNI_OK || env == nullptr) {
				return STATUS_NO_ENV;
			}
		}

		// 路线 A（优先）：完全不碰 Java 类，只走 NativeActivity 官方入口
		// FMOD_Android_JNI_Init(env, activity)。按文档它就是给"没有 Java 层"的宿主
		// 用的，理论上只需缓存 VM + Activity，不需要 org.fmod.FMOD 这个类。
		AndroidJniInitFn android_init =
				(AndroidJniInitFn)dlsym(handle, "FMOD_Android_JNI_Init");
		if (android_init != nullptr) {
			jobject activity = find_activity(env);
			if (activity != nullptr) {
				jint result = android_init(env, activity);
				env->DeleteLocalRef(activity);
				clear_exception(env);
				if (result == 0) {
					return STATUS_OK;
				}
			}
		}

		// 路线 B：等价于 Java 侧 System.loadLibrary。JNI_OnLoad 第一件事就是
		// FindClass("org/fmod/FMOD")；缺类时它会带着挂起异常再次 FindClass，
		// CheckJNI 直接 abort 整个进程，所以先探测再调用。
		jclass fmod_class = env->FindClass("org/fmod/FMOD");
		if (fmod_class == nullptr || env->ExceptionCheck() == JNI_TRUE) {
			clear_exception(env);
			return STATUS_MISSING_JAVA_CLASS;
		}
		env->DeleteLocalRef(fmod_class);

		JniOnLoadFn on_load = (JniOnLoadFn)dlsym(handle, "JNI_OnLoad");
		if (on_load == nullptr) {
			return STATUS_NO_JNI_ON_LOAD;
		}
		if (on_load(vm, nullptr) <= 0) {
			return STATUS_JNI_ON_LOAD_FAILED;
		}
		return STATUS_OK;
	}
};

void register_fmod_bootstrap(ModuleInitializationLevel p_level) {
	// 关键：Godot 会在引擎启动时按 `res://.godot/extension_list.cfg` 的顺序自动加载
	// 所有 .gdextension（`.gdignore` 只挡编辑器扫描，不挡运行期）。FmodGodot 的
	// 初始化就在它自己的 SERVERS 阶段跑完——那时 GDScript 一行都还没执行。
	// 所以 JNI 必须在**本扩展自己的** SERVERS 阶段补上，而本扩展要排在
	// FmodGodot 之前（导出插件负责改写 extension_list.cfg 的顺序）。
	if (p_level == MODULE_INITIALIZATION_LEVEL_SERVERS) {
		const char *candidates[] = { "libfmodL.so", "libfmod.so" };
		for (const char *name : candidates) {
			const int status = FmodJniBootstrap::prime(String(name));
			if (status == STATUS_OK || status == STATUS_MISSING_JAVA_CLASS) {
				break;
			}
		}
		return;
	}
	if (p_level == MODULE_INITIALIZATION_LEVEL_SCENE) {
		GDREGISTER_CLASS(FmodJniBootstrap);
	}
}

void unregister_fmod_bootstrap(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

// The entry symbol referenced by fmod_bootstrap.gdextension. It must have C
// linkage: without `extern "C"` the symbol is C++-mangled and Godot reports
// LOAD_STATUS_FAILED ("GDExtension entry point not found").
extern "C" {

GDExtensionBool GDE_EXPORT fmod_bootstrap_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(register_fmod_bootstrap);
	init_obj.register_terminator(unregister_fmod_bootstrap);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SERVERS);
	return init_obj.init();
}

}  // extern "C"
