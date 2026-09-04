# release_public.ps1 · 私有开发仓 → 公开仓发布同步
# 用途：把私有仓（D:\000-me-work\事务伴侣）的白名单子集镜像到公开仓
#       （D:\000-me-work\affairmate），供推 GitHub。
# 白名单机制 = 天然安全阀：不在 $SyncMap 上的一律不进公开仓（SEC-004 兜底）。
# 正本在私有仓 tools/，同步时随 tools/ 一并镜像到公开仓（公开仓副本勿手改）。
# 用法：powershell -File tools\release_public.ps1 [-Message "发布说明"]

param(
    [string]$Message = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Private = "D:\000-me-work\事务伴侣"
$Public  = "D:\000-me-work\affairmate"

# 同步白名单（私有仓相对路径，公开仓同构）
$SyncDirs = @("app", "tools", "docs")

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

Step "校验两仓在位"
if (-not (Test-Path "$Private\app\pubspec.yaml")) { throw "私有仓不存在或结构异常：$Private" }
if (-not (Test-Path "$Public\README.md")) { throw "公开仓不存在或未初始化：$Public" }
if (-not (Test-Path "$Private\tools\release_public.ps1")) { throw "私有仓缺 release_public.ps1 正本" }

Step "记录私有仓当前提交（写进公开提交信息做溯源）"
$srcHash = (git -C $Private rev-parse --short HEAD)
$srcDate = (Get-Date -Format "yyyy-MM-dd HH:mm")

Step "镜像白名单目录（robocopy /MIR，增删改全对齐）"
foreach ($dir in $SyncDirs) {
    $src = Join-Path $Private $dir
    $dst = Join-Path $Public  $dir
    if (-not (Test-Path $src)) { Write-Host "跳过（源不存在）：$dir" -ForegroundColor Yellow; continue }
    # /MIR 镜像；/XD 排除缓存目录；/NFL /NDL 关文件级日志；robocopy 0-7 都是成功
    robocopy $src $dst /MIR /XD .dart_tool build ephemeral .idea .vscode /NFL /NDL /NJH /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy 失败（$dir，代码 $LASTEXITCODE）" }
    Write-Host "已镜像：$dir"
}

Step "安全自检：公开仓暂存区不得出现敏感模式"
git -C $Public add -A
$suspects = git -C $Public diff --cached --name-only | Select-String -Pattern "\.(env|pem|key|keystore|jks)$|secrets/|\.workbuddy|providers\.json"
if ($suspects) {
    git -C $Public reset | Out-Null
    throw "检出疑似敏感文件，已中止：$($suspects -join ', ')"
}
Write-Host "安全自检通过（无敏感文件混入）" -ForegroundColor Green

Step "公开仓提交（无变更则跳过）"
$hasChange = (git -C $Public diff --cached --name-only | Measure-Object).Count -gt 0
if ($hasChange) {
    if ($Message -eq "") { $Message = "sync from private repo @$srcHash" }
    git -C $Public commit -m "$Message" -m "mirrored-from: $srcHash at $srcDate"
    if ($LASTEXITCODE -ne 0) { throw "公开仓提交失败" }
    Write-Host "已提交" -ForegroundColor Green
} else {
    Write-Host "无变更，跳过提交" -ForegroundColor Yellow
}

Step "完成"
Write-Host @"
公开仓：$Public（HEAD = $((git -C $Public rev-parse --short HEAD))）
溯源：私有仓 $srcHash（$srcDate）
推 GitHub：git -C $Public push
（远端已配置：https://github.com/zyl-123456/affairmate.git）
"@ -ForegroundColor Green
