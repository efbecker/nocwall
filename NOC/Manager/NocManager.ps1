<#
  NocManager.ps1 - Scry / Video Wall: gerenciador web do video wall do NOC ("Veja o topo da operacao")
  - Servidor HTTPS (HttpListener) com login, papeis e auditoria
  - Le/grava C:\NOC\paineis.json (paineis + cenarios)
  - Troca links na hora via porta de depuracao do Chrome (127.0.0.1:9300-9309)

  Uso normal (via tarefa agendada criada pelo instalador):
    powershell -ExecutionPolicy Bypass -File C:\NOC\Manager\NocManager.ps1
  Criar/redefinir um admin:
    powershell -ExecutionPolicy Bypass -File C:\NOC\Manager\NocManager.ps1 -NovoAdmin admin
  Gerar o codigo do assistente de configuracao (so enquanto nao existe nenhum usuario):
    powershell -ExecutionPolicy Bypass -File C:\NOC\Manager\NocManager.ps1 -NovoCodigo

  Sem nenhum usuario cadastrado, o servidor sobe em MODO DE CONFIGURACAO: a pagina inicial vira um
  assistente que pede o codigo de uso unico (setup.json), cria o admin, registra a tarefa da parede e,
  se pedido, ativa o logon automatico do Windows. Concluido, o assistente some.

  Arquivo em ASCII de proposito (PowerShell 5.1 le UTF-8 sem BOM como ANSI).
#>
param(
  [string]$Root     = "C:\NOC",
  [string]$Prefix   = "https://+:443/",
  [string]$PublicUrl = "",                 # endereco oficial (ex.: https://scry.armazem.cloud); destino dos redirecionamentos
  [string]$ExtraPrefixes = "",             # ex.: "http://+:80/,https://+:8443/" - tudo que chegar por eles e redirecionado
  [string]$AllowFrom = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16",   # so redes internas (alem de localhost)
  [string]$WallTask = "NOC-VideoWall",
  [int]$MaxMemMB    = 800,
  [string]$NovoAdmin,
  [switch]$NovoCodigo
)

$ErrorActionPreference = 'Stop'
$Version     = '1.6.0'
$ManagerDir  = Join-Path $Root 'Manager'
$PauseFile   = Join-Path $Root 'pausado.json'     # existe = parede pausada (Start-Wall.ps1 respeita)
$LayoutFile  = Join-Path $Root 'layout.json'      # gravado pelo Start-Wall.ps1 (telas e blocos reais)
$CfgFile     = Join-Path $Root 'paineis.json'
$UsersFile   = Join-Path $ManagerDir 'users.json'
$AuditFile   = Join-Path $ManagerDir 'audit.log'
$WwwDir      = Join-Path $ManagerDir 'www'
$ProfilesDir = Join-Path $Root 'profiles'
$ManutStateFile = Join-Path $ManagerDir 'manutencao-estado.json'
$SetupFile   = Join-Path $ManagerDir 'setup.json'                # codigo do assistente (so o hash)   # data da ultima reabertura diaria
$StartedAt   = Get-Date
$BasePort    = 9300
$PanelCount  = 10
$SessionHours = 12
$RoleRank    = @{ visualizador = 1; operador = 2; admin = 3 }

