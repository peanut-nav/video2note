# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

Video URL → structured Markdown note, fully automated. Input a YouTube/Bilibili/etc. link, get a polished Chinese-language study note. Uses Claude Code (`--print` non-interactive mode) for the final summarization step.

## Core pipeline

```
URL → yt-dlp download subtitles
       ├─ subtitles found → parse .srt/.vtt to plaintext (seconds)
       └─ no subtitles → download audio → ffmpeg → 16kHz mono WAV → FunASR paraformer-zh → text (minutes)
                                              ↓
                                    Claude Code generates note
                                              ↓
                                        notes/标题.md
```

## How to run

```powershell
# YouTube
.\video2note.ps1 "https://www.youtube.com/watch?v=xxxxx"

# Bilibili (requires cookies.txt — see 使用教程.md)
.\video2note.ps1 "https://www.bilibili.com/video/BVxxxxx" -Cookies ".\bilibili_cookies.txt"

# Keep intermediate files for debugging
.\video2note.ps1 "https://..." -NoCleanup

# Standalone ASR (requires 16kHz mono WAV)
python asr.py audio_16k.wav
```

## Dependency check commands

```powershell
python -c "import yt_dlp; print('yt-dlp OK')" 2>&1   # yt-dlp
pip show funasr 2>&1                                    # FunASR
Get-Command ffmpeg -ErrorAction SilentlyContinue        # ffmpeg
Get-Command claude -ErrorAction SilentlyContinue        # Claude Code
Get-Command deno -ErrorAction SilentlyContinue          # Deno (YouTube JS challenges)
```

## Architecture

| File | Role |
|------|------|
| `video2note.ps1` | Main orchestrator — PATH refresh, yt-dlp download, subtitle parsing, ASR fallback, Claude invocation, output |
| `asr.py` | FunASR speech-to-text module — loads paraformer-zh model, auto-chunks audio >3.5min into 3min segments to avoid O(n²) attention memory blowup |
| `config.json` | User-editable config: subtitle language priority, `notePrompt` template (variables: `{title}`, `{url}`, `{text}`), ASR/LLM settings |
| `bilibili_cookies.txt` | Netscape-format cookies for Bilibili auth (user exports once via browser console) |

## Critical encoding rules (PowerShell 5.1 on Chinese Windows)

1. **`video2note.ps1` MUST be UTF-8 with BOM.** Without BOM, PowerShell 5.1 reads the file as GBK, corrupting comment/string bytes containing `MB`/`KB` substrings, causing parse errors. Always write with `[System.Text.UTF8Encoding]::new($true)`.

2. **`[Console]::OutputEncoding` must be set to UTF-8 before capturing Claude stdout.** PowerShell defaults to system ANSI code page (GBK/cp936), which garbles the UTF-8 bytes from `claude --print`. Save and restore in a `try/finally` block.

3. **`$ErrorActionPreference = "Stop"` breaks Python subprocess calls.** Python/FunASR write all progress to stderr; PowerShell interprets ANY stderr as an error and aborts. Temporarily switch to `"Continue"` before calling Python, restore after, and check `$LASTEXITCODE` for actual failures.

4. **Pipe UTF-8 text to external commands via `cmd /c`.** PowerShell's native pipe re-encodes through the console code page. Use: `cmd /c "chcp 65001 >nul & type file.txt | command"` to bypass. The temp file must be UTF-8 without BOM (BOM confuses stdin parsers).

## ASR chunking strategy (`asr.py`)

- Audio ≤ 3.5 min: single `model.generate(batch_size_s=300)` call
- Audio > 3.5 min: ffmpeg splits into 3-min chunks → each chunk transcribed independently → results joined with spaces
- Rationale: paraformer-zh self-attention is O(n²) memory; a 15-min 16kHz audio (~14M samples) needs ~3.7GB attention matrix, causing OOM

## `video2note.ps1` PATH handling

The script refreshes `$env:PATH` from registry (Machine + User) and scans winget package directories at startup. This avoids "command not found" errors when winget-installed tools (deno, ffmpeg) haven't been added to the terminal session PATH yet. yt-dlp is invoked as `python -m yt_dlp` to avoid the same problem with pip-installed scripts.
