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

## Instalação passo a passo (deploy)

Tempo estimado: 20 a 30 minutos. Você só vai precisar dar **dois cliques num arquivo** e responder algumas perguntas.

### Antes de começar: o que ter em mãos

| Item | Observação |
|---|---|
| Um PC com **Windows 10 ou 11** ligado às TVs | com o **Google Chrome** instalado |
| Acesso de **Administrador** nesse PC | o instalador pede permissão |
| Um **usuário do Windows para a parede** (ex.: `parede`) | é ele que fica logado mostrando as TVs |
| Um **endereço** para o Scry (ex.: `scry.suaempresa.local`) | alguém da TI cria esse nome no DNS interno apontando para o IP do PC |
| *(opcional)* Certificado `.pfx` que cubra esse endereço e a senha dele | sem ele, o Scry gera um certificado próprio e o navegador mostra um aviso |
| *(opcional)* Usuário **só leitura do Grafana** | só se os dashboards pedirem login |

> **Importante:** esta versão foi feita para uma parede de **exatamente 10 painéis de 1920×1080**. Cada TV 4K conta como 4 painéis e cada TV Full HD conta como 1. Exemplo: 2 TVs 4K + 2 TVs Full HD = 10 painéis. Outro arranjo exige ajuste no código.

### Passo 1. Preparar o PC

1. Ligue todas as TVs. Em **Configurações → Sistema → Tela**:
   - arrume as telas na mesma posição em que estão na parede;
   - deixe a **escala em 100%** em todas;
   - use a resolução nativa (4K = 3840×2160, Full HD = 1920×1080).
2. **Logon automático** do usuário da parede: aperte `Win + R`, digite `netplwiz`, desmarque *"Os usuários devem digitar um nome de usuário e uma senha"* e informe o usuário da parede.
3. **Energia:** em **Configurações → Sistema → Energia**, coloque *Nunca* para desligar a tela e para suspender. Desative a proteção de tela.
4. Se houver outro programa de video wall no PC, feche e tire da inicialização, ou eles vão brigar pelas telas.

### Passo 2. Baixar o pacote

Baixe o arquivo **`Scry-vX.Y.Z.zip`** mais recente na aba **[Releases](../../releases)** deste repositório.

