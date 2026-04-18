# Skill: 跨平台 CLI 工具自动化部署脚本生成规范

## 目录结构

```
skill-name/
├── config.json       # 必须：应用配置
├── setup.sh        # 必须：Unix/macOS 安装脚本
├── setup.ps1       # 必须：Windows PowerShell 脚本
└── README.md      # 可选：使用说明
```

## 1. 配置驱动

**必须字段** (config.json):
```json
{
  "log_level": "INFO",
  "timestamp_format": "%Y-%m-%d %H:%M:%S",
  "app": {
    "name": "string",
    "description": "string",
    "default_version": "string",
    "versions": ["string"]
  },
  "platforms": {
    "darwin": {
      "install_method": "brew|curl|manual",
      "install_dir": "~/.local/app-name",
      "data_dir": "~/.local/share/app-name",
      "backup_dir": "~/backups/app-name"
    },
    "linux": {
      "install_method": "curl|manual",
      "install_dir": "~/.local/app-name",
      "data_dir": "~/.local/share/app-name",
      "backup_dir": "~/backups/app-name"
    },
    "windows": {
      "install_method": "scoop|choco|winget|manual",
      "install_dir": "%LOCALAPPDATA%\\app-name",
      "data_dir": "%LOCALAPPDATA%\\app-name\\data",
      "backup_dir": "%USERPROFILE%\\backups\\app-name"
    }
  },
  "shell_profile": {
    "bash": "",
    "zsh": "",
    "powershell": ""
  }
}
```

> **注意**: `backup_dir` 必须明确配置，用于 `backup_file()` 存放备份文件。

### 1.1 三目录规范

| 字段 | 用途 | 加入 PATH |
|------|------|-----------|
| `install_dir` | 软件本体/二进制文件 | 是 |
| `data_dir` | 运行数据/状态 | 否 |
| `backup_dir` | 备份文件存储 | 否 |

`~` 自动展开为 `$HOME` / `$env:USERPROFILE`。

## 2. 脚本分层架构

### 2.1 Bash (setup.sh)

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"
TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"

# ===== 🎨 日志层 =====
LOG_LEVEL=1
log() {
  local level=$1; local message=$2
  [[ "$level" -lt "$LOG_LEVEL" ]] && return

  local timestamp=$(date +"$TIMESTAMP_FORMAT")
  local level_str="" color="" prefix=""
  case $level in
    0) level_str="DEBUG"; color="\033[0;37m"; prefix="  " ;;
    1) level_str="INFO";  color="\033[0;36m"; prefix="▶ " ;;
    2) level_str="WARN";  color="\033[1;33m"; prefix="⚠ " ;;
    3) level_str="ERROR"; color="\033[0;31m"; prefix="✘ " ;;
  esac
  [[ "$message" =~ ^已|成功|完成 ]] && { prefix="✔ "; color="\033[0;32m"; }
  echo -e "${color}${timestamp} [${level_str}] $prefix${message}\033[0m"
  [[ "$level" -eq 3 ]] && exit 1
}

