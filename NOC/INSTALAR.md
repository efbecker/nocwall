# Scry · Instalar em outro computador

Guia para instalar o Scry num PC de video wall novo, do zero. Tempo estimado: 30 minutos, mais o ajuste dos painéis.

> **Antes de começar, confira:** nesta versão o Scry controla uma parede de **exatamente 10 painéis de 1920×1080**. Cada saída 4K do Windows vira 4 painéis e cada saída 1080p vira 1. A parede do NOC (2 telas 4K + 2 de 1080p) dá os 10. Se o novo PC tiver outro arranjo, ou outra quantidade de telas, fale com o responsável pelo projeto antes: isso exige ajuste no código.

## O que você precisa ter em mãos

| Item | Onde conseguir |
|---|---|
| Pacote `Scry-vX.Y.Z.zip` (a versão mais recente) | repositório privado `github.com/armazemcloud/Scry` (aba *Tags* → baixar o .zip) ou com o responsável pelo projeto |
| Conta de administrador local do PC | TI |
| Usuário Windows que fica logado na parede (logon automático) | criar no PC, por exemplo `parede` |
| Usuário do Grafana só leitura para a parede | administrador do Grafana |
| Nome interno do novo endereço, por exemplo `scry-jlle.armazem.cloud` | criar o registro A no DNS interno apontando para o IP do PC |
| Certificado `*.armazem.cloud` (`armazem_cloud.pfx`) e a senha | `\\armazemdc-files\NOC$\Gestão Infraestrutura\ArmazemDC\Certificados\armazem.cloud\` (pasta da validade atual; senha na linha **PFX** do `senhas.txt`) |

## 1. Preparar o PC

1. **Windows 10 ou 11** atualizado, com o **Google Chrome** instalado.
2. **Telas:** ligue todas e, em *Configurações → Sistema → Tela*:
   - arranje as telas na posição física real;
   - deixe a **escala em 100%** em todas;
   - use a resolução nativa (4K como 3840×2160, Full HD como 1920×1080).
3. **Usuário da parede** com logon automático. Rode `netplwiz`, desmarque "Os usuários devem digitar um nome de usuário e uma senha" e informe o usuário da parede.
4. **Energia:** em *Configurações → Sistema → Energia*, desligue a suspensão e o desligamento da tela. Desative a proteção de tela.
5. **Outros programas de parede** (C-Control, players de sinalização e afins): pare e tire da inicialização, ou eles vão brigar pelas telas.

## 2. Copiar o pacote

1. Extraia o `.zip` em `C:\`. Ele já traz a pasta `NOC`, e o resultado deve ser `C:\NOC\Install-NocManager.ps1`, `C:\NOC\Manager\...` e assim por diante.
2. Copie o `armazem_cloud.pfx` para uma pasta temporária, por exemplo `C:\temp\armazem.pfx`. Ele é apagado no fim.

## 3. Credencial do Grafana (logado como o usuário da parede)

Entre no Windows **como o usuário da parede**. Abra o PowerShell (não precisa ser como administrador) e rode, trocando `USUARIO_GRAFANA` pelo login do Grafana:

```powershell
Get-Credential -UserName USUARIO_GRAFANA -Message Grafana | Export-Clixml C:\NOC\grafana.cred
```

A janela pede a senha do Grafana. O arquivo fica criptografado e só esse usuário, neste PC, consegue usá-lo. Se for criado por outro usuário, o login automático do Grafana não funciona.

## 4. Instalar (PowerShell como Administrador)

Troque o nome do PC, o usuário da parede e o endereço:

```powershell
powershell -ExecutionPolicy Bypass -File C:\NOC\Install-NocManager.ps1 `
  -WallUser "NOME-DO-PC\parede" `
  -HostName scry-jlle.armazem.cloud `
  -PfxPath C:\temp\armazem.pfx
```

O instalador pede duas senhas:

1. **Senha do usuário `admin` do Scry** (mínimo de 10 caracteres). É o administrador da interface web desta instalação; guarde no cofre de senhas da equipe.
2. **Senha do PFX.**

No fim deve aparecer `Pronto! Acesse: https://scry-jlle.armazem.cloud`. Então:

- Apague o certificado temporário: `Remove-Item C:\temp\armazem.pfx`.
- Faça logoff e logon do usuário da parede, ou aguarde até 5 minutos: as janelas do Chrome abrem sozinhas.

Opções do instalador, se precisar:

| Opção | Para quê |
|---|---|
| `-AllowFrom "10.0.0.0/8,192.168.0.0/16"` | redes que podem acessar (padrão: todas as faixas internas) |
| `-SemHttp` | não abrir a porta 80 (redirecionamento de http para https) |
| `-LegacyPort 0` | não abrir a porta 8443 (só faz sentido em PCs que já usavam o endereço antigo) |
| sem `-PfxPath` | gera certificado autoassinado (o navegador vai avisar) |

## 5. Conferir

1. **Navegador:** abra `https://scry-jlle.armazem.cloud`. Deve abrir sem aviso de certificado. Entre com `admin`.
2. **Parede:** os 10 painéis devem aparecer online na grade, com miniaturas. As telas Tela 1, Tela 2 e assim por diante precisam bater com a parede física.
3. **Teste automático**, de qualquer PC da rede:
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\NOC\Test-NocManager.ps1 -Url https://scry-jlle.armazem.cloud -Usuario admin
   ```
   Espere `Resultado: 0 falha(s)`.
4. **Reboot:** reinicie o PC uma vez. A parede e o Scry precisam voltar sozinhos em cerca de 1 minuto depois do logon.

## 6. Ajustar os painéis

O pacote vem com os dashboards da parede de Brusque como exemplo. Na interface:

- use **Editar** em cada painel, ou arraste da **Biblioteca**, para colocar os dashboards deste local;
- use **Gerenciar → Salvar a parede atual em um cenário** para gravar o arranjo final;
- crie os usuários da equipe em **Conta → Usuários** (`operador` para quem troca painéis, `visualizador` para quem só olha).

Prefira links do Grafana com `refresh=30s` ou mais e com `&kiosk`. A interface avisa quando não estiverem assim.

## Problemas comuns na instalação

| Sintoma | Causa provável |
|---|---|
| Aviso "Paineis detectados: N (esperado: 10)" | escala diferente de 100% ou arranjo de telas diferente de 10 blocos 1920×1080 |
| Painéis abrem na tela de login do Grafana | o `grafana.cred` não foi criado pelo usuário da parede, ou a senha mudou (refaça o passo 3) |
| "O certificado do PFX não cobre ..." | o `-HostName` não termina em `.armazem.cloud` |
| Navegador não acha o endereço | falta o registro no DNS interno, ou ele aponta para o IP errado |
| "Acesso permitido somente pela rede interna" | o PC de quem acessa está numa rede fora do `-AllowFrom` |
| Janelas não abrem | confira o logon automático e se a tarefa `NOC-VideoWall` existe em *Agendador de Tarefas* |

## Depois de instalado

- **Atualizar** para uma versão nova: extraia o pacote novo fora de `C:\NOC` e rode `Update-NocManager.ps1` (detalhes no `LEIAME.md`).
- **Renovar o certificado** quando o curinga vencer: rode de novo o passo 4 com o PFX novo.
- **Manual de uso** e solução de problemas do dia a dia: `C:\NOC\LEIAME.md`.
