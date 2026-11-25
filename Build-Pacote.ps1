<#
  Build-Pacote.ps1 - gera o pacote de instalacao do Scry: dist\Scry-vX.Y.Z.zip

    powershell -ExecutionPolicy Bypass -File .\Build-Pacote.ps1

  O zip contem:
    INSTALAR.cmd   dois cliques para instalar ou atualizar
    README.md      o que e e como instalar
    NOC\           o programa (sem nenhum dado de producao)

  Funciona no Windows PowerShell 5.1 e no PowerShell 7 (inclusive no GitHub Actions).
  Arquivo em ASCII de proposito.
#>
param([string]$OutDir = (Join-Path $PSScriptRoot 'dist'))
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

$mgr = Join-Path (Join-Path $here 'NOC') (Join-Path 'Manager' 'NocManager.ps1')
$m = [regex]::Match([IO.File]::ReadAllText($mgr), "\`$Version\s*=\s*'([^']+)'")
if (-not $m.Success) { throw "Nao achei `$Version em $mgr" }
$version = $m.Groups[1].Value

# dados de producao: nunca vao para o pacote (mesma lista do .gitignore)
$excluir = @(
  'paineis.json', 'grafana.cred', 'grafana.json', 'layout.json', 'pausado.json', 'run-hidden.vbs',
  'deploy.log', 'start-wall.log', 'users.json', 'audit.log', 'manutencao-estado.json', 'setup.json'
)
$excluirPastas = @('profiles', 'backups')

$name  = "Scry-v$version"
$stage = Join-Path $OutDir $name
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Copy-Item (Join-Path $here 'INSTALAR.cmd') $stage
Copy-Item (Join-Path $here 'README.md') $stage
$nocSrc = Join-Path $here 'NOC'
$count = 0
foreach ($f in Get-ChildItem $nocSrc -Recurse -File) {
  $rel = $f.FullName.Substring($nocSrc.Length + 1)
  $parts = $rel -split '[\\/]'
  if ($excluir -contains $f.Name) { continue }
  if ($f.Name -like 'diag.log*' -or $f.Name -like '*.bak*' -or $f.Name -like '*.tmp') { continue }
  if (@($parts | Where-Object { $excluirPastas -contains $_ }).Count) { continue }
  $dst = Join-Path (Join-Path $stage 'NOC') $rel
  New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
  Copy-Item -LiteralPath $f.FullName -Destination $dst
  $count++
}

$zip = Join-Path $OutDir "$name.zip"
if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item -LiteralPath $stage -Recurse -Force
Write-Host "Pacote gerado: $zip ($count arquivos em NOC\, versao $version)" -ForegroundColor Green
