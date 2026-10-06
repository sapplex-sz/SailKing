using System.IO;
using System.IO.Pipes;
using System.Security.Principal;
using System.Diagnostics;
using System.Text;
using System.Runtime.InteropServices;
namespace SailKing;
internal enum Operation : uint {Status,Key,Select,Reset,Close,ToggleEnglish,ToggleTranslation,TranslateText,Cancel,CommitOriginal}
internal enum Job : uint {Idle,Running,Ready,Failed}
internal record Reply(bool Available,bool Handled,bool English,bool Translation,Job Job,string Preedit,string Draft,string Commit,string Result,string Error,string[] Candidates);
internal sealed class InputService : IDisposable {
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int ActiveProfile();
    public static bool IsActive() {
        IntPtr library=IntPtr.Zero;
        try {
            library=NativeLibrary.Load(Path.Combine(AppContext.BaseDirectory,"native","0.4.0-preview.1","x64","SailKingTip.dll"));
            return Marshal.GetDelegateForFunctionPointer<ActiveProfile>(NativeLibrary.GetExport(library,"SailKingIsActive"))()!=0;
        }catch(Exception){return false;}
        finally{if(library!=IntPtr.Zero)NativeLibrary.Free(library);}
    }
    private const uint Magic=0x534B494D;
    private readonly Guid session=Guid.NewGuid();
    private readonly SemaphoreSlim serial=new(1,1);
    private static string Fixed(BinaryReader reader,int count) {var text=Encoding.Unicode.GetString(reader.ReadBytes(count*2));var end=text.IndexOf('\0');if(end<0)throw new InvalidDataException("输入服务返回了无效文字。");return text[..end];}
    private static void Fixed(BinaryWriter writer,string text,int count){if(text.Length>=count||text.Contains('\0'))throw new ArgumentException("文字过长或包含无效字符。");writer.Write(Encoding.Unicode.GetBytes(text.PadRight(count,'\0')));}
    public async Task<Reply> Send(Operation operation,string text="",string source="auto",string target="en",CancellationToken token=default) {
        await serial.WaitAsync(token);
        try {
            using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);deadline.CancelAfter(TimeSpan.FromSeconds(5));
            string sid=WindowsIdentity.GetCurrent().User?.Value??throw new InvalidOperationException("无法读取当前用户。");
            using var pipe=new NamedPipeClientStream(".","SailKing-"+sid+"-"+Process.GetCurrentProcess().SessionId,PipeDirection.InOut,PipeOptions.Asynchronous);
            await pipe.ConnectAsync(deadline.Token);
            using var buffer=new MemoryStream();using(var writer=new BinaryWriter(buffer,Encoding.Unicode,true)) {
                writer.Write(Magic);writer.Write(1u);writer.Write(session.ToByteArray());writer.Write((uint)operation);writer.Write(0u);writer.Write(0u);
                Fixed(writer,text,4096);Fixed(writer,source,32);Fixed(writer,target,32);
            }
            await pipe.WriteAsync(buffer.ToArray(),deadline.Token);
            var bytes=new byte[45860];await pipe.ReadExactlyAsync(bytes,deadline.Token);
            await pipe.WriteAsync(new byte[]{0xa5},deadline.Token);
            using var reader=new BinaryReader(new MemoryStream(bytes),Encoding.Unicode);
            if(reader.ReadUInt32()!=Magic||reader.ReadUInt32()!=1)throw new InvalidDataException("输入服务版本不匹配。");
            bool available=reader.ReadUInt32()!=0,handled=reader.ReadUInt32()!=0,english=reader.ReadUInt32()!=0,translation=reader.ReadUInt32()!=0;
            var job=(Job)reader.ReadUInt32();reader.ReadInt32();int count=reader.ReadInt32();if(count<0||count>9||job>Job.Failed)throw new InvalidDataException("输入服务返回了无效结果。");
            string preedit=Fixed(reader,1024),draft=Fixed(reader,4096),commit=Fixed(reader,8192),result=Fixed(reader,8192),error=Fixed(reader,256);
            var candidates=new string[9];for(int i=0;i<9;++i)candidates[i]=Fixed(reader,128);
            return new Reply(available,handled,english,translation,job,preedit,draft,commit,result,error,candidates.Take(count).ToArray());
        }finally{serial.Release();}
    }
    public void Dispose(){serial.Dispose();}
}