# ===== 🛠️ 工具层 =====
confirm_destructive_action() {
  local prompt="${1:-确认执行此破坏性操作？}"
  read -r -p "$(date +"$TIMESTAMP_FORMAT") [WARN] ⚠  ${prompt} (y/N) " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

ensure_directory() {
  local dir_path="$1"
  [[ ! -d "${dir_path}" ]] && { mkdir -p "${dir_path}"; log 0 "已创建目录：${dir_path}"; }
}

backup_file() {
  local file_path="$1"
  [[ -f "${file_path}" ]] && {
    ensure_directory "${BACKUP_DIR}"
    cp "${file_path}" "${BACKUP_DIR}/$(basename "${file_path}")_$(date +%Y%m%d_%H%M%S).bak"
    log 0 "已备份：${file_path}"
  }
}

safe_remove_directory() {
  local dir_path="$1"
  local danger_paths=("/" "$HOME" "~" "$HOME/." ".git")
  for p in "${danger_paths[@]}"; do
    [[ "$dir_path" == "$p"* ]] && { log 2 "安全跳过（危险路径）：$dir_path"; return; }
  done
  [[ -d "$dir_path" ]] && { rm -rf "$dir_path"; log 1 "已删除：${dir_path}"; }
}

is_installed() {
  command -v "$APP_NAME" &>/dev/null
}

get_installed_version() {
  local version_cmd="${1:-$APP_NAME --version}"
  $version_cmd 2>/dev/null | head -1 || echo "unknown"
}

rollback() {
  local restore_point="$1"
  local backup_list=(${BACKUP_DIR}/${APP_NAME}_*.bak)
  if [[ ${#backup_list[@]} -eq 0 || "${backup_list[0]}" == "${BACKUP_DIR}/${APP_NAME}_*.bak" ]]; then
    log 2 "无备份可回滚"
    return 1
  fi
  local latest_backup="${backup_list[-1]}"
  log 1 "从备份回滚：${latest_backup}"
  cp "$latest_backup" "$restore_point"
}

safe_sed() {
  local pattern="$1"; local file="$2"
  [[ "$(uname -s)" == "Darwin" ]] && sed -i '' "$pattern" "$file" || sed -i "$pattern" "$file"
}

resolve_shell_rc() {
  case "${SHELL:-}" in *bash) echo "$HOME/.bashrc" ;; *zsh) echo "$HOME/.zshrc" ;; esac
}

# ===== ⚙️ 配置层 =====
check_dependencies() {
  command -v jq &>/dev/null || log 3 "缺少 jq，请先安装: brew install jq / apt install jq"
}

read_configuration() {
  [[ ! -f "${CONFIG_FILE}" ]] && log 3 "配置文件不存在：${CONFIG_FILE}"
  CONFIG_JSON=$(<"$CONFIG_FILE")

  local os_key; os_key=$(uname -s | awk '{print tolower($0)}')
  [[ "$os_key" =~ darwin ]] && os_key="darwin"
  [[ "$os_key" =~ linux ]] && os_key="linux"
  [[ "$os_key" =~ msys|cygwin|mingw ]] && os_key="windows"

  local shell_key="bash"; [[ "${SHELL:-}" == *zsh* ]] && shell_key="zsh"

  IFS=$'\t' read -r raw_log_level TIMESTAMP_FORMAT APP_NAME INSTALL_DIR DATA_DIR INSTALL_METHOD BACKUP_DIR DEFAULT_VERSION PROFILE_LINE <<< \
    "$(jq -r --arg os "$os_key" --arg sh "$shell_key" \
      '[.log_level // "INFO", .timestamp_format // "%Y-%m-%d %H:%M:%S", .app.name, .platforms[$os].install_dir, .platforms[$os].data_dir, .platforms[$os].install_method, (.platforms[$os].backup_dir // ""), .app.default_version, .shell_profile[$sh]] | @tsv' <<< "$CONFIG_JSON")"

  case "$raw_log_level" in DEBUG) LOG_LEVEL=0 ;; INFO) LOG_LEVEL=1 ;; WARN) LOG_LEVEL=2 ;; ERROR) LOG_LEVEL=3 ;; esac
  [[ -z "$BACKUP_DIR" || "$BACKUP_DIR" == "null" ]] && BACKUP_DIR="${SCRIPT_DIR}/backups"

  INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
  DATA_DIR="${DATA_DIR/#\~/$HOME}"
  BACKUP_DIR="${BACKUP_DIR/#\~/$HOME}"

  mapfile -t VERSIONS < <(jq -r '.app.versions[]' <<< "$CONFIG_JSON")
}

# ===== 🚀 业务层 =====

install_via_brew() {
  local pkg="$1"
  if brew list "$pkg" &>/dev/null; then
    log 2 "$pkg 已通过 brew 安装，跳过"
    return
  fi
  brew install "$pkg"
}

install_via_curl() {
  local url="$1" local target="$2" local mode="${3:-0755}"
  if [[ -x "$target" ]]; then
    log 1 "$target 已存在，跳过下载"
    return
  fi
  ensure_directory "$(dirname "$target")"
  curl -fsSL "$url" -o "$target"
  chmod "$mode" "$target"
  log 1 "已下载：$target"
}

install_via_scoop() {
  local pkg="$1"
  if scoop list "$pkg" &>/dev/null; then
    log 2 "$pkg 已通过 scoop 安装，跳过"
    return
  fi
  scoop install "$pkg"
}

install_via_choco() {
  local pkg="$1"
  if choco list --local-only "$pkg" &>/dev/null; then
    log 2 "$pkg 已通过 choco 安装，跳过"
    return
  fi
  choco install "$pkg" -y
}

