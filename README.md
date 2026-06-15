# 视频到笔记 🎬→📝

> 复制视频链接 → 一键生成结构化 Markdown 笔记，全链路自动化。
> 不依赖任何付费 API，字幕 + 语音转文字双链路覆盖。

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Platform: Windows](https://img.shields.io/badge/Platform-Windows%2010%2F11-blue)
![PowerShell: 5.1](https://img.shields.io/badge/PowerShell-5.1%2B-blue)

---

## 效果

输入一个视频链接，得到一个结构化笔记：

```
▶ .\video2note.ps1 "https://www.youtube.com/watch?v=xxxxx"

▶ 获取视频信息...
  ✅ 视频: AI编程越写越乱？我用水桶装水，把边界讲透

▶ 尝试下载字幕...
  ✅ 找到字幕: video.zh-Hans.vtt (42.5 KB)
  ✅ 字幕提取完成 (10234 字符)

▶ Claude Code 生成笔记...
  ✅ 笔记生成完成 (3587 字符)

  ✅ 完成！
  📝 笔记: notes\AI编程越写越乱？我用水桶装水，把边界讲透.md
```

生成的笔记包含：**核心主题 → 关键概念 → 重要细节 → 个人可行动项**，可直接用于复习、分享。

---

## 工作原理

```
输入链接
  │
  ├─ yt-dlp 下载字幕 (.srt / .vtt)
  │   └─ 有字幕 → 解析纯文本 ✅（秒级）
  │
  └─ 无字幕 → 下载音频 → ffmpeg 转 16kHz WAV
                └─ FunASR paraformer-zh 语音转文字
                   ├─ 短音频: 一次性处理
                   └─ 长音频: 3分钟×N 分段处理（避免内存溢出）
                       │
                       ▼
               Claude Code 生成结构化笔记
                       │
                       ▼
                  notes/标题.md
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
cd 视频到笔记

# YouTube（直接跑）
.\video2note.ps1 "https://www.youtube.com/watch?v=xxxxx"

# B站（需要先导出 Cookie，见下方说明）
.\video2note.ps1 "https://www.bilibili.com/video/BVxxxxx" -Cookies ".\bilibili_cookies.txt"
```

#### 命令行参数

| 参数 | 必填 | 说明 |
|------|------|------|
| `-Url` | ✅ | 视频链接 |
| `-Cookies` | ❌ | cookies.txt 文件路径，或浏览器名 (edge/chrome/firefox) |
| `-OutputDir` | ❌ | 输出目录，默认 `./notes` |
| `-NoCleanup` | ❌ | 保留中间文件（字幕/音频/prompt），方便调试 |

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
├── video2note.ps1          # 主入口：编排全流程
├── asr.py                  # FunASR 语音转文字模块（自动分段）
├── config.json             # 配置文件（prompt 模板、语言优先级）
├── bilibili_cookies.txt    # B站 Cookie（需手动导出，gitignore）
├── notes/                  # 笔记输出目录
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
