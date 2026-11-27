@echo off
rem Remote control's native test (tests/remotectl_test.cpp: extension/remotectl.h's pure parts, no REAPER): builds remotectl_test.exe in
rem %TEMP% and runs it. macOS/Linux: c++ -std=c++17 -O2 tests/remotectl_test.cpp -o /tmp/remotectl_test && /tmp/remotectl_test
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
set OUT=%TEMP%\ss_remotectl_test
if not exist "%OUT%" mkdir "%OUT%"
cl /nologo /O2 /EHsc /MT /W3 /std:c++17 /D_CRT_SECURE_NO_WARNINGS /Fo"%OUT%\\" /Fe"%OUT%\remotectl_test.exe" "%~dp0remotectl_test.cpp" >"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
"%OUT%\remotectl_test.exe" %*
