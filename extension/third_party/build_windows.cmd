@echo off
rem Builds the real-time audio libraries (AOO with Opus, vendored here: README.md) once into build\studiosync_deps-x64.lib, which
rem extension\build_windows.cmd links into reaper_studiosync-x64.dll (static: nothing extra to install). Delete build\ to rebuild them.
rem The flags (AOO_*, OPUS_*) must match the #defines at the top of extension\rtaudio.cpp: AOO's headers read them too. (James, rt)
setlocal enabledelayedexpansion
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
cd /d "%~dp0"
if not exist build\opus mkdir build\opus
if not exist build\aoo mkdir build\aoo
set OPUS=
for /f "usebackq delims=" %%f in ("opus\sources.txt") do set "OPUS=!OPUS! opus\%%f"
set AOO=
for /f "usebackq delims=" %%f in ("aoo\sources.txt") do set "AOO=!AOO! aoo\%%f"
rem (Opus in plain C: no SSE/NEON paths, so one build runs on every x64 CPU)
cl /nologo /c /MP /O2 /MT /GS- /W0 /DNDEBUG /DOPUS_BUILD /DUSE_ALLOCA /D_CRT_SECURE_NO_WARNINGS /Iopus\include /Iopus\celt /Iopus\silk /Iopus\silk\float /Fobuild\opus\ %OPUS% >build\opus.txt
if errorlevel 1 (type build\opus.txt & exit /b 1)
cl /nologo /c /MP /O2 /MT /GS- /W0 /EHsc /std:c++17 /DNDEBUG /DAOO_BUILD /DAOO_NET=0 /DAOO_USE_OPUS=1 /DAOO_USE_IPV6=0 /DAOO_SAMPLE_SIZE=32 /DAOO_MAX_PACKET_SIZE=4096 /DAOO_LOG_LEVEL=kAooLogLevelWarning /DAOO_HAVE_ATOMIC_DOUBLE /DAOO_HAVE_ATOMIC_INT64 /DOSC_HOST_LITTLE_ENDIAN /DNOMINMAX /D_CRT_SECURE_NO_WARNINGS /Iaoo /Iaoo\include /Iaoo\aoo /Iaoo\deps\oscpack /Iopus\include /Fobuild\aoo\ %AOO% >build\aoo.txt
if errorlevel 1 (type build\aoo.txt & exit /b 1)
lib /nologo /OUT:build\studiosync_deps-x64.lib build\opus\*.obj build\aoo\*.obj
