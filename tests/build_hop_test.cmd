@echo off
rem StudioSync Hop's native test (tests/hop_test.cpp with extension/hop.cpp and plugin/hop_core.h, no REAPER): builds hop_test.exe in %TEMP% and runs it.
rem macOS/Linux: c++ -std=c++17 -O2 -pthread -DHOP_STANDALONE tests/hop_test.cpp extension/hop.cpp -o /tmp/hop_test && /tmp/hop_test
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
set OUT=%TEMP%\ss_hop_test
if not exist "%OUT%" mkdir "%OUT%"
cl /nologo /O2 /EHsc /MT /W3 /DHOP_STANDALONE /D_CRT_SECURE_NO_WARNINGS /Fo"%OUT%\\" /Fe"%OUT%\hop_test.exe" "%~dp0hop_test.cpp" "%~dp0..\extension\hop.cpp" >"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
"%OUT%\hop_test.exe" %*
