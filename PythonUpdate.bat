@echo off
REM ============================================================================
REM BuildAll.bat - rebuild BOTH OmniWatch exes from source, in sequence.
REM
REM Merges PythonUpdate.bat (OmniWatch.exe overlay) and RoutingGuiUpdate.bat
REM (omniwatch_routing_gui.exe) into one run so you don't have to launch two
REM scripts after editing the Python sources.
REM
REM Order:
REM   PART A - OmniWatch.exe       (overlay; built with embedded icon)
REM   PART B - omniwatch_routing_gui.exe  (routing config GUI; no icon)
REM
REM If PART A fails the script stops and PART B is NOT attempted, so a broken
REM overlay build never hides behind a successful GUI build. Each part keeps
REM the original per-step error handling; labels are namespaced A_/B_ so the
REM two halves don't collide.
REM
REM Run this any time OmniWatch.py or omniwatch_routing_gui.py changes. The
REM lua addon does NOT need rebuilding -- Windower interprets it at load time.
REM
REM Requires icons\ui\OmniWatch.ico for PART A (multi-resolution Windows .ico).
REM ============================================================================

setlocal
set "OW_DIR=C:\Program Files (x86)\SquareEnix\SquareEnix\Windower\addons\OmniWatch"
set "ICON_FILE=icons\ui\OmniWatch.ico"
set "GUI_SOURCE=omniwatch_routing_gui.py"
set "GUI_EXE=omniwatch_routing_gui"

cd /d "%OW_DIR%"
if errorlevel 1 goto :cd_failed

echo.
echo ############################################################################
echo ##  PART A: Building OmniWatch.exe (overlay)
echo ############################################################################

echo.
echo === A Step 0: Verify icon exists ===
if not exist "%ICON_FILE%" goto :a_no_icon
echo   Icon found: %ICON_FILE%

echo.
echo === A Step 1/4: Closing any running OmniWatch process ===
taskkill /F /IM OmniWatch.exe >nul 2>&1
taskkill /F /IM omniwatch.exe >nul 2>&1
timeout /t 1 /nobreak >nul

echo.
echo === A Step 2/4: Cleaning previous build artifacts ===
if exist "build"           echo   Removing build\
if exist "build"           rmdir /s /q "build"
if exist "dist"            echo   Removing dist\
if exist "dist"            rmdir /s /q "dist"
if exist "omniwatch.spec"  echo   Removing omniwatch.spec
if exist "omniwatch.spec"  del /q "omniwatch.spec"
REM Also remove the previous root .exe so a stale build doesn't sit
REM around if PyInstaller fails midway through this run.
if exist "OmniWatch.exe"   echo   Removing OmniWatch.exe
if exist "OmniWatch.exe"   del /q "OmniWatch.exe"
if exist "omniwatch.exe"   del /q "omniwatch.exe"

echo.
echo === A Step 3/4: Running PyInstaller (with icon) ===
REM --noconsole hides the black cmd-style window that would otherwise
REM open alongside the overlay. All print() output now goes to a
REM session log file under %APPDATA%\OmniWatch\logs\ instead. See
REM _open_session_log() in OmniWatch.py for the rotation policy.
py -m PyInstaller --onefile --noconsole --icon "%ICON_FILE%" omniwatch.py
if errorlevel 1 goto :a_build_failed

echo.
echo === A Step 4/4: Moving exe up to addon root ===
REM PyInstaller dumps the .exe into dist\. For a clean shippable
REM layout we want the .exe sitting at the addon root next to
REM OmniWatch.lua, icons\, and data\ -- so end users don't have
REM to navigate into a dist\ folder. Copy + clean up.
if not exist "dist\omniwatch.exe" goto :a_no_built_exe
echo   Copying dist\omniwatch.exe -^> OmniWatch.exe
REM /Y = silent overwrite. Note we rename to capital-O OmniWatch.exe
REM to match the visual branding (lua addon, icon name, etc.).
copy /Y "dist\omniwatch.exe" "OmniWatch.exe" >nul
if errorlevel 1 goto :a_copy_failed
echo   Removing dist\ and build\ (no longer needed)
if exist "dist"  rmdir /s /q "dist"
if exist "build" rmdir /s /q "build"
if exist "omniwatch.spec" del /q "omniwatch.spec"

echo.
echo === PART A complete. Output: %OW_DIR%\OmniWatch.exe ===

echo.
echo ############################################################################
echo ##  PART B: Building %GUI_EXE%.exe (routing config GUI)
echo ############################################################################

echo.
echo === B Step 0: Verify source exists ===
if not exist "%GUI_SOURCE%" goto :b_no_source
echo   Source found: %GUI_SOURCE%

echo.
echo === B Step 1/4: Closing any running %GUI_EXE% process ===
taskkill /F /IM %GUI_EXE%.exe >nul 2>&1
timeout /t 1 /nobreak >nul

