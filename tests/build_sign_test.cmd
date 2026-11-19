@echo off
rem Signed updates' native test (tests/sign_test.cpp with extension/sign.cpp, no REAPER): builds sign_test.exe in %TEMP% and runs it, then
rem checks a copy signed by tools/sign_release.py with it (tests/sign_cross.py). macOS/Linux:
rem   c++ -std=c++17 -O2 -pthread -DSIGN_STANDALONE -DDIRECT_STANDALONE tests/sign_test.cpp extension/sign.cpp extension/direct.cpp extension/direct_audio.cpp -o /tmp/sign_test && /tmp/sign_test && python3 tests/sign_cross.py /tmp/sign_test
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
set OUT=%TEMP%\ss_sign_test
if not exist "%OUT%" mkdir "%OUT%"
cl /nologo /O2 /EHsc /MT /W3 /DSIGN_STANDALONE /DDIRECT_STANDALONE /D_CRT_SECURE_NO_WARNINGS /Fo"%OUT%\\" /Fe"%OUT%\sign_test.exe" "%~dp0sign_test.cpp" "%~dp0..\extension\sign.cpp" "%~dp0..\extension\direct.cpp" "%~dp0..\extension\direct_audio.cpp" /link ws2_32.lib >"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
"%OUT%\sign_test.exe" || exit /b 1
python "%~dp0sign_cross.py" "%OUT%\sign_test.exe"
