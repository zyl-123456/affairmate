# parallel_dev.ps1 · 事务伴侣 —— 多分支并行开发助手
# 用途：把「一个分支一个任务、多个对话窗口同时推进、最后统一合并」这套流程一键化
# 依据：开发驱动文档/00-驱动开发规则.md 11.7（分支两层制 + git worktree）
# 详解：docs/多分支并行开发手册.md
#
# 用法：
#   派单  powershell -File tools\parallel_dev.ps1 new  -Task "feat/xxx" -Goal "一句话目标" -Files "a.dart,b.dart" -Standard "完成标准"
#   查看  powershell -File tools\parallel_dev.ps1 list
#   收口  powershell -File tools\parallel_dev.ps1 merge -Tasks "feat/a,feat/b"
#   清理  powershell -File tools\parallel_dev.ps1 clean -Task "feat/xxx"
#         powershell -File tools\parallel_dev.ps1 clean -All
#
# 依赖：git 在 PATH；Flutter=D:\flutter；主仓=D:\000-me-work\事务伴侣

param(
    [Parameter(Position = 0)]
    [ValidateSet("new", "list", "merge", "clean")]
    [string]$Action = "list",
    [string]$Task = "",        # 单个分支名，如 feat/voice-ui
    [string]$Goal = "",        # 派单：一句话目标
    [string]$Files = "",       # 派单：允许改动的文件（逗号分隔）
    [string]$Standard = "",    # 派单：完成标准
    [string]$Tasks = "",       # 收口：多个分支（逗号分隔）
    [switch]$All,              # clean：清理所有已合并分支
    [switch]$NoWarmup,         # new：跳过车间预热（省 1-3 分钟，但工人首次编译要等）
    [switch]$Force             # clean：连未合并的分支一起删
)

$Repo     = "D:\000-me-work\事务伴侣"
$WtRoot   = "D:\000-me-work"
$ShopRoot = "D:\sw_build"

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "  [XX] $m" -ForegroundColor Red; exit 1 }

function Get-Slug($b)  { return (($b -replace '^(feat|exp)/', '') -replace '[^a-zA-Z0-9-]', '-') }
function Get-WtDir($b) { return "$WtRoot\wt-$(Get-Slug $b)" }
function Get-Shop($b)  { return "$ShopRoot-$(Get-Slug $b)" }

function Invoke-Git([string[]]$GitArgs) {
    # git 把进度信息写 stderr，PowerShell 会把它渲染成红色 NativeCommandError 刷屏；
    # 这里先收进临时文件，只在命令真的失败时才打出来
    $errLog = Join-Path $env:TEMP "parallel_dev_git_err.txt"
    & git @GitArgs 2>$errLog | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $errLog) { Get-Content $errLog | Write-Host }
        Die "git $($GitArgs -join ' ') 执行失败"
    }
}

function Get-DevBranches {
    $a = @(git -C $Repo for-each-ref --format='%(refname:short)' 'refs/heads/feat/*')
    $b = @(git -C $Repo for-each-ref --format='%(refname:short)' 'refs/heads/exp/*')
    return @($a) + @($b)
}

