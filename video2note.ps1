#Requires -Version 5.1
<#
.SYNOPSIS
  视频链接 / 音频文件 / 视频文件 → 结构化 Markdown 笔记，一键自动化

.DESCRIPTION
  三种输入模式：
  - 视频链接：下载字幕（或 FunASR 语音转文字）→ Claude Code 生成笔记
  - 音频文件：ffmpeg 转 16kHz WAV → FunASR → Claude Code 生成笔记
  - 视频文件：ffmpeg 提取音频 → FunASR → Claude Code 生成笔记

.PARAMETER Url
  视频网页链接（URL 模式）

.PARAMETER AudioFile
  本地音频文件路径（音频文件模式）

.PARAMETER VideoFile
  本地视频文件路径（视频文件模式）

.PARAMETER Title
  自定义标题（文件模式可选，不填则从文件名推导）

.PARAMETER OutputDir
  笔记输出目录，默认 .\notes

.PARAMETER Cookies
  cookies.txt 文件路径（URL 模式可选）

.PARAMETER NoCleanup
  保留中间文件

.EXAMPLE
  # YouTube
  .\video2note.ps1 "https://www.youtube.com/watch?v=xxxxx"

.EXAMPLE
  # 音频文件
  .\video2note.ps1 -AudioFile ".\recording.mp3"

.EXAMPLE
  # 视频文件
  .\video2note.ps1 -VideoFile ".\lecture.mp4" -Title "我的课程笔记"
#>

[CmdletBinding(DefaultParameterSetName="Url")]
param(
    # ── URL 模式 ─────────────────────────────
    [Parameter(Mandatory=$true, ParameterSetName="Url", Position=0)]
    [string]$Url,

    [Parameter(ParameterSetName="Url")]
    [string]$Cookies,

    # ── 音频文件模式 ─────────────────────────
    [Parameter(Mandatory=$true, ParameterSetName="AudioFile", Position=0)]
    [string]$AudioFile,

    # ── 视频文件模式 ─────────────────────────
    [Parameter(Mandatory=$true, ParameterSetName="VideoFile", Position=0)]
    [string]$VideoFile,

    # ── 文件模式可选标题 ─────────────────────
    [Parameter(ParameterSetName="AudioFile")]
    [Parameter(ParameterSetName="VideoFile")]
    [string]$Title,

    # ── 共享参数 ─────────────────────────────
    [string]$OutputDir = ".\notes",

    [switch]$NoCleanup,

    [string]$ProgressFile
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── 刷新 PATH ─────────────────────────────────
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")

$wingetPackages = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
if (Test-Path $wingetPackages) {
    Get-ChildItem $wingetPackages -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-Path (Join-Path $_.FullName "*.exe")) {
            $env:PATH = "$($_.FullName);$env:PATH"
        }
    }
}

# ── 颜色辅助 ──────────────────────────────────
function Write-Step { $msg = "$args"; Write-Host "`n▶ $msg" -ForegroundColor Cyan;      Write-ProgressLog -Level "step" -Message $msg }
function Write-OK   { $msg = "$args"; Write-Host "  ✅ $msg" -ForegroundColor Green;      Write-ProgressLog -Level "ok"   -Message $msg }
function Write-Warn { $msg = "$args"; Write-Host "  ⚠️  $msg" -ForegroundColor Yellow;    Write-ProgressLog -Level "warn" -Message $msg }
function Write-Err  { $msg = "$args"; Write-Host "  ❌ $msg" -ForegroundColor Red;        Write-ProgressLog -Level "err"  -Message $msg }

function Write-ProgressLog {
    param([string]$Level, [string]$Message, [string]$Path)
    if (-not $script:ProgressFile) { return }

    $entry = [PSCustomObject]@{
        timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        level     = $Level
        message   = $Message
    }
    if ($Path) {
        $entry | Add-Member -MemberType NoteProperty -Name "path" -Value $Path
    }
    $json = $entry | ConvertTo-Json -Compress

    $maxRetries = 10
    for ($i = 0; $i -lt $maxRetries; $i++) {
        try {
            Add-Content -Path $script:ProgressFile -Value $json -Encoding UTF8 -ErrorAction Stop
            break
        } catch {
            if ($i -eq $maxRetries - 1) {
                Write-Host "  ⚠️ 进度文件写入失败（已重试${maxRetries}次）" -ForegroundColor DarkYellow
            } else {
                Start-Sleep -Milliseconds 50
            }
        }
    }
}

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
# 共享函数
# ═══════════════════════════════════════════════

