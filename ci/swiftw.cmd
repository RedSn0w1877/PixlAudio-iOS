@echo off
rem Runs the Windows Swift toolchain with the environment it needs (SDKROOT, Swift bin, MSVC linker).
rem Usage: swiftw.cmd test --package-path Packages\PixlCore    (any swift subcommand/args)
set "SDKROOT=C:\Users\Hoa\AppData\Local\Programs\Swift\Platforms\6.4.0\Windows.platform\Developer\SDKs\Windows.sdk\"
set "PATH=C:\Users\Hoa\AppData\Local\Programs\Swift\Toolchains\6.4.0+Asserts\usr\bin;C:\Users\Hoa\AppData\Local\Programs\Swift\Runtimes\6.4.0\usr\bin;C:\Program Files (x86)\Microsoft Visual Studio\Installer;%PATH%"
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
swift %*