# ---------------------------------------------------------------- new · 派单
if ($Action -eq "new") {
    if ([string]::IsNullOrWhiteSpace($Task)) { Die "new 需要 -Task ""feat/xxx""" }
    if ($Task -notmatch '^(feat|exp)/[a-z0-9][a-z0-9-]*$') {
        Die "分支名必须是 feat/小写英文 或 exp/小写英文，例如 feat/voice-ui"
    }
    $dir  = Get-WtDir $Task
    $shop = Get-Shop  $Task

    Step "派单：$Task"
    if (git -C $Repo branch --list $Task) { Die "分支 $Task 已存在（换名，或先 clean 掉旧的）" }
    if (Test-Path $dir)  { Die "目录已存在：$dir" }
    if (Test-Path $shop) { Die "车间已存在：$shop" }

    Step "① 建分支 + 检出独立目录 $dir"
    Invoke-Git @("-C", $Repo, "worktree", "add", "-b", $Task, $dir, "main")
    Ok "目录就绪"

    if (-not $NoWarmup) {
        Step "② 预热独立编译车间 $shop（同步源码 + 拉依赖，约 1-3 分钟）"
        & powershell -NoProfile -File "$Repo\tools\build_all.ps1" -Project $dir -Workshop $shop -SyncOnly
        if ($LASTEXITCODE -ne 0) { Warn "预热失败（不影响开工，工人首次编译会自己拉依赖）" }
        else { Ok "车间就绪" }
    } else {
        Warn "已跳过车间预热"
    }

    Step "③ 生成任务单 _任务单.md"
    $fileList = if ([string]::IsNullOrWhiteSpace($Files)) { "（未指定——请工人会话自行判断，但不得越界到他人文件）" } else { $Files }
    $std      = if ([string]::IsNullOrWhiteSpace($Standard)) { "flutter test 全绿 + Windows 编译通过" } else { $Standard }
    # 注意：必须用单引号 here-string（@''@），双引号版本会把反引号当转义符，吃掉文件名首字符
    $tpl = @'
# 任务单 · {0}

- **分支**：{0}
- **工作目录**（本对话唯一工作区）：{1}
- **编译车间**：{2}
- **任务目标**：{3}
- **允许改动的文件**：{4}
- **完成标准**：{5}

## 干活纪律（违反会给合并埋雷）

1. 只改上面列出的文件；不碰 开发驱动文档/、START_HERE.md、verify.py（事实线与编号权只在 main）。
2. 不切分支、不改别人的文件、不动 app/pubspec.yaml（要加依赖包必须先报工头）。
3. 自测（在车间里跑）：cd {2}   然后   flutter test
4. 编译验证：powershell -File tools\build_all.ps1 -Project {1} -Workshop {2}
5. 干完提交（git add -A && git commit），并在对话最后输出这一行完工报告：

   BRANCH_DONE | {0} | 改动文件: xxx | 测试: n/n 绿 | 备注: 无

6. 不用管合并、不用更新 04 文档、不用分配 M 编号——收口由工头统一做。
'@
    $order = $tpl -f $Task, $dir, $shop, $Goal, $fileList, $std
    $orderPath = Join-Path $dir "_任务单.md"
    [System.IO.File]::WriteAllText($orderPath, $order, (New-Object System.Text.UTF8Encoding $true))
    Ok "任务单：$orderPath"

    Step "下一步（老大操作）"
    Write-Host @"
  1) 新开一个 WorkBuddy 对话窗口，把工作区切到：
       $dir
  2) 把任务单内容（上面这个文件）整段粘进新对话，工人即可开工
  3) 想几个任务并行，就对新窗口重复本命令（换 -Task 名）
  4) 全部报 BRANCH_DONE 后，回主目录执行：
       powershell -File tools\parallel_dev.ps1 merge -Tasks "$Task"
"@ -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------- list · 查看
if ($Action -eq "list") {
    Step "并行任务一览（主仓：$Repo）"
    $branches = Get-DevBranches
    if (-not $branches -or $branches.Count -eq 0) {
        Write-Host "  当前没有并行分支。派单：powershell -File tools\parallel_dev.ps1 new -Task ""feat/xxx"" -Goal ""..."" "
        exit 0
    }
    foreach ($b in $branches) {
        $dir  = Get-WtDir $b
        $shop = Get-Shop  $b
        $hasDir  = Test-Path $dir
        $merged  = @(git -C $Repo branch --merged main --list $b)
        $state   = if ($merged.Count -gt 0) { "已合并" } else { "进行中" }
        $last    = if ($hasDir) { (git -C $dir log -1 --oneline) } else { "(无目录)" }
        $dirtyN  = 0
        if ($hasDir) { $dirtyN = @(git -C $dir status --porcelain).Count }
        Write-Host "`n  ■ $b  [$state]"
        Write-Host "      目录  ：$dir  $(if($hasDir){'√'}else{'× 未检出'})"
        Write-Host "      车间  ：$shop  $(if(Test-Path $shop){'√'}else{'×'})"
        Write-Host "      未提交：$dirtyN 个文件"
        Write-Host "      最新  ：$last"
        if ($dirtyN -gt 0) { Warn "      ↑ 有未提交改动，收口前先让工人会话提交" }
    }
    Write-Host "`n  收口命令：powershell -File tools\parallel_dev.ps1 merge -Tasks ""$($branches -join ',')""" -ForegroundColor Cyan
    exit 0
}

