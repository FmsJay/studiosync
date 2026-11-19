@echo off
rem Builds StudioSync Hop for 64-bit Windows with MSVC (Visual Studio 2019 Build Tools, 14.29) and CMake's NMake generator: no other tools.
rem Output: plugin\build\bin\StudioSync Hop.vst3 (a bundle folder) and plugin\build\bin\StudioSync Hop.clap. The build folder isn't committed.
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
cd /d "%~dp0"
cmake -S . -B build -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Release || exit /b 1
cmake --build build || exit /b 1
dir /s /b "build\bin\*.vst3" "build\bin\*.clap"
