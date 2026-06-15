#Requires -Version 5.1
<#
.SYNOPSIS
  视频链接 → 结构化 Markdown 笔记，一键自动化

.DESCRIPTION
  全自动：下载字幕（或 FunASR 语音转文字）→ Claude Code 生成笔记 → .md 文件。
  YouTube、B站均验证通过。短音频直接转写，长音频自动分段处理避免内存溢出。

.PARAMETER Url
  视频网页链接

.PARAMETER OutputDir
  笔记输出目录，默认 ./notes

.PARAMETER Cookies
  cookies.txt 文件路径（推荐）或浏览器名 (edge/chrome/firefox/brave)。
  导出 B站 Cookie: F12→Console→粘贴 JS 代码→保存为 bilibili_cookies.txt

.PARAMETER NoCleanup
  保留中间文件（字幕/音频/转写文本），方便调试

.EXAMPLE
  # YouTube
  .\video2note.ps1 "https://www.youtube.com/watch?v=xxxxx"

.EXAMPLE
  # B站 (cookies.txt)
  .\video2note.ps1 "https://www.bilibili.com/video/BVxxxxx" -Cookies ".\bilibili_cookies.txt"
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Url,

    [string]$OutputDir = ".\notes",

    [switch]$NoCleanup,

    [string]$Cookies
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── 刷新 PATH ─────────────────────────────────
# 从注册表读取最新 PATH（解决 winget 安装后不重启终端找不到命令的问题）
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")

# 补充 winget 安装目录（deno、ffmpeg 等可能不在注册表 PATH 中）
$wingetPackages = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
if (Test-Path $wingetPackages) {
    Get-ChildItem $wingetPackages -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-Path (Join-Path $_.FullName "*.exe")) {
            $env:PATH = "$($_.FullName);$env:PATH"
        }
    }
}

# ── 检测 yt-dlp（优先直接调用，回退 python -m）─────────────
$ytDlpBin = $null
if (Get-Command yt-dlp -ErrorAction SilentlyContinue) {
    $ytDlpBin = @("yt-dlp")
}
else {
    $ytDlpBin = @("python", "-m", "yt_dlp")
}

# ── 颜色辅助 ──────────────────────────────────
function Write-Step { Write-Host "`n▶ $args" -ForegroundColor Cyan }
function Write-OK   { Write-Host "  ✅ $args" -ForegroundColor Green }
function Write-Warn { Write-Host "  ⚠️  $args" -ForegroundColor Yellow }
function Write-Err  { Write-Host "  ❌ $args" -ForegroundColor Red }

# ── 加载配置 ──────────────────────────────────
$configPath = Join-Path $scriptDir "config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
else {
    Write-Warn "config.json 未找到，使用默认配置"
    $config = [PSCustomObject]@{
        outputDir       = ".\notes"
        keepTempFiles   = $false
        subLangPriority = @("zh-Hans", "zh-CN", "zh", "en", "en-US")
        llm             = @{ engine = "claude"; maxTokens = 4096 }
    }
}

# ── 工作目录 ──────────────────────────────────
$OutputDir = Join-Path $scriptDir $OutputDir
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$workDir = Join-Path $OutputDir "_work_$timestamp"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# ── 清理函数 ──────────────────────────────────
function Cleanup {
    if (-not $NoCleanup) {
        Write-Step "清理临时文件..."
        Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
        Write-OK "已清理"
    }
    else {
        Write-Warn "-NoCleanup 已设置，中间文件保留在: $workDir"
    }
}

