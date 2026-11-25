# Scry · Video Wall

> Veja o topo da operação.

O **Scry** controla o video wall (as TVs) do NOC a partir do navegador. Ele roda num PC Windows ligado às telas, abre um Google Chrome em cada painel e oferece uma página web onde a equipe troca o que cada TV mostra, sem precisar ir até o PC.

## O que ele faz

- **Troca o dashboard de cada painel** pelo navegador: editar o link, arrastar da **biblioteca** ou aplicar um **cenário** pronto (com **Desfazer** por 10 s).
- **Mostra a parede ao vivo**: miniaturas de cada painel, com cores de estado (ok, carregando, offline, pausado), e o estado do PC (RAM, CPU, Chrome).
- **Mosaico**: junta painéis vizinhos numa tela maior (por exemplo, 4 painéis de uma TV 4K num 2×2).
- **Pausa a parede** por 30 min, 1 h, 4 h ou até alguém religar.
- **Se corrige sozinho**: reabre janelas fechadas ou travadas, recarrega páginas com erro de rede, refaz o login do Grafana e reabre tudo uma vez por dia (padrão 04:00) para liberar memória.
- **Controle de acesso**: usuários com papéis `admin`, `operador` e `visualizador`, e uma auditoria de tudo que foi feito.
- **Monitoração pelo Zabbix**: a rota `/api/saude` informa o estado da parede (template em [`zabbix/`](zabbix/LEIAME.md)).

Detalhes de cada função: [NOC/LEIAME.md](NOC/LEIAME.md).

### Como funciona por baixo

O instalador cria duas tarefas agendadas no Windows, e não é preciso instalar mais nada além do Chrome:

| Tarefa | Roda como | O que faz |
|---|---|---|
| `NOC-VideoWall` | usuário logado na parede | abre e posiciona uma janela do Chrome por painel; roda no logon e a cada 5 min |
| `NOC-Manager` | SYSTEM | servidor web HTTPS (PowerShell puro) da página de gestão; sobe no boot e volta sozinho se cair |

Tudo fica em `C:\NOC`.

---

## Instalação (deploy)

São **dois passos**: um comando no PC da parede e o resto pelo navegador. Tempo estimado: 15 minutos.

> **Importante:** esta versão foi feita para uma parede de **exatamente 10 painéis de 1920×1080**. Cada TV 4K conta como 4 painéis e cada TV Full HD conta como 1. Exemplo: 2 TVs 4K + 2 TVs Full HD = 10 painéis. Outro arranjo exige ajuste no código.

### Antes de começar

1. Um PC com **Windows 10 ou 11**, ligado às TVs, com o **Google Chrome** instalado.
2. Um **usuário do Windows para a parede** (ex.: `parede`). É ele que fica logado mostrando as TVs.
3. Com as TVs ligadas, em **Configurações → Sistema → Tela**: arrume as telas na mesma posição da parede, deixe a **escala em 100%** e use a resolução nativa (4K = 3840×2160, Full HD = 1920×1080).
4. Em **Configurações → Sistema → Energia**, coloque *Nunca* para desligar a tela e para suspender.
5. Se houver outro programa de video wall no PC, feche e tire da inicialização.

### Passo 1. Rodar o comando de instalação

No PC da parede, abra o **Prompt de Comando** ou o **PowerShell como Administrador** (botão direito no menu Iniciar → *Terminal (Admin)*) e cole esta linha inteira:

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/efbecker/nocwall/main/install.ps1 | iex"
```

Também funciona por **SSH** numa sessão de administrador. A mesma linha serve no `cmd` e no PowerShell. A parte do `Tls12` é necessária no Windows Server 2019 e em Windows 10 mais antigos; sem ela o GitHub recusa a conexão.

O comando **nunca pede nada no terminal**: tudo que precisa de resposta é feito no navegador. Ele precisa de um Release **v1.6.0 ou mais novo**; se o último Release for mais antigo, ele avisa e para sem mudar nada.

O comando baixa a versão mais recente da aba [Releases](../../releases), copia para `C:\NOC`, cria o certificado, libera o firewall só para as redes internas e sobe o servidor web. No fim ele mostra algo assim:

```
[4/4] Pronto! Agora termine a configuração pelo navegador, de qualquer PC da rede:

        https://192.168.0.40

        Código de instalação:  K7QM-3XPA
        (vale por 24 horas; rodar este comando de novo gera outro)