echo.
echo === B Step 2/4: Cleaning previous build artifacts ===
if exist "build"           echo   Removing build\
if exist "build"           rmdir /s /q "build"
if exist "dist"            echo   Removing dist\
if exist "dist"            rmdir /s /q "dist"
if exist "%GUI_EXE%.spec"  echo   Removing %GUI_EXE%.spec
if exist "%GUI_EXE%.spec"  del /q "%GUI_EXE%.spec"
REM Also remove the previous root .exe so a stale build doesn't sit
REM around if PyInstaller fails midway through this run.
if exist "%GUI_EXE%.exe"   echo   Removing %GUI_EXE%.exe
if exist "%GUI_EXE%.exe"   del /q "%GUI_EXE%.exe"

echo.
echo === B Step 3/4: Running PyInstaller ===
REM --noconsole hides the cmd window that would otherwise open
REM alongside the GUI. The GUI is a self-contained pygame window
REM and has no useful console output to show.
py -m PyInstaller --onefile --noconsole %GUI_SOURCE%
if errorlevel 1 goto :b_build_failed

echo.
echo === B Step 4/4: Moving exe up to addon root ===
if not exist "dist\%GUI_EXE%.exe" goto :b_no_built_exe
echo   Copying dist\%GUI_EXE%.exe -^> %GUI_EXE%.exe
copy /Y "dist\%GUI_EXE%.exe" "%GUI_EXE%.exe" >nul
if errorlevel 1 goto :b_copy_failed
echo   Removing dist\ and build\ (no longer needed)
if exist "dist"            rmdir /s /q "dist"
if exist "build"           rmdir /s /q "build"
if exist "%GUI_EXE%.spec"  del /q "%GUI_EXE%.spec"

echo.
echo === PART B complete. Output: %OW_DIR%\%GUI_EXE%.exe ===

echo.
echo ############################################################################
echo ##  ALL BUILDS COMPLETE
echo ##    %OW_DIR%\OmniWatch.exe
echo ##    %OW_DIR%\%GUI_EXE%.exe
echo ############################################################################
echo === Note: Windows may show a cached old icon for OmniWatch.exe.        ===
echo ===   To refresh:  ie4uinit.exe -show                                  ===
echo ===   Or rename the .exe and rename it back.                           ===
echo === Launch the routing GUI via the Routing button in the chat header.  ===
pause
endlocal
exit /b 0

REM ---------------------------------------------------------------------------
REM PART A error handlers
REM ---------------------------------------------------------------------------
:a_no_icon
echo [BuildAll/A] %ICON_FILE% not found.
echo              Place a multi-resolution .ico file there before building.
echo              ImageMagick:  magick icons\ui\OmniWatch.png -define icon:auto-resize=16,32,48,256 icons\ui\OmniWatch.ico
echo              Or use https://convertio.co/png-ico/
pause
endlocal
exit /b 1

:a_build_failed
echo.
echo [BuildAll/A] PyInstaller reported an error building OmniWatch.exe.
echo              See output above. PART B was NOT attempted.
pause
endlocal
exit /b 1

:a_no_built_exe
echo.
echo [BuildAll/A] PyInstaller said it succeeded but dist\omniwatch.exe
echo              doesn't exist. Something went wrong with the build.
echo              PART B was NOT attempted.
pause
endlocal
exit /b 1

:a_copy_failed
echo.
echo [BuildAll/A] Could not copy dist\omniwatch.exe to OmniWatch.exe.
echo              Likely cause: a running OmniWatch.exe held the file.
echo              Close it via Task Manager and re-run. PART B was NOT attempted.
pause
endlocal
exit /b 1

REM ---------------------------------------------------------------------------
REM PART B error handlers
REM ---------------------------------------------------------------------------
:b_no_source
echo [BuildAll/B] %GUI_SOURCE% not found in %OW_DIR%.
echo              Place %GUI_SOURCE% there before building.
echo              NOTE: OmniWatch.exe (PART A) built fine and is in place.
pause
endlocal
exit /b 1

:b_build_failed
echo.
echo [BuildAll/B] PyInstaller reported an error building %GUI_EXE%.exe.
echo              See output above.
echo              NOTE: OmniWatch.exe (PART A) built fine and is in place.
pause
endlocal
exit /b 1

:b_no_built_exe
echo.
echo [BuildAll/B] PyInstaller said it succeeded but
echo              dist\%GUI_EXE%.exe doesn't exist. Something went wrong.
echo              NOTE: OmniWatch.exe (PART A) built fine and is in place.
pause
endlocal
exit /b 1

:b_copy_failed
echo.
echo [BuildAll/B] Could not copy dist\%GUI_EXE%.exe to %GUI_EXE%.exe.
echo              Likely cause: a running %GUI_EXE%.exe held the file.
echo              Close it via Task Manager and re-run.
echo              NOTE: OmniWatch.exe (PART A) built fine and is in place.
pause
endlocal
exit /b 1

REM ---------------------------------------------------------------------------
REM Shared error handler
REM ---------------------------------------------------------------------------
:cd_failed
echo [BuildAll] Could not cd to "%OW_DIR%"
pause
endlocal
exit /b 1