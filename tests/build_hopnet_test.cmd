@echo off
rem The Hop's network leg's native test (tests/hopnet_test.cpp with extension/hopnet.cpp and plugin/hop_core.h, no REAPER): builds
rem hopnet_test.exe in %TEMP% and runs it. macOS/Linux: the CI's lines (.github/workflows/extension.yml).
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
set OUT=%TEMP%\ss_hopnet_test
if not exist "%OUT%" mkdir "%OUT%"
cl /nologo /O2 /EHsc /MT /W3 /std:c++17 /DHOPNET_STANDALONE /DDIRECT_STANDALONE /D_CRT_SECURE_NO_WARNINGS /Fo"%OUT%\\" /Fe"%OUT%\hopnet_test.exe" "%~dp0hopnet_test.cpp" "%~dp0..\extension\hopnet.cpp" "%~dp0..\extension\direct.cpp" "%~dp0..\extension\direct_audio.cpp" /link ws2_32.lib advapi32.lib >"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
"%OUT%\hopnet_test.exe" %*
