#include "world_ext.h"
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/fast_noise_lite.hpp>
#include "parallel_dispatcher.h"
#include <cmath>
#include <algorithm>
#include <limits>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>

namespace pk {
namespace {
godot::Dictionary loading_terrain_detail(const godot::Dictionary &input) {
    using namespace godot;
    const int w=int(input.get("width",0)),h=int(input.get("height",0));
    Dictionary out;out["fallback"]=true;
    if(w<=0 || h<=0 || int64_t(w)*h>67108864) return out;
    Ref<FastNoiseLite> detail,ridge;detail.instantiate();ridge.instantiate();
    int seed=int(input.get("seed",0));
    detail->set_seed(seed+503);detail->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
    detail->set_frequency(.8);detail->set_fractal_type(FastNoiseLite::FRACTAL_FBM);detail->set_fractal_octaves(4);
    ridge->set_seed(seed+977);ridge->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
    ridge->set_frequency(.8*1.15);ridge->set_fractal_type(FastNoiseLite::FRACTAL_RIDGED);ridge->set_fractal_octaves(3);
    const double ox=double(input.get("origin_x",0)),oy=double(input.get("origin_y",0));
    const double sx=double(input.get("size_x",w))/w,sy=double(input.get("size_y",h))/h;
    const double wrap=double(input.get("wrap_period_x",0)),hex=double(input.get("hex_size",1));
    const double lo=double(input.get("min_detail",.7)),hi=double(input.get("max_detail",1.3));
    auto sample=[&](FastNoiseLite *noise,double wx,double wy,double freq,double offx,double offy) {
        double x=wx*freq+offx,y=wy*freq+offy,period=wrap*std::max(freq,.0001);
        double value;
        if(period<=.0001) value=noise->get_noise_2d(x,y);
        else {
            double phase=std::fmod(x-offx,period);if(phase<0)phase+=period;
            double base=noise->get_noise_2d(offx+phase,y);
            double band=std::min(std::max(hex*8*std::max(freq,.0001),1.0),period*.12);
            value=base;
            if(band>.0001) {
                double seam=(double(noise->get_noise_2d(offx,y))+noise->get_noise_2d(offx+period,y))*.5;
                double t=phase<band?phase/band:(phase>period-band?(period-phase)/band:1.0);
                t=t*t*(3-2*t);value=seam+(base-seam)*t;
            }
        }
        return std::clamp(value*.5+.5,0.0,1.0);
    };
    PackedByteArray bytes;bytes.resize(w*h);auto dst=bytes.ptrw();
    parallel_for_range("loading_terrain_detail",h,[&](int begin,int end) {
        for(int y=begin;y<end;++y)for(int x=0;x<w;++x) {
            double wx=ox+(double(x)+.5)*sx,wy=oy+(double(y)+.5)*sy;
            double n=sample(detail.ptr(),wx,wy,.18,0,0),m=sample(detail.ptr(),wx,wy,.45,13,-7),r=sample(ridge.ptr(),wx,wy,.22,-19,31);
            double scalar=std::clamp(1+((n-.5)*.54+(r-.5)*.31+(m-.5)*.15)*.34,lo,hi);
            dst[y*w+x]=uint8_t(std::clamp(int(std::round((scalar-lo)/(hi-lo)*255)),0,255));
        }
    });
    out["fallback"]=false;out["data"]=bytes;return out;
}
// Dictionaries/PackedArrays here are private value snapshots, never scene or
// Resource references. A private unbound DCWorldExt reuses the exact synchronous
// kernels and their private RNG/noise instances, avoiding a second world generator.
struct LoadingTask {
    int64_t id = 0;
    uint64_t owner = 0;
    std::string operation;
    godot::Dictionary input;
    godot::Dictionary result;
    godot::Ref<DCWorldExt> context;
    std::atomic<bool> done{false};
    std::atomic<bool> canceled{false};
};

bool value_only(const godot::Variant &value) {
    using godot::Variant;
    if (value.get_type() == Variant::OBJECT || value.get_type() == Variant::CALLABLE ||
        value.get_type() == Variant::SIGNAL || value.get_type() == Variant::RID) return false;
    if (value.get_type() == Variant::DICTIONARY) {
        godot::Dictionary dict = value;
        auto keys = dict.keys();
        for (int i=0;i<keys.size();++i) if (!value_only(keys[i]) || !value_only(dict[keys[i]])) return false;
    } else if (value.get_type() == Variant::ARRAY) {
        godot::Array array = value;
        for (int i=0;i<array.size();++i) if (!value_only(array[i])) return false;
    }
    return true;
}

class LoadingQueue {
public:
    std::mutex mutex;
    std::condition_variable changed;
    std::deque<std::shared_ptr<LoadingTask>> pending;
    std::unordered_map<int64_t,std::shared_ptr<LoadingTask>> tasks;
    std::thread coordinator;
    int64_t next_id = 1;
    bool stopping = false;

