# Cross-Platform Script Writer Skill

为 AI 注入跨平台脚本编写专家能力。让 AI 自动生成符合工业级规范的 Windows PowerShell 与 Linux/macOS Shell 安装/卸载脚本。

---

## 核心能力

- **配置驱动**：`config.json` 统一管理配置，支持多平台
- **三目录规范**：`install_dir` + `data_dir` + `backup_dir`
- **分层架构**：日志层 → 工具层 → 配置层 → 业务层 → 入口
- **安全第一**：自动备份、破坏性操作二次确认、危险路径校验
- **跨平台适配**：自动识别 Windows / Linux / macOS
- **幂等执行**：已安装跳过、配置存在跳过
- **高性能**：Bash 单次 jq 批量提取、PS 原生 ConvertFrom-Json
- **Profile 标记**：BEGIN/END 标记对，精准写入/清理

---

## 使用方式

安装此 Skill 后，直接描述需求，例如：

> 帮我写一个安装 fnm 的脚本

AI 会根据规范生成 `config.json`、`setup.sh`、`setup.ps1`。

```bash
# 或复制模板后编辑
./setup.sh install    # Unix/macOS
./setup.sh uninstall # 卸载
./setup.sh status    # 检查状态

.\setup.ps1 install    # Windows
.\setup.ps1 uninstall
.\setup.ps1 status
```

---

## 规范速览

| 项目 | Windows (.ps1) | Unix (.sh) |
|------|----------------|-----------|
| 配置文件 | config.json | config.json |
| 日志级别 | 0=DEBUG, 1=INFO, 2=WARN, 3=ERROR | 同左 |
| 安装基址 | `%LOCALAPPDATA%` | `~/.local/app-name` |
| 数据基址 | `%LOCALAPPDATA%` | `~/.local/share/app-name` |
| 备份基址 | `%USERPROFILE%\backups` | `~/backups/app-name` |
| 配置解析 | `ConvertFrom-Json`（零依赖） | `jq`（单次批量提取） |
| Shell Profile | `$PROFILE` | `~/.bashrc` / `~/.zshrc` |
| Profile 标记 | `# APP - BEGIN/END` | 同左 |

---

## 文件结构

```
skill-name/
├── config.json       # 应用配置（必须）
├── setup.sh          # Unix/macOS 脚本
├── setup.ps1         # Windows PowerShell 脚本
└── README.md        # 使用说明（可选）
```

---

## 分层架构说明

### 1. 日志层
- `log(level, message)`: 0=DEBUG, 1=INFO, 2=WARN, 3=ERROR
- 格式: `[级别] 时分秒 前缀 消息`
- 自动识别成功消息并显示 ✔

### 2. 工具层
- `confirm_destructive_action`: 破坏性操作二次确认
- `ensure_directory`: 创建目录
- `backup_file`: 备份文件至 `backup_dir`
- `safe_remove_directory`: 安全删除（危险路径黑名单）
- `is_installed`: 检查应用是否已安装
- `get_installed_version`: 获取已安装版本
- `rollback`: 从备份回滚

### 3. 配置层
- `check_dependencies`: 检查依赖（Bash 检查 jq）
- `read_configuration`: 解析 config.json

### 4. 业务层
- `install_via_brew/scoop/choco/winget/curl`: 各安装方式实现
- `uninstall_via_*`: 对应卸载逻辑
- `install_application`: 入口，自动判断已安装跳过
- `set_default_version`: 设置默认版本

### 5. 状态查询
- `check_status`: 检查安装状态和版本

### 6. 主流程层
- `main(action)`: 入口，处理 install / uninstall / status

---

## 配置说明 (config.json)

```json
{
  "log_level": "INFO",
  "app": {
    "name": "fnm",
    "description": "Fast Node Manager",
    "default_version": "1.39.0",
    "versions": ["1.39.0", "1.38.0", "1.37.0"]
  },
  "platforms": {
    "darwin": {
      "install_method": "curl",
      "install_dir": "~/.local/fnm",
      "data_dir": "~/.local/share/fnm",
      "backup_dir": "~/backups/fnm"
    },
    "linux": {
      "install_method": "curl",
      "install_dir": "~/.local/fnm",
      "data_dir": "~/.local/share/fnm",
      "backup_dir": "~/backups/fnm"
    },
    "windows": {
      "install_method": "scoop",
      "install_dir": "%LOCALAPPDATA%\\fnm",
      "data_dir": "%LOCALAPPDATA%\\fnm\\data",
      "backup_dir": "%USERPROFILE%\\backups\\fnm"
    }
  },
  "shell_profile": {
    "bash": "",
    "zsh": "",
    "powershell": ""
  }
}
```

> **注意**: `backup_dir` 必须配置，用于 `backup_file()` 存放备份文件。

---

## 支持的安装方式

| 方式 | Unix | Windows | 说明 |
|------|------|---------|------|
| brew | ✅ | - | Homebrew |
| curl | ✅ | - | 下载安装 |
| scoop | - | ✅ | Scoop |
| choco | - | ✅ | Chocolatey |
| winget | - | ✅ | Windows Package Manager |
| manual | ✅ | ✅ | 手动实现 |

---

## 发布

```bash
cd skills/cross-platform-script-writer
# 推送到 GitHub 或打包分享
git add .
git commit -m "v2.0.0"
```