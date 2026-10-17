#requires -Version 7.0
<#
.SYNOPSIS
    外壳交互与终端底座生产力基线

.DESCRIPTION
    Windows 11 操作系统外壳交互、资源管理器视图、Windows Terminal 生产力底座与输入法调优模块。
    1. 专为 PowerShell 7+ (pwsh) 编写，遵循声明式五阶管线。
    2. 还原 Win10 经典完整右键菜单，调优文件扩展名、系统时钟秒数与完整路径展示。
    3. 精简资源管理器快捷栏（仅保留桌面与下载，穿透剥离系统出厂预置项）。
    4. 彻底卸载 OneDrive、清理用户目录残留与侧边栏驻留，剥离图库与遗留已知文件夹沙盒化。
    5. 净化左侧导航窗格（隐藏网络与主页，直达“此电脑”），禁用外置介质自动播放。
    6. 锁屏直达密码框、切断聚焦推广并锁定纯色/图片背景。
    7. 调优微软拼音输入法（关闭 Shift+Space、新窗口默认英文、切断云端候选）。
    8. 探测并自愈注册工作站等宽字体基线 (Maple Mono NL NFMono CN)。
    9. 配置 Windows Terminal 生产力底座（默认 pwsh、自适应路径、磨砂亚克力、纳管现代 Shell 与字体注入）。
    10. 固化 pwsh $PROFILE 前缀历史检索（HistorySearchBackward/Forward）与预测。
    11. 禁用辅助连击弹窗（粘滞键）与关闭鼠标指针加速度（锁定 1:1 纯线性位移）。

.PARAMETER Mode
    操作动词: Sync (执行加固/默认) 或 CheckOnly (只查不改/体检巡检)。

.PARAMETER Profile
    配置预设: Full (黄金深度基线/默认) 或 General (通用稳健基线)。

.PARAMETER Yes
    非交互自动确认放行。

.PARAMETER NonInteractive
    非交互模式，遇到确认直接放行执行。

.EXAMPLE
    # 只读体检巡检
    pwsh -File .\scripts\windows\shell.ps1 -Mode CheckOnly

    # 交互式检查与加固
    pwsh -File .\scripts\windows\shell.ps1

    # 无交互一键全量对齐
    pwsh -File .\scripts\windows\shell.ps1 -Yes
#>

[CmdletBinding()]
param(
    [ValidateSet("Sync", "CheckOnly")]
    [string]$Mode = "Sync",

    [ValidateSet("Full", "General")]
    [string]$Profile = "Full",

    [switch]$Yes,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

# ==============================================================================
# 环境校验：强制锁定 PowerShell 7+ 与 管理员权限
# ==============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "【版本错误】此脚本针对 PowerShell 7 (pwsh) 现代运行时深度定制，严禁在 Windows PowerShell 5.1 下执行！"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
if (-not $isAdmin) {
    throw "【权限错误】此脚本必须以管理员身份运行！请右键 pwsh 选择 [以管理员身份运行] 后重新执行。"
}

# ==============================================================================
# 内部辅助函数
# ==============================================================================
function Ensure-Key([string]$path) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
}

function Set-RegDword([string]$Path, [string]$Name, [int]$Value) {
    Ensure-Key $Path
    $cur = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($cur -ne $Value) {
        try {
            Set-ItemProperty -Path $Path -Name $Name -Type DWord -Value $Value -Force -ErrorAction Stop
        } catch {
            $regPath = $Path -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
            reg.exe add $regPath /v $Name /t REG_DWORD /d $Value /f *>$null
        }
    }
}

function Test-RegDword([string]$Path, [string]$Name, [int]$Expected) {
    if (-not (Test-Path $Path)) { return $false }
    $val = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    return ($null -ne $val -and [int]$val -eq $Expected)
}

