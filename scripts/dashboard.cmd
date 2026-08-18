@echo off
REM One-click launcher for the claude-dev dashboard.
REM Double-click this from Windows. It runs the dashboard INSIDE WSL (where Docker and the
REM containers live) and opens it in your browser. Keep this window open while you use it;
REM closing it stops the dashboard.
REM Self-locating: works wherever the repo lives (no hard-coded path). The dashboard reads
REM its distro/port from config/local.env. Uses your default WSL distro; pass one explicitly
REM below (wsl.exe -d <name> ...) if that isn't the one with Docker.
title claude-dev dashboard
wsl.exe -e bash -lc "python3 \"$(wslpath -a '%~dp0dashboard.py')\" --open"
echo.
echo Dashboard stopped. Press any key to close.
pause >nul
