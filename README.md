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

## Instalacao

1. **Banco:** rodar `sql/001_conversas.sql` no SQL Editor do projeto Supabase. Pode rodar de novo sem estragar.
2. **n8n:** criar a credencial "Supabase API" (host do projeto + chave `service_role`) e colar os dois nos de
   `n8n/nos-gravar-conversa.json` no fluxo, ligando `Dados -> Gravar mensagem do cliente` e
   `Agente Houzze -> Gravar resposta da Ana`.
3. **Quem entra:** criar o usuario em Authentication > Users (com "Auto Confirm User") e liberar o e-mail:

   ```sql
   insert into public.ia_liberacoes (email, nome) values ('pessoa@houzze.com.br', 'Nome') on conflict (email) do nothing;
   ```

4. **Publicar:** o repositorio e um site estatico; basta apontar um projeto da Vercel para ele.

## Seguranca

- A chave `publishable` que esta no `index.html` e publica por desenho. O que protege os dados e o RLS:
  so e-mails em `ia_liberacoes` leem, e ninguem escreve pelo site.
- A chave `service_role` fica apenas no cofre de credenciais do n8n. Nunca no repositorio.
- O fluxo completo do n8n contem o PIN do numero e ids de credenciais: nao sobe para este repositorio.
