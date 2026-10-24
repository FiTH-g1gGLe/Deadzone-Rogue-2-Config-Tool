@echo off
rem Starts the Deadzone: Rogue 2 Config Tool window. Close the game before applying.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Deadzone-Config-Tool.ps1" %*
if errorlevel 1 pause
