# file: push_to_github.ps1
param(
  [Parameter(Mandatory=$true)][string]$RepoUrl,    # ex: https://github.com/monuser/monrepo.git
  [string]$Branch = "main"
)

$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSCommandPath
Set-Location $root

function WriteUtf8NoBom([string]$Path,[string]$Content){
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($Path,$Content,$enc)
}

# 1) Préchecks
git --version | Out-Null
if(-not (Test-Path ".git")){ git init | Out-Null }

# 2) .gitignore (évite d’envoyer node_modules, caches, .env…)
$gi = ".gitignore"
$want = @"
# General
.DS_Store
Thumbs.db
*.log
.env
.env.*
*.env

# Python
__pycache__/
*.py[cod]
*.pyo
*.pyd
.pytest_cache/
.mypy_cache/
.venv/
venv/
*.sqlite
*.db

# Node / Frontend
node_modules/
frontend/node_modules/
frontend/dist/

# Build artifacts
dist/
build/

# IDE
.vscode/
.idea/

# Docker / runtime
.docker/
*.pid
# volumes locales éventuelles
data/
"@
if(!(Test-Path $gi)){
  WriteUtf8NoBom $gi $want
}else{
  $cur = Get-Content $gi -Raw
  $append = ""
  foreach($line in ($want -split "`n")){
    if($line.Trim() -ne "" -and $cur -notmatch [regex]::Escape($line.Trim())){
      $append += ($line + "`n")
    }
  }
  if($append){ Add-Content -Path $gi -Value $append; Write-Host "[.gitignore] mis à jour" }
}

# 3) Config Git minimale (pour éviter les commits anonymes)
$uname = (git config user.name 2>$null)
$uemail = (git config user.email 2>$null)
if(!$uname){ git config user.name "CapTech User" }
if(!$uemail){ git config user.email "captech.user@example.com" }

# 4) Ajout + commit
git add -A
# Si aucun commit existe encore → commit initial
$hasCommit = $false
try{ git rev-parse --verify HEAD | Out-Null; $hasCommit = $true }catch{}
if($hasCommit){
  # Commit only if there are staged changes
  $diff = git diff --cached --name-only
  if($diff){ git commit -m "chore: sync local changes" | Out-Null }
}else{
  git commit -m "chore: initial import (backend FastAPI + frontend Vite + Docker)" | Out-Null
}

# 5) Branch par défaut
git branch -M $Branch

# 6) Remote origin
$existing = ""
try{ $existing = (git remote get-url origin) }catch{}
if($existing){
  if($existing -ne $RepoUrl){
    git remote set-url origin $RepoUrl
  }
}else{
  git remote add origin $RepoUrl
}

# 7) Push
# Pourquoi: ne pas stocker de token en clair dans .git/config
# - Si $env:GITHUB_USER et $env:GITHUB_TOKEN sont définis, on pousse via une push-url éphémère.
# - Sinon, Git Credential Manager affichera une fenêtre/ouvre le navigateur pour s’authentifier.
$usingToken = $false
if($env:GITHUB_USER -and $env:GITHUB_TOKEN){
  $usingToken = $true
  # Ne pas persister la push-url avec token: on la met juste pour cette commande via -c
  git -c credential.helper= -c "url.https://$($env:GITHUB_USER):$($env:GITHUB_TOKEN)@github.com/.insteadOf=https://github.com/" push -u origin $Branch
}else{
  git push -u origin $Branch
}

Write-Host "`n✅ Push terminé sur '$Branch' -> $RepoUrl"
if($usingToken){
  Write-Host "Note: token utilisé via config éphémère (non stocké)."
}else{
  Write-Host "Astuce: tu peux définir GITHUB_USER/GITHUB_TOKEN pour un push silencieux (PAT: 'repo')."
}