function Update-ManagedConfigFile([string]$FilePath, [string]$BlockTag, [string]$BlockContent) {
    $parentDir = Split-Path -Path $FilePath -Parent
    if (-not (Test-Path -Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $startMarker = "# >>> managed: $BlockTag >>>"
    $endMarker   = "# <<< managed: $BlockTag <<<"
    $injection   = "$startMarker`r`n$BlockContent`r`n$endMarker"

    $existingContent = ""
    if (Test-Path -Path $FilePath) {
        $existingContent = [System.IO.File]::ReadAllText($FilePath, [System.Text.UTF8Encoding]::new($false))
    }

    $regex = "(?s)[ \t]*\Q$startMarker\E\r?\n.*?\r?\n[ \t]*\Q$endMarker\E"

    if ($existingContent -match $regex) {
        $newContent = [System.Text.RegularExpressions.Regex]::Replace($existingContent, $regex, $injection)
    } else {
        if ([string]::IsNullOrWhiteSpace($existingContent)) {
            $newContent = "$injection`r`n"
        } else {
            $trimmed = $existingContent.TrimEnd("`r", "`n")
            $newContent = "$trimmed`r`n`r`n$injection`r`n"
        }
    }

    if ($existingContent -ne $newContent) {
        [System.IO.File]::WriteAllText($FilePath, $newContent, [System.Text.UTF8Encoding]::new($false))
    }
}

# ==============================================================================
# 阶段 1: 全量只读嗅探与状态比对 (Plan & Diff)
# ==============================================================================
$items = @(
    [PSCustomObject]@{
        Name   = "还原 Win10 经典完整右键菜单"
        Check  = {
            return Test-Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
        }
        Action = {
            New-Item -Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" -Value "" -Force | Out-Null
        }
    },
    [PSCustomObject]@{
        Name   = "调优资源管理器与任务栏视图 (显示后缀/秒数/完整路径/免快捷方式后缀)"
        Check  = {
            $adv = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            $c1 = (Test-RegDword $adv "HideFileExt" 0) -and (Test-RegDword $adv "LaunchTo" 1) -and (Test-RegDword $adv "ShowSecondsInSystemClock" 1)
            $c2 = Test-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState" "FullPath" 1
            $c3 = (Test-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer" "ShowRecent" 0) -and (Test-RegDword $adv "ShowSyncProviderNotifications" 0) -and (Test-RegDword $adv "Start_TrackDocs" 0)
            return ($c1 -and $c2 -and $c3)
        }
        Action = {
            $adv = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            Ensure-Key $adv
            Set-ItemProperty -Path $adv -Name "HideFileExt" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $adv -Name "Hidden" -Type DWord -Value 1 -Force
            Set-ItemProperty -Path $adv -Name "LaunchTo" -Type DWord -Value 1 -Force
            Set-ItemProperty -Path $adv -Name "SeparateProcess" -Type DWord -Value 1 -Force
            Set-ItemProperty -Path $adv -Name "SnapAssist" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $adv -Name "TaskbarAl" -Type DWord -Value 1 -Force
            Set-ItemProperty -Path $adv -Name "TaskbarDa" -Type DWord -Value 0 -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $adv -Name "TaskbarMn" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $adv -Name "ShowTaskViewButton" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $adv -Name "ShowCopilotButton" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $adv -Name "ShowSecondsInSystemClock" -Type DWord -Value 1 -Force
            Set-ItemProperty -Path $adv -Name "ShowSyncProviderNotifications" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $adv -Name "Start_Layout" -Type DWord -Value 1 -Force
            Set-ItemProperty -Path $adv -Name "Start_TrackDocs" -Type DWord -Value 0 -Force

            Ensure-Key "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState"
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState" -Name "FullPath" -Type DWord -Value 1 -Force

            $exp = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"
            Set-ItemProperty -Path $exp -Name "ShowRecent" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $exp -Name "ShowFrequent" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $exp -Name "ShowCloudFilesInQuickAccess" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $exp -Name "link" -Type Binary -Value ([byte[]](0,0,0,0)) -Force

            Get-ChildItem -Path "$env:APPDATA\Microsoft\Windows\Recent" -Exclude "AutomaticDestinations" -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "$env:APPDATA\Microsoft\Windows\Recent\CustomDestinations\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Name   = "精简资源管理器快捷栏 (仅保留桌面与下载，穿透剥离系统出厂预置项)"
        Check  = {
            $exp = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"
            $frequent = (Get-ItemProperty $exp -Name "ShowFrequent" -ErrorAction SilentlyContinue).ShowFrequent
            $recent   = (Get-ItemProperty $exp -Name "ShowRecent" -ErrorAction SilentlyContinue).ShowRecent
            if ($frequent -ne 0 -or $recent -ne 0) { return $false }

            try {
                $shell = New-Object -ComObject Shell.Application
                $qa = $null
                $homeGuids = @(
                    "shell:::{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
                    "shell:Quick Access",
                    "shell:::{679f85cb-0200-4426-8c76-49e6b8663329}"
                )
                foreach ($hg in $homeGuids) {
                    $folder = $shell.Namespace($hg)
                    if ($folder -and $folder.Items().Count -gt 0) { $qa = $folder; break }
                }
                if (-not $qa) { return $true }

                $targetPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                @(
                    [Environment]::GetFolderPath("Desktop"),
                    (Join-Path $env:USERPROFILE "Downloads")
                ) | Where-Object { $_ -and (Test-Path $_) } | ForEach-Object { [void]$targetPaths.Add((Get-Item $_).FullName) }

                $hasStray = $false
                foreach ($item in $qa.Items()) {
                    $itemPath = $item.Path
                    if ([string]::IsNullOrWhiteSpace($itemPath) -or (-not (Test-Path $itemPath))) { continue }
                    $full = (Get-Item $itemPath -ErrorAction SilentlyContinue).FullName
                    if ($full -and (-not $targetPaths.Contains($full))) {
                        $hasStray = $true
                        break
                    }
                }
                return (-not $hasStray)
            } catch {
                return $true
            }
        }
        Action = {
            $exp = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"
            Set-ItemProperty -Path $exp -Name "ShowFrequent" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $exp -Name "ShowRecent" -Type DWord -Value 0 -Force

            try {
                $shell = New-Object -ComObject Shell.Application
                $qa = $null
                $homeGuids = @(
                    "shell:::{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
                    "shell:Quick Access",
                    "shell:::{679f85cb-0200-4426-8c76-49e6b8663329}"
                )
                foreach ($hg in $homeGuids) {
                    $folder = $shell.Namespace($hg)
                    if ($folder -and $folder.Items().Count -gt 0) { $qa = $folder; break }
                }
                if ($qa) {
                    $keepPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    @(
                        [Environment]::GetFolderPath("Desktop"),
                        (Join-Path $env:USERPROFILE "Downloads")
                    ) | Where-Object { $_ -and (Test-Path $_) } | ForEach-Object { [void]$keepPaths.Add((Get-Item $_).FullName) }

                    foreach ($item in $qa.Items()) {
                        $p = $item.Path
                        $resolved = if ($p -and (Test-Path $p)) { (Get-Item $p -ErrorAction SilentlyContinue).FullName } else { $null }
                        if (-not $resolved -or (-not $keepPaths.Contains($resolved))) {
                            $verbs = $item.Verbs()
                            for ($i = 0; $i -lt $verbs.Count(); $i++) {
                                $v = $verbs.Item($i)
                                if ($v.Name -match '从快速访问取消固定|从“主页”取消固定|Unpin from Quick access|Unpin from Home') {
                                    $v.DoIt()
                                    break
                                }
                            }
                        }
                    }
                }
            } catch { }
        }
    },
    [PSCustomObject]@{
        Name   = "彻底卸载 OneDrive 并清理用户残留与侧边栏驻留"
        Check  = {
            if ($Profile -eq 'General') { return $true }
            $p = Get-Process -Name "OneDrive" -ErrorAction SilentlyContinue
            $exe1 = Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"
            $exe2 = Test-Path "C:\Program Files\Microsoft OneDrive\OneDrive.exe"
            $userOd = Join-Path $env:USERPROFILE "OneDrive"
            $hasUserOd = Test-Path $userOd
            $progDataOd = Join-Path $env:ProgramData "Microsoft OneDrive"
            $hasProgDataOd = Test-Path $progDataOd
            $envOd = [Environment]::GetEnvironmentVariable("OneDrive", "User")
            $clsidPaths = @(
                "HKCU:\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
                "HKLM:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
                "HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
            )
            $isPinned = $false
            foreach ($cp in $clsidPaths) {
                if (Test-Path $cp) {
                    $v = (Get-ItemProperty -Path $cp -Name "System.IsPinnedToNameSpaceTree" -ErrorAction SilentlyContinue)."System.IsPinnedToNameSpaceTree"
                    if ($null -ne $v -and [int]$v -ne 0) { $isPinned = $true; break }
                }
            }
            $gpoOk = Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" 1
            return ($null -eq $p -and -not $exe1 -and -not $exe2 -and -not $hasUserOd -and -not $hasProgDataOd -and [string]::IsNullOrEmpty($envOd) -and (-not $isPinned) -and $gpoOk)
        }
        Action = {
            if ($Profile -eq 'General') { return }
            Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
            $odSetup = "$env:LOCALAPPDATA\Microsoft\OneDrive\Update\OneDriveSetup.exe"
            if (-not (Test-Path $odSetup)) { $odSetup = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe" }
            if (-not (Test-Path $odSetup)) { $odSetup = "$env:SystemRoot\System32\OneDriveSetup.exe" }
            if (Test-Path $odSetup) {
                Start-Process $odSetup -ArgumentList "/uninstall" -Wait -NoNewWindow
            }
            Start-Sleep -Milliseconds 500
            Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue

            # 组策略：彻底阻断 OneDrive 文件同步引擎
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" 1

            # 移除文件资源管理器侧边栏驻留 (跨架构三视图彻底剥离)
            $clsidPaths = @(
                "HKCU:\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
                "HKLM:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
                "HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
            )
            foreach ($cp in $clsidPaths) {
                if (Test-Path $cp) {
                    Set-ItemProperty -Path $cp -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 0 -Force -ErrorAction SilentlyContinue
                }
            }

            # 清理开机自启项与用户环境变量
            Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDrive" -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path "HKCU:\Environment" -Name "OneDrive" -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path "HKCU:\Environment" -Name "OneDriveCommercial" -Force -ErrorAction SilentlyContinue
            [Environment]::SetEnvironmentVariable("OneDrive", $null, "User")
            [Environment]::SetEnvironmentVariable("OneDriveCommercial", $null, "User")

            # 清理个人用户目录残留
            $userOd = Join-Path $env:USERPROFILE "OneDrive"
            if (Test-Path $userOd) {
                Get-ChildItem -Path $userOd -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    $_.Attributes = 'Normal'
                }
                (Get-Item -Path $userOd -Force).Attributes = 'Normal'
                Remove-Item -Path $userOd -Recurse -Force -ErrorAction SilentlyContinue
            }

            # 清理 LocalAppData 残留缓存
            $localOd = "$env:LOCALAPPDATA\Microsoft\OneDrive"
            if (Test-Path $localOd) {
                Remove-Item -Path $localOd -Recurse -Force -ErrorAction SilentlyContinue
            }

            # 清理系统级 ProgramData 残留
            $progDataOd = Join-Path $env:ProgramData "Microsoft OneDrive"
            if (Test-Path $progDataOd) {
                Remove-Item -Path $progDataOd -Recurse -Force -ErrorAction SilentlyContinue
            }

            # 清理注册表配置分支
            Remove-Item -Path "HKCU:\Software\Microsoft\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
        }
    },
    [PSCustomObject]@{
        Name   = "剥离资源管理器图库驻留与遗留已知文件夹沙盒化"
        Check  = {
            if ($Profile -eq 'General') { return $true }
            $galleryClsid = "{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
            $clsidPath = "HKCU:\Software\Classes\CLSID\$galleryClsid"
            $pinnedVal = if (Test-Path $clsidPath) {
                (Get-ItemProperty -Path $clsidPath -Name "System.IsPinnedToNameSpaceTree" -ErrorAction SilentlyContinue)."System.IsPinnedToNameSpaceTree"
            } else { 0 }
            $desktop = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$galleryClsid"
            $zombieFolders = @("3D Objects", "Contacts", "Links", "Searches", "Favorites")
            $activeFolders = @("Saved Games", "Music", "Videos", "Pictures")
            $zombieUnhidden = $zombieFolders | Where-Object {
                $p = Join-Path $env:USERPROFILE $_
                (Test-Path $p) -and (-not ((Get-Item $p -Force).Attributes -match "System" -and (Get-Item $p -Force).Attributes -match "Hidden"))
            }
            $activeUnhidden = $activeFolders | Where-Object {
                $p = Join-Path $env:USERPROFILE $_
                (Test-Path $p) -and ((Get-Item $p -Force).Attributes -notmatch "Hidden")
            }
            return ($pinnedVal -eq 0 -and -not $desktop -and ($zombieUnhidden.Count -eq 0) -and ($activeUnhidden.Count -eq 0))
        }
        Action = {
            if ($Profile -eq 'General') { return }
            $galleryClsid = "{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
            $hklmPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$galleryClsid"
            if (Test-Path $hklmPath) { Remove-Item -Path $hklmPath -Recurse -Force -ErrorAction SilentlyContinue }

            $hkcuClsid = "HKCU:\Software\Classes\CLSID\$galleryClsid"
            Ensure-Key $hkcuClsid
            Set-ItemProperty -Path $hkcuClsid -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 0 -Force

            $zombieFolders = @("3D Objects", "Contacts", "Links", "Searches", "Favorites")
            foreach ($f in $zombieFolders) {
                $p = Join-Path $env:USERPROFILE $f
                if (Test-Path $p) {
                    (Get-Item -Path $p -Force).Attributes = 'Directory', 'Hidden', 'System'
                }
            }

            $activeFolders = @("Saved Games", "Music", "Videos", "Pictures")
            foreach ($f in $activeFolders) {
                $p = Join-Path $env:USERPROFILE $f
                if (Test-Path $p) {
                    (Get-Item -Path $p -Force).Attributes = 'Directory', 'Hidden'
                }
            }
        }
    },
    [PSCustomObject]@{
        Name   = "从左侧导航窗格隐藏网络 (Network) 网上邻居图标"
        Check  = {
            if ($Profile -eq 'General') { return $true }
            $netGuid = "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}"
            $hklmNet = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$netGuid"
            $hkcuNet = "HKCU:\Software\Classes\CLSID\$netGuid"
            $hkcuPinned = if (Test-Path $hkcuNet) {
                (Get-ItemProperty -Path $hkcuNet -Name "System.IsPinnedToNameSpaceTree" -ErrorAction SilentlyContinue)."System.IsPinnedToNameSpaceTree"
            } else { $null }
            return (-not $hklmNet -and ($hkcuPinned -eq 0))
        }
        Action = {
            if ($Profile -eq 'General') { return }
            $netGuid = "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}"
            $hklmPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$netGuid"
            if (Test-Path $hklmPath) { Remove-Item -Path $hklmPath -Recurse -Force -ErrorAction SilentlyContinue }

            $hkcuNet = "HKCU:\Software\Classes\CLSID\$netGuid"
            Ensure-Key $hkcuNet
            Set-ItemProperty -Path $hkcuNet -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 0 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "从左侧导航窗格隐藏小房子主页与用户个人主文件夹 (直达此电脑)"
        Check  = {
            if ($Profile -eq 'General') { return $true }
            $homeGuid = "{f874310e-b6b7-47dc-bc84-b9e6b38f5903}"
            $userGuid = "{59031a47-3f72-44a7-89c5-5595fe6b30ee}"
            $hklmHome = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$homeGuid"
            $hklmUser = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$userGuid"
            $hkcuHome = "HKCU:\Software\Classes\CLSID\$homeGuid"
            $hkcuHomePinned = if (Test-Path $hkcuHome) {
                (Get-ItemProperty -Path $hkcuHome -Name "System.IsPinnedToNameSpaceTree" -ErrorAction SilentlyContinue)."System.IsPinnedToNameSpaceTree"
            } else { $null }
            return (-not $hklmHome -and -not $hklmUser -and ($hkcuHomePinned -eq 0))
        }
        Action = {
            if ($Profile -eq 'General') { return }
            $homeGuid = "{f874310e-b6b7-47dc-bc84-b9e6b38f5903}"
            $userGuid = "{59031a47-3f72-44a7-89c5-5595fe6b30ee}"
            foreach ($g in @($homeGuid, $userGuid)) {
                $hklmPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$g"
                if (Test-Path $hklmPath) { Remove-Item -Path $hklmPath -Recurse -Force -ErrorAction SilentlyContinue }

                $hkcuPath = "HKCU:\Software\Classes\CLSID\$g"
                Ensure-Key $hkcuPath
                Set-ItemProperty -Path $hkcuPath -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 0 -Force
            }
        }
    },
    [PSCustomObject]@{
        Name   = "禁用外置存储介质自动播放"
        Check  = {
            $a = Test-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" "DisableAutoplay" 1
            $b = Test-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoDriveTypeAutoRun" 255
            return ($a -and $b)
        }
        Action = {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" "DisableAutoplay" 1
            Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoDriveTypeAutoRun" 255
        }
    },
    [PSCustomObject]@{
        Name   = "锁屏直达密码/PIN 输入框"
        Check  = {
            return Test-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" "NoLockScreen" 1
        }
        Action = {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" "NoLockScreen" 1
        }
    },
    [PSCustomObject]@{
        Name   = "锁定桌面背景为纯图片并切断 Windows 聚焦"
        Check  = {
            $cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            $c1 = Test-RegDword $cdm "RotatingLockScreenEnabled" 0
            $c2 = Test-RegDword $cdm "RotatingLockScreenOverlayEnabled" 0
            $c3 = Test-RegDword $cdm "SubscribedContent-338387Enabled" 0
            $c4 = Test-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers" "BackgroundType" 0
            return ($c1 -and $c2 -and $c3 -and $c4)
        }
        Action = {
            $cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            Set-RegDword $cdm "RotatingLockScreenEnabled" 0
            Set-RegDword $cdm "RotatingLockScreenOverlayEnabled" 0
            Set-RegDword $cdm "SubscribedContent-338387Enabled" 0
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers" "BackgroundType" 0
        }
    },
    [PSCustomObject]@{
        Name   = "调优微软拼音输入法 (禁用 Shift+Space、新窗口默认英文、切断云候选)"
        Check  = {
            $chs = "HKCU:\Software\Microsoft\InputMethod\Settings\CHS"
            $m = Test-RegDword $chs "Mode" 0
            $c = Test-RegDword $chs "Enable Cloud Candidate" 0
            $hotKey = (Get-ItemProperty "HKCU:\Control Panel\Input Method\Hot Keys\00000011" -Name "Key Modifiers" -ErrorAction SilentlyContinue).'Key Modifiers'
            return ($m -and $c -and ($null -ne $hotKey))
        }
        Action = {
            $hotKeyPath = "HKCU:\Control Panel\Input Method\Hot Keys\00000011"
            Ensure-Key $hotKeyPath
            Set-ItemProperty -Path $hotKeyPath -Name "Key Modifiers" -Type Binary -Value ([byte[]](0, 192, 0, 0)) -Force
            Set-ItemProperty -Path $hotKeyPath -Name "Virtual Key" -Type Binary -Value ([byte[]](0, 0, 0, 0)) -Force

            $chsPath = "HKCU:\Software\Microsoft\InputMethod\Settings\CHS"
            Ensure-Key $chsPath
            Set-ItemProperty -Path $chsPath -Name "Mode" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $chsPath -Name "Enable Cloud Candidate" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $chsPath -Name "Enable Self Learning" -Type DWord -Value 0 -Force
            Set-ItemProperty -Path $chsPath -Name "Enable LiveSticker" -Type DWord -Value 0 -Force
        }
    },
    [PSCustomObject]@{
        Name   = "安装并注册工作站等宽字体基线 (Maple Mono NL NFMono CN)"
        Check  = {
            $regHklm = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
            $regHkcu = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
            $hasHklm = (Get-ItemProperty -Path $regHklm -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -like "*Maple Mono NL*" }
            $hasHkcu = (Get-ItemProperty -Path $regHkcu -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -like "*Maple Mono NL*" }
            return [bool]($hasHklm -or $hasHkcu)
        }
        Action = {
            $tempSandboxDir = Join-Path $env:TEMP ("maple-font-" + [Guid]::NewGuid().ToString("N"))
            $tempZip = Join-Path $env:TEMP ("maple-font-" + [Guid]::NewGuid().ToString("N") + ".zip")
            New-Item -ItemType Directory -Path $tempSandboxDir -Force | Out-Null

            try {
                $remoteBase = $env:VPSBASE_REMOTE_BASE ?? "https://raw.githubusercontent.com/Lokyael/vpsbase"
                $fontAssetUrl = if ($remoteBase -match "raw\.githubusercontent\.com") {
                    "https://raw.githubusercontent.com/Lokyael/vpsbase/assets/latest-maple-mono-nl.zip"
                } else {
                    "$remoteBase/assets/latest-maple-mono-nl.zip"
                }

                Write-Host "  [*] 正在从云端资产源拉取预编译 Maple Mono NL 等宽字体基线..." -ForegroundColor Cyan
                Invoke-RestMethod -Uri $fontAssetUrl -OutFile $tempZip -TimeoutSec 60
                Expand-Archive -Path $tempZip -DestinationPath $tempSandboxDir -Force

                $ttfFiles = Get-ChildItem -Path $tempSandboxDir -Filter "*.ttf" -Recurse -File
                if ($ttfFiles.Count -eq 0) {
                    Write-Warning "解压后的字体包内未发现任何 .ttf 字体文件。"
                    return
                }

                $shellApp = New-Object -ComObject Shell.Application
                $fontsFolder = $shellApp.Namespace(0x14)
                foreach ($file in $ttfFiles) {
                    $fontsFolder.CopyHere($file.FullName, 0x10)
                }
                Write-Host "  [+] Maple Mono NL 等宽字体基线已成功装配至系统字体库" -ForegroundColor Green
            } catch {
                Write-Warning "拉取或安装云端预编译字体包失败: $($_.Exception.Message)。跳过字体配置。"
            } finally {
                if (Test-Path $tempZip) { Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue }
                if (Test-Path $tempSandboxDir) { Remove-Item -Path $tempSandboxDir -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    },
    [PSCustomObject]@{
        Name   = "配置 Windows Terminal 生产力基准 (默认 pwsh、自适应路径、磨砂亚克力与现代 Shell 纳管)"
        Check  = {
            $wtSettings = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
            if (-not (Test-Path $wtSettings)) { $wtSettings = "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json" }
            if (-not (Test-Path $wtSettings)) { return $true }
            try {
                $json = Get-Content -Path $wtSettings -Raw -Encoding UTF8 | ConvertFrom-Json
                $pwshGuid = "{574e775e-4f2a-5b96-ac1e-a2962a402336}"
                $targetStartDir = if ((Test-Path "D:\act") -and $Profile -ne 'General') { "D:\act" } else { $env:USERPROFILE }
                $isDefaultPwsh = ($json.defaultProfile -eq $pwshGuid)
                $isDirMatch = ($null -ne $json.profiles.defaults -and $json.profiles.defaults.startingDirectory -eq $targetStartDir)
                $isAcrylic = ($null -ne $json.profiles.defaults -and $json.profiles.defaults.useAcrylic -eq $true -and ($json.profiles.defaults.acrylicOpacity -eq 0.85 -or $json.profiles.defaults.opacity -eq 85))
                $isCopyOnSelect = ($json.copyOnSelect -eq $true -and $json.copyFormatting -eq "none")
                $azureProfile = $json.profiles.list | Where-Object { $_.guid -eq "{b453ae62-4e3d-5e58-b989-0a998ec441b3}" -or $_.guid -eq "{b453ae62-4e3d-5e58-b989-0a998ec441b8}" -or $_.name -match 'Azure Cloud Shell' }
                $isAzureHidden = ($null -eq $azureProfile -or (-not (@($azureProfile | Where-Object { $_.hidden -ne $true }))))
                
                $regHklm = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
                $regHkcu = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
                $hasMaple = ((Get-ItemProperty -Path $regHklm -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -like "*Maple Mono NL*" }) -or
                            ((Get-ItemProperty -Path $regHkcu -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -like "*Maple Mono NL*" })
                $isFontMatch = if ($hasMaple) {
                    ($null -ne $json.profiles.defaults.font -and $json.profiles.defaults.font.face -eq "Maple Mono NL NFMono CN")
                } else { $true }

                return ($isDefaultPwsh -and $isDirMatch -and $isAcrylic -and $isCopyOnSelect -and $isAzureHidden -and $isFontMatch)
            } catch { return $false }
        }
        Action = {
            $wtSettings = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
            if (-not (Test-Path $wtSettings)) { $wtSettings = "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json" }
            if (-not (Test-Path $wtSettings)) { return }

            $internalDrives = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            try {
                $disks = Get-Disk -ErrorAction Stop | Where-Object { $_.BusType -ne 'USB' }
                $partitions = $disks | Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }
                foreach ($p in $partitions) { [void]$internalDrives.Add("$($p.DriveLetter):") }
            } catch {
                [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' } | ForEach-Object {
                    [void]$internalDrives.Add($_.Name.TrimEnd('\'))
                }
            }

            $testInternalValid = {
                param([string]$path)
                if ([string]::IsNullOrWhiteSpace($path)) { return $false }
                if (-not (Test-Path -Path $path -PathType Leaf)) { return $false }
                $root = [System.IO.Path]::GetPathRoot($path).TrimEnd('\')
                return $internalDrives.Contains($root)
            }

            $scoopRoots = @($env:SCOOP, "D:\prog\scoop", "$env:USERPROFILE\scoop") | Where-Object { $_ -and (Test-Path $_) }

            $pwshExe = $null
            $pathPwsh = Get-Command pwsh.exe -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
            foreach ($cand in $pathPwsh) { if (& $testInternalValid $cand) { $pwshExe = $cand; break } }
            if (-not $pwshExe) {
                foreach ($root in $scoopRoots) {
                    $cand = Join-Path $root "apps\powershell\current\pwsh.exe"
                    if (& $testInternalValid $cand) { $pwshExe = $cand; break }
                }
            }

            $json = Get-Content -Path $wtSettings -Raw -Encoding UTF8 | ConvertFrom-Json

            $setProp = {
                param($target, [string]$name, $value)
                if ($null -eq $target) { return }
                foreach ($item in @($target)) {
                    if ($null -ne $item) {
                        $item | Add-Member -MemberType NoteProperty -Name $name -Value $value -Force
                    }
                }
            }

            $azureProfile = $json.profiles.list | Where-Object { $_.guid -eq "{b453ae62-4e3d-5e58-b989-0a998ec441b3}" -or $_.guid -eq "{b453ae62-4e3d-5e58-b989-0a998ec441b8}" -or $_.name -match 'Azure Cloud Shell' }
            & $setProp $azureProfile "hidden" $true

            if ($Profile -ne 'General') {
                $devBuiltins = @("{61c54bbd-c2c6-5271-96e7-009a87ff44bf}", "{0caa0dad-35be-5f56-a8ff-afceeeaa6101}")
                foreach ($p in $json.profiles.list) {
                    if ($devBuiltins -contains $p.guid -or $p.name -match 'Windows PowerShell 5|Command Prompt|命令提示符') {
                        & $setProp $p "hidden" $true
                    }
                }
            }

            $pwshGuid = "{574e775e-4f2a-5b96-ac1e-a2962a402336}"
            $pwshProfile = $json.profiles.list | Where-Object { $_.guid -eq $pwshGuid -or $_.name -match 'PowerShell 7|pwsh' }
            $pwshCmd = if ($pwshExe) { "`"$pwshExe`" -NoLogo" } else { "pwsh.exe -NoLogo" }
            if (-not $pwshProfile) {
                $newPwsh = [PSCustomObject]@{
                    guid        = $pwshGuid
                    name        = "PowerShell 7"
                    commandline = $pwshCmd
                    tabColor    = "#012456"
                    hidden      = $false
                    environment = [PSCustomObject]@{ POWERSHELL_TELEMETRY_OPTOUT = "1" }
                }
                $json.profiles.list = @($newPwsh) + @($json.profiles.list)
            } else {
                foreach ($p in @($pwshProfile)) {
                    & $setProp $p "commandline" $pwshCmd
                    & $setProp $p "tabColor" "#012456"
                    & $setProp $p "hidden" $false
                    if (-not $p.environment) { & $setProp $p "environment" ([PSCustomObject]@{}) }
                    & $setProp $p.environment "POWERSHELL_TELEMETRY_OPTOUT" "1"
                }
            }
            & $setProp $json "defaultProfile" $pwshGuid

            if (-not $json.profiles.defaults) { & $setProp $json.profiles "defaults" (New-Object PSObject) }
            $targetStartDir = if ((Test-Path "D:\act") -and $Profile -ne 'General') { "D:\act" } else { $env:USERPROFILE }
            & $setProp $json.profiles.defaults "startingDirectory" $targetStartDir
            & $setProp $json.profiles.defaults "useAcrylic" $true
            & $setProp $json.profiles.defaults "acrylicOpacity" 0.85
            & $setProp $json.profiles.defaults "opacity" 85
            & $setProp $json.profiles.defaults "historySize" 20000
            & $setProp $json "copyOnSelect" $true
            & $setProp $json "copyFormatting" "none"
            & $setProp $json "confirmCloseAllTabs" $false

            $regHklm = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
            $regHkcu = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
            $hasMaple = ((Get-ItemProperty -Path $regHklm -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -like "*Maple Mono NL*" }) -or
                        ((Get-ItemProperty -Path $regHkcu -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -like "*Maple Mono NL*" })
            if ($hasMaple) {
                if (-not $json.profiles.defaults.font) { & $setProp $json.profiles.defaults "font" (New-Object PSObject) }
                & $setProp $json.profiles.defaults.font "face" "Maple Mono NL NFMono CN"
                & $setProp $json.profiles.defaults.font "size" 12
            }

            [System.IO.File]::WriteAllText($wtSettings, ($json | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
        }
    },
    [PSCustomObject]@{
        Name   = "配置 pwsh 前缀历史滚动基准 ($PROFILE)"
        Check  = {
            $pwshProfilePath = if ($PROFILE) { $PROFILE } else { Join-Path $env:USERPROFILE "Documents\PowerShell\Microsoft.PowerShell_profile.ps1" }
            if (-not (Test-Path $pwshProfilePath)) { return $false }
            $c = (Get-Content -Path $pwshProfilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) ?? ""
            return ($c -match 'HistorySearchBackward' -and $c -match 'HistorySearchForward')
        }
        Action = {
            $pwshProfilePath = if ($PROFILE) { $PROFILE } else { Join-Path $env:USERPROFILE "Documents\PowerShell\Microsoft.PowerShell_profile.ps1" }
            $pwshBlock = @'
# PSReadLine 按键绑定: 根据已输入前缀滚动历史记录
if (Get-Module -ListAvailable -Name PSReadLine) {
    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineOption -PredictionSource History
    Set-PSReadLineOption -PredictionViewStyle InlineView
}
'@
            Update-ManagedConfigFile $pwshProfilePath "pwsh-history-search" $pwshBlock
        }
    },
    [PSCustomObject]@{
        Name   = "禁用粘滞键等辅助连击弹窗"
        Check  = {
            $s = (Get-ItemProperty "HKCU:\Control Panel\Accessibility\StickyKeys" -Name "Flags" -ErrorAction SilentlyContinue).Flags
            return ($s -eq "506")
        }
        Action = {
            Ensure-Key "HKCU:\Control Panel\Accessibility\StickyKeys"
            Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\StickyKeys" -Name "Flags" -Value "506" -Force
            Ensure-Key "HKCU:\Control Panel\Accessibility\Keyboard Response"
            Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\Keyboard Response" -Name "Flags" -Value "122" -Force
            Ensure-Key "HKCU:\Control Panel\Accessibility\ToggleKeys"
            Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\ToggleKeys" -Name "Flags" -Value "58" -Force
        }
    },
    [PSCustomObject]@{
        Name   = "禁用系统鼠标指针加速度 (锁定 1:1 纯线性位移)"
        Check  = {
            $p = "HKCU:\Control Panel\Mouse"
            $speed = (Get-ItemProperty -Path $p -Name "MouseSpeed" -ErrorAction SilentlyContinue).MouseSpeed
            $t1 = (Get-ItemProperty -Path $p -Name "MouseThreshold1" -ErrorAction SilentlyContinue).MouseThreshold1
            $t2 = (Get-ItemProperty -Path $p -Name "MouseThreshold2" -ErrorAction SilentlyContinue).MouseThreshold2
            return ($speed -eq "0" -and $t1 -eq "0" -and $t2 -eq "0")
        }
        Action = {
            $p = "HKCU:\Control Panel\Mouse"
            Ensure-Key $p
            Set-ItemProperty -Path $p -Name "MouseSpeed" -Value "0" -Force
            Set-ItemProperty -Path $p -Name "MouseThreshold1" -Value "0" -Force
            Set-ItemProperty -Path $p -Name "MouseThreshold2" -Value "0" -Force
            Set-ItemProperty -Path $p -Name "MouseSensitivity" -Value "10" -Force
        }
    }
)

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  外壳交互与终端底座生产力基线巡检 (pwsh 7+)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$chkList = [System.Collections.Generic.List[PSCustomObject]]::new()
$pendingItems = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($item in $items) {
    $isReady = $false
    try {
        $isReady = [bool](& $item.Check)
    } catch {
        $isReady = $false
    }

    $chkList.Add([PSCustomObject]@{
        受控项目 = $item.Name
        当前状态 = if ($isReady) { "已就绪" } else { "待加固" }
        判定     = if ($isReady) { "✔ 合规" } else { "✘ 偏离" }
    })

    if (-not $isReady) {
        $pendingItems.Add($item)
    }
}

$chkList | Format-Table -AutoSize | Out-String | Write-Host
$driftCount = $pendingItems.Count

if ($driftCount -eq 0) {
    Write-Host "🎉 [状态完美] 外壳交互与终端底座基线全部合规，无需调整。`n" -ForegroundColor Green
    return
}

Write-Host "⚠️  共发现 $driftCount 项基线偏离。" -ForegroundColor Yellow

if ($Mode -eq "CheckOnly") {
    Write-Host "💡 当前处于 -Mode CheckOnly 只查不改模式，未执行任何系统改动。`n" -ForegroundColor Gray
    return
}

# ==============================================================================
# 阶段 2: 审查门禁 (Gate)
# ==============================================================================
if (-not $Yes -and -not $NonInteractive) {
    Write-Host "💡 [改动说明与交互体验]" -ForegroundColor Cyan
    Write-Host "   - 核心意图: 还原 Win10 经典右键菜单、扩展名展示、Windows Terminal 生产力底座与 1:1 线性鼠标位移" -ForegroundColor Gray
    Write-Host "   - 生效机制: 注册表写入完成后，统一由总编排门面在流水线尾部平滑重启 Explorer 使桌面即刻生效" -ForegroundColor Gray
    $choice = Read-Host "`n是否立即对齐上述 $driftCount 项外壳基线？[Y/n/q] (回车确认)"
    if ($choice -match '^[Qq]') {
        Write-Host "[-] 用户取消操作，安全退出。`n" -ForegroundColor DarkGray
        return
    }
    if ($choice -match '^[Nn]') {
        Write-Host "[-] 跳过本模块基准对齐。`n" -ForegroundColor DarkGray
        return
    }
}

# ==============================================================================
# 阶段 3: 单向原子落盘 (Apply)
# ==============================================================================
Write-Host "`n🚀 正在单向对齐外壳交互基线..." -ForegroundColor Cyan
$successCount = 0

foreach ($it in $pendingItems) {
    Write-Host -NoNewline ("   - 正在配置: {0} ... " -f $it.Name)
    try {
        & $it.Action
        Write-Host -ForegroundColor Green "[OK]"
        $successCount++
    } catch {
        Write-Host -ForegroundColor Red "[FAIL]"
        Write-Warning "执行 [$($it.Name)] 失败: $($_.Exception.Message)"
    }
}

# ==============================================================================
# 阶段 4: 尾部简报 (Report)
# ==============================================================================
Write-Host "`n✅ [外壳加固完成] 成功对齐 $successCount / $driftCount 项基线配置。`n" -ForegroundColor Green
