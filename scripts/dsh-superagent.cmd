@echo off
rem Windows entry point for scripts/dsh-superagent.ps1; the POSIX sibling needs tmux, fcntl and ps.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-superagent.ps1" %*
