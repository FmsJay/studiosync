@echo off
rem The web UI server's native test (tests/webui_test.cpp with extension/webui.cpp and the direct link it rides on, no REAPER): builds
rem webui_test.exe in %TEMP% and runs it. macOS/Linux:
rem   c++ -std=c++17 -O2 -pthread -DDIRECT_STANDALONE -DWEBUI_STANDALONE tests/webui_test.cpp extension/webui.cpp extension/direct.cpp extension/direct_audio.cpp -o /tmp/webui_test && /tmp/webui_test
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
set OUT=%TEMP%\ss_webui_test_build
if not exist "%OUT%" mkdir "%OUT%"
cl /nologo /O2 /EHsc /MT /W3 /DDIRECT_STANDALONE /DWEBUI_STANDALONE /D_CRT_SECURE_NO_WARNINGS /Fo"%OUT%\\" /Fe"%OUT%\webui_test.exe" "%~dp0webui_test.cpp" "%~dp0..\extension\webui.cpp" "%~dp0..\extension\direct.cpp" "%~dp0..\extension\direct_audio.cpp" /link ws2_32.lib >"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
"%OUT%\webui_test.exe" %*
