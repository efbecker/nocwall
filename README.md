# Scry · Video Wall

O **Scry** controla as TVs do NOC pelo navegador. Ele roda num PC Windows ligado às TVs, abre um Chrome em cada painel e dá uma página web para a equipe trocar o que cada TV mostra, sem ir até o PC.

![Página do Scry: a parede ao vivo, os cenários e a biblioteca de dashboards](docs/img/painel.png)

## Instalar

No PC das TVs, abra o **Prompt de Comando como Administrador** (ou entre por SSH com um administrador) e cole:

```
curl.exe -fsSL https://raw.githubusercontent.com/efbecker/nocwall/main/install.ps1 | powershell -NoProfile -ExecutionPolicy Bypass -Command -
```

Ele instala sozinho, sem perguntas (inclusive o Google Chrome, se faltar), e no fim mostra um endereço e um código:

```
        https://192.168.0.40

        Código de instalação:  K7QM-3XPA
```

Depois, de qualquer PC da rede:

1. Abra o endereço. O navegador avisa sobre o certificado: clique em **Avançado → Continuar**.
2. Digite o código.
3. Preencha a senha do administrador, escolha o usuário do Windows que fica nas TVs e clique em **Concluir configuração**.

| Passo 1: o código | Passo 2: a configuração |
|---|---|
| ![Assistente pedindo o código de instalação](docs/img/assistente-codigo.png) | ![Assistente com administrador, usuário da parede, logon automático e Grafana](docs/img/assistente-config.png) |

Pronto. Entre no Windows com o usuário da parede (ou marque o **logon automático** no assistente) e as janelas abrem sozinhas, uma por painel. Reinicie o PC uma vez para ver tudo voltar sozinho.

### Antes de instalar

- Windows 10, 11 ou Server 2019+. O **Google Chrome** é instalado sozinho se não houver.
- Um usuário do Windows para as TVs (ex.: `parede`).
- Em **Configurações → Sistema → Tela**: telas na mesma posição da parede, **escala 100%** e resolução nativa. Em **Energia**: nunca desligar a tela nem suspender.
- A parede precisa somar **10 painéis Full HD**: cada TV 4K vale 4 e cada TV Full HD vale 1 (ex.: 2 TVs 4K + 2 Full HD).

<details>
<summary>Outras formas de instalar</summary>

