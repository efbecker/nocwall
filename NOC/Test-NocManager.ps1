<#
  Test-NocManager.ps1 - teste rapido do Scry (gerenciador do video wall); roda de qualquer PC Windows.

    powershell -ExecutionPolicy Bypass -File Test-NocManager.ps1 -Url https://scry.armazem.cloud -Usuario admin

  Pede a senha (ou use -Senha com SecureString). Testa, sem mexer na parede:
    versao, login, sessao, estado, status, miniaturas, auditoria, usuarios, protecoes (401/403)
    e o consumo de memoria do gerenciador antes e depois.
  -Acoes            tambem recarrega um painel (-Painel, padrao 9) e espera a miniatura nova.
  -Mosaico          (admin) MEXE NA PAREDE: mescla 4-7 em 2x2, confere, separa e confere de novo.
  -Thumbprint X     confere o certificado (SHA1 mostrado pelo instalador). Sem ele, aceita qualquer um.
  Codigo de saida = numero de falhas (0 = tudo certo).
#>
param(
  [string]$Url = "https://scry.armazem.cloud",
  [string]$Usuario = "admin",
  [Security.SecureString]$Senha,
  [string]$Thumbprint,
  [switch]$Acoes,
  [int]$Painel = 9,
  [switch]$Mosaico
)
$ErrorActionPreference = 'Stop'
$Url = $Url.TrimEnd('/')
$script:fails = 0; $script:warns = 0

function Show-Result([string]$Name, [string]$State, [string]$Detail) {
  $color = @{ OK = 'Green'; AVISO = 'Yellow'; FALHA = 'Red' }[$State]
  if ($State -eq 'FALHA') { $script:fails++ } elseif ($State -eq 'AVISO') { $script:warns++ }
  Write-Host ("[{0,-5}] {1,-28} {2}" -f $State, $Name, $Detail) -ForegroundColor $color
}

# ---------------------------------------------------------------- certificado
$isCore = $PSVersionTable.PSVersion.Major -ge 6
$uri = [Uri]$Url
# callbacks de certificado em C#: no PS 5.1 um scriptblock roda em outra thread sem runspace e falha
if (-not ('NocTestTls' -as [type])) {
  # ServicePointManager so existe/importa no PS 5.1 (no PS 7 o compilador o recusa como obsoleto)
  $spm = if ($isCore) { '' } else { 'public static void AcceptAll() { ServicePointManager.ServerCertificateValidationCallback = Any; }' }
  Add-Type -TypeDefinition @"
using System.Net; using System.Net.Security; using System.Security.Cryptography.X509Certificates;
public static class NocTestTls {
  public static bool Any(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) { return true; }
  public static RemoteCertificateValidationCallback AnyCallback { get { return Any; } }
  $spm
}
"@
}
try {
  $tcp = New-Object Net.Sockets.TcpClient($uri.Host, $uri.Port)
  $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, [NocTestTls]::AnyCallback)
  $ssl.AuthenticateAsClient($uri.Host)
  $rc  = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
  $got = $rc.Thumbprint
  $ssl.Dispose(); $tcp.Dispose()
  # cadeia confiavel neste PC + nome do endereco no certificado
  $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
  $chain.ChainPolicy.RevocationMode = 'NoCheck'
  $trusted = $chain.Build($rc)
  $names = @($rc.DnsNameList | ForEach-Object { $_.Unicode })
  $nameOk = [bool]($names | Where-Object { $_ -eq $uri.Host -or ($_.StartsWith('*.') -and $uri.Host -like $_ -and $uri.Host.Split('.').Count -eq $_.Split('.').Count) })
  $days = [int][math]::Floor(($rc.NotAfter - (Get-Date)).TotalDays)
  $desc = "$($rc.Subject -replace ',.*$', '') | vence $($rc.NotAfter.ToString('dd/MM/yyyy')) ($days dias) | $got"
  if ($Thumbprint -and $got -ne ($Thumbprint -replace '[:\s]', '').ToUpper()) { Show-Result 'Certificado' FALHA "esperado $Thumbprint, recebido $got"; exit $script:fails }
  elseif ($trusted -and $nameOk) { Show-Result 'Certificado' OK "confiavel: $desc" }
  elseif ($Thumbprint) { Show-Result 'Certificado' OK "impressao digital conferida (nao confiavel neste PC): $desc" }
  else { Show-Result 'Certificado' AVISO "nao confiavel ou nome diferente de $($uri.Host): $desc (use -Thumbprint)" }
  if ($days -lt 30) { Show-Result 'Vencimento do certificado' $(if ($days -lt 7) { 'FALHA' } else { 'AVISO' }) "faltam $days dias - renove e rode Install-NocManager.ps1 -PfxPath" }
} catch { Show-Result 'Conexao TLS' FALHA $_.Exception.Message; exit $script:fails }

