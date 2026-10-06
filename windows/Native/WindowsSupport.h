#pragma once
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <sddl.h>
#include <shlobj.h>
#include <string>
#include <vector>
#include <filesystem>
#include <stdexcept>
#include "Protocol.h"
namespace sailking {
inline std::wstring wide(const std::u16string& s) { return {reinterpret_cast<const wchar_t*>(s.data()),s.size()}; }
inline std::u16string utf16(const std::wstring& s) { return {reinterpret_cast<const char16_t*>(s.data()),s.size()}; }
inline std::string utf8(const std::wstring& s) {
    int n=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,s.data(),int(s.size()),nullptr,0,nullptr,nullptr);
    if(!n && !s.empty()) throw std::runtime_error("Invalid UTF-16");
    std::string out(n,'\0'); if(n) WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,s.data(),int(s.size()),out.data(),n,nullptr,nullptr); return out;
}
inline std::u16string fromUtf8(const std::string& s) {
    int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s.data(),int(s.size()),nullptr,0);
    if(!n && !s.empty()) throw std::runtime_error("Invalid UTF-8");
    std::wstring out(n,L'\0'); if(n) MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s.data(),int(s.size()),out.data(),n); return utf16(out);
}
inline std::filesystem::path executableDirectory(HMODULE module=nullptr) {
    wchar_t path[32768]{}; DWORD n=GetModuleFileNameW(module,path,32768);
    if(!n || n>=32768) throw std::runtime_error("Application path unavailable");
    return std::filesystem::path(path).parent_path();
}
inline std::wstring userSid() {
    HANDLE token=nullptr; if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token)) throw std::runtime_error("User token unavailable");
    DWORD size=0; GetTokenInformation(token,TokenUser,nullptr,0,&size); std::vector<char> data(size);
    BOOL ok=GetTokenInformation(token,TokenUser,data.data(),size,&size); CloseHandle(token);
    if(!ok) throw std::runtime_error("User SID unavailable");
    LPWSTR sid=nullptr; if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid,&sid)) throw std::runtime_error("Invalid SID");
    std::wstring out=sid; LocalFree(sid); return out;
}
inline std::wstring pipeName() {
    DWORD session=0; if(!ProcessIdToSessionId(GetCurrentProcessId(),&session)) throw std::runtime_error("Session unavailable");
    return L"\\\\.\\pipe\\SailKing-"+userSid()+L"-"+std::to_wstring(session);
}
inline std::filesystem::path userData() {
    PWSTR path=nullptr; if(FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&path))) throw std::runtime_error("Local app data unavailable");
    std::filesystem::path out=std::filesystem::path(path)/L"SailKing"; CoTaskMemFree(path); return out;
}
inline std::wstring setting(const wchar_t* name,const wchar_t* fallback=L"") {
    wchar_t value[32768]{}; DWORD bytes=sizeof(value);
    if(RegGetValueW(HKEY_CURRENT_USER,L"Software\\SailKing",name,RRF_RT_REG_SZ,nullptr,value,&bytes)!=ERROR_SUCCESS) return fallback;
    return value;
}
inline DWORD settingNumber(const wchar_t* name,DWORD fallback=0) {
    DWORD value=0,size=sizeof(value);
    return RegGetValueW(HKEY_CURRENT_USER,L"Software\\SailKing",name,RRF_RT_REG_DWORD,nullptr,&value,&size)==ERROR_SUCCESS?value:fallback;
}
inline void saveNumber(const wchar_t* name,DWORD value) {
    HKEY key=nullptr; if(RegCreateKeyExW(HKEY_CURRENT_USER,L"Software\\SailKing",0,nullptr,0,KEY_SET_VALUE,nullptr,&key,nullptr)==ERROR_SUCCESS) {
        RegSetValueExW(key,name,0,REG_DWORD,reinterpret_cast<const BYTE*>(&value),sizeof(value));RegCloseKey(key);
    }
}
inline bool transfer(HANDLE pipe,void* buffer,DWORD size,bool writing,DWORD timeout) {
    OVERLAPPED pending{};pending.hEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);if(!pending.hEvent)return false;
    DWORD done=0;BOOL started=writing?WriteFile(pipe,buffer,size,&done,&pending):ReadFile(pipe,buffer,size,&done,&pending);
    bool ok=started!=FALSE;
    if(!started&&GetLastError()==ERROR_IO_PENDING){
        if(WaitForSingleObject(pending.hEvent,timeout)==WAIT_OBJECT_0)ok=GetOverlappedResult(pipe,&pending,&done,FALSE)!=FALSE;
        else {CancelIoEx(pipe,&pending);GetOverlappedResult(pipe,&pending,&done,TRUE);}
    }
    CloseHandle(pending.hEvent);return ok&&done==size;
}
inline bool exchange(const Request& request,Response& response,DWORD timeout=180) {
    try {
        auto name=pipeName();
        HANDLE pipe=CreateFileW(name.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,nullptr);
        if(pipe==INVALID_HANDLE_VALUE){
            if(GetLastError()!=ERROR_PIPE_BUSY||!WaitNamedPipeW(name.c_str(),timeout))return false;
            pipe=CreateFileW(name.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,nullptr);
        }
        if(pipe==INVALID_HANDLE_VALUE)return false;
        DWORD mode=PIPE_READMODE_MESSAGE;SetNamedPipeHandleState(pipe,&mode,nullptr,nullptr);
        Response result;
        bool ok=transfer(pipe,const_cast<Request*>(&request),sizeof(request),true,timeout)&&transfer(pipe,&result,sizeof(result),false,timeout);
        CloseHandle(pipe);
        if(!ok||result.signature!=magic||result.protocol!=version||result.count<0||result.count>9||
            !terminated(result.preedit)||!terminated(result.draft)||!terminated(result.commit)||!terminated(result.result)||!terminated(result.error))return false;
        for(int i=0;i<result.count;++i)if(!terminated(result.candidates[i]))return false;
        response=result; return result.available!=0;
    } catch(...) { return false; }
}
}
}
