# Scry - instalador de verdade. Normalmente nao e chamado direto: o install.ps1 da raiz do
# repositorio (o "comando de instalacao") baixa este arquivo e roda com powershell -File.
# Rodar direto tambem funciona (PowerShell como Administrador):
#   powershell -NoProfile -ExecutionPolicy Bypass -File install-scry.ps1
#
# Nunca pede nada no terminal: tudo que precisa de resposta e feito no navegador.
#
# O que faz:
#   - Baixa o pacote do ultimo Release do GitHub (Scry-vX.Y.Z.zip).
#   - Primeira vez: copia para C:\NOC, instala sem perguntas (certificado autoassinado, firewall so
#     para redes internas, servidor web como SYSTEM) e mostra o endereco e um CODIGO de uso unico.
#     O resto (admin, usuario da parede, logon automatico) e feito no navegador.
#   - Sem Google Chrome: instala o MSI oficial do Google (sem perguntas). Para pular: $env:SCRY_SEM_CHROME = '1'
#   - Ja instalado: so atualiza (com backup; paineis, usuarios e auditoria sao mantidos).
#
# Opcoes (variaveis de ambiente, antes do comando):
#   $env:SCRY_VERSAO = 'v1.6.0'          instala essa versao em vez da ultima
#   $env:SCRY_ZIP    = 'C:\temp\Scry.zip' usa um pacote local (PC sem acesso ao GitHub)
#
# Arquivo em ASCII de proposito (Windows PowerShell 5.1 le UTF-8 sem BOM como ANSI).

& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'      # deixa o download bem mais rapido no PS 5.1
  $Repo = 'efbecker/nocwall'
  $Root = 'C:\NOC'

  function Say([string]$t, [string]$c = 'Cyan') { Write-Host $t -ForegroundColor $c }
  function Fail([string]$t) { Write-Host ""; Write-Host "ERRO: $t" -ForegroundColor Red; throw "Scry: instalacao interrompida." }
  function Run-Ps([string]$File, [string[]]$ArgList) {
    # sempre no Windows PowerShell 5.1 (os scripts do Scry sao para ele), mesmo se este comando rodar no PS 7
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $File @ArgList | Out-Host
    return $LASTEXITCODE
  }

  # Baixa um endereco: texto (sem $OutFile) ou arquivo. Tenta o .NET e, se falhar, o curl.exe do Windows.
  function Get-Url([string]$Url, [string]$OutFile) {
    try {
      $wc = New-Object Net.WebClient
      $wc.Headers['User-Agent'] = 'scry-installer'
      if ($OutFile) { $wc.DownloadFile($Url, $OutFile); return $null }
      $wc.Encoding = [Text.Encoding]::UTF8
      return $wc.DownloadString($Url)
    } catch {
      $netErr = $_.Exception.Message; $ErrorActionPreference = 'Continue'
      $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
      if (-not (Test-Path $curl)) { throw $netErr }
      $tmp = if ($OutFile) { $OutFile } else { [IO.Path]::GetTempFileName() }
      & $curl -fsL -A scry-installer -o $tmp $Url
      if ($LASTEXITCODE -ne 0) { throw "$netErr / curl.exe codigo $LASTEXITCODE" }
      if ($OutFile) { return $null }
      try { return [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8) } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
  }
  # Endereco final depois dos redirecionamentos (ex.: .../releases/latest -> .../releases/tag/v1.7.1)
  function Get-RedirectTarget([string]$Url) {
    try {
      $rq = [Net.HttpWebRequest]::Create($Url); $rq.AllowAutoRedirect = $false; $rq.UserAgent = 'scry-installer'; $rq.Method = 'HEAD'
      $rs = $rq.GetResponse(); try { $loc = $rs.Headers['Location'] } finally { $rs.Close() }
      if ($loc) { return $loc }
      throw "sem redirecionamento"
    } catch {
      $netErr = $_.Exception.Message; $ErrorActionPreference = 'Continue'
      $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
      if (-not (Test-Path $curl)) { throw $netErr }
      $out = & $curl -fsIL -A scry-installer -o NUL -w '%{url_effective}' $Url
      if ($LASTEXITCODE -ne 0 -or -not $out) { throw "$netErr / curl.exe codigo $LASTEXITCODE" }
      return [string]$out
    }
  }

  Write-Host ""
  Say "  Scry - Video Wall  |  instalacao com um comando" White
  Say "  ----------------------------------------------" White

  # ---------------------------------------------------------------- pre-requisitos
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) { Fail "Abra o PowerShell como Administrador (botao direito > Executar como administrador) e rode o comando de novo." }
  if ($env:OS -ne 'Windows_NT') { Fail "O Scry roda so no Windows." }
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $work = Join-Path $env:TEMP ("scry-install-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $work -Force | Out-Null
  try {
    # ---------------------------------------------------------------- 1. baixar o pacote
    $zip = Join-Path $work 'scry.zip'
    if ($env:SCRY_ZIP) {
      if (-not (Test-Path $env:SCRY_ZIP)) { Fail "Pacote nao encontrado: $env:SCRY_ZIP" }
      Copy-Item $env:SCRY_ZIP $zip
      Say "[1/4] Pacote local: $env:SCRY_ZIP"
    } else {
      # Descobre o Release. 1o pela API do GitHub; se a rede bloquear api.github.com, pelo redirecionamento
      # de github.com/.../releases/latest. Cada acesso tenta o .NET e depois o curl.exe (que ja baixou este
      # instalador, entao costuma passar por onde o .NET nao passa: proxy, inspecao de TLS etc.).
      $tag = $env:SCRY_VERSAO; $zipUrl = $null; $zipNome = $null; $erros = @()
      try {
        $api = if ($tag) { "https://api.github.com/repos/$Repo/releases/tags/$tag" } else { "https://api.github.com/repos/$Repo/releases/latest" }
        $rel = (Get-Url $api) | ConvertFrom-Json
        $asset = @($rel.assets | Where-Object { $_.name -like 'Scry-v*.zip' }) | Select-Object -First 1
        if (-not $asset) { Fail "O Release $($rel.tag_name) nao tem o pacote Scry-v*.zip anexado (o GitHub Actions ainda esta gerando? Tente em 1 minuto. Se o Actions falhou, a tag pode nao bater com a versao do codigo)." }
        $zipUrl = $asset.browser_download_url; $zipNome = $asset.name
      } catch {
        if ($_.Exception.Message -like 'Scry:*') { throw }
        $erros += "api.github.com: $($_.Exception.Message)"
      }
      if (-not $zipUrl) {
        try {
          if (-not $tag) {
            $final = Get-RedirectTarget "https://github.com/$Repo/releases/latest"
            if ($final -notmatch '/releases/tag/([^/?#]+)') { throw "o GitHub nao indicou o ultimo Release ($final)" }
            $tag = $Matches[1]
          }
          $zipNome = "Scry-$tag.zip"
          $zipUrl = "https://github.com/$Repo/releases/download/$tag/$zipNome"
        } catch { $erros += "github.com: $($_.Exception.Message)" }
      }
      if (-not $zipUrl) { Fail ("Nao consegui consultar os Releases em github.com/$Repo (" + ($erros -join '; ') + "). Libere api.github.com e github.com no firewall/proxy, ou use `$env:SCRY_ZIP com um pacote local.") }
      Say "[1/4] Baixando $zipNome..."
      try { Get-Url $zipUrl $zip | Out-Null }
      catch { Fail "Nao consegui baixar $zipUrl ($($_.Exception.Message)). Libere github.com e *.githubusercontent.com no firewall/proxy, ou use `$env:SCRY_ZIP." }
    }
    $pkg = Join-Path $work 'pkg'
    Expand-Archive -Path $zip -DestinationPath $pkg -Force
    $src = Join-Path $pkg 'NOC'
    if (-not (Test-Path (Join-Path $src 'Manager\NocManager.ps1'))) { Fail "Pacote invalido: falta NOC\Manager\NocManager.ps1." }
    Get-ChildItem $pkg -Recurse -File | Unblock-File
    $ver = ([regex]::Match([IO.File]::ReadAllText((Join-Path $src 'Manager\NocManager.ps1')), "\`$Version\s*=\s*'([^']+)'")).Groups[1].Value
    Say "      Scry v$ver"
    # pacotes anteriores a 1.6.0 nao tem o modo sem perguntas (-Setup) e pediriam a senha no terminal
    if ([IO.File]::ReadAllText((Join-Path $src 'Install-NocManager.ps1')) -notmatch '\[switch\]\$Setup') {
      Fail ("O pacote baixado e a v$ver, que ainda nao tem a instalacao pelo navegador (precisa da v1.6.0 ou mais nova). " +
            "Crie o Release v1.6.0 (ou mais novo) em https://github.com/$Repo/releases/new e rode o comando de novo.")
    }

    $installed = (Get-ScheduledTask -TaskName 'NOC-Manager' -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $Root 'Manager\NocManager.ps1'))

    if ($installed) {
      # ---------------------------------------------------------------- 2. atualizar
      Say "[2/4] Scry ja instalado: atualizando (com backup)..."
      $rc = Run-Ps (Join-Path $src 'Update-NocManager.ps1') @('-Root', $Root, '-AplicarParede')
      if ($rc -ne 0) { Fail "A atualizacao nao terminou bem. Para voltar: powershell -ExecutionPolicy Bypass -File $Root\Update-NocManager.ps1 -Reverter" }
      Say "[3/4] (atualizacao nao muda tarefas, certificado nem firewall)"
    } else {
      # ---------------------------------------------------------------- 2. copiar e 3. instalar
      Say "[2/4] Copiando para $Root..."
      New-Item -ItemType Directory -Path $Root -Force | Out-Null
      $keep = @('paineis.json', 'grafana.cred', 'grafana.json', 'layout.json', 'pausado.json', 'Manager\users.json', 'Manager\audit.log')
      foreach ($f in Get-ChildItem $src -Recurse -File) {
        $rel2 = $f.FullName.Substring($src.TrimEnd('\').Length + 1)
        $dst = Join-Path $Root $rel2
        if (($keep -contains $rel2) -and (Test-Path $dst)) { continue }
        New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
      }
      # o INSTALAR.cmd tambem fica em C:\NOC, para reinstalar/reconfigurar depois
      if (Test-Path (Join-Path $pkg 'INSTALAR.cmd')) { Copy-Item (Join-Path $pkg 'INSTALAR.cmd') (Join-Path $Root 'INSTALAR.cmd') -Force }
      Say "[3/4] Instalando o servidor web (certificado, firewall, tarefa agendada)..."
      $rc = Run-Ps (Join-Path $Root 'Install-NocManager.ps1') @('-Root', $Root, '-Setup')
      if ($rc -ne 0) { Fail "O instalador falhou (veja as mensagens acima)." }
    }

    # ---------------------------------------------------------------- Google Chrome (as telas sao janelas dele)
    # Windows Server e PCs novos podem vir sem o Chrome. Instala o MSI oficial do Google para empresas,
    # sem perguntas e para todos os usuarios. Para pular: $env:SCRY_SEM_CHROME = '1'.
    function Find-ChromeExe {
      @(
        (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
      ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    }
    if (Find-ChromeExe) {
      Say "      Google Chrome: ok"
    } elseif ($env:SCRY_SEM_CHROME) {
      Say "  Aviso: o Google Chrome nao esta instalado (SCRY_SEM_CHROME definido: nao vou instalar). As telas so abrem com ele." Yellow
    } else {
      Say "      Google Chrome nao encontrado: instalando o MSI oficial do Google (1 a 3 minutos)..."
      try {
        $msi = Join-Path $work 'chrome.msi'
        Get-Url 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi' $msi | Out-Null
        $sig = Get-AuthenticodeSignature -FilePath $msi
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Google LLC') {
          throw "assinatura do instalador nao confere ($($sig.Status))"
        }
        $p = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { throw "msiexec terminou com o codigo $($p.ExitCode)" }
        if (-not (Find-ChromeExe)) { throw "o Chrome nao apareceu depois da instalacao" }
        Say "      Google Chrome instalado." Green
      } catch {
        Say "  Aviso: nao consegui instalar o Google Chrome ($($_.Exception.Message))." Yellow
        Say "  Instale pelo site google.com/chrome (para todos os usuarios). Sem ele as telas nao abrem." Yellow
      }
    }

    # Politica do Chrome para o PC todo: sem o balao do Google Tradutor nas telas da parede
    try {
      $pol = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
      if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
      New-ItemProperty -Path $pol -Name 'TranslateEnabled' -Value 0 -PropertyType DWord -Force | Out-Null
    } catch { Say "  Aviso: nao consegui desligar o tradutor do Chrome ($($_.Exception.Message))." Yellow }

    # ---------------------------------------------------------------- 4. codigo do assistente
    $usersFile = Join-Path $Root 'Manager\users.json'
    $pending = $true
    if (Test-Path $usersFile) {
      try { $pending = -not @((Get-Content $usersFile -Raw -Encoding UTF8 | ConvertFrom-Json).usuarios | Where-Object { $_.ativo }).Count } catch {}
    }
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { $_.IPAddress })
    $taskArgs = [string]((Get-ScheduledTask -TaskName 'NOC-Manager' -ErrorAction SilentlyContinue).Actions | Select-Object -First 1 -ExpandProperty Arguments)
    $mPort = [regex]::Match($taskArgs, '-Prefix\s+"?https://[^:/]+:(\d+)/')
    $port = if ($mPort.Success) { [int]$mPort.Groups[1].Value } else { 443 }
    $mUrl = [regex]::Match($taskArgs, '-PublicUrl\s+"([^"]+)"')
    $urls = if ($mUrl.Success) { @($mUrl.Groups[1].Value) } else { @($ips | ForEach-Object { "https://$_" + $(if ($port -ne 443) { ":$port" } else { '' }) }) }

    Write-Host ""
    if ($pending) {
      $out = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Root 'Manager\NocManager.ps1') -Root $Root -NovoCodigo
      $code = ($out | Where-Object { $_ -like 'CODIGO=*' } | Select-Object -First 1) -replace '^CODIGO=', ''
      if (-not $code) { Fail "Nao consegui gerar o codigo de configuracao: $out" }
      Say "[4/4] Pronto! Agora termine a configuracao pelo navegador, de qualquer PC da rede:" Green
      Write-Host ""
      foreach ($u in $urls) { Say "        $u" White }
      Write-Host ""
      Say "        Codigo de instalacao:  $code" Yellow
      Say "        (vale por 24 horas; rodar este comando de novo gera outro)" DarkGray
      Write-Host ""
      Say "  O navegador vai avisar sobre o certificado (autoassinado): clique em Avancado > Continuar." DarkGray
      Say "  Se a porta 443 estiver bloqueada entre as redes, libere-a no firewall da rede." DarkGray
    } else {
      Say "[4/4] Pronto! Scry v$ver no ar:" Green
      foreach ($u in $urls) { Say "        $u" White }
      if (-not (Get-ScheduledTask -TaskName 'NOC-VideoWall' -ErrorAction SilentlyContinue)) {
        Say "  Aviso: a tarefa da parede (NOC-VideoWall) nao existe. Rode $Root\INSTALAR.cmd -Reinstalar para informar o usuario da parede." Yellow
      }
    }
    Write-Host ""
  } finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}