```

### Passo 2. Terminar pelo navegador

1. De qualquer PC da rede, abra o endereço mostrado (`https://IP-DO-PC`). O navegador avisa sobre o certificado, porque ele é autoassinado: clique em **Avançado → Continuar**.
2. Digite o **código de instalação**.
3. O assistente mostra o que encontrou no PC (nome, IP, Chrome e telas) e pede:
   - **Administrador do Scry:** usuário e senha (mínimo de 10 caracteres). **Guarde no cofre de senhas da equipe.**
   - **Usuário da parede:** escolha na lista o usuário do Windows que fica logado nas TVs.
   - **Logon automático (opcional):** marque para o Windows entrar sozinho com esse usuário quando o PC ligar. Ele pede a senha desse usuário, confere e guarda protegida pelo Windows. Pode também reiniciar o PC na hora para testar.
   - **Login do Grafana (opcional):** endereço, usuário e senha, com botão **Testar conexão** (veja abaixo).
4. Clique em **Concluir configuração**. O assistente some e a página passa a ser o Scry normal, com login.

Depois disso:

- Entre no Windows como o usuário da parede (ou espere o logon automático). As janelas do Chrome abrem sozinhas, uma por painel.
- Entre no Scry com o administrador. Os 10 painéis devem aparecer **verdes**, com miniaturas.
- Ajuste os dashboards (**Editar** ou arrastando da **Biblioteca**), salve o arranjo em **Gerenciar → Salvar a parede atual em um cenário** e crie os usuários da equipe em **Conta → Usuários**.
- **Reinicie o PC uma vez** para confirmar que tudo volta sozinho.

### Login do Grafana (só se os dashboards pedem login)

Configure pelo navegador, no próprio assistente (passo 2) ou depois em **Conta → Login do Grafana** (só administradores):

1. Informe o **endereço do Grafana** (ex.: `https://grafana.suaempresa.com`), um **usuário só leitura** e a **senha**.
2. Clique em **Testar conexão**: o Scry faz o mesmo login que a parede vai fazer e diz se o Grafana aceitou.
3. **Salvar**. Os painéis que estiverem na tela de login entram sozinhos em até 1 minuto.

A senha fica guardada protegida pelo Windows (DPAPI) em `C:\NOC\grafana.json`, que só o sistema, os administradores e o usuário da parede conseguem ler. Ela nunca é mostrada de volta na tela: para trocar, digite uma nova. A senha só é enviada para o endereço configurado.

> Instalações antigas que usavam o `grafana.cred` (criado pelo PowerShell) continuam funcionando. Quando o login é salvo pela interface, ele passa a valer no lugar do arquivo antigo.

### Outra forma: pacote com dois cliques (sem internet, ou com nome e certificado próprios)

Use quando o PC não acessa o GitHub, ou quando você já quer instalar com um **nome no DNS** (ex.: `scry.suaempresa.local`) e um **certificado `.pfx`**:

1. Baixe o `Scry-vX.Y.Z.zip` na aba [Releases](../../releases) e leve para o PC.
2. Botão direito no `.zip` → **Propriedades** → marque **Desbloquear** → **OK**. Depois, **Extrair tudo…**.
3. Dois cliques em **`INSTALAR.cmd`** → **Sim**. Responda as perguntas (Enter aceita o valor sugerido): usuário da parede, endereço, caminho do `.pfx` (ou Enter para autoassinado) e a senha do `admin`.

Tem o zip, mas quer o caminho do assistente? Rode `$env:SCRY_ZIP = 'C:\caminho\Scry-vX.Y.Z.zip'` e depois o comando do passo 1.

---

## Atualizar para uma versão nova

Rode **o mesmo comando** do passo 1, como Administrador:

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/efbecker/nocwall/main/install.ps1 | iex"
```

Ele percebe que o Scry já está instalado e só atualiza: faz backup em `C:\NOC\Manager\backups`, troca o código, reinicia e confere se a versão nova respondeu. **Painéis, usuários e auditoria são mantidos.** Com o pacote, dá no mesmo: extraia o zip novo **fora** de `C:\NOC` e dê dois cliques no `INSTALAR.cmd`.

Deu errado? Volte para a versão anterior (PowerShell como Administrador):

```powershell
powershell -ExecutionPolicy Bypass -File C:\NOC\Update-NocManager.ps1 -Reverter
```

## Outras tarefas

| Quero… | Como (PowerShell como Administrador) |
|---|---|
| Usar um nome no DNS e um certificado `.pfx` no lugar do IP, ou trocar o usuário da parede | rode `C:\NOC\INSTALAR.cmd -Reinstalar` num prompt de comando como Administrador e responda as perguntas |
| Gerar um código novo para o assistente (venceu ou perdeu) | rode o comando de instalação de novo |
| Redefinir a senha do `admin` | `powershell -ExecutionPolicy Bypass -File C:\NOC\Manager\NocManager.ps1 -NovoAdmin admin` |
| Testar tudo automaticamente | `powershell -ExecutionPolicy Bypass -File C:\NOC\Test-NocManager.ps1 -Url https://SEU-ENDERECO -Usuario admin` (esperado: `0 falha(s)`) |
| Desinstalar | `powershell -ExecutionPolicy Bypass -File C:\NOC\Install-NocManager.ps1 -Remover` (remove tarefas, firewall e certificado das portas; mantém os arquivos) |

