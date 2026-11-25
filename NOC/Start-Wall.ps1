# C:\NOC\Start-Wall.ps1
# Video wall NOC - 10 janelas 1920x1080 sem borda, 1 por painel (ou menos, maiores, com mosaico).
# Numeracao por coluna: 0/1 = coluna 1 (cima/baixo), 2/3 = coluna 2, ... 8/9 = coluna 5.
# Pode rodar de novo a qualquer momento: abre so o que faltar e reposiciona o resto.

# Registro da ultima execucao (a tarefa roda escondida a cada 5 min)
try { Start-Transcript -Path 'C:\NOC\start-wall.log' -Force | Out-Null } catch {}

Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class W3 {
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
 // Janela principal (visivel, com titulo, classe do Chrome) de qualquer um dos PIDs informados
 public static IntPtr FindChromeWindow(uint[] pids) {
   IntPtr found = IntPtr.Zero;
   EnumWindows(delegate(IntPtr h, IntPtr l) {
     if (!IsWindowVisible(h) || GetWindowTextLength(h) == 0) return true;
     uint pid; GetWindowThreadProcessId(h, out pid);
     if (Array.IndexOf(pids, pid) < 0) return true;
     StringBuilder sb = new StringBuilder(64); GetClassName(h, sb, 64);
     if (sb.ToString() != "Chrome_WidgetWin_1") return true;
     found = h; return false;
   }, IntPtr.Zero);
   return found;
 }
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
 [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int cx,int cy,uint f);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
 [DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr h, IntPtr rgn, bool redraw);
 [DllImport("gdi32.dll")]  public static extern IntPtr CreateRectRgn(int l,int t,int r,int b);
}
"@
[W3]::SetProcessDPIAware() | Out-Null
Add-Type -AssemblyName System.Windows.Forms

