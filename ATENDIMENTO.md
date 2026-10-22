# Atendimento humano no backoffice da Ana

O que entrou em 22/10/2026 e como ligar cada parte. A ordem importa: banco, usuarios, n8n, webhooks, modelos da Meta.

## O que a equipe ganha

| Onde | O que faz |
| --- | --- |
| Conversa aberta | **Pausar a Ana / Retomar a Ana**: a Ana para de responder aquele cliente. **Assumir**: a conversa passa a ser sua (aparece em "Minhas"). Caixa de resposta no rodape: o texto sai pelo numero oficial, em nome da equipe, e a Ana entra em pausa sozinha. |
| Etiquetas | Novo, quente, morno, frio, agendado, perdido, pediu humano, fechado. O banco calcula uma etiqueta automatica a cada mensagem (preco perguntado + 3 mensagens = quente; visita registrada = agendado; 24 h sem resposta do cliente = frio; 7 dias = perdido). A equipe pode escolher uma manual no seletor da conversa; ela vence a automatica. Filtro por etiqueta na lista. |
| Ficha do lead | Ao lado da conversa (botao "Ficha" em telas menores): etiqueta, estado da Ana, responsavel, interesse, renda, unidade, visita, status, resumo e **notas da equipe** (Ctrl+Enter salva). O gerente pode passar a conversa para outra pessoa. |
| Busca | Nome, numero ou **palavra dentro das conversas** (3 letras ou mais). |
| Agendamentos | Cada visita tem **Confirmar / remarcar**: confirmada, remarcada (com dia e periodo novos), realizada ou cancelada, com observacao. O status volta para a aba Leads da planilha sozinho. |
| Nao resolvidas | Quem pediu uma pessoa, quem ouviu um "nao sei" da Ana e quem sumiu depois de perguntar preco (ultimos 30 dias). |
| Painel (so gerente) | Conversas por dia, leads, visitas, pedidos de humano, tempo medio da 1a resposta da Ana, horario de pico, conversas por etiqueta. Periodo de 7, 30 ou 90 dias. |
| Exportar | Botao de download na lista (conversas + mensagens, em dois CSV) e na agenda (leads). Respeita o filtro que estiver ativo. |
| Avisos | WhatsApp para o corretor quando a Ana registra um lead novo e quando um cliente pede atendimento humano. |
| Papeis | **gerente** ve tudo e o Painel; **corretor** ve as conversas sem dono e as que assumiu. |

## 1. Banco

Rodar `sql/004_atendimento.sql` no SQL Editor do Supabase (projeto da Houzze). Pode rodar de novo sem estragar.
Ele cria as colunas de atendimento, a fila `ia_envios`, a tabela `ia_eventos`, as visoes do painel e as regras de
acesso por papel. No fim, libera `lucas@hotmail.com` como gerente e promove `imobiliariahouzze@gmail.com` a gerente.

Depois, `sql/005_telefone.sql`: a planilha de leads grava o telefone como a Ana escreve (sem o 55) e o WhatsApp manda
com o DDI; o 005 faz lead e conversa casarem pelos ultimos 11 digitos (ficha do lead, etiqueta "agendado", quem ve o
que na agenda). Sem ele, a ficha fica vazia e a etiqueta nao acende.

Para cadastrar corretores (o WhatsApp e opcional, serve para os avisos):

```sql
insert into public.ia_liberacoes (email, nome, papel, whatsapp)
values ('corretor@houzze.com.br', 'Nome', 'corretor', '5511999999999')
on conflict (email) do update set nome = excluded.nome, papel = excluded.papel, whatsapp = excluded.whatsapp;
```

## 2. Usuarios

A liberacao no SQL nao cria a senha. Em **Authentication > Users > Add user > Create new user**, informar o e-mail
e a senha e marcar **Auto Confirm User**. Fazer isso para `lucas@hotmail.com` e para cada corretor.
Recomendacao: senha longa, nunca sequencia de numeros; o proprio usuario pode trocar depois.

## 3. n8n

### 3.1 Fluxo da Ana (pausa)

