# Scry · Video Wall

> Veja o topo da operação.

O Scry gerencia as 10 telas do video wall pelo navegador. Permite trocar o link de cada painel, arrastar dashboards de uma biblioteca e aplicar cenários. Também mostra miniaturas ao vivo e o estado do PC, pausa a parede com prazo, controla o acesso por papéis e registra tudo numa auditoria.

## Estrutura (`C:\NOC`)

```
C:\NOC\
  Start-Wall.ps1            abre e encaixa uma janela do Chrome por painel; respeita a pausa; grava layout.json
  paineis.json              painéis, cenários e biblioteca (dado de produção; o gerenciador edita)
  paineis.exemplo.json      modelo usado só na primeira instalação
  layout.json               telas e blocos reais, gravado pelo Start-Wall (o gerenciador desenha a grade com ele)
  pausado.json              existe só enquanto a parede está pausada
  Deploy-Scry.ps1           instalação/atualização em um passo (chamado pelo INSTALAR.cmd do pacote)
  Install-NocManager.ps1    instalador (primeira vez, ou para recriar tarefas, certificado e firewall)
  Update-NocManager.ps1     atualização com backup e reinício (dia a dia)
  Test-NocManager.ps1       teste automático (roda de qualquer PC)
  Manager\
    NocManager.ps1          servidor HTTPS (PowerShell puro)
    www\index.html          interface
    www\setup.html          assistente de configuração (só aparece enquanto não existe nenhum usuário)
    users.json  audit.log  diag.log
    backups\                backups do Update (só SYSTEM e Administradores)
```

## Instalação (primeira vez, PowerShell como Administrador)