# Localiza o chrome.exe (registro App Paths -> caminhos comuns, inclusive instalacao por usuario)
$chrome = @(
  (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'
  (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if (-not $chrome) { throw "chrome.exe nao encontrado. Rode: Get-ChildItem C:\ -Filter chrome.exe -Recurse -ErrorAction SilentlyContinue" }
Write-Host "Chrome: $chrome"
# Paineis vem do C:\NOC\paineis.json (editado pelo gerenciador web).
$cfgFile = "C:\NOC\paineis.json"
if (-not (Test-Path $cfgFile)) { throw "Nao encontrei $cfgFile" }
$cfgStamp = (Get-Item $cfgFile).LastWriteTimeUtc     # se mudar durante a rodada, roda de novo no fim
$cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
$paineis = @($cfg.paineis | Sort-Object { [int]$_.n } | ForEach-Object {
  $z = 0.67; if ($_.zoom) { $z = [double]$_.zoom }
  [pscustomobject]@{ N = [int]$_.n; Nome = [string]$_.nome; Url = [string]$_.url; Zoom = $z }
})

# Corta cada saida do Windows em blocos 1920x1080 (saida 4K = 4 blocos)
$tiles = foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
  $b = $s.Bounds
  for ($y = $b.Y; $y -lt $b.Bottom; $y += 1080) {
    for ($x = $b.X; $x -lt $b.Right; $x += 1920) { [pscustomobject]@{ X=$x; Y=$y } }
  }
}
# Ordem por COLUNA (esq->dir) e dentro da coluna de cima para baixo = 0,1 | 2,3 | ...
$tiles = @($tiles | Sort-Object X, Y)
Write-Host "Paineis detectados: $($tiles.Count) (esperado: 10)"
if ($tiles.Count -ne 10) { Write-Warning "Confira escala 100% e o arranjo das telas no Windows." }

# Layout real (telas e blocos) para o gerenciador desenhar a grade igual a parede
try {
  $lay = [pscustomobject]@{
    gerado = (Get-Date -Format s)
    telas  = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
      [pscustomobject]@{ nome = $_.DeviceName; x = $_.Bounds.X; y = $_.Bounds.Y; w = $_.Bounds.Width; h = $_.Bounds.Height; principal = $_.Primary } })
    tiles  = @(for ($i = 0; $i -lt $tiles.Count; $i++) { [pscustomobject]@{ n = $i; x = $tiles[$i].X; y = $tiles[$i].Y; w = 1920; h = 1080 } })
  }
  [IO.File]::WriteAllText("C:\NOC\layout.json", ($lay | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
} catch { Write-Warning "Nao consegui gravar C:\NOC\layout.json: $($_.Exception.Message)" }

# Mosaico (paineis mesclados pelo Scry): o painel ancora ocupa a area inteira (W x H)
# e os absorvidos ficam com a janela fechada. Area que nao bate com as telas atuais e ignorada.
$areas = @{}; $absorvidos = @{}
foreach ($a in @($cfg.mosaico | Where-Object { $_ })) {
  $n = [int]$a.n; $w = [int]$a.w; $h = [int]$a.h
  $membros = @(@($a.paineis) | ForEach-Object { [int]$_ })
  $ok = ($n -ge 0) -and ($n -lt $tiles.Count) -and ($membros -contains $n) -and ($membros.Count -ge 2) -and ($w -ge 1920) -and ($h -ge 1080)
  if ($ok) {
    $t0 = $tiles[$n]; $soma = 0
    foreach ($m in $membros) {
      if ($m -lt 0 -or $m -ge $tiles.Count -or $absorvidos.ContainsKey($m) -or $areas.ContainsKey($m)) { $ok = $false; break }
      $tm = $tiles[$m]
      if ($tm.X -lt $t0.X -or $tm.Y -lt $t0.Y -or ($tm.X + 1920) -gt ($t0.X + $w) -or ($tm.Y + 1080) -gt ($t0.Y + $h)) { $ok = $false; break }
      $soma += 1920 * 1080
    }
    if ([math]::Abs($w * $h - $soma) -gt 8 * ($w + $h)) { $ok = $false }   # folga de ate 8 px entre telas
  }
  if (-not $ok) { Write-Warning "Mosaico do painel $n ignorado (nao bate com as telas atuais)."; continue }
  # "ampliar": o conteudo cresce junto com a area (2x2 = 2x); "espaco": mesmo tamanho de letra, mais conteudo
  $fator = 1.0
  if ([string]$a.escala -ne 'espaco') { $fator = [double][math]::Max(1, [math]::Min([math]::Floor($w / 1920), [math]::Floor($h / 1080))) }
  $areas[$n] = [pscustomobject]@{ W = $w; H = $h; Fator = $fator }
  foreach ($m in $membros) { if ($m -ne $n) { $absorvidos[$m] = $n } }
  Write-Host ("Mosaico: painel {0} ocupa {1}x{2} (paineis {3}, escala {4})" -f $n, $w, $h, ($membros -join ','), $a.escala)
}

# Parede pausada pelo gerenciador: nao abre nada enquanto a pausa valer
$pauseFile = "C:\NOC\pausado.json"
if (Test-Path $pauseFile) {
  try {
    $pz = Get-Content $pauseFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $pz.ate -or ([datetime]$pz.ate) -gt (Get-Date)) { Write-Host "Parede pausada por $($pz.por) desde $($pz.desde) - nada a fazer."; return }
  } catch { Write-Warning "pausado.json ilegivel - seguindo e abrindo a parede." }
}

# --- Login automatico no Grafana ------------------------------------------
# Credencial guardada com DPAPI: so o MESMO usuario, NESTA maquina, consegue ler.
# Criar uma vez (logado como o usuario da tarefa agendada):
#   Get-Credential -UserName tvbqe -Message Grafana | Export-Clixml C:\NOC\grafana.cred
$credFile = "C:\NOC\grafana.cred"
$loginBody = $null
if (Test-Path $credFile) {
  $c = Import-Clixml $credFile
  $loginBody = @{ user = $c.UserName; password = $c.GetNetworkCredential().Password } | ConvertTo-Json -Compress
} else { Write-Warning "Sem $credFile - login automatico desativado." }

function Invoke-CDP($wsUrl, $expr) {
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $ct = [Threading.CancellationToken]::None
  try {
    $ws.ConnectAsync([Uri]$wsUrl, $ct).Wait(5000) | Out-Null
    $msg = @{ id = 1; method = 'Runtime.evaluate'
              params = @{ expression = $expr; awaitPromise = $true; returnByValue = $true } } |
           ConvertTo-Json -Compress -Depth 5
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $ws.SendAsync((New-Object ArraySegment[byte] (,$bytes)), 'Text', $true, $ct).Wait(5000) | Out-Null
    $buf = New-Object byte[] 65536
    $task = $ws.ReceiveAsync((New-Object ArraySegment[byte] (,$buf)), $ct)
    if ($task.Wait(15000)) { return [Text.Encoding]::UTF8.GetString($buf, 0, $task.Result.Count) }
  } catch { return $null } finally { $ws.Dispose() }
}

function Invoke-AutoLogin($port, $url, $nome) {
  if (-not $loginBody) { return }
  $jsUrl = $url | ConvertTo-Json      # string JS ja escapada
  # Se a pagina estiver no /login, autentica via POST /login (mesma origem) e volta ao dashboard
  $js = @"
(async () => {
  if (!location.pathname.startsWith('/login')) return 'ja-autenticado';
  const r = await fetch('/login', { method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify($loginBody) });
  if (!r.ok) return 'falha-' + r.status;
  setTimeout(() => { location.href = $jsUrl; }, 200);
  return 'logado';
})()
"@
  for ($k = 0; $k -lt 20; $k++) {
    $page = $null
    try { $page = Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 3 |
                  Where-Object { $_.type -in 'page','app' } | Select-Object -First 1 } catch {}
    if ($page -and $page.url -like 'https://grafana.armazem.cloud/*') {
      $res = Invoke-CDP $page.webSocketDebuggerUrl $js
      if ($res -match '"value":"([^"]+)"') { Write-Host "    login: $($Matches[1])" ; return }
    }
    Start-Sleep -Seconds 1
  }
  Write-Warning "    login: sem resposta no painel $nome"
}

# --- Zoom real do navegador (igual Ctrl + / Ctrl -), gravado no perfil -----
# Chrome guarda o zoom como nivel: fator = 1.2 ^ nivel. O "67%" do Chrome e exatamente 2/3.
function Set-ProfileZoom($prof, $factor) {
  if ([Math]::Abs($factor - 0.67) -lt 0.001) { $factor = 2.0 / 3.0 }
  $level    = [Math]::Log($factor) / [Math]::Log(1.2)
  $prefFile = Join-Path $prof 'Default\Preferences'
  try {
    if (Test-Path $prefFile) {
      $json = Get-Content $prefFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
      New-Item -ItemType Directory -Path (Split-Path $prefFile) -Force | Out-Null
      $json = New-Object psobject
    }
    if (-not $json.partition) { $json | Add-Member -NotePropertyName partition -NotePropertyValue (New-Object psobject) -Force }
    $json.partition | Add-Member -NotePropertyName default_zoom_level `
      -NotePropertyValue ([pscustomobject]@{ x = $level }) -Force
    # remove zoom salvo por site (senao ele vence o padrao)
    if ($json.partition.PSObject.Properties['per_host_zoom_levels']) {
      $json.partition.PSObject.Properties.Remove('per_host_zoom_levels')
    }
    $text = $json | ConvertTo-Json -Depth 100 -Compress
    [IO.File]::WriteAllText($prefFile, $text, (New-Object Text.UTF8Encoding $false))   # UTF-8 sem BOM
  } catch {
    Write-Warning "    zoom: nao consegui gravar em $prefFile ($($_.Exception.Message))"
  }
}

function Show-Viewport($port) {
  try {
    $page = Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 3 |
            Where-Object { $_.type -in 'page','app' } | Select-Object -First 1
    $res = Invoke-CDP $page.webSocketDebuggerUrl 'innerWidth + "x" + innerHeight + " zoom=" + Math.round(devicePixelRatio*100) + "%"'
    if ($res -match '"value":"([^"]+)"') { Write-Host "    viewport: $($Matches[1])" }
  } catch {}
}

# Faz a AREA DA PAGINA ter exatamente 1920x1080 no painel:
# 1) mede a moldura (barra de titulo + bordas) que o Chrome mantem;
# 2) aumenta a janela para compensar, deixando a moldura "para fora" do painel;
# 3) recorta a janela (SetWindowRgn) para so a area da pagina ficar visivel.
function Get-Insets($hwnd) {
  $w = New-Object W3+RECT; $c = New-Object W3+RECT; $pt = New-Object W3+POINT
  [W3]::GetWindowRect($hwnd, [ref]$w) | Out-Null
  [W3]::GetClientRect($hwnd, [ref]$c) | Out-Null
  [W3]::ClientToScreen($hwnd, [ref]$pt) | Out-Null
  [pscustomobject]@{
    L = $pt.X - $w.L; T = $pt.Y - $w.T
    R = $w.R - ($pt.X + $c.R); B = $w.B - ($pt.Y + $c.B)
  }
}

# Barra de titulo que o Chrome desenha DENTRO da area cliente (nao aparece nas bordas do Windows).
# Mede pela diferenca: altura da area cliente - altura real da pagina (innerHeight x zoom).
function Get-CaptionHeight($hwnd, $port) {
  for ($k = 0; $k -lt 20; $k++) {
    try {
      $page = Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 3 |
              Where-Object { $_.type -in 'page','app' } | Select-Object -First 1
      $res = Invoke-CDP $page.webSocketDebuggerUrl 'String(Math.round(innerHeight * devicePixelRatio))'
      if ($res -match '"value":"(\d+)"' -and [int]$Matches[1] -gt 0) {
        $c = New-Object W3+RECT
        [W3]::GetClientRect($hwnd, [ref]$c) | Out-Null
        $cap = $c.B - [int]$Matches[1]
        if ($cap -ge 0 -and $cap -lt 150) { return $cap } else { return 0 }
      }
    } catch {}
    Start-Sleep -Milliseconds 500
  }
  Write-Warning "    nao consegui medir a barra de titulo; seguindo sem compensar"
  return 0
}

# Mosaico de 2+ linhas: a janela (area + barra de 31 px do Chrome) fica mais alta que a area de trabalho,
# e o Windows a limitaria (WM_GETMINMAXINFO) - o rodape perdia ~19 px. SWP_NOSENDCHANGING pula essa trava.
function Set-Panel($hwnd, $t, $cap = 0, [int]$W = 1920, [int]$H = 1080) {
  [W3]::SetWindowRgn($hwnd, [IntPtr]::Zero, $true) | Out-Null    # tira recorte anterior antes de medir
  $i = Get-Insets $hwnd
  $flags = 0x0044                                                  # NOZORDER|SHOWWINDOW
  if ($W -ne 1920 -or $H -ne 1080) { $flags = $flags -bor 0x0400 } # + NOSENDCHANGING (so janelas de mosaico)
  # janela maior: bordas do Windows + barra do Chrome ficam para fora do painel
  [W3]::SetWindowPos($hwnd, [IntPtr]::Zero, ($t.X - $i.L), ($t.Y - $i.T - $cap),
    ($W + $i.L + $i.R), ($H + $i.T + $i.B + $cap), $flags) | Out-Null
  $i = Get-Insets $hwnd                                            # mede de novo apos o resize
  # recorte: so a pagina (abaixo da barra do Chrome), exatamente W x H (1920x1080 ou a area do mosaico)
  $rgn = [W3]::CreateRectRgn($i.L, ($i.T + $cap), ($i.L + $W), ($i.T + $cap + $H))
  [W3]::SetWindowRgn($hwnd, $rgn, $true) | Out-Null                # o Windows passa a ser dono do rgn
}

foreach ($p in $paineis) {
  if ($p.N -ge $tiles.Count) { Write-Warning "Sem bloco para o painel $($p.N)"; continue }
  $t    = $tiles[$p.N]
  $prof = "C:\NOC\profiles\painel$($p.N)"
  $port = 9300 + $p.N      # porta de depuracao local (so 127.0.0.1)
  $profRx = [regex]::Escape($prof) + '(["\s]|$)'     # painel1 nao pode casar com painel10

  # painel mesclado a outro: janela fechada
  if ($absorvidos.ContainsKey($p.N)) {
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -match $profRx } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host ("[{0}] mesclado ao painel {1} - janela fechada" -f $p.N, $absorvidos[$p.N])
    continue
  }
  $W = 1920; $H = 1080; $zoom = $p.Zoom
  if ($areas.ContainsKey($p.N)) {
    $ar = $areas[$p.N]; $W = $ar.W; $H = $ar.H
    if ([Math]::Abs($zoom - 0.67) -lt 0.001) { $zoom = 2.0 / 3.0 }
    $zoom = $zoom * $ar.Fator
  }

  # processo principal do Chrome deste perfil (o que nao tem --type=)
  $main = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
    Where-Object { $_.CommandLine -match $profRx -and $_.CommandLine -notlike "*--type=*" } |
    Select-Object -First 1

  # O zoom so vale ao abrir o Chrome. Se a janela aberta foi lancada com outro zoom (ex.: mosaico desfeito
  # enquanto outra rodada estava em curso), reabre so ela.
  $zoomFile = Join-Path $prof 'scry-zoom.txt'
  $inv = [Globalization.CultureInfo]::InvariantCulture
  if ($main -and (Test-Path $zoomFile)) {
    $zAberto = 0.0
    if ([double]::TryParse(([IO.File]::ReadAllText($zoomFile)).Trim(), [Globalization.NumberStyles]::Float, $inv, [ref]$zAberto) -and
        [Math]::Abs($zAberto - $zoom) -gt 0.001) {
      Write-Host ("[{0}] aberto com zoom {1:N2}, esperado {2:N2} - reabrindo" -f $p.N, $zAberto, $zoom)
      Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -match $profRx } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
      Start-Sleep -Seconds 2
      $main = $null
    }
  }

  if (-not $main) {
    Set-ProfileZoom $prof $zoom          # grava o zoom do painel no perfil antes de abrir
    try { [IO.File]::WriteAllText($zoomFile, $zoom.ToString('R', $inv)) } catch {}
    Start-Process $chrome -ArgumentList @(
      "--user-data-dir=`"$prof`"", "--app=$($p.Url)",
      "--window-position=$($t.X),$($t.Y)", "--window-size=$W,$H",
      "--no-first-run", "--noerrdialogs", "--disable-session-crashed-bubble",
      "--disable-features=Translate", "--remote-debugging-port=$port")
  }

  # Procura a janela entre TODOS os processos Chrome deste perfil (ate 15 s)
  $hwnd = [IntPtr]::Zero
  for ($k = 0; $k -lt 30 -and $hwnd -eq [IntPtr]::Zero; $k++) {
    $pids = [uint32[]]@(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
      Where-Object { $_.CommandLine -match $profRx } | ForEach-Object { $_.ProcessId })
    if ($pids.Count) { $hwnd = [W3]::FindChromeWindow($pids) }
    if ($hwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 500 }
  }
  if ($hwnd -ne [IntPtr]::Zero) {
    $cap = Get-CaptionHeight $hwnd $port
    Set-Panel $hwnd $t $cap $W $H
    Write-Host ("[{0}] {1} -> {2},{3} {4}x{5}  (barra compensada: {6}px)" -f $p.N, $p.Nome, $t.X, $t.Y, $W, $H, $cap)
    Invoke-AutoLogin $port $p.Url $p.Nome
    Show-Viewport $port
  } else {
    Write-Warning "Falhou painel $($p.N) - $($p.Nome)"
  }
}

# O Scry mudou a parede enquanto esta rodada acontecia (a tarefa ignora disparos simultaneos):
# roda de novo para aplicar o estado atual (no maximo 3 rodadas seguidas).
$passo = 1; [void][int]::TryParse([string]$env:NOC_WALL_PASSO, [ref]$passo)
if ((Get-Item $cfgFile).LastWriteTimeUtc -ne $cfgStamp -and $passo -lt 3) {
  Write-Host "paineis.json mudou durante a rodada - rodando de novo (rodada $($passo + 1))"
  try { Stop-Transcript | Out-Null } catch {}
  $env:NOC_WALL_PASSO = [string]($passo + 1)
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
}
