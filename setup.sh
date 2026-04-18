#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"
TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"

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