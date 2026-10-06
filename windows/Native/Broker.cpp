#include "WindowsSupport.h"
#include "Translation.h"
#include "CHaHaRuntime.h"
#include <rime_api.h>
#include <bcrypt.h>
#include <fstream>
#include <mutex>
#include <thread>
#include <memory>
#include <chrono>
#include <iostream>
#include <iomanip>
#include <sstream>
#include <atomic>
using namespace sailking;
namespace {
RimeApi* api=nullptr;
std::mutex stateMutex,engineMutex;
std::map<std::array<uint8_t,16>,std::shared_ptr<struct Session>> sessions;
haha_engine* engine=nullptr;
bool testing=false;
std::filesystem::path testingData;
std::wstring testingPipe;
std::atomic<bool> stopping{false};
struct Cancel {
    haha_cancellation* value=haha_cancellation_create();
    ~Cancel(){haha_cancellation_destroy(value);}
    void request(){haha_cancellation_request(value);}
};
struct Session {
    RimeSessionId rime=0;
    bool english=false,translation=false,workspace=false;
    std::wstring source=L"auto",target=L"en";
    std::u16string draft,result,error;
    Job job=Job::idle;
    uint64_t generation=0;
    std::shared_ptr<Cancel> cancellation;
    std::chrono::steady_clock::time_point touched=std::chrono::steady_clock::now();
    ~Session(){if(cancellation)cancellation->request();}
};
void cancel(Session& s) {
    if(s.cancellation)s.cancellation->request();s.cancellation.reset();++s.generation;
    s.result.clear();s.error.clear();s.job=Job::idle;
}
std::string sha256(const std::filesystem::path& path) {
    BCRYPT_ALG_HANDLE algorithm=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)throw std::runtime_error("SHA-256 unavailable");
    DWORD size=0,bytes=0;BCryptGetProperty(algorithm,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&size),sizeof(size),&bytes,0);
    std::vector<BYTE> object(size);std::array<BYTE,32> digest{};
    if(BCryptCreateHash(algorithm,&hash,object.data(),size,nullptr,0,0)<0){BCryptCloseAlgorithmProvider(algorithm,0);throw std::runtime_error("SHA-256 failed");}
    bool ok=true;std::ifstream file(path,std::ios::binary);std::vector<char> buffer(1024*1024);
    if(!file)ok=false;
    while(file){file.read(buffer.data(),buffer.size());auto n=file.gcount();if(n>0&&BCryptHashData(hash,reinterpret_cast<PUCHAR>(buffer.data()),ULONG(n),0)<0){ok=false;break;}}
    if(file.bad())ok=false;
    if(BCryptFinishHash(hash,digest.data(),DWORD(digest.size()),0)<0)ok=false;
    BCryptDestroyHash(hash);BCryptCloseAlgorithmProvider(algorithm,0);
    if(!ok)throw std::runtime_error("Model checksum failed");
    std::ostringstream out;out<<std::hex<<std::setfill('0');for(auto b:digest)out<<std::setw(2)<<int(b);return out.str();
}
std::filesystem::path trustedModel() {
    auto path=(testing?testingData:userData())/L"Models"/L"Hy-MT2-1.8B-Q4_K_M.gguf";
    static std::filesystem::file_time_type verifiedTime{};
    if(!std::filesystem::exists(path)||std::filesystem::file_size(path)!=1133080448ULL)throw std::runtime_error("请在出海王设置中下载本地翻译模型。");
    auto time=std::filesystem::last_write_time(path);
    if(time!=verifiedTime){
        if(sha256(path)!="dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699")throw std::runtime_error("模型校验失败，请重新下载。");
        verifiedTime=time;
    }return path;
}
void beginTranslation(const std::shared_ptr<Session>& s,std::u16string text,std::wstring source,std::wstring target) {
    cancel(*s);
    if(text.empty())return;
    s->draft=text;s->job=Job::running;s->cancellation=std::make_shared<Cancel>();
    auto generation=s->generation;auto cancellation=s->cancellation;
    std::thread([s,text=std::move(text),source=std::move(source),target=std::move(target),generation,cancellation]{
        std::u16string result,error;
        bool wasCancelled=false;
        try{
            std::lock_guard<std::mutex> serial(engineMutex);
            if(cancellation->value==nullptr)throw std::runtime_error("Not enough memory");
            {std::lock_guard<std::mutex> lock(stateMutex);if(s->generation!=generation)return;}
            auto model=trustedModel();
            if(!engine)engine=haha_engine_create();if(!engine)throw std::runtime_error("Not enough memory");
            auto original=utf8(wide(text));auto instruction=prompt(original,utf8(source),utf8(target));
            char* output=nullptr;char* detail=nullptr;haha_metrics metrics{};
            int code=haha_engine_translate(engine,utf8(model.wstring()).c_str(),instruction.c_str(),2048,cancellation->value,nullptr,nullptr,&output,&detail,&metrics);
            std::string value=output?output:"";haha_string_free(output);haha_string_free(detail);
            if(code==HAHA_CANCELLED)wasCancelled=true;
            else if(code==HAHA_CONTEXT_LIMIT)throw std::runtime_error("段落过长，请分成短段落。");
            else if(code==HAHA_OUTPUT_LIMIT)throw std::runtime_error("译文达到长度限制，请缩短原文。");
            else if(code!=HAHA_OK)throw std::runtime_error("本地翻译失败，原文已保留。请检查内存和模型。");
            else if(value.empty())throw std::runtime_error("模型没有返回译文。");
            else if(!entitiesIntact(original,value))throw std::runtime_error("订单号、链接或邮箱可能被修改，请核对或使用原文。");
            else {result=fromUtf8(value);if(result.size()>=8192)throw std::runtime_error("译文过长，请分成短段落。");}
        }catch(const std::exception& e){try{error=fromUtf8(e.what());}catch(...){error=u"本地翻译失败，原文已保留。";}}
        std::lock_guard<std::mutex> lock(stateMutex);
        if(s->generation!=generation)return;
        s->cancellation.reset();
        if(wasCancelled){s->job=Job::idle;return;}
        s->result=std::move(result);s->error=std::move(error);s->job=s->error.empty()?Job::ready:Job::failed;
    }).detach();
}
void initialize(const std::filesystem::path& root,const std::filesystem::path& data) {
    std::filesystem::create_directories(data);
    static std::string shared,user;shared=utf8((root/L"RimeData").wstring());user=utf8(data.wstring());
    RIME_STRUCT(RimeTraits,traits);traits.shared_data_dir=shared.c_str();traits.user_data_dir=user.c_str();
    traits.distribution_name="SailKing Input Method";traits.distribution_code_name="sailking";traits.distribution_version="0.4.0";
    traits.app_name="rime.sailking";traits.min_log_level=2;traits.log_dir="";
    api=rime_get_api();api->setup(&traits);api->initialize(&traits);api->start_maintenance(False);api->join_maintenance_thread();
}
std::shared_ptr<Session> sessionFor(const Request& r) {
    auto& s=sessions[r.session];if(s){s->touched=std::chrono::steady_clock::now();return s;}
    s=std::make_shared<Session>();s->rime=api->create_session();
    if(!s->rime||!api->select_schema(s->rime,"luna_pinyin_simp"))throw std::runtime_error("拼音词库初始化失败，请重新安装。");
    api->set_option(s->rime,"ascii_mode",False);api->set_option(s->rime,"zh_hans",True);api->set_option(s->rime,"full_shape",False);
    s->translation=!testing&&settingNumber(L"TranslationEnabled",0)!=0;s->source=setting(L"Source",L"auto");s->target=setting(L"Target",L"en");return s;
}
std::u16string takeCommit(Session& s) {
    RIME_STRUCT(RimeCommit,commit);std::u16string text;
    if(api->get_commit(s.rime,&commit)){if(commit.text)text=fromUtf8(commit.text);api->free_commit(&commit);}return text;
}
Response snapshot(Session& s) {
    Response out;out.available=1;out.english=s.english;out.translation=s.translation;out.job=s.job;
    copy(out.draft,s.draft);copy(out.result,s.result);copy(out.error,s.error);
    RIME_STRUCT(RimeContext,context);
    if(api->get_context(s.rime,&context)){
        if(context.composition.preedit)copy(out.preedit,fromUtf8(context.composition.preedit));
        out.count=std::min(9,context.menu.num_candidates);out.selected=std::clamp(context.menu.highlighted_candidate_index,0,std::max(0,out.count-1));
        for(int i=0;i<out.count;++i)if(context.menu.candidates[i].text)copy(out.candidates[i],fromUtf8(context.menu.candidates[i].text));
        api->free_context(&context);
    }return out;
}
void appendDraft(Session& s,const std::u16string& text) {
    if(s.draft.size()+text.size()>=4096){s.error=u"原文过长，请先提交当前段落。";return;}
    s.draft+=text;
}
Response process(const Request& r) {
    std::lock_guard<std::mutex> lock(stateMutex);
    if(!valid(r))return {};
    // Prevent stale sessions from accumulating when a host exits without Deactivate.
    auto now=std::chrono::steady_clock::now();
    for(auto i=sessions.begin();i!=sessions.end();)if(now-i->second->touched>std::chrono::minutes(30)&&i->second->job!=Job::running){if(i->second->rime){api->destroy_session(i->second->rime);i->second->rime=0;}i=sessions.erase(i);}else ++i;
    if(r.operation==Operation::shutdown){for(auto& item:sessions)cancel(*item.second);stopping=true;Response out;out.available=out.handled=1;return out;}
    if(r.operation==Operation::close){auto it=sessions.find(r.session);if(it!=sessions.end()){cancel(*it->second);if(it->second->rime)api->destroy_session(it->second->rime);it->second->rime=0;sessions.erase(it);}Response out;out.available=1;return out;}
    auto s=sessionFor(r);std::u16string commit;bool handled=false;
    if(!testing&&!s->workspace&&r.operation!=Operation::translateText){
        bool mode=settingNumber(L"TranslationEnabled",0)!=0;auto source=setting(L"Source",L"auto"),target=setting(L"Target",L"en");
        if(mode!=s->translation){cancel(*s);api->clear_composition(s->rime);s->draft.clear();s->translation=mode;}
        if(source!=s->source||target!=s->target){cancel(*s);s->source=source;s->target=target;}
    }
    switch(r.operation){
    case Operation::reset: cancel(*s);api->clear_composition(s->rime);s->draft.clear();handled=true;break;
    case Operation::cancel: cancel(*s);handled=true;break;
    case Operation::toggleEnglish:
        cancel(*s);api->commit_composition(s->rime);commit=takeCommit(*s);
        if(s->translation){appendDraft(*s,commit);commit.clear();}s->english=!s->english;handled=true;break;
    case Operation::toggleTranslation:
        cancel(*s);api->commit_composition(s->rime);commit=takeCommit(*s);
        if(s->translation)appendDraft(*s,commit);s->translation=!s->translation;
        if(!s->translation){commit=s->draft;s->draft.clear();}
        if(!testing)saveNumber(L"TranslationEnabled",s->translation);handled=true;break;
    case Operation::translateText:
        if(!terminated(r.text)||std::u16string(r.text).empty())break;
        s->workspace=true;beginTranslation(s,r.text,wide(r.source),wide(r.target));handled=true;break;
    case Operation::commitOriginal:
        cancel(*s);api->commit_composition(s->rime);commit=s->draft+takeCommit(*s);s->draft.clear();handled=true;break;
    case Operation::select:
        cancel(*s);handled=api->select_candidate_on_current_page(s->rime,r.key)!=False;commit=takeCommit(*s);
        if(s->translation){appendDraft(*s,commit);commit.clear();}break;
    case Operation::key:
        if(s->translation&&r.key==0xff1b){
            if(s->job!=Job::idle)cancel(*s);else {api->clear_composition(s->rime);s->draft.clear();}handled=true;break;
        }
        if(s->translation&&r.key==0xff0d){
            handled=true;
            if(s->job==Job::running)break;
            if(s->job==Job::ready){commit=s->result;cancel(*s);s->draft.clear();api->clear_composition(s->rime);break;}
            auto state=snapshot(*s);if(state.count>0)api->select_candidate_on_current_page(s->rime,state.selected);
            else api->commit_composition(s->rime);
            appendDraft(*s,takeCommit(*s));
            beginTranslation(s,s->draft,setting(L"Source",L"auto"),setting(L"Target",L"en"));break;
        }
        if(s->job!=Job::idle)cancel(*s);
        if(s->english){
            if(s->translation){
                if(r.key==0xff08&&!s->draft.empty()){
                    s->draft.pop_back();if(!s->draft.empty()&&s->draft.back()>=0xd800&&s->draft.back()<=0xdbff)s->draft.pop_back();handled=true;
                }else if(r.key>=32&&r.key<0xff00){appendDraft(*s,std::u16string(1,char16_t(r.key)));handled=true;}
            }
        }else{
            auto before=snapshot(*s);
            if(s->translation&&r.key==0xff08&&!before.preedit[0]&&!s->draft.empty()){
                s->draft.pop_back();if(!s->draft.empty()&&s->draft.back()>=0xd800&&s->draft.back()<=0xdbff)s->draft.pop_back();handled=true;
            }else{
                handled=api->process_key(s->rime,r.key,r.modifiers)!=False;commit=takeCommit(*s);
                if(s->translation){appendDraft(*s,commit);commit.clear();if(!handled&&r.key>=32&&r.key<0xff00){appendDraft(*s,std::u16string(1,char16_t(r.key)));handled=true;}}
            }
        }break;
    default:break;
    }
    auto out=snapshot(*s);out.handled=handled;
    if(!copy(out.commit,commit)){out.handled=0;copy(out.error,u"文字过长，请缩短后重试。");}
    return out;
}
int translationSmoke(){
    auto model=trustedModel();auto local=haha_engine_create();auto cancellation=haha_cancellation_create();
    if(!local||!cancellation)return 30;
    std::string source="您好，您的订单 AB-123 已发货。请留意物流更新。";
    auto instruction=prompt(source,"zh-Hans","en");char* output=nullptr;char* error=nullptr;haha_metrics metrics{};
    int code=haha_engine_translate(local,utf8(model.wstring()).c_str(),instruction.c_str(),256,cancellation,nullptr,nullptr,&output,&error,&metrics);
    std::string result=output?output:"";haha_string_free(output);haha_string_free(error);
    if(code!=HAHA_OK||result.empty()||!entitiesIntact(source,result)){
        std::cerr<<"Translation smoke failed: "<<code<<"\n";haha_cancellation_destroy(cancellation);haha_engine_destroy(local);return 31;
    }
    std::cout<<"Local translation: "<<result<<"\n"<<"Prompt tokens: "<<metrics.prompt_tokens<<"; output tokens: "<<metrics.generated_tokens<<"; first token seconds: "<<metrics.first_token_seconds<<"; generation seconds: "<<metrics.generation_seconds<<"\n";
    haha_cancellation_destroy(cancellation);cancellation=haha_cancellation_create();
    std::thread cancelTask([cancellation]{std::this_thread::sleep_for(std::chrono::milliseconds(30));haha_cancellation_request(cancellation);});
    output=error=nullptr;
    code=haha_engine_translate(local,utf8(model.wstring()).c_str(),instruction.c_str(),2048,cancellation,nullptr,nullptr,&output,&error,&metrics);
    cancelTask.join();haha_string_free(output);haha_string_free(error);haha_cancellation_destroy(cancellation);haha_engine_destroy(local);
    if(code!=HAHA_CANCELLED)return 32;
    std::cout<<"Native cancellation passed\n";return 0;
}

