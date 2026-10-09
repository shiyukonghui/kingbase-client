@echo off
rem Build/run helper for the native target.
rem vcvars64.bat is broken in this VS 2022 install, so set the toolchain env by hand.
setlocal
set "MSVC=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207"
set "SDK=C:\Program Files (x86)\Windows Kits\10"
set "VCVER=10.0.26100.0"
if not exist "%MSVC%\include" for /d %%d in ("C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*") do if exist "%%d\include" set "MSVC=%%d"
if not exist "%SDK%\Include\%VCVER%" for /d %%d in ("%SDK%\Include\*") do set "VCVER=%%~nxd"
set "INCLUDE=%MSVC%\include;%SDK%\Include\%VCVER%\ucrt;%SDK%\Include\%VCVER%\shared;%SDK%\Include\%VCVER%\um"
set "LIB=%MSVC%\lib\x64;%SDK%\Lib\%VCVER%\ucrt\x64;%SDK%\Lib\%VCVER%\um\x64"
set "PATH=%MSVC%\bin\Hostx64\x64;%PATH%"
moon %*
endlocal
