using System.Diagnostics;
using System.IO;
using System.Windows;
namespace SailKing;
public partial class App : Application {
    private Mutex? singleton;
    private void OnStartup(object sender,StartupEventArgs e) {
        if(!OperatingSystem.IsWindowsVersionAtLeast(10,0,19041)) { MessageBox.Show("需要 Windows 10 2004 或更高版本。","出海王输入法"); Shutdown(1);return; }
        singleton=new Mutex(true,"Local\\SailKing.Settings",out bool created);
        if(!created){Shutdown();return;}
        try { Process.Start(new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory,"SailKingBroker.exe")){UseShellExecute=false,CreateNoWindow=true}); }
        catch(Exception ex){MessageBox.Show("输入服务未能启动："+ex.Message,"出海王输入法");}
        var window=new MainWindow(e.Args.Contains("--settings"));MainWindow=window;window.Show();
        if(e.Args.Length==2&&e.Args[0]=="--render-preview")window.RenderPreview(e.Args[1]);
    }
    private void OnExit(object sender,ExitEventArgs e){singleton?.Dispose();}
}
