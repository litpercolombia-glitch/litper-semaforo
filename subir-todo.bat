@echo off
set REPO=C:\Users\boost\Downloads\litper-sem
set DL=C:\Users\boost\Downloads

echo Copiando 5 paginas HTML...
copy "%DL%\landing.html" "%REPO%\landing.html"
copy "%DL%\checkout.html" "%REPO%\checkout.html"
copy "%DL%\login.html" "%REPO%\login.html"
copy "%DL%\pricing.html" "%REPO%\pricing.html"
copy "%DL%\profile.html" "%REPO%\profile.html"

echo.
echo === Archivos en el repo ===
dir "%REPO%" /b

cd /d "%REPO%"
git add .
git commit -m "feat: agregar 6 paginas completas - landing checkout login pricing profile semaforo"
git push origin main --force
echo PUSH_OK=%errorlevel%