# ═══════════════════════════════════════════════
# 第1步：获取视频信息
# ═══════════════════════════════════════════════
try {
    Write-Step "获取视频信息..."

    $ytDlpBase = @(
        "--no-playlist"
        "--no-check-certificates"
        "--socket-timeout", "30"
        "--retries", "3"
        "--add-header", "User-Agent:Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        "--add-header", "Referer:https://www.bilibili.com/"
        "--remote-components", "ejs:github"
    )

    # 如果指定了 Cookies 浏览器，添加 cookie 选项
    if ($Cookies) {
        # 判断是浏览器名还是文件路径
        if (Test-Path $Cookies -ErrorAction SilentlyContinue) {
            $ytDlpBase += @("--cookies", $Cookies)
        }
        else {
            $ytDlpBase += @("--cookies-from-browser", $Cookies)
        }
    }

    # 获取标题
    $title = & $ytDlpBin @ytDlpBase "--print" "%(title)s" "--no-download" $Url 2>&1 | Where-Object {
        $_ -is [string] -and $_ -notmatch '^WARNING:' -and $_.Trim() -ne ''
    } | Select-Object -Last 1

    if (-not $title) {
        Write-Err "无法获取视频信息，请检查链接是否有效"
        Write-Warn "B站 遇到限制? 尝试: .\video2note.ps1 -Url '...' -Cookies chrome"
        Write-Warn "YouTube 遇到限制? 尝试安装 deno: winget install deno"
        exit 1
    }

    $title = $title.Trim()
    Write-OK "视频: $title"

    # 安全文件名
    $safeTitle = $title -replace '[\\/:*?"<>|]', '_' -replace '\s+', ' ' -replace '\.\.+', '.'
    if ($safeTitle.Length -gt 120) { $safeTitle = $safeTitle.Substring(0, 120) }

}
catch {
    Write-Err "获取视频信息失败: $_"
    Cleanup
    exit 1
}

# ═══════════════════════════════════════════════
# 第2步：尝试下载字幕
# ═══════════════════════════════════════════════
$subtitleText = $null

