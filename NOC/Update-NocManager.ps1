<#
  Update-NocManager.ps1 - atualiza o Scry (gerenciador do video wall) sem rodar o instalador inteiro.

  Rode como ADMINISTRADOR a partir da pasta do pacote NOVO (nao de C:\NOC):
    powershell -ExecutionPolicy Bypass -File <pacote>\NOC\Update-NocManager.ps1

  O que faz:
    1. Faz backup do codigo e dos dados atuais em C:\NOC\Manager\backups\<data>-v<versao>.zip
       (pasta acessivel so para SYSTEM e Administradores; guarda os 10 ultimos)
    2. Copia scripts e interface. NUNCA sobrescreve paineis.json, users.json, audit.log nem perfis.
    3. Reinicia a tarefa NOC-Manager e confere se a versao nova respondeu na porta.

  Opcoes:
    -AplicarParede   roda a tarefa NOC-VideoWall em seguida (aplica mudancas do Start-Wall.ps1 agora;
                     sem isso elas valem na proxima rodada de 5 min). Nao fecha janelas abertas.
    -Reverter        restaura o codigo do backup mais recente (dados nao sao tocados) e reinicia.
#>
param(
  [string]$Root = "C:\NOC",
  [int]$Port = 0,            # 0 = descobre pela tarefa NOC-Manager (-Prefix https://+:<porta>/)
  [switch]$AplicarParede,
  [switch]$Reverter
)
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Rode como Administrador." }

if (-not $Port) {
  $taskArgs = (Get-ScheduledTask -TaskName 'NOC-Manager' -ErrorAction SilentlyContinue).Actions | Select-Object -First 1 -ExpandProperty Arguments
  $m = [regex]::Match([string]$taskArgs, '-Prefix\s+"?https://[^:/]+:(\d+)/')
  $Port = if ($m.Success) { [int]$m.Groups[1].Value } else { 443 }
}

$BackupDir = Join-Path $Root 'Manager\backups'
# arquivos de codigo (caminhos relativos a C:\NOC); dados de producao ficam de fora
$CodeFiles = @(
  'Start-Wall.ps1', 'Install-NocManager.ps1', 'Update-NocManager.ps1', 'Test-NocManager.ps1', 'Deploy-Scry.ps1',
  'LEIAME.md', 'INSTALAR.md', 'paineis.exemplo.json', 'Manager\NocManager.ps1', 'Manager\www\index.html'
)
$DataFiles = @('paineis.json', 'Manager\users.json', 'Manager\audit.log')

function Get-ScriptVersion([string]$File) {
  if (-not (Test-Path $File)) { return '?' }
  $m = [regex]::Match([IO.File]::ReadAllText($File), "\`$Version\s*=\s*'([^']+)'")
  if ($m.Success) { return $m.Groups[1].Value } else { return '1.0.0' }
}

function Restart-Manager {
  Stop-ScheduledTask -TaskName 'NOC-Manager' -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*\Manager\NocManager.ps1*' -and $_.CommandLine -notlike '*NovoAdmin*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 1
  Start-ScheduledTask -TaskName 'NOC-Manager'
}

# Espera a versao esperada responder em https://127.0.0.1:<porta>/api/versao (aceita so o nosso certificado)
function Wait-Version([string]$Expected) {
  $thumb = (Get-ChildItem Cert:\LocalMachine\My | Where-Object FriendlyName -eq 'NOC Manager' |
            Sort-Object NotAfter -Descending | Select-Object -First 1).Thumbprint
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  # callback em C#: um scriptblock aqui roda em outra thread sem runspace e derruba a conexao
  if (-not ('NocCertPin' -as [type])) {
    Add-Type -TypeDefinition @"
using System; using System.Net; using System.Net.Security; using System.Security.Cryptography.X509Certificates;
public static class NocCertPin {
  public static string Thumb;
  public static bool Check(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) {
    return c != null && !String.IsNullOrEmpty(Thumb) && String.Equals(c.GetCertHashString(), Thumb, StringComparison.OrdinalIgnoreCase);
  }
  public static void Enable(string t) { Thumb = t; ServicePointManager.ServerCertificateValidationCallback = Check; }
}
"@
  }
  [NocCertPin]::Enable($thumb)
  try {
    for ($i = 0; $i -lt 30; $i++) {
      try {
        $v = (Invoke-RestMethod "https://127.0.0.1:$Port/api/versao" -TimeoutSec 3).versao
        if ($v -eq $Expected) { return $v }
      } catch {}
      Start-Sleep -Seconds 1
    }
    return $null
  } finally { [Net.ServicePointManager]::ServerCertificateValidationCallback = $null }
}