# ---------------------------------------------------------------- merge · 收口
if ($Action -eq "merge") {
    if ([string]::IsNullOrWhiteSpace($Tasks)) { Die "merge 需要 -Tasks ""feat/a,feat/b""" }
    $arr = @($Tasks -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })

    $cur = (git -C $Repo rev-parse --abbrev-ref HEAD).Trim()
    if ($cur -ne "main") { Die "主目录当前在 $cur 分支；收口必须在 main 上（先切回 main）" }
    $dirty = @(git -C $Repo status --porcelain)
    if ($dirty.Count -gt 0) {
        Warn "主目录有未提交改动，先处理干净再收口："
        $dirty | ForEach-Object { Write-Host "      $_" }
        exit 1
    }

    Step "收口：准备把 $($arr -join '、') 依次并入 main"
    foreach ($b in $arr) {
        if (-not (git -C $Repo branch --list $b)) { Warn "分支 $b 不存在，跳过"; continue }
        if (@(git -C $Repo branch --merged main --list $b).Count -gt 0) { Ok "$b 已合并，跳过"; continue }

        $dir = Get-WtDir $b
        if (Test-Path $dir) {
            $d = @(git -C $dir status --porcelain)
            if ($d.Count -gt 0) { Warn "$b 有 $($d.Count) 个未提交改动，跳过（先让工人会话 commit）"; continue }
        }

        Step "合并 $b → main"
        & git -C $Repo merge --no-ff $b -m "merge: $b 收口合并" 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            $conf = @(git -C $Repo diff --name-only --diff-filter=U)
            Warn "合并 $b 时冲突，已停下（不会硬并）。冲突文件："
            $conf | ForEach-Object { Write-Host "      $_" }
            Write-Host @"

  处理办法：
    1) 打开上面的文件，按 <<<<<<< / ======= / >>>>>>> 标记人工裁决（业务逻辑不定就问老大）
    2) git add <文件>
    3) git commit -m "merge: $b 解决冲突"
    4) 重跑同一条 merge 命令（已合并的会自动跳过）
"@ -ForegroundColor Yellow
            exit 1
        }
        Ok "$b 合并完成"
    }

    Step "全部合并完成 —— 请执行收口四步"
    Write-Host @"
  1) 04-实现过程记录.md 登记 M 编号（每个分支一条）
  2) 必要时补 01/02/03 文档
  3) E:\anaconda\python.exe verify.py   必须全绿
  4) powershell -File tools\build_all.ps1   重编 Windows 预览 + APK（交付物铁律：合并后当轮重编）

  清理样板间：powershell -File tools\parallel_dev.ps1 clean -All
"@ -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------- clean · 清理
if ($Action -eq "clean") {
    if ($All) {
        $list = Get-DevBranches
    } elseif (-not [string]::IsNullOrWhiteSpace($Task)) {
        $list = @($Task)
    } else {
        Die "clean 需要 -Task ""feat/xxx"" 或 -All"
    }

    Step "清理样板间"
    foreach ($b in $list) {
        $dir  = Get-WtDir $b
        $shop = Get-Shop  $b
        $merged = (@(git -C $Repo branch --merged main --list $b).Count -gt 0)
        if (-not $merged -and -not $Force) { Warn "$b 尚未合并到 main，跳过（确认要删加 -Force）"; continue }

        if (Test-Path $dir) {
            & git -C $Repo worktree remove --force $dir 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) { Warn "$dir 移除失败（可能有 exe/进程占用），稍后重试" }
            else { Ok "已移除目录 $dir" }
        }
        if (git -C $Repo branch --list $b) {
            if ($Force) { & git -C $Repo branch -D $b | Out-Host } else { & git -C $Repo branch -d $b | Out-Host }
            Ok "已删除分支 $b"
        }
        if (Test-Path $shop) {
            try {
                Remove-Item -Recurse -Force $shop -ErrorAction Stop
                Ok "已删除车间 $shop"
            } catch {
                Warn "车间 $shop 删除失败（被占用或受安全策略拦截），请手动删除该目录"
            }
        }
    }
    Write-Host "`n  剩余并行分支：" -ForegroundColor Cyan
    & git -C $Repo worktree list | Out-Host
    exit 0
}