try {
    Write-Step "尝试下载字幕..."

    $subLangs = ($config.subLangPriority -join ",")
    $subOutput = Join-Path $workDir "video"

    & $ytDlpBin @ytDlpBase `
        "--write-subs" `
        "--write-auto-subs" `
        "--sub-langs", $subLangs `
        "--skip-download" `
        `
        "-o", $subOutput `
        $Url 2>&1 | Out-Null

    # 查找字幕文件
    # 搜索字幕文件 (YouTube 通常为 .vtt，B站为 .srt)
    $srtFiles = Get-ChildItem -Path $workDir -Include "*.srt", "*.vtt" -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending

    # 排除只有少量内容的字幕（可能是占位文件）
    $srtFiles = $srtFiles | Where-Object { $_.Length -gt 100 }

    if ($srtFiles.Count -gt 0) {
        # 优先中文
        $zhSub = $srtFiles | Where-Object { $_.Name -match '\.(zh|zh-Hans|zh-CN)' } | Select-Object -First 1
        if (-not $zhSub) { $zhSub = $srtFiles | Select-Object -First 1 }

        $subSizeKB = [math]::Round($zhSub.Length / 1KB, 1)
        Write-OK "找到字幕: $($zhSub.Name) ($($subSizeKB) KB)"

        # 解析 SRT → 纯文本
        $subtitleText = Parse-SrtToText -Path $zhSub.FullName
        Write-OK "字幕提取完成 ($($subtitleText.Length) 字符)"
    }
    else {
        Write-Warn "无字幕可用，将使用语音转文字"
    }
}
catch {
    Write-Warn "字幕下载异常 ($_)，将使用语音转文字"
}

# ═══════════════════════════════════════════════
# 第3步：语音转文字（无字幕时）
# ═══════════════════════════════════════════════
if (-not $subtitleText) {
    try {
        Write-Step "下载音频..."

        $audioOutput = Join-Path $workDir "audio"
        $audioExtPattern = "$audioOutput.*"

        # 下载最佳音频
        & $ytDlpBin @ytDlpBase `
            "-x" `
            "--audio-format", "mp3" `
            "--audio-quality", "0" `
            "-o", $audioOutput `
            $Url 2>&1 | Out-Null

        # 找到下载的音频文件（可能是 .mp3 / .m4a / .webm 等）
        $audioFile = Get-ChildItem -Path $workDir | Where-Object {
            $_.Name.StartsWith("audio.") -and $_.Extension -in ".mp3", ".m4a", ".webm", ".opus", ".aac", ".wav"
        } | Select-Object -First 1

        if (-not $audioFile) {
            Write-Err "音频下载失败，找不到输出文件"
            Cleanup
            exit 1
        }

        $audioSize = [math]::Round($audioFile.Length / 1MB, 1)
        Write-OK "音频: $($audioFile.Name) ($audioSize MB)"

        # 转换为 16kHz mono WAV（FunASR 要求）
        Write-Step "音频格式转换 (16kHz mono WAV)..."
        $wavFile = Join-Path $workDir "audio_16k.wav"
        $ffmpegResult = & ffmpeg -y -hide_banner -loglevel error -i $audioFile.FullName -ar 16000 -ac 1 -acodec pcm_s16le $wavFile 2>&1

        if (-not (Test-Path $wavFile)) {
            Write-Err "ffmpeg 转换失败"
            Write-Err "ffmpeg 输出: $($ffmpegResult -join ' ') "
            Cleanup
            exit 1
        }

        $wavSizeMB = [math]::Round((Get-Item $wavFile).Length / 1MB, 1)
        Write-OK "WAV: $($wavSizeMB) MB"

        # 调用 FunASR（asr.py 自动处理分段：短音频一次性，长音频 3min×N 段）
        Write-Step "FunASR 语音转文字..."
        Write-Warn "首次运行会下载模型 (~1GB)，请耐心等待..."

        $asrScript = Join-Path $scriptDir "asr.py"

        # 注意: PowerShell 的 $ErrorActionPreference="Stop" 会把 Python 的
        # stderr 输出（进度条、日志）误判为错误。这里临时切回 Continue 模式，
        # 只检查 $LASTEXITCODE 来判断是否真正失败。
        $savedEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $transcription = & python $asrScript $wavFile   # 只捕获 stdout，stderr 直出终端
        $ErrorActionPreference = $savedEAP

        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
            Write-Err "FunASR 退出码: $LASTEXITCODE"
            $subtitleText = $null
        } else {
            $subtitleText = ($transcription -join "").Trim()
        }

        if (-not $subtitleText) {
            Write-Err "语音转文字结果为空"
            if ($LASTEXITCODE -ne 0) { Write-Err "FunASR 退出码: $LASTEXITCODE" }
            Cleanup
            exit 1
        }

        Write-OK "转写完成 ($($subtitleText.Length) 字符)"
    }
    catch {
        Write-Err "语音转文字失败: $_"
        Cleanup
        exit 1
    }
}

# ═══════════════════════════════════════════════
# 第4步：调用 Claude Code 生成笔记
# ═══════════════════════════════════════════════
try {
    Write-Step "Claude Code 生成笔记..."

    # 如果文本过长，截断提醒
    $maxInputChars = 80000  # ~20k tokens，留足余量
    $textForPrompt = $subtitleText
    if ($textForPrompt.Length -gt $maxInputChars) {
        $truncated = $textForPrompt.Substring(0, $maxInputChars)
        $remaining = $textForPrompt.Length - $maxInputChars
        $textForPrompt = $truncated + "`n`n[... 内容过长，已截断 $remaining 字符 ...]"
        Write-Warn "文本过长 ($($subtitleText.Length) 字符)，已截断至 $maxInputChars 字符"
    }

    # 构建 prompt（从 config 模板填充）
    $promptTemplate = $config.notePrompt
    if (-not $promptTemplate) {
        $promptTemplate = "请根据以下视频字幕/音频转录内容，生成一份结构化的学习笔记。`n`n要求：`n1. 用 Markdown 格式，标题用视频原标题「{title}」`n2. 包含：## 核心主题、## 关键概念、## 重要细节、## 个人可行动项`n3. 如果内容涉及技术，保留代码片段或命令示例`n4. 用中文撰写`n5. 在笔记末尾注明来源链接：{url}`n`n以下是视频内容：`n---`n{text}"
    }

    $prompt = $promptTemplate `
        -replace '\{title\}', $title `
        -replace '\{url\}', $Url `
        -replace '\{text\}', $textForPrompt

    # 写入临时文件（UTF-8 无 BOM，兼容 stdin 管道）
    $promptFile = Join-Path $workDir "prompt.txt"
    [System.IO.File]::WriteAllText($promptFile, $prompt, [System.Text.UTF8Encoding]::new($false))

    Write-Host "  发送 $($textForPrompt.Length) 字符到 Claude..." -ForegroundColor Gray

    # 将 prompt 写入 UTF-8 文件，通过 cmd /c 管道传入。
    # 关键：必须设置 OutputEncoding 为 UTF-8，否则 PowerShell 会用 GBK 解码 Claude 返回的 UTF-8 字节。
    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    try {
        $claudeOutput = cmd /c "chcp 65001 >nul & type `"$promptFile`" | claude --print --output-format text" 2>&1
    } finally {
        [Console]::OutputEncoding = $prevEncoding
    }

    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        Write-Warn "Claude 退出码: $LASTEXITCODE, 检查输出..."
    }

    $noteContent = ($claudeOutput | Out-String).Trim()

    if (-not $noteContent) {
        Write-Err "Claude Code 返回空内容"
        Cleanup
        exit 1
    }

    Write-OK "笔记生成完成 ($($noteContent.Length) 字符)"
}
catch {
    Write-Err "Claude Code 调用失败: $_"
    Write-Warn "提示: 确保 claude 已登录 (claude login)"
    Cleanup
    exit 1
}

