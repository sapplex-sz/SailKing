param([string]$Output = '',[string]$Cache = '',[switch]$SkipInstaller,[switch]$TestComPreflight)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (!$Output) { $Output = Join-Path $root 'build\windows' }
if (!$Cache) { $Cache = Join-Path $env:LOCALAPPDATA 'SailKingBuildCache' }
New-Item -ItemType Directory -Force $Output,$Cache | Out-Null
function Run([string]$Executable,[string[]]$Arguments) { & $Executable @Arguments | Out-Host; if ($LASTEXITCODE -ne 0) { throw "$Executable failed ($LASTEXITCODE)" } }
function Download([string]$Url,[string]$Hash,[string]$File) {
 if (!(Test-Path $File) -or (Get-FileHash $File -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) {
  $temporary = "$File.download"
  Run 'curl.exe' @('-fL','--retry','3','--connect-timeout','30','--output',$temporary,$Url)
  if ((Get-FileHash $temporary -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) { throw 'Dependency checksum mismatch' }
  Move-Item -Force $temporary $File
 }
}
$rimeArchive = Join-Path $Cache 'rime-1.17.0-msvc-x64.7z'
Download 'https://github.com/rime/librime/releases/download/1.17.0/rime-33e7814-Windows-msvc-x64.7z' '7478c7caa4ff6b37de86daba1f7ce4a994a4f5ba24872a820fb2b3a9b01fed15' $rimeArchive
$rime = Join-Path $Cache 'rime-1.17.0-x64'
$sevenCommand = Get-Command 7z.exe -ErrorAction SilentlyContinue
$sevenZip = if ($sevenCommand) { $sevenCommand.Source } else { '' }
if (!$sevenZip) { $sevenZip = 'C:\Program Files\7-Zip\7z.exe' }
if (!(Test-Path "$rime\dist\include\rime_api.h")) { Run $sevenZip @('x','-y',"-o$rime",$rimeArchive) }
$revision = '1e411d8f5a1e23525fa3265dfb4bd76265465397'
$llamaArchive = Join-Path $Cache "llama-$revision.tar.gz"
Download "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$revision" 'e7b9788ae7d41bf388ce4f89d38d372ed17aab2c2da1169f7620acb8419c8e51' $llamaArchive
$llama = Join-Path $Cache "llama.cpp-$revision"
if (!(Test-Path "$llama\CMakeLists.txt")) { Run 'tar.exe' @('-xf',$llamaArchive,'-C',$Cache) }
# Windows uses Q4, so the legacy ARM-only STQ model remapping is not applied.
$stage = Join-Path $Output 'stage'
New-Item -ItemType Directory -Force $stage | Out-Null
Run 'dotnet.exe' @('publish',"$root\windows\App\SailKing.csproj",'-c','Release','-r','win-x64','--self-contained','true','-o',$stage,'-p:PublishSingleFile=false','-p:DebugType=None')
foreach ($arch in @('x64','Win32')) {
 $build = Join-Path $Output $arch
 $broker = if ($arch -eq 'x64') { 'ON' } else { 'OFF' }
 Run 'cmake.exe' @('-S',"$root\windows",'-B',$build,'-A',$arch,"-DSAILKING_BROKER=$broker","-DSAILKING_RIME_ROOT=$rime/dist","-DSAILKING_LLAMA_ROOT=$llama")
 Run 'cmake.exe' @('--build',$build,'--config','Release','--target','SailKingTip','SailKingProbe','SailKingCoreTests','--parallel','4')
 if ($TestComPreflight) {
  $register = if ($arch -eq 'x64') { "$env:SystemRoot\System32\regsvr32.exe" } else { "$env:SystemRoot\SysWOW64\regsvr32.exe" }
  $dll = "$build\Release\SailKingTip.dll"
  Run $register @('/s',$dll)
  try { Run "$build\Release\SailKingProbe.exe" @('--self-test') }
  finally { Run $register @('/s','/u',$dll) }
 }
 Run 'cmake.exe' @('--build',$build,'--config','Release','--parallel','4')
 Run 'ctest.exe' @('--test-dir',$build,'-C','Release','--output-on-failure')
 $tipStage = Join-Path $stage ('native\0.4.0-preview.1\'+ $(if ($arch -eq 'x64') { 'x64' } else { 'x86' }))
 New-Item -ItemType Directory -Force $tipStage | Out-Null
 Copy-Item "$build\Release\SailKingTip.dll","$build\Release\SailKingProbe.exe" $tipStage
 if ($arch -eq 'x64') { Copy-Item "$build\Release\SailKingBroker.exe","$build\Release\SailKingProbe.exe","$build\Release\CHaHaRuntime.dll" $stage }
}
$optimized = Join-Path $Output 'avx2'
Run 'cmake.exe' @('-S',"$root\windows",'-B',$optimized,'-A','x64','-DSAILKING_BROKER=ON','-DSAILKING_AVX2_RUNTIME=ON',"-DSAILKING_RIME_ROOT=$rime/dist","-DSAILKING_LLAMA_ROOT=$llama")
Run 'cmake.exe' @('--build',$optimized,'--config','Release','--target','CHaHaRuntime','--parallel','4')
$optimizedStage = Join-Path $stage 'Runtime\avx2'
New-Item -ItemType Directory -Force $optimizedStage | Out-Null
Copy-Item "$optimized\Release\CHaHaRuntime.dll" $optimizedStage
Copy-Item "$rime\dist\lib\rime.dll" $stage

$rimeData = Join-Path $stage 'RimeData'
New-Item -ItemType Directory -Force $rimeData | Out-Null
Copy-Item "$root\Vendor\RimeData\*.yaml","$root\Vendor\RimeData\essay.txt" $rimeData
Copy-Item "$root\Vendor\RimeData\opencc" $rimeData -Recurse -Force
# Include editable dictionaries and all upstream notices with the binary package.
$licenses = Join-Path $stage 'Licenses'
New-Item -ItemType Directory -Force $licenses | Out-Null
Copy-Item "$root\LICENSE","$root\THIRD_PARTY_NOTICES.md" $licenses
Copy-Item "$root\Vendor\licenses" (Join-Path $licenses 'Rime') -Recurse -Force
Copy-Item "$root\Resources\Licenses" (Join-Path $licenses 'Runtime') -Recurse -Force
Copy-Item "$root\windows\Licenses" (Join-Path $licenses 'Microsoft') -Recurse -Force
Copy-Item "$root\Vendor\THIRD_PARTY_NOTICES.md" (Join-Path $licenses 'Rime-NOTICES.md')
# App-local VC runtime: no system-wide redistributable installation is required.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$redist = Get-ChildItem "$vs\VC\Redist\MSVC" -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (!$redist) { throw 'Versioned Visual C++ redistributable directory was not found' }
$crt = Get-ChildItem "$($redist.FullName)\x64" -Directory -Filter '*CRT' | Select-Object -First 1
Copy-Item "$($crt.FullName)\*.dll" $stage
foreach ($arch in @('x64','x86')) {
 $runtime = Get-ChildItem "$($redist.FullName)\$arch" -Directory -Filter '*CRT' | Select-Object -First 1
 Copy-Item "$($runtime.FullName)\*.dll" (Join-Path $stage "native\0.4.0-preview.1\$arch")
}
Run (Join-Path $stage 'SailKingBroker.exe') @('--smoke')
Run (Join-Path $stage 'SailKingBroker.exe') @('--runtime-smoke')
Run (Join-Path $stage 'SailKingBroker.exe') @('--runtime-smoke-baseline')
Run (Join-Path $stage 'SailKingBroker.exe') @('--prepare-data')
Run (Join-Path $stage 'SailKingProbe.exe') @('--ipc-smoke')
# Production installers can be signed by setting a SignTool command externally.
if (!$SkipInstaller) {
 $iscc = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
 Run $iscc @("/DStage=$stage","/DOutput=$Output", "$root\windows\installer\SailKing.iss")
 $installer = Join-Path $Output 'SailKing-0.4.0-preview.1-Windows-x64.exe'
 $hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
 [IO.File]::WriteAllText((Join-Path $Output 'SHA256SUMS.txt'),"$hash  $(Split-Path $installer -Leaf)`n",[Text.UTF8Encoding]::new($false))
}