    void start() {
        if (coordinator.joinable()) return;
        stopping = false;
        coordinator = std::thread([this] {
            for (;;) {
                std::shared_ptr<LoadingTask> task;
                {
                    std::unique_lock<std::mutex> lock(mutex);
                    changed.wait(lock,[this]{return stopping || !pending.empty();});
                    if (stopping && pending.empty()) return;
                    task = pending.front(); pending.pop_front();
                }
                if (!task->canceled.load(std::memory_order_acquire)) {
                    try {
                        if (task->operation == "generate") {
                            task->result = task->context->run_native_world_generate_full_pass(
                                int(task->input.get("seed",0)),task->input.get("cfg",godot::Dictionary()),
                                task->input.get("profile",godot::Dictionary()));
                        } else if (task->operation == "geometry") {
                            task->result = task->context->run_bake_geometry_fields_pass(task->input);
                        } else if (task->operation == "visual_tile") {
                            task->result = task->context->run_bake_visual_tile_layer_pass(task->input);
                        } else if (task->operation == "height_flow") {
                            task->result = task->context->encode_bake_height_flow_tex_data(task->input);
                        } else if (task->operation == "normal") {
                            task->result = task->context->encode_bake_terrain_normal_tex_data(task->input);
                        } else if (task->operation == "terrain_detail") {
                            task->result = loading_terrain_detail(task->input);
                        } else if (task->operation == "horizon") {
                            task->result = task->context->encode_bake_horizon_tex_data(task->input);
                        } else if (task->operation == "detail_scatter") {
                            task->result = task->context->encode_detail_scatter(task->input);
                        } else if (task->operation == "catalog_manifest") {
                            godot::Dictionary files = task->input.get("files",godot::Dictionary());
                            auto keys = files.keys(); bool valid = !keys.is_empty();
                            for (int i=0;i<keys.size() && valid;++i) {
                                if (task->canceled.load()) { valid=false; break; }
                                godot::String path=keys[i];
                                valid=godot::FileAccess::get_sha256(path)==godot::String(files[keys[i]]);
                            }
                            task->result["valid"]=valid;
                        }
                    } catch (...) {
                        task->result["fallback"] = true;
                        task->result["reason"] = "loading_worker_exception";
                    }
                }
                // Publish only after every kernel and nested native pool barrier
                // has completed. Poll/take never join a running compute thread.
                task->done.store(true,std::memory_order_release);
            }
        });
    }
    void collect() {
        for (auto it=tasks.begin();it!=tasks.end();) {
            if (it->second->canceled.load() && it->second->done.load(std::memory_order_acquire))
                it=tasks.erase(it);
            else ++it;
        }
    }
    void shutdown() {
        {
            std::lock_guard<std::mutex> lock(mutex);
            stopping = true;
            for (auto &entry:tasks) entry.second->canceled.store(true);
        }
        changed.notify_all();
        if (coordinator.joinable()) coordinator.join();
        pending.clear(); tasks.clear();
    }
    ~LoadingQueue() { shutdown(); }
};
LoadingQueue &queue() { static LoadingQueue singleton; return singleton; }
} // namespace

int64_t DCWorldExt::begin_loading_task(const godot::String &operation, const godot::Dictionary &input) {
#if defined(__EMSCRIPTEN__) && !defined(__EMSCRIPTEN_PTHREADS__)
    return 0;
#else
    const std::string op = operation.utf8().get_data();
    if ((op != "generate" && op != "geometry" && op != "visual_tile" && op != "height_flow" && op != "normal" && op != "terrain_detail" && op != "horizon" && op != "detail_scatter" && op != "catalog_manifest") || !value_only(input)) return 0;
    auto task = std::make_shared<LoadingTask>();
    task->operation = op;
    task->owner = get_instance_id();
    task->input = input.duplicate(true);
    // All Object/Resource allocation occurs on the caller thread. This private
    // context is never bound and cannot read or mutate the live simulation slots.
    task->context.instantiate();
    if (op != "generate") {
        task->context->_gen_river_n = _gen_river_n;
        task->context->_gen_river_q = _gen_river_q;
        task->context->_gen_river_r = _gen_river_r;
        task->context->_gen_river_terrain = _gen_river_terrain;
        task->context->_gen_river_elev = _gen_river_elev;
        task->context->_gen_river_has = _gen_river_has;
        task->context->_gen_river_flow = _gen_river_flow;
        task->context->_gen_river_downstream = _gen_river_downstream;
        task->context->_gen_river_neighbors = _gen_river_neighbors;
    }
    auto &q=queue();
    std::lock_guard<std::mutex> lock(q.mutex);
    q.collect(); q.start();
    task->id=q.next_id++;
    q.tasks.emplace(task->id,task); q.pending.push_back(task); q.changed.notify_one();
    return task->id;
#endif
}

godot::Dictionary DCWorldExt::poll_loading_task(int64_t handle) {
    auto &q=queue(); std::lock_guard<std::mutex> lock(q.mutex); q.collect();
    godot::Dictionary out;
    auto it=q.tasks.find(handle);
    if (it!=q.tasks.end() && it->second->owner!=get_instance_id()) it=q.tasks.end();
    out["valid"]=it!=q.tasks.end();
    out["done"]=it!=q.tasks.end() && it->second->done.load(std::memory_order_acquire);
    out["canceled"]=it==q.tasks.end() || it->second->canceled.load();
    return out;
}

godot::Dictionary DCWorldExt::take_loading_task(int64_t handle) {
    auto &q=queue(); std::lock_guard<std::mutex> lock(q.mutex);
    auto it=q.tasks.find(handle);
    if (it==q.tasks.end() || it->second->owner!=get_instance_id() || !it->second->done.load(std::memory_order_acquire) || it->second->canceled.load())
        return godot::Dictionary();
    auto task=it->second;
    if (task->operation=="generate") {
        _gen_river_n=task->context->_gen_river_n;
        _gen_river_q=std::move(task->context->_gen_river_q);
        _gen_river_r=std::move(task->context->_gen_river_r);
        _gen_river_terrain=std::move(task->context->_gen_river_terrain);
        _gen_river_elev=std::move(task->context->_gen_river_elev);
        _gen_river_has=std::move(task->context->_gen_river_has);
        _gen_river_flow=std::move(task->context->_gen_river_flow);
        _gen_river_downstream=std::move(task->context->_gen_river_downstream);
        _gen_river_neighbors=std::move(task->context->_gen_river_neighbors);
    }
    auto result=task->result;
    q.tasks.erase(it);
    return result;
}

void DCWorldExt::cancel_loading_task(int64_t handle) {
    auto &q=queue(); std::lock_guard<std::mutex> lock(q.mutex);
    auto it=q.tasks.find(handle);
    if (it!=q.tasks.end() && it->second->owner==get_instance_id()) it->second->canceled.store(true,std::memory_order_release);
    q.collect();
}
void DCWorldExt::cancel_all_loading_tasks() {
    auto &q=queue(); std::lock_guard<std::mutex> lock(q.mutex);
    for (auto &entry:q.tasks) if (entry.second->owner==get_instance_id()) entry.second->canceled.store(true,std::memory_order_release);
    q.collect();
}
void DCWorldExt::shutdown_loading_tasks() { queue().shutdown(); }

godot::Dictionary DCWorldExt::encode_bake_height_flow_tex_data(const godot::Dictionary &input) {
    using namespace godot;
    Dictionary out; out["fallback"]=true;
    const int w=int(input.get("width",0)),h=int(input.get("height",0));
    const int64_t n64=int64_t(w)*h;
    if(w<=0 || h<=0 || n64<=0 || n64>67108864) { out["reason"]="invalid_size"; return out; }
    const int n=int(n64);
    PackedFloat32Array height=input.get("height_buffer",PackedFloat32Array());
    PackedFloat32Array flow=input.get("flow_buffer",PackedFloat32Array());
    if(height.size()<n) { out["reason"]="height_buffer_too_small"; return out; }
    Dictionary knobs; knobs["width"]=w;knobs["height"]=h;knobs["buffer"]=height;
    Dictionary hr=encode_bake_height_tex_data(knobs);
    knobs["buffer"]=flow;
    Dictionary fr=encode_bake_flow_tex_data(knobs);
    PackedByteArray hb=hr.get("data",PackedByteArray()),fb=fr.get("data",PackedByteArray());
    if(hb.size()!=n*2) return out;
    PackedByteArray rgba;rgba.resize(n*4);
    auto dst=rgba.ptrw();auto hp=hb.ptr();auto fp=fb.ptr();
    for(int i=0;i<n;++i) { dst[i*4]=hp[i*2];dst[i*4+1]=hp[i*2+1];dst[i*4+2]=fb.size()==n?fp[i]:0;dst[i*4+3]=0; }
    const int stride=std::max(1,n/65536);
    int samples=0,hi=0,bhi=0,bmin=255,bmax=0;int64_t bsum=0;
    double sum=0,min=std::numeric_limits<double>::infinity(),max=-min;
    for(int i=0;i<n;i+=stride) {
        double v=flow.size()>=n?flow[i]:0;
        min=std::min(min,v);max=std::max(max,v);sum+=v;if(v>=.70)++hi;
        int byte=dst[i*4+2];bmin=std::min(bmin,byte);bmax=std::max(bmax,byte);bsum+=byte;if(byte>=179)++bhi;
        ++samples;
    }
    Dictionary src;src["n"]=flow.size()>=n?n:0;src["buf_size"]=flow.size();src["samples"]=samples;src["stride"]=stride;
    src["min"]=min;src["max"]=max;src["mean"]=sum/samples;src["hi_frac"]=double(hi)/samples;
    Dictionary stats;stats["data_size"]=n;stats["samples"]=samples;stats["min"]=bmin;stats["max"]=bmax;
    stats["mean"]=double(bsum)/samples;stats["hi_frac"]=double(bhi)/samples;
    out["fallback"]=false;out["path"]="gdext_height_flow_pack";out["data"]=rgba;out["src"]=src;out["out"]=stats;
    return out;
}
} // namespace pk
