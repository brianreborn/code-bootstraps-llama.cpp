@echo off
rem Click-and-go launcher for Windows: double-click. UNTESTED on Windows.
rem Downloads the pinned llama.cpp release and the models (sha256-checked), starts the
rem server and opens the web UI. Close this window to stop.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start.ps1" %*
if errorlevel 1 pause
