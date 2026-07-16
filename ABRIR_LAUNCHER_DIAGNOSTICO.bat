@echo off
cd /d "%~dp0"
title Palworld Server Manager v7.3 - Diagnostico
echo Iniciando launcher desde:
echo %CD%
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -NoExit -Command "& '%~dp0launcher\PalworldLauncher.ps1'"
