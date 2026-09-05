# test_android.ps1 · 事务伴侣安卓模拟器测试环境一键脚本
# 用途：启动模拟器（未启动时）→ 编译最新 APK → 安装 → 拉起 App
#       给老大在电脑端用模拟器做真实安卓环境的功能测试（老大 2026-09-04 指示）。
# 用法：powershell -File tools\test_android.ps1 [-Avd test_phone] [-NoBuild]
# 依赖：Flutter=D:\flutter，JDK=D:\jdk\jdk-17.0.20.1+1，SDK=D:\android-sdk，车间=D:\sw_build

param(
    [string]$Avd = "test_phone",
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"
$Project  = "D:\000-me-work\事务伴侣"
$App      = "$Project\app"
$Workshop = "D:\sw_build"
$Flutter  = "D:\flutter\bin\flutter.bat"
$Adb      = "D:\android-sdk\platform-tools\adb.exe"
$Emu      = "D:\android-sdk\emulator\emulator.exe"
$Pkg      = "cn.affairmate.shiwu_companion"
$Env:JAVA_HOME = "D:\jdk\jdk-17.0.20.1+1"

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# ---------- 1. 模拟器在线检测，不在线则启动并等开机 ----------
Step "检查模拟器（$Avd）"
& $Adb start-server 2>$null | Out-Null
$booted = & $Adb shell getprop sys.boot_completed 2>$null
if ("$booted".Trim() -ne "1") {
    Write-Host "模拟器未运行，启动中（冷启动约 1 分钟）…"
    Start-Process -FilePath $Emu -ArgumentList "-avd",$Avd,"-no-snapshot-load","-no-boot-anim","-gpu","auto" -WindowStyle Minimized
    & $Adb wait-for-device | Out-Null
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        $b = (& $Adb shell getprop sys.boot_completed 2>$null)
        if ("$b".Trim() -eq "1") { break }
        Start-Sleep -Seconds 3
    }
    if ("$b".Trim() -ne "1") { throw "模拟器 3 分钟内未完成开机" }
}
Write-Host "模拟器在线" -ForegroundColor Green

# ---------- 2. 同步源码到车间并编译 ----------
$apk = "$Workshop\build\app\outputs\flutter-apk\app-debug.apk"
if (-not $NoBuild) {
    Step "同步源码到车间并编译 APK"
    foreach ($item in @("lib", "android", "windows", "integration_test")) {
        $src = Join-Path $App $item; $dst = Join-Path $Workshop $item
        if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
        Copy-Item -Recurse $src $dst
    }
    # 关键：插件注册隐藏文件必须同步，否则 GeneratedPluginRegistrant 找不到插件包（M-025 坑）
    foreach ($f in @(".flutter-plugins", ".flutter-plugins-dependencies",
                     "pubspec.yaml", "pubspec.lock", "analysis_options.yaml")) {
        Copy-Item (Join-Path $App $f) (Join-Path $Workshop $f) -Force
    }
    if (Test-Path "$Workshop\windows\flutter\ephemeral") {
        Remove-Item -Recurse -Force "$Workshop\windows\flutter\ephemeral"
    }
    Push-Location $Workshop
    try {
        # --no-pub：绕过 pub advisories 缓存 bug（M-017 坑，依赖未变时安全）
        & $Flutter build apk --debug --no-pub
        if ($LASTEXITCODE -ne 0) { throw "APK 编译失败" }
    } finally { Pop-Location }
    Write-Host "APK 编译完成" -ForegroundColor Green
} else {
    Step "跳过编译（-NoBuild，复用现成 APK）"
    if (-not (Test-Path $apk)) { throw "APK 不存在：$apk（去掉 -NoBuild 先编译）" }
}

# ---------- 3. 安装并拉起 ----------
Step "安装并启动 App"
& $Adb install -r $apk
if ($LASTEXITCODE -ne 0) { throw "APK 安装失败" }
& $Adb shell am start -n "$Pkg/.MainActivity" | Out-Null
Start-Sleep -Seconds 3
$procId = (& $Adb shell pidof $Pkg)
if (-not $procId) { throw "App 启动后未见进程（检查 adb logcat）" }
Write-Host "App 运行中（pid $procId）" -ForegroundColor Green

Step "完成 —— 直接在模拟器窗口里测试吧"
Write-Host @"
提示：
  · 语音测试：模拟器内按住麦克风说话（走你电脑麦克风，首次会请求权限）
  · 看日志  ：$Adb logcat -s flutter
  · 截屏    ：$Adb exec-out screencap -p > screen.png
"@ -ForegroundColor Green
