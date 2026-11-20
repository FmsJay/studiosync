@echo off
rem Live audio over the connection without Tailscale (tests/nat_audio_test.cpp with extension/rtaudio.cpp and extension/nat.cpp, no REAPER):
rem builds nat_audio_test.exe in %TEMP% and runs it. macOS/Linux: the CI's line in .github/workflows/extension.yml.
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
set TP=%~dp0..\extension\third_party
if not exist "%TP%\build\studiosync_deps-x64.lib" call "%TP%\build_windows.cmd" || exit /b 1
if not exist "%TP%\build\studiosync_nat3-x64.lib" call "%TP%\build_windows.cmd" || exit /b 1
set OUT=%TEMP%\ss_nat_audio_test
if not exist "%OUT%" mkdir "%OUT%"
cl /nologo /O2 /EHsc /MT /W3 /std:c++17 /DRTAUDIO_STANDALONE /DNAT_STANDALONE /DDIRECT_STANDALONE /DJUICE_STATIC /D_CRT_SECURE_NO_WARNINGS /I"%TP%\aoo" /I"%TP%\aoo\include" /I"%TP%\opus\include" /Fo"%OUT%\\" /Fe"%OUT%\nat_audio_test.exe" "%~dp0nat_audio_test.cpp" "%~dp0..\extension\rtaudio.cpp" "%~dp0..\extension\nat.cpp" "%~dp0..\extension\direct.cpp" "%~dp0..\extension\direct_audio.cpp" /link "%TP%\build\studiosync_deps-x64.lib" "%TP%\build\studiosync_nat3-x64.lib" ws2_32.lib advapi32.lib bcrypt.lib >"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
"%OUT%\nat_audio_test.exe" %*
