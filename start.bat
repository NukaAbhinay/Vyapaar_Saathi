@echo off
REM Paytm Vyaapar Saathi - open the app in a real browser tab (the only place the mic works)
cd /d "%~dp0"
title Paytm Vyaapar Saathi

where py >nul 2>nul
if %errorlevel%==0 (
  py start.py
  goto :eof
)
where python >nul 2>nul
if %errorlevel%==0 (
  python start.py
  goto :eof
)
where python3 >nul 2>nul
if %errorlevel%==0 (
  python3 start.py
  goto :eof
)

echo.
echo  Python not found. Starting a tiny PowerShell server instead...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