function Convert-ToWav {
    <#
    .SYNOPSIS
      将音频/视频文件转换为 16kHz mono PCM WAV
    #>
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [switch]$IsVideo
    )

    $ffmpegArgs = @("-y", "-hide_banner", "-loglevel", "error", "-i", $InputPath)
    if ($IsVideo) { $ffmpegArgs += "-vn" }
    $ffmpegArgs += @("-ar", "16000", "-ac", "1", "-acodec", "pcm_s16le", $OutputPath)

    $result = & ffmpeg @ffmpegArgs 2>&1

    if (-not (Test-Path $OutputPath)) {
        throw "ffmpeg 转换失败: $($result -join ' ')"
    }

    $wavSizeMB = [math]::Round((Get-Item $OutputPath).Length / 1MB, 1)
    Write-OK "WAV: $($wavSizeMB) MB"
}

function Invoke-AsrTranscribe {
    <#
    .SYNOPSIS
      调用 FunASR asr.py 进行语音转文字
    #>
    param([string]$WavPath)

    Write-Step "FunASR 语音转文字..."
    Write-Warn "首次运行会下载模型 (~1GB)，请耐心等待..."

    $asrScript = Join-Path $scriptDir "asr.py"

    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $transcription = & python $asrScript $WavPath
    $ErrorActionPreference = $savedEAP

    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        Write-Err "FunASR 退出码: $LASTEXITCODE"
        return $null
    }

    $text = ($transcription -join "").Trim()

    if (-not $text) {
        Write-Err "语音转文字结果为空"
        if ($LASTEXITCODE -ne 0) { Write-Err "FunASR 退出码: $LASTEXITCODE" }
        return $null
    }

    Write-OK "转写完成 ($($text.Length) 字符)"
    return $text
}

function Invoke-ClaudeNote {
    <#
    .SYNOPSIS
      调用 Claude Code 生成结构化笔记
    #>
    param(
        [string]$Text,
        [string]$Title,
        [string]$SourceRef,
        [string]$WorkDir,
        [string]$PromptTemplate,
        [string]$Label = ""
    )

    if ($Label) {
        Write-Step "Claude Code 生成笔记 ($Label)..."
    } else {
        Write-Step "Claude Code 生成笔记..."
    }

    $maxInputChars = 80000
    $textForPrompt = $Text
    if ($textForPrompt.Length -gt $maxInputChars) {
        $truncated = $textForPrompt.Substring(0, $maxInputChars)
        $remaining = $textForPrompt.Length - $maxInputChars
        $textForPrompt = $truncated + "`n`n[... 内容过长，已截断 $remaining 字符 ...]"
        Write-Warn "文本过长 ($($Text.Length) 字符)，已截断至 $maxInputChars 字符"
    }

    if (-not $PromptTemplate) {
        $PromptTemplate = $config.notePrompt
    }
    if (-not $PromptTemplate) {
        $PromptTemplate = "请根据以下视频字幕/音频转录内容，生成一份结构化的学习笔记。`n`n要求：`n1. 用 Markdown 格式，标题用原标题「{title}」`n2. 包含：## 核心主题、## 关键概念、## 重要细节、## 个人可行动项`n3. 如果内容涉及技术，保留代码片段或命令示例`n4. 用中文撰写`n5. 在笔记末尾注明来源链接：{url}`n`n以下是视频内容：`n---`n{text}"
    }

    $prompt = $PromptTemplate `
        -replace '\{title\}', $Title `
        -replace '\{url\}', $SourceRef `
        -replace '\{text\}', $textForPrompt

    $promptFile = Join-Path $WorkDir "prompt.txt"
    [System.IO.File]::WriteAllText($promptFile, $prompt, [System.Text.UTF8Encoding]::new($false))

    Write-ProgressLog -Level "info" -Message "发送 $($textForPrompt.Length) 字符到 Claude ($Label)..."
    Write-Host "  发送 $($textForPrompt.Length) 字符到 Claude..." -ForegroundColor Gray

    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    try {
        $claudeOutput = cmd /c "chcp 65001 >nul & type `"$promptFile`" | claude --print --output-format text --tools `"`" --permission-mode bypassPermissions" 2>&1
    } finally {
        [Console]::OutputEncoding = $prevEncoding
    }

    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        Write-Warn "Claude 退出码: $LASTEXITCODE, 检查输出..."
    }

    $noteContent = ($claudeOutput | Out-String).Trim()

    if (-not $noteContent) {
        throw "Claude Code 返回空内容 ($Label)"
    }

    Write-OK "笔记生成完成 ($Label) — $($noteContent.Length) 字符"
    return $noteContent
}