if (-not $isCore) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  [NocTestTls]::AcceptAll()     # o certificado ja foi conferido acima (com -Thumbprint)
}

# ---------------------------------------------------------------- HTTP
$session = $null
function Invoke-Api([string]$Method, [string]$Path, $Body, [switch]$NoNoc, [switch]$Raw, [switch]$NoSession) {
  $p = @{ Uri = "$Url$Path"; Method = $Method; UseBasicParsing = $true; TimeoutSec = 30; ErrorAction = 'Stop' }
  if ($isCore) { $p.SkipCertificateCheck = $true; $p.SkipHttpErrorCheck = $true }
  if (-not $NoSession) {
    if ($script:session) {
      $script:session.Headers.Clear()   # PS 5.1 incorpora os cabecalhos de cada chamada na sessao; so os desta valem
      $p.WebSession = $script:session
    } else { $p.SessionVariable = 'sv' }
  }
  $h = @{}; if (-not $NoNoc) { $h['X-NOC'] = '1' }; $p.Headers = $h
  if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Compress); $p.ContentType = 'application/json' }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try { $r = Invoke-WebRequest @p; $code = [int]$r.StatusCode }
  catch [Net.WebException] {
    $r = $_.Exception.Response; $code = if ($r) { [int]$r.StatusCode } else { 0 }
    return [pscustomobject]@{ Code = $code; Ms = $sw.ElapsedMilliseconds; Json = $null; Bytes = 0; Type = '' }
  }
  if (-not $NoSession -and -not $script:session -and $sv) {
    $script:session = $sv
  }
  $json = $null
  if (-not $Raw -and $r.Content) { try { $json = $r.Content | ConvertFrom-Json } catch {} }
  $len = if ($r.RawContentLength) { $r.RawContentLength } else { ([string]$r.Content).Length }
  return [pscustomobject]@{ Code = $code; Ms = $sw.ElapsedMilliseconds; Json = $json; Bytes = $len; Type = [string]$r.Headers['Content-Type'] }
}

# 1. versao
$r = Invoke-Api GET '/api/versao' -NoSession
if ($r.Code -eq 200 -and $r.Json.versao) { Show-Result 'Versao' OK "v$($r.Json.versao) ($($r.Ms) ms)" } else { Show-Result 'Versao' FALHA "HTTP $($r.Code)" }

# 1b. saude (rota do Zabbix, sem sessao)
$r = Invoke-Api GET '/api/saude' -NoSession
if ($r.Code -eq 200 -and $null -ne $r.Json.codigo) {
  $estado = if ($r.Json.codigo -eq 0) { 'OK' } else { 'AVISO' }
  $cert = if ($r.Json.certificado) { "certificado $($r.Json.certificado.dias) dias" } else { 'certificado ainda nao lido' }
  Show-Result 'Saude (/api/saude)' $estado "$($r.Json.status): $($r.Json.resumo) | auto=$($r.Json.manutencao.autoCorrigir) | $cert"
} else { Show-Result 'Saude (/api/saude)' FALHA "HTTP $($r.Code)" }

# 2. protecao: sem sessao
$r = Invoke-Api GET '/api/estado' -NoSession
if ($r.Code -eq 401) { Show-Result 'Sem sessao -> 401' OK '' } else { Show-Result 'Sem sessao -> 401' FALHA "HTTP $($r.Code)" }

# 3. login
if (-not $Senha) { $Senha = Read-Host "Senha de $Usuario" -AsSecureString }
$plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Senha))
$r = Invoke-Api POST '/api/login' @{ usuario = $Usuario; senha = $plain }
$plain = $null
if ($r.Code -ne 200) { Show-Result 'Login' FALHA "HTTP $($r.Code)"; exit $script:fails }
$papel = $r.Json.papel
Show-Result 'Login' OK "$Usuario ($papel) em $($r.Ms) ms"

# 4. sessao e CSRF
$r = Invoke-Api GET '/api/me'
if ($r.Code -eq 200) { Show-Result 'Sessao (/api/me)' OK "$($r.Ms) ms" } else { Show-Result 'Sessao (/api/me)' FALHA "HTTP $($r.Code)" }
$r = Invoke-Api POST '/api/logout' @{} -NoNoc
if ($r.Code -eq 403) { Show-Result 'Sem X-NOC -> 403' OK '' } else { Show-Result 'Sem X-NOC -> 403' FALHA "HTTP $($r.Code) (a sessao pode ter sido encerrada)" }

