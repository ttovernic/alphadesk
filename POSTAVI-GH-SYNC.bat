@echo off
title Alpha Desk — GitHub Sync Setup
color 0A

:: Procitaj token iz Windows environment varijable
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "[System.Environment]::GetEnvironmentVariable('ALPHADESK_GH_TOKEN','User')"`) do set GH_TOKEN=%%T

if "%GH_TOKEN%"=="" (
    echo [GRESKA] ALPHADESK_GH_TOKEN nije postavljen!
    echo Postavi ga u: System Properties - Environment Variables - User variables
    pause
    exit /b 1
)

echo [OK] Token pronadjen. Otvaram Alpha Desk i postavljam GitHub sync...
echo.

:: Otvori app s tokenom u URL-u (spremi se u localStorage, URL se odmah ocisti)
start "" "https://pajdo2.github.io/alphadesk/?ghtoken=%GH_TOKEN%"

echo [OK] Browser otvoren. Token ce se automatski spremiti.
echo     Zatvori ovaj prozor.
echo.
timeout /t 5 >nul