$installed = Get-ScriptVersion (Join-Path $Root 'Manager\NocManager.ps1')

# ---------------------------------------------------------------- reverter
if ($Reverter) {
  $last = Get-ChildItem $BackupDir -Filter '*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $last) { throw "Nenhum backup em $BackupDir." }
  $tmp = Join-Path $env:TEMP ("noc-reverter-" + [guid]::NewGuid().ToString('N'))
  Expand-Archive $last.FullName -DestinationPath $tmp
  foreach ($f in $CodeFiles) {
    $s = Join-Path $tmp $f
    if (Test-Path $s) { Copy-Item $s (Join-Path $Root $f) -Force }
  }
  Remove-Item -LiteralPath $tmp -Recurse -Force
  $target = Get-ScriptVersion (Join-Path $Root 'Manager\NocManager.ps1')
  Restart-Manager
  $ok = Wait-Version $target
  if ($ok) { Write-Host "Revertido para v$target (backup $($last.Name))." -ForegroundColor Green }
  else { Write-Warning "Codigo restaurado de $($last.Name), mas a versao v$target nao respondeu na porta $Port. Veja C:\NOC\Manager\diag.log." }
  return
}

# ---------------------------------------------------------------- atualizar
$src = $PSScriptRoot
if ((Resolve-Path $src).Path.TrimEnd('\') -eq (Resolve-Path $Root).Path.TrimEnd('\')) {
  throw "Rode a partir da pasta do pacote novo (extraido em outro lugar), nao de $Root."
}
foreach ($f in @('Manager\NocManager.ps1', 'Manager\www\index.html', 'Start-Wall.ps1')) {
  if (-not (Test-Path (Join-Path $src $f))) { throw "Pacote incompleto: falta $f em $src" }
}
$newVersion = Get-ScriptVersion (Join-Path $src 'Manager\NocManager.ps1')
Write-Host "Instalado: v$installed  ->  pacote: v$newVersion" -ForegroundColor Cyan

# 1. backup
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$zip = Join-Path $BackupDir "$stamp-v$installed.zip"
$stage = Join-Path $env:TEMP ("noc-backup-" + [guid]::NewGuid().ToString('N'))
foreach ($f in $CodeFiles + $DataFiles) {
  $s = Join-Path $Root $f
  if (Test-Path $s) {
    $d = Join-Path $stage $f
    New-Item -ItemType Directory -Path (Split-Path $d) -Force | Out-Null
    Copy-Item $s $d -Force
  }
}
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
Remove-Item -LiteralPath $stage -Recurse -Force
Get-ChildItem $BackupDir -Filter '*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 | Remove-Item -Force
Write-Host "[1/3] Backup: $zip" -ForegroundColor Cyan

# 2. copiar codigo
$copied = 0
foreach ($f in $CodeFiles) {
  $s = Join-Path $src $f
  if (Test-Path $s) {
    $d = Join-Path $Root $f
    New-Item -ItemType Directory -Path (Split-Path $d) -Force | Out-Null
    Copy-Item $s $d -Force
    Unblock-File $d -ErrorAction SilentlyContinue
    $copied++
  }
}
if (-not (Test-Path (Join-Path $Root 'paineis.json')) -and (Test-Path (Join-Path $Root 'paineis.exemplo.json'))) {
  Copy-Item (Join-Path $Root 'paineis.exemplo.json') (Join-Path $Root 'paineis.json')
  Write-Host "      paineis.json nao existia - criado a partir do exemplo."
}
Write-Host "[2/3] $copied arquivos de codigo copiados (paineis.json, usuarios e auditoria mantidos)." -ForegroundColor Cyan

# 3. reiniciar e conferir
Restart-Manager
$v = Wait-Version $newVersion
if ($v) {
  Write-Host "[3/3] Gerenciador reiniciado e respondendo: v$v" -ForegroundColor Green
} else {
  Write-Warning "A versao v$newVersion nao respondeu na porta $Port em 30 s."
  Write-Host  "Veja C:\NOC\Manager\diag.log. Para voltar: Update-NocManager.ps1 -Reverter"
  exit 1
}

if ($AplicarParede) {
  & schtasks.exe /Run /TN NOC-VideoWall | Out-Null
  Write-Host "Tarefa NOC-VideoWall disparada (aplica o Start-Wall.ps1 novo)."
}