# 5. estado
$r = Invoke-Api GET '/api/estado'
if ($r.Code -eq 200) {
  $np = @($r.Json.paineis).Count; $nc = @($r.Json.cenarios).Count; $nb = @($r.Json.biblioteca).Count
  $lay = if ($r.Json.layout) { "layout real ($(@($r.Json.layout.telas).Count) telas)" } else { 'sem layout.json (grade padrao)' }
  if ($np -eq 10) { Show-Result 'Estado' OK "$np paineis, $nc cenarios, $nb na biblioteca, $lay ($($r.Ms) ms)" }
  else { Show-Result 'Estado' FALHA "$np paineis (esperado 10)" }
} else { Show-Result 'Estado' FALHA "HTTP $($r.Code)" }

# 6. status
$r = Invoke-Api GET '/api/status'
$mem0 = $null; $st = $null
if ($r.Code -eq 200) {
  $st = $r.Json
  $on = @($st.paineis | Where-Object online).Count
  $vis = @($st.paineis | Where-Object { $null -eq $_.absorvido }).Count     # paineis mesclados ficam fechados de proposito
  $mos = if ($vis -lt 10) { " (mosaico: $(10 - $vis) painel(is) mesclado(s))" } else { '' }
  $mem0 = if ($st.pc) { $st.pc.managerMB } else { $null }
  if ($st.pausa) { Show-Result 'Status' AVISO "parede PAUSADA por $($st.pausa.por) ($on/$vis online)" }
  elseif ($on -eq $vis) { Show-Result 'Status' OK "$on/$vis online$mos ($($r.Ms) ms)" }
  else { Show-Result 'Status' AVISO "$on/$vis online$mos" }
  if ($r.Ms -gt 500) { Show-Result 'Status: tempo' AVISO "$($r.Ms) ms (esperado < 500)" }
  if ($st.pc) {
    $usado = [math]::Round((1 - $st.pc.memLivreMB / $st.pc.memTotalMB) * 100)
    $state = if ($usado -gt 85) { 'AVISO' } else { 'OK' }
    Show-Result 'PC da parede' $state ("RAM {0}% | CPU {1}% | Chrome {2:N1} GB ({3} proc.) | ligado ha {4} h" -f $usado, $st.pc.cpu, ($st.pc.chromeMB / 1024), $st.pc.chromeProc, $st.pc.uptimeH)
  } else { Show-Result 'PC da parede' AVISO 'ainda sem dados (o worker coleta a cada 15 s)' }
} else { Show-Result 'Status' FALHA "HTTP $($r.Code)" }

# 7. miniaturas
if ($st) {
  foreach ($p in @($st.paineis | Where-Object online)) {
    $r = Invoke-Api GET "/api/paineis/$($p.n)/print?t=$($p.imgT)" -Raw
    if ($r.Code -eq 200 -and $r.Type -like 'image/jpeg*' -and $r.Bytes -gt 5000 -and $r.Ms -lt 1000) { Show-Result "Miniatura $($p.n)" OK ("{0:N0} KB em {1} ms" -f ($r.Bytes / 1KB), $r.Ms) }
    elseif ($r.Code -eq 404) { Show-Result "Miniatura $($p.n)" AVISO 'ainda nao gerada (abra a pagina ou aguarde 10 s)' }
    else { Show-Result "Miniatura $($p.n)" FALHA "HTTP $($r.Code), $($r.Bytes) bytes, $($r.Ms) ms" }
  }
}

# 8. auditoria e usuarios (admin)
if ($papel -eq 'admin') {
  $r = Invoke-Api GET '/api/auditoria'
  if ($r.Code -eq 200 -and $r.Ms -lt 2000) { Show-Result 'Auditoria' OK "$(@($r.Json).Count) linhas em $($r.Ms) ms" }
  else { Show-Result 'Auditoria' FALHA "HTTP $($r.Code) em $($r.Ms) ms" }
  $r = Invoke-Api GET '/api/usuarios'
  if ($r.Code -eq 200) { Show-Result 'Usuarios' OK "$(@($r.Json).Count) usuario(s)" } else { Show-Result 'Usuarios' FALHA "HTTP $($r.Code)" }
  # validacao do mosaico sem mexer na parede: 0 e 3 sao diagonais (nao formam retangulo)
  $r = Invoke-Api POST '/api/mosaico/mesclar' @{ paineis = @(0, 3) }
  if ($r.Code -eq 400) { Show-Result 'Mosaico: valida retangulo' OK '0+3 (diagonal) recusado' } else { Show-Result 'Mosaico: valida retangulo' FALHA "HTTP $($r.Code) (esperado 400)" }
} else {
  $r = Invoke-Api POST '/api/mosaico/mesclar' @{ paineis = @(0, 3) }
  if ($r.Code -eq 403) { Show-Result 'Mosaico so admin' OK "$papel recebe 403" } else { Show-Result 'Mosaico so admin' FALHA "HTTP $($r.Code) (esperado 403)" }
}

