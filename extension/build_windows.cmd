@echo off
rem Builds the menu extension for 64-bit Windows: reaper_studiosync-x64.dll, and with "reapersona" as the argument reaper_reapersona-x64.dll.
rem Needs the REAPER SDK (github.com/justinfrankel/reaper-sdk, its sdk folder) and MSVC (Visual Studio Build Tools). SDK path: REAPER_SDK, or the default below.
rem StudioSync's also has the direct link (direct.cpp, sockets: ws2_32), the web UI server (webui.cpp) signed updates (sign.cpp: bcrypt, by its #pragma) and the Hop plug-in's end (hop.cpp, plugin/hop_shm.h). DLL_OUT: another file name, for a build while REAPER holds the DLL.
rem And the web UI docked in REAPER (webui_dock.cpp): WebView2's static loader, third_party\webview2 (no WebView2Loader.dll to ship), and what it needs: ole32, shell32, advapi32.
setlocal
if "%REAPER_SDK%"=="" set REAPER_SDK=J:\Portable Workstation\DAW\Extensions\reaper-sdk\sdk
set NAME=studiosync
set DEF=
set SRC=reaper_menu.cpp direct.cpp direct_audio.cpp sign.cpp webui.cpp webui_dock.cpp hop.cpp
set LIBS=third_party\webview2\x64\WebView2LoaderStatic.lib ole32.lib shell32.lib advapi32.lib
if /i "%1"=="reapersona" (set NAME=reapersona& set DEF=/DREAPERSONA& set SRC=reaper_menu.cpp& set LIBS=)
set OUT=reaper_%NAME%-x64.dll
if not "%DLL_OUT%"=="" set OUT=%DLL_OUT%
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
cd /d "%~dp0"
cl /nologo /LD /O2 /EHsc /MT /GS- /W3 /DWIN32 /D_WINDOWS /D_USRDLL /D_CRT_SECURE_NO_WARNINGS %DEF% /I"%REAPER_SDK%" %SRC% /link /OUT:%OUT% user32.lib ws2_32.lib %LIBS%
set ERR=%ERRORLEVEL%
del /q reaper_menu.obj direct.obj direct_audio.obj sign.obj webui.obj webui_dock.obj hop.obj reaper_menu.lib reaper_menu.exp reaper_%NAME%-x64.lib reaper_%NAME%-x64.exp 2>nul
exit /b %ERR%
