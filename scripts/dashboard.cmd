@echo off
REM One-click launcher for the claude-dev dashboard.
REM Double-click this from Windows. It runs the dashboard INSIDE WSL (where Docker and the
REM containers live) and opens it in your browser. Keep this window open while you use it;
REM closing it stops the dashboard. Change the distro/port below if yours differ.
title claude-dev dashboard
wsl.exe -d Ubuntu -e bash -lc "python3 /path/to/claude-dev-environment/scripts/dashboard.py --open --port 8787"
echo.
echo Dashboard stopped. Press any key to close.
pause >nul
