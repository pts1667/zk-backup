@echo off
rem No arguments (e.g. double-clicked): open the join window without keeping a console around.
if "%~1"=="" (
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0zk-direct.ps1"
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0zk-direct.ps1" %*
