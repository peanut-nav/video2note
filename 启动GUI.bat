@echo off
cd /d "%~dp0"

:: 优先使用 pythonw（无黑窗），找不到则用 python
where pythonw >nul 2>&1
if %errorlevel%==0 (
    start "" pythonw gui.py
) else (
    start "" python gui.py
)
