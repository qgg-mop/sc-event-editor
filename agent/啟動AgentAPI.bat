@echo off
chcp 65001 >nul
title Style Agent API (port 8090)
echo.
echo   ShinyColors 風格 Agent API
echo   http://127.0.0.1:8090/docs
echo.
"D:\irodori\src\Irodori-TTS-main\.venv\Scripts\python.exe" "D:\事件編輯器\agent\style_agent_api.py" --port 8090
pause