# Chamadas locais (CDP em 127.0.0.1) nunca devem passar por proxy
[Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy

# ---------------------------------------------------------------- endereco oficial e redes permitidas
$MainPort = ([Uri]($Prefix -replace '\+|\*', 'localhost')).Port

$AllowNets = @(foreach ($c in ($AllowFrom -split ',')) {
  $c = $c.Trim(); if (-not $c) { continue }
  $parts = $c -split '/'; $bits = if ($parts.Count -gt 1) { [int]$parts[1] } else { 32 }
  if ($bits -lt 0 -or $bits -gt 32) { throw "Rede invalida em -AllowFrom: $c" }
  $b = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes(); [Array]::Reverse($b)
  # mascara sem literais hex (no PS 5.1, 0xFFFFFFFF vira -1): 2^32 - 2^(32-bits)
  $mask = [uint32]([uint64]4294967296 - [uint64][math]::Pow(2, 32 - $bits))
  [pscustomobject]@{ net = [uint32]([BitConverter]::ToUInt32($b, 0) -band $mask); mask = $mask }
})
# Vale mesmo com o firewall do Windows desligado: IP fora das redes internas recebe 403.
function Test-IpAllowed([Net.IPAddress]$Ip) {
  if ($Ip.IsIPv4MappedToIPv6) { $Ip = $Ip.MapToIPv4() }
  if ([Net.IPAddress]::IsLoopback($Ip)) { return $true }
  if ($Ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
    # IPv6 so local: link-local (fe80::/10), site-local e ULA (fc00::/7)
    return ($Ip.IsIPv6LinkLocal -or $Ip.IsIPv6SiteLocal -or (($Ip.GetAddressBytes()[0] -band 0xFE) -eq 0xFC))
  }
  $b = $Ip.GetAddressBytes(); [Array]::Reverse($b); $n = [BitConverter]::ToUInt32($b, 0)
  foreach ($a in $AllowNets) { if ($null -ne $a.mask -and [uint32]($n -band $a.mask) -eq $a.net) { return $true } }
  return $false       # sem redes validas: so localhost passa (falha fechada)
}

# ---------------------------------------------------------------- utilidades
function Read-JsonFile([string]$Path) {
  if (-not (Test-Path $Path)) { return $null }
  return (Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-JsonFile([string]$Path, $Obj) {
  $text = ConvertTo-Json -InputObject $Obj -Depth 20
  $tmp  = "$Path.tmp"
  [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
  if (Test-Path $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
}

function Write-Audit([string]$User, [string]$Ip, [string]$Action, [string]$Detail) {
  $line = "{0} | {1} | {2} | {3} | {4}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $User, $Ip, $Action, ($Detail -replace '[\r\n]', ' ')
  [IO.File]::AppendAllText($AuditFile, $line + "`r`n", (New-Object Text.UTF8Encoding $false))
}

function Copy-Deep($Obj) {
  return (ConvertTo-Json -InputObject $Obj -Depth 20 | ConvertFrom-Json)
}

# ---------------------------------------------------------------- senhas (PBKDF2-SHA256)
function New-PasswordHash([string]$Plain) {
  $salt = New-Object byte[] 16
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
  $iter = 120000
  $kdf  = New-Object Security.Cryptography.Rfc2898DeriveBytes($Plain, $salt, $iter, [Security.Cryptography.HashAlgorithmName]::SHA256)
  $hash = $kdf.GetBytes(32)
  return "pbkdf2-sha256`$$iter`$$([Convert]::ToBase64String($salt))`$$([Convert]::ToBase64String($hash))"
}

function Test-PasswordHash([string]$Plain, [string]$Stored) {
  $parts = $Stored -split '\$'
  if ($parts.Count -ne 4 -or $parts[0] -ne 'pbkdf2-sha256') { return $false }
  $iter = [int]$parts[1]; $salt = [Convert]::FromBase64String($parts[2]); $want = [Convert]::FromBase64String($parts[3])
  $kdf  = New-Object Security.Cryptography.Rfc2898DeriveBytes($Plain, $salt, $iter, [Security.Cryptography.HashAlgorithmName]::SHA256)
  $got  = $kdf.GetBytes($want.Length)
  $diff = 0
  for ($i = 0; $i -lt $want.Length; $i++) { $diff = $diff -bor ($want[$i] -bxor $got[$i]) }
  return ($diff -eq 0)
}

function New-Token {
  $b = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ---------------------------------------------------------------- usuarios
function Get-Users {
  $u = Read-JsonFile $UsersFile
  if (-not $u) { $u = [pscustomobject]@{ usuarios = @() } }
  $u.usuarios = @($u.usuarios)
  return $u
}
function Save-Users($u) { Write-JsonFile $UsersFile $u }

function Test-NewPassword([string]$p) {
  if ($p.Length -lt 10) { return "A senha precisa ter pelo menos 10 caracteres." }
  return $null
}

# ---------------------------------------------------------------- configuracao inicial (assistente web)
function Test-SetupPending { return (-not @((Get-Users).usuarios | Where-Object { $_.ativo }).Count) }
function Format-SetupCode([string]$c) { return ($c.ToUpper() -replace '[^A-Z0-9]', '') }

if ($NovoCodigo) {
  if (-not (Test-SetupPending)) { throw "Ja existe usuario cadastrado: a configuracao inicial ja foi feita. Entre pela pagina com o admin." }
  if (-not (Test-Path $ManagerDir)) { New-Item -ItemType Directory -Path $ManagerDir -Force | Out-Null }
  $alfa = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'          # 32 simbolos, sem 0/O e 1/I
  $rb = New-Object byte[] 8
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rb)
  $code = -join ($rb | ForEach-Object { $alfa[$_ % 32] })
  Write-JsonFile $SetupFile ([pscustomobject]@{
    hash = (New-PasswordHash $code); criado = (Get-Date -Format s); expira = (Get-Date).AddHours(24).ToString('s') })
  Write-Audit "console" "local" "SETUP_CODIGO_GERADO" "valido por 24 h"
  Write-Output ("CODIGO=" + $code.Substring(0, 4) + '-' + $code.Substring(4))
  return
}

# ---------------------------------------------------------------- modo: criar admin
if ($NovoAdmin) {
  if ($NovoAdmin -notmatch '^[A-Za-z0-9._-]{3,32}$') { throw "Usuario invalido (3-32: letras, numeros, . _ -)" }
  if (-not (Test-Path $ManagerDir)) { New-Item -ItemType Directory -Path $ManagerDir -Force | Out-Null }
  $s1 = Read-Host "Senha para '$NovoAdmin' (min. 10 caracteres)" -AsSecureString
  $s2 = Read-Host "Repita a senha" -AsSecureString
  $toPlain = { param($s) [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)) }
  $p1 = & $toPlain $s1; $p2 = & $toPlain $s2
  if ($p1 -ne $p2) { throw "As senhas nao conferem." }
  $err = Test-NewPassword $p1; if ($err) { throw $err }
  $users = Get-Users
  $users.usuarios = @($users.usuarios | Where-Object { $_.usuario -ne $NovoAdmin })
  $users.usuarios += [pscustomobject]@{
    usuario = $NovoAdmin; nome = "Administrador"; papel = "admin"; ativo = $true
    hash = (New-PasswordHash $p1); criado = (Get-Date -Format s)
  }
  Save-Users $users
  Write-Audit "console" "local" "ADMIN_DEFINIDO" "usuario=$NovoAdmin"
  Write-Host "Admin '$NovoAdmin' gravado em $UsersFile"
  return
}

# ---------------------------------------------------------------- configuracao (paineis/cenarios)
function Get-Config {
  $c = Read-JsonFile $CfgFile
  if (-not $c) { throw "Arquivo $CfgFile nao encontrado." }
  $c.paineis  = @($c.paineis | Sort-Object { [int]$_.n })
  $c.cenarios = @($c.cenarios)
  if (-not $c.PSObject.Properties['biblioteca']) {
    # primeira vez: a biblioteca nasce com os links ja usados nos paineis e cenarios
    $seen = @{}; $lib = @()
    foreach ($p in @($c.paineis) + @($c.cenarios | ForEach-Object { $_.paineis })) {
      if ($p -and $p.url -and -not $seen.ContainsKey([string]$p.url)) {
        $seen[[string]$p.url] = 1
        # id derivado do link (e nao aleatorio): enquanto ninguem salvar, cada leitura gera os MESMOS ids,
        # senao o id que a pagina mostra nao existe mais na hora de remover/editar (erro 'Item inexistente')
        $lib += [pscustomobject]@{ id = (Get-StableLibId ([string]$p.url)); nome = [string]$p.nome; url = [string]$p.url }
      }
    }
    $c | Add-Member -NotePropertyName biblioteca -NotePropertyValue $lib
  }
  $c.biblioteca = @($c.biblioteca)
  if (-not $c.PSObject.Properties['mosaico']) { $c | Add-Member -NotePropertyName mosaico -NotePropertyValue @() }
  $c.mosaico = @($c.mosaico | Where-Object { $_ })
  if (-not $c.PSObject.Properties['cenarioAtivo']) { $c | Add-Member -NotePropertyName cenarioAtivo -NotePropertyValue $null }
  if (-not $c.PSObject.Properties['manutencao']) {
    $c | Add-Member -NotePropertyName manutencao -NotePropertyValue ([pscustomobject]@{ autoCorrigir = $true; congeladoMin = 15; reabrirHora = '04:00' })
  }
  return $c
}

# Manutencao automatica em vigor -> cache lido pelo worker
function Update-ManutCache($c) {
  $m = $c.manutencao
  $Cache['manut'] = @{ auto = [bool]$m.autoCorrigir; congeladoMin = [int]$m.congeladoMin; reabrirHora = [string]$m.reabrirHora }
}

# Proxima reabertura diaria (texto) ou $null
function Get-NextReopen {
  $m = $Cache['manut']
  if (-not $m -or [string]$m.reabrirHora -notmatch '^([01]\d|2[0-3]):([0-5]\d)$') { return $null }
  $alvo = (Get-Date).Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
  if ($Cache['reabertoEm'] -eq (Get-Date).ToString('yyyy-MM-dd') -or $alvo.AddMinutes(30) -le (Get-Date)) { $alvo = $alvo.AddDays(1) }
  return $alvo.ToString('s')
}

# Resumo para monitoracao (Zabbix): sem sessao, so rede interna; sem links nem nomes de dashboards
function Get-Health {
  $abs = $Cache['absorvidos']; if (-not $abs) { $abs = @{} }
  $vis = Get-VisiblePanels
  $grupos = @{ offline = @(); naoResponde = @(); erro = @(); login = @(); travado = @() }
  $online = 0
  foreach ($n in $vis) {
    $st = $Cache["st$n"]; if ($st -and $st.online) { $online++ }
    $al = $Cache["al$n"]; if ($al -and $grupos.ContainsKey($al.estado)) { $grupos[$al.estado] += $n }
  }
  $pz = Get-Pause; $pc = $Cache['pc']; $cert = $Cache['cert']
  $ram = if ($pc -and $pc.memTotalMB) { [int][math]::Round((1 - $pc.memLivreMB / $pc.memTotalMB) * 100) } else { $null }
  $prob = @()
  if ($grupos.offline.Count)     { $prob += "painel(is) $($grupos.offline -join ',') fechado(s)" }
  if ($grupos.naoResponde.Count) { $prob += "painel(is) $($grupos.naoResponde -join ',') sem resposta" }
  if ($grupos.login.Count)       { $prob += "painel(is) $($grupos.login -join ',') na tela de login do Grafana" }
  if ($grupos.erro.Count)        { $prob += "painel(is) $($grupos.erro -join ',') com erro de rede" }
  if ($grupos.travado.Count)     { $prob += "painel(is) $($grupos.travado -join ',') com imagem congelada" }
  if ($null -ne $ram -and $ram -gt 90) { $prob += "RAM do PC em $ram%" }
  if ($cert -and $cert.dias -lt 30) { $prob += "certificado vence em $($cert.dias) dias" }
  $grave = $grupos.offline.Count + $grupos.naoResponde.Count + $grupos.login.Count
  $codigo = if ($grave -or ($null -ne $ram -and $ram -gt 90) -or ($cert -and $cert.dias -lt 7)) { 2 } elseif ($prob.Count) { 1 } else { 0 }
  if ($pz) { $prob += "parede pausada por $($pz.por)" }
  return [ordered]@{
    versao = $Version; agora = (Get-Date -Format s)
    codigo = $codigo; status = @('ok', 'alerta', 'critico')[$codigo]; resumo = $(if ($prob.Count) { $prob -join '; ' } else { 'ok' })
    parede = [ordered]@{
      pausada = [bool]$pz; pausaAte = $(if ($pz) { $pz.ate } else { $null })
      janelas = $vis.Count; online = $online; mescladas = $abs.Count
      offline = @($grupos.offline); naoResponde = @($grupos.naoResponde); login = @($grupos.login); erro = @($grupos.erro); travado = @($grupos.travado)
    }
    pc = $(if ($pc) { [ordered]@{ ramPct = $ram; cpu = $pc.cpu; chromeMB = $pc.chromeMB; uptimeH = $pc.uptimeH } } else { $null })
    gerenciador = [ordered]@{ memMB = $(if ($pc) { $pc.managerMB } else { $null }); uptimeMin = [int]((Get-Date) - $StartedAt).TotalMinutes; reiniciosMemoria24h = [int]$Cache['reinicios24h'] }
    certificado = $cert
    manutencao = [ordered]@{ autoCorrigir = [bool]$Cache['manut'].auto; reabertoEm = $Cache['reabertoEm']; proximaReabertura = (Get-NextReopen) }
  }
}
function New-LibId { return ('b' + ([guid]::NewGuid().ToString('N').Substring(0, 10))) }
function Get-StableLibId([string]$Url) {
  $sha = [Security.Cryptography.SHA1]::Create()
  try { $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url)) } finally { $sha.Dispose() }
  return ('b' + (-join ($h[0..4] | ForEach-Object { $_.ToString('x2') })))
}
function Save-Config($c) { Write-JsonFile $CfgFile $c }

# ---------------------------------------------------------------- mosaico (paineis mesclados)
# cfg.mosaico = @( { n = <ancora>; paineis = @(4,5,6,7); w = 3840; h = 2160; escala = 'ampliar'|'espaco' } )
# O ancora (bloco do canto superior esquerdo) ocupa a area toda; os outros ficam com a janela fechada.
function Get-Tiles {
  $lay = $null; try { $lay = Read-JsonFile $LayoutFile } catch {}
  if ($lay -and @($lay.tiles).Count -ge $PanelCount) {
    return @($lay.tiles | ForEach-Object { [pscustomobject]@{ n = [int]$_.n; x = [int]$_.x; y = [int]$_.y; w = [int]$_.w; h = [int]$_.h } })
  }
  return @(for ($i = 0; $i -lt $PanelCount; $i++) { [pscustomobject]@{ n = $i; x = [int][math]::Floor($i / 2) * 1920; y = ($i % 2) * 1080; w = 1920; h = 1080 } })
}
function Get-Mosaic($c) {
  if ($c -and $c.PSObject.Properties['mosaico']) { return @($c.mosaico | Where-Object { $_ }) }
  return @()
}
function Get-AreaSig($a) { return "$([int]$a.n):$((@($a.paineis) | ForEach-Object { [int]$_ } | Sort-Object) -join ',')|$($a.escala)" }
function Get-MosaicSig($Mosaic) { return ((@($Mosaic) | Sort-Object { [int]$_.n } | ForEach-Object { Get-AreaSig $_ }) -join ';') }
# painel absorvido -> ancora
function Get-AbsorbedMap($Mosaic) {
  $m = @{}
  foreach ($a in @($Mosaic)) { foreach ($p in @($a.paineis)) { if ([int]$p -ne [int]$a.n) { $m[[int]$p] = [int]$a.n } } }
  return $m
}

# Valida uma selecao e devolve a area (retangulo exato de blocos) ou o erro.
# Selecionar um ancora inclui a area inteira dele (permite aumentar um mosaico existente).
function Resolve-MergeArea($Tiles, $Mosaic, [int[]]$Sel, [string]$Escala) {
  $byN = @{}; foreach ($t in $Tiles) { $byN[[int]$t.n] = $t }
  $areaOf = @{}; foreach ($a in @($Mosaic)) { foreach ($p in @($a.paineis)) { $areaOf[[int]$p] = $a } }
  $cells = @{}
  foreach ($n in $Sel) {
    if (-not $byN.ContainsKey($n)) { return @{ erro = "Painel $n inexistente." } }
    if ($areaOf.ContainsKey($n)) { foreach ($p in @($areaOf[$n].paineis)) { $cells[[int]$p] = 1 } } else { $cells[$n] = 1 }
  }
  if ($cells.Count -lt 2) { return @{ erro = 'Selecione pelo menos 2 paineis.' } }
  $ts = @(foreach ($k in $cells.Keys) { $byN[$k] })
  $x0 = [long]::MaxValue; $y0 = [long]::MaxValue; $x1 = [long]::MinValue; $y1 = [long]::MinValue; [long]$soma = 0
  foreach ($t in $ts) {
    $x0 = [math]::Min($x0, [long]$t.x); $y0 = [math]::Min($y0, [long]$t.y)
    $x1 = [math]::Max($x1, [long]($t.x + $t.w)); $y1 = [math]::Max($y1, [long]($t.y + $t.h))
    $soma += [long]$t.w * [long]$t.h
  }
  foreach ($t in $Tiles) {
    $dentro = ($t.x -ge $x0) -and ($t.y -ge $y0) -and (($t.x + $t.w) -le $x1) -and (($t.y + $t.h) -le $y1)
    if ($dentro -and -not $cells.ContainsKey([int]$t.n)) {
      $ref = if ($areaOf.ContainsKey([int]$t.n)) { "o painel $($areaOf[[int]$t.n].n) (mesclado)" } else { "o painel $($t.n)" }
      return @{ erro = "A selecao nao forma um retangulo: inclua tambem $ref." }
    }
  }
  # folga de ate 8 px entre telas (o Windows as vezes deixa 1 px entre monitores no arranjo)
  if ([math]::Abs(($x1 - $x0) * ($y1 - $y0) - $soma) -gt 8 * (($x1 - $x0) + ($y1 - $y0))) { return @{ erro = 'A selecao nao forma um retangulo.' } }
  $anc = $ts | Where-Object { $_.x -eq $x0 -and $_.y -eq $y0 } | Select-Object -First 1
  if (-not $anc) { return @{ erro = 'A selecao nao forma um retangulo.' } }
  if ($Escala -ne 'espaco') { $Escala = 'ampliar' }
  return @{ area = [pscustomobject]@{ n = [int]$anc.n; paineis = @($cells.Keys | Sort-Object); w = [int]($x1 - $x0); h = [int]($y1 - $y0); escala = $Escala } }
}

# Revalida um mosaico inteiro (de cenario ou de desfazer) contra as telas atuais
function Test-Mosaic($Tiles, $Mosaic) {
  $ok = @(); $usado = @{}
  foreach ($a in @($Mosaic)) {
    $r = Resolve-MergeArea $Tiles @() ([int[]]@($a.paineis | ForEach-Object { [int]$_ })) ([string]$a.escala)
    if ($r.erro) { return @{ erro = "mosaico do painel $($a.n): $($r.erro)" } }
    foreach ($p in $r.area.paineis) {
      if ($usado.ContainsKey($p)) { return @{ erro = "painel $p em duas areas do mosaico" } }
      $usado[$p] = 1
    }
    $ok += $r.area
  }
  return @{ mosaico = $ok }
}

function Get-AreaLabel($Tiles, $a) {
  $t = $Tiles | Where-Object { $_.n -eq [int]$a.n } | Select-Object -First 1
  if (-not $t) { return '?' }
  return "$([math]::Round($a.w / $t.w))x$([math]::Round($a.h / $t.h))"
}

function Test-PanelInput($b) {
  if (-not $b.nome -or $b.nome.Length -gt 60) { return "Nome obrigatorio (ate 60 caracteres)." }
  if (-not $b.url -or $b.url.Length -gt 2048 -or $b.url -notmatch '^https?://') { return "URL invalida (precisa comecar com http:// ou https://)." }
  $z = 0.0
  if (-not [double]::TryParse([string]$b.zoom, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$z) -or $z -lt 0.25 -or $z -gt 3) {
    return "Zoom invalido (entre 0.25 e 3)."
  }
  return $null
}

# ---------------------------------------------------------------- Chrome DevTools Protocol
# Codigo compartilhado com o worker de miniaturas/status (roda em outro runspace).
$CdpCode = @'
function Get-CdpTarget([int]$N) {
  $resp = $null
  try {
    $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$($BasePort + $N)/json")
    $req.Proxy = $null; $req.Timeout = 2000; $req.ReadWriteTimeout = 2000
    $resp = $req.GetResponse()
    $sr = New-Object IO.StreamReader($resp.GetResponseStream())
    $list = $sr.ReadToEnd() | ConvertFrom-Json
    return ($list | ForEach-Object { $_ } | Where-Object { $_.type -in 'page', 'app' } | Select-Object -First 1)
  } catch { return $null } finally { if ($resp) { $resp.Close() } }
}

function Invoke-CdpCall([string]$WsUrl, [string]$Method, $Params, [int]$TimeoutSec = 10) {
  $ws = New-Object Net.WebSockets.ClientWebSocket
  $ws.Options.Proxy = $null
  $ct = [Threading.CancellationToken]::None
  try {
    if (-not $ws.ConnectAsync([Uri]$WsUrl, $ct).Wait(3000)) { throw "CDP: tempo esgotado ao conectar" }
    if ($null -eq $Params) { $Params = @{} }
    $msg   = ConvertTo-Json -Compress -Depth 10 -InputObject @{ id = 1; method = $Method; params = $Params }
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    if (-not $ws.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(3000)) { throw "CDP: tempo esgotado ao enviar" }
    $buf = New-Object byte[] 65536
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
      $ms = New-Object IO.MemoryStream
      do {
        $task = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $ct)
        if (-not $task.Wait($TimeoutSec * 1000)) { throw "CDP: tempo esgotado ao receber" }
        if ($task.Result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw "CDP: conexao fechada pelo Chrome" }
        $ms.Write($buf, 0, $task.Result.Count)
        if ($ms.Length -gt 16MB) { throw "CDP: resposta grande demais" }
      } while (-not $task.Result.EndOfMessage)
      $obj = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
      if ($obj.id -eq 1) {
        if ($obj.error) { throw "CDP: $($obj.error.message)" }
        return $obj.result
      }
    }
    throw "CDP: sem resposta"
  } finally { $ws.Dispose() }
}

Add-Type -AssemblyName System.Drawing

