@echo off
REM Batch file to run OpenDomain.ps1 with arguments passed to this batch file

setlocal
set "PSPath="

REM Try to find powershell.exe in PATH
for /f "delims=" %%p in ('where powershell 2^>nul') do (
    set "PSPath=%%p"
    goto foundPS
)

REM Try to find pwsh.exe (PowerShell Core) in PATH
for %%v in (pwsh pwsh7 pwsh6) do (
    for /f "delims=" %%p in ('where %%v 2^>nul') do (
        set "PSPath=%%p"
        goto foundPS
    )
)

REM Check common Windows PowerShell default path
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
    set "PSPath=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
    goto foundPS
)

REM Check common PowerShell Core install paths (64-bit)
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    set "PSPath=%ProgramFiles%\PowerShell\7\pwsh.exe"
    goto foundPS
)
if exist "%ProgramFiles%\PowerShell\6\pwsh.exe" (
    set "PSPath=%ProgramFiles%\PowerShell\6\pwsh.exe"
    goto foundPS
)
if exist "%ProgramFiles%\PowerShell\pwsh.exe" (
    set "PSPath=%ProgramFiles%\PowerShell\pwsh.exe"
    goto foundPS
)

REM Check common PowerShell Core install paths (32-bit)
if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" (
    set "PSPath=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
    goto foundPS
)
if exist "%ProgramFiles(x86)%\PowerShell\6\pwsh.exe" (
    set "PSPath=%ProgramFiles(x86)%\PowerShell\6\pwsh.exe"
    goto foundPS
)
if exist "%ProgramFiles(x86)%\PowerShell\pwsh.exe" (
    set "PSPath=%ProgramFiles(x86)%\PowerShell\pwsh.exe"
    goto foundPS
)

echo [ERROR] PowerShell executable not found on this system.
pause
exit /b 1

:foundPS
REM Change directory to the script location
cd /d "%~dp0"

REM Run the PowerShell script, passing all arguments
"%PSPath%" -NoProfile -ExecutionPolicy Bypass -File "opendomain.ps1" %*

endlocal
pause
