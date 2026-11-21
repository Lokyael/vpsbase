#requires -Version 7.0
<#
.SYNOPSIS
    应用生命周期域私有入站阻断防火墙规则算子 (Firewall Helper)

.DESCRIPTION
    1. 专为 PowerShell 7+ (pwsh) 打造的无状态防火墙探测与收敛辅助算子。
    2. 严格践行物理解耦与机制分离契约：
       - 只接收纯属性数据（规格哈希表、规格数组），严禁接收可执行代码块（ScriptBlock）；
       - 唯一定位 PersistentStore 策略存储库，实施入站阻断规则的只读探测 (GetState) 与幂等收敛写入 (SyncRules)；
       - 绝不调用 exit，写入后执行精确回读，失败抛出明确阻断异常，决策权交付应用子脚本；
       - 命名采用下划线前缀 (_firewall.ps1) 明确标识为领域私有辅助算子，隔离于编排门面实体清单。

.PARAMETER Task
    指定执行的任务，可选值: GetState, SyncRules。

.PARAMETER Spec
    单条受控规则规格哈希表 (用于 GetState)，包含:
    - Name     : 本地受控规则唯一标识 (必填)
    - Program  : 受控程序绝对路径 (必填)
    - Protocol : 协议 (TCP 或 UDP) (必填)
    - Desc     : 规则展示描述 (可选)

.PARAMETER Specs
    受控规则规格哈希表数组 (用于 SyncRules)。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("GetState", "SyncRules")]
    [string]$Task,

    [hashtable]$Spec,

    [object[]]$Specs
)

$ErrorActionPreference = "Stop"

function Get-AppFirewallState {
    param([hashtable]$Spec)

    $expected = "Enabled=True; Direction=Inbound; Action=Block; Profile=Any; Program=$($Spec.Program); Protocol=$($Spec.Protocol); LocalAddress=Any; RemoteAddress=Any; LocalPort=Any; RemotePort=Any"
    try {
        $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $Spec.Name -ErrorAction Stop)
    } catch {
        if ($_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound) { throw }
        $rules = @()
    }
    if ($rules.Count -eq 0) {
        return [pscustomobject]@{ Name = $Spec.Name; Exists = $false; IsMatch = $false; Expected = $expected; Actual = '本地受控规则缺失' }
    }
    if ($rules.Count -ne 1) { throw "本地规则名称不唯一: $($Spec.Name)" }
    $rule = $rules[0]
    $application = @(Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop)
    $port = @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop)
    $address = @(Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop)
    if ($application.Count -ne 1 -or $port.Count -ne 1 -or $address.Count -ne 1) {
        throw "无法完整读取本地规则过滤器: $($Spec.Name)"
    }
    $actual = [ordered]@{
        Enabled = [string]$rule.Enabled
        Direction = [string]$rule.Direction
        Action = [string]$rule.Action
        Profile = [string]$rule.Profile
        Program = [string]$application[0].Program
        Protocol = [string]$port[0].Protocol
        LocalAddress = @($address[0].LocalAddress) -join ','
        RemoteAddress = @($address[0].RemoteAddress) -join ','
        LocalPort = @($port[0].LocalPort) -join ','
        RemotePort = @($port[0].RemotePort) -join ','
    }
    $protocolNumber = if ($Spec.Protocol -eq 'TCP') { '6' } else { '17' }
    $profiles = @(([string]$rule.Profile -split ',') | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    $allProfiles = $actual.Profile -in @('Any', '0', '7') -or ($profiles -join ',') -eq 'Domain,Private,Public'
    $isMatch = $actual.Enabled -eq 'True' -and $actual.Direction -eq 'Inbound' -and
        $actual.Action -eq 'Block' -and $allProfiles -and
        [string]::Equals($actual.Program.Replace('/', '\'), $Spec.Program.Replace('/', '\'), [StringComparison]::OrdinalIgnoreCase) -and
        $actual.Protocol -in @($Spec.Protocol, $protocolNumber)
    foreach ($field in @('LocalAddress', 'RemoteAddress', 'LocalPort', 'RemotePort')) {
        if ($actual[$field] -ne 'Any') { $isMatch = $false }
    }
    return [pscustomobject]@{
        Name = $Spec.Name; Exists = $true; IsMatch = $isMatch; Expected = $expected
        Actual = ($actual.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
    }
}

function Sync-AppFirewallRules {
    param([object[]]$Specs)

    $applied = 0
    foreach ($spec in $Specs) {
        $state = Get-AppFirewallState $spec
        if ($state.IsMatch) { continue }
        $parameters = @{
            PolicyStore = 'PersistentStore'; Name = $spec.Name
            Enabled = 'True'; Direction = 'Inbound'; Action = 'Block'; Profile = 'Any'
            Program = $spec.Program; Protocol = $spec.Protocol
            LocalAddress = 'Any'; RemoteAddress = 'Any'; LocalPort = 'Any'; RemotePort = 'Any'
            ErrorAction = 'Stop'
        }
        if ($state.Exists) {
            Set-NetFirewallRule @parameters | Out-Null
        } else {
            New-NetFirewallRule @parameters -DisplayName $spec.Desc | Out-Null
        }
        try {
            $verified = Get-AppFirewallState $spec
            if (-not $verified.IsMatch) { throw $verified.Actual }
        } catch {
            throw "本地规则已写入，但回读校验失败: $($spec.Name); $($_.Exception.Message)"
        }
        $applied++
    }
    return $applied
}

if ($Task -eq "GetState") {
    if ($null -eq $Spec) { throw "Task 'GetState' 缺少必要的 -Spec 参数。" }
    return (Get-AppFirewallState -Spec $Spec)
}

if ($Task -eq "SyncRules") {
    if ($null -eq $Specs) { throw "Task 'SyncRules' 缺少必要的 -Specs 参数。" }
    return (Sync-AppFirewallRules -Specs $Specs)
}
