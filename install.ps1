# Scry - comando de instalacao (bootstrap). Como Administrador, no PC da parede ou por SSH, use UM destes:
#   curl.exe -fsSL https://raw.githubusercontent.com/efbecker/nocwall/main/install.ps1 | powershell -NoProfile -ExecutionPolicy Bypass -Command -
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/efbecker/nocwall/main/install.ps1 | iex"
# Este arquivo e de proposito curto, em ASCII e com UM comando completo por linha: o "-Command -" le
# a entrada linha a linha. Ele so baixa o instalador de verdade (scripts/install-scry.ps1) e o roda.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ScryInstaller = Join-Path $env:TEMP ('scry-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
Write-Host 'Scry: baixando o instalador...'
try { (New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/efbecker/nocwall/main/scripts/install-scry.ps1', $ScryInstaller); $ScryOk = $true } catch { $ScryOk = $false; Write-Host ('Scry: nao consegui baixar o instalador do GitHub: ' + $_.Exception.Message) -ForegroundColor Red }
if ($ScryOk) { @() | & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScryInstaller; $ScryRc = $LASTEXITCODE } else { $ScryRc = 1 }
Remove-Item -LiteralPath $ScryInstaller -Force -ErrorAction SilentlyContinue
if ($ScryRc -ne 0) { Write-Host "Scry: a instalacao terminou com erro (codigo $ScryRc). Veja as mensagens acima." -ForegroundColor Red }