# Reduz o JPEG nativo para a miniatura (~480 px de largura)
function ConvertTo-Thumb([byte[]]$Jpeg, [int]$Width = 480) {
  $ms = New-Object IO.MemoryStream(, $Jpeg)
  $img = [Drawing.Image]::FromStream($ms)
  try {
    $h   = [int]($img.Height * $Width / $img.Width)
    $bmp = New-Object Drawing.Bitmap($Width, $h)
    $g   = [Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
    $g.DrawImage($img, 0, 0, $Width, $h); $g.Dispose()
    $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
    $ep  = New-Object Drawing.Imaging.EncoderParameters(1)
    $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter([Drawing.Imaging.Encoder]::Quality, [long]60)
    $out = New-Object IO.MemoryStream
    $bmp.Save($out, $enc, $ep); $bmp.Dispose()
    return , $out.ToArray()
  } finally { $img.Dispose(); $ms.Dispose() }
}

# Captura SEM clip/scale: com clip o Chrome aplica um override de resolucao temporario,
# redesenha a pagina e a tela PISCA na parede. A captura nativa so le o que ja esta desenhado.
function Get-PanelShot([int]$N, $Target, [int]$Width = 480) {
  $t = $Target; if (-not $t) { $t = Get-CdpTarget $N }
  if (-not $t) { return $null }
  $shot = Invoke-CdpCall $t.webSocketDebuggerUrl 'Page.captureScreenshot' @{ format = 'jpeg'; quality = 70; fromSurface = $true }
  return (ConvertTo-Thumb ([Convert]::FromBase64String($shot.data)) $Width)
}
'@
. ([scriptblock]::Create($CdpCode))

# ---------------------------------------------------------------- worker: status + miniaturas em cache
# O HTTP so le o cache (resposta instantanea); o worker conversa com o Chrome em segundo plano.
$Cache = [hashtable]::Synchronized(@{})
$WorkerScript = {
  [Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy
  . ([scriptblock]::Create($CdpCode))
  $last = [datetime]::MinValue; $lastPc = [datetime]::MinValue
  function Write-WDiag([string]$Text) { try { [IO.File]::AppendAllText($DiagFile, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text`r`n") } catch {} }

  # ---- manutencao automatica: estado local do worker (hashtables: alteraveis de dentro das funcoes)
  $sha = [Security.Cryptography.SHA1]::Create()
  $hash = @{}; $hashDesde = @{}; $semResp = @{}; $cond = @{}; $ultAcao = @{}; $ultTipo = @{}; $fila = @{}; $erroPg = @{}; $congAcoes = @{}
  $ws = @{ lastTask = [datetime]::MinValue; lastWd = [datetime]::MinValue; wdIdx = -1; lastCert = [datetime]::MinValue; fimFila = $null }
  try { $Cache['reabertoEm'] = [string]((Get-Content $ManutStateFile -Raw | ConvertFrom-Json).reabertoEm) } catch {}
  function Add-Evento([string]$Txt) {
    $t2 = Get-Date
    $Cache['eventos'] = @(@("$($t2.ToString('dd/MM HH:mm')) $Txt") + @($Cache['eventos'] | Where-Object { $_ }) | Select-Object -First 30)
    try { [IO.File]::AppendAllText($AuditFile, ("{0} | sistema | local | AUTO_CORRECAO | {1}`r`n" -f $t2.ToString('yyyy-MM-dd HH:mm:ss'), $Txt)) } catch {}
    Write-WDiag "AUTO $Txt"
  }
  function Invoke-WallTask([switch]$Forcar) {
    if ($Cache['pausa']) { return }
    if (-not $Forcar -and ((Get-Date) - $ws.lastTask).TotalSeconds -lt 60) { return }
    $ws.lastTask = Get-Date
    try { & schtasks.exe /Run /TN $WallTask 2>&1 | Out-Null } catch { Write-WDiag "AVISO tarefa ${WallTask}: $($_.Exception.Message)" }
  }
  function Stop-Profile([int]$N) {
    $rx = [regex]::Escape((Join-Path $ProfilesDir "painel$N")) + '(["\s]|$)'
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -match $rx } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  }

  while ($true) {
    # Protecao de memoria nesta thread (independe da thread HTTP, que pode estar presa)
    $mb = [math]::Round([Diagnostics.Process]::GetCurrentProcess().PrivateMemorySize64 / 1MB)
    $r = $Cache['_req']
    if ($r -and -not $r.logado -and ((Get-Date) - $r.t).TotalSeconds -gt 10) {
      Write-WDiag "PRESO ha >10s: $($r.p) mem=${mb}MB"; $r.logado = $true
    }
    if ($mb -gt $MaxMemMB) {
      Write-WDiag "REINICIO_MEMORIA (worker) ${mb}MB > ${MaxMemMB}MB; requisicao em curso: $(if ($r) { $r.p } else { '-' })"
      [Environment]::Exit(1)
    }
    try {
      $now  = Get-Date

      # pausa com prazo vencido: religa a parede sozinho
      $pz = $Cache['pausa']
      if ($pz -and $pz.ate -and ([datetime]$pz.ate) -le $now) {
        Remove-Item -LiteralPath $PauseFile -Force -ErrorAction SilentlyContinue
        $Cache['pausa'] = $null
        try { [IO.File]::AppendAllText($AuditFile, ("{0} | sistema | local | PAREDE_RELIGADA | prazo da pausa venceu`r`n" -f $now.ToString('yyyy-MM-dd HH:mm:ss'))) } catch {}
        try { & schtasks.exe /Run /TN $WallTask 2>&1 | Out-Null } catch { Write-WDiag "AVISO tarefa ${WallTask}: $($_.Exception.Message)" }
        foreach ($k in 0..($PanelCount - 1)) { $Cache["pedido$k"] = $now.AddSeconds(25) }
      }

      # paineis mesclados a outro (janela fechada de proposito): sem status, sem miniatura, sem pedidos
      $abs = $Cache['absorvidos']; if (-not $abs) { $abs = @{} }
      $thumbW = $Cache['thumbW']; if (-not $thumbW) { $thumbW = @{} }
      foreach ($n in @($abs.Keys)) {
        $Cache["st$n"] = [pscustomobject]@{ n = $n; online = $false; urlAtual = $null; absorvido = $abs[$n] }
        foreach ($k in "img$n", "imgT$n", "pedido$n", "recarregar$n") { $Cache.Remove($k) }
      }

      # recarregamentos agendados (Recarregar tudo = um painel a cada 1,5 s)
      foreach ($n in 0..($PanelCount - 1)) {
        $rd = $Cache["recarregar$n"]
        if ($rd -and $rd -le $now) {
          $Cache.Remove("recarregar$n")
          try {
            $t = Get-CdpTarget $n
            if ($t) { Invoke-CdpCall $t.webSocketDebuggerUrl 'Page.reload' @{ ignoreCache = $true } | Out-Null; $Cache["pedido$n"] = $now.AddSeconds(4) }
          } catch {}
        }
      }

      # status do PC (a cada 15 s)
      if (($now - $lastPc).TotalSeconds -ge 15) {
        $lastPc = $now
        try {
          $os  = Get-CimInstance Win32_OperatingSystem
          $cpu = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
          $ch  = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$ProfilesDir*" })
          $Cache['pc'] = [pscustomobject]@{
            memTotalMB = [math]::Round($os.TotalVisibleMemorySize / 1KB)
            memLivreMB = [math]::Round($os.FreePhysicalMemory / 1KB)
            cpu        = [int]$cpu
            uptimeH    = [math]::Round(($now - $os.LastBootUpTime).TotalHours, 1)
            chromeMB   = [math]::Round((($ch | Measure-Object PrivatePageCount -Sum).Sum) / 1MB)
            chromeProc = $ch.Count
            managerMB  = $mb
            t          = $now.ToString('s')
          }
        } catch {}
      }

      $man = $Cache['manut']; if (-not $man) { $man = @{ auto = $true; congeladoMin = 15; reabrirHora = '04:00' } }
      $pausada = [bool]$Cache['pausa']

      # certificado em uso na porta principal (a cada 30 min) - para o /api/saude e o Zabbix
      if (($now - $ws.lastCert).TotalMinutes -ge 30) {
        $ws.lastCert = $now
        try {
          $txt = (& netsh.exe http show sslcert 2>&1 | Out-String) -split '(\r?\n){2,}'
          $bloco = $txt | Where-Object { $_ -match ":$MainPort\b" -and $_ -match '\b[0-9a-fA-F]{40}\b' } | Select-Object -First 1
          if ($bloco -and $bloco -match '\b([0-9a-fA-F]{40})\b') {
            $c = Get-Item "Cert:\LocalMachine\My\$($Matches[1])" -ErrorAction Stop
            $Cache['cert'] = [pscustomobject]@{ dias = [int][math]::Floor(($c.NotAfter - $now).TotalDays); vence = $c.NotAfter.ToString('yyyy-MM-dd'); assunto = ($c.Subject -replace ',.*$', '') }
          }
        } catch {}
      }

      # vigia: a cada 6 s tira um print de um painel (rodizio) mesmo sem ninguem olhando - detecta
      # janela que nao responde e imagem congelada (cada painel e conferido ~1 vez por minuto)
      $wd = -1
      if (($now - $ws.lastWd).TotalSeconds -ge 6 -and -not $pausada) {
        $ws.lastWd = $now
        for ($k = 0; $k -lt $PanelCount; $k++) {
          $ws.wdIdx = ($ws.wdIdx + 1) % $PanelCount
          if (-not $abs.ContainsKey($ws.wdIdx)) { $wd = $ws.wdIdx; break }
        }
      }

      $full = ($now - $last).TotalSeconds -ge 10
      $viewed = $Cache['_visto'] -and ($Cache['_visto'] -gt $now.AddMinutes(-2))   # miniatura a cada 10 s so se alguem esta olhando
      foreach ($n in 0..($PanelCount - 1)) {
        if ($abs.ContainsKey($n)) { continue }
        $due = $Cache["pedido$n"]
        $pedido = $due -and ($due -le $now)
        if (-not $full -and -not $pedido -and $n -ne $wd) { continue }
        if ($pedido) { $Cache.Remove("pedido$n") }
        $t = Get-CdpTarget $n
        $Cache["st$n"] = [pscustomobject]@{ n = $n; online = [bool]$t; urlAtual = $(if ($t) { [string]$t.url } else { $null }) }
        if ($t -and ($viewed -or $pedido -or $n -eq $wd)) {
          try {
            $w = 480; if ($thumbW.ContainsKey($n)) { $w = [int]$thumbW[$n] }
            $img = Get-PanelShot $n $t $w
            if ($img) {
              $Cache["img$n"] = $img; $Cache["imgT$n"] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
              $semResp[$n] = 0
              $h = [BitConverter]::ToString($sha.ComputeHash($img))
              if ($hash[$n] -ne $h) {
                if ($hash[$n]) { $congAcoes[$n] = 0 }       # so zera quando a imagem MUDOU (nao na 1a imagem apos reabrir)
                $hash[$n] = $h; $hashDesde[$n] = $now
              }
            }
            if ($n -eq $wd) {
              # pagina de erro do Chrome (sem rede/DNS): a lista de abas mantem o endereco original, so a pagina sabe
              $pr = Invoke-CdpCall $t.webSocketDebuggerUrl 'Runtime.evaluate' @{ expression = 'location.protocol'; returnByValue = $true } 5
              $erroPg[$n] = ([string]$pr.result.value -eq 'chrome-error:')
            }
          } catch { if ($n -eq $wd) { $semResp[$n] = [int]$semResp[$n] + 1 } }
        } elseif (-not $t) { $Cache.Remove("img$n"); $Cache.Remove("imgT$n"); $semResp[$n] = 0; $hash.Remove($n); $erroPg.Remove($n) }
      }

      # ---- avaliacao e auto-correcao (a cada 10 s)
      if ($full) {
        foreach ($n in 0..($PanelCount - 1)) {
          if ($abs.ContainsKey($n) -or $pausada -or $fila.ContainsKey($n)) { $Cache.Remove("al$n"); $cond.Remove($n); continue }
          $s = $Cache["st$n"]; $url = if ($s) { [string]$s.urlAtual } else { '' }
          $ocupado = [bool]($Cache["pedido$n"] -or $Cache["recarregar$n"])
          # condicao bruta (a mais grave primeiro)
          $c = $null
          if (-not $s -or -not $s.online) { $c = 'offline' }
          elseif ([int]$semResp[$n] -ge 3) { $c = 'naoResponde' }
          elseif ($url -like 'chrome-error:*' -or $erroPg[$n]) { $c = 'erro' }
          elseif ($url -match '^https?://[^/]+/login') { $c = 'login' }
          elseif ($man.congeladoMin -gt 0 -and $url -match '[?&]refresh=' -and $hashDesde[$n] -and ($now - $hashDesde[$n]).TotalMinutes -ge $man.congeladoMin) { $c = 'travado' }
          if (-not $c) { $Cache.Remove("al$n"); $cond.Remove($n); continue }
          if (-not $cond[$n] -or $cond[$n].c -ne $c) { $cond[$n] = @{ c = $c; t = $now } }
          $dur = ($now - $cond[$n].t).TotalSeconds
          $limite = @{ offline = 120; naoResponde = 0; erro = 60; login = 120; travado = 0 }[$c]
          if ($dur -lt $limite) { $Cache.Remove("al$n"); continue }
          $desde = if ($c -eq 'travado') { $hashDesde[$n] } else { $cond[$n].t }
          $Cache["al$n"] = [pscustomobject]@{ estado = $c; desde = $desde.ToString('s') }

          # acao automatica (no maximo 1 a cada 5 min por painel; nunca no meio de uma acao do usuario)
          if (-not $man.auto -or $ocupado) { continue }
          if ($ultAcao[$n] -and ($now - $ultAcao[$n]).TotalMinutes -lt 5) { continue }
          # congelado: no maximo recarregar e depois reabrir; se continuar igual, so alerta (pode ser estatico de verdade)
          if ($c -eq 'travado' -and [int]$congAcoes[$n] -ge 2) { continue }
          if ($c -eq 'travado') { $congAcoes[$n] = [int]$congAcoes[$n] + 1 }
          $acao = $null
          try {
            switch ($c) {
              'offline'     { Invoke-WallTask; $acao = "painel $n fechado ha 2 min: watchdog acionado" }
              'naoResponde' { Stop-Profile $n; Start-Sleep -Milliseconds 1500; Invoke-WallTask -Forcar; $semResp[$n] = 0; $acao = "painel $n nao respondia: janela reaberta" }
              'erro'        { $t = Get-CdpTarget $n; if ($t) { Invoke-CdpCall $t.webSocketDebuggerUrl 'Page.reload' @{ ignoreCache = $true } | Out-Null }; $acao = "painel $n com erro de rede: recarregado" }
              'login'       { Invoke-WallTask -Forcar; $acao = "painel $n na tela de login do Grafana: login automatico refeito" }
              'travado'     {
                if ([int]$congAcoes[$n] -ge 2) {
                  Stop-Profile $n; Start-Sleep -Milliseconds 1500; Invoke-WallTask -Forcar; $ultTipo[$n] = 'reabrir'
                  $acao = "painel $n continuou congelado depois de recarregar: janela reaberta"
                } else {
                  $t = Get-CdpTarget $n; if ($t) { Invoke-CdpCall $t.webSocketDebuggerUrl 'Page.reload' @{ ignoreCache = $true } | Out-Null }
                  $ultTipo[$n] = 'recarregar'; $acao = "painel $n com imagem congelada ha $($man.congeladoMin) min: recarregado"
                }
                $hashDesde[$n] = $now
              }
            }
          } catch { $acao = "painel ${n}: falha ao corrigir ($c): $($_.Exception.Message)" }
          if ($acao) {
            $ultAcao[$n] = $now; if ($c -ne 'travado') { $ultTipo[$n] = $c }
            $Cache["pedido$n"] = $now.AddSeconds(15)
            Add-Evento $acao
          }
        }
      }

      # ---- reabertura diaria preventiva (libera a memoria que o Chrome acumula em dias ligado)
      if (-not $pausada -and [string]$man.reabrirHora -match '^([01]\d|2[0-3]):([0-5]\d)$') {
        $alvo = $now.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
        $hoje = $now.ToString('yyyy-MM-dd')
        if ($now -ge $alvo -and $now -lt $alvo.AddMinutes(30) -and $Cache['reabertoEm'] -ne $hoje) {
          $Cache['reabertoEm'] = $hoje
          try { [IO.File]::WriteAllText($ManutStateFile, (@{ reabertoEm = $hoje } | ConvertTo-Json)) } catch {}
          $vis = @(0..($PanelCount - 1) | Where-Object { -not $abs.ContainsKey($_) })
          for ($i = 0; $i -lt $vis.Count; $i++) { $fila[$vis[$i]] = $now.AddSeconds(40 * $i) }
          $ws.fimFila = $now.AddSeconds(40 * $vis.Count)
          $gb = if ($Cache['pc']) { '{0:N1} GB' -f ($Cache['pc'].chromeMB / 1024) } else { '?' }
          Add-Evento "reabertura diaria: $($vis.Count) janelas, uma a cada 40 s (Chrome antes: $gb)"
        }
      }
      foreach ($n in @($fila.Keys)) {
        if ($pausada) { $fila.Clear(); break }
        if ($fila[$n] -le $now) {
          $fila.Remove($n)
          Stop-Profile $n; Start-Sleep -Milliseconds 1500; Invoke-WallTask -Forcar
          $Cache["pedido$n"] = $now.AddSeconds(15); $cond.Remove($n)
        }
      }
      if ($ws.fimFila -and $now -ge $ws.fimFila -and -not $fila.Count) {
        $ws.fimFila = $null; Invoke-WallTask -Forcar      # garante que nenhuma ficou fechada
        $gb = if ($Cache['pc']) { '{0:N1} GB' -f ($Cache['pc'].chromeMB / 1024) } else { '?' }
        Add-Evento "reabertura diaria concluida (Chrome agora: $gb)"
      }

      if ($full) { $last = $now; $Cache['_ciclo'] = $now }
    } catch {
      $em = "$($_.Exception.Message) (linha $($_.InvocationInfo.ScriptLineNumber))"
      if ($Cache['_erroWorkerMsg'] -ne $em) { Write-WDiag "ERRO worker: $em"; $Cache['_erroWorkerMsg'] = $em }   # registra cada erro novo uma vez
      $Cache['_erroWorker'] = "$(Get-Date -Format s) $em"
    }
    Start-Sleep -Milliseconds 500
  }
}

function Start-Worker {
  $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
  foreach ($v in 'Cache', 'CdpCode', 'BasePort', 'PanelCount', 'MaxMemMB', 'DiagFile', 'PauseFile', 'AuditFile', 'WallTask', 'ProfilesDir', 'MainPort', 'ManutStateFile') { $rs.SessionStateProxy.SetVariable($v, (Get-Variable $v -ValueOnly)) }
  $ps = [powershell]::Create(); $ps.Runspace = $rs
  $ps.AddScript($WorkerScript) | Out-Null
  $script:WorkerHandle = $ps.BeginInvoke()
  $script:WorkerPs = $ps
}

# Pede uma miniatura nova do painel daqui a $Seg segundos (tempo da pagina carregar)
function Request-Shot([int]$N, [int]$Seg = 3) { $Cache["pedido$N"] = (Get-Date).AddSeconds($Seg) }

function Invoke-PanelNavigate([int]$N, [string]$Url) {
  $t = Get-CdpTarget $N
  if (-not $t) { return $false }
  Invoke-CdpCall $t.webSocketDebuggerUrl 'Page.navigate' @{ url = $Url } | Out-Null
  return $true
}

function Invoke-PanelReload([int]$N) {
  $t = Get-CdpTarget $N
  if (-not $t) { return $false }
  Invoke-CdpCall $t.webSocketDebuggerUrl 'Page.reload' @{ ignoreCache = $true } | Out-Null
  Request-Shot $N 4
  return $true
}

function Start-WallWatchdog {
  # Roda o Start-Wall.ps1 na sessao do usuario da parede (tarefa criada pelo instalador)
  if (Get-Pause) { return }          # pausada: nao reabre nada
  # tarefa ausente nao pode derrubar a resposta (o estado ja foi gravado; o Start-Wall aplica na proxima rodada)
  try { & schtasks.exe /Run /TN $WallTask 2>&1 | Out-Null } catch { Write-Diag "AVISO tarefa ${WallTask}: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- pausa da parede
function Get-Pause {
  $p = $Cache['pausa']
  if ($p -and $p.ate -and ([datetime]$p.ate) -le (Get-Date)) { return $null }   # venceu (o worker religa)
  return $p
}

# Fecha as janelas de todos os paineis (so os perfis do NOC)
function Stop-AllPanels {
  $like = "*$ProfilesDir\painel*"
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
    Where-Object { $_.CommandLine -like $like } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Request-AllShots([int]$Seg) { foreach ($k in 0..($PanelCount - 1)) { Request-Shot $k $Seg } }

function Stop-PanelWindow([int]$N) {
  $pattern = [regex]::Escape((Join-Path $ProfilesDir "painel$N")) + '(["\s]|$)'
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
    Where-Object { $_.CommandLine -match $pattern } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Invoke-PanelReopen([int]$N) {
  Stop-PanelWindow $N
  Start-Sleep -Milliseconds 1500
  Start-WallWatchdog
  Request-Shot $N 12
}

# Aplica a mudanca de UM painel na parede. Retorna texto com o que foi feito.
function Invoke-PanelApply($New, $Old) {
  $n = [int]$New.n
  if (Get-Pause) { return "salvo (parede pausada: vale ao religar)" }
  if ($Old -and [math]::Abs([double]$New.zoom - [double]$Old.zoom) -gt 0.001) {
    Invoke-PanelReopen $n
    return "reaberto (zoom mudou)"
  }
  if (-not $Old -or $New.url -ne $Old.url) {
    if (Invoke-PanelNavigate $n $New.url) { Request-Shot $n 4; return "link trocado" }
    Start-WallWatchdog
    return "janela offline - o watchdog reabre com o link novo"
  }
  return "sem mudanca na parede"
}

# Mosaico em vigor -> cache lido pelo worker e pelo /api/status
function Update-MosaicCache($Mosaic) {
  $tiles = Get-Tiles
  $tw = @{}
  foreach ($a in @($Mosaic)) {
    $t = $tiles | Where-Object { $_.n -eq [int]$a.n } | Select-Object -First 1
    $cols = if ($t) { [math]::Round($a.w / $t.w) } else { 2 }
    $tw[[int]$a.n] = [int](480 * [math]::Min(2, [math]::Max(1, $cols)))
  }
  $Cache['thumbW'] = $tw
  $Cache['absorvidos'] = Get-AbsorbedMap $Mosaic
  $Cache['mosaicoSig'] = Get-MosaicSig $Mosaic
}

function Get-VisiblePanels {
  $abs = $Cache['absorvidos']; if (-not $abs) { $abs = @{} }
  return @(0..($PanelCount - 1) | Where-Object { -not $abs.ContainsKey($_) })
}

# Aplica um estado completo (paineis + mosaico). Paineis de areas que mudaram sao reabertos
# (a janela muda de tamanho/zoom); os demais so trocam de link, como sempre.
function Set-WallState($cfg, $NovosPaineis, $NovoMosaico) {
  $novos = @(Copy-Deep @($NovosPaineis) | Sort-Object { [int]$_.n })
  $NovoMosaico = @($NovoMosaico | Where-Object { $_ })
  $oldS = @{}; foreach ($a in (Get-Mosaic $cfg)) { $oldS[(Get-AreaSig $a)] = $a }
  $newS = @{}; foreach ($a in $NovoMosaico) { $newS[(Get-AreaSig $a)] = $a }
  $afetados = @{}
  foreach ($k in $oldS.Keys) { if (-not $newS.ContainsKey($k)) { foreach ($p in $oldS[$k].paineis) { $afetados[[int]$p] = 1 } } }
  foreach ($k in $newS.Keys) { if (-not $oldS.ContainsKey($k)) { foreach ($p in $newS[$k].paineis) { $afetados[[int]$p] = 1 } } }
  $absNovo = Get-AbsorbedMap $NovoMosaico
  $results = @()
  foreach ($np in $novos) {
    $n = [int]$np.n
    if ($afetados.ContainsKey($n) -or $absNovo.ContainsKey($n)) { continue }   # reaberto abaixo / fica fechado
    $op = $cfg.paineis | Where-Object { [int]$_.n -eq $n } | Select-Object -First 1
    $results += "P${n}: " + (Invoke-PanelApply $np $op)
  }
  $cfg.paineis = $novos
  $cfg.mosaico = $NovoMosaico
  Save-Config $cfg
  Update-MosaicCache $NovoMosaico
  $lista = @($afetados.Keys | Sort-Object)
  if ($lista.Count) {
    if (Get-Pause) { $results += "mosaico salvo (parede pausada: vale ao religar)" }
    else {
      foreach ($n in $lista) { Stop-PanelWindow $n }
      Start-Sleep -Milliseconds 1500
      Start-WallWatchdog
      foreach ($n in $lista) { if (-not $absNovo.ContainsKey($n)) { Request-Shot $n 15 } }
      $results += "mosaico aplicado (janelas reabertas: $($lista -join ','))"
    }
  }
  return @{ detalhes = $results; afetados = $lista }
}

# Desfazer de acoes que mexem no mosaico/cenario: o servidor guarda o estado anterior (15 min)
$UndoSnaps = @{}
function New-UndoSnapshot($cfg, [string]$MinRole) {
  foreach ($k in @($UndoSnaps.Keys)) { if ($UndoSnaps[$k].exp -lt (Get-Date)) { $UndoSnaps.Remove($k) } }
  $id = (New-Token).Substring(0, 20)
  $UndoSnaps[$id] = @{
    paineis = @(Copy-Deep @($cfg.paineis)); mosaico = @(Copy-Deep @(Get-Mosaic $cfg))
    cenarioAtivo = $cfg.cenarioAtivo; papel = $MinRole; exp = (Get-Date).AddMinutes(15)
  }
  return $id
}

# ---------------------------------------------------------------- HTTP
$Sessions = @{}   # token -> @{ usuario; papel; nome; exp }
$Fails    = @{}   # ip    -> @{ count; until }

function Send-Bytes($Ctx, [int]$Status, [byte[]]$Bytes, [string]$Type) {
  $res = $Ctx.Response
  $res.StatusCode = $Status
  $res.ContentType = $Type
  $res.Headers['X-Content-Type-Options'] = 'nosniff'
  $res.Headers['X-Frame-Options'] = 'DENY'
  $res.Headers['Referrer-Policy'] = 'no-referrer'
  $res.Headers['Cache-Control'] = 'no-store'
  $res.Headers['Strict-Transport-Security'] = 'max-age=31536000'
  $res.Headers['Content-Security-Policy'] = "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'"
  $res.ContentLength64 = $Bytes.Length
  $res.OutputStream.Write($Bytes, 0, $Bytes.Length)
}

function Send-Json($Ctx, [int]$Status, $Obj) {
  $json = ConvertTo-Json -InputObject $Obj -Depth 20 -Compress
  Send-Bytes $Ctx $Status ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8'
}

function Read-Body($Ctx) {
  $req = $Ctx.Request
  if ($req.ContentLength64 -gt 65536) { throw "Corpo da requisicao grande demais." }
  $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
  $text = $sr.ReadToEnd()
  if (-not $text) { return [pscustomobject]@{} }
  return ($text | ConvertFrom-Json)
}

function Get-Session($Ctx) {
  $c = $Ctx.Request.Cookies['noc_sid']
  if (-not $c) { return $null }
  $s = $Sessions[$c.Value]
  if (-not $s) { return $null }
  if ($s.exp -lt (Get-Date)) { $Sessions.Remove($c.Value); return $null }
  return $s
}

function Remove-UserSessions([string]$User) {
  foreach ($k in @($Sessions.Keys)) { if ($Sessions[$k].usuario -eq $User) { $Sessions.Remove($k) } }
}

function Test-Role($Sess, [string]$Min) { return ($RoleRank[$Sess.papel] -ge $RoleRank[$Min]) }

function Get-PublicUser($u) {
  return [pscustomobject]@{ usuario = $u.usuario; nome = $u.nome; papel = $u.papel; ativo = [bool]$u.ativo; criado = $u.criado }
}

# ---------------------------------------------------------------- assistente de configuracao
$SetupTokens = @{}   # token -> validade (depois de informar o codigo)

function Find-Chrome {
  return (@(
    (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
}

function Get-SetupInfo {
  $logado = $null; try { $logado = (Get-CimInstance Win32_ComputerSystem).UserName } catch {}
  # contas locais ativas, sem as internas (Convidado -501, DefaultAccount -503, WDAGUtilityAccount -504)
  $locais = @()
  try { $locais = @(Get-LocalUser | Where-Object { $_.Enabled -and $_.SID.Value -notmatch '-(501|503|504)$' } | ForEach-Object { "$env:COMPUTERNAME\$($_.Name)" }) } catch {}
  $ips = @()
  try { $ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { $_.IPAddress }) } catch {}
  $telas = $null
  try {
    $lay = Read-JsonFile $LayoutFile
    if ($lay) { $telas = @{ gerado = [string]$lay.gerado; telas = @($lay.telas | ForEach-Object { "$($_.w)x$($_.h)" }); paineis = @($lay.tiles).Count } }
  } catch {}
  $auto = $null
  try {
    $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
    if ([string]$wl.AutoAdminLogon -eq '1' -and $wl.DefaultUserName) { $auto = "$($wl.DefaultDomainName)\$($wl.DefaultUserName)" }
  } catch {}
  $tarefa = $null
  try { $tarefa = (Get-ScheduledTask -TaskName $WallTask -ErrorAction Stop).Principal.UserId } catch {}
  return @{ pc = $env:COMPUTERNAME; ips = $ips; chrome = (Find-Chrome); logado = $logado; usuarios = $locais
            telas = $telas; esperado = $PanelCount; autoLogon = $auto; tarefaParede = $tarefa; versao = $Version }
}

function Initialize-ScryWin {
  if ('ScryWin' -as [type]) { return }
  Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class ScryWin {
  [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool LogonUser(string user, string domain, string pass, int type, int provider, out IntPtr token);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  // 0 = senha confere; senao, o codigo de erro do Windows
  public static int CheckLogon(string user, string domain, string pass) {
    IntPtr t;
    if (LogonUser(user, domain, pass, 2, 0, out t)) { CloseHandle(t); return 0; }
    return Marshal.GetLastWin32Error();
  }
  [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
  [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public int Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
  [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attr, int access, out IntPtr handle);
  [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr handle, ref LSA_UNICODE_STRING key, ref LSA_UNICODE_STRING data);
  [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
  [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
  static LSA_UNICODE_STRING Str(string s) {
    LSA_UNICODE_STRING u = new LSA_UNICODE_STRING();
    u.Buffer = Marshal.StringToHGlobalUni(s); u.Length = (ushort)(s.Length * 2); u.MaximumLength = (ushort)(s.Length * 2 + 2);
    return u;
  }
  // Grava um segredo LSA: o mesmo lugar onde o Autologon da Microsoft guarda a senha do logon automatico
  public static int StoreSecret(string key, string value) {
    LSA_OBJECT_ATTRIBUTES a = new LSA_OBJECT_ATTRIBUTES(); a.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
    IntPtr h; uint st = LsaOpenPolicy(IntPtr.Zero, ref a, 0x000F0FFF, out h);
    if (st != 0) return LsaNtStatusToWinError(st);
    LSA_UNICODE_STRING k = Str(key), d = Str(value);
    try { st = LsaStorePrivateData(h, ref k, ref d); return st == 0 ? 0 : LsaNtStatusToWinError(st); }
    finally { Marshal.FreeHGlobal(k.Buffer); Marshal.FreeHGlobal(d.Buffer); LsaClose(h); }
  }
}
"@
}

# Tarefa da parede: mesma definicao do Install-NocManager.ps1 (Start-Wall.ps1 no logon e a cada 5 min, sem janela)
function Register-WallTask([string]$WallUser) {
  $startWall = Join-Path $Root 'Start-Wall.ps1'
  $vbs = Join-Path $Root 'run-hidden.vbs'
  $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""$startWall"""
  Set-Content -Path $vbs -Encoding ASCII -Value ("CreateObject(""WScript.Shell"").Run ""{0}"", 0, False" -f ($cmd -replace '"', '""'))
  $aWall  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
  $tLogon = New-ScheduledTaskTrigger -AtLogOn -User $WallUser
  $tRep   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
  $pWall  = New-ScheduledTaskPrincipal -UserId $WallUser -LogonType Interactive -RunLevel Limited
  $sWall  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  Register-ScheduledTask -TaskName $WallTask -Action $aWall -Trigger @($tLogon, $tRep) -Principal $pWall -Settings $sWall -Force | Out-Null
}

function Set-AutoLogon([string]$WallUser, [string]$Senha) {
  Initialize-ScryWin
  $dom, $usr = $WallUser -split '\\', 2
  $r = [ScryWin]::StoreSecret('DefaultPassword', $Senha)
  if ($r -ne 0) { throw "Nao consegui gravar a senha do logon automatico (erro $r do Windows)." }
  $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  Set-ItemProperty -Path $wl -Name AutoAdminLogon -Value '1' -Type String
  Set-ItemProperty -Path $wl -Name DefaultUserName -Value $usr -Type String
  Set-ItemProperty -Path $wl -Name DefaultDomainName -Value $dom -Type String
  # a senha nunca fica em texto puro no registro: so no segredo LSA
  Remove-ItemProperty -Path $wl -Name DefaultPassword -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $wl -Name AutoLogonCount -ErrorAction SilentlyContinue
}

function Register-Fail([string]$Ip) {
  $f = $Fails[$Ip]
  if (-not $f -or $f.last -lt (Get-Date).AddMinutes(-15)) { $f = @{ count = 0; until = [datetime]::MinValue; last = Get-Date } }
  $f.count++; $f.last = Get-Date
  if ($f.count -ge 5) { $f.until = (Get-Date).AddMinutes(5); $f.count = 0 }
  $Fails[$Ip] = $f
  Start-Sleep -Milliseconds 700
}

function Invoke-SetupRoute($Ctx, [string]$path, [string]$method, [string]$ip) {
  $req = $Ctx.Request
  if ($method -eq 'GET' -and ($path -eq '' -or $path -eq '/index.html' -or $path -eq '/setup.html')) {
    Send-Bytes $Ctx 200 ([IO.File]::ReadAllBytes((Join-Path $WwwDir 'setup.html'))) 'text/html; charset=utf-8'; return
  }
  if ($path -eq '/api/versao' -and $method -eq 'GET') { Send-Json $Ctx 200 @{ versao = $Version; configuracao = $true }; return }
  if ($path -notlike '/api/setup/*') { Send-Json $Ctx 409 @{ erro = 'Configuracao inicial pendente. Abra a pagina inicial do Scry.'; setup = $true }; return }
  if ($method -ne 'GET' -and $req.Headers['X-NOC'] -ne '1') { Send-Json $Ctx 403 @{ erro = 'Requisicao recusada.' }; return }

  $c = $req.Cookies['scry_setup']
  $autorizado = [bool]($c -and $SetupTokens[$c.Value] -and $SetupTokens[$c.Value] -gt (Get-Date))

  if ($path -eq '/api/setup/estado' -and $method -eq 'GET') {
    Send-Json $Ctx 200 @{ pendente = $true; autorizado = $autorizado; pc = $env:COMPUTERNAME; versao = $Version }; return
  }
  if ($path -eq '/api/setup/codigo' -and $method -eq 'POST') {
    $f = $Fails[$ip]
    if ($f -and $f.until -gt (Get-Date)) { Send-Json $Ctx 429 @{ erro = 'Muitas tentativas. Aguarde alguns minutos.' }; return }
    $b = Read-Body $Ctx
    $st = $null; try { $st = Read-JsonFile $SetupFile } catch {}
    $ok = $false
    if ($st -and $st.hash -and ([datetime]$st.expira) -gt (Get-Date)) { $ok = Test-PasswordHash (Format-SetupCode ([string]$b.codigo)) ([string]$st.hash) }
    if (-not $ok) {
      Write-Audit 'assistente' $ip 'SETUP_CODIGO_INVALIDO' ''
      Register-Fail $ip
      Send-Json $Ctx 401 @{ erro = 'Codigo invalido ou vencido. Rode o comando de instalacao de novo para gerar outro.' }; return
    }
    $Fails.Remove($ip)
    $t = New-Token; $SetupTokens[$t] = (Get-Date).AddHours(2)
    $Ctx.Response.Headers.Add('Set-Cookie', "scry_setup=$t; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=7200")
    Write-Audit 'assistente' $ip 'SETUP_CODIGO_OK' ''
    Send-Json $Ctx 200 @{ ok = $true }; return
  }
  if (-not $autorizado) { Send-Json $Ctx 401 @{ erro = 'Informe o codigo de instalacao.'; codigo = $true }; return }

  if ($path -eq '/api/setup/info' -and $method -eq 'GET') { Send-Json $Ctx 200 (Get-SetupInfo); return }

  if ($path -eq '/api/setup/concluir' -and $method -eq 'POST') {
    $b = Read-Body $Ctx
    $adm = ([string]$b.admin.usuario).Trim()
    if ($adm -notmatch '^[A-Za-z0-9._-]{3,32}$') { Send-Json $Ctx 400 @{ erro = 'Usuario do Scry invalido (3 a 32: letras, numeros, . _ -).' }; return }
    $err = Test-NewPassword ([string]$b.admin.senha); if ($err) { Send-Json $Ctx 400 @{ erro = $err }; return }
    $wall = ([string]$b.parede.usuario).Trim()
    if (-not $wall) { Send-Json $Ctx 400 @{ erro = 'Informe o usuario do Windows que fica logado na parede.' }; return }
    if ($wall -notlike '*\*') { $wall = "$env:COMPUTERNAME\$wall" }
    try { $null = (New-Object Security.Principal.NTAccount($wall)).Translate([Security.Principal.SecurityIdentifier]) }
    catch { Send-Json $Ctx 400 @{ erro = "Usuario do Windows nao encontrado: $wall" }; return }
    $auto = [bool]$b.autoLogon.ativar
    if ($auto) {
      Initialize-ScryWin
      $dom, $usr = $wall -split '\\', 2
      $r = [ScryWin]::CheckLogon($usr, $dom, [string]$b.autoLogon.senha)
      if ($r -ne 0) {
        Write-Audit 'assistente' $ip 'SETUP_SENHA_PAREDE_INVALIDA' "usuario=$wall erro=$r"
        Send-Json $Ctx 400 @{ erro = "A senha do usuario $wall nao confere (erro $r do Windows)." }; return
      }
    }
    # parede e logon automatico antes do admin: se algo falhar, o assistente continua disponivel
    try { Register-WallTask $wall } catch { Send-Json $Ctx 500 @{ erro = "Nao consegui criar a tarefa da parede: $($_.Exception.Message)" }; return }
    if ($auto) { try { Set-AutoLogon $wall ([string]$b.autoLogon.senha) } catch { Send-Json $Ctx 500 @{ erro = $_.Exception.Message }; return } }
    # admin: a partir daqui o Scry sai do modo de configuracao
    $users = Get-Users
    $users.usuarios = @($users.usuarios | Where-Object { $_.usuario -ne $adm })
    $users.usuarios += [pscustomobject]@{
      usuario = $adm; nome = "Administrador"; papel = "admin"; ativo = $true
      hash = (New-PasswordHash ([string]$b.admin.senha)); criado = (Get-Date -Format s)
    }
    Save-Users $users
    Remove-Item -LiteralPath $SetupFile -Force -ErrorAction SilentlyContinue
    $SetupTokens.Clear()
    $script:SetupPending = $false
    $Ctx.Response.Headers.Add('Set-Cookie', 'scry_setup=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0')
    Write-Audit 'assistente' $ip 'SETUP_CONCLUIDO' "admin=$adm parede=$wall autoLogon=$auto"
    # se o usuario da parede ja estiver logado, as janelas abrem agora
    & schtasks.exe /Run /TN $WallTask 2>&1 | Out-Null
    $reiniciar = [bool]$b.reiniciar
    if ($reiniciar) { Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r /t 20 /c "Scry: reiniciando para concluir a configuracao"' -WindowStyle Hidden }
    Send-Json $Ctx 200 @{ ok = $true; admin = $adm; parede = $wall; autoLogon = $auto; reiniciando = $reiniciar }; return
  }
  Send-Json $Ctx 404 @{ erro = 'Rota inexistente.' }
}

function Invoke-Route($Ctx) {
  $req    = $Ctx.Request
  $path   = $req.Url.AbsolutePath.TrimEnd('/')
  $method = $req.HttpMethod
  $ip     = $req.RemoteEndPoint.Address.ToString()

  # ---- http:// ou porta antiga: redireciona para o endereco oficial
  if ($req.Url.Scheme -ne 'https' -or $req.Url.Port -ne $MainPort) {
    $base = if ($PublicUrl) { $PublicUrl.TrimEnd('/') } else { "https://$($req.Url.Host)" + $(if ($MainPort -ne 443) { ":$MainPort" } else { '' }) }
    $Ctx.Response.StatusCode = 301
    $Ctx.Response.RedirectLocation = $base + $req.Url.PathAndQuery
    return
  }

  # ---- sem nenhum usuario: assistente de configuracao inicial
  if ($script:SetupPending) {
    if (-not (Test-SetupPending)) { $script:SetupPending = $false }      # admin criado por outro caminho (-NovoAdmin)
    else { Invoke-SetupRoute $Ctx $path $method $ip; return }
  }

  # ---- arquivos estaticos (so a pagina)
  if ($method -eq 'GET' -and ($path -eq '' -or $path -eq '/index.html')) {
    Send-Bytes $Ctx 200 ([IO.File]::ReadAllBytes((Join-Path $WwwDir 'index.html'))) 'text/html; charset=utf-8'
    return
  }
  if ($path -notlike '/api/*') { Send-Json $Ctx 404 @{ erro = 'Nao encontrado' }; return }

  # ---- versao (sem sessao: usada pelo Update/Test e pela tela de login)
  if ($path -eq '/api/versao' -and $method -eq 'GET') { Send-Json $Ctx 200 @{ versao = $Version }; return }
  # ---- saude (sem sessao, so rede interna): monitoracao pelo Zabbix
  if ($path -eq '/api/saude' -and $method -eq 'GET') { Send-Json $Ctx 200 (Get-Health); return }

  # ---- login (unica rota sem sessao)
  if ($path -eq '/api/login' -and $method -eq 'POST') {
    $f = $Fails[$ip]
    if ($f -and $f.until -gt (Get-Date)) { Send-Json $Ctx 429 @{ erro = 'Muitas tentativas. Aguarde alguns minutos.' }; return }
    $b = Read-Body $Ctx
    $u = (Get-Users).usuarios | Where-Object { $_.usuario -eq $b.usuario -and $_.ativo } | Select-Object -First 1
    if (-not $u -or -not (Test-PasswordHash ([string]$b.senha) $u.hash)) {
      # zera o contador se a ultima falha foi ha mais de 15 min
      if (-not $f -or $f.last -lt (Get-Date).AddMinutes(-15)) { $f = @{ count = 0; until = [datetime]::MinValue; last = Get-Date } }
      $f.count++
      $f.last = Get-Date
      if ($f.count -ge 5) { $f.until = (Get-Date).AddMinutes(5); $f.count = 0 }
      $Fails[$ip] = $f
      Write-Audit ([string]$b.usuario) $ip 'LOGIN_FALHOU' ''
      Start-Sleep -Milliseconds 700
      Send-Json $Ctx 401 @{ erro = 'Usuario ou senha invalidos.' }
      return
    }
    $Fails.Remove($ip)
    $token = New-Token
    $Sessions[$token] = @{ usuario = $u.usuario; nome = $u.nome; papel = $u.papel; exp = (Get-Date).AddHours($SessionHours) }
    $Ctx.Response.Headers.Add('Set-Cookie', "noc_sid=$token; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=$($SessionHours * 3600)")
    Write-Audit $u.usuario $ip 'LOGIN' ''
    Send-Json $Ctx 200 @{ usuario = $u.usuario; nome = $u.nome; papel = $u.papel }
    return
  }

  # ---- daqui para baixo exige sessao
  $s = Get-Session $Ctx
  if (-not $s) { Send-Json $Ctx 401 @{ erro = 'Sessao expirada. Entre novamente.' }; return }
  # protecao CSRF: toda alteracao precisa do cabecalho que so a nossa pagina envia
  if ($method -ne 'GET' -and $req.Headers['X-NOC'] -ne '1') { Send-Json $Ctx 403 @{ erro = 'Requisicao recusada.' }; return }
  $who = $s.usuario

  if ($path -eq '/api/me' -and $method -eq 'GET') {
    Send-Json $Ctx 200 @{ usuario = $s.usuario; nome = $s.nome; papel = $s.papel }; return
  }
  if ($path -eq '/api/logout' -and $method -eq 'POST') {
    $c = $req.Cookies['noc_sid']; if ($c) { $Sessions.Remove($c.Value) }
    $Ctx.Response.Headers.Add('Set-Cookie', 'noc_sid=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0')
    Write-Audit $who $ip 'LOGOUT' ''
    Send-Json $Ctx 200 @{ ok = $true }; return
  }
  if ($path -eq '/api/me/senha' -and $method -eq 'POST') {
    $b = Read-Body $Ctx
    $users = Get-Users
    $u = $users.usuarios | Where-Object { $_.usuario -eq $who } | Select-Object -First 1
    if (-not $u -or -not (Test-PasswordHash ([string]$b.atual) $u.hash)) { Send-Json $Ctx 400 @{ erro = 'Senha atual incorreta.' }; return }
    $err = Test-NewPassword ([string]$b.nova); if ($err) { Send-Json $Ctx 400 @{ erro = $err }; return }
    $u.hash = New-PasswordHash ([string]$b.nova)
    Save-Users $users
    Write-Audit $who $ip 'SENHA_ALTERADA' 'propria'
    Send-Json $Ctx 200 @{ ok = $true }; return
  }

  # ---- estado e status
  if ($path -eq '/api/estado' -and $method -eq 'GET') {
    $o = Get-Config
    $lay = $null; try { $lay = Read-JsonFile $LayoutFile } catch {}
    $o | Add-Member -NotePropertyName layout -NotePropertyValue $lay -Force
    $o | Add-Member -NotePropertyName mosaicoSig -NotePropertyValue (Get-MosaicSig $o.mosaico) -Force
    Send-Json $Ctx 200 $o; return
  }
  if ($path -eq '/api/status' -and $method -eq 'GET') {
    $Cache['_visto'] = Get-Date
    $abs = $Cache['absorvidos']; if (-not $abs) { $abs = @{} }
    $st = foreach ($n in 0..($PanelCount - 1)) {
      $c = $Cache["st$n"]
      $ab = if ($abs.ContainsKey($n)) { $abs[$n] } else { $null }
      [pscustomobject]@{
        n         = $n
        online    = [bool]($null -eq $ab -and $c -and $c.online)
        urlAtual  = $(if ($c -and $null -eq $ab) { $c.urlAtual } else { $null })
        imgT      = $(if ($null -eq $ab) { $Cache["imgT$n"] } else { $null })
        pendente  = [bool]($null -eq $ab -and ($Cache["pedido$n"] -or $Cache["recarregar$n"]))
        absorvido = $ab
        alerta    = $(if ($null -eq $ab) { $Cache["al$n"] } else { $null })
      }
    }
    Send-Json $Ctx 200 @{ versao = $Version; agora = (Get-Date -Format s); agoraMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                          paineis = @($st); pc = $Cache['pc']; pausa = (Get-Pause); mosaicoSig = [string]$Cache['mosaicoSig']
                          manut = @{ auto = [bool]$Cache['manut'].auto; proxima = (Get-NextReopen); ultimo = @($Cache['eventos'] | Select-Object -First 1)[0] } }
    return
  }

  # ---- manutencao automatica (ver: todos; alterar: admin)
  if ($path -eq '/api/manutencao') {
    if ($method -eq 'GET') {
      Send-Json $Ctx 200 @{ config = (Get-Config).manutencao; eventos = @($Cache['eventos'] | Where-Object { $_ }); reabertoEm = $Cache['reabertoEm']; proxima = (Get-NextReopen) }; return
    }
    if ($method -eq 'PUT') {
      if (-not (Test-Role $s 'admin')) { Send-Json $Ctx 403 @{ erro = 'Somente administradores.' }; return }
      $b = Read-Body $Ctx
      $min = -1; [void][int]::TryParse([string]$b.congeladoMin, [ref]$min)
      if ($min -lt 0 -or $min -gt 240) { Send-Json $Ctx 400 @{ erro = 'Minutos para considerar congelado: 0 (desliga) a 240.' }; return }
      $hora = ([string]$b.reabrirHora).Trim()
      if ($hora -and $hora -notmatch '^([01]\d|2[0-3]):([0-5]\d)$') { Send-Json $Ctx 400 @{ erro = 'Horario invalido (HH:MM ou vazio para desligar).' }; return }
      $cfg = Get-Config
      $cfg.manutencao = [pscustomobject]@{ autoCorrigir = [bool]$b.autoCorrigir; congeladoMin = $min; reabrirHora = $hora }
      Save-Config $cfg
      Update-ManutCache $cfg
      Write-Audit $who $ip 'MANUTENCAO_ALTERADA' "auto=$([bool]$b.autoCorrigir) congeladoMin=$min reabrirHora=$(if ($hora) { $hora } else { 'desligada' })"
      Send-Json $Ctx 200 @{ ok = $true; msg = 'Manutencao automatica salva.' }; return
    }
  }

  # ---- parede inteira
  if ($path -match '^/api/parede/(pausar|religar|recarregar|reabrir)$' -and $method -eq 'POST') {
    $acao = $Matches[1]
    if (-not (Test-Role $s 'operador')) { Send-Json $Ctx 403 @{ erro = 'Sem permissao.' }; return }
    switch ($acao) {
      'pausar' {
        $b = Read-Body $Ctx
        $min = 0; [void][int]::TryParse([string]$b.minutos, [ref]$min)
        if ($min -lt 0 -or $min -gt 1440) { Send-Json $Ctx 400 @{ erro = 'Prazo invalido (0 a 1440 minutos).' }; return }
        $p = [pscustomobject]@{ desde = (Get-Date -Format s); ate = $(if ($min -gt 0) { (Get-Date).AddMinutes($min).ToString('s') } else { $null }); por = $who }
        Write-JsonFile $PauseFile $p
        $Cache['pausa'] = $p
        Stop-AllPanels
        $prazo = $(if ($min -gt 0) { "por $min min" } else { 'ate religar' })
        Write-Audit $who $ip 'PAREDE_PAUSADA' $prazo
        Send-Json $Ctx 200 @{ ok = $true; msg = "Parede pausada $prazo." }; return
      }
      'religar' {
        Remove-Item -LiteralPath $PauseFile -Force -ErrorAction SilentlyContinue
        $Cache['pausa'] = $null
        Start-WallWatchdog
        Request-AllShots 25
        Write-Audit $who $ip 'PAREDE_RELIGADA' ''
        Send-Json $Ctx 200 @{ ok = $true; msg = 'Religando a parede (as janelas abrem em alguns segundos).' }; return
      }
      'recarregar' {
        if (Get-Pause) { Send-Json $Ctx 400 @{ erro = 'A parede esta pausada.' }; return }
        $t0 = Get-Date; $vis = Get-VisiblePanels
        for ($i = 0; $i -lt $vis.Count; $i++) { $Cache["recarregar$($vis[$i])"] = $t0.AddMilliseconds(1500 * $i) }
        Write-Audit $who $ip 'PAREDE_RECARREGADA' ''
        Send-Json $Ctx 200 @{ ok = $true; msg = "Recarregando os $($vis.Count) paineis, um a cada 1,5 s." }; return
      }
      'reabrir' {
        if (Get-Pause) { Send-Json $Ctx 400 @{ erro = 'A parede esta pausada.' }; return }
        Stop-AllPanels
        Start-Sleep -Milliseconds 1500
        Start-WallWatchdog
        Request-AllShots 30
        Write-Audit $who $ip 'PAREDE_REABERTA' ''
        Send-Json $Ctx 200 @{ ok = $true; msg = 'Reabrindo todas as janelas (leva ate 1 minuto).' }; return
      }
    }
  }

  # ---- varios paineis de uma vez (trocar posicao, arrastar da biblioteca, desfazer)
  if ($path -eq '/api/paineis/lote' -and $method -eq 'POST') {
    if (-not (Test-Role $s 'operador')) { Send-Json $Ctx 403 @{ erro = 'Sem permissao.' }; return }
    $b = Read-Body $Ctx
    $itens = @($b.paineis)
    if ($itens.Count -lt 1 -or $itens.Count -gt $PanelCount) { Send-Json $Ctx 400 @{ erro = 'Informe de 1 a 10 paineis.' }; return }
    $cfg = Get-Config
    $abs = Get-AbsorbedMap (Get-Mosaic $cfg)
    foreach ($it in $itens) {
      $nn = -1
      if (-not [int]::TryParse([string]$it.n, [ref]$nn) -or $nn -lt 0 -or $nn -ge $PanelCount) { Send-Json $Ctx 400 @{ erro = 'Painel invalido.' }; return }
      if ($abs.ContainsKey($nn)) { Send-Json $Ctx 400 @{ erro = "O painel $nn esta mesclado ao painel $($abs[$nn]). Use o painel $($abs[$nn]) ou separe o mosaico." }; return }
      $err = Test-PanelInput $it; if ($err) { Send-Json $Ctx 400 @{ erro = "Painel ${nn}: $err" }; return }
    }
    $anteriores = @(); $res = @()
    foreach ($it in $itens) {
      $nn  = [int]$it.n
      $old = Copy-Deep ($cfg.paineis | Where-Object { [int]$_.n -eq $nn } | Select-Object -First 1)
      $new = [pscustomobject]@{ n = $nn; nome = [string]$it.nome; url = [string]$it.url
               zoom = [double]::Parse([string]$it.zoom, [Globalization.CultureInfo]::InvariantCulture) }
      if ($old) { $anteriores += $old }
      $cfg.paineis = @(@($cfg.paineis | Where-Object { [int]$_.n -ne $nn }) + $new | Sort-Object { [int]$_.n })
      $res += "P${nn}: " + (Invoke-PanelApply $new $old)
    }
    Save-Config $cfg
    $motivo = ([string]$b.motivo) -replace '[^A-Za-z0-9 _-]', ''
    Write-Audit $who $ip 'PAINEIS_LOTE' "motivo=$motivo :: $($res -join '; ')"
    Send-Json $Ctx 200 @{ ok = $true; msg = "Parede atualizada ($($itens.Count) painel(is))."; detalhes = $res; anteriores = @($anteriores) }; return
  }

  # ---- biblioteca de dashboards
  if ($path -match '^/api/biblioteca(/([a-z0-9]+))?$') {
    $bid = $Matches[2]
    if (-not (Test-Role $s 'operador')) { Send-Json $Ctx 403 @{ erro = 'Sem permissao.' }; return }
    $cfg = Get-Config
    if (-not $bid -and $method -eq 'POST') {
      $b = Read-Body $Ctx
      $b | Add-Member -NotePropertyName zoom -NotePropertyValue 1 -Force      # so para reaproveitar a validacao
      $err = Test-PanelInput $b; if ($err) { Send-Json $Ctx 400 @{ erro = $err }; return }
      if ($cfg.biblioteca | Where-Object { $_.url -eq [string]$b.url }) { Send-Json $Ctx 400 @{ erro = 'Este link ja esta na biblioteca.' }; return }
      $item = [pscustomobject]@{ id = (New-LibId); nome = [string]$b.nome; url = [string]$b.url }
      $cfg.biblioteca = @($cfg.biblioteca) + $item
      Save-Config $cfg
      Write-Audit $who $ip 'BIBLIOTECA_ADICIONADO' "nome=$($item.nome) url=$($item.url)"
      Send-Json $Ctx 200 @{ ok = $true; id = $item.id; msg = "'$($item.nome)' adicionado a biblioteca." }; return
    }
    $item = $cfg.biblioteca | Where-Object { $_.id -eq $bid } | Select-Object -First 1
    if ($bid -and -not $item) { Send-Json $Ctx 404 @{ erro = 'Item inexistente.' }; return }
    if ($bid -and $method -eq 'PUT') {
      $b = Read-Body $Ctx
      $b | Add-Member -NotePropertyName zoom -NotePropertyValue 1 -Force
      $err = Test-PanelInput $b; if ($err) { Send-Json $Ctx 400 @{ erro = $err }; return }
      $item.nome = [string]$b.nome; $item.url = [string]$b.url
      Save-Config $cfg
      Write-Audit $who $ip 'BIBLIOTECA_ALTERADO' "id=$bid nome=$($item.nome)"
      Send-Json $Ctx 200 @{ ok = $true; msg = "'$($item.nome)' salvo." }; return
    }
    if ($bid -and $method -eq 'DELETE') {
      $cfg.biblioteca = @($cfg.biblioteca | Where-Object { $_.id -ne $bid })
      Save-Config $cfg
      Write-Audit $who $ip 'BIBLIOTECA_REMOVIDO' "id=$bid nome=$($item.nome)"
      Send-Json $Ctx 200 @{ ok = $true; msg = "'$($item.nome)' removido da biblioteca." }; return
    }
  }

  # ---- paineis
  if ($path -match '^/api/paineis/(\d)(/(recarregar|reabrir|print))?$') {
    $n = [int]$Matches[1]; $acao = $Matches[3]
    if ($n -ge $PanelCount) { Send-Json $Ctx 404 @{ erro = 'Painel inexistente.' }; return }

    if ($acao -eq 'print' -and $method -eq 'GET') {
      $Cache['_visto'] = Get-Date
      $img = $Cache["img$n"]
      if (-not $img) { Send-Json $Ctx 404 @{ erro = 'Miniatura indisponivel (painel offline ou carregando).' }; return }
      Send-Bytes $Ctx 200 $img 'image/jpeg'; return
    }
    if (-not (Test-Role $s 'operador')) { Send-Json $Ctx 403 @{ erro = 'Sem permissao.' }; return }
    $absP = $Cache['absorvidos']
    if ($absP -and $absP.ContainsKey($n)) { Send-Json $Ctx 400 @{ erro = "O painel $n esta mesclado ao painel $($absP[$n]). Use o painel $($absP[$n]) ou separe o mosaico." }; return }

    if ($acao -eq 'recarregar' -and $method -eq 'POST') {
      $ok = Invoke-PanelReload $n
      Write-Audit $who $ip 'PAINEL_RECARREGADO' "n=$n"
      Send-Json $Ctx 200 @{ ok = $ok; msg = $(if ($ok) { 'Recarregado.' } else { 'Painel offline.' }) }; return
    }
    if ($acao -eq 'reabrir' -and $method -eq 'POST') {
      if (Get-Pause) { Send-Json $Ctx 400 @{ erro = 'A parede esta pausada.' }; return }
      Invoke-PanelReopen $n
      Write-Audit $who $ip 'PAINEL_REABERTO' "n=$n"
      Send-Json $Ctx 200 @{ ok = $true; msg = 'Janela sendo reaberta (alguns segundos).' }; return
    }
    if (-not $acao -and $method -eq 'PUT') {
      $b = Read-Body $Ctx
      $err = Test-PanelInput $b; if ($err) { Send-Json $Ctx 400 @{ erro = $err }; return }
      $cfg = Get-Config
      $old = Copy-Deep ($cfg.paineis | Where-Object { [int]$_.n -eq $n } | Select-Object -First 1)
      $new = [pscustomobject]@{ n = $n; nome = [string]$b.nome; url = [string]$b.url
               zoom = [double]::Parse([string]$b.zoom, [Globalization.CultureInfo]::InvariantCulture) }
      $cfg.paineis = @(@($cfg.paineis | Where-Object { [int]$_.n -ne $n }) + $new | Sort-Object { [int]$_.n })
      Save-Config $cfg
      $r = Invoke-PanelApply $new $old
      Write-Audit $who $ip 'PAINEL_ALTERADO' "n=$n nome=$($new.nome) zoom=$($new.zoom) url=$($new.url) [$r]"
      Send-Json $Ctx 200 @{ ok = $true; msg = "Painel $n salvo: $r."; anteriores = @($old) }; return
    }
  }

  # ---- mosaico (somente admin): mesclar paineis num retangulo ou separar
  if ($path -match '^/api/mosaico/(mesclar|separar)$' -and $method -eq 'POST') {
    $acao = $Matches[1]
    if (-not (Test-Role $s 'admin')) { Send-Json $Ctx 403 @{ erro = 'Somente administradores mesclam ou separam paineis.' }; return }
    $b = Read-Body $Ctx
    $cfg = Get-Config; $tiles = Get-Tiles; $mos = @(Get-Mosaic $cfg)
    if ($acao -eq 'mesclar') {
      $sel = @()
      foreach ($x in @($b.paineis)) {
        $v = -1
        if (-not [int]::TryParse([string]$x, [ref]$v) -or $v -lt 0 -or $v -ge $PanelCount) { Send-Json $Ctx 400 @{ erro = 'Painel invalido.' }; return }
        $sel += $v
      }
      $r = Resolve-MergeArea $tiles $mos ([int[]]$sel) ([string]$b.escala)
      if ($r.erro) { Send-Json $Ctx 400 @{ erro = $r.erro }; return }
      $area = $r.area
      $novo = @(foreach ($a in $mos) {
        $sobrepoe = $false
        foreach ($p in @($a.paineis)) { if ($area.paineis -contains [int]$p) { $sobrepoe = $true } }
        if (-not $sobrepoe) { $a }
      }) + $area
      $undo = New-UndoSnapshot $cfg 'admin'
      $res = Set-WallState $cfg $cfg.paineis $novo
      $lbl = Get-AreaLabel $tiles $area
      Write-Audit $who $ip 'MOSAICO_MESCLADO' "n=$($area.n) paineis=$($area.paineis -join ',') ($lbl) escala=$($area.escala) :: $($res.detalhes -join '; ')"
      Send-Json $Ctx 200 @{ ok = $true; msg = "Paineis $($area.paineis -join ', ') mesclados no painel $($area.n) ($lbl)."; n = $area.n; afetados = $res.afetados; desfazer = $undo }; return
    }
    $n = -1
    if (-not [int]::TryParse([string]$b.n, [ref]$n)) { Send-Json $Ctx 400 @{ erro = 'Painel invalido.' }; return }
    $area = $mos | Where-Object { [int]$_.n -eq $n } | Select-Object -First 1
    if (-not $area) { Send-Json $Ctx 400 @{ erro = "O painel $n nao esta mesclado." }; return }
    $undo = New-UndoSnapshot $cfg 'admin'
    $res = Set-WallState $cfg $cfg.paineis @($mos | Where-Object { [int]$_.n -ne $n })
    Write-Audit $who $ip 'MOSAICO_SEPARADO' "n=$n paineis=$(@($area.paineis) -join ',') :: $($res.detalhes -join '; ')"
    Send-Json $Ctx 200 @{ ok = $true; msg = "Painel $n separado: $(@($area.paineis) -join ', ') voltam a ser independentes."; afetados = $res.afetados; desfazer = $undo }; return
  }

  # ---- desfazer (estado guardado pelo servidor antes de mesclar/separar/aplicar cenario)
  if ($path -match '^/api/desfazer/([a-f0-9]{20})$' -and $method -eq 'POST') {
    $undoId = $Matches[1]
    $snap = $UndoSnaps[$undoId]
    if (-not $snap -or $snap.exp -lt (Get-Date)) { Send-Json $Ctx 400 @{ erro = 'Nao da mais para desfazer (expirou ou o gerenciador reiniciou).' }; return }
    if (-not (Test-Role $s $snap.papel)) { Send-Json $Ctx 403 @{ erro = 'Sem permissao para desfazer esta acao.' }; return }
    $cfg = Get-Config
    $tm = Test-Mosaic (Get-Tiles) $snap.mosaico
    if ($tm.erro) { Send-Json $Ctx 400 @{ erro = "Nao da para desfazer: $($tm.erro)" }; return }
    $UndoSnaps.Remove($undoId)
    $cfg.cenarioAtivo = $snap.cenarioAtivo
    $res = Set-WallState $cfg $snap.paineis @($tm.mosaico)
    Write-Audit $who $ip 'DESFEITO' ($res.detalhes -join '; ')
    Send-Json $Ctx 200 @{ ok = $true; msg = 'Alteracao desfeita.'; afetados = $res.afetados; detalhes = $res.detalhes }; return
  }

  # ---- cenarios
  if ($path -eq '/api/cenarios' -and $method -eq 'POST') {
    if (-not (Test-Role $s 'operador')) { Send-Json $Ctx 403 @{ erro = 'Sem permissao.' }; return }
    $b = Read-Body $Ctx
    if (-not $b.nome -or $b.nome.Length -gt 40) { Send-Json $Ctx 400 @{ erro = 'Nome do cenario obrigatorio (ate 40).' }; return }
    $cfg = Get-Config
    $id = ($b.nome.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $id) { $id = 'cenario' }
    $base = $id; $i = 2
    while ($cfg.cenarios | Where-Object { $_.id -eq $id }) { $id = "$base-$i"; $i++ }
    $cfg.cenarios = @($cfg.cenarios) + [pscustomobject]@{ id = $id; nome = [string]$b.nome; paineis = @(Copy-Deep $cfg.paineis); mosaico = @(Copy-Deep @(Get-Mosaic $cfg)) }
    $cfg.cenarioAtivo = $id
    Save-Config $cfg
    Write-Audit $who $ip 'CENARIO_CRIADO' "id=$id nome=$($b.nome)"
    Send-Json $Ctx 200 @{ ok = $true; id = $id; msg = "Cenario '$($b.nome)' criado com a parede atual." }; return
  }
  if ($path -match '^/api/cenarios/([a-z0-9-]+)(/aplicar)?$') {
    $id = $Matches[1]; $aplicar = [bool]$Matches[2]
    if (-not (Test-Role $s 'operador')) { Send-Json $Ctx 403 @{ erro = 'Sem permissao.' }; return }
    $cfg = Get-Config
    $cen = $cfg.cenarios | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $cen) { Send-Json $Ctx 404 @{ erro = 'Cenario inexistente.' }; return }

    if ($aplicar -and $method -eq 'POST') {
      $anteriores = @(Copy-Deep $cfg.paineis)
      # cenario antigo (sem mosaico) = todos os paineis separados
      $mosCen = @(); if ($cen.PSObject.Properties['mosaico']) { $mosCen = @($cen.mosaico | Where-Object { $_ }) }
      $aviso = ''
      $tm = Test-Mosaic (Get-Tiles) $mosCen
      if ($tm.erro) { $mosCen = @(Get-Mosaic $cfg); $aviso = " Mosaico do cenario ignorado ($($tm.erro))." } else { $mosCen = @($tm.mosaico) }
      # paineis que o cenario nao define ficam como estao
      $novos = @($cfg.paineis | Where-Object { $n0 = [int]$_.n; -not ($cen.paineis | Where-Object { [int]$_.n -eq $n0 }) }) + @($cen.paineis)
      $undo = New-UndoSnapshot $cfg 'operador'
      $cfg.cenarioAtivo = $id
      $r = Set-WallState $cfg $novos $mosCen
      Write-Audit $who $ip 'CENARIO_APLICADO' "id=$id :: $($r.detalhes -join '; ')$aviso"
      Send-Json $Ctx 200 @{ ok = $true; msg = "Cenario '$($cen.nome)' aplicado.$aviso"; detalhes = $r.detalhes; afetados = $r.afetados; anteriores = $anteriores; desfazer = $undo }; return
    }
    if (-not $aplicar -and $method -eq 'PUT') {
      $b = Read-Body $Ctx
      if ($b.nome) {
        if ($b.nome.Length -gt 40) { Send-Json $Ctx 400 @{ erro = 'Nome ate 40 caracteres.' }; return }
        $cen.nome = [string]$b.nome
      }
      if ($b.salvarAtual) {
        $cen.paineis = @(Copy-Deep $cfg.paineis)
        $cen | Add-Member -NotePropertyName mosaico -NotePropertyValue @(Copy-Deep @(Get-Mosaic $cfg)) -Force
        $cfg.cenarioAtivo = $id
      }
      Save-Config $cfg
      Write-Audit $who $ip 'CENARIO_ALTERADO' "id=$id nome=$($cen.nome) salvarAtual=$([bool]$b.salvarAtual)"
      Send-Json $Ctx 200 @{ ok = $true; msg = "Cenario '$($cen.nome)' salvo." }; return
    }
    if (-not $aplicar -and $method -eq 'DELETE') {
      if (@($cfg.cenarios).Count -le 1) { Send-Json $Ctx 400 @{ erro = 'Precisa existir pelo menos um cenario.' }; return }
      $cfg.cenarios = @($cfg.cenarios | Where-Object { $_.id -ne $id })
      if ($cfg.cenarioAtivo -eq $id) { $cfg.cenarioAtivo = $null }
      Save-Config $cfg
      Write-Audit $who $ip 'CENARIO_EXCLUIDO' "id=$id nome=$($cen.nome)"
      Send-Json $Ctx 200 @{ ok = $true; msg = "Cenario '$($cen.nome)' excluido." }; return
    }
  }

  # ---- usuarios (admin)
  if ($path -like '/api/usuarios*' -or $path -eq '/api/auditoria') {
    if (-not (Test-Role $s 'admin')) { Send-Json $Ctx 403 @{ erro = 'Somente administradores.' }; return }
  }
  if ($path -eq '/api/auditoria' -and $method -eq 'GET') {
    # [IO.File] em vez de Get-Content: as strings do Get-Content carregam PSDrive/PSProvider e o
    # ConvertTo-Json -Depth 20 serializava esse grafo inteiro (GBs de RAM e CPU travada).
    [string[]]$lines = @()
    if (Test-Path $AuditFile) {
      $lines = @([IO.File]::ReadAllLines($AuditFile, [Text.Encoding]::UTF8) | Select-Object -Last 300)
    }
    [array]::Reverse($lines)
    Send-Json $Ctx 200 @($lines); return
  }
  if ($path -eq '/api/usuarios' -and $method -eq 'GET') {
    Send-Json $Ctx 200 @((Get-Users).usuarios | ForEach-Object { Get-PublicUser $_ }); return
  }
  if ($path -eq '/api/usuarios' -and $method -eq 'POST') {
    $b = Read-Body $Ctx
    if ([string]$b.usuario -notmatch '^[A-Za-z0-9._-]{3,32}$') { Send-Json $Ctx 400 @{ erro = 'Usuario invalido (3-32: letras, numeros, . _ -).' }; return }
    if (-not $RoleRank.ContainsKey([string]$b.papel)) { Send-Json $Ctx 400 @{ erro = 'Papel invalido.' }; return }
    $err = Test-NewPassword ([string]$b.senha); if ($err) { Send-Json $Ctx 400 @{ erro = $err }; return }
    $users = Get-Users
    if ($users.usuarios | Where-Object { $_.usuario -eq $b.usuario }) { Send-Json $Ctx 400 @{ erro = 'Usuario ja existe.' }; return }
    $nome = [string]$b.nome; if (-not $nome) { $nome = [string]$b.usuario }
    $users.usuarios = @($users.usuarios) + [pscustomobject]@{
      usuario = [string]$b.usuario; nome = $nome.Substring(0, [math]::Min(60, $nome.Length)); papel = [string]$b.papel
      ativo = $true; hash = (New-PasswordHash ([string]$b.senha)); criado = (Get-Date -Format s) }
    Save-Users $users
    Write-Audit $who $ip 'USUARIO_CRIADO' "usuario=$($b.usuario) papel=$($b.papel)"
    Send-Json $Ctx 200 @{ ok = $true; msg = "Usuario '$($b.usuario)' criado." }; return
  }
  if ($path -match '^/api/usuarios/([A-Za-z0-9._-]{3,32})$') {
    $alvo = $Matches[1]
    $users = Get-Users
    $u = $users.usuarios | Where-Object { $_.usuario -eq $alvo } | Select-Object -First 1
    if (-not $u) { Send-Json $Ctx 404 @{ erro = 'Usuario inexistente.' }; return }
    $outrosAdmins = @($users.usuarios | Where-Object { $_.usuario -ne $alvo -and $_.papel -eq 'admin' -and $_.ativo }).Count

    if ($method -eq 'PUT') {
      $b = Read-Body $Ctx
      if ($b.papel -and -not $RoleRank.ContainsKey([string]$b.papel)) { Send-Json $Ctx 400 @{ erro = 'Papel invalido.' }; return }
      $vaiPerderAdmin = ($u.papel -eq 'admin') -and (($b.papel -and $b.papel -ne 'admin') -or ($null -ne $b.ativo -and -not $b.ativo))
      if ($vaiPerderAdmin -and $outrosAdmins -eq 0) { Send-Json $Ctx 400 @{ erro = 'Precisa existir pelo menos um admin ativo.' }; return }
      if ($b.nome)  { $u.nome = ([string]$b.nome).Substring(0, [math]::Min(60, ([string]$b.nome).Length)) }
      if ($b.papel) { $u.papel = [string]$b.papel }
      if ($null -ne $b.ativo) { $u.ativo = [bool]$b.ativo }
      if ($b.senha) {
        $err = Test-NewPassword ([string]$b.senha); if ($err) { Send-Json $Ctx 400 @{ erro = $err }; return }
        $u.hash = New-PasswordHash ([string]$b.senha)
      }
      Save-Users $users
      Remove-UserSessions $alvo          # forca novo login com as permissoes novas
      Write-Audit $who $ip 'USUARIO_ALTERADO' "usuario=$alvo papel=$($u.papel) ativo=$($u.ativo) senhaTrocada=$([bool]$b.senha)"
      Send-Json $Ctx 200 @{ ok = $true; msg = "Usuario '$alvo' atualizado." }; return
    }
    if ($method -eq 'DELETE') {
      if ($alvo -eq $who) { Send-Json $Ctx 400 @{ erro = 'Voce nao pode excluir o proprio usuario.' }; return }
      if ($u.papel -eq 'admin' -and $outrosAdmins -eq 0) { Send-Json $Ctx 400 @{ erro = 'Precisa existir pelo menos um admin ativo.' }; return }
      $users.usuarios = @($users.usuarios | Where-Object { $_.usuario -ne $alvo })
      Save-Users $users
      Remove-UserSessions $alvo
      Write-Audit $who $ip 'USUARIO_EXCLUIDO' "usuario=$alvo"
      Send-Json $Ctx 200 @{ ok = $true; msg = "Usuario '$alvo' excluido." }; return
    }
  }

  Send-Json $Ctx 404 @{ erro = 'Rota inexistente.' }
}

# ---------------------------------------------------------------- loop principal
# sem usuario cadastrado: sobe em modo de configuracao (assistente web com codigo de uso unico)
$script:SetupPending = Test-SetupPending

$DiagFile = Join-Path $ManagerDir 'diag.log'
function Write-Diag([string]$Text) {
  try {
    if ((Test-Path $DiagFile) -and (Get-Item $DiagFile).Length -gt 2MB) { Move-Item $DiagFile "$DiagFile.1" -Force }
    [IO.File]::AppendAllText($DiagFile, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text`r`n")
  } catch {}
}
function Get-MemMB { [math]::Round([Diagnostics.Process]::GetCurrentProcess().PrivateMemorySize64 / 1MB) }

# Protecao: se o processo passar do limite, sai com erro; a tarefa agendada (repeticao a cada 5 min) sobe de novo.
function Test-Health {
  $mb = Get-MemMB
  if ($mb -gt $MaxMemMB) {
    Write-Audit "sistema" "local" "REINICIO_MEMORIA" "${mb}MB > ${MaxMemMB}MB"
    Write-Diag "REINICIO_MEMORIA ${mb}MB"
    try { $listener.Stop() } catch {}
    [Environment]::Exit(1)       # encerra tambem o runspace do worker
  }
  if ($WorkerHandle -and $WorkerHandle.IsCompleted) {
    Write-Diag "worker parou: $($WorkerPs.Streams.Error | Select-Object -First 1) - reiniciando"
    Start-Worker
  }
}

$extras = @($ExtraPrefixes -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$listener = New-Object Net.HttpListener
foreach ($p in @($Prefix) + $extras) { $listener.Prefixes.Add($p) }
try { $listener.Start() }
catch {
  # algum prefixo extra (80/8443) ocupado por outro programa: sobe so com o principal
  Write-Diag "AVISO prefixos extras recusados ($($extras -join ', ')): $($_.Exception.Message) - seguindo so com $Prefix"
  try { $listener.Close() } catch {}
  $listener = New-Object Net.HttpListener
  $listener.Prefixes.Add($Prefix)
  $listener.Start()
}
# pausa sobrevive a reinicios do gerenciador e do PC
if (Test-Path $PauseFile) { try { $Cache['pausa'] = Read-JsonFile $PauseFile } catch {} }
try { $c0 = Get-Config; Update-MosaicCache (Get-Mosaic $c0); Update-ManutCache $c0 } catch { Write-Diag "AVISO paineis.json ilegivel: $($_.Exception.Message)" }
# reinicios por memoria nas ultimas 24 h (para o /api/saude)
try {
  $lim = (Get-Date).AddHours(-24).ToString('yyyy-MM-dd HH:mm:ss')
  $linhas = @(foreach ($f in "$DiagFile.1", $DiagFile) { if (Test-Path $f) { [IO.File]::ReadAllLines($f) } })
  $Cache['reinicios24h'] = @($linhas | Where-Object { $_ -match '^(\S+ \S+) REINICIO_MEMORIA' -and $Matches[1] -ge $lim }).Count
  $linhas = $null
} catch { $Cache['reinicios24h'] = 0 }
Start-Worker
Write-Host "NOC Manager ouvindo em $Prefix (Ctrl+C para sair)"
Write-Audit "sistema" "local" "SERVIDOR_INICIADO" "$Prefix v$Version"
if ($script:SetupPending) { Write-Diag "MODO_CONFIGURACAO: nenhum usuario; assistente web ativo (codigo: NocManager.ps1 -NovoCodigo)" }
Write-Diag "SERVIDOR_INICIADO v$Version mem=$(Get-MemMB)MB prefixos=$($listener.Prefixes -join ', ') oficial=$PublicUrl redes=$AllowFrom"

try {
  $pending = $null
  while ($listener.IsListening) {
    if (-not $pending) { $pending = $listener.GetContextAsync() }
    if (-not $pending.Wait(5000)) { Test-Health; continue }     # sem requisicao: so checa a saude
    $ctx = $pending.Result; $pending = $null
    if (-not (Test-IpAllowed $ctx.Request.RemoteEndPoint.Address)) {
      try {
        $deny = [Text.Encoding]::UTF8.GetBytes('Scry: acesso permitido somente pela rede interna.')
        $ctx.Response.StatusCode = 403; $ctx.Response.ContentType = 'text/plain; charset=utf-8'
        $ctx.Response.OutputStream.Write($deny, 0, $deny.Length)
      } catch {}
      try { $ctx.Response.Close() } catch {}
      Write-Diag "BLOQUEADO (fora da rede interna) $($ctx.Request.RemoteEndPoint) $($ctx.Request.HttpMethod) $($ctx.Request.RawUrl)"
      continue
    }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $m0 = Get-MemMB
    $Cache['_req'] = @{ p = "$($ctx.Request.HttpMethod) $($ctx.Request.RawUrl) de $($ctx.Request.RemoteEndPoint)"; t = Get-Date; logado = $false }
    try {
      Invoke-Route $ctx
    } catch {
      try { Send-Json $ctx 500 @{ erro = "Erro interno: $($_.Exception.Message)" } } catch {}
    } finally {
      try { $ctx.Response.Close() } catch {}
      $Cache.Remove('_req')
    }
    $dm = (Get-MemMB) - $m0
    if ($sw.ElapsedMilliseconds -gt 2000 -or $dm -gt 50) {
      Write-Diag ("LENTO {0} {1} {2}ms mem+{3}MB total={4}MB" -f $ctx.Request.HttpMethod, $ctx.Request.Url.AbsolutePath, $sw.ElapsedMilliseconds, $dm, (Get-MemMB))
    }
    # limpeza simples de sessoes expiradas
    foreach ($k in @($Sessions.Keys)) { if ($Sessions[$k].exp -lt (Get-Date)) { $Sessions.Remove($k) } }
    Test-Health
  }
} finally {
  $listener.Stop()
}