function Parse-SrtToText {
    param([string]$Path)

    $lines = Get-Content $Path -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $lines) { return "" }

    $textLines = @()
    $isVTT = ($lines[0] -match '^WEBVTT')

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed -eq '') { continue }
        if ($isVTT -and $trimmed -match '^(WEBVTT|Kind:|Language:)') { continue }
        if ($trimmed -match '^\d{2}:\d{2}:\d{2}[.,]\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}[.,]\d{3}') { continue }
        if ($trimmed -match '^\d{1,6}$') { continue }
        if ($trimmed -match '^::cue') { continue }

        $clean = $trimmed -replace '<[^>]+>', ''
        $clean = $clean -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'"

        if ($clean.Trim() -ne '') {
            $textLines += $clean.Trim()
        }
    }

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

# ═══════════════════════════════════════════════
# 主流程
# ═══════════════════════════════════════════════

$subtitleText = $null
$sourceRef = $null

# ── 根据参数集确定模式 ────────────────────────
$mode = $PSCmdlet.ParameterSetName

switch ($mode) {

    # ═══════════════════════════════════════════
    # URL 模式
    # ═══════════════════════════════════════════
    "Url" {
        # yt-dlp 检测（仅 URL 模式需要）
        $ytDlpBin = $null
        if (Get-Command yt-dlp -ErrorAction SilentlyContinue) {
            $ytDlpBin = @("yt-dlp")
        }
        else {
            $ytDlpBin = @("python", "-m", "yt_dlp")
        }

        $ytDlpBase = @(
            "--no-playlist"
            "--no-check-certificates"
            "--socket-timeout", "30"
            "--retries", "3"
            "--add-header", "User-Agent:Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            "--add-header", "Referer:https://www.bilibili.com/"
            "--remote-components", "ejs:github"
        )

        if ($Cookies) {
            if (Test-Path $Cookies -ErrorAction SilentlyContinue) {
                $ytDlpBase += @("--cookies", $Cookies)
            }
            else {
                $ytDlpBase += @("--cookies-from-browser", $Cookies)
            }
        }

        try {
            Write-Step "获取视频信息并下载字幕..."

            $subLangs = ($config.subLangPriority -join ",")
            $subOutput = Join-Path $workDir "video"

            $savedEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $rawOutput = & $ytDlpBin @ytDlpBase `
                "--print", "__TITLE__:%(title)s" `
                "--write-subs" `
                "--write-auto-subs" `
                "--sub-langs", $subLangs `
                "--skip-download" `
                "-o", $subOutput `
                $Url 2>&1
            $ErrorActionPreference = $savedEAP

            $titleLine = $rawOutput | Where-Object { $_ -match '^__TITLE__:' } | Select-Object -Last 1
            if ($titleLine) {
                $title = $titleLine -replace '^__TITLE__:', ''
            } else {
                $title = $null
            }

            if (-not $title -or $title.Trim() -eq '') {
                Write-Err "无法获取视频信息，请检查链接是否有效"
                Write-Warn "B站 遇到限制? 尝试: .\video2note.ps1 -Url '...' -Cookies chrome"
                Write-Warn "YouTube 遇到限制? 尝试安装 deno: winget install deno"
                Cleanup
                exit 1
            }

            $title = $title.Trim()
            Write-OK "视频: $title"

            $sourceRef = $Url

            # 查找字幕
            $srtFiles = Get-ChildItem -Path $workDir -Include "*.srt", "*.vtt" -ErrorAction SilentlyContinue |
                Sort-Object Length -Descending |
                Where-Object { $_.Length -gt 100 }

            if ($srtFiles.Count -gt 0) {
                $zhSub = $srtFiles | Where-Object { $_.Name -match '\.(zh|zh-Hans|zh-CN)' } | Select-Object -First 1
                if (-not $zhSub) { $zhSub = $srtFiles | Select-Object -First 1 }

                $subSizeKB = [math]::Round($zhSub.Length / 1KB, 1)
                Write-OK "找到字幕: $($zhSub.Name) ($($subSizeKB) KB)"

                $subtitleText = Parse-SrtToText -Path $zhSub.FullName
                Write-OK "字幕提取完成 ($($subtitleText.Length) 字符)"
            }
            else {
                Write-Warn "无字幕可用，将使用语音转文字"
            }
        }
        catch {
            Write-Err "获取视频信息失败: $_"
            Cleanup
            exit 1
        }

        # URL 模式 — 无字幕回退：下载音频 → ASR
        if (-not $subtitleText) {
            try {
                Write-Step "下载音频..."

                $audioOutput = Join-Path $workDir "audio"

                $savedEAP = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                & $ytDlpBin @ytDlpBase `
                    "-x" `
                    "--audio-format", "mp3" `
                    "--audio-quality", "0" `
                    "-o", $audioOutput `
                    $Url 2>&1 | Out-Null
                $ErrorActionPreference = $savedEAP

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

                Write-Step "音频格式转换 (16kHz mono WAV)..."
                $wavFile = Join-Path $workDir "audio_16k.wav"
                Convert-ToWav -InputPath $audioFile.FullName -OutputPath $wavFile

                $subtitleText = Invoke-AsrTranscribe -WavPath $wavFile
                if (-not $subtitleText) {
                    Cleanup
                    exit 1
                }
            }
            catch {
                Write-Err "语音转文字失败: $_"
                Cleanup
                exit 1
            }
        }
    }

    # ═══════════════════════════════════════════
    # 音频文件模式
    # ═══════════════════════════════════════════
    "AudioFile" {
        if (-not (Test-Path $AudioFile)) {
            Write-Err "文件不存在: $AudioFile"
            Cleanup
            exit 1
        }

        # 推导标题
        if ($Title -and $Title.Trim() -ne '') {
            $title = $Title.Trim()
        }
        else {
            $title = [System.IO.Path]::GetFileNameWithoutExtension($AudioFile)
        }
        if (-not $title -or $title.Trim() -eq '') {
            $title = "未命名笔记"
        }
        Write-OK "标题: $title"

        $sourceRef = [System.IO.Path]::GetFileName($AudioFile)

        try {
            Write-Step "音频格式转换 (16kHz mono WAV)..."
            $wavFile = Join-Path $workDir "audio_16k.wav"
            Convert-ToWav -InputPath $AudioFile -OutputPath $wavFile

            $subtitleText = Invoke-AsrTranscribe -WavPath $wavFile
            if (-not $subtitleText) {
                Cleanup
                exit 1
            }
        }
        catch {
            Write-Err "处理失败: $_"
            Cleanup
            exit 1
        }
    }

    # ═══════════════════════════════════════════
    # 视频文件模式
    # ═══════════════════════════════════════════
    "VideoFile" {
        if (-not (Test-Path $VideoFile)) {
            Write-Err "文件不存在: $VideoFile"
            Cleanup
            exit 1
        }

        # 推导标题
        if ($Title -and $Title.Trim() -ne '') {
            $title = $Title.Trim()
        }
        else {
            $title = [System.IO.Path]::GetFileNameWithoutExtension($VideoFile)
        }
        if (-not $title -or $title.Trim() -eq '') {
            $title = "未命名笔记"
        }
        Write-OK "标题: $title"

        $sourceRef = [System.IO.Path]::GetFileName($VideoFile)

        try {
            Write-Step "提取音频并转换格式 (16kHz mono WAV)..."
            $wavFile = Join-Path $workDir "audio_16k.wav"
            Convert-ToWav -InputPath $VideoFile -OutputPath $wavFile -IsVideo

            $subtitleText = Invoke-AsrTranscribe -WavPath $wavFile
            if (-not $subtitleText) {
                Cleanup
                exit 1
            }
        }
        catch {
            Write-Err "处理失败: $_"
            Cleanup
            exit 1
        }
    }
}

