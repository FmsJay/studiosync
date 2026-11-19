@echo off
rem The direct link's native test (tests/direct_test.cpp with extension/direct.cpp, no REAPER): builds direct_test.exe in %TEMP% and runs it.
rem Arguments go to the test ("connect james-laptop 22 20": TCP connect times only). macOS/Linux:
rem   c++ -std=c++17 -O2 -pthread -DDIRECT_STANDALONE tests/direct_test.cpp extension/direct.cpp extension/direct_audio.cpp -o /tmp/direct_test && /tmp/direct_test
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
set OUT=%TEMP%\ss_direct_test
if not exist "%OUT%" mkdir "%OUT%"
cl /nologo /O2 /EHsc /MT /W3 /DDIRECT_STANDALONE /D_CRT_SECURE_NO_WARNINGS /Fo"%OUT%\\" /Fe"%OUT%\direct_test.exe" "%~dp0direct_test.cpp" "%~dp0..\extension\direct.cpp" "%~dp0..\extension\direct_audio.cpp" /link ws2_32.lib >"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
"%OUT%\direct_test.exe" %*
