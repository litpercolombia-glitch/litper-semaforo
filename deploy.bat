@echo off
setlocal
set REPO=C:\Users\boost\Downloads\litper-sem
set DL=C:\Users\boost\Downloads

echo ===================================
echo  LitperPro - Copiando archivos HTML
echo ===================================

REM Copiar el semaforo principal (el mas reciente)
copy "%DL%\litper-transportadoras-FINAL (2).html" "%REPO%\index.html"
if errorlevel 1 (
    copy "%DL%\litper-transportadoras-FINAL.html" "%REPO%\index.html"
)

REM Copiar otras paginas si existen
if exist "%DL%\landing.html" copy "%DL%\landing.html" "%REPO%\landing.html"
if exist "%DL%\checkout.html" copy "%DL%\checkout.html" "%REPO%\checkout.html"
if exist "%DL%\login.html" copy "%DL%\login.html" "%REPO%\login.html"
if exist "%DL%\pricing.html" copy "%DL%\pricing.html" "%REPO%\pricing.html"
if exist "%DL%\profile.html" copy "%DL%\profile.html" "%REPO%\profile.html"

echo.
echo Archivos copiados:
dir "%REPO%" /b

echo.
echo ===================================
echo  Haciendo git commit y push...
echo ===================================
cd /d "%REPO%"

git init
git config user.email "litpercolombia@gmail.com"
git config user.name "Litper Colombia"

git remote remove origin 2>nul
git remote add origin https://github.com/litpercolombia-glitch/litper-semaforo.git

git add .
git status
git commit -m "feat: LitperPro Semaforo v2 - Predictor IA + Score Ciudades + Modo Jimmy + Benchmark"
git branch -M main
git push -u origin main --force

echo.
echo ===================================
if errorlevel 1 (
    echo ERROR en el push. Revisa la autenticacion.
) else (
    echo EXITO! Repo subido a GitHub.
    echo URL: https://github.com/litpercolombia-glitch/litper-semaforo
)
echo ===================================
pause