# ═══════════════════════════════════════════════
# 共享阶段：Claude Code 生成笔记（精炼版 + 详细版）
# ═══════════════════════════════════════════════
if (-not $subtitleText) {
    Write-Err "没有可处理的文本内容"
    Cleanup
    exit 1
}

# ── 生成精炼版笔记 ─────────────────────────────
try {
    $conciseContent = Invoke-ClaudeNote -Text $subtitleText -Title $title -SourceRef $sourceRef -WorkDir $workDir -PromptTemplate $config.notePrompt -Label "精炼版"
}
catch {
    Write-Err "Claude Code 调用失败 (精炼版): $_"
    Write-Warn "提示: 确保 claude 已登录 (claude login)"
    Cleanup
    exit 1
}

# ── 生成详细版笔记 ─────────────────────────────
try {
    $detailedPrompt = $config.detailedNotePrompt
    if (-not $detailedPrompt) {
        $detailedPrompt = "请根据以下视频字幕/音频转录内容，生成一份**极其详尽、事无巨细**的学习笔记。`n`n注意：以下内容来自自动语音识别（ASR），人名、品牌名、专有名词可能不准确，请根据上下文推断正确名称，不确定的标注「[音译，待核实]」。`n`n要求：`n1. 用 Markdown 格式，标题用视频原标题「{title}」`n2. 包含以下结构：`n   ## 完整内容记录 — 按时间线或逻辑顺序，逐段逐节复述所有内容，不遗漏任何信息`n   ## 核心主题`n   ## 关键概念详解 — 每个概念包含定义、原理、示例、应用场景`n   ## 重要细节与数据 — 所有数字、时间节点、参数、配置`n   ## 问答/讨论记录`n   ## 个人可行动项`n3. 用中文撰写，字数不限，越长越详细越好`n4. 在笔记末尾注明来源链接：{url}`n5. 不要空行——Markdown 段落之间不要有空行`n`n以下是视频内容：`n---`n{text}"
    }
    $detailedContent = Invoke-ClaudeNote -Text $subtitleText -Title $title -SourceRef $sourceRef -WorkDir $workDir -PromptTemplate $detailedPrompt -Label "详细版"
}
catch {
    Write-Err "Claude Code 调用失败 (详细版): $_"
    Write-Warn "提示: 确保 claude 已登录 (claude login)"
    Cleanup
    exit 1
}