install_via_winget() {
  local pkg="$1"
  winget list --id "$pkg" &>/dev/null && { log 2 "$pkg 已通过 winget 安装"; return; }
  winget install --id "$pkg" --silent --accept-package-agreements --accept-source-agreements
}

install_application() {
  log 1 "开始安装 ${APP_NAME}..."
  if is_installed; then
    log 2 "${APP_NAME} 已安装（$(get_installed_version)），跳过"
    return
  fi

  case "$INSTALL_METHOD" in
    brew)    install_via_brew "$APP_NAME" ;;
    curl)   log 1 "请配置 curl 下载逻辑" ;;
    scoop)  install_via_scoop "$APP_NAME" ;;
    choco)  install_via_choco "$APP_NAME" ;;
    winget) install_via_winget "$APP_NAME" ;;
    manual) log 1 "请实现 manual 安装逻辑" ;;
    *)     log 3 "不支持的安装方式：$INSTALL_METHOD" ;;
  esac

  log 1 "${APP_NAME} 安装完成"
}

setup_environment() {
  log 1 "设置环境变量..."
  ensure_directory "$INSTALL_DIR"
  ensure_directory "$DATA_DIR"
  [[ ":$PATH:" != *":$INSTALL_DIR:"* ]] && { export PATH="$INSTALL_DIR:$PATH"; log 1 "已加入 PATH：${INSTALL_DIR}"; }
  eval "$PROFILE_LINE"
  log 1 "环境变量配置完成"
}

select_target_version() {
  local default_version=$1; shift
  local versions=("$@")
  echo "  ┌─────────────────────────────────────────┐"
  echo "  │       选择要安装的版本                   │"
  echo "  └─────────────────────────────────────────┘"
  local i=1; for v in "${versions[@]}"; do echo "  $i) $v"; ((i++)); done
  read -r -p "  输入编号回车安装 (默认 ${default_version}): " choice

  local idx=0
  if [[ -n "$choice" ]]; then
    [[ "$choice" =~ ^[0-9]+$ ]] || { log 2 "无效输入，使用默认"; choice=0; }
    idx=$((choice - 1))
  fi
  if [[ $idx -ge 0 && $idx -lt ${#versions[@]} ]]; then
    SELECTED_VERSION="${versions[$idx]}"
  else
    SELECTED_VERSION="$default_version"
  fi
}

set_default_version() {
  select_target_version "$DEFAULT_VERSION" "${VERSIONS[@]}"
  log 1 "设置默认版本：${SELECTED_VERSION}"

  case "$INSTALL_METHOD" in
    brew)
      brew alias add "$SELECTED_VERSION" 2>/dev/null || true
      ;;
    fnm)
      fnm install "$SELECTED_VERSION" && fnm default "$SELECTED_VERSION"
      ;;
    nvm)
      export NVM_DIR="$DATA_DIR"
      nvm install "$SELECTED_VERSION" && nvm alias default "$SELECTED_VERSION"
      ;;
    *)
      log 1 "请实现 $INSTALL_METHOD 的版本切换逻辑"
      ;;
  esac

  log 1 "默认版本已设置为 ${SELECTED_VERSION}"
}

add_shell_profile() {
  log 1 "持久化 Shell 配置..."
  local shell_rc=$(resolve_shell_rc)
  local init_block="export PATH=\"${INSTALL_DIR}:\$PATH\"\nexport ${APP_NAME^^}_DIR=\"${DATA_DIR}\"\n${PROFILE_LINE}"

  if ! grep -q "# ${APP_NAME} - BEGIN" "$shell_rc" 2>/dev/null; then
    backup_file "$shell_rc"
    printf "\n# %s - BEGIN\n%b\n# %s - END\n" "${APP_NAME}" "${init_block}" "${APP_NAME}" >> "$shell_rc"
    log 1 "已写入：${shell_rc}"
  else
    log 2 "配置已存在，跳过"
  fi
}

uninstall_via_brew() {
  local pkg="$1"
  if ! brew list "$pkg" &>/dev/null; then
    log 2 "$pkg 未通过 brew 安装"
    return
  fi
  brew uninstall "$pkg"
}

uninstall_via_scoop() {
  local pkg="$1"
  scoop uninstall "$pkg" 2>/dev/null || log 2 "$pkg 未通过 scoop 安装"
}

uninstall_via_choco() {
  local pkg="$1"
  choco uninstall "$pkg" -y 2>/dev/null || log 2 "$pkg 未通过 choco 安装"
}

