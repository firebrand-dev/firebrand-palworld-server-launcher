@echo off
cd /d "%~dp0"
title Palworld Server Manager v7.3
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0launcher\PalworldLauncher.ps1"
if errorlevel 1 (
    echo.
    echo El launcher termino con un error.
    echo Copia o captura el mensaje que aparece arriba.
    pause
)
