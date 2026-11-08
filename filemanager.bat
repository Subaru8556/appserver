@echo off
cd /d %~dp0
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "server.ps1" -App "filemanager" -Standalone