uninstall_via_winget() {
  local pkg="$1"
  winget uninstall --id "$pkg" --silent 2>/dev/null || log 2 "winget 卸载失败"
}

uninstall_application() {
  log 1 "卸载 ${APP_NAME}..."

  case "$INSTALL_METHOD" in
    brew)    uninstall_via_brew "$APP_NAME" ;;
    curl)   safe_remove_directory "$INSTALL_DIR" ;;
    scoop)  uninstall_via_scoop "$APP_NAME" ;;
    choco)  uninstall_via_choco "$APP_NAME" ;;
    winget) uninstall_via_winget "$APP_NAME" ;;
    manual) safe_remove_directory "$INSTALL_DIR" ;;
    *)      log 3 "不支持的安装方式：$INSTALL_METHOD" ;;
  esac

  log 1 "${APP_NAME} 已卸载"
}

remove_shell_profile() {
  log 1 "清理 Shell 配置..."
  local shell_rc=$(resolve_shell_rc)
  if [[ -f "$shell_rc" ]] && grep -q "# ${APP_NAME} - BEGIN" "$shell_rc" 2>/dev/null; then
    backup_file "$shell_rc"
    safe_sed "/# ${APP_NAME} - BEGIN/,/# ${APP_NAME} - END/d" "$shell_rc"
    log 1 "已清理：${shell_rc}"
  else
    log 2 "未找到配置"
  fi
}

# ===== 🚀 状态查询 =====
check_status() {
  log 1 "检查 ${APP_NAME} 状态..."
  if is_installed; then
    local version
    version=$(get_installed_version)
    log 1 "${APP_NAME} 已安装（版本：$version）"
  else
    log 2 "${APP_NAME} 未安装"
  fi
}

# ===== 🏁 入口 =====
main() {
  local action="${1:-}"
  [[ -z "$action" ]] && log 3 "缺少参数！用法: ./setup.sh install | uninstall | status"
  [[ "$action" != "install" && "$action" != "uninstall" && "$action" != "status" ]] && log 3 "无效参数：install | uninstall | status"

  check_dependencies
  read_configuration

  echo "╔══════════════════════════════════════════╗"
  echo "║  ${APP_NAME} ($action)                   ║"
  echo "╚══════════════════════════════════════════╝"

  if [[ "$action" == "install" ]]; then
    if is_installed; then
      log 2 "${APP_NAME} 已安装，跳过"
      return
    fi
    install_application
    setup_environment
    set_default_version
    add_shell_profile
  elif [[ "$action" == "uninstall" ]]; then
    if ! confirm_destructive_action "卸载 ${APP_NAME} 及其所有数据"; then
      log 2 "操作已取消"; exit 0
    fi
    uninstall_application
    safe_remove_directory "$DATA_DIR"
    remove_shell_profile
  elif [[ "$action" == "status" ]]; then
    check_status
  fi
}

main "$@"
```

### 2.2 PowerShell (setup.ps1)

```powershell
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
```

## 3. 使用方法

```bash
# Unix/macOS
chmod +x setup.sh
./setup.sh install
./setup.sh uninstall
./setup.sh status

# Windows (使用 $args[0] 位置参数)
.\setup.ps1 install
.\setup.ps1 uninstall
.\setup.ps1 status
```

## 4. 扩展安装方式

如需支持更多安装方式，在对应位置添加函数：

### curl 下载安装（需配置 URL）

```bash
install_via_curl() {
  local url="$1" local target="$2" local version="$3"
  local versioned_dir="${INSTALL_DIR}/versions/${version}"
  ensure_directory "$versioned_dir"
  curl -fsSL "$url" -o "$target"
  chmod +x "$target"
  ln -sf "$target" "${INSTALL_DIR}/${APP_NAME}"
}

# 调用示例
install_via_curl "https://.../fnm-${VERSION}-macos.tar.zip" "$versioned_dir/fnm" "$SELECTED_VERSION"
```

### npm/yarn 全局安装

```bash
install_via_npm() {
  npm install -g "$APP_NAME"
}

install_via_yarn() {
  yarn global add "$APP_NAME"
}
```

### pip install

```bash
install_via_pip() {
  pip install --user "$APP_NAME"
}
```

### Windows MSI/MSIX

```powershell
function Install-ViaMsi {
    param([string]$MsiPath)
    Start-Process msiexec.exe -ArgumentList "/i", $MsiPath, "/quiet", "/qn" -Wait
}