# ═══════════════════════════════════════════════
# 第5步：保存笔记
# ═══════════════════════════════════════════════
try {
    $noteFilename = "$safeTitle.md"
    $notePath = Join-Path $OutputDir $noteFilename

    # 如果文件已存在，加时间戳
    if (Test-Path $notePath) {
        $noteFilename = "$safeTitle`_$timestamp.md"
        $notePath = Join-Path $OutputDir $noteFilename
    }

    [System.IO.File]::WriteAllText($notePath, $noteContent, [System.Text.UTF8Encoding]::new($false))
    Write-Step "笔记已保存: $($notePath | Resolve-Path -Relative)"
}
catch {
    Write-Err "保存笔记失败: $_"
    Cleanup
    exit 1
}

# ═══════════════════════════════════════════════
# 清理并输出结果
# ═══════════════════════════════════════════════
Cleanup

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host "  ✅ 完成！" -ForegroundColor Green
Write-Host "  📝 笔记: $notePath" -ForegroundColor White
Write-Host "  📹 来源: $Url" -ForegroundColor Gray
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor Green

# ═══════════════════════════════════════════════
# 辅助函数
# ═══════════════════════════════════════════════

function Parse-SrtToText {
    param([string]$Path)

    $lines = Get-Content $Path -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $lines) { return "" }

    $textLines = @()
    $isVTT = ($lines[0] -match '^WEBVTT')

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        # 跳过空白行
        if ($trimmed -eq '') { continue }

        # 跳过 VTT 头部
        if ($isVTT -and $trimmed -match '^(WEBVTT|Kind:|Language:)') { continue }

        # 跳过时间戳行
        if ($trimmed -match '^\d{2}:\d{2}:\d{2}[.,]\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}[.,]\d{3}') { continue }

        # 跳过纯数字行（SRT 序列号）
        if ($trimmed -match '^\d{1,6}$') { continue }

        # 跳过 CSS/VTT 样式行
        if ($trimmed -match '^::cue') { continue }

        # 移除 HTML 标签
        $clean = $trimmed -replace '<[^>]+>', ''

        # 解码常见 HTML 实体
        $clean = $clean -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'"

        if ($clean.Trim() -ne '') {
            $textLines += $clean.Trim()
        }
    }

    # 去重：连续相同行只保留一条（YouTube 自动字幕常见问题）
    $deduped = @()
    $prev = ''
    foreach ($t in $textLines) {
        if ($t -ne $prev) {
            $deduped += $t
            $prev = $t
        }
    }

    return ($deduped -join ' ').Trim()
}
