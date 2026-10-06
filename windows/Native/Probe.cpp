#include "WindowsSupport.h"
#include "Guids.h"
#include <msctf.h>
#include <wrl/client.h>
#include <iostream>
#include <tlhelp32.h>
using Microsoft::WRL::ComPtr;
int wmain(int argc,wchar_t** argv){
    HRESULT hr=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);if(FAILED(hr))return 1;
    ComPtr<ITfInputProcessorProfiles> profiles;
    hr=CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles));
    if(FAILED(hr))return 2;
    std::wstring op=argc>1?argv[1]:L"--profiles";
    if(op==L"--ipc-smoke"){
        auto exe=sailking::executableDirectory()/L"SailKingBroker.exe";
        std::wstring testId=std::to_wstring(GetCurrentProcessId()),testPipe=sailking::pipeName()+L"-test-"+testId;
        std::wstring command=L"\""+exe.wstring()+L"\" --ipc-test "+testId;
        STARTUPINFOW startup{sizeof(startup)};PROCESS_INFORMATION child{};
        if(!CreateProcessW(exe.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&child))return 10;
        sailking::Request request;GUID id;CoCreateGuid(&id);memcpy(request.session.data(),&id,16);sailking::Response reply;
        bool ready=false;for(int i=0;i<100&&!ready;++i){Sleep(100);ready=sailking::exchangeAt(testPipe,request,reply,500);if(WaitForSingleObject(child.hProcess,0)==WAIT_OBJECT_0)break;}
        int result=ready?0:11;
        auto call=[&](sailking::Operation operation,uint32_t key=0){request.operation=operation;request.key=key;return sailking::exchangeAt(testPipe,request,reply,1000);};
        if(!result){
            for(int iteration=0;iteration<20&&!result;++iteration){
                if(!call(sailking::Operation::reset))result=12;
                for(char c:std::string("nihao"))if(!call(sailking::Operation::key,c)||!reply.handled)result=13;
                if(!reply.count||std::u16string(reply.candidates[0])!=u"你好")result=14;
                if(!call(sailking::Operation::key,' ')||std::u16string(reply.commit)!=u"你好"||reply.preedit[0])result=15;
            }
            if(!call(sailking::Operation::toggleTranslation)||!reply.translation)result=16;
            for(char c:std::string("nihao"))if(!call(sailking::Operation::key,c))result=17;
            if(!call(sailking::Operation::key,' ')||reply.commit[0]||std::u16string(reply.draft)!=u"你好")result=18;
            if(!call(sailking::Operation::key,0xff0d)||reply.commit[0])result=19;
            for(int i=0;i<50&&reply.job==sailking::Job::running;++i){Sleep(100);if(!call(sailking::Operation::status))result=20;}
            if(reply.job!=sailking::Job::failed||reply.result[0]||std::u16string(reply.draft)!=u"你好")result=21;
            if(!call(sailking::Operation::commitOriginal)||std::u16string(reply.commit)!=u"你好")result=22;
            if(!call(sailking::Operation::toggleTranslation)||reply.translation)result=23;
            if(!call(sailking::Operation::toggleEnglish)||!reply.english)result=24;
            if(!call(sailking::Operation::key,'A')||reply.handled||reply.commit[0])result=25;
        }
        std::cout<<"IPC checks before shutdown: "<<result<<"\n";
        bool shutdown=call(sailking::Operation::shutdown);DWORD ended=WaitForSingleObject(child.hProcess,10000),exitCode=0;GetExitCodeProcess(child.hProcess,&exitCode);
        // This is the isolated child created above, never the user's input service.
        if(ended!=WAIT_OBJECT_0){TerminateProcess(child.hProcess,99);WaitForSingleObject(child.hProcess,5000);}
        CloseHandle(child.hThread);CloseHandle(child.hProcess);
        if(!result&&!shutdown)result=27;
        if(!result&&ended!=WAIT_OBJECT_0)result=26;
        if(!result&&exitCode!=0)result=28;
        std::cout<<"{\"ipcSmoke\":"<<(result?"false":"true")<<",\"code\":"<<result<<",\"childExit\":"<<exitCode<<"}\n";return result;
    }
    else if(op==L"--stop-broker"){
        HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);PROCESSENTRY32W entry{};entry.dwSize=sizeof(entry);
        if(snapshot!=INVALID_HANDLE_VALUE&&Process32FirstW(snapshot,&entry))do{
            if(_wcsicmp(entry.szExeFile,L"SailKingBroker.exe")!=0)continue;
            HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,entry.th32ProcessID);if(!process)continue;
            wchar_t image[32768]{};DWORD length=32768,session=0;
            if(QueryFullProcessImageNameW(process,0,image,&length)&&std::filesystem::path(image)==sailking::executableDirectory()/L"SailKingBroker.exe"&&ProcessIdToSessionId(entry.th32ProcessID,&session)){
                sailking::Request request;request.operation=sailking::Operation::shutdown;sailking::Response reply;
                sailking::exchangeAt(sailking::pipeNameFor(session),request,reply,2000);
            }CloseHandle(process);
        }while(Process32NextW(snapshot,&entry));
        if(snapshot!=INVALID_HANDLE_VALUE)CloseHandle(snapshot);hr=S_OK;
    }
    else if(op==L"--enable")hr=profiles->EnableLanguageProfile(tipClsid,inputLanguage,profileGuid,TRUE);
    else if(op==L"--self-test"||op==L"--activation-test"){
        ComPtr<ITfTextInputProcessorEx> tip;ComPtr<ITfThreadMgr> manager;TfClientId id=TF_CLIENTID_NULL;
        const char* stage="class";hr=CoCreateInstance(tipClsid,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&tip));
        ComPtr<ITfInputProcessorProfileMgr> profileManager;TF_INPUTPROCESSORPROFILE previous{};LANGID previousLanguage=0;bool threadActive=false,hadProfile=false,changedLanguage=false;
        if(op==L"--activation-test"){
            if(SUCCEEDED(hr)){stage="manager";hr=CoCreateInstance(CLSID_TF_ThreadMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&manager));}
            if(SUCCEEDED(hr)){stage="thread";hr=manager->Activate(&id);threadActive=SUCCEEDED(hr);}
            if(SUCCEEDED(hr)){stage="profile-manager";hr=CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profileManager));}
            if(SUCCEEDED(hr)){
                hadProfile=profileManager->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD,&previous)==S_OK;
                stage="language";hr=profiles->GetCurrentLanguage(&previousLanguage);
                if(SUCCEEDED(hr)){hr=profiles->ChangeCurrentLanguage(inputLanguage);changedLanguage=SUCCEEDED(hr);}
            }
            if(SUCCEEDED(hr)){stage="activate-profile";hr=profileManager->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR,inputLanguage,tipClsid,profileGuid,nullptr,TF_IPPMF_FORPROCESS);}
        }
        if(SUCCEEDED(hr)){
            stage="profile-export";
            auto dll=sailking::executableDirectory()/L"SailKingTip.dll";
            if(!std::filesystem::exists(dll))dll=sailking::executableDirectory()/L"native"/L"0.4.0-preview.1"/L"x64"/L"SailKingTip.dll";
            HMODULE library=LoadLibraryExW(dll.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
            using ActiveProfile=BOOL(WINAPI*)();
            auto active=library?reinterpret_cast<ActiveProfile>(GetProcAddress(library,"SailKingIsActive")):nullptr;
            auto ready=library?reinterpret_cast<ActiveProfile>(GetProcAddress(library,"SailKingServiceReady")):nullptr;
            if(!active||!ready)hr=E_FAIL;
            else if(op==L"--activation-test"){
                stage="service-ready";
                for(int i=0;i<50&&!ready();++i){MSG message;while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}Sleep(20);}
                if(!active()||!ready())hr=E_FAIL;
            }else{(void)active();(void)ready();}
            if(library)FreeLibrary(library);
        }
        if(op==L"--activation-test"){
            if(profileManager)profileManager->DeactivateProfile(TF_PROFILETYPE_INPUTPROCESSOR,inputLanguage,tipClsid,profileGuid,nullptr,TF_IPPMF_FORPROCESS);
            if(changedLanguage)profiles->ChangeCurrentLanguage(previousLanguage);
            if(profileManager&&hadProfile)profileManager->ActivateProfile(previous.dwProfileType,previous.langid,previous.clsid,previous.guidProfile,previous.hkl,TF_IPPMF_FORPROCESS);
            if(threadActive)manager->Deactivate();
        }
        std::cout<<"{\""<<(op==L"--activation-test"?"serviceInitialization":"comClass")<<"\":"<<(SUCCEEDED(hr)?"true":"false")<<",\"stage\":\""<<stage<<"\",\"hresult\":"<<static_cast<long>(hr)<<"}\n";
    }else{
        BOOL enabled=FALSE;hr=profiles->IsEnabledLanguageProfile(tipClsid,inputLanguage,profileGuid,&enabled);
        std::cout<<"{\"registered\":"<<(SUCCEEDED(hr)?"true":"false")<<",\"enabled\":"<<(enabled?"true":"false")<<"}\n";
    }
    profiles.Reset();CoUninitialize();return SUCCEEDED(hr)?0:3;
}
