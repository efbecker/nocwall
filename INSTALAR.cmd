@echo off
rem ===================================================================
rem  Scry - Video Wall: instalar ou atualizar com dois cliques.
rem  Pede permissao de Administrador e roda NOC\Deploy-Scry.ps1.
rem  Opcional na linha de comando: INSTALAR.cmd -Reinstalar
rem ===================================================================
setlocal
set "SCRIPT=%~dp0NOC\Deploy-Scry.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0Deploy-Scry.ps1"
if not exist "%SCRIPT%" (
  echo Nao encontrei NOC\Deploy-Scry.ps1 ao lado deste arquivo.
  echo Extraia o .zip inteiro e rode o INSTALAR.cmd de dentro da pasta extraida.
  pause
  exit /b 1
)

rem Sem privilegio de Administrador? Reabre este arquivo pedindo elevacao (UAC).
net session >nul 2>&1
if errorlevel 1 (
  echo Pedindo permissao de Administrador...
  if "%~1"=="" (
    powershell.exe -NoProfile -Command "Start-Process -FilePath %~f0 -Verb RunAs"
  ) else (
    powershell.exe -NoProfile -Command "Start-Process -FilePath %~f0 -ArgumentList %* -Verb RunAs"
  )
  exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
echo.
pause
