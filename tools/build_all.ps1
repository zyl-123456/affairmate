# build_all.ps1 · 事务伴侣一键构建流水线
# 用途：源码同步到 ASCII 编译车间 → 双平台编译 → 预览目录更新
# 背景：项目路径含中文（D:\000-me-work\事务伴侣），MSBuild/CMake 会按 GBK 误读导致
#       "锟斤拷"路径错误；junction 无效（CMake 解析回真实路径），必须复制源码到
#       纯 ASCII 路径编译（详见 开发驱动文档/04 坑位速查表 2026-09-04）。
# 用法：powershell -File tools\build_all.ps1 [-SkipAndroid] [-SkipWindows]
# 依赖：Flutter=D:\flutter，JDK=D:\jdk\jdk-17.0.20.1+1，车间=D:\sw_build

param(
    [switch]$SkipAndroid,
    [switch]$SkipWindows
)

$ErrorActionPreference = "Stop"

$Project   = "D:\000-me-work\事务伴侣"
$App       = "$Project\app"
$Workshop  = "D:\sw_build"
$Preview   = "$Project\预览版-Windows"
$Flutter   = "D:\flutter\bin\flutter.bat"
$Env:JAVA_HOME = "D:\jdk\jdk-17.0.20.1+1"

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# ---------- 1. 车间同步（排除 build/.dart_tool 缓存） ----------
Step "同步源码到编译车间 $Workshop"
New-Item -ItemType Directory -Force -Path $Workshop | Out-Null
foreach ($item in @("lib", "android", "windows", "integration_test")) {
    if (Test-Path "$Workshop\$item") { Remove-Item -Recurse -Force "$Workshop\$item" }
    Copy-Item -Recurse "$App\$item" "$Workshop\$item"
}
# 关键：清掉从源工程带过来的 ephemeral 符号链接缓存（指向原路径的旧链接会让 flutter 报 errno 183）
if (Test-Path "$Workshop\windows\flutter\ephemeral") {
    Remove-Item -Recurse -Force "$Workshop\windows\flutter\ephemeral"
}
foreach ($f in @("pubspec.yaml", "pubspec.lock", "analysis_options.yaml")) {
    Copy-Item "$App\$f" "$Workshop\$f" -Force
}
Write-Host "源码同步完成"

# ---------- 2. pub get（容错：advisories 缓存偶崩时依赖未变可跳过） ----------
Step "拉取依赖"
Push-Location $Workshop
$pubOk = $true
try {
    # 注意：不在全局 Stop 偏好下重定向 stderr（pub 的 NativeCommandError 会升级为终止错误）
    & $Flutter pub get | Out-Null
    if ($LASTEXITCODE -ne 0) { $pubOk = $false }
} catch {
    $pubOk = $false
} finally { Pop-Location }

if (-not $pubOk) {
    Write-Host "pub get 失败（可能是 advisories 缓存 bug）——依赖未变时可直接继续" -ForegroundColor Yellow
    if (-not (Test-Path "$Workshop\.dart_tool\package_config.json")) {
        throw "package_config.json 缺失，无法继续编译"
    }
    Write-Host "package_config 完好，继续编译" -ForegroundColor Yellow
}

# ---------- 3. Windows Release ----------
if (-not $SkipWindows) {
    Step "编译 Windows Release"
    Push-Location $Workshop
    try {
        & $Flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "Windows 编译失败" }
    } finally { Pop-Location }

    Step "更新预览目录 $Preview"
    New-Item -ItemType Directory -Force -Path $Preview | Out-Null
    Get-ChildItem $Preview | Where-Object { $_.Name -ne "使用说明.md" } | Remove-Item -Recurse -Force
    Copy-Item -Recurse "$Workshop\build\windows\x64\runner\Release\*" $Preview
    # 使用说明正本在 docs/，构建时同步副本
    Copy-Item "$Project\docs\使用说明-Windows预览版.md" "$Preview\使用说明.md" -Force
    Write-Host "预览目录已更新（exe + dll + data + 使用说明）"
}

# ---------- 4. Android debug APK（内部验证用，不进交付——C-002） ----------
if (-not $SkipAndroid) {
    Step "编译 Android debug APK"
    Push-Location $Workshop
    try {
        & $Flutter build apk --debug
        if ($LASTEXITCODE -ne 0) { throw "Android 编译失败" }
    } finally { Pop-Location }
    Write-Host "APK：$Workshop\build\app\outputs\flutter-apk\app-debug.apk"
}

Step "完成"
Write-Host @"
产物位置：
  Windows 预览：$Preview\shiwu_companion.exe
  Android APK ：$Workshop\build\app\outputs\flutter-apk\app-debug.apk
下步验证（可选）：
  UI 冒烟    ：flutter test integration_test\smoke_test.dart -d windows（在 $Workshop 下）
  模拟器装机：adb install -r D:\sw_build\build\app\outputs\flutter-apk\app-debug.apk
"@ -ForegroundColor Green
