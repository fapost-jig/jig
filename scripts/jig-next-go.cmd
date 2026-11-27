@echo off
setlocal
rem jig-next-go.cmd -- the Windows launcher of scripts/jig-next-go, which is a
rem bash script: PowerShell and cmd.exe cannot run it themselves. LF-only, as
rem scripts/jig.cmd is, for the same reason; this file has no labels or goto.
rem PATH's "bash" can be the WSL launcher, so Git for Windows' own Bash is
rem found next to git's exec path, as scripts/jig.cmd finds it.
for /f "delims=" %%G in ('git --exec-path') do set "JIG_GIT_EXEC=%%G"
set "JIG_BASH=%JIG_GIT_EXEC%\..\..\..\bin\bash.exe"
if not exist "%JIG_BASH%" (echo jig-next-go: Git Bash not found next to git 1>&2 & exit /b 127)
set "JIG_SELF=%~dp0jig-next-go"
set "JIG_SELF=%JIG_SELF:\=/%"
"%JIG_BASH%" "%JIG_SELF%" %*
exit /b %ERRORLEVEL%
