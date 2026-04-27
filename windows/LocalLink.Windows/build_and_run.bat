@echo off
setlocal

set "PROJECT_DIR=%~dp0"
set "PUBLISH_DIR=%PROJECT_DIR%publish"
set "INSTALL_DIR=%USERPROFILE%\Desktop\LocalLink"
set "SHORTCUT=%USERPROFILE%\Desktop\LocalLink.lnk"

echo.
echo Building LocalLink...
echo Project: %PROJECT_DIR%
echo Output:  %PUBLISH_DIR%
echo.

where dotnet >nul 2>nul
if errorlevel 1 (
    echo dotnet was not found.
    echo Please install .NET 8 SDK, then run this file again.
    pause
    exit /b 1
)

dotnet publish "%PROJECT_DIR%LocalLink.Windows.csproj" -c Release -p:SelfContained=false -p:RuntimeIdentifier= -o "%PUBLISH_DIR%"
if errorlevel 1 (
    echo.
    echo Build failed. Please check the error messages above.
    pause
    exit /b 1
)

echo.
echo Copying app files to Desktop\LocalLink...
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
xcopy "%PUBLISH_DIR%\*" "%INSTALL_DIR%\" /E /I /Y >nul
if errorlevel 1 (
    echo Copy failed.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%SHORTCUT%'); $s.TargetPath='%INSTALL_DIR%\LocalLink.exe'; $s.WorkingDirectory='%INSTALL_DIR%'; $s.Description='LocalLink'; $s.IconLocation='%INSTALL_DIR%\LocalLink.exe,0'; $s.Save()"

echo.
echo Done.
echo App:      %INSTALL_DIR%\LocalLink.exe
echo Shortcut: %SHORTCUT%
echo.
pause
