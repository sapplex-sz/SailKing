using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
namespace SailKing;
internal static class ModelDownload {
    public const long Bytes=1133080448;
    public const string Hash="dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699";
    public static readonly string DirectoryPath=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"SailKing","Models");
    public static readonly string ModelPath=Path.Combine(DirectoryPath,"Hy-MT2-1.8B-Q4_K_M.gguf");
    public static bool Present => File.Exists(ModelPath)&&new FileInfo(ModelPath).Length==Bytes;
    public static async Task Download(IProgress<double> progress,CancellationToken token) {
        Directory.CreateDirectory(DirectoryPath);
        string staging=ModelPath+"."+Guid.NewGuid().ToString("N")+".download";
        try {
            using var client=new HttpClient{Timeout=Timeout.InfiniteTimeSpan};
            using var response=await client.GetAsync("https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/a0c709d9fac510f2c807aa3af52872340dc37a4a/Hy-MT2-1.8B-Q4_K_M.gguf?download=true",HttpCompletionOption.ResponseHeadersRead,token);
            response.EnsureSuccessStatusCode();
            if(response.Content.Headers.ContentLength is long size&&size!=Bytes)throw new InvalidDataException("模型大小与固定版本不一致。");
            if(new DriveInfo(Path.GetPathRoot(staging)!).AvailableFreeSpace<Bytes+200*1024*1024)throw new IOException("磁盘空间不足，需要至少 1.4 GB 可用空间。");
            await using(var input=await response.Content.ReadAsStreamAsync(token))
            await using(var output=new FileStream(staging,FileMode.CreateNew,FileAccess.Write,FileShare.None,1024*1024,FileOptions.Asynchronous)) {
                byte[] buffer=new byte[1024*1024];long total=0;
                using var hash=IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                int count;
                while((count=await input.ReadAsync(buffer,token))>0){total+=count;if(total>Bytes)throw new InvalidDataException("模型文件过大。");hash.AppendData(buffer,0,count);await output.WriteAsync(buffer.AsMemory(0,count),token);progress.Report((double)total/Bytes*100);}
                if(total!=Bytes||!Convert.ToHexString(hash.GetHashAndReset()).Equals(Hash,StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("模型校验失败，请重新下载。");
                await output.FlushAsync(token);
            }
            token.ThrowIfCancellationRequested();File.Move(staging,ModelPath,true);
        }finally{if(File.Exists(staging))File.Delete(staging);}
    }
}
