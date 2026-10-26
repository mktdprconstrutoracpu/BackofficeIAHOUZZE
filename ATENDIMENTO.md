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

Importar os dois nos de `n8n/ana-pausa.json` e ligar `Dados -> Conversa no backoffice -> Ana em pausa? -> (falso) Esperar antes do visto`
(no fluxo anterior esse no se chamava "Esperar 15 segundos"; em 23/10 o tempo total de resposta da Ana passou a 15 s:
4 s antes do visto e, depois da resposta, so o que faltar para completar 15 s contados da mensagem do cliente).
A saida "verdadeiro" fica solta: a mensagem do cliente ja foi gravada e a Ana nao responde.
No no **Visto e digitando**, trocar `message_id: $json.message_id` por `message_id: $('Dados').first().json.message_id`.
(O fluxo completo ja montado com tudo isso esta em `Downloads/houzze-ana-fluxo-completo.json`, fora do repositorio porque tem o PIN.)

### 3.1b Documentos da pre analise (26/10/2026)

Antes de fechar o agendamento, a Ana pede seis documentos (CNH ou RG, comprovante de residencia, declaracao de
imposto de renda, certidao de nascimento ou casamento, comprovante de renda formal e extrato bancario dos ultimos
6 meses) e a pessoa manda foto ou PDF pelo proprio WhatsApp. Nada disso passa pela IA:

- `WhatsApp Trigger -> Fotos e arquivos` (filtro `type` = image ou document) `-> Dados do arquivo -> Conversa (documento)
  -> Rotular documento -> Endereco do arquivo na Meta -> Baixar arquivo -> Guardar no cofre -> Registrar documento
  -> Arquivo na conversa -> Equipe assumiu? -> (falso) O que falta -> Montar confirmacao -> Enviar confirmacao`
  (+ `Gravar confirmacao`). Os nos estao em `n8n/documentos.json` (sem credenciais); o fluxo completo montado fica em
  `Downloads/houzze-ana-fluxo-completo.json`.
- O arquivo vai para o bucket privado `documentos` do Supabase (`<telefone>/<timestamp>-<tipo>.<ext>`), a linha para
  `ia_documentos` e um balao para a conversa (`ia_mensagens.texto` = caminho no cofre). A pessoa recebe na hora
  "Recebi a CNH ou RG! Ainda faltam: ...". Se a equipe assumiu a conversa (Ana em pausa), o arquivo e guardado e a
  confirmacao nao sai.
- O tipo vem da legenda ("segue o RG"), senao de `ia_conversas.documento_esperado`, senao fica `outro`: a confirmacao
  pergunta qual documento e, e a Ana reclassifica com a ferramenta `classificar_documento`
  (`rpc/ia_classificar_ultimo_documento`). A equipe tambem reclassifica pelo backoffice.
- No fluxo de texto, o no `Documentos da pessoa` (entre `Visto e digitando` e o agente) le a view
  `ia_documentos_resumo` e o texto do agente ganha "Documentos ja recebidos: ... Ainda faltam: ...", para a Ana nao
  pedir de novo. A secao "Documentos para a pre analise" do prompt diz quando pedir e que a visita nunca fica presa
  por documento.
- Credenciais dos HTTP Request: **WhatsApp account** (predefinida `whatsAppApi`, baixa o arquivo da Meta) e
  **Supabase Houzze** (predefinida `supabaseApi`, com a chave `service_role`: sobe no cofre e grava as linhas).
- SQL: `sql/006_documentos.sql` (bucket, tabela, view, funcoes, policies, realtime).

No backoffice: bloco "Documentos para a pre analise" na ficha (N de 6, barra, cada item com Abrir / Conferir /
Recusar, seletor "E qual?" nos arquivos sem tipo), balao de arquivo na conversa (abre por link assinado de 5 minutos)
e o chip `docs N/6` nos cartoes da agenda.

### 3.2 Fluxo "Houzze - Backoffice e leads"

`n8n/backoffice.json` e um fluxo unico que **substitui** o "Houzze - Leads para o backoffice": traz os mesmos quatro
nos da sincronizacao dos leads (mesmo gatilho de 5 minutos) mais o webhook e a varredura da fila. Abrir o fluxo dos
leads no n8n, menu "..." > **Import from File**, escolher o arquivo: o conteudo e trocado e nao fica nada em dobro.
(Se preferir importar como fluxo novo, desativar o antigo, senao a planilha e copiada duas vezes a cada 5 minutos.)

Ao abrir o no **Webhook do Supabase**, criar uma credencial **Header Auth**: nome `x-houzze-segredo`, valor uma frase
longa e aleatoria (guardar, vai ser usada no passo 4). Ativar o fluxo e copiar a URL de producao do webhook
(`https://<seu n8n>/webhook/houzze-backoffice`).

No no **Evento**, o campo `whatsapp_padrao` pode receber um numero (so digitos, com 55) que recebe os avisos quando
nenhum corretor ou gerente tiver WhatsApp em `ia_liberacoes`. Pode ficar vazio.

O que o fluxo faz:

- `ia_envios` novo: manda o texto pelo numero oficial, grava em `ia_mensagens` como `corretor` e marca `enviado` (ou `erro`, com o motivo; o backoffice mostra o balao tracejado).
- A cada 5 minutos, varre a fila: envio ainda `pendente` ou evento sem `tratado_em` ha mais de 2 minutos sai pelo mesmo caminho. E o que faz uma mensagem escrita antes de o fluxo existir (ou com o n8n fora do ar) sair sozinha depois.
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
