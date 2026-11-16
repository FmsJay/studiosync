@echo off
rem Builds the menu extension for 64-bit Windows: reaper_studiosync-x64.dll, and with "reapersona" as the argument reaper_reapersona-x64.dll.
rem Needs the REAPER SDK (github.com/justinfrankel/reaper-sdk, its sdk folder) and MSVC (Visual Studio Build Tools). SDK path: REAPER_SDK, or the default below.
setlocal
if "%REAPER_SDK%"=="" set REAPER_SDK=J:\Portable Workstation\DAW\Extensions\reaper-sdk\sdk
set NAME=studiosync
set DEF=
if /i "%1"=="reapersona" (set NAME=reapersona& set DEF=/DREAPERSONA)
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
cd /d "%~dp0"
cl /nologo /LD /O2 /EHsc /MT /GS- /DWIN32 /D_WINDOWS /D_USRDLL /D_CRT_SECURE_NO_WARNINGS %DEF% /I"%REAPER_SDK%" reaper_menu.cpp /link /OUT:reaper_%NAME%-x64.dll user32.lib
set ERR=%ERRORLEVEL%
del /q reaper_menu.obj reaper_menu.lib reaper_menu.exp reaper_%NAME%-x64.lib reaper_%NAME%-x64.exp 2>nul
exit /b %ERR%
