# Conversas da Ana (Houzze)

Backoffice da Houzze Imobiliaria para ver todas as conversas da **Ana**, a consultora virtual que atende o
WhatsApp pela API oficial da Meta. Como o numero esta na API, ninguem consegue abrir essas conversas no
aplicativo do WhatsApp; aqui elas aparecem com o numero do cliente, o nome do perfil e a troca completa.

## Como funciona

1. O fluxo da Ana no n8n recebe a mensagem do cliente, responde com a IA e **grava as duas pontas** na tabela
   `ia_mensagens` do Supabase (nos `Gravar mensagem do cliente` e `Gravar resposta da Ana`, em
   `n8n/nos-gravar-conversa.json`). Esses nos rodam em paralelo com o fluxo original e, se falharem, nao
   seguram a resposta da Ana.
2. Um gatilho no banco mantem `ia_conversas`, uma linha por numero com a ultima mensagem e as contagens.
3. Esta pagina (`index.html`, sem build) faz login pelo Supabase Auth, le as duas tabelas e recebe mensagens
   novas em tempo real.

## Alem das conversas

- **Atendimento humano (22/10/2026):** pausar a Ana e responder pelo numero oficial, etiquetas com filtro, ficha do
  lead com notas, busca dentro das conversas, confirmar/remarcar/cancelar visitas (volta para a planilha), avisos
  por WhatsApp ao corretor, aba "Nao resolvidas", painel de numeros para o gerente, exportar CSV e papeis
  (gerente e corretor). SQL em `sql/004_atendimento.sql`, fluxo `n8n/backoffice.json` e a checagem de pausa
  `n8n/ana-pausa.json` no fluxo da Ana. **Passo a passo em `ATENDIMENTO.md`.**
- **Aba Agendamentos:** o que a Ana registra na aba "Leads" da planilha (visitas marcadas, contatos, repasses ao
  corretor). O fluxo n8n `n8n/leads-backoffice.json` copia a aba para a tabela `ia_agendamentos` a cada 5 minutos
  (SQL em `sql/003_agendamentos.sql`); status e corretor editados na planilha aparecem no backoffice no proximo ciclo
  (menos nos leads que a equipe ja mexeu pelo backoffice: nesses, o backoffice manda).
- **Retomada automatica:** o fluxo `n8n/retomada.json` (SQL em `sql/002_retomada.sql`) manda "posso ajudar em mais
  alguma coisa?" quando o cliente fica 20 minutos sem responder e encerra com educacao 20 minutos depois, sempre
  dentro da janela de 24 horas da Meta. As mensagens aparecem na conversa como da Ana.
## Instalacao

1. **Banco:** rodar `sql/001_conversas.sql`, `002`, `003` e `004` (nessa ordem) no SQL Editor do projeto Supabase.
   Podem rodar de novo sem estragar.
2. **n8n:** criar a credencial "Supabase API" (host do projeto + chave `service_role`) e colar os dois nos de
   `n8n/nos-gravar-conversa.json` no fluxo da Ana, ligando `Dados -> Gravar mensagem do cliente` e
   `Agente Houzze -> Gravar resposta da Ana`. Depois, a checagem de pausa (`n8n/ana-pausa.json`) e o fluxo
   `n8n/backoffice.json`, como descrito em `ATENDIMENTO.md`.
3. **Quem entra:** criar o usuario em Authentication > Users (com "Auto Confirm User") e liberar o e-mail com o papel
   (`gerente` ve tudo e o painel; `corretor` ve as conversas sem dono e as dele):

   ```sql
   insert into public.ia_liberacoes (email, nome, papel) values ('pessoa@houzze.com.br', 'Nome', 'corretor') on conflict (email) do nothing;
   ```

4. **Publicar:** o repositorio e um site estatico; basta apontar um projeto da Vercel para ele.

## Seguranca

- A chave `publishable` que esta no `index.html` e publica por desenho. O que protege os dados e o RLS:
  so e-mails em `ia_liberacoes` leem (cada papel o que lhe cabe) e o site so escreve nas colunas de atendimento
  (etiqueta, notas, pausa, responsavel, status da visita) e na fila de envios, sempre em nome de quem esta logado.
- O segredo do webhook (cabecalho `x-houzze-segredo`) fica so na credencial do n8n e na configuracao do Supabase.
- A chave `service_role` fica apenas no cofre de credenciais do n8n. Nunca no repositorio.
- O fluxo completo do n8n contem o PIN do numero e ids de credenciais: nao sobe para este repositorio.
