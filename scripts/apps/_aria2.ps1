#requires -Version 7.0
<#
.SYNOPSIS
    应用生命周期域私有高速并发下载引擎 (aria2 专属)

.DESCRIPTION
    基于 aria2c 多连接并发切片与断点校验的高性能内部工具算子。
    恪守单主干确定性、Fail-Fast 与极简高信噪比输出：
    1. 唯一锚定 aria2c 引擎，杜绝多重降级与隐式回退；
    2. 若未就绪 aria2c 依赖直接中断报错，指引用户就绪环境；
    3. 支持分段并发、零磁盘预分配与下载终态字节校验；
    4. 流式捕获并解析底层输出，屏蔽冗长重定向 URL 与调试噪点，呈现单行极简动态进度；
    5. 命名采用下划线前缀 (_aria2.ps1) 明确标识为领域私有辅助算子，隔离于编排门面实体清单。

.PARAMETER Url
    待下载目标资源的 HTTP/HTTPS 绝对 URL 地址。

.PARAMETER OutFile
    下载产物在本地的绝对保存目标路径。

.PARAMETER Description
    文件语义描述，用于控制台交互告知与进度高亮呈现。默认 "文件"。

.PARAMETER MinBytes
    有效性校验门禁所允许的最小字节数。默认 1024 字节。

.PARAMETER TimeoutSec
    网络请求与传输单次超时时间阈值（秒）。默认 300 秒。

.PARAMETER Connections
    aria2 单任务并发连接数与分段切片数 (-x / -s / -j)。默认 8。

.EXAMPLE
    pwsh -File .\scripts\apps\_aria2.ps1 -Url "https://example.com/pkg.zip" -OutFile "$env:TEMP\pkg.zip" -Description "测试包"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [Parameter(Mandatory = $true)]
    [string]$OutFile,

    [string]$Description = "文件",

    [long]$MinBytes = 1024,

    [int]$TimeoutSec = 300,

    [int]$Connections = 8
)

$ErrorActionPreference = "Stop"

# 1. 嗅探 aria2c 依赖 (严格唯一锚定，零兜底降级)
$scoopRoot = if ($env:SCOOP -and (Test-Path $env:SCOOP)) { $env:SCOOP } else { "D:\prog\scoop" }
$aria2Candidates = @(
    (Join-Path $scoopRoot "shims\aria2c.exe"),
    (Join-Path $scoopRoot "apps\aria2\current\aria2c.exe")
)
$aria2Exe = $aria2Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $aria2Exe) {
    $aria2Exe = (Get-Command "aria2c.exe" -ErrorAction SilentlyContinue).Source
}

if (-not $aria2Exe -or -not (Test-Path $aria2Exe)) {
    throw "【依赖缺失】未检测到 aria2c 下载引擎！本脚本强依赖 aria2 进行多线程并发下载，请先就绪 Scoop 并安装: scoop install aria2"
}

# 2. 准备目录与清理旧残留
$destDir = Split-Path -Path $OutFile -Parent
if ($destDir -and -not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}
$fileName = Split-Path -Path $OutFile -Leaf
$aria2Control = "$OutFile.aria2"

if (Test-Path $OutFile) { Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue }
if (Test-Path $aria2Control) { Remove-Item -Path $aria2Control -Force -ErrorAction SilentlyContinue }

Write-Host "⬇️  正在通过 aria2 并发下载 $Description..." -ForegroundColor Cyan

# 3. 构造参数并通过进程宿主捕获流式输出，实施高信噪比精炼呈现
$argList = @(
    "-x", "$Connections",
    "-s", "$Connections",
    "-j", "$Connections",
    "--file-allocation=none",
    "--allow-overwrite=true",
    "--auto-file-renaming=false",
    "--connect-timeout=30",
    "--timeout=$TimeoutSec",
    "--console-log-level=warn",
    "--download-result=hide",
    "-d", "`"$destDir`"",
    "-o", "`"$fileName`"",
    "`"$Url`""
)

$pinfo = [System.Diagnostics.ProcessStartInfo]::new($aria2Exe)
$pinfo.Arguments = $argList -join ' '
$pinfo.RedirectStandardOutput = $true
$pinfo.RedirectStandardError = $true
$pinfo.UseShellExecute = $false
$pinfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$pinfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

$proc = [System.Diagnostics.Process]::Start($pinfo)
$errLines = [System.Collections.Generic.List[string]]::new()
$hasReadout = $false
$lastPrintTime = [System.DateTime]::MinValue

try {
    while (-not $proc.StandardOutput.EndOfStream) {
        $rawLine = $proc.StandardOutput.ReadLine()
        if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
        $line = $rawLine.Trim()

        # 精确正则匹配 aria2 原生进度字段: [#gid transferred/total(pct%) CN:x DL:speed ETA:time]
        if ($line -match '^\[#\w+\s+(?<transferred>[^\(]+)\((?<pct>[^\)]+)\).*?(?:CN:(?<cn>\d+)).*?DL:(?<speed>[^\s\]]+)(?:\s+ETA:(?<eta>[^\s\]]+))?\]') {
            $hasReadout = $true
            $now = [System.DateTime]::UtcNow
            if (($now - $lastPrintTime).TotalMilliseconds -ge 120) {
                $lastPrintTime = $now
                $pct = $Matches['pct'].Trim()
                $transferred = $Matches['transferred'].Trim()
                $speed = $Matches['speed'].Trim()
                $etaStr = if ($Matches['eta']) { " | 剩余: $($Matches['eta'].Trim())" } else { "" }
                $cnStr = if ($Matches['cn']) { " | 并发: $($Matches['cn'].Trim())" } else { "" }
                Write-Host -NoNewline ("`r   ⬇️ 进度: {0,4} ({1}) [速度: {2}/s{3}{4}]   " -f $pct, $transferred, $speed, $etaStr, $cnStr)
            }
        } elseif ($line -match '\[ERROR\]|errorCode=') {
            $errLines.Add($line)
        }
    }
} finally {
    $stdErr = $proc.StandardError.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($stdErr)) { $errLines.Add($stdErr.Trim()) }
    $proc.WaitForExit()
}

if ($hasReadout) { Write-Host "" }

# 4. 退出代码与完整性硬校验 (Fail-Fast 抛错)
if ($proc.ExitCode -ne 0) {
    if (Test-Path $OutFile) { Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $aria2Control) { Remove-Item -Path $aria2Control -Force -ErrorAction SilentlyContinue }
    $errMsg = if ($errLines.Count -gt 0) { ($errLines | Select-Object -Unique) -join '; ' } else { "进程退出代码: $($proc.ExitCode)" }
    throw "下载 $Description 失败: aria2c 异常退出 (代码 $($proc.ExitCode))。详情: $errMsg"
}

if (-not (Test-Path $OutFile) -or ((Get-Item $OutFile).Length -lt $MinBytes)) {
    if (Test-Path $OutFile) { Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $aria2Control) { Remove-Item -Path $aria2Control -Force -ErrorAction SilentlyContinue }
    throw "下载 $Description 失败: 产物不存在或未达到有效字节阈值 ($MinBytes 字节)。"
}

Write-Host "   ✔ 下载成功 ($([math]::Round((Get-Item $OutFile).Length / 1MB, 2)) MB)" -ForegroundColor Green
return
