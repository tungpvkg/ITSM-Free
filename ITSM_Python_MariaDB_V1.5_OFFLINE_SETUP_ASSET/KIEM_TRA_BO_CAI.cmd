@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================================
echo   KIEM TRA ITSM V1.5 OFFLINE - ASSET
echo   BUILD: V1.5-R2-ASSET-20260907
echo ============================================================
echo.
set ERR=0
if exist "mariadb-12.3.3-winx64.msi" (echo [OK] mariadb-12.3.3-winx64.msi) else (echo [THIEU] mariadb-12.3.3-winx64.msi ^& set ERR=1)
if exist "python-3-13-5-amd64.exe" (echo [OK] python-3-13-5-amd64.exe) else if exist "python-3.13.5-amd64.exe" (echo [OK] python-3.13.5-amd64.exe) else (echo [THIEU] python-3-13-5-amd64.exe ^& set ERR=1)
if exist "installer\app_payload.zip" (echo [OK] installer\app_payload.zip) else (echo [THIEU] app_payload.zip ^& set ERR=1)
if exist "installer\python_site_packages_cp313_win_amd64.zip" (echo [OK] Python libraries offline) else (echo [THIEU] Python libraries offline ^& set ERR=1)
if exist "installer\verify_runtime.py" (echo [OK] verify_runtime.py) else (echo [THIEU] verify_runtime.py ^& set ERR=1)
if exist "installer\bootstrap_clean_db.py" (echo [OK] bootstrap_clean_db.py) else (echo [THIEU] bootstrap_clean_db.py ^& set ERR=1)
if exist "installer\create_first_admin.py" (echo [OK] create_first_admin.py) else (echo [THIEU] create_first_admin.py ^& set ERR=1)
if exist "BUILD_ID.txt" (echo [OK] BUILD_ID.txt) else (echo [THIEU] BUILD_ID.txt ^& set ERR=1)
echo.
if "%ERR%"=="0" (echo BO CAI DU FILE. CO THE CHAY SETUP_ITSM.cmd) else (echo HAY COPY DU FILE CON THIEU VAO CUNG THU MUC.)
echo.
pause
exit /b %ERR%
