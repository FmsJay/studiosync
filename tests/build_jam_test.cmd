@echo off
rem The Jam capture's native test (tests/jam_test.cpp with extension/direct_audio.cpp, no REAPER): builds jam_test.exe in %TEMP% and runs it.
rem With Opus (rt-p12: Jam over Ogg Opus and the receiver's decoder): JAM_OPUS and the libraries from extension\third_party\build_windows.cmd.
rem macOS/Linux (libssdeps.a from extension/third_party/build_unix.sh):
rem   c++ -std=c++17 -O2 -pthread -DDIRECT_STANDALONE -DJAM_OPUS -I extension/third_party/opus/include tests/jam_test.cpp extension/direct.cpp extension/direct_audio.cpp libssdeps.a -o /tmp/jam_test && /tmp/jam_test
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
set TP=%~dp0..\extension\third_party
if not exist "%TP%\build\studiosync_deps-x64.lib" call "%TP%\build_windows.cmd" || exit /b 1
set OUT=%TEMP%\ss_jam_test
if not exist "%OUT%" mkdir "%OUT%"
cl /nologo /O2 /EHsc /MT /W3 /DDIRECT_STANDALONE /DJAM_OPUS /D_CRT_SECURE_NO_WARNINGS /I"%TP%\opus\include" /Fo"%OUT%\\" /Fe"%OUT%\jam_test.exe" "%~dp0jam_test.cpp" "%~dp0..\extension\direct.cpp" "%~dp0..\extension\direct_audio.cpp" /link "%TP%\build\studiosync_deps-x64.lib" ws2_32.lib advapi32.lib >"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
"%OUT%\jam_test.exe"