> Passo a passo completo para um PC novo (pré-requisitos, credencial do Grafana, DNS e certificado): **[INSTALAR.md](INSTALAR.md)**.
>
> **Mais simples ainda:** como Administrador (cmd, PowerShell ou SSH), `powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/efbecker/nocwall/main/install.ps1 | iex"`. Ele instala sem perguntas e mostra um endereço e um código; o resto (admin, usuário da parede, logon automático) é feito no navegador. Veja o [README](../README.md#instalação-deploy).
>
> **Mais simples:** extraia o pacote em qualquer pasta e dê dois cliques em `INSTALAR.cmd`. Ele copia para `C:\NOC`, pergunta o necessário e roda o instalador abaixo.

Forma manual:

1. Extraia o pacote e copie a pasta `NOC` para `C:\NOC`.
2. Rode o instalador, informando o usuário que fica logado na parede e a rede de gestão:
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\NOC\Install-NocManager.ps1 -WallUser NOME_DO_USUARIO
   ```
   Ele pede a senha do usuário `admin` (mínimo de 10 caracteres). Se não existir `paineis.json`, ele é criado a partir do exemplo.
3. Acesse **https://scry.armazem.cloud**. O nome precisa apontar para o PC da parede no DNS interno (hoje: 192.168.0.40).

**Endereço e portas** (parâmetros do instalador):

| Porta | Uso |
|---|---|
| 443 | endereço oficial `https://scry.armazem.cloud` (`-HostName`, `-Port`) |
| 80 | redireciona `http://` para `https://` (desligue com `-SemHttp`) |
| 8443 | endereço antigo; só redireciona para o novo (`-LegacyPort 0` desliga) |

**Certificado:**
- Sem parâmetros, o instalador gera um certificado autoassinado para `scry.armazem.cloud`. O navegador avisa até o certificado ser confiado.
- Para usar um certificado confiável (por exemplo, o curinga `*.armazem.cloud`), rode de novo com `-PfxPath C:\caminho\cert.pfx`. Ele pede a senha do PFX.

**Só rede interna:** `-AllowFrom` (padrão `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16`) vale no firewall do Windows e também dentro do próprio Scry. Assim, qualquer IP fora dessas redes recebe 403, mesmo com o firewall desligado.

| Tarefa | Conta | Quando | O que faz |
|---|---|---|---|
| `NOC-VideoWall` | usuário da parede | no logon e a cada 5 min | roda o `Start-Wall.ps1` sem abrir janela (watchdog) |
| `NOC-Manager` | SYSTEM | no boot (30 s de atraso) e a cada 5 min | servidor web (443, mais os redirecionamentos 80 e 8443); se o processo cair ou passar de 800 MB, sai e a repetição sobe de novo |

## Atualização (dia a dia)

Extraia o pacote novo **fora** de `C:\NOC` (por exemplo, em `C:\Temp\noc-v1.2`) e dê dois cliques no `INSTALAR.cmd` dele. Ele detecta que o Scry já está instalado e roda a atualização abaixo. Ou rode direto, como Administrador:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Temp\noc-v1.2\NOC\Update-NocManager.ps1 -AplicarParede
```

- Faz backup em `C:\NOC\Manager\backups` (guarda os 10 últimos).
- Copia só o código. `paineis.json`, usuários, auditoria e perfis não são tocados.
- Reinicia o gerenciador e confere se a versão nova respondeu.
- `-AplicarParede` roda o `Start-Wall.ps1` novo na hora. Ele não fecha janelas abertas.
- Para voltar à versão anterior: `Update-NocManager.ps1 -Reverter`.

## Teste

De qualquer PC Windows da rede de gestão:

```powershell
powershell -ExecutionPolicy Bypass -File Test-NocManager.ps1 -Url https://scry.armazem.cloud -Usuario admin -Thumbprint <SHA1>
```

- **O que verifica:** versão, proteções (401/403), login, estado, status, as 10 miniaturas, auditoria, usuários e a memória do gerenciador antes e depois.
- **Sem mexer na parede:** é o comportamento padrão. `-Acoes` também recarrega um painel (`-Painel 9`) e espera a miniatura nova. `-Mosaico` (admin) mescla os painéis 4 a 7 em 2×2, confere, separa e confere de novo.
- **Resultado:** o código de saída é o número de falhas.

## Uso

- **Grade**: desenhada como a parede física, com as telas e seus painéis. As cores indicam o estado:

  | Cor | Estado |
  |---|---|
  | Verde | ok |
  | Amarelo | carregando ou miniatura antiga |
  | Vermelho | offline |
  | Cinza | pausado |

  O selo **≠ cenário** marca painéis diferentes do cenário ativo.
- **Painel**: passe o mouse para ver as ações:
  - **Editar**: nome, link, zoom ou escolha da biblioteca. Avisa sobre `refresh` abaixo de 30s, links de login e `/goto/`.
  - **Recarregar**: F5 sem cache.
  - **Reabrir**: fecha e reabre a janela.
  - **Abrir ↗**: abre o dashboard no seu navegador.
- **Biblioteca**:
  - arraste um item para um painel, ou use **→** para escolher o painel (também funciona no celular);
  - arraste um painel sobre outro para trocá-los de lugar.
- **Mosaico** (só admin): junta painéis vizinhos numa tela maior, por exemplo os 4 painéis de uma 4K num 2×2.
  1. Clique em **▦ Mosaico** e depois nos painéis que vão virar uma tela só. A seleção precisa formar um retângulo; a barra roxa avisa o que falta.
  2. **Mesclar…** pergunta a escala: **Ampliar** (o dashboard fica igual, só que maior) ou **Mais espaço** (mesma letra, mais conteúdo).
  3. O painel do canto superior esquerdo ocupa a área toda e mantém o dashboard dele. Os outros ficam fechados e voltam, cada um com o seu dashboard, ao **Separar** (no cartão ou na barra do Mosaico).
  - Pode atravessar monitores físicos (a moldura entre eles corta a imagem; a tela avisa).
  - Selecionar um painel já mesclado e vizinhos aumenta a área.
  - Só as janelas da área reabrem (de 5 a 15 s); o resto da parede não pisca.
  - Os **cenários** guardam o mosaico. Um operador pode aplicar um cenário com mosaico, mas só o admin mescla ou separa.
  - O mosaico vale depois de reboot e respeita a pausa (aplica ao religar).
- **Desfazer**: toda troca de link, troca de lugar, mesclagem e aplicação de cenário mostra **Desfazer** por 10 s.
- **Progresso**: o cartão mostra "Trocando link… → Carregando… → ✓ Pronto" até a miniatura nova chegar.
- **Cenários**:
  - clique no nome para aplicar (pede confirmação se mais de 3 painéis forem mudar);
  - **Gerenciar** cria, sobrescreve, renomeia e exclui cenários.
- **Parede inteira**:
  - **Recarregar tudo**: um painel a cada 1,5 s.
  - **Reabrir tudo**: fecha e reabre todas as janelas (10, ou menos com mosaico).
  - **Pausar parede**: por 30 min, 1 h, 4 h ou até alguém religar. Enquanto valer, nada reabre, nem o watchdog nem um reboot. Com prazo, a parede religa sozinha no horário.
- **Topo**: painéis online, RAM, CPU e Chrome do PC da parede, tempo ligado, memória do gerenciador e o selo **Auto** (manutenção automática; passe o mouse para ver a próxima reabertura e a última ação).

## Manutenção automática

Configure em **Conta → Manutenção automática** (todos veem; só o admin altera). O Scry confere cada painel cerca de 1 vez por minuto, mesmo sem ninguém com a página aberta, e corrige sozinho:

| Situação | O cartão mostra | Ação automática |
|---|---|---|
| Janela fechada há 2 min | offline | aciona o watchdog (reabre) |
| Janela não responde (3 conferências seguidas) | não responde | reabre a janela |
| Página de erro do Chrome (sem rede/DNS) há 1 min | erro de rede | recarrega |
| Tela de login do Grafana há 2 min | tela de login | refaz o login automático |
| Imagem igual há 15 min num link com `refresh=` | congelado | recarrega; se continuar, reabre; depois só alerta |

- No máximo uma ação a cada 5 min por painel, e nunca no meio de uma ação de alguém. Nada acontece com a parede pausada.
- Toda ação vai para a auditoria (`AUTO_CORRECAO`), para o `diag.log` e para a lista da própria janela.
- **Reabertura diária preventiva** (padrão 04:00): reabre uma janela por vez, a cada 40 s, para liberar a memória que o Chrome acumula em dias ligado (foi a causa das quedas do C-Control). Vazio desliga.

## Monitoração pelo Zabbix

`https://scry.armazem.cloud/api/saude` responde sem login (só para a rede interna) com o estado da parede: `codigo` (0 ok, 1 alerta, 2 crítico), `resumo`, painéis por problema, RAM/CPU/Chrome do PC, memória e reinícios do gerenciador, dias para o certificado vencer e a próxima reabertura. Não expõe links nem nomes de dashboards.

O template está no repositório em `zabbix/scry_template.yaml` (Zabbix 7.0). Veja `zabbix/LEIAME.md`.
- **Papéis**:

  | Papel | Pode |
  |---|---|
  | `admin` | tudo, inclusive mosaico, usuários e auditoria |
  | `operador` | painéis, cenários, biblioteca e parede |
  | `visualizador` | só ver |

## Segurança

- Só HTTPS. A sessão expira em 12 h, com cookie `HttpOnly`, `Secure` e `SameSite=Strict`, e as alterações exigem um cabeçalho anti-CSRF.
- 5 senhas erradas seguidas bloqueiam o IP por 5 minutos.
- Desativar ou alterar um usuário derruba as sessões dele na hora.
- Só redes internas (`-AllowFrom`): o firewall do Windows libera 443, 80 e 8443 só para elas, e o próprio Scry recusa qualquer outro IP com 403. Os bloqueios ficam no `diag.log`.
- As portas de depuração do Chrome (9300 a 9309) ficam em 127.0.0.1.
- A pasta `Manager` (inclusive os backups) fica acessível só para SYSTEM e Administradores.

## Problemas comuns

| Sintoma | Verificar |
|---|---|
| Página lenta ou caiu | Veja `C:\NOC\Manager\diag.log`: registra requisições lentas, travadas e reinícios por memória. |
| Navegador avisa sobre o certificado | O certificado é autoassinado. Instale um confiável com `Install-NocManager.ps1 -PfxPath`. |
| "Acesso permitido somente pela rede interna" | O IP de origem está fora de `-AllowFrom`. Inclua a rede no instalador, se ela for interna. |
| Página não abre | `Get-ScheduledTask NOC-Manager` deve estar em *Running*. Teste rodando manualmente: `powershell -ExecutionPolicy Bypass -File C:\NOC\Manager\NocManager.ps1` |
| Parede apagada | Veja se há a faixa vermelha de **pausa** no topo da página e clique em **Religar**. |
| Painel vermelho (offline) | A janela está fechada ou foi aberta sem a porta de depuração. Use **Reabrir**. |
| Grade diferente da parede | O `layout.json` é regravado pelo watchdog a cada 5 min. Confira a escala 100% e o arranjo das telas no Windows. |
| Atualização deu errado | `Update-NocManager.ps1 -Reverter` restaura o código do último backup. |
| Esqueci a senha do admin | `powershell -ExecutionPolicy Bypass -File C:\NOC\Manager\NocManager.ps1 -NovoAdmin admin` (como Administrador) |
| Remover tudo | `Install-NocManager.ps1 -Remover`. Os arquivos, usuários e auditoria são mantidos. |
