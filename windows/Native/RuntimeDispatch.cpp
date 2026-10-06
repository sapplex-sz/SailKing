#include "WindowsSupport.h"
#include "RuntimeDispatch.h"
#include "CHaHaRuntime.h"
#include <intrin.h>
#include <cstdlib>
namespace {
bool baselineForValidation=false;
bool optimizedCPU(){
    // Windows validates the OS YMM state support as well as the CPU's AVX2 bit.
    if(!IsProcessorFeaturePresent(PF_AVX2_INSTRUCTIONS_AVAILABLE))return false;
    int features[4]{};__cpuid(features,0);if(features[0]<7)return false;
    __cpuid(features,1);uint32_t ecx=uint32_t(features[2]);
    __cpuidex(features,7,0);uint32_t ebx=uint32_t(features[1]);
    return (ecx&(1u<<12))&&(ecx&(1u<<29))&&(ecx&(1u<<20))&&(ebx&(1u<<5))&&(ebx&(1u<<8));
}
struct Functions {
    HMODULE library=nullptr;
    decltype(&::haha_engine_create) create=nullptr;
    decltype(&::haha_engine_destroy) destroy=nullptr;
    decltype(&::haha_engine_unload) unload=nullptr;
    decltype(&::haha_cancellation_create) cancelCreate=nullptr;
    decltype(&::haha_cancellation_request) cancelRequest=nullptr;
    decltype(&::haha_cancellation_destroy) cancelDestroy=nullptr;
    decltype(&::haha_engine_translate) translate=nullptr;
    decltype(&::haha_string_free) stringFree=nullptr;
    decltype(&::haha_runtime_version) version=nullptr;
};
Functions load(const std::filesystem::path& path){
    Functions r;r.library=LoadLibraryExW(path.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if(!r.library)return {};
#define BIND(field,name) r.field=reinterpret_cast<decltype(r.field)>(GetProcAddress(r.library,#name))
    BIND(create,haha_engine_create);BIND(destroy,haha_engine_destroy);BIND(unload,haha_engine_unload);
    BIND(cancelCreate,haha_cancellation_create);BIND(cancelRequest,haha_cancellation_request);BIND(cancelDestroy,haha_cancellation_destroy);
    BIND(translate,haha_engine_translate);BIND(stringFree,haha_string_free);BIND(version,haha_runtime_version);
#undef BIND
    if(!r.create||!r.destroy||!r.unload||!r.cancelCreate||!r.cancelRequest||!r.cancelDestroy||!r.translate||!r.stringFree||!r.version){FreeLibrary(r.library);return {};}
    return r;
}
const Functions& runtime(){
    static const Functions value=[]() noexcept {
        try{
            auto root=sailking::executableDirectory();
            if(!baselineForValidation&&optimizedCPU()){
                auto fast=load(root/L"Runtime"/L"avx2"/L"CHaHaRuntime.dll");if(fast.library)return fast;
            }
            return load(root/L"CHaHaRuntime.dll");
        }catch(...){return Functions{};}
    }();
    return value;
}
}
void sailkingRuntimeBaselineForValidation(){baselineForValidation=true;}
extern "C" {
haha_engine* haha_engine_create(){auto f=runtime().create;return f?f():nullptr;}
void haha_engine_destroy(haha_engine* value){if(value&&runtime().destroy)runtime().destroy(value);}
void haha_engine_unload(haha_engine* value){if(value&&runtime().unload)runtime().unload(value);}
haha_cancellation* haha_cancellation_create(){auto f=runtime().cancelCreate;return f?f():nullptr;}
void haha_cancellation_request(haha_cancellation* value){if(value&&runtime().cancelRequest)runtime().cancelRequest(value);}
void haha_cancellation_destroy(haha_cancellation* value){if(value&&runtime().cancelDestroy)runtime().cancelDestroy(value);}
void haha_string_free(char* value){if(value){if(runtime().stringFree)runtime().stringFree(value);else std::free(value);}}
const char* haha_runtime_version(){auto f=runtime().version;return f?f():"Local runtime unavailable";}
int32_t haha_engine_translate(haha_engine* engine,const char* model,const char* prompt,int32_t limit,haha_cancellation* cancellation,haha_token_callback callback,void* user,char** output,char** error,haha_metrics* metrics){
    auto f=runtime().translate;if(f)return f(engine,model,prompt,limit,cancellation,callback,user,output,error,metrics);
    if(output)*output=nullptr;if(error)*error=nullptr;if(metrics)*metrics={};return HAHA_MODEL_ERROR;
}
}
