@echo off
rem Builds the menu extension for 64-bit Windows: reaper_studiosync-x64.dll, and with "reapersona" as the argument reaper_reapersona-x64.dll.
rem Needs the REAPER SDK (github.com/justinfrankel/reaper-sdk, its sdk folder) and MSVC (Visual Studio Build Tools). SDK path: REAPER_SDK, or the default below.
rem StudioSync's also has the direct link (direct.cpp, sockets: ws2_32), the web UI server (webui.cpp), signed updates (sign.cpp: bcrypt, by its #pragma) and the Hop plug-in's end (hop.cpp, plugin/hop_shm.h). DLL_OUT: another file name, for a build while REAPER holds the DLL.
setlocal
if "%REAPER_SDK%"=="" set REAPER_SDK=J:\Portable Workstation\DAW\Extensions\reaper-sdk\sdk
set NAME=studiosync
set DEF=
set SRC=reaper_menu.cpp direct.cpp direct_audio.cpp sign.cpp webui.cpp hop.cpp
if /i "%1"=="reapersona" (set NAME=reapersona& set DEF=/DREAPERSONA& set SRC=reaper_menu.cpp)
set OUT=reaper_%NAME%-x64.dll
if not "%DLL_OUT%"=="" set OUT=%DLL_OUT%
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
cd /d "%~dp0"
cl /nologo /LD /O2 /EHsc /MT /GS- /W3 /DWIN32 /D_WINDOWS /D_USRDLL /D_CRT_SECURE_NO_WARNINGS %DEF% /I"%REAPER_SDK%" %SRC% /link /OUT:%OUT% user32.lib ws2_32.lib
set ERR=%ERRORLEVEL%
del /q reaper_menu.obj direct.obj direct_audio.obj sign.obj webui.obj hop.obj reaper_menu.lib reaper_menu.exp reaper_%NAME%-x64.lib reaper_%NAME%-x64.exp 2>nul
exit /b %ERR%