# 8b. mosaico de verdade (opcional): mescla 4-7, confere, separa
function Wait-Panels([scriptblock]$Cond, [int]$Seg) {
  for ($i = 0; $i -lt $Seg; $i += 2) {
    Start-Sleep -Seconds 2
    $s = (Invoke-Api GET '/api/status').Json
    if ($s -and (& $Cond $s)) { return $i + 2 }
  }
  return $null
}
if ($Mosaico -and $papel -eq 'admin' -and $st -and -not $st.pausa) {
  if (@($st.paineis | Where-Object { $_.absorvido -ne $null -or ($_.n -ge 4 -and $_.n -le 7 -and -not $_.online) }).Count) {
    Show-Result 'Mosaico 4-7' AVISO 'pulado: ja existe mosaico ou algum dos paineis 4-7 esta offline'
  } else {
    $r = Invoke-Api POST '/api/mosaico/mesclar' @{ paineis = @(4, 5, 6, 7); escala = 'ampliar' }
    if ($r.Code -ne 200) { Show-Result 'Mosaico: mesclar 4-7' FALHA "HTTP $($r.Code)" }
    else {
      $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      $seg = Wait-Panels { param($s) $p4 = $s.paineis | Where-Object n -eq 4
        (@($s.paineis | Where-Object { $_.absorvido -eq 4 }).Count -eq 3) -and $p4.online -and $p4.imgT -gt $t0 } 90
      if ($seg) { Show-Result 'Mosaico: mesclar 4-7' OK "painel 4 em 2x2 com miniatura nova em ~$seg s" } else { Show-Result 'Mosaico: mesclar 4-7' FALHA 'painel 4 nao voltou com a area 2x2 em 90 s' }
      $r = Invoke-Api POST '/api/mosaico/separar' @{ n = 4 }
      $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      $seg = Wait-Panels { param($s) @($s.paineis | Where-Object { $_.n -ge 4 -and $_.n -le 7 -and $_.online -and $_.imgT -gt $t1 }).Count -eq 4 } 120
      if ($r.Code -eq 200 -and $seg) { Show-Result 'Mosaico: separar' OK "4, 5, 6, 7 online de novo em ~$seg s" } else { Show-Result 'Mosaico: separar' FALHA "HTTP $($r.Code); paineis 4-7 nao voltaram em 120 s" }
    }
  }
}

# 9. acao real (opcional)
if ($Acoes -and $st -and -not $st.pausa) {
  $before = ($st.paineis | Where-Object n -eq $Painel).imgT
  $r = Invoke-Api POST "/api/paineis/$Painel/recarregar" @{}
  if ($r.Code -eq 200) {
    $ok = $false
    for ($i = 0; $i -lt 25; $i++) {
      Start-Sleep -Seconds 1
      $s2 = (Invoke-Api GET '/api/status').Json
      $p2 = $s2.paineis | Where-Object n -eq $Painel
      if ($p2.imgT -and $p2.imgT -gt $before -and -not $p2.pendente) { $ok = $true; break }
    }
    if ($ok) { Show-Result "Recarregar painel $Painel" OK "miniatura nova em ~$($i + 1) s" } else { Show-Result "Recarregar painel $Painel" FALHA 'miniatura nao atualizou em 25 s' }
  } else { Show-Result "Recarregar painel $Painel" FALHA "HTTP $($r.Code)" }
}

# 10. memoria do gerenciador depois do teste (o worker atualiza a cada 15 s)
if ($null -ne $mem0) {
  Write-Host "Aguardando 16 s para medir a memoria do gerenciador de novo..." -ForegroundColor DarkGray
  Start-Sleep -Seconds 16
  $s3 = (Invoke-Api GET '/api/status').Json
  $mem1 = $s3.pc.managerMB
  $delta = $mem1 - $mem0
  if ($mem1 -gt 500 -or $delta -gt 150) { Show-Result 'Memoria do gerenciador' FALHA "$mem0 -> $mem1 MB" }
  else { Show-Result 'Memoria do gerenciador' OK "$mem0 -> $mem1 MB" }
}

Invoke-Api POST '/api/logout' @{} | Out-Null
Write-Host ""
$color = if ($script:fails) { 'Red' } elseif ($script:warns) { 'Yellow' } else { 'Green' }
Write-Host ("Resultado: {0} falha(s), {1} aviso(s)." -f $script:fails, $script:warns) -ForegroundColor $color
exit $script:fails
