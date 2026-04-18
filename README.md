# Cross-Platform Script Writer

为 AI 注入跨平台脚本编写专家能力。

---

## 文件结构

```
skill-name/
├── config.json       # 应用配置
├── setup.sh        # Unix/macOS 安装脚本
├── setup.ps1       # Windows PowerShell 脚本
└── README.md      # 使用说明
```

---

## 使用方式

```bash
# Unix/macOS
chmod +x setup.sh
./setup.sh install | uninstall | status

# Windows
.\setup.ps1 install | uninstall | status
```

---

## 配置说明

编辑 `config.json` 自定义应用名称、版本、安装方式等。

详细规范见 [SKILL.md](./SKILL.md)