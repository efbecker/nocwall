<#
  Deploy-Scry.ps1 - instalacao/atualizacao do Scry em UM passo.

  Normalmente nao e chamado direto: de dois cliques no INSTALAR.cmd que vem na raiz do pacote.
  Ele pede permissao de Administrador e roda este script.

  O que faz:
    1. Confere os pre-requisitos (Administrador, Windows PowerShell 5.1, Google Chrome, telas).
    2. Descobre sozinho se e uma INSTALACAO NOVA ou uma ATUALIZACAO:
         - Ja instalado (tarefa NOC-Manager existe)  -> roda o Update-NocManager.ps1 (com backup).
         - Nao instalado                             -> copia o pacote para C:\NOC e roda o
                                                        Install-NocManager.ps1 com as respostas.
    3. Na instalacao nova, pergunta so o necessario (com valor padrao entre colchetes):
         usuario da parede, endereco (HostName), certificado PFX (opcional) e
         credencial do Grafana (opcional).
    4. Mostra o endereco final e abre no navegador.

  Tudo o que aparece na tela fica tambem em C:\NOC\deploy.log (senhas nao sao gravadas).

  Uso sem perguntas (ex.: automacao):
    powershell -ExecutionPolicy Bypass -File <pacote>\NOC\Deploy-Scry.ps1 -SemPerguntas `
      -WallUser "PC\parede" -HostName scry.exemplo.local [-PfxPath C:\temp\cert.pfx]

  Arquivo em ASCII de proposito (PowerShell 5.1 le UTF-8 sem BOM como ANSI).
#>
param(
  [string]$WallUser,
  [string]$HostName,
  [string]$PfxPath,
  [string]$AllowFrom = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16",
  [switch]$SemPerguntas,        # usa os parametros/padroes sem perguntar nada
  [switch]$Reinstalar           # roda o instalador mesmo se ja estiver instalado (recria tarefas, certificado, firewall)
)
$ErrorActionPreference = 'Stop'
$Root = 'C:\NOC'                # fixo: o Start-Wall.ps1 usa C:\NOC
$src  = $PSScriptRoot           # pasta NOC do pacote extraido
$DefaultHost = 'scry.armazem.cloud'

function Write-Step([string]$t)  { Write-Host ""; Write-Host "==> $t" -ForegroundColor Cyan }
function Write-Ok([string]$t)    { Write-Host "    OK  $t" -ForegroundColor Green }
function Write-Warn2([string]$t) { Write-Host "    !!  $t" -ForegroundColor Yellow }
function Stop-Deploy([string]$t) {
  Write-Host ""
  Write-Host "ERRO: $t" -ForegroundColor Red
  Write-Host "Nada mais foi alterado. Corrija e rode o INSTALAR.cmd de novo."
  exit 1
}
function Ask([string]$Question, [string]$Default) {
  if ($SemPerguntas) { return $Default }
  $sfx = if ($Default) { " [$Default]" } else { "" }
  $a = Read-Host "$Question$sfx"
  if ([string]::IsNullOrWhiteSpace($a)) { return $Default } else { return $a.Trim().Trim('"') }
}
function Ask-YesNo([string]$Question, [bool]$Default) {
  if ($SemPerguntas) { return $Default }
  $d = if ($Default) { 'S/n' } else { 's/N' }
  $a = Read-Host "$Question ($d)"
  if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
  return ($a.Trim().ToLower() -in @('s', 'sim', 'y', 'yes'))
}
function Same-Path([string]$a, [string]$b) {
  return ([IO.Path]::GetFullPath($a).TrimEnd('\') -eq [IO.Path]::GetFullPath($b).TrimEnd('\'))
}

Write-Host ""
Write-Host "  Scry - Video Wall  |  instalacao / atualizacao" -ForegroundColor White
Write-Host "  -----------------------------------------------"

# ---------------------------------------------------------------- 1. pre-requisitos
Write-Step "1/4 Conferindo pre-requisitos"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Stop-Deploy "Rode como Administrador (de dois cliques no INSTALAR.cmd e aceite o aviso do Windows)." }
Write-Ok "Administrador"

if ($PSVersionTable.PSVersion.Major -ne 5) {
  Stop-Deploy "Use o Windows PowerShell 5.1 (powershell.exe), nao o PowerShell $($PSVersionTable.PSVersion). O INSTALAR.cmd ja faz isso."
}
Write-Ok "Windows PowerShell $($PSVersionTable.PSVersion)"

foreach ($f in @('Install-NocManager.ps1', 'Update-NocManager.ps1', 'Start-Wall.ps1', 'Manager\NocManager.ps1', 'Manager\www\index.html')) {
  if (-not (Test-Path (Join-Path $src $f))) { Stop-Deploy "Pacote incompleto: falta $f em $src. Extraia o .zip inteiro antes de rodar." }
}
Get-ChildItem $src -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
$pkgVersion = ([regex]::Match([IO.File]::ReadAllText((Join-Path $src 'Manager\NocManager.ps1')), "\`$Version\s*=\s*'([^']+)'")).Groups[1].Value
Write-Ok "Pacote Scry v$pkgVersion em $src"

$chrome = @(
  (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($chrome) { Write-Ok "Google Chrome: $chrome" }
else { Write-Warn2 "Google Chrome nao encontrado para todos os usuarios. Instale o Chrome antes de usar a parede (https://www.google.com/chrome/)." }

try {
  Add-Type -AssemblyName System.Windows.Forms
  $tiles = 0
  foreach ($s in [System.Windows.Forms.Screen]::AllScreens) { $tiles += [math]::Ceiling($s.Bounds.Width / 1920) * [math]::Ceiling($s.Bounds.Height / 1080) }
  if ($tiles -eq 10) { Write-Ok "Telas: 10 paineis de 1920x1080 detectados" }
  else { Write-Warn2 "Telas: $tiles paineis detectados (esperado: 10). Confira escala 100% e resolucao nativa. Siga mesmo assim se as telas ainda nao estiverem ligadas." }
} catch { Write-Warn2 "Nao consegui ler as telas ($($_.Exception.Message))." }

# ---------------------------------------------------------------- 2. instalar ou atualizar?
$installed = (Get-ScheduledTask -TaskName 'NOC-Manager' -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $Root 'Manager\NocManager.ps1'))

if ($installed -and -not $Reinstalar) {
  Write-Step "2/4 Scry ja instalado em ${Root}: ATUALIZANDO para v$pkgVersion"
  if (Same-Path $src $Root) {
    Write-Warn2 "O pacote esta dentro de $Root; nao ha o que copiar."
    Write-Host  "    Para atualizar, extraia o pacote NOVO em outra pasta (ex.: C:\Temp\scry) e rode o INSTALAR.cmd de la."
    Write-Host  "    Para recriar tarefas/certificado/firewall, rode:  INSTALAR.cmd -Reinstalar"
    exit 0
  }
  try { & (Join-Path $src 'Update-NocManager.ps1') -Root $Root -AplicarParede }
  catch { Stop-Deploy "A atualizacao falhou: $($_.Exception.Message)" }
  if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { Stop-Deploy "A atualizacao nao terminou bem. Para voltar: powershell -ExecutionPolicy Bypass -File $Root\Update-NocManager.ps1 -Reverter" }
  Write-Step "3/4 (atualizacao nao precisa de configuracao)"
  Write-Step "4/4 Pronto"
  Write-Host "    Scry atualizado. Dados (paineis, usuarios, auditoria) foram mantidos." -ForegroundColor Green
  exit 0
}

Write-Step "2/4 Copiando os arquivos para $Root"
if (Same-Path $src $Root) {
  Write-Ok "O pacote ja esta em $Root"
} else {
  New-Item -ItemType Directory -Path $Root -Force | Out-Null
  # dados de producao que possam existir no destino nunca sao sobrescritos
  $keep = @('paineis.json', 'grafana.cred', 'grafana.json', 'layout.json', 'pausado.json', 'Manager\users.json', 'Manager\audit.log')
  $n = 0
  foreach ($f in Get-ChildItem $src -Recurse -File) {
    $rel = $f.FullName.Substring($src.TrimEnd('\').Length + 1)
    $dst = Join-Path $Root $rel
    if (($keep -contains $rel) -and (Test-Path $dst)) { continue }
    New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
    Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
    $n++
  }
  Write-Ok "$n arquivos copiados"
}

# a partir daqui tudo fica registrado (o Read-Host de senha nao aparece no log)
try { Start-Transcript -Path (Join-Path $Root 'deploy.log') -Append | Out-Null } catch {}

# ---------------------------------------------------------------- 3. perguntas
Write-Step "3/4 Configuracao (Enter aceita o valor entre colchetes)"

if (-not $WallUser) {
  $WallUser = (Get-CimInstance Win32_ComputerSystem).UserName
  if (-not $WallUser) { $WallUser = "$env:COMPUTERNAME\$env:USERNAME" }
  $WallUser = Ask "Usuario do Windows que fica logado na parede" $WallUser
}
if (-not $WallUser) { Stop-Deploy "Informe o usuario da parede." }

if (-not $HostName) {
  Write-Host "    Endereco do Scry: o nome que a equipe vai digitar no navegador."
  Write-Host "    Ele precisa existir no DNS interno apontando para o IP deste PC."
  $HostName = Ask "Endereco (HostName)" $DefaultHost
}

if (-not $PfxPath -and -not $SemPerguntas) {
  Write-Host "    Certificado: informe o caminho de um .pfx (ex.: curinga da empresa) ou de Enter"
  Write-Host "    para gerar um autoassinado (funciona, mas o navegador mostra um aviso)."
  $PfxPath = Ask "Caminho do .pfx" ""
}
if ($PfxPath -and -not (Test-Path $PfxPath)) { Stop-Deploy "PFX nao encontrado: $PfxPath" }

# credencial do Grafana: criptografada (DPAPI) para o USUARIO DA PAREDE; so ele consegue criar
$credFile = Join-Path $Root 'grafana.cred'
$credHint = $null
if (-not (Test-Path $credFile)) {
  $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $sameUser = ($me -ieq $WallUser) -or (($me -split '\\')[-1] -ieq $WallUser)
  if ($sameUser -and (Ask-YesNo "Os paineis usam login do Grafana? Gravar a credencial agora" $false)) {
    $gu = Ask "Usuario do Grafana (de preferencia so leitura)" ""
    if ($gu) {
      Get-Credential -UserName $gu -Message 'Senha do Grafana (fica criptografada neste PC)' | Export-Clixml $credFile
      Write-Ok "Credencial do Grafana gravada em $credFile"
    }
  } else {
    $credHint = "Get-Credential -UserName USUARIO_GRAFANA -Message Grafana | Export-Clixml $credFile"
  }
}

Write-Host ""
Write-Host "    Resumo:" -ForegroundColor White
Write-Host "      Pasta ........... $Root"
Write-Host "      Usuario parede .. $WallUser"
Write-Host "      Endereco ........ https://$HostName"
Write-Host "      Certificado ..... $(if ($PfxPath) { $PfxPath } else { 'autoassinado (gerado agora)' })"
Write-Host "      Redes liberadas . $AllowFrom"
if (-not (Ask-YesNo "Continuar" $true)) { Write-Host "Cancelado. Os arquivos ficaram em $Root."; exit 0 }

# ---------------------------------------------------------------- 4. instalador
Write-Step "4/4 Instalando (vai pedir a senha do usuario 'admin' do Scry, minimo 10 caracteres)"
$inst = @{ WallUser = $WallUser; HostName = $HostName; AllowFrom = $AllowFrom; Root = $Root }
if ($PfxPath) { $inst.PfxPath = $PfxPath }
try {
  & (Join-Path $Root 'Install-NocManager.ps1') @inst
} catch {
  Stop-Deploy "O instalador falhou: $($_.Exception.Message)"
}

$url = "https://$HostName"
Write-Host ""
Write-Host "  ==============================================================" -ForegroundColor Green
Write-Host "   Scry instalado!  Acesse $url  (usuario: admin)" -ForegroundColor Green
Write-Host "  ==============================================================" -ForegroundColor Green
Write-Host "   Proximos passos:"
Write-Host "   - DNS: o nome $HostName precisa apontar para o IP deste PC."
Write-Host "   - Parede: faca logoff/logon do usuario $WallUser (ou espere ate 5 min)."
if ($credHint) {
  Write-Host "   - Grafana (se os paineis pedem login): entre no Windows como $WallUser,"
  Write-Host "     abra o PowerShell (normal) e rode:"
  Write-Host "       $credHint" -ForegroundColor Yellow
}
Write-Host "   - Log desta instalacao: $Root\deploy.log"
try { Stop-Transcript | Out-Null } catch {}
if (-not $SemPerguntas) { try { Start-Process $url } catch {} }
