@echo off
rem VOIDBLOOM - double-click this to send the server to GitHub.
rem Render sees the commit and redeploys itself.
title VOIDBLOOM - ship the co-op server
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\update-server.ps1"
if errorlevel 1 pause
