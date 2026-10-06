#include "WindowsSupport.h"
#include "Guids.h"
#include <msctf.h>
#include <initguid.h>
#include <inputscope.h>
#include <wrl/client.h>
#include <atomic>
#include <functional>
#include <commctrl.h>
#include <shellapi.h>
using Microsoft::WRL::ComPtr;
using namespace sailking;
namespace {
HMODULE module=nullptr;
std::atomic<long> liveObjects{0};
TF_DISPLAYATTRIBUTE displayAttribute{{TF_CT_COLORREF,{RGB(25,105,190)}},{TF_CT_NONE,{0}},TF_LS_SOLID,FALSE,{TF_CT_COLORREF,{RGB(25,105,190)}},TF_ATTR_INPUT};
class Attribute final:public ITfDisplayAttributeInfo {
    std::atomic<ULONG> refs{1};
public:
    Attribute(){++liveObjects;}~Attribute(){--liveObjects;}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out)override{
        if(!out)return E_POINTER;*out=nullptr;
        if(iid==IID_IUnknown||iid==IID_ITfDisplayAttributeInfo){*out=static_cast<ITfDisplayAttributeInfo*>(this);AddRef();return S_OK;}return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef()override{return ++refs;}ULONG STDMETHODCALLTYPE Release()override{auto n=--refs;if(!n)delete this;return n;}
    HRESULT STDMETHODCALLTYPE GetGUID(GUID* out)override{if(!out)return E_POINTER;*out=displayGuid;return S_OK;}
    HRESULT STDMETHODCALLTYPE GetDescription(BSTR* out)override{if(!out)return E_POINTER;*out=SysAllocString(L"出海王组合文字");return *out?S_OK:E_OUTOFMEMORY;}
    HRESULT STDMETHODCALLTYPE GetAttributeInfo(TF_DISPLAYATTRIBUTE* out)override{if(!out)return E_POINTER;*out=displayAttribute;return S_OK;}
    HRESULT STDMETHODCALLTYPE SetAttributeInfo(const TF_DISPLAYATTRIBUTE*)override{return E_NOTIMPL;}
    HRESULT STDMETHODCALLTYPE Reset()override{return S_OK;}
};
class AttributeEnum final:public IEnumTfDisplayAttributeInfo {
    std::atomic<ULONG> refs{1};bool used=false;
public:
    AttributeEnum(bool done=false):used(done){++liveObjects;}~AttributeEnum(){--liveObjects;}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out)override{if(!out)return E_POINTER;*out=nullptr;if(iid==IID_IUnknown||iid==IID_IEnumTfDisplayAttributeInfo){*out=this;AddRef();return S_OK;}return E_NOINTERFACE;}
    ULONG STDMETHODCALLTYPE AddRef()override{return ++refs;}ULONG STDMETHODCALLTYPE Release()override{auto n=--refs;if(!n)delete this;return n;}
    HRESULT STDMETHODCALLTYPE Clone(IEnumTfDisplayAttributeInfo** out)override{if(!out)return E_POINTER;*out=new(std::nothrow) AttributeEnum(used);return *out?S_OK:E_OUTOFMEMORY;}
    HRESULT STDMETHODCALLTYPE Next(ULONG count,ITfDisplayAttributeInfo** out,ULONG* fetched)override{if(fetched)*fetched=0;if(!out||(!fetched&&count!=1))return E_POINTER;if(used||!count)return S_FALSE;*out=new(std::nothrow) Attribute();if(!*out)return E_OUTOFMEMORY;used=true;if(fetched)*fetched=1;return count==1?S_OK:S_FALSE;}
    HRESULT STDMETHODCALLTYPE Reset()override{used=false;return S_OK;}
    HRESULT STDMETHODCALLTYPE Skip(ULONG count)override{if(!count)return S_OK;if(used)return S_FALSE;used=true;return count==1?S_OK:S_FALSE;}
};
class Edit final:public ITfEditSession {
    std::atomic<ULONG> refs{1};std::function<HRESULT(TfEditCookie)> action;
public:
    explicit Edit(std::function<HRESULT(TfEditCookie)> f):action(std::move(f)){++liveObjects;}~Edit(){--liveObjects;}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out)override{if(!out)return E_POINTER;*out=nullptr;if(iid==IID_IUnknown||iid==IID_ITfEditSession){*out=this;AddRef();return S_OK;}return E_NOINTERFACE;}
    ULONG STDMETHODCALLTYPE AddRef()override{return ++refs;}ULONG STDMETHODCALLTYPE Release()override{auto n=--refs;if(!n)delete this;return n;}
    HRESULT STDMETHODCALLTYPE DoEditSession(TfEditCookie cookie)override{return action(cookie);}
};
class Tip final:public ITfTextInputProcessorEx,public ITfKeyEventSink,public ITfCompositionSink,
    public ITfThreadMgrEventSink,public ITfThreadFocusSink,public ITfTextEditSink,public ITfDisplayAttributeProvider {
    std::atomic<ULONG> refs{1};ComPtr<ITfThreadMgr> manager;ComPtr<ITfContext> context;ComPtr<ITfComposition> composition;
    DWORD managerCookie=TF_INVALID_COOKIE,focusCookie=TF_INVALID_COOKIE,editCookie=TF_INVALID_COOKIE;
    TfClientId client=TF_CLIENTID_NULL;TfGuidAtom attribute=TF_INVALID_GUIDATOM;
    Request identity;Response state;bool secure=false,updating=false,shiftOnly=false;
    HWND window=nullptr;HFONT font=nullptr;bool moving=false;UINT dpi=96;
    void request(Operation operation,uint32_t key=0){
        if(!context)return;ComPtr<ITfContext> ctx=context;
        ComPtr<Tip> self(this);auto task=new(std::nothrow) Edit([self,ctx,operation,key](TfEditCookie ec){
            if(self->context.Get()!=ctx.Get())return S_FALSE;
            return self->apply(ec,ctx.Get(),operation,key,0);
        });
        if(!task)return;
        HRESULT executed=E_FAIL;HRESULT hr=ctx->RequestEditSession(client,task,TF_ES_ASYNCDONTCARE|TF_ES_READWRITE,&executed);
        task->Release();(void)hr;
    }
    bool compartment(IUnknown* object,REFGUID guid){
        ComPtr<ITfCompartmentMgr> cm;ComPtr<ITfCompartment> c;VARIANT v;VariantInit(&v);
        if(!object||FAILED(object->QueryInterface(IID_PPV_ARGS(&cm)))||FAILED(cm->GetCompartment(guid,&c)))return false;
        bool disabled=SUCCEEDED(c->GetValue(&v))&&v.vt==VT_I4&&v.lVal!=0;VariantClear(&v);return disabled;
    }
    bool disabled(ITfContext* ctx){
        if(!ctx||secure||!manager)return true;
        TF_STATUS status{};if(SUCCEEDED(ctx->GetStatus(&status))&&(status.dwDynamicFlags&TF_SD_READONLY))return true;
        HWND focused=GetFocus();wchar_t name[80]{};
        if(focused&&GetClassNameW(focused,name,80)&&_wcsicmp(name,L"Edit")==0&&(GetWindowLongPtrW(focused,GWL_STYLE)&ES_PASSWORD))return true;
        return compartment(manager.Get(),GUID_COMPARTMENT_KEYBOARD_DISABLED)||compartment(manager.Get(),GUID_COMPARTMENT_EMPTYCONTEXT)||
            compartment(ctx,GUID_COMPARTMENT_KEYBOARD_DISABLED)||compartment(ctx,GUID_COMPARTMENT_EMPTYCONTEXT);
    }
    bool privateInput(TfEditCookie ec,ITfContext* ctx,ITfRange* selection){
        ComPtr<ITfProperty> property;VARIANT value;VariantInit(&value);bool sensitive=false;
        if(SUCCEEDED(ctx->GetProperty(GUID_PROP_INPUTSCOPE,&property))&&SUCCEEDED(property->GetValue(ec,selection,&value))&&value.vt==VT_UNKNOWN&&value.punkVal){
            ComPtr<ITfInputScope> scope;
            if(SUCCEEDED(value.punkVal->QueryInterface(IID_PPV_ARGS(&scope)))){
                InputScope* scopes=nullptr;UINT count=0;
                if(SUCCEEDED(scope->GetInputScopes(&scopes,&count)))for(UINT i=0;i<count;++i)if(scopes[i]==IS_PASSWORD||scopes[i]==IS_PRIVATE||scopes[i]==IS_NUMERIC_PASSWORD||scopes[i]==IS_NUMERIC_PIN||scopes[i]==IS_ALPHANUMERIC_PIN||scopes[i]==IS_ALPHANUMERIC_PIN_SET)sensitive=true;
                CoTaskMemFree(scopes);
            }
        }VariantClear(&value);return sensitive;
    }
    void finish(TfEditCookie ec,bool erase){
        if(!composition)return;ComPtr<ITfRange> range;composition->GetRange(&range);
        if(range){if(erase)range->SetText(ec,0,L"",0);ComPtr<ITfProperty> prop;if(context&&SUCCEEDED(context->GetProperty(GUID_PROP_ATTRIBUTE,&prop)))prop->Clear(ec,range.Get());}
        auto ended=composition;composition.Reset();ended->EndComposition(ec);
    }
    bool updateText(TfEditCookie ec,ITfContext* ctx,const std::wstring& text,bool commit){
        ComPtr<ITfRange> range;
        if(composition){if(FAILED(composition->GetRange(&range)))return false;}
        else{
            ComPtr<ITfInsertAtSelection> insert;
            if(FAILED(ctx->QueryInterface(IID_PPV_ARGS(&insert)))||FAILED(insert->InsertTextAtSelection(ec,TF_IAS_QUERYONLY,nullptr,0,&range)))return false;
            if(!commit){ComPtr<ITfContextComposition> cc;if(FAILED(ctx->QueryInterface(IID_PPV_ARGS(&cc)))||FAILED(cc->StartComposition(ec,range.Get(),this,&composition)))return false;}
        }
        if(FAILED(range->SetText(ec,0,text.c_str(),LONG(text.size()))))return false;
        if(!commit&&attribute!=TF_INVALID_GUIDATOM){ComPtr<ITfProperty> property;if(SUCCEEDED(ctx->GetProperty(GUID_PROP_ATTRIBUTE,&property))){VARIANT value;VariantInit(&value);value.vt=VT_I4;value.lVal=attribute;property->SetValue(ec,range.Get(),&value);}}
        ComPtr<ITfRange> caret;range->Clone(&caret);caret->Collapse(ec,TF_ANCHOR_END);
        TF_SELECTION selection{caret.Get(),{TF_AE_NONE,FALSE}};ctx->SetSelection(ec,1,&selection);
        if(commit)finish(ec,false);return true;
    }
    bool selectionCovered(TfEditCookie ec,ITfRange* selection){
        if(!composition)return true;ComPtr<ITfRange> range;if(FAILED(composition->GetRange(&range)))return false;
        LONG start=0,end=0;
        return SUCCEEDED(range->CompareStart(ec,selection,TF_ANCHOR_START,&start))&&start<=0&&SUCCEEDED(range->CompareEnd(ec,selection,TF_ANCHOR_END,&end))&&end>=0;
    }
    HRESULT apply(TfEditCookie ec,ITfContext* ctx,Operation op,uint32_t key,uint32_t modifiers){
        if(disabled(ctx))return S_FALSE;
        TF_SELECTION selection{};ULONG fetched=0;
        if(FAILED(ctx->GetSelection(ec,TF_DEFAULT_SELECTION,1,&selection,&fetched))||fetched!=1)return S_FALSE;
        ComPtr<ITfRange> selected;selected.Attach(selection.range);
        if(privateInput(ec,ctx,selected.Get())||!selectionCovered(ec,selected.Get())){
            Request r=identity;r.operation=Operation::reset;Response ignored;exchange(r,ignored);hide();return S_FALSE;
        }
        if(context.Get()!=ctx){cancelContext();context=ctx;adviseEdit();}
        Request r=identity;r.operation=op;r.key=key;r.modifiers=modifiers;Response next;
        if(!exchange(r,next)){hide();return S_FALSE;}
        state=next;if(!next.handled)return S_FALSE;
        updating=true;
        if(next.commit[0]&&!updateText(ec,ctx,wide(next.commit),true)){updating=false;return E_FAIL;}
        std::wstring text=wide(std::u16string(next.draft)+next.preedit);
        if(!text.empty()){if(!updateText(ec,ctx,text,false)){updating=false;return E_FAIL;}}
        else finish(ec,true);
        updating=false;show(ec,ctx);updateConversion();return S_OK;
    }
    void updateConversion(){
        if(!manager)return;ComPtr<ITfCompartmentMgr> cm;ComPtr<ITfCompartment> c;
        if(SUCCEEDED(manager.As(&cm))&&SUCCEEDED(cm->GetCompartment(GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION,&c))){VARIANT value;VariantInit(&value);value.vt=VT_I4;value.lVal=state.english?0:TF_CONVERSIONMODE_NATIVE;c->SetValue(client,&value);
            if(SUCCEEDED(cm->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE,&c))){value.lVal=1;c->SetValue(client,&value);}}
    }
    void adviseEdit(){
        if(!context)return;ComPtr<ITfSource> source;if(SUCCEEDED(context.As(&source)))source->AdviseSink(IID_ITfTextEditSink,static_cast<ITfTextEditSink*>(this),&editCookie);
    }
    void cancelContext(){
        hide();if(!context)return;ComPtr<ITfContext> old=context;
        if(editCookie!=TF_INVALID_COOKIE){ComPtr<ITfSource> source;if(SUCCEEDED(old.As(&source)))source->UnadviseSink(editCookie);editCookie=TF_INVALID_COOKIE;}
        if(composition){
            auto oldComposition=composition;composition.Reset();
            auto task=new(std::nothrow) Edit([old,oldComposition](TfEditCookie ec){ComPtr<ITfRange> range;if(SUCCEEDED(oldComposition->GetRange(&range))){range->SetText(ec,0,L"",0);ComPtr<ITfProperty> property;if(SUCCEEDED(old->GetProperty(GUID_PROP_ATTRIBUTE,&property)))property->Clear(ec,range.Get());}return oldComposition->EndComposition(ec);});
            if(task){HRESULT result;old->RequestEditSession(client,task,TF_ES_ASYNCDONTCARE|TF_ES_READWRITE,&result);task->Release();}
        }
        context.Reset();Request r=identity;r.operation=Operation::reset;Response out;if(exchange(r,out))state=out;
    }
    uint32_t character(WPARAM key,LPARAM flags){
        switch(key){case VK_BACK:return 0xff08;case VK_RETURN:return 0xff0d;case VK_ESCAPE:return 0xff1b;case VK_LEFT:return 0xff51;case VK_UP:return 0xff52;case VK_RIGHT:return 0xff53;case VK_DOWN:return 0xff54;case VK_PRIOR:return 0xff55;case VK_NEXT:return 0xff56;case VK_DELETE:return 0xffff;}
        BYTE keyboard[256]{};wchar_t text[4]{};GetKeyboardState(keyboard);
        // Windows 10 1607+: flag 4 leaves the dead-key state untouched.
        int n=ToUnicode(UINT(key),UINT((flags>>16)&0xff),keyboard,text,4,4);
        if(n==1)return uint32_t(text[0]);return 0;
    }
    bool wants(ITfContext* ctx,WPARAM key,LPARAM flags){
        if(disabled(ctx))return false;
        bool ctrl=(GetKeyState(VK_CONTROL)&0x8000)!=0,alt=(GetKeyState(VK_MENU)&0x8000)!=0,shift=(GetKeyState(VK_SHIFT)&0x8000)!=0;
        if(key==VK_SHIFT){if(!(flags&(1LL<<30)))shiftOnly=!ctrl&&!alt;return false;}
        shiftOnly=false;
        if(alt||(ctrl&&!(shift&&key=='T')&&key!=VK_RETURN))return false;
        if(ctrl&&((shift&&key=='T')||(key==VK_RETURN&&state.translation)))return true;
        if(ctrl)return false;
        if(state.job!=Job::idle&&(key==VK_RETURN||key==VK_ESCAPE||key==VK_BACK))return true;
        if(state.translation)return character(key,flags)!=0;
        if(state.english)return false;
        if(state.preedit[0])return character(key,flags)!=0;
        return (key>='A'&&key<='Z')&&!ctrl;
    }
    int scaled(int n)const{return MulDiv(n,int(dpi),96);}
    int height()const{
        int h=(state.preedit[0]?62:36)+((state.count+2)/3)*32;
        if(state.draft[0])h+=34;
        if(state.job!=Job::idle)h+=state.job==Job::ready?100:38;
        return scaled(h+22);
    }
    RECT clamp(RECT r){
        MONITORINFO mi{sizeof(mi)};GetMonitorInfoW(MonitorFromRect(&r,MONITOR_DEFAULTTONEAREST),&mi);
        int w=r.right-r.left,h=r.bottom-r.top;
        r.left=std::clamp(r.left,mi.rcWork.left,std::max(mi.rcWork.left,mi.rcWork.right-w));
        r.top=std::clamp(r.top,mi.rcWork.top,std::max(mi.rcWork.top,mi.rcWork.bottom-h));r.right=r.left+w;r.bottom=r.top+h;return r;
    }
    void show(TfEditCookie ec,ITfContext* ctx){
        if(!window||(!state.preedit[0]&&!state.draft[0]&&state.job==Job::idle)){hide();return;}
        RECT r{0,0,scaled(420),height()};
        if(settingNumber(L"CandidatePinned")) {r.left=int(settingNumber(L"CandidateX"));r.top=int(settingNumber(L"CandidateY"));}
        else{
            RECT caret{};BOOL clipped=FALSE;ComPtr<ITfContextView> view;ComPtr<ITfRange> range;
            if(composition)composition->GetRange(&range);
            if(range&&SUCCEEDED(ctx->GetActiveView(&view))&&SUCCEEDED(view->GetTextExt(ec,range.Get(),&caret,&clipped))){r.left=caret.left;r.top=caret.bottom+scaled(6);}
            else{POINT p;GetCaretPos(&p);HWND focused=GetFocus();if(focused)ClientToScreen(focused,&p);r.left=p.x;r.top=p.y+scaled(24);}
        }
        r.right=r.left+scaled(420);r.bottom=r.top+height();r=clamp(r);
        SetWindowPos(window,HWND_TOPMOST,r.left,r.top,r.right-r.left,r.bottom-r.top,SWP_NOACTIVATE|SWP_SHOWWINDOW);
        SetWindowTextW(window,(L"出海王输入法 · "+wide(state.preedit)).c_str());InvalidateRect(window,nullptr,TRUE);
        if(state.job==Job::running)SetTimer(window,1,100,nullptr);else KillTimer(window,1);
    }
    void hide(){if(window){KillTimer(window,1);ShowWindow(window,SW_HIDE);}}
    void paint(HDC dc){
        RECT bounds;GetClientRect(window,&bounds);HBRUSH bg=CreateSolidBrush(RGB(250,251,253));FillRect(dc,&bounds,bg);DeleteObject(bg);
        SelectObject(dc,font);SetBkMode(dc,TRANSPARENT);SetTextColor(dc,RGB(32,43,57));
        auto text=[&](const std::wstring& value,int x,int y,int w,int h,UINT flags=DT_LEFT|DT_SINGLELINE|DT_END_ELLIPSIS){RECT r{scaled(x),scaled(y),scaled(x+w),scaled(y+h)};DrawTextW(dc,value.c_str(),int(value.size()),&r,flags);};
        HICON icon=static_cast<HICON>(LoadImageW(module,MAKEINTRESOURCEW(101),IMAGE_ICON,scaled(20),scaled(20),LR_DEFAULTCOLOR));
        if(icon){DrawIconEx(dc,scaled(10),scaled(7),icon,scaled(20),scaled(20),0,nullptr,DI_NORMAL);DestroyIcon(icon);}
        text(L"出海王",36,8,75,24);text(state.english?L"英":L"中",120,8,30,24);
        text(state.translation?L"翻译输入":L"普通输入",275,8,95,24);
        SetTextColor(dc,RGB(20,99,183));text(wide(state.preedit),12,36,395,25);
        int y=state.preedit[0]?62:36;if(state.draft[0]){SetTextColor(dc,RGB(60,70,82));text(wide(state.draft),12,y,395,32);y+=34;}
        for(int i=0;i<state.count;++i){int x=12+(i%3)*134,row=y+(i/3)*32;
            if(i==state.selected){RECT r{scaled(x-2),scaled(row),scaled(x+126),scaled(row+29)};HBRUSH b=CreateSolidBrush(RGB(221,233,248));FillRect(dc,&r,b);DeleteObject(b);}
            SetTextColor(dc,RGB(110,118,130));text(std::to_wstring(i+1),x+3,row+5,15,24);SetTextColor(dc,RGB(32,43,57));text(wide(state.candidates[i]),x+24,row+3,100,25);
        }
        y+=((state.count+2)/3)*32;
        if(state.job==Job::running)text(L"正在本机翻译…  Esc 取消",12,y,395,32);
        if(state.job==Job::failed){SetTextColor(dc,RGB(170,55,40));text(wide(state.error),12,y,395,38,DT_LEFT|DT_WORDBREAK);}
        if(state.job==Job::ready){SetTextColor(dc,RGB(20,99,183));text(wide(state.result),12,y,395,96,DT_LEFT|DT_WORDBREAK);}
        SetTextColor(dc,RGB(120,127,137));text(state.job==Job::ready?L"Enter 译文上屏 · Ctrl+Enter 原文":L"空格选词 · Shift 中/英 · Ctrl+Shift+T 翻译",12,MulDiv(height(),96,int(dpi))-22,395,20);
    }
    static LRESULT CALLBACK windowProc(HWND hwnd,UINT message,WPARAM wp,LPARAM lp){
        Tip* tip=reinterpret_cast<Tip*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));
        if(message==WM_NCCREATE){tip=static_cast<Tip*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);SetWindowLongPtrW(hwnd,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(tip));}
        if(!tip)return DefWindowProcW(hwnd,message,wp,lp);
        switch(message){
        case WM_MOUSEACTIVATE:return MA_NOACTIVATE;
        case WM_PAINT:{PAINTSTRUCT ps;HDC dc=BeginPaint(hwnd,&ps);tip->paint(dc);EndPaint(hwnd,&ps);return 0;}
        case WM_NCHITTEST:{POINT p{int(short(LOWORD(lp))),int(short(HIWORD(lp)))};ScreenToClient(hwnd,&p);int x=MulDiv(p.x,96,int(tip->dpi)),y=MulDiv(p.y,96,int(tip->dpi));if(y<30&&!(x>=110&&x<160)&&x<270)return HTCAPTION;return HTCLIENT;}
        case WM_EXITSIZEMOVE:{RECT r;GetWindowRect(hwnd,&r);r=tip->clamp(r);SetWindowPos(hwnd,nullptr,r.left,r.top,0,0,SWP_NOSIZE|SWP_NOACTIVATE|SWP_NOZORDER);saveNumber(L"CandidateX",DWORD(r.left));saveNumber(L"CandidateY",DWORD(r.top));saveNumber(L"CandidatePinned",1);return 0;}
        case WM_LBUTTONUP:{int x=MulDiv(int(short(LOWORD(lp))),96,int(tip->dpi)),y=MulDiv(int(short(HIWORD(lp))),96,int(tip->dpi));
            if(y<30&&x>=110&&x<160)tip->request(Operation::toggleEnglish);
            else if(y<30&&x>=270)tip->request(Operation::toggleTranslation);
            else{int top=(tip->state.preedit[0]?62:36)+(tip->state.draft[0]?34:0),index=((y-top)/32)*3+(x-12)/134;if(y>=top&&x>=12&&index>=0&&index<tip->state.count)tip->request(Operation::select,uint32_t(index));}return 0;}
        case WM_CONTEXTMENU:{HMENU menu=CreatePopupMenu();AppendMenuW(menu,MF_STRING,1,L"跟随光标");AppendMenuW(menu,MF_STRING,2,L"打开出海王设置");POINT p;GetCursorPos(&p);int choice=TrackPopupMenu(menu,TPM_RETURNCMD|TPM_NONOTIFY,p.x,p.y,0,hwnd,nullptr);DestroyMenu(menu);if(choice==1){saveNumber(L"CandidatePinned",0);tip->request(Operation::status);}if(choice==2){auto root=executableDirectory(module).parent_path().parent_path().parent_path();auto app=setting(L"InstallPath",root.c_str())+L"\\SailKing.exe";ShellExecuteW(nullptr,L"open",app.c_str(),L"--settings",nullptr,SW_SHOWNORMAL);}return 0;}
        case WM_TIMER:{Request r=tip->identity;r.operation=Operation::status;Response out;if(!exchange(r,out)){tip->hide();return 0;}tip->state=out;InvalidateRect(hwnd,nullptr,TRUE);if(out.job!=Job::running){KillTimer(hwnd,1);RECT rect;GetWindowRect(hwnd,&rect);SetWindowPos(hwnd,nullptr,0,0,tip->scaled(420),tip->height(),SWP_NOMOVE|SWP_NOACTIVATE|SWP_NOZORDER);}return 0;}
        case WM_DPICHANGED:{tip->dpi=HIWORD(wp);if(tip->font)DeleteObject(tip->font);tip->font=CreateFontW(-tip->scaled(14),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Microsoft YaHei UI");return 0;}
        }return DefWindowProcW(hwnd,message,wp,lp);
    }
public:
    Tip(){++liveObjects;GUID id;CoCreateGuid(&id);memcpy(identity.session.data(),&id,16);}
    ~Tip(){if(window)DestroyWindow(window);if(font)DeleteObject(font);UnregisterClassW(L"SailKing.Candidates",module);--liveObjects;}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out)override{
        if(!out)return E_POINTER;*out=nullptr;
        if(iid==IID_IUnknown||iid==IID_ITfTextInputProcessor||iid==IID_ITfTextInputProcessorEx)*out=static_cast<ITfTextInputProcessorEx*>(this);
        else if(iid==IID_ITfKeyEventSink)*out=static_cast<ITfKeyEventSink*>(this);
        else if(iid==IID_ITfCompositionSink)*out=static_cast<ITfCompositionSink*>(this);
        else if(iid==IID_ITfThreadMgrEventSink)*out=static_cast<ITfThreadMgrEventSink*>(this);
        else if(iid==IID_ITfThreadFocusSink)*out=static_cast<ITfThreadFocusSink*>(this);
        else if(iid==IID_ITfTextEditSink)*out=static_cast<ITfTextEditSink*>(this);
        else if(iid==IID_ITfDisplayAttributeProvider)*out=static_cast<ITfDisplayAttributeProvider*>(this);
        if(!*out)return E_NOINTERFACE;AddRef();return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef()override{return ++refs;}ULONG STDMETHODCALLTYPE Release()override{auto n=--refs;if(!n)delete this;return n;}
    HRESULT STDMETHODCALLTYPE Activate(ITfThreadMgr* tm,TfClientId id)override{return ActivateEx(tm,id,0);}
    HRESULT STDMETHODCALLTYPE ActivateEx(ITfThreadMgr* tm,TfClientId id,DWORD flags)override{
        if(!tm)return E_INVALIDARG;manager=tm;client=id;secure=(flags&TF_TMAE_SECUREMODE)!=0;
        ComPtr<ITfKeystrokeMgr> keys;ComPtr<ITfSource> source;ComPtr<ITfCategoryMgr> categories;
        if(FAILED(manager.As(&keys))||FAILED(keys->AdviseKeyEventSink(client,this,TRUE))||FAILED(manager.As(&source))){Deactivate();return E_FAIL;}
        if(FAILED(source->AdviseSink(IID_ITfThreadMgrEventSink,static_cast<ITfThreadMgrEventSink*>(this),&managerCookie))||
           FAILED(source->AdviseSink(IID_ITfThreadFocusSink,static_cast<ITfThreadFocusSink*>(this),&focusCookie))){Deactivate();return E_FAIL;}
        if(SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&categories))))categories->RegisterGUID(displayGuid,&attribute);
        WNDCLASSEXW wc{sizeof(wc)};wc.lpfnWndProc=windowProc;wc.hInstance=module;wc.lpszClassName=L"SailKing.Candidates";wc.hCursor=LoadCursor(nullptr,IDC_ARROW);RegisterClassExW(&wc);
        window=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE|WS_EX_TOPMOST,wc.lpszClassName,tipDescription,WS_POPUP|WS_BORDER,0,0,420,100,nullptr,nullptr,module,this);
        if(window){dpi=GetDpiForWindow(window);font=CreateFontW(-scaled(14),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Microsoft YaHei UI");}
        Request r=identity;exchange(r,state);updateConversion();return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Deactivate()override{
        cancelContext();Request r=identity;r.operation=Operation::close;Response ignored;exchange(r,ignored);
        if(manager){ComPtr<ITfKeystrokeMgr> keys;if(SUCCEEDED(manager.As(&keys)))keys->UnadviseKeyEventSink(client);ComPtr<ITfSource> source;if(SUCCEEDED(manager.As(&source))){if(managerCookie!=TF_INVALID_COOKIE)source->UnadviseSink(managerCookie);if(focusCookie!=TF_INVALID_COOKIE)source->UnadviseSink(focusCookie);}}
        managerCookie=focusCookie=TF_INVALID_COOKIE;manager.Reset();client=TF_CLIENTID_NULL;
        if(window){DestroyWindow(window);window=nullptr;}if(font){DeleteObject(font);font=nullptr;}return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnSetFocus(BOOL foreground)override{if(!foreground)cancelContext();return S_OK;}
    HRESULT STDMETHODCALLTYPE OnTestKeyDown(ITfContext* ctx,WPARAM key,LPARAM flags,BOOL* eaten)override{if(!eaten)return E_POINTER;*eaten=wants(ctx,key,flags);return S_OK;}
    HRESULT STDMETHODCALLTYPE OnKeyDown(ITfContext* ctx,WPARAM key,LPARAM flags,BOOL* eaten)override{
        if(!eaten)return E_POINTER;*eaten=FALSE;if(!wants(ctx,key,flags))return S_OK;
        bool ctrl=(GetKeyState(VK_CONTROL)&0x8000)!=0;
        Operation op=ctrl&&key=='T'?Operation::toggleTranslation:ctrl&&key==VK_RETURN?Operation::commitOriginal:Operation::key;
        uint32_t value=character(key,flags),mask=(GetKeyState(VK_SHIFT)&0x8000)?1:0;
        auto task=new(std::nothrow) Edit([this,ctx,op,value,mask](TfEditCookie ec){return apply(ec,ctx,op,value,mask);});
        if(!task)return E_OUTOFMEMORY;HRESULT executed=E_FAIL;HRESULT result=ctx->RequestEditSession(client,task,TF_ES_SYNC|TF_ES_READWRITE,&executed);task->Release();
        *eaten=SUCCEEDED(result)&&executed==S_OK;return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnTestKeyUp(ITfContext* ctx,WPARAM key,LPARAM,BOOL* eaten)override{if(!eaten)return E_POINTER;*eaten=key==VK_SHIFT&&shiftOnly&&!disabled(ctx);return S_OK;}
    HRESULT STDMETHODCALLTYPE OnKeyUp(ITfContext* ctx,WPARAM key,LPARAM,BOOL* eaten)override{
        if(!eaten)return E_POINTER;*eaten=FALSE;if(key==VK_SHIFT&&shiftOnly&&!disabled(ctx)){
            if(context.Get()!=ctx){cancelContext();context=ctx;adviseEdit();}request(Operation::toggleEnglish);*eaten=TRUE;
        }shiftOnly=false;return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnPreservedKey(ITfContext*,REFGUID,BOOL* eaten)override{if(!eaten)return E_POINTER;*eaten=FALSE;return S_OK;}
    HRESULT STDMETHODCALLTYPE OnCompositionTerminated(TfEditCookie,ITfComposition* ended)override{
        if(ended==composition.Get()){composition.Reset();hide();Request r=identity;r.operation=Operation::reset;Response ignored;exchange(r,ignored);}return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnInitDocumentMgr(ITfDocumentMgr*)override{return S_OK;}
    HRESULT STDMETHODCALLTYPE OnUninitDocumentMgr(ITfDocumentMgr*)override{return S_OK;}
    HRESULT STDMETHODCALLTYPE OnSetFocus(ITfDocumentMgr*,ITfDocumentMgr*)override{cancelContext();return S_OK;}
    HRESULT STDMETHODCALLTYPE OnPushContext(ITfContext*)override{cancelContext();return S_OK;}
    HRESULT STDMETHODCALLTYPE OnPopContext(ITfContext*)override{cancelContext();return S_OK;}
    HRESULT STDMETHODCALLTYPE OnSetThreadFocus()override{return S_OK;}
    HRESULT STDMETHODCALLTYPE OnKillThreadFocus()override{cancelContext();return S_OK;}
    HRESULT STDMETHODCALLTYPE OnEndEdit(ITfContext* ctx,TfEditCookie ec,ITfEditRecord* record)override{
        if(updating||!composition||ctx!=context.Get())return S_OK;BOOL changed=FALSE;
        if(SUCCEEDED(record->GetSelectionStatus(&changed))&&changed){TF_SELECTION s{};ULONG fetched=0;if(SUCCEEDED(ctx->GetSelection(ec,TF_DEFAULT_SELECTION,1,&s,&fetched))&&fetched==1){bool covered=selectionCovered(ec,s.range);s.range->Release();if(!covered)cancelContext();}}
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo** out)override{if(!out)return E_POINTER;*out=new(std::nothrow) AttributeEnum();return *out?S_OK:E_OUTOFMEMORY;}
    HRESULT STDMETHODCALLTYPE GetDisplayAttributeInfo(REFGUID guid,ITfDisplayAttributeInfo** out)override{if(!out)return E_POINTER;*out=nullptr;if(guid!=displayGuid)return E_INVALIDARG;*out=new(std::nothrow) Attribute();return *out?S_OK:E_OUTOFMEMORY;}
};
class Factory final:public IClassFactory{
    std::atomic<ULONG> refs{1};
public:
    Factory(){++liveObjects;}~Factory(){--liveObjects;}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out)override{if(!out)return E_POINTER;*out=nullptr;if(iid==IID_IUnknown||iid==IID_IClassFactory){*out=this;AddRef();return S_OK;}return E_NOINTERFACE;}
    ULONG STDMETHODCALLTYPE AddRef()override{return ++refs;}ULONG STDMETHODCALLTYPE Release()override{auto n=--refs;if(!n)delete this;return n;}
    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer,REFIID iid,void** out)override{if(outer)return CLASS_E_NOAGGREGATION;auto tip=new(std::nothrow) Tip();if(!tip)return E_OUTOFMEMORY;HRESULT result=tip->QueryInterface(iid,out);tip->Release();return result;}
    HRESULT STDMETHODCALLTYPE LockServer(BOOL lock)override{if(lock)++liveObjects;else --liveObjects;return S_OK;}
};
HRESULT registration(bool install){
    HRESULT initialized=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);bool uninitialize=SUCCEEDED(initialized);
    auto finish=[&](HRESULT hr){if(uninitialize)CoUninitialize();return hr;};
    wchar_t id[40]{};StringFromGUID2(tipClsid,id,40);
    std::wstring key=L"Software\\Classes\\CLSID\\"+std::wstring(id);
    auto path=executableDirectory(module)/L"SailKingTip.dll";
    ComPtr<ITfInputProcessorProfileMgr> profiles;ComPtr<ITfCategoryMgr> categories;
    HRESULT hr=CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles));if(FAILED(hr))return finish(hr);
    hr=CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&categories));if(FAILED(hr))return finish(hr);
    const GUID supported[]={GUID_TFCAT_TIP_KEYBOARD,GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,GUID_TFCAT_TIPCAP_INPUTMODECOMPARTMENT,GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT};
    if(!install){
        profiles->UnregisterProfile(tipClsid,inputLanguage,profileGuid,0);
        for(auto& category:supported)categories->UnregisterCategory(tipClsid,category,tipClsid);
        LONG deleted=RegDeleteTreeW(HKEY_LOCAL_MACHINE,key.c_str());return finish(deleted==ERROR_SUCCESS||deleted==ERROR_FILE_NOT_FOUND?S_OK:HRESULT_FROM_WIN32(deleted));
    }
    HKEY registry=nullptr;LONG result=RegCreateKeyExW(HKEY_LOCAL_MACHINE,(key+L"\\InprocServer32").c_str(),0,nullptr,0,KEY_SET_VALUE,nullptr,&registry,nullptr);
    if(result!=ERROR_SUCCESS)return finish(HRESULT_FROM_WIN32(result));
    auto dll=path.wstring();result=RegSetValueExW(registry,nullptr,0,REG_SZ,reinterpret_cast<const BYTE*>(dll.c_str()),DWORD((dll.size()+1)*sizeof(wchar_t)));
    if(result==ERROR_SUCCESS)result=RegSetValueExW(registry,L"ThreadingModel",0,REG_SZ,reinterpret_cast<const BYTE*>(L"Apartment"),sizeof(L"Apartment"));RegCloseKey(registry);
    if(result!=ERROR_SUCCESS)return finish(HRESULT_FROM_WIN32(result));
    hr=profiles->RegisterProfile(tipClsid,inputLanguage,profileGuid,tipDescription,ULONG(wcslen(tipDescription)),dll.c_str(),ULONG(dll.size()),0,nullptr,0,TRUE,0);
    if(SUCCEEDED(hr))for(auto& category:supported){hr=categories->RegisterCategory(tipClsid,category,tipClsid);if(FAILED(hr))break;}
    return finish(hr);
}
}
BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,LPVOID){if(reason==DLL_PROCESS_ATTACH){module=instance;DisableThreadLibraryCalls(instance);}return TRUE;}
STDAPI DllGetClassObject(REFCLSID clsid,REFIID iid,void** out){if(clsid!=tipClsid)return CLASS_E_CLASSNOTAVAILABLE;auto factory=new(std::nothrow) Factory();if(!factory)return E_OUTOFMEMORY;HRESULT hr=factory->QueryInterface(iid,out);factory->Release();return hr;}
STDAPI DllCanUnloadNow(){return liveObjects==0?S_OK:S_FALSE;}
STDAPI DllRegisterServer(){try{return registration(true);}catch(...){return E_FAIL;}}
STDAPI DllUnregisterServer(){try{return registration(false);}catch(...){return E_FAIL;}}
extern "C" BOOL WINAPI SailKingIsActive(){
    HRESULT initialized=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    ComPtr<ITfInputProcessorProfileMgr> profiles;TF_INPUTPROCESSORPROFILE active{};BOOL result=FALSE;
    if(SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles)))&&
       profiles->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD,&active)==S_OK)
        result=active.dwProfileType==TF_PROFILETYPE_INPUTPROCESSOR&&active.clsid==tipClsid&&active.guidProfile==profileGuid;
    profiles.Reset();if(SUCCEEDED(initialized))CoUninitialize();return result;
}
