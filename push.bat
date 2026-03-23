@echo off
setlocal
set REPO=C:\Users\boost\Downloads\litper-sem
set DL=C:\Users\boost\Downloads

echo Copiando HTML principal...
copy "%DL%\litper-transportadoras-FINAL (2).html" "%REPO%\index.html"
if errorlevel 1 copy "%DL%\litper-transportadoras-FINAL.html" "%REPO%\index.html"

echo Copiando otras paginas...
if exist "%DL%\landing.html" (copy "%DL%\landing.html" "%REPO%\landing.html") else echo landing.html NO encontrado
if exist "%DL%\checkout.html" (copy "%DL%\checkout.html" "%REPO%\checkout.html") else echo checkout.html NO encontrado
if exist "%DL%\login.html" (copy "%DL%\login.html" "%REPO%\login.html") else echo login.html NO encontrado
if exist "%DL%\pricing.html" (copy "%DL%\pricing.html" "%REPO%\pricing.html") else echo pricing.html NO encontrado
if exist "%DL%\profile.html" (copy "%DL%\profile.html" "%REPO%\profile.html") else echo profile.html NO encontrado

echo.
echo === ARCHIVOS EN EL REPO ===
dir "%REPO%" /b

echo.
echo === HACIENDO PUSH A GITHUB ===
cd /d "%REPO%"
git add .
git status
git commit -m "feat: LitperPro Semaforo v2 completo - 6 paginas"
git branch -M main
git push -u origin main --force
echo EXIT_CODE=%errorlevel%
