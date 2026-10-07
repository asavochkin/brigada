@echo off
rem brg.cmd - brigada for PowerShell and cmd on Windows: runs brg (the file next
rem to this one) in Git Bash. From the project root: .\.brigada\bin\brg.cmd join ...
rem
rem bash.exe of Git for Windows is looked up in this order; bash from PATH is
rem never used (C:\Windows\System32\bash.exe is the bash of WSL):
rem   1. the variable BRG_BASH (full path of bash.exe)
rem   2. ProgramFiles\Git\bin\bash.exe
rem   3. ProgramFiles(x86)\Git\bin\bash.exe
rem   4. LOCALAPPDATA\Programs\Git\bin\bash.exe (Git installed for one user)
rem   5. USERPROFILE\scoop\apps\git\current\bin\bash.exe (scoop)
rem   6. for every git.exe found by "where git": bin\bash.exe of that Git
rem The console code page is switched to UTF-8 (65001) for the call and restored
rem afterwards; BRG_NO_CHCP=1 leaves it alone. The exit code of brg is kept.
rem Keep this file ASCII with CRLF line endings (see .gitattributes).
setlocal EnableExtensions DisableDelayedExpansion
set "BRG_SH="

if not defined BRG_BASH goto brg_std
if exist "%BRG_BASH%" set "BRG_SH=%BRG_BASH%"
if defined BRG_SH goto brg_found
>&2 echo brg.cmd: BRG_BASH=%BRG_BASH% - no such file. Set BRG_BASH to bash.exe of Git for Windows or unset it.
exit /b 127

:brg_std
if exist "%ProgramFiles%\Git\bin\bash.exe" set "BRG_SH=%ProgramFiles%\Git\bin\bash.exe"
if defined BRG_SH goto brg_found
if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BRG_SH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if defined BRG_SH goto brg_found
if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BRG_SH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if defined BRG_SH goto brg_found
if exist "%USERPROFILE%\scoop\apps\git\current\bin\bash.exe" set "BRG_SH=%USERPROFILE%\scoop\apps\git\current\bin\bash.exe"
if defined BRG_SH goto brg_found
for /f "delims=" %%G in ('where git 2^>nul') do if not defined BRG_SH call :brg_from_git "%%~dpG"
if defined BRG_SH goto brg_found
>&2 echo brg.cmd: Git Bash not found. Install Git for Windows (https://git-scm.com/download/win)
>&2 echo brg.cmd: or set BRG_BASH to the full path of its bash.exe, e.g. C:\Program Files\Git\bin\bash.exe
exit /b 127

:brg_from_git
rem argument: the directory of git.exe - GITROOT\cmd, GITROOT\bin or GITROOT\mingw64\bin
set "BRG_G=%~1"
if exist "%BRG_G%..\bin\bash.exe" set "BRG_SH=%BRG_G%..\bin\bash.exe"
if defined BRG_SH exit /b 0
if exist "%BRG_G%..\..\bin\bash.exe" set "BRG_SH=%BRG_G%..\..\bin\bash.exe"
if defined BRG_SH exit /b 0
if exist "%BRG_G%bash.exe" set "BRG_SH=%BRG_G%bash.exe"
exit /b 0

:brg_found
rem WSL's bash.exe lives in System32 (or WindowsApps): refuse it
if /i not "%BRG_SH:\System32\=%"=="%BRG_SH%" goto brg_wsl
if /i not "%BRG_SH:\WindowsApps\=%"=="%BRG_SH%" goto brg_wsl
rem brg: next to this file; forward slashes - bash takes C:/... paths as they are
set "BRG_SCRIPT=%~dp0brg"
set "BRG_SCRIPT=%BRG_SCRIPT:\=/%"
rem brg prints its commands for PowerShell/cmd (.\.brigada\bin\brg.cmd) when this is set
set "BRG_VIA_CMD=%~f0"
set "BRG_CP="
if defined BRG_NO_CHCP goto brg_exec
for /f "tokens=2 delims=:." %%C in ('chcp 2^>nul') do set "BRG_CP=%%C"
if defined BRG_CP set "BRG_CP=%BRG_CP: =%"
if defined BRG_CP chcp 65001 >nul 2>&1

:brg_exec
"%BRG_SH%" "%BRG_SCRIPT%" %*
set "BRG_RC=%ERRORLEVEL%"
if defined BRG_CP chcp %BRG_CP% >nul 2>&1
exit /b %BRG_RC%

:brg_wsl
>&2 echo brg.cmd: %BRG_SH% is the bash of WSL, not Git Bash. Set BRG_BASH to bash.exe of Git for Windows.
exit /b 127
