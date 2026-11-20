@echo off
rem The connection without Tailscale's test (tests/nat_test.cpp with extension/nat.cpp, libjuice and Monocypher from extension/third_party,
rem no REAPER): builds nat_test.exe in %TEMP% and runs it. Arguments go to the test ("server 3478", "peer <folder> <me> <them> <secret> ...").
rem nat.cpp is in the shipped extension too (stage 1); here without REAPER (NAT_STANDALONE). macOS/Linux:
rem   cc -O2 -c -DJUICE_STATIC -I extension/third_party/libjuice/include/juice extension/third_party/libjuice/src/*.c extension/third_party/monocypher/monocypher.c
rem   cc -O2 -c -DJUICE_STATIC -Dudp_sendto=nat_relay_sendto -I extension/third_party/libjuice/include/juice extension/third_party/libjuice/src/server.c
rem   c++ -std=c++17 -O2 -pthread -DNAT_STANDALONE -DDIRECT_STANDALONE -DJUICE_STATIC tests/nat_test.cpp extension/nat.cpp extension/direct.cpp extension/direct_audio.cpp *.o -o nat_test
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
set OUT=%TEMP%\ss_nat_test
set TP=%~dp0..\extension\third_party
if not exist "%OUT%\c" mkdir "%OUT%\c"
cl /nologo /O2 /MT /W3 /utf-8 /DJUICE_STATIC /D_CRT_SECURE_NO_WARNINGS /I"%TP%\libjuice\include\juice" /c /Fo"%OUT%\c\\" "%TP%\libjuice\src\*.c" "%TP%\monocypher\monocypher.c" >"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
rem (libjuice's server sends through nat.cpp's nat_relay_sendto, the relay's caps: server.c alone, built again over the first one)
cl /nologo /O2 /MT /W3 /utf-8 /DJUICE_STATIC /D_CRT_SECURE_NO_WARNINGS /Dudp_sendto=nat_relay_sendto /I"%TP%\libjuice\include\juice" /c /Fo"%OUT%\c\\" "%TP%\libjuice\src\server.c" >>"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
cl /nologo /O2 /EHsc /MT /W3 /std:c++17 /DNAT_STANDALONE /DDIRECT_STANDALONE /DJUICE_STATIC /D_CRT_SECURE_NO_WARNINGS /Fo"%OUT%\\" /Fe"%OUT%\nat_test.exe" "%~dp0nat_test.cpp" "%~dp0..\extension\nat.cpp" "%~dp0..\extension\direct.cpp" "%~dp0..\extension\direct_audio.cpp" "%OUT%\c\*.obj" /link ws2_32.lib bcrypt.lib advapi32.lib >>"%OUT%\build.txt"
if errorlevel 1 (type "%OUT%\build.txt" & exit /b 1)
"%OUT%\nat_test.exe" %*