> Ainda não tem Release? Veja [Gerar o pacote](#gerar-o-pacote-para-quem-mantém-o-projeto) mais abaixo.

### Passo 3. Extrair

1. Clique com o botão direito no `.zip` → **Propriedades** → marque **Desbloquear** (se aparecer) → **OK**. Isso evita o aviso "O Windows protegeu o computador".
2. Botão direito no `.zip` → **Extrair tudo…** → pode ser em qualquer pasta (por exemplo, `Downloads`).

Dentro da pasta extraída você vai ver:

```
Scry-vX.Y.Z\
  INSTALAR.cmd   <- é este que você vai usar
  README.md
  NOC\
```

### Passo 4. Instalar com dois cliques

1. Dê **dois cliques em `INSTALAR.cmd`**.
2. O Windows pergunta se o programa pode fazer alterações: clique em **Sim**.
3. Responda as perguntas. Apertar **Enter** aceita o valor sugerido entre colchetes:

| Pergunta | O que responder |
|---|---|
| Usuário do Windows que fica logado na parede | o usuário da parede, ex.: `NOME-DO-PC\parede` |
| Endereço (HostName) | o nome criado no DNS, ex.: `scry.suaempresa.local` |
| Caminho do .pfx | o caminho do certificado, ex.: `C:\temp\cert.pfx`, ou **Enter** para gerar um autoassinado |
| Gravar a credencial do Grafana agora | só aparece se você estiver logado como o usuário da parede |
| Continuar | confira o resumo e aperte **Enter** |
| Senha do usuário `admin` do Scry | mínimo de 10 caracteres. **Guarde no cofre de senhas da equipe.** |
| Senha do PFX | só se você informou um `.pfx` |

No fim aparece **"Scry instalado! Acesse https://…"** e o navegador abre a página.

O `INSTALAR.cmd` copia tudo para `C:\NOC` sozinho, confere os pré-requisitos e grava um registro em `C:\NOC\deploy.log`. Depois disso você pode apagar a pasta extraída e o `.pfx` temporário.

### Passo 5. Credencial do Grafana (só se os dashboards pedem login)

Ela fica criptografada e **só o usuário da parede consegue criar e ler**. Se o instalador não gravou no passo 4, faça assim:

1. Entre no Windows **como o usuário da parede**.
2. Abra o **PowerShell** normal (não precisa ser como Administrador) e rode, trocando `USUARIO_GRAFANA`:
   ```powershell
   Get-Credential -UserName USUARIO_GRAFANA -Message Grafana | Export-Clixml C:\NOC\grafana.cred
   ```
3. Digite a senha do Grafana na janela que abrir.

### Passo 6. Conferir

1. Faça **logoff e logon** do usuário da parede (ou espere até 5 minutos). As janelas do Chrome abrem sozinhas, uma por painel.
2. Em outro PC da rede, abra `https://SEU-ENDERECO` e entre com `admin`.
3. Os 10 painéis devem aparecer **verdes** na grade, com miniaturas.
4. **Reinicie o PC uma vez.** A parede e o Scry precisam voltar sozinhos cerca de 1 minuto depois do logon.

Pronto! Agora ajuste os dashboards de cada painel pela página (**Editar** ou arrastando da **Biblioteca**), salve o arranjo em **Gerenciar → Salvar a parede atual em um cenário** e crie os usuários da equipe em **Conta → Usuários**.

---

## Atualizar para uma versão nova

É o mesmo caminho da instalação:

1. Baixe e extraia o `.zip` novo (em qualquer pasta, **menos** dentro de `C:\NOC`).
2. Dois cliques em **`INSTALAR.cmd`** → **Sim**.

O instalador percebe que o Scry já está instalado e só atualiza: faz backup em `C:\NOC\Manager\backups`, troca o código, reinicia e confere se a versão nova respondeu. **Painéis, usuários e auditoria são mantidos.**

Deu errado? Volte para a versão anterior (PowerShell como Administrador):

```powershell
powershell -ExecutionPolicy Bypass -File C:\NOC\Update-NocManager.ps1 -Reverter
```

## Outras tarefas

| Quero… | Como (PowerShell como Administrador) |
|---|---|
| Trocar o certificado, o endereço ou o usuário da parede | extraia o pacote e rode `INSTALAR.cmd -Reinstalar` num prompt de comando |
| Redefinir a senha do `admin` | `powershell -ExecutionPolicy Bypass -File C:\NOC\Manager\NocManager.ps1 -NovoAdmin admin` |
| Testar tudo automaticamente | `powershell -ExecutionPolicy Bypass -File C:\NOC\Test-NocManager.ps1 -Url https://SEU-ENDERECO -Usuario admin` (esperado: `0 falha(s)`) |
| Desinstalar | `powershell -ExecutionPolicy Bypass -File C:\NOC\Install-NocManager.ps1 -Remover` (remove tarefas, firewall e certificado das portas; mantém os arquivos) |

Opções avançadas do instalador (portas, redes permitidas, sem HTTP): [NOC/INSTALAR.md](NOC/INSTALAR.md).

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| "O Windows protegeu o computador" ao abrir o `INSTALAR.cmd` | clique em **Mais informações → Executar assim mesmo**, ou desbloqueie o `.zip` antes de extrair (passo 3) |
| "Telas: N painéis detectados (esperado: 10)" | escala diferente de 100%, resolução não nativa ou arranjo diferente de 10 blocos 1920×1080 |
| Navegador não acha o endereço | falta o registro no DNS interno, ou ele aponta para o IP errado |
| Navegador avisa sobre o certificado | o certificado é autoassinado; instale um confiável com `INSTALAR.cmd -Reinstalar` e um `.pfx` |
| "Acesso permitido somente pela rede interna" | o PC de quem acessa está numa rede fora das liberadas (`-AllowFrom`) |
| Painéis abrem na tela de login do Grafana | refaça o passo 5 logado como o usuário da parede |
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
| `INSTALAR.cmd` | instalar ou atualizar com dois cliques |
| `Build-Pacote.ps1` | gera o `.zip` de instalação |
| `NOC/` | o programa, que vai para `C:\NOC` no PC da parede ([uso e manutenção](NOC/LEIAME.md), [instalação detalhada](NOC/INSTALAR.md)) |
| `zabbix/` | template de monitoração ([LEIAME](zabbix/LEIAME.md)) |
| `brand/` | identidade visual ([BRAND](brand/BRAND.md)) |
