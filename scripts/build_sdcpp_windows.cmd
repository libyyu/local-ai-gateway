@echo off
rem ============================================================
rem  SDCPP Windows 编译脚本（由 install.sh 调用，也可手动运行）
rem  用法: build_sdcpp_windows.cmd <源码目录> <CUDA目录> <架构>
rem  规避三个已知坑:
rem   1) CUDA 13 的 MSBuild .targets 在 VS2026 下找不到 Toolkit -> 用 Ninja
rem   2) nvcc 找不到 VS2026 的 MSVC -> NVCC_CCBIN 显式指定
rem   3) 新版 sd.cpp 选项名: CMAKE_CUDA_ARCHITECTURES / SD_SERVER_BUILD_FRONTEND
rem ============================================================
setlocal
set "SRC=%~1"
set "CUDA_DIR=%~2"
set "CUDA_ARCH=%~3"
if "%SRC%"=="" echo [error] usage: build_sdcpp_windows.cmd src_dir cuda_dir arch & exit /b 1
if "%CUDA_ARCH%"=="" set "CUDA_ARCH=89"

rem ---- 定位 Visual Studio（C++ 工具集）----
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" echo [error] vswhere not found. Install VS with C++ workload. & exit /b 1
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSROOT=%%i"
if "%VSROOT%"=="" echo [error] Visual Studio with C++ workload not found. & exit /b 1

set "VSCMAKE=%VSROOT%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
set "VCVARS=%VSROOT%\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VSCMAKE%" echo [error] VS bundled CMake not found: %VSCMAKE% & exit /b 1
if not exist "%VCVARS%" echo [error] vcvars64.bat not found: %VCVARS% & exit /b 1

rem ---- 最新 MSVC x64 工具集（nvcc 的 host 编译器）----
set "MSVCVER="
for /f "usebackq delims=" %%i in (`dir /b /ad /on "%VSROOT%\VC\Tools\MSVC"`) do set "MSVCVER=%%i"
set "NVCC_CCBIN=%VSROOT%\VC\Tools\MSVC\%MSVCVER%\bin\HostX64\x64"
if not exist "%NVCC_CCBIN%\cl.exe" echo [error] cl.exe not found under %NVCC_CCBIN% & exit /b 1

echo [info] VS root : %VSROOT%
echo [info] MSVC    : %MSVCVER%
echo [info] CUDA    : %CUDA_DIR%
echo [info] CMake   : %VSCMAKE%

call "%VCVARS%" >nul 2>&1
set "CUDA_PATH=%CUDA_DIR%"
set "PATH=%CUDA_DIR%\bin;%PATH%"

"%VSCMAKE%" -G Ninja -S "%SRC%" -B "%SRC%\build" -DSD_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=%CUDA_ARCH% -DSD_SERVER_BUILD_FRONTEND=OFF -DCMAKE_BUILD_TYPE=Release -DCUDAToolkit_ROOT="%CUDA_DIR%"
if errorlevel 1 exit /b 1
"%VSCMAKE%" --build "%SRC%\build" --parallel
exit /b %ERRORLEVEL%
