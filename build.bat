@echo off
rem Nautilus build script (Windows). Requires Odin compiler on PATH or ODIN env var.
setlocal
set ODIN_CMD=odin
if not "%ODIN%"=="" set ODIN_CMD=%ODIN%
rem -o:speed matters: the LUT map loop is ~19x slower unoptimized.
%ODIN_CMD% build src -o:speed -out:nautilus.exe %*
if errorlevel 1 exit /b 1
endlocal
