using Microsoft.Win32;
using System.Diagnostics;
using System.IO;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
namespace SailKing;
public partial class MainWindow : Window {
    private record LanguageOption(string Code,string Name);
    private static readonly LanguageOption[] Languages=[new("zh-Hans","简体中文"),new("zh-Hant","繁体中文"),new("en","英语"),new("ja","日语"),new("ko","韩语"),new("de","德语"),new("fr","法语"),new("es","西班牙语"),new("pt","葡萄牙语"),new("it","意大利语"),new("ru","俄语"),new("ar","阿拉伯语"),new("hi","印地语"),new("id","印度尼西亚语"),new("vi","越南语"),new("th","泰语"),new("tr","土耳其语"),new("nl","荷兰语"),new("pl","波兰语"),new("uk","乌克兰语")];
    private readonly InputService service=new();
    private readonly DispatcherTimer automatic=new(){Interval=TimeSpan.FromMilliseconds(700)};
    private CancellationTokenSource? translation,download;
    private bool initialized,registered,enabled,practiced,composing,closing;
    private readonly bool openSettings,preview;
    private long generation;
    public MainWindow(bool settings=false,bool renderingPreview=false) {
        openSettings=settings;preview=renderingPreview;InitializeComponent();
        SourceLanguage.ItemsSource=new[]{new LanguageOption("auto","自动识别")}.Concat(Languages).ToArray();TargetLanguage.ItemsSource=Languages;
        SourceLanguage.SelectedItem=((LanguageOption[])SourceLanguage.ItemsSource).FirstOrDefault(x=>x.Code==Get("Source","auto"))??((LanguageOption[])SourceLanguage.ItemsSource)[0];
        TargetLanguage.SelectedItem=Languages.FirstOrDefault(x=>x.Code==Get("Target","en"))??Languages[2];
        TranslationMode.IsChecked=GetNumber("TranslationEnabled")!=0;Automatic.IsChecked=GetNumber("AutoTranslate")!=0;
        automatic.Tick+=async(_,_)=>{automatic.Stop();if(!composing)await Translate();};
        TextCompositionManager.AddPreviewTextInputStartHandler(SourceText,(_,_)=>{composing=true;automatic.Stop();});
        TextCompositionManager.AddPreviewTextInputHandler(SourceText,(_,_)=>{composing=false;if(Automatic.IsChecked==true)automatic.Start();});
        TextCompositionManager.AddPreviewTextInputHandler(PracticeText,(_,e)=>{
            if(e.Text=="你好"&&registered&&enabled&&InputService.IsActive()){practiced=true;PracticeStatus.Text="已完成拼音试打";FinishGuide.IsEnabled=true;}
        });
        AddPhrases();initialized=true;ShowPage(openSettings?"Settings":GetNumber("Onboarded")==0?"Guide":"Workspace");UpdateModelStatus();
    }
    private static RegistryKey PreferencesKey()=>Registry.CurrentUser.CreateSubKey("Software\\SailKing");
    private static string Get(string name,string fallback){using var key=Registry.CurrentUser.OpenSubKey("Software\\SailKing");return key?.GetValue(name) as string??fallback;}
    private static int GetNumber(string name){using var key=Registry.CurrentUser.OpenSubKey("Software\\SailKing");return key?.GetValue(name) is int n?n:0;}
    private static void Save(string name,object value){using var key=PreferencesKey();key.SetValue(name,value);}
    private void ShowPage(string name){foreach(var element in new FrameworkElement[]{Workspace,Settings,Phrases,Guide})element.Visibility=element.Name==name?Visibility.Visible:Visibility.Collapsed;PageTitle.Text=name switch{"Settings"=>"设置","Phrases"=>"常用表达","Guide"=>"新手设置",_=>"翻译工作台"};Status.Text="";}
    private void Navigate(object sender,RoutedEventArgs e){if(sender is Button b&&b.Tag is string page)ShowPage(page);}
    private async void OnLoaded(object sender,RoutedEventArgs e){await RefreshInput();}
    private async Task RefreshInput(){
        if(preview)return;
        try {
            var info=new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory,"SailKingProbe.exe"),"--profiles"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true};
            using var process=Process.Start(info)??throw new IOException("输入法检测组件不存在。");
            string text=await process.StandardOutput.ReadToEndAsync();await process.WaitForExitAsync();
            registered=text.Contains("\"registered\":true");enabled=text.Contains("\"enabled\":true");
            InputStatus.Text=registered?(enabled?"已启用":"已安装，尚未启用"):"尚未安装";
            GuideStatus.Text=registered?(enabled?"输入法组件已安装并启用。":"点击启用出海王，再用 Win + Space 切换。"):"请重新运行安装包安装输入法组件。";
        }catch(Exception ex){InputStatus.Text="检测失败";GuideStatus.Text=ex.Message;}
    }
    private async void EnableClicked(object sender,RoutedEventArgs e){
        try{using var p=Process.Start(new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory,"SailKingProbe.exe"),"--enable"){UseShellExecute=false,CreateNoWindow=true});if(p is null)throw new IOException("无法启用输入法。");await p.WaitForExitAsync();await RefreshInput();if(p.ExitCode!=0)Status.Text="请在键盘设置中添加出海王输入法。";}
        catch(Exception ex){Status.Text=ex.Message;}
    }
    private async void RefreshClicked(object sender,RoutedEventArgs e)=>await RefreshInput();
    private static void Open(string destination)=>Process.Start(new ProcessStartInfo(destination){UseShellExecute=true});
    private void KeyboardSettingsClicked(object sender,RoutedEventArgs e)=>Open("ms-settings:regionlanguage");
    private void ReleaseClicked(object sender,RoutedEventArgs e)=>Open("https://github.com/sapplex-sz/SailKing/releases");
    private void UninstallClicked(object sender,RoutedEventArgs e){Open("ms-settings:appsfeatures");Close();}
    private void HelpClicked(object sender,RoutedEventArgs e)=>Open("https://github.com/sapplex-sz/SailKing/blob/main/docs/WINDOWS.md");
    private void FinishClicked(object sender,RoutedEventArgs e){if(!practiced)return;Save("Onboarded",1);ShowPage("Workspace");}
    private void FollowClicked(object sender,RoutedEventArgs e){Save("CandidatePinned",0);Status.Text="候选窗口将跟随光标。";}
    private void UpdateModelStatus(){ModelStatus.Text=ModelDownload.Present?"已下载，使用前校验":"尚未下载";DownloadButton.Content=ModelDownload.Present?"重新下载":"下载模型";}
    private async void DownloadClicked(object sender,RoutedEventArgs e){
        if(download is not null)return;download=new CancellationTokenSource();DownloadButton.IsEnabled=false;CancelDownloadButton.IsEnabled=true;DownloadProgress.Visibility=Visibility.Visible;
        try{Status.Text="正在下载本地模型…";await ModelDownload.Download(new Progress<double>(p=>DownloadProgress.Value=p),download.Token);Status.Text="模型已完成大小与 SHA-256 校验。";}
        catch(OperationCanceledException){Status.Text="下载已取消。";}catch(Exception ex){Status.Text="下载失败："+ex.Message;}
        finally{download.Dispose();download=null;DownloadButton.IsEnabled=true;CancelDownloadButton.IsEnabled=false;DownloadProgress.Visibility=Visibility.Collapsed;UpdateModelStatus();}
    }
    private void CancelDownloadClicked(object sender,RoutedEventArgs e)=>download?.Cancel();
    private async void TranslationModeChanged(object sender,RoutedEventArgs e){
        if(!initialized||preview)return;Save("TranslationEnabled",TranslationMode.IsChecked==true?1:0);
        try{await service.Send(Operation.Cancel);}catch(Exception ex){Status.Text=ex.Message;}
    }
    private async void LanguageChanged(object sender,SelectionChangedEventArgs e){
        if(!initialized||preview)return;Save("Source",((LanguageOption)SourceLanguage.SelectedItem).Code);Save("Target",((LanguageOption)TargetLanguage.SelectedItem).Code);await InvalidateTranslation();
    }
    private void AutomaticChanged(object sender,RoutedEventArgs e){if(!initialized||preview)return;Save("AutoTranslate",Automatic.IsChecked==true?1:0);if(Automatic.IsChecked==true&&!composing&&!string.IsNullOrWhiteSpace(SourceText.Text))automatic.Start();else automatic.Stop();}
    private async void SourceChanged(object sender,TextChangedEventArgs e){if(!initialized)return;await InvalidateTranslation();if(Automatic.IsChecked==true&&!composing)automatic.Start();}
    private async Task InvalidateTranslation(){
        ++generation;translation?.Cancel();OutputText.Clear();CopyButton.IsEnabled=false;Status.Text="";
        if(preview)return;
        try{await service.Send(Operation.Cancel);}catch(Exception){/* Preserve source and show a concrete error on the next request. */}
    }
    private async Task Translate(){
        if(closing||composing||string.IsNullOrWhiteSpace(SourceText.Text))return;
        if(!ModelDownload.Present){ShowPage("Settings");Status.Text="请先下载本地翻译模型。";return;}
        long id=++generation;translation?.Cancel();var request=new CancellationTokenSource();translation=request;
        string text=SourceText.Text,source=((LanguageOption)SourceLanguage.SelectedItem).Code,target=((LanguageOption)TargetLanguage.SelectedItem).Code;
        OutputText.Clear();CopyButton.IsEnabled=false;TranslateButton.IsEnabled=false;
        try {
            await service.Send(Operation.Cancel,token:request.Token);
            var reply=await service.Send(Operation.TranslateText,text,source,target,request.Token);
            if(!reply.Available||!reply.Handled)throw new IOException("输入服务尚未就绪，请稍后重试。");
            Status.Text="正在本机翻译…";
            do {await Task.Delay(150,request.Token);reply=await service.Send(Operation.Status,token:request.Token);}while(reply.Job==Job.Running);
            if(id!=generation)return;
            if(reply.Job==Job.Failed)throw new IOException(reply.Error);
            if(reply.Job!=Job.Ready||string.IsNullOrWhiteSpace(reply.Result))throw new IOException("翻译未完成，原文已保留。");
            OutputText.Text=reply.Result;CopyButton.IsEnabled=true;Status.Text="";
        }catch(OperationCanceledException){if(id==generation)Status.Text="翻译已取消。";}
        catch(Exception ex){if(id==generation)Status.Text=ex.Message;}
        finally{if(translation==request){translation=null;TranslateButton.IsEnabled=true;}request.Dispose();}
    }
    private async void TranslateClicked(object sender,RoutedEventArgs e)=>await Translate();
    private async void CancelClicked(object sender,RoutedEventArgs e){automatic.Stop();await InvalidateTranslation();Status.Text="翻译已取消。";}
    private void ClearClicked(object sender,RoutedEventArgs e){automatic.Stop();SourceText.Clear();OutputText.Clear();CopyButton.IsEnabled=false;Status.Text="";}
    private void CopyClicked(object sender,RoutedEventArgs e){if(CopyButton.IsEnabled&&!string.IsNullOrEmpty(OutputText.Text)){Clipboard.SetText(OutputText.Text);Status.Text="已复制译文。";}}
    private async void OnKeyDown(object sender,KeyEventArgs e){if(e.Key==Key.Enter&&Keyboard.Modifiers==ModifierKeys.Control&&Workspace.Visibility==Visibility.Visible){e.Handled=true;await Translate();}}
    private void AddPhrases(){
        foreach(var group in new[]{("客户沟通",new[]{"您好，您的订单已经发货，请留意物流更新。","感谢您的耐心等待，我们会尽快处理。","请提供订单编号，以便我们为您查询。"}),("商品介绍",new[]{"这款产品适合日常使用，操作简单，方便携带。","如果您有任何问题，请随时联系我们。"}),("社媒互动",new[]{"感谢您的支持，欢迎分享您的使用体验！","新品现已上线，期待听到您的反馈。"})}){
            PhraseItems.Children.Add(new TextBlock{Text=group.Item1,FontSize=16,FontWeight=FontWeights.SemiBold,Margin=new Thickness(0,6,0,12)});
            foreach(string text in group.Item2){var button=new Button{Content=new TextBlock{Text=text,TextWrapping=TextWrapping.Wrap},HorizontalContentAlignment=HorizontalAlignment.Left,Margin=new Thickness(0,0,0,8),Padding=new Thickness(14,12,14,12)};button.Click+=(_,_)=>{ShowPage("Workspace");SourceText.Text=text;SourceText.Focus();};PhraseItems.Children.Add(button);}
        }
    }
    private async void OnClosing(object? sender,CancelEventArgs e){
        if(closing||preview)return;
        if(download is not null){download.Cancel();}
        closing=true;automatic.Stop();translation?.Cancel();
        try{await service.Send(Operation.Close);}catch(Exception){/* Process exit clears its session at the broker's expiry. */}
        // Do not dispose the semaphore while a cancelled request is unwinding.
    }
    internal void RenderPreview(string path){
        Dispatcher.BeginInvoke(async()=>{
            ShowPage("Workspace");Automatic.IsChecked=false;SourceText.Text="您好，您的订单 AB-123 已发货，请留意物流更新。";
            await InvalidateTranslation();OutputText.Text="Hello, your order AB-123 has shipped. Please keep an eye on the tracking updates.";CopyButton.IsEnabled=true;Status.Text="界面预览 · 示例译文";
            UpdateLayout();var content=(FrameworkElement)Content;var bitmap=new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth),(int)Math.Ceiling(content.ActualHeight),96,96,System.Windows.Media.PixelFormats.Pbgra32);bitmap.Render(content);
            var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bitmap));using(var stream=File.Create(path))png.Save(stream);Close();
        },DispatcherPriority.ApplicationIdle);
    }
}