# ═══════════════════════════════════════════════
# 保存笔记（精炼版 + 详细版）
# ═══════════════════════════════════════════════
try {
    $safeTitle = $title -replace '[\\/:*?"<>|]', '_' -replace '\s+', ' ' -replace '\.\.+', '.'
    if ($safeTitle.Length -gt 100) { $safeTitle = $safeTitle.Substring(0, 100) }

    # 精炼版
    $conciseFilename = "$safeTitle.md"
    $concisePath = Join-Path $OutputDir $conciseFilename
    if (Test-Path $concisePath) {
        $conciseFilename = "$safeTitle`_$timestamp.md"
        $concisePath = Join-Path $OutputDir $conciseFilename
    }
    [System.IO.File]::WriteAllText($concisePath, $conciseContent, [System.Text.UTF8Encoding]::new($false))
    Write-OK "精炼版笔记已保存: $($concisePath | Resolve-Path -Relative)"

    # 详细版
    $detailedFilename = "$safeTitle`_详细.md"
    $detailedPath = Join-Path $OutputDir $detailedFilename
    if (Test-Path $detailedPath) {
        $detailedFilename = "$safeTitle`_详细_$timestamp.md"
        $detailedPath = Join-Path $OutputDir $detailedFilename
    }
    [System.IO.File]::WriteAllText($detailedPath, $detailedContent, [System.Text.UTF8Encoding]::new($false))
    Write-OK "详细版笔记已保存: $($detailedPath | Resolve-Path -Relative)"
}
catch {
    Write-Err "保存笔记失败: $_"
    Cleanup
    exit 1
}

# ═══════════════════════════════════════════════
# 清理并输出结果
# ═══════════════════════════════════════════════
Write-ProgressLog -Level "done" -Message "笔记已生成" -Path $concisePath
Cleanup

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host "  ✅ 完成！" -ForegroundColor Green
Write-Host "  📝 精炼版: $concisePath" -ForegroundColor White
Write-Host "  📚 详细版: $detailedPath" -ForegroundColor White
Write-Host "  📹 来源: $sourceRef" -ForegroundColor Gray
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor Green
