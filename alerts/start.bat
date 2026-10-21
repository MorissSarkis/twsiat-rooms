@echo off
REM Pivot Alerts - keeps running and restarts if it ever stops
cd /d "%~dp0"
:loop
python main.py
echo Restarting in 10 seconds...
timeout /t 10 /nobreak >nul
goto loop
