@echo off
rem The live audio core's native test (tests/rtaudio_test.cpp with extension/rtaudio.cpp, AOO and Opus, no REAPER): builds rtaudio_test.exe in
rem %TEMP% and runs it. The libraries come from extension\third_party\build_windows.cmd (built once). macOS/Linux: the CI's lines.
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
set TP=%~dp0..\extension\third_party
if not exist "%TP%\build\studiosync_deps-x64.lib" call "%TP%\build_windows.cmd" || exit /b 1
set OUT=%TEMP%\ss_rtaudio_test
if not exist "%OUT%" mkdir "%OUT%"
cl /nologo /O2 /EHsc /MT /W3 /std:c++17 /DRTAUDIO_STANDALONE /DDIRECT_STANDALONE /D_CRT_SECURE_NO_WARNINGS /I"%TP%\aoo" /I"%TP%\aoo\include" /I"%TP%\opus\include" /Fo"%OUT%\\" /Fe"%OUT%\rtaudio_test.exe" "%~dp0rtaudio_test.cpp" "%~dp0..\extension\rtaudio.cpp" "%~dp0..\extension\direct.cpp" "%~dp0..\extension\direct_audio.cpp" /link "%TP%\build\studiosync_deps-x64.lib" ws2_32.lib advapi32.lib >"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
"%OUT%\rtaudio_test.exe" %*
