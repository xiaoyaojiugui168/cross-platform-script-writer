#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"

$SCRIPT_DIR = $PSScriptRoot
$CONFIG_FILE = Join-Path $SCRIPT_DIR "config.json"

function Write-Log {
    param([int]$Level, [string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $levelStr = @("DEBUG", "INFO", "WARN", "ERROR")[$Level]
    $color = @("Gray", "Cyan", "Yellow", "Red")[$Level]
    $prefix = @("  ", "▶ ", "⚠ ", "✘ ")[$Level]
    if ($Message -match "^已|成功|完成") { $prefix = "✔ "; $color = "Green" }
    Write-Host "$timestamp [$levelStr] $prefix$Message" -ForegroundColor $color
    if ($Level -eq 3) { exit 1 }
}

function Confirm-DestructiveAction {
    param([string]$Prompt)
    $answer = Read-Host "$Prompt (y/N)"
    $answer -match "^[Yy]$"
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Log 0 "已创建目录：$Path"
    }
}

function Backup-File {
    param([string]$Path)
    if (Test-Path $Path) {
        Ensure-Directory $BACKUP_DIR
        $backupPath = Join-Path $BACKUP_DIR "$(Split-Path $Path -Leaf)_$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"
        Copy-Item $Path $backupPath
        Write-Log 0 "已备份：$backupPath"
    }
}

function Safe-RemoveDirectory {
    param([string]$Path)
    $dangerPaths = @("C:\", "$env:USERPROFILE", $env:USERPROFILE, "$env:USERPROFILE\.")
    if ($dangerPaths -contains $Path -or $Path.StartsWith("$env:USERPROFILE\")) { Write-Log 2 "安全跳过（危险路径）：$Path"; return }
    if (Test-Path $Path) { Remove-Item $Path -Recurse -Force; Write-Log 1 "已删除：$Path" }
}

function Test-Installed {
    param([string]$Command = $APP_NAME)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-InstalledVersion {
    param([string]$Command = $APP_NAME, [string]$Args = "--version")
    try { & $Command $Args 2>$null | Select-Object -First 1 } catch { "unknown" }
}

function Rollback {
    param([string]$RestorePath)
    $backupFiles = Get-ChildItem -Path $BACKUP_DIR -Filter "$APP_NAME*.bak" -ErrorAction SilentlyContinue
    if (-not $backupFiles) { Write-Log 2 "无备份可回滚"; return $false }
    $latestBackup = $backupFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Log 1 "从备份回滚：$($latestBackup.Name)"
    Copy-Item $latestBackup.FullName $RestorePath -Force
}

function Resolve-ShellRc {
    $profile = $PROFILE
    if (-not (Test-Path $profile)) { New-Item -ItemType File -Path $profile -Force | Out-Null }
    $profile
}

function Read-Configuration {
    if (-not (Test-Path $CONFIG_FILE)) { Write-Log 3 "配置文件不存在：$CONFIG_FILE" }
    $script:CONFIG = Get-Content $CONFIG_FILE -Raw | ConvertFrom-Json

    $osKey = $PSVersionTable.OS -replace ".*Windows.*" -replace ".*Darwin.*" -replace ".*Linux.*"
    if ($osKey -match "Darwin") { $osKey = "darwin" }
    elseif ($osKey -match "Linux") { $osKey = "linux" }
    else { $osKey = "windows" }

    $shellKey = "powershell"
    $platform = $CONFIG.platforms.$osKey

    $script:LOG_LEVEL = @{DEBUG=0;INFO=1;WARN=2;ERROR=3}[$CONFIG.log_level]
    $script:TIMESTAMP_FORMAT = $CONFIG.timestamp_format
    $script:APP_NAME = $CONFIG.app.name
    $script:INSTALL_DIR = $ExecutionContext.InvokeCommand.ExpandString($platform.install_dir)
    $script:DATA_DIR = $ExecutionContext.InvokeCommand.ExpandString($platform.data_dir)
    $script:BACKUP_DIR = if ($platform.backup_dir) { $ExecutionContext.InvokeCommand.ExpandString($platform.backup_dir) } else { Join-Path $SCRIPT_DIR "backups" }
    $script:INSTALL_METHOD = $platform.install_method
    $script:DEFAULT_VERSION = $CONFIG.app.default_version
    $script:VERSIONS = @($CONFIG.app.versions)
    $script:PROFILE_LINE = $CONFIG.shell_profile.$shellKey

    Write-Log 0 "日志级别：$($CONFIG.log_level)"
}

function Install-ViaScoop {
    param([string]$Pkg)
    if (scoop list $Pkg) { Write-Log 2 "$Pkg 已通过 scoop 安装，跳过"; return }
    scoop install $Pkg
}

function Install-ViaChoco {
    param([string]$Pkg)
    if (choco list --local-only $Pkg) { Write-Log 2 "$Pkg 已通过 choco 安装，跳过"; return }
    choco install $Pkg -y
}

function Install-ViaWinget {
    param([string]$Pkg)
    if (winget list --id $Pkg) { Write-Log 2 "$Pkg 已通过 winget 安装"; return }
    winget install --id $Pkg --silent --accept-package-agreements --accept-source-agreements
}

function Install-Application {
    Write-Log 1 "开始安装 ${APP_NAME}..."
    if (Test-Installed) {
        Write-Log 2 "$APP_NAME 已安装（$(Get-InstalledVersion)），跳过"
        return
    }

    switch ($INSTALL_METHOD) {
        "scoop"  { Install-ViaScoop $APP_NAME }
        "choco"  { Install-ViaChoco $APP_NAME }
        "winget" { Install-ViaWinget $APP_NAME }
        "manual" { Write-Log 1 "请实现 manual 安装逻辑" }
        default  { Write-Log 3 "不支持的安装方式：$INSTALL_METHOD" }
    }

    Write-Log 1 "${APP_NAME} 安装完成"
}

function Setup-Environment {
    Write-Log 1 "设置环境变量..."
    Ensure-Directory $INSTALL_DIR
    Ensure-Directory $DATA_DIR
    $env:PATH = "$INSTALL_DIR;$env:PATH"
    Set-Item -Path "env:$($APP_NAME.ToUpper())_DIR" -Value $DATA_DIR
    Write-Log 1 "环境变量配置完成"
}

function Select-TargetVersion {
    param([string]$DefaultVersion)
    Write-Host "  ┌─────────────────────────────────────────┐"
    Write-Host "  │       选择要安装的版本                   │"
    Write-Host "  └─────────────────────────────────────────┘"
    $i = 1; foreach ($v in $VERSIONS) { Write-Host "  $i) $v"; $i++ }
    $choice = Read-Host "  输入编号回车安装 (默认 $DefaultVersion)"

    $idx = 0
    if ($choice) {
        try { $idx = [int]$choice - 1 } catch { Write-Log 2 "无效输入，使用默认"; $idx = 0 }
    }
    if ($idx -ge 0 -and $idx -lt $VERSIONS.Count) { $script:SELECTED_VERSION = $VERSIONS[$idx] }
    else { $script:SELECTED_VERSION = $DefaultVersion }
}

function Set-DefaultVersion {
    Select-TargetVersion $DEFAULT_VERSION
    Write-Log 1 "设置默认版本：$SELECTED_VERSION"

    switch ($INSTALL_METHOD) {
        "scoop"  { scoop reset $SELECTED_VERSION 2>$null; scoop alias add $APP_NAME $SELECTED_VERSION }
        "choco"  { choco pin add --name=$APP_NAME --version=$SELECTED_VERSION }
        default  { Write-Log 1 "请实现 $INSTALL_METHOD 的版本切换逻辑" }
    }

    Write-Log 1 "默认版本已设置为 $SELECTED_VERSION"
}

function Add-ShellProfile {
    Write-Log 1 "持久化 Shell 配置..."
    $shellRc = Resolve-ShellRc
    $initBlock = @"
`n# $APP_NAME - BEGIN
`$env:PATH = `"$INSTALL_DIR;`$env:PATH`"
`$env:$($APP_NAME.ToUpper())_DIR = `"$DATA_DIR`"
$PROFILE_LINE
# $APP_NAME - END
"@
    if (-not (Select-String -Path $shellRc -Pattern "# $APP_NAME - BEGIN" -Quiet)) {
        Backup-File $shellRc
        Add-Content $shellRc $initBlock
        Write-Log 1 "已写入：$shellRc"
    } else {
        Write-Log 2 "配置已存在，跳过"
    }
}

function Uninstall-ViaScoop {
    param([string]$Pkg)
    scoop uninstall $Pkg 2>$null -or Write-Log 2 "$Pkg 未通过 scoop 安装"
}

function Uninstall-ViaChoco {
    param([string]$Pkg)
    choco uninstall $Pkg -y 2>$null -or Write-Log 2 "$Pkg 未通过 choco 安装"
}

function Uninstall-ViaWinget {
    param([string]$Pkg)
    winget uninstall --id $Pkg --silent 2>$null -or Write-Log 2 "winget 卸载失败"
}

function Uninstall-Application {
    Write-Log 1 "卸载 ${APP_NAME}..."

    switch ($INSTALL_METHOD) {
        "scoop"  { Uninstall-ViaScoop $APP_NAME }
        "choco"  { Uninstall-ViaChoco $APP_NAME }
        "winget" { Uninstall-ViaWinget $APP_NAME }
        "manual" { Safe-RemoveDirectory $INSTALL_DIR }
        default  { Write-Log 3 "不支持的安装方式：$INSTALL_METHOD" }
    }

    Write-Log 1 "${APP_NAME} 已卸载"
}

function Remove-ShellProfile {
    Write-Log 1 "清理 Shell 配置..."
    $shellRc = Resolve-ShellRc
    if (Select-String -Path $shellRc -Pattern "# $APP_NAME - BEGIN" -Quiet) {
        Backup-File $shellRc
        $content = Get-Content $shellRc -Raw
        $content -replace "(?s)# $APP_NAME - BEGIN.*?# $APP_NAME - END\r?\n?", "" | Set-Content $shellRc
        Write-Log 1 "已清理：$shellRc"
    } else {
        Write-Log 2 "未找到配置"
    }
}

function Check-Status {
    Write-Log 1 "检查 $APP_NAME 状态..."
    if (Test-Installed) {
        $version = Get-InstalledVersion
        Write-Log 1 "$APP_NAME 已安装（版本：$version）"
    } else {
        Write-Log 2 "$APP_NAME 未安装"
    }
}

function Main {
    param([string]$Action)
    if (-not $Action) { Write-Log 3 "缺少参数！用法: .\setup.ps1 install | uninstall | status" }
    if ($Action -ne "install" -and $Action -ne "uninstall" -and $Action -ne "status") { Write-Log 3 "无效参数：install | uninstall | status" }

    Read-Configuration

    Write-Host "╔══════════════════════════════════════════╗"
    Write-Host "║  $APP_NAME ($Action)                   ║"
    Write-Host "╚══════════════════════════════════════════╝"

    if ($Action -eq "install") {
        if (Test-Installed) {
            Write-Log 2 "$APP_NAME 已安装，跳过"
            return
        }
        Install-Application
        Setup-Environment
        Set-DefaultVersion
        Add-ShellProfile
    } elseif ($Action -eq "uninstall") {
        if (-not (Confirm-DestructiveAction "卸载 ${APP_NAME} 及其所有数据")) {
            Write-Log 2 "操作已取消"; exit 0
        }
        Uninstall-Application
        Safe-RemoveDirectory $DATA_DIR
        Remove-ShellProfile
    } elseif ($Action -eq "status") {
        Check-Status
    }
}

Main $args[0]