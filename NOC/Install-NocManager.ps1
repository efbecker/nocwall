<#
  Install-NocManager.ps1 - instala o Scry (gerenciador web do video wall)
  Rode como ADMINISTRADOR, a partir de C:\NOC:
    powershell -ExecutionPolicy Bypass -File C:\NOC\Install-NocManager.ps1 -WallUser <usuario_da_parede>

  O que faz:
    1. Desbloqueia os arquivos baixados
    2. Cria o primeiro usuario admin (pergunta a senha)
    3. Certificado HTTPS para -HostName (padrao scry.armazem.cloud): autoassinado, ou o seu com -PfxPath
       (ex.: o curinga *.armazem.cloud). Associa na porta principal (443) e na antiga (8443, so redireciona)
    4. Firewall: libera 443, 80 (redireciona para https) e 8443 (antiga) so para -AllowFrom (redes internas)
    5. Cria/atualiza as tarefas agendadas:
         NOC-VideoWall -> Start-Wall.ps1 no logon do usuario da parede e a cada 5 min (janela oculta)
         NOC-Manager   -> NocManager.ps1 como SYSTEM no boot e a cada 5 min (sobe de novo se cair)
  O proprio Scry recusa IPs fora de -AllowFrom (vale mesmo com o firewall do Windows desligado).

  Trocar so o certificado (ex.: curinga):
    ... Install-NocManager.ps1 -WallUser admin -PfxPath C:\temp\armazem.pfx   (pede a senha do PFX)
  Remover tudo:  ... Install-NocManager.ps1 -Remover
#>
param(
  [string]$WallUser,
  [string]$HostName  = "scry.armazem.cloud",
  [int]$Port         = 443,
  [int]$LegacyPort   = 8443,          # endereco antigo: so redireciona para o novo (0 = desligar)
  [switch]$SemHttp,                    # nao abrir a porta 80 (redirecionamento http -> https)
  [string]$AllowFrom = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16",
  [string]$PfxPath,
  [Security.SecureString]$PfxPassword,
  [string]$IpAddress,
  [string]$Root = "C:\NOC",
  [switch]$Remover
)
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Rode este instalador como Administrador." }

$appId  = '{6f6b0c9e-4e2a-4c1b-9a77-0c4e1a5d2b11}'
$fwName = 'NOC Manager (HTTPS)'
$fwHttp = 'NOC Manager (HTTP redirect)'
$sslPorts = @($Port) + $(if ($LegacyPort -gt 0 -and $LegacyPort -ne $Port) { @($LegacyPort) } else { @() })

if ($Remover) {
  Unregister-ScheduledTask -TaskName 'NOC-Manager'   -Confirm:$false -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName 'NOC-VideoWall' -Confirm:$false -ErrorAction SilentlyContinue
  Get-NetFirewallRule -DisplayName $fwName, $fwHttp -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  foreach ($p in ($sslPorts + 8443 | Select-Object -Unique)) { & netsh http delete sslcert ipport="0.0.0.0:$p" 2>&1 | Out-Null }
  Write-Host "Removido: tarefas, regras de firewall e certificados associados as portas." -ForegroundColor Yellow
  Write-Host "Arquivos em $Root, usuarios e auditoria foram mantidos."
  return
}

$startWall = Join-Path $Root 'Start-Wall.ps1'
$manager   = Join-Path $Root 'Manager\NocManager.ps1'
# paineis.json e dado de producao: o pacote traz so o exemplo, usado na primeira instalacao
$cfgFile = Join-Path $Root 'paineis.json'
if (-not (Test-Path $cfgFile) -and (Test-Path (Join-Path $Root 'paineis.exemplo.json'))) {
  Copy-Item (Join-Path $Root 'paineis.exemplo.json') $cfgFile
  Write-Host "paineis.json criado a partir de paineis.exemplo.json." -ForegroundColor Cyan
}
foreach ($f in @($startWall, $manager, $cfgFile, (Join-Path $Root 'Manager\www\index.html'))) {
  if (-not (Test-Path $f)) { throw "Arquivo nao encontrado: $f (extraia o pacote em $Root)" }
}

# ---------------------------------------------------------------- 1. desbloquear
Get-ChildItem $Root -Recurse -File | Unblock-File
Write-Host "[1/5] Arquivos desbloqueados." -ForegroundColor Cyan

# ---------------------------------------------------------------- 2. admin
$usersFile = Join-Path $Root 'Manager\users.json'
if (-not (Test-Path $usersFile)) {
  Write-Host "[2/5] Criando o primeiro administrador (usuario: admin)" -ForegroundColor Cyan
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager -Root $Root -NovoAdmin admin
  if (-not (Test-Path $usersFile)) { throw "Admin nao foi criado." }
} else {
  Write-Host "[2/5] users.json ja existe - mantido." -ForegroundColor Cyan
}
# so SYSTEM e Administradores leem os arquivos do gerenciador (hashes de senha, auditoria, backups)
& icacls (Join-Path $Root 'Manager') /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

# ---------------------------------------------------------------- 3. certificado
if (-not $IpAddress) {
  $IpAddress = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Select-Object -First 1).IPAddress
}
function Test-CertCovers($c, [string]$name) {
  # DnsNameList (PowerShell) nao depende do idioma do Windows, ao contrario de Extension.Format()
  $dnsNames = @($c.DnsNameList | ForEach-Object { $_.Unicode })
  foreach ($d in $dnsNames) {
    if ($d -eq $name) { return $true }
    if ($d.StartsWith('*.') -and $name -like $d -and ($name.Split('.').Count -eq $d.Split('.').Count)) { return $true }
  }
  return $false
}
if ($PfxPath) {
  if (-not (Test-Path $PfxPath)) { throw "PFX nao encontrado: $PfxPath" }
  if (-not $PfxPassword) { $PfxPassword = Read-Host "Senha do PFX" -AsSecureString }
  $all  = @(Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation Cert:\LocalMachine\My -Password $PfxPassword)
  $cert = @($all | Where-Object HasPrivateKey)[0]
  if (-not $cert) { throw "O PFX nao tem chave privada." }
  if (-not (Test-CertCovers $cert $HostName)) { throw "O certificado do PFX nao cobre $HostName." }
  # cadeia: intermediarios vao para 'Autoridades Intermediarias' (o http.sys envia a cadeia ao navegador);
  # raizes NAO sao adicionadas a confianca. Os extras importados em 'Pessoal' sao retirados de la.
  $caStore = New-Object Security.Cryptography.X509Certificates.X509Store('CA', 'LocalMachine')
  $caStore.Open('ReadWrite')
  foreach ($x in $all | Where-Object { $_.Thumbprint -ne $cert.Thumbprint }) {
    if ($x.Subject -ne $x.Issuer) { $caStore.Add($x); Write-Host "      intermediario: $($x.Subject -replace ',.*$', '')" }
    Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($x.Thumbprint)" -ErrorAction SilentlyContinue
  }
  $caStore.Close()
  # autoassinados antigos deixam de ser candidatos a reaproveitamento
  Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'NOC Manager' -and $_.Thumbprint -ne $cert.Thumbprint -and $_.Subject -eq $_.Issuer } |
    ForEach-Object { $_.FriendlyName = 'NOC Manager (autoassinado antigo)' }
  # o objeto devolvido pelo Import-PfxCertificate nao fica ligado ao repositorio: grava pelo Cert:\
  $cert = Get-Item -LiteralPath "Cert:\LocalMachine\My\$($cert.Thumbprint)"
  $cert.FriendlyName = 'NOC Manager'
  Write-Host "      Certificado importado: $($cert.Subject) (valido ate $($cert.NotAfter.ToString('dd/MM/yyyy')))"
} else {
  # reaproveita um certificado 'NOC Manager' que ja cubra o nome; prefere o emitido por autoridade ao autoassinado
  $cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.FriendlyName -eq 'NOC Manager' -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) -and (Test-CertCovers $_ $HostName) } |
    Sort-Object @{ Expression = { $_.Subject -ne $_.Issuer }; Descending = $true }, @{ Expression = 'NotAfter'; Descending = $true } |
    Select-Object -First 1
  if (-not $cert) {
    $san = "DNS=$HostName&DNS=$($env:COMPUTERNAME)&IPAddress=$IpAddress"
    $cert = New-SelfSignedCertificate -CertStoreLocation Cert:\LocalMachine\My -FriendlyName 'NOC Manager' `
      -Subject "CN=$HostName" -TextExtension @("2.5.29.17={text}$san") `
      -KeyExportPolicy NonExportable -KeyAlgorithm RSA -KeyLength 2048 -NotAfter (Get-Date).AddYears(5)
    Write-Host "      Certificado autoassinado novo para $HostName."
  }
}
foreach ($p in $sslPorts) {
  & netsh http delete sslcert ipport="0.0.0.0:$p" 2>&1 | Out-Null
  $out = & netsh http add sslcert ipport="0.0.0.0:$p" certhash=$($cert.Thumbprint) appid=$appId 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Falha ao associar certificado na porta ${p}: $out" }
}
Write-Host "[3/5] Certificado $($cert.Thumbprint) nas portas $($sslPorts -join ', ') ($HostName)." -ForegroundColor Cyan

# ---------------------------------------------------------------- 4. firewall
$remote = @($AllowFrom -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Get-NetFirewallRule -DisplayName $fwName, $fwHttp -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Protocol TCP -LocalPort $sslPorts `
  -RemoteAddress $remote -Action Allow -Profile Any | Out-Null
if (-not $SemHttp) {
  New-NetFirewallRule -DisplayName $fwHttp -Direction Inbound -Protocol TCP -LocalPort 80 `
    -RemoteAddress $remote -Action Allow -Profile Any | Out-Null
}
$fwOff = @(Get-NetFirewallProfile | Where-Object { -not $_.Enabled } | ForEach-Object Name)
Write-Host "[4/5] Firewall: portas $(($sslPorts + $(if (-not $SemHttp) { 80 })) -join ', ') so para $($remote -join ', ')." -ForegroundColor Cyan
if ($fwOff) { Write-Warning "Firewall do Windows desligado nos perfis: $($fwOff -join ', '). O Scry recusa IPs fora de -AllowFrom por conta propria." }

# ---------------------------------------------------------------- 5. tarefas
# 5a. Parede: roda na sessao do usuario logado, sem janela (via wscript), a cada 5 min
if (-not $WallUser) {
  $WallUser = (Get-CimInstance Win32_ComputerSystem).UserName
  if (-not $WallUser) { throw "Informe -WallUser (usuario que fica logado na parede)." }
}
$vbs = Join-Path $Root 'run-hidden.vbs'
$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""$startWall"""
Set-Content -Path $vbs -Encoding ASCII -Value ("CreateObject(""WScript.Shell"").Run ""{0}"", 0, False" -f ($cmd -replace '"', '""'))

$aWall = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
$tLogon = New-ScheduledTaskTrigger -AtLogOn -User $WallUser
$tRep   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$pWall  = New-ScheduledTaskPrincipal -UserId $WallUser -LogonType Interactive -RunLevel Limited
$sWall  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName 'NOC-VideoWall' -Action $aWall -Trigger @($tLogon, $tRep) -Principal $pWall -Settings $sWall -Force | Out-Null

# 5b. Gerenciador: SYSTEM, no boot e a cada 5 min, sem limite de tempo
$publicUrl = "https://$HostName" + $(if ($Port -ne 443) { ":$Port" } else { "" })
$extra = @()
if (-not $SemHttp) { $extra += "http://+:80/" }
if ($LegacyPort -gt 0 -and $LegacyPort -ne $Port) { $extra += "https://+:$LegacyPort/" }
$mgrArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$manager`" -Root `"$Root`" -Prefix `"https://+:$Port/`" -PublicUrl `"$publicUrl`" -AllowFrom `"$($remote -join ',')`""
if ($extra) { $mgrArgs += " -ExtraPrefixes `"$($extra -join ',')`"" }
$aMgr = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $mgrArgs
$tBoot = New-ScheduledTaskTrigger -AtStartup
$tBoot.Delay = 'PT30S'                       # da tempo para rede/http.sys subirem
# Repeticao a cada 5 min: se o processo morreu (ou saiu pela protecao de memoria), sobe de novo.
# Enquanto estiver rodando, MultipleInstances=IgnoreNew ignora o disparo.
$tMgrRep = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$pMgr  = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$sMgr  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
  -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName 'NOC-Manager' -Action $aMgr -Trigger @($tBoot, $tMgrRep) -Principal $pMgr -Settings $sMgr -Force | Out-Null

Stop-ScheduledTask  -TaskName 'NOC-Manager' -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*\Manager\NocManager.ps1*' -and $_.CommandLine -notlike '*NovoAdmin*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
Start-ScheduledTask -TaskName 'NOC-Manager'
Write-Host "[5/5] Tarefas NOC-VideoWall ($WallUser) e NOC-Manager (SYSTEM) registradas." -ForegroundColor Cyan

Start-Sleep -Seconds 5
$listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
Write-Host ""
if ($listening) {
  Write-Host "Pronto! Acesse: $publicUrl   (usuario: admin)" -ForegroundColor Green
  if (-not $PfxPath -and $cert.Issuer -eq $cert.Subject) {
    Write-Host "Certificado autoassinado: o navegador vai avisar. Confira a impressao digital:"
    Write-Host "  $($cert.Thumbprint)"
  }
} else {
  Write-Warning "O Scry nao esta ouvindo na porta $Port. Veja C:\NOC\Manager\diag.log ou rode manualmente:"
  Write-Host "  powershell -ExecutionPolicy Bypass -File `"$manager`" -Prefix https://+:$Port/"
}