int smoke(const std::filesystem::path& root){
    testing=true;
    auto data=std::filesystem::temp_directory_path()/(L"SailKing-Rime-Test-"+std::to_wstring(GetCurrentProcessId()));
    initialize(root,data);Request r;r.session[0]=1;Response out;
    for(char c:std::string("nihao")){r.operation=Operation::key;r.key=c;out=process(r);if(!out.handled)return 10;}
    if(out.count<1||std::u16string(out.candidates[0])!=u"你好")return 11;
    r.key=' ';out=process(r);if(std::u16string(out.commit)!=u"你好"||out.preedit[0])return 12;
    r.operation=Operation::toggleTranslation;out=process(r);if(!out.translation)return 13;
    for(char c:std::string("zhongguo")){r.operation=Operation::key;r.key=c;out=process(r);}
    r.key=' ';out=process(r);if(out.commit[0]||std::u16string(out.draft)!=u"中国")return 14;
    r.operation=Operation::commitOriginal;out=process(r);if(std::u16string(out.commit)!=u"中国")return 15;
    r.operation=Operation::close;process(r);api->finalize();std::filesystem::remove_all(data);
    std::cout<<"Rime composition, candidates, commit and translation draft passed\n";return 0;
}
}
int wmain(int argc,wchar_t** argv){
    try{
        SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32|LOAD_LIBRARY_SEARCH_APPLICATION_DIR|LOAD_LIBRARY_SEARCH_USER_DIRS);
        auto root=executableDirectory();
        if(argc>1&&std::wstring(argv[1])==L"--ipc-test"){
            if(argc!=3||!argv[2][0]||wcslen(argv[2])>10||std::wstring(argv[2]).find_first_not_of(L"0123456789")!=std::wstring::npos)return 5;
            testing=true;testingPipe=pipeName()+L"-test-"+argv[2];
            testingData=std::filesystem::temp_directory_path()/(L"SailKing-IPC-Test-"+std::to_wstring(GetCurrentProcessId()));
        }
        if(argc>1&&std::wstring(argv[1])==L"--smoke")return smoke(root);
        if(argc>1&&std::wstring(argv[1])==L"--translation-smoke")return translationSmoke();
        if(argc>1&&std::wstring(argv[1])==L"--prepare-data"){initialize(root,root/L"RimeData");api->finalize();return 0;}
        auto name=testing?testingPipe:pipeName();auto mutexName=L"Local\\"+name.substr(9);
        HANDLE singleton=CreateMutexW(nullptr,TRUE,mutexName.c_str());if(!singleton)return 2;if(GetLastError()==ERROR_ALREADY_EXISTS){CloseHandle(singleton);return 0;}
        initialize(root,(testing?testingData:userData())/L"Rime");
        // Current user + SYSTEM, local logon session only. No network endpoint and no Everyone ACL.
        PSECURITY_DESCRIPTOR descriptor=nullptr;
        std::wstring acl=L"D:P(A;;GA;;;SY)(A;;GA;;;"+userSid()+L")";
        if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(acl.c_str(),SDDL_REVISION_1,&descriptor,nullptr))return 3;
        SECURITY_ATTRIBUTES security{sizeof(security),descriptor,FALSE};
        DWORD currentSession=0;ProcessIdToSessionId(GetCurrentProcessId(),&currentSession);
        HANDLE pipe=CreateNamedPipeW(name.c_str(),PIPE_ACCESS_DUPLEX|FILE_FLAG_OVERLAPPED,PIPE_TYPE_MESSAGE|PIPE_READMODE_MESSAGE|PIPE_WAIT|PIPE_REJECT_REMOTE_CLIENTS,1,sizeof(Response),sizeof(Request),1000,&security);
        if(pipe==INVALID_HANDLE_VALUE)return 4;
        while(!stopping){
            OVERLAPPED connection{};connection.hEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);
            bool connected=ConnectNamedPipe(pipe,&connection)!=FALSE;
            if(!connected){DWORD error=GetLastError();if(error==ERROR_PIPE_CONNECTED)connected=true;else if(error==ERROR_IO_PENDING)connected=WaitForSingleObject(connection.hEvent,INFINITE)==WAIT_OBJECT_0;}
            CloseHandle(connection.hEvent);
            if(connected){
                ULONG pid=0;DWORD clientSession=0;
                Request request;Response response;
                if(GetNamedPipeClientProcessId(pipe,&pid)&&ProcessIdToSessionId(pid,&clientSession)&&transfer(pipe,&request,sizeof(request),false,500)){
                    bool permitted=clientSession==currentSession;
                    if(!permitted&&request.operation==Operation::shutdown){
                        HANDLE peer=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);wchar_t image[32768]{};DWORD length=32768;
                        if(peer){permitted=QueryFullProcessImageNameW(peer,0,image,&length)&&std::filesystem::path(image)==root/L"SailKingProbe.exe";CloseHandle(peer);}
                    }
                    if(!permitted){DisconnectNamedPipe(pipe);continue;}
                    try{response=process(request);}catch(const std::exception& e){response.available=1;copy(response.error,fromUtf8(e.what()));}
                    if(transfer(pipe,&response,sizeof(response),true,500)){BYTE acknowledged=0;transfer(pipe,&acknowledged,1,false,500);}
                }
            }
            // Keep the endpoint alive between requests so a fast next keystroke
            // cannot race a close/recreate interval and get FILE_NOT_FOUND.
            DisconnectNamedPipe(pipe);
        }
        CloseHandle(pipe);
        LocalFree(descriptor);
        {std::lock_guard<std::mutex> serial(engineMutex);haha_engine_destroy(engine);engine=nullptr;}
        {std::lock_guard<std::mutex> lock(stateMutex);for(auto& item:sessions){if(item.second->rime)api->destroy_session(item.second->rime);item.second->rime=0;}sessions.clear();api->finalize();}
        ReleaseMutex(singleton);CloseHandle(singleton);if(testing)std::filesystem::remove_all(testingData);return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}
}