Importar os dois nos de `n8n/ana-pausa.json` e ligar `Dados -> Conversa no backoffice -> Ana em pausa? -> (falso) Esperar 15 segundos`.
A saida "verdadeiro" fica solta: a mensagem do cliente ja foi gravada e a Ana nao responde.
No no **Visto e digitando**, trocar `message_id: $json.message_id` por `message_id: $('Dados').first().json.message_id`.
(O fluxo completo ja montado com tudo isso esta em `Downloads/houzze-ana-fluxo-completo.json`, fora do repositorio porque tem o PIN.)

### 3.2 Fluxo novo "Houzze - Backoffice"

Importar `n8n/backoffice.json`. Ao abrir o no **Webhook do Supabase**, criar uma credencial **Header Auth**:
nome `x-houzze-segredo`, valor uma frase longa e aleatoria (guardar, vai ser usada no passo 4). Ativar o fluxo e
copiar a URL de producao do webhook (`https://<seu n8n>/webhook/houzze-backoffice`).

No no **Evento**, o campo `whatsapp_padrao` pode receber um numero (so digitos, com 55) que recebe os avisos quando
nenhum corretor ou gerente tiver WhatsApp em `ia_liberacoes`. Pode ficar vazio.

O que o fluxo faz:

- `ia_envios` novo: manda o texto pelo numero oficial, grava em `ia_mensagens` como `corretor` e marca `enviado` (ou `erro`, com o motivo; o backoffice mostra o balao tracejado).
- `ia_eventos` do tipo `agendamento_atualizado`: acha a linha na aba Leads pela coluna `data_hora` e troca `status`, `visita_dia` e `visita_periodo`.
- `ia_eventos` do tipo `novo_agendamento` ou `pediu_humano`: manda um modelo (template) de WhatsApp para o corretor que assumiu a conversa; sem corretor, para os gerentes com WhatsApp; sem ninguem, para `whatsapp_padrao`.

## 4. Webhooks do Supabase

Em **Database > Webhooks > Create a new hook**, dois ganchos iguais, mudando so a tabela:

| Campo | Valor |
| --- | --- |
| Table | `ia_envios` (1o gancho) e `ia_eventos` (2o gancho) |
| Events | somente **Insert** |
| Type | HTTP Request, POST |
| URL | a URL de producao do webhook do n8n |
| HTTP Headers | `x-houzze-segredo` = o mesmo valor da credencial do n8n; `Content-Type` = `application/json` |

## 5. Modelos de mensagem na Meta (avisos ao corretor)

O corretor nao escreveu para o numero da Ana, entao a Meta so aceita mensagem de **modelo** (template). Em
**WhatsApp Manager > Modelos de mensagem > Criar**, categoria **Utilidade**, idioma **Portugues (BR)**:

**houzze_novo_lead**

```
Novo lead da Ana: {{1}} ({{2}}).
Interesse: {{3}}.
Visita: {{4}}.
Abra o backoffice para ver a conversa.
```

**houzze_pediu_humano**

```
{{1}} ({{2}}) pediu para falar com uma pessoa.
Ultima mensagem: "{{3}}"
Responda pelo backoffice: a Ana ja esta em pausa nessa conversa.
```

A aprovacao costuma levar minutos, as vezes horas. Enquanto nao aprovar, o evento fica em `ia_eventos` com o erro no
campo `resultado`. Alternativa sem modelo: trocar o no "Enviar aviso (modelo aprovado)" por um no de e-mail (Gmail ou
SMTP) usando os mesmos campos `$json.parametros`.

## 6. Limites que valem a pena saber

- **Janela de 24 h.** A Meta so deixa a equipe mandar texto livre para um cliente que escreveu nas ultimas 24 horas.
  Passou disso, o envio volta com erro e o balao fica tracejado; nesse caso, usar um modelo ou o WhatsApp do corretor.
- **Planilha x backoffice.** Depois que alguem confirma, remarca ou cancela uma visita pelo backoffice, o backoffice
  manda naquele lead: a sincronizacao de 5 minutos nao sobrescreve mais o dia, o periodo e o status dele. Mudancas
  feitas direto na planilha nesse lead nao voltam para o backoffice.
- **Etiqueta automatica** e uma leitura por palavras-chave (preco, parcela, entrada, visita, atendente, corretor,
  humano...). A manual sempre vence.
- **Quem ve o que.** O corretor so le as conversas sem dono ou as dele. Se um corretor assumir uma conversa por engano,
  o gerente a passa para outra pessoa na ficha ("Passar para...").
