# Scry · Identidade

> **Veja o topo da operação.**

## O nome

Em jogos de cartas como Magic, *scry* é uma mecânica: você olha as cartas do topo do baralho e decide o que fica em cima e o que vai para baixo. É o que a equipe faz com a parede do NOC: vê o que está no topo da operação e escolhe o que merece a tela.

O nome e o conceito vêm dessa ideia. Nenhum elemento gráfico do jogo é usado: nem símbolos, nem verso de carta, nem fontes ou ícones. Apenas um toque de identidade pessoal baseado nos meus hobbies. 

## Símbolo

| Arquivo | Uso |
|---|---|
| `scry-mark.svg` | símbolo (64×64), para documentos, slides e ícone grande |
| `scry-favicon.svg` | recorte justo do símbolo, para a aba do navegador e ícones pequenos |
| `scry-logo.svg` | símbolo e nome com o descritor "VIDEO WALL", na horizontal |

**Anatomia:**
- **Carta do topo, erguida:** é a tela que está sendo vista agora.
- **Olho:** representa a visão; a pupila em degradê é o "ao vivo".
- **Cartas de trás, inclinadas:** as outras telas e dashboards do baralho.

**Regras:**
- Use sobre fundo escuro (`#0a1216` ou `#0f1d25`). Sobre fundo claro, coloque o símbolo dentro de um quadrado escuro com cantos arredondados.
- Respeite uma área livre de pelo menos ¼ da largura do símbolo em volta.
- Não distorça, não gire, não troque as cores do degradê e não aplique contorno ou sombra dura.
- Abaixo de 24 px, use o `scry-favicon.svg`.

## Cores

| Nome | Hex | Papel |
|---|---|---|
| Ciano visão | `#3fd8e6` | início do degradê; destaques |
| Violeta arcano | `#8b7cf6` | fim do degradê; brilho do símbolo |
| Destaque UI | `#3fc9d8` | botões, foco e links da interface |
| Destaque UI escuro | `#1d8799` | botão principal |
| Fundo | `#0a1216` | fundo da aplicação |
| Painel | `#0f1d25` | cartões e caixas |
| Texto | `#d8e6ec` | texto principal |
| Texto suave | `#7f98a4` | rótulos e o descritor "VIDEO WALL" |

**Degradê da marca:** `linear-gradient(135deg, #3fd8e6, #8b7cf6)`. O nome "Scry" usa o mesmo degradê em versão clara, `#e6f6f8 → #c9c2ff`.

As cores de estado (verde ok, amarelo carregando, vermelho offline) não fazem parte da marca. Elas continuam reservadas para sinalizar estado.

## Tipografia

- **Nome "Scry":** Segoe UI (ou a fonte do sistema), peso 700, espaçamento +0,5.
- **Descritor "VIDEO WALL":** caixa alta, peso 600, espaçamento largo (+3,2 px), cor de texto suave.
- **Interface:** Segoe UI e system-ui, sem fontes externas, porque a página roda com CSP restrita.

## Voz

- **Slogan:** *Veja o topo da operação.*
- **Título da página e da aba:** **Scry · Video Wall**.
- **Tom:** curto, operacional e direto. A metáfora da carta fica no nome e no símbolo; a interface fala a língua do NOC (painel, tela, cenário), não a do jogo.

## Nomes técnicos

A marca vale para o que as pessoas veem. Os nomes internos continuam os mesmos para não quebrar a instalação:
- pasta `C:\NOC`;
- tarefas `NOC-Manager` e `NOC-VideoWall`;
- scripts `NocManager.ps1` e `*-NocManager.ps1`;
- certificado "NOC Manager" e regra de firewall.
