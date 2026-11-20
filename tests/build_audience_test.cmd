@echo off
rem Live to an audience's native test (tests/audience_test.cpp with extension/audience.cpp, the web UI server it hands over from, the direct
rem link that one rides on, and Opus, no REAPER): builds audience_test.exe in %TEMP% and runs it. The libraries come from
rem extension\third_party\build_windows.cmd (built once). macOS/Linux (libssdeps.a from extension/third_party/build_unix.sh):
rem   c++ -std=c++17 -O2 -pthread -DAUDIENCE_STANDALONE -DDIRECT_STANDALONE -DWEBUI_STANDALONE -I extension/third_party/opus/include tests/audience_test.cpp extension/audience.cpp extension/webui.cpp extension/direct.cpp extension/direct_audio.cpp libssdeps.a -o /tmp/audience_test && /tmp/audience_test
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
set TP=%~dp0..\extension\third_party
if not exist "%TP%\build\studiosync_deps-x64.lib" call "%TP%\build_windows.cmd" || exit /b 1
set OUT=%TEMP%\ss_audience_test
if not exist "%OUT%" mkdir "%OUT%"
cl /nologo /O2 /EHsc /MT /W3 /std:c++17 /DAUDIENCE_STANDALONE /DDIRECT_STANDALONE /DWEBUI_STANDALONE /D_CRT_SECURE_NO_WARNINGS /I"%TP%\opus\include" /Fo"%OUT%\\" /Fe"%OUT%\audience_test.exe" "%~dp0audience_test.cpp" "%~dp0..\extension\audience.cpp" "%~dp0..\extension\webui.cpp" "%~dp0..\extension\direct.cpp" "%~dp0..\extension\direct_audio.cpp" /link "%TP%\build\studiosync_deps-x64.lib" ws2_32.lib advapi32.lib >"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
"%OUT%\audience_test.exe" %*
