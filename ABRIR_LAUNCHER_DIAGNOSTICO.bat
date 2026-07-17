@echo off
cd /d "%~dp0"
title Firebrand Palworld Server Launcher - Diagnostico
echo Iniciando launcher desde:
echo %CD%
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -NoExit -Command "& '%~dp0launcher\FirebrandPalworldLauncher.ps1'"
