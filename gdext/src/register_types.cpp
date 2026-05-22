#include "register_types.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "world_ext.h"
#include "knobs_struct.h"
#include "sus_scheduler_ext.h"

using namespace godot;

void initialize_dots_ext_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    ClassDB::register_class<pk::DCWorldExt>();
    // Phase A.3：常驻 knobs RID — GDScript 端用 ClassDB.instantiate("KnobsHandle")
    // 拿到实例，跨 frame 持有；ClimateProfile.changed 时调 set_*_scalars / set_*_tables
    // dirty-write，hot path 仅 to_*_knobs_dict 拿缓存 Dict。
    ClassDB::register_class<pk::KnobsHandle>();
    // Phase 1A — sus-cpp-port: SUS scheduler 主循环 native 化。GDScript 端
    // SusScheduler.gd 在 use_gdext_sus_scheduler=true 时 ClassDB.instantiate
    // 这里注册的 SusSchedulerExt，把 register_job / tick / report_* 全部
    // forward 过来；C++ 内部仅在每 slice 跨界一次调 SusJob.run_slice(ctx)。
    ClassDB::register_class<pk::SusSchedulerExt>();
}

void uninitialize_dots_ext_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

extern "C" {

// Entry symbol referenced from `dots_ext.gdextension`.
GDExtensionBool GDE_EXPORT dots_ext_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
                                         GDExtensionClassLibraryPtr p_library,
                                         GDExtensionInitialization *r_initialization) {
    GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

    init_obj.register_initializer(initialize_dots_ext_module);
    init_obj.register_terminator(uninitialize_dots_ext_module);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

    return init_obj.init();
}

} // extern "C"
