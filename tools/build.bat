@echo off
rem Lighthouse CLI build - cmd.exe friendly wrapper for build.sh
rem Usage: double-click, or run: build.bat
chcp 65001 >nul
cd /d "%~dp0"

set "BASH=C:\Users\Administrator\.workbuddy\binaries\PortableGit\versions\1.2.0\bin\bash.exe"
if not exist "%BASH%" set "BASH=bash"

"%BASH%" build.sh %*
echo.
pause