**Pelo PowerShell** (mesmo resultado; funciona também no Prompt de Comando):

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/efbecker/nocwall/main/install.ps1 | iex"
```

**Sem internet, ou com nome no DNS e certificado `.pfx` próprio:** baixe o `Scry-vX.Y.Z.zip` em [Releases](../../releases), clique com o botão direito → **Propriedades → Desbloquear**, extraia e dê dois cliques em **`INSTALAR.cmd`**. Ele faz as perguntas no próprio terminal.

Opções avançadas (portas, redes permitidas): [NOC/INSTALAR.md](NOC/INSTALAR.md).

</details>

## Login do Grafana

Se os dashboards pedem login, informe um usuário **só leitura** no assistente ou depois em **Conta → Login do Grafana**. Use **Testar conexão** e **Salvar**: os painéis entram sozinhos em até 1 minuto. A senha fica protegida pelo Windows e nunca é mostrada de volta.

![Janela do Login do Grafana](docs/img/grafana-login.png)

## Usar

- **Trocar um dashboard:** passe o mouse num painel e clique em ✎ **Editar**, ou arraste um item da **Biblioteca** para o painel.
- **Cenários:** salve a parede inteira (ex.: *Dia*, *Noite*, *Incidente*) e aplique com um clique.
- **Mosaico:** junte painéis vizinhos numa tela maior.
- **Pausar a parede** por um tempo, **recarregar** ou **reabrir** tudo.
- **Grafana em tela cheia:** os links de dashboard (`/d/...`) abrem com `kiosk`, sem o menu lateral. Para outro modo, escreva o `kiosk` no próprio link. O balão do Google Tradutor fica desligado nas telas.
- **Usuários** com papéis `admin`, `operador` e `visualizador`, e auditoria de tudo.

![Botões de um painel: editar, recarregar, reabrir e abrir o link](docs/img/cartoes.png)

O Scry também se corrige sozinho: reabre janelas travadas, recarrega páginas com erro, refaz o login do Grafana e reabre tudo uma vez por dia. Detalhes: [NOC/LEIAME.md](NOC/LEIAME.md). Monitoração pelo Zabbix: [zabbix/](zabbix/LEIAME.md).

## Atualizar

Rode **o mesmo comando** da instalação. Ele faz backup, atualiza e mantém painéis, usuários e auditoria. Para voltar à versão anterior:

```
powershell -ExecutionPolicy Bypass -File C:\NOC\Update-NocManager.ps1 -Reverter
```

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| "Abra o PowerShell como Administrador" | abra o terminal com *Executar como administrador* |
| O comando não mostra nada | o PC não alcança o GitHub; teste `curl.exe -I https://raw.githubusercontent.com` ou use o `INSTALAR.cmd` |
| "O pacote baixado é a v1.5.x…" | o último Release é antigo; crie um Release novo (veja abaixo) |
| "Código inválido ou vencido" | rode o comando de instalação de novo: ele mostra outro código |
| Faixa vermelha "Chrome não instalado" | rode o comando de instalação de novo (ele instala o Chrome) e clique em **Reabrir tudo** |
| Faixa vermelha "Usuário da parede não está logado" | entre no Windows com o usuário da parede (ou ative o logon automático) |
| Painéis na tela de login do Grafana | **Conta → Login do Grafana → Testar conexão** |
| Janelas do Chrome não abrem | confira o logon automático e a tarefa `NOC-VideoWall` no *Agendador de Tarefas* |
| A página não abre | veja `C:\NOC\Manager\diag.log` e a tarefa `NOC-Manager` |
| Esqueci a senha do `admin` | `powershell -ExecutionPolicy Bypass -File C:\NOC\Manager\NocManager.ps1 -NovoAdmin admin` |

Mais casos: [NOC/LEIAME.md](NOC/LEIAME.md#problemas-comuns). Desinstalar: `powershell -ExecutionPolicy Bypass -File C:\NOC\Install-NocManager.ps1 -Remover`.

---

## Para quem mantém o projeto

- **Nova versão:** mude `$Version` em `NOC/Manager/NocManager.ps1` e crie um Release com a tag `vX.Y.Z` (aba **Releases → Draft a new release**). O GitHub Actions gera o `Scry-vX.Y.Z.zip` e anexa ao Release. Crie o Release **depois** do merge, com o alvo na `main` atual: o Actions confere se a tag bate com o `$Version` e falha se não bater. O comando de instalação sempre baixa o último Release.
- **Gerar o pacote à mão** (Windows): `powershell -ExecutionPolicy Bypass -File .\Build-Pacote.ps1` (sai em `dist\`).
- Os `.ps1` precisam ficar em **ASCII** (sem acentos): o Windows PowerShell 5.1 lê UTF-8 sem BOM como ANSI. O workflow falha se achar acento.

| Pasta/arquivo | O que tem |
|---|---|
| `install.ps1` | o comando de instalação: só baixa e roda o `scripts/install-scry.ps1` |
| `scripts/install-scry.ps1` | o instalador de verdade (baixa o Release, instala ou atualiza, mostra o código) |
| `INSTALAR.cmd` | instalar pelo pacote, com dois cliques |
| `NOC/` | o programa, que vai para `C:\NOC` ([uso](NOC/LEIAME.md), [instalação detalhada](NOC/INSTALAR.md)) |
| `docs/img/` | imagens deste README |
| `zabbix/`, `brand/` | template de monitoração e identidade visual |
