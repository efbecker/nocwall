# Scry no Zabbix

Template `scry_template.yaml` (Zabbix 7.0): lê `{$SCRY.URL}/api/saude` a cada minuto (agente HTTP) e cria os itens e alertas abaixo.

## Importar

1. *Coleta de dados → Templates → Importar*, escolha `scry_template.yaml`.
2. Crie um host, por exemplo `Scry Video Wall NOC`, com o template **Scry Video Wall**. Não precisa de interface nem de agente.
3. O host precisa ser monitorado por um servidor ou proxy de dentro da rede interna. O Scry recusa IPs fora do `-AllowFrom`.
4. Se o endereço for outro, ajuste a macro `{$SCRY.URL}` no host (sem barra no fim).

## Alertas

| Alerta | Severidade |
|---|---|
| Sem resposta há 5 min | Alta |
| RAM do PC acima de 90% por 10 min | Alta |
| Certificado vence em menos de 7 dias | Alta |
| Painel fechado (há mais de 2 min, por 5 min) | Média |
| Painel sem resposta há 10 min | Média |
| Painel na tela de login do Grafana há 10 min | Média |
| Painel com imagem congelada há 30 min | Atenção |
| Painel com erro de rede há 10 min | Atenção |
| Gerenciador reiniciou por memória 3+ vezes em 24 h | Atenção |
| Certificado vence em menos de 30 dias | Atenção |
| Parede pausada há mais de 4 h · gerenciador reiniciou · versão mudou | Informação |

A auto-correção do Scry age antes dos alertas: eles disparam só quando ela não resolveu.
