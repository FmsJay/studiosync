@echo off
rem The docked web UI's native test (tests/webui_dock_test.cpp with extension/webui_dock.cpp, and the web UI server it loads from, no
rem REAPER): builds webui_dock_test.exe in %TEMP% and runs it. Without the WebView2 Runtime the headless part says skip. macOS/Linux:
rem   c++ -std=c++17 -O2 -pthread -DWEBUI_DOCK_STANDALONE tests/webui_dock_test.cpp extension/webui_dock.cpp -o /tmp/webui_dock_test && /tmp/webui_dock_test
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
set OUT=%TEMP%\ss_webui_dock_test_build
if not exist "%OUT%" mkdir "%OUT%"
set SS_REPO=%~dp0..
cl /nologo /O2 /EHsc /MT /W3 /DWEBUI_DOCK_STANDALONE /DDIRECT_STANDALONE /DWEBUI_STANDALONE /D_CRT_SECURE_NO_WARNINGS /Fo"%OUT%\\" /Fe"%OUT%\webui_dock_test.exe" "%~dp0webui_dock_test.cpp" "%~dp0..\extension\webui_dock.cpp" "%~dp0..\extension\webui.cpp" "%~dp0..\extension\direct.cpp" "%~dp0..\extension\direct_audio.cpp" /link "%~dp0..\extension\third_party\webview2\x64\WebView2LoaderStatic.lib" ws2_32.lib user32.lib ole32.lib shell32.lib advapi32.lib >"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
"%OUT%\webui_dock_test.exe" %*
