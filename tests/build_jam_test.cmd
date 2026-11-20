@echo off
rem The Jam capture's native test (tests/jam_test.cpp with extension/direct_audio.cpp, no REAPER): builds jam_test.exe in %TEMP% and runs it.
rem macOS/Linux: c++ -std=c++17 -O2 -pthread -DDIRECT_STANDALONE tests/jam_test.cpp extension/direct.cpp extension/direct_audio.cpp -o /tmp/jam_test && /tmp/jam_test
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
set OUT=%TEMP%\ss_jam_test
if not exist "%OUT%" mkdir "%OUT%"
cl /nologo /O2 /EHsc /MT /W3 /DDIRECT_STANDALONE /D_CRT_SECURE_NO_WARNINGS /Fo"%OUT%\\" /Fe"%OUT%\jam_test.exe" "%~dp0jam_test.cpp" "%~dp0..\extension\direct.cpp" "%~dp0..\extension\direct_audio.cpp" /link ws2_32.lib >"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
"%OUT%\jam_test.exe"
