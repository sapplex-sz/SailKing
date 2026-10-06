#include "WindowsSupport.h"
#include "Guids.h"
#include <msctf.h>
#include <wrl/client.h>
#include <iostream>
using Microsoft::WRL::ComPtr;
int wmain(int argc,wchar_t** argv){
    HRESULT hr=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);if(FAILED(hr))return 1;
    ComPtr<ITfInputProcessorProfiles> profiles;
    hr=CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles));
    if(FAILED(hr))return 2;
    std::wstring op=argc>1?argv[1]:L"--profiles";
    if(op==L"--enable")hr=profiles->EnableLanguageProfile(tipClsid,inputLanguage,profileGuid,TRUE);
    else if(op==L"--self-test"){
        ComPtr<ITfTextInputProcessorEx> tip;ComPtr<ITfThreadMgr> manager;TfClientId id=TF_CLIENTID_NULL;
        hr=CoCreateInstance(tipClsid,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&tip));
        if(SUCCEEDED(hr))hr=CoCreateInstance(CLSID_TF_ThreadMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&manager));
        if(SUCCEEDED(hr))hr=manager->Activate(&id);
        if(SUCCEEDED(hr)){hr=tip->ActivateEx(manager.Get(),id,0);if(SUCCEEDED(hr))tip->Deactivate();manager->Deactivate();}
        std::cout<<"{\"comActivation\":"<<(SUCCEEDED(hr)?"true":"false")<<",\"hresult\":"<<static_cast<long>(hr)<<"}\n";
    }else{
        BOOL enabled=FALSE;hr=profiles->IsEnabledLanguageProfile(tipClsid,inputLanguage,profileGuid,&enabled);
        std::cout<<"{\"registered\":"<<(SUCCEEDED(hr)?"true":"false")<<",\"enabled\":"<<(enabled?"true":"false")<<"}\n";
    }
    profiles.Reset();CoUninitialize();return SUCCEEDED(hr)?0:3;
}