Opções avançadas do instalador (portas, redes permitidas, sem HTTP): [NOC/INSTALAR.md](NOC/INSTALAR.md).

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| "Abra o PowerShell como Administrador" | o comando precisa de uma janela aberta com *Executar como administrador* (ou SSH com um usuário administrador) |
| `'irm' não é reconhecido como um comando` | você colou só o `irm …` no Prompt de Comando; use a linha completa do passo 1, que começa com `powershell` |
| "O pacote baixado é a v1.5.x…" | o último Release é anterior à 1.6.0; crie um Release novo e rode de novo |
| "O Release … não tem o pacote" | o GitHub Actions ainda está gerando o zip; espere 1 minuto e rode de novo |
| "Código inválido ou vencido" | rode o comando de instalação de novo para gerar outro código |
| Logon automático não entra sozinho | confira a senha do usuário; contas com *Windows Hello* exigido podem bloquear o logon automático (desative em *Contas → Opções de entrada*) |
| "O Windows protegeu o computador" ao abrir o `INSTALAR.cmd` | clique em **Mais informações → Executar assim mesmo**, ou desbloqueie o `.zip` antes de extrair |
| "Telas: N painéis detectados (esperado: 10)" | escala diferente de 100%, resolução não nativa ou arranjo diferente de 10 blocos 1920×1080 |
| Navegador não acha o endereço | falta o registro no DNS interno, ou ele aponta para o IP errado |
| Navegador avisa sobre o certificado | o certificado é autoassinado; instale um confiável com `INSTALAR.cmd -Reinstalar` e um `.pfx` |
| "Acesso permitido somente pela rede interna" | o PC de quem acessa está numa rede fora das liberadas (`-AllowFrom`) |
| Painéis abrem na tela de login do Grafana | em **Conta → Login do Grafana**, use **Testar conexão**; confira endereço, usuário e senha |
| Janelas do Chrome não abrem | confira o logon automático e se a tarefa `NOC-VideoWall` existe no *Agendador de Tarefas* |
| Página não abre | veja `C:\NOC\Manager\diag.log` e se a tarefa `NOC-Manager` está *Em execução* |

Mais casos: [NOC/LEIAME.md](NOC/LEIAME.md#problemas-comuns).

---

## Gerar o pacote (para quem mantém o projeto)

**Automático (recomendado):** crie uma tag de versão e envie. O GitHub Actions confere os scripts, gera o `.zip` e publica na aba **Releases**:

```bash
git tag v1.5.0
git push origin v1.5.0
```

Em todo push e pull request o mesmo workflow gera o `.zip` e deixa para download em *Actions → execução → Artifacts*.

**Manual, num PC Windows:**

```powershell
powershell -ExecutionPolicy Bypass -File .\Build-Pacote.ps1
```

O pacote sai em `dist\Scry-vX.Y.Z.zip`. A versão vem de `$Version` em `NOC/Manager/NocManager.ps1`. Nenhum dado de produção (painéis, usuários, credenciais, logs) entra no pacote.

> Os scripts `.ps1` precisam ficar em **ASCII** (sem acentos): o Windows PowerShell 5.1 lê UTF-8 sem BOM como ANSI. O workflow falha se encontrar acento num `.ps1`.

## Estrutura do repositório

| Pasta/arquivo | O que tem |
|---|---|
| `install.ps1` | instalação/atualização com um comando (passo 1) |
| `INSTALAR.cmd` | instalar ou atualizar pelo pacote, com dois cliques |
| `Build-Pacote.ps1` | gera o `.zip` de instalação |
| `NOC/` | o programa, que vai para `C:\NOC` no PC da parede ([uso e manutenção](NOC/LEIAME.md), [instalação detalhada](NOC/INSTALAR.md)) |
| `zabbix/` | template de monitoração ([LEIAME](zabbix/LEIAME.md)) |
| `brand/` | identidade visual ([BRAND](brand/BRAND.md)) |
