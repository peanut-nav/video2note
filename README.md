# 视频/音频到笔记 🎬🎤→📝

> 三种输入方式 → 一键生成结构化 Markdown 笔记，全链路自动化。
> 视频链接 / 音频文件 / 视频文件，字幕 + 语音转文字双链路覆盖。
> 自带 tkinter 图形界面，也支持命令行调用。

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Platform: Windows](https://img.shields.io/badge/Platform-Windows%2010%2F11-blue)
![PowerShell: 5.1](https://img.shields.io/badge/PowerShell-5.1%2B-blue)

---

## 效果

### GUI（推荐）

```powershell
python gui.py
```

三种输入模式一键切换：**视频链接** / **音频文件** / **视频文件**，实时显示处理进度，设置自动记忆。

### CLI

输入一个链接/文件，得到两份笔记（精炼版 + 详细版）：

```
▶ .\video2note.ps1 -AudioFile ".\lecture.mp3"

▶ 标题: lecture
▶ 音频格式转换 (16kHz mono WAV)...
  ✅ WAV: 54.6 MB

▶ FunASR 语音转文字...
  ✅ 转写完成 (18519 字符)

▶ Claude Code 生成笔记 (精炼版)...
  ✅ 笔记生成完成 — 2947 字符

▶ Claude Code 生成笔记 (详细版)...
  ✅ 笔记生成完成 — 17659 字符

  ✅ 完成！
  📝 精炼版: notes\lecture.md
  📚 详细版: notes\lecture_详细.md
```

精炼版笔记包含：**核心主题 → 关键概念 → 重要细节 → 个人可行动项**。详细版额外包含 **完整内容记录**（逐段复述）、**问答记录**等。

---

## 工作原理

```
┌─ URL 模式 ───── 视频链接 → yt-dlp 下载字幕
│                              ├─ 有字幕 → 解析纯文本 ✅
│                              └─ 无字幕 → 下载音频 → ffmpeg → WAV
│
├─ AudioFile 模式  音频文件 → ffmpeg → 16kHz mono WAV
│
└─ VideoFile 模式  视频文件 → ffmpeg -vn → 16kHz mono WAV
                                                   │
                                          FunASR 语音转文字
                                          (长音频自动分段)
                                                   │
                                    ┌──────────────┴──────────────┐
                                    │                             │
                              Claude Code                    Claude Code
                              精炼版 prompt                  详细版 prompt
                                    │                             │
                              notes/标题.md              notes/标题_详细.md
```

---

## 快速开始

### 环境要求

- Windows 10/11 + PowerShell 5.1
- Python 3.10+
- [Claude Code](https://claude.ai/code) 已登录

### 安装依赖

```powershell
# 1. yt-dlp（视频/字幕下载，覆盖 1800+ 站点）
pip install yt-dlp

# 2. ffmpeg（音频格式转换）
winget install ffmpeg

# 3. FunASR（语音转文字，通义千问同款引擎）
pip install funasr

# 4. deno（YouTube JS 运行时，必须装）
winget install deno
```

> 安装后**不需要重启终端**，脚本启动时会自动刷新 PATH。

### 使用

```powershell
# GUI（图形界面，支持三种模式）
python gui.py

# CLI — URL 模式
.\video2note.ps1 "https://www.youtube.com/watch?v=xxxxx"
.\video2note.ps1 "https://www.bilibili.com/video/BVxxxxx" -Cookies ".\bilibili_cookies.txt"

# CLI — 音频文件模式
.\video2note.ps1 -AudioFile ".\recording.mp3"

# CLI — 视频文件模式（可自定义标题）
.\video2note.ps1 -VideoFile ".\lecture.mp4" -Title "深度学习笔记"
```

#### 命令行参数

| 参数 | 模式 | 必填 | 说明 |
|------|------|------|------|
| `-Url` | URL | ✅ | 视频链接 |
| `-AudioFile` | 音频文件 | ✅ | 本地音频文件路径 |
| `-VideoFile` | 视频文件 | ✅ | 本地视频文件路径 |
| `-Title` | 文件模式 | ❌ | 自定义标题（默认从文件名推导） |
| `-Cookies` | URL | ❌ | cookies.txt 路径，或浏览器名 |
| `-OutputDir` | 全部 | ❌ | 输出目录，默认 `./notes` |
| `-NoCleanup` | 全部 | ❌ | 保留中间文件，方便调试 |

#### B站 需要导出 Cookie（一次操作，永久使用）

B站视频要求登录态：

1. Edge 打开 B站并**登录**
2. 按 **F12** → 选 **"控制台"**（Console）
3. 粘贴以下代码 → 回车：

```javascript
copy(document.cookie.split('; ').map(c => c.replace('=', '\t') + '\tFALSE\t/\tFALSE\t0\t' + c.split('=')[0]).join('\n'))
```

4. 在项目目录新建文件 `bilibili_cookies.txt`，**Ctrl+V** 粘贴 → 保存

> ⚠️ Cookie 文件已在 `.gitignore` 中排除，不会被提交到 Git。

---

## 自定义笔记风格

编辑 `config.json` 的 `notePrompt` 字段，可用变量：

| 变量 | 含义 |
|------|------|
| `{title}` | 视频标题 |
| `{url}` | 视频链接 |
| `{text}` | 字幕/转写文本 |

---

## 费用

| 环节 | 费用 |
|------|------|
| yt-dlp 下载 | 🆓 免费 |
| ffmpeg 转换 | 🆓 免费 |
| FunASR 语音转文字 | 🆓 免费（本地 CPU 运行） |
| Claude Code 总结 | 💰 已有订阅，无额外费用 |

---

## 支持平台

| 平台 | 字幕 | 备注 |
|------|------|------|
| YouTube | ✅ | 自动字幕可用 |
| B站 (bilibili) | ✅ | 需 cookies.txt |
| 抖音/TikTok | ⚠️ | 通常无字幕，需走语音转文字 |
| Twitter/X | ✅ | — |
| Vimeo | ✅ | — |

yt-dlp 理论上支持 1800+ 站点，更多见 [yt-dlp 支持列表](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md)。

---

## 项目结构

```
视频到笔记/
├── video2note.ps1          # 主脚本：三种输入模式，编排全流程
├── gui.py                  # tkinter 图形界面
├── gui_settings.json       # GUI 用户设置（自动保存，gitignore）
├── asr.py                  # FunASR 语音转文字模块（自动分段）
├── config.json             # 配置文件（精炼+详细双 prompt 模板）
├── 启动GUI.bat              # Windows 双击启动 GUI
├── bilibili_cookies.txt    # B站 Cookie（需手动导出，gitignore）
├── notes/                  # 笔记输出目录
├── CLAUDE.md               # Claude Code 项目指引
├── 使用教程.md              # 详细使用文档
└── 项目实现总结.md           # 技术决策 & 踩坑记录
```

---

## 常见问题

**Q: 提示 "yt-dlp 找不到"？** 脚本启动时会自动从注册表刷新 PATH，一般不需要重启终端。

**Q: 转写结果中文乱码？** 模型 `paraformer-zh` 专为中文优化。英文视频尽量走字幕路径。

**Q: 长视频很久没反应？** 15分钟以上的视频 FunASR 会分段处理（每3分钟一段，每段约12秒），15分钟视频约需 1.5 分钟。

**Q: 首次运行 FunASR 很慢？** 首次会自动下载 paraformer-zh 模型（~1GB），之后永久缓存到 `~/.cache/modelscope/`。

---

## 技术栈

| 环节 | 工具 | 说明 |
|------|------|------|
| 下载 | yt-dlp | 覆盖 1800+ 站点 |
| 转码 | ffmpeg | 16kHz mono WAV |
| 语音转文字 | FunASR paraformer-zh | 阿里达摩院开源，本地 CPU 推理 |
| AI 总结 | Claude Code | `--print` 非交互模式 |
| 脚本 | PowerShell 5.1 | Windows 原生 |

---

## License

MIT © 2025
