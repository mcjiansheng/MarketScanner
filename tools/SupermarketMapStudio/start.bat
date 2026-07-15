@echo off
setlocal
set SCRIPT_DIR=%~dp0
where py >nul 2>nul
if %ERRORLEVEL% EQU 0 (
  py -3 "%SCRIPT_DIR%server.py"
) else (
  python "%SCRIPT_DIR%server.py"
)
endlocal
