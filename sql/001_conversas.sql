-- Backoffice IA Houzze: as conversas da Ana (IA do WhatsApp) gravadas pelo n8n.
-- Rodar UMA vez no SQL Editor do Supabase. Prefixo ia_ para conviver com as outras tabelas do projeto.
-- Pode rodar de novo sem estragar nada: tudo e "if not exists" ou "or replace".

-- 1. Cada mensagem, do cliente ou da Ana
create table if not exists public.ia_mensagens (
  id            bigint generated always as identity primary key,
  telefone      text not null,                 -- DDI + DDD + numero, so digitos, como a Meta manda (5511999999999)
  nome_whatsapp text,                          -- nome do perfil no WhatsApp, quando a Meta manda
  direcao       text not null check (direcao in ('cliente', 'ana')),
  tipo          text not null default 'text',  -- text, audio, image, document...
  texto         text,
  wa_id         text,                          -- id da mensagem na Meta (wamid...); impede gravar a mesma duas vezes
  criada_em     timestamptz not null default now()
);
create unique index if not exists ia_mensagens_wa_id on public.ia_mensagens (wa_id) where wa_id is not null;
create index if not exists ia_mensagens_telefone on public.ia_mensagens (telefone, criada_em);

-- 2. Uma linha por numero: o resumo que a lista do backoffice mostra
create table if not exists public.ia_conversas (
  telefone        text primary key,
  nome_whatsapp   text,
  primeira_em     timestamptz not null,
  ultima_em       timestamptz not null,
  ultima_mensagem text,
  ultima_direcao  text,
  total           integer not null default 0,
  do_cliente      integer not null default 0
);

-- 3. Quem pode entrar no backoffice (o e-mail do login do Supabase Auth)
create table if not exists public.ia_liberacoes (
  email     text primary key,
  nome      text,
  criado_em timestamptz not null default now()
);

-- 4. Toda mensagem nova atualiza o resumo da conversa (o n8n so insere em ia_mensagens)
create or replace function public.ia_atualizar_conversa() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.ia_conversas
    (telefone, nome_whatsapp, primeira_em, ultima_em, ultima_mensagem, ultima_direcao, total, do_cliente)
  values
    (new.telefone, nullif(new.nome_whatsapp, ''), new.criada_em, new.criada_em, left(new.texto, 200), new.direcao,
     1, case when new.direcao = 'cliente' then 1 else 0 end)
  on conflict (telefone) do update set
    nome_whatsapp   = coalesce(nullif(excluded.nome_whatsapp, ''), ia_conversas.nome_whatsapp),
    ultima_em       = greatest(ia_conversas.ultima_em, excluded.ultima_em),
    ultima_mensagem = case when excluded.ultima_em >= ia_conversas.ultima_em then excluded.ultima_mensagem else ia_conversas.ultima_mensagem end,
    ultima_direcao  = case when excluded.ultima_em >= ia_conversas.ultima_em then excluded.ultima_direcao  else ia_conversas.ultima_direcao  end,
    total           = ia_conversas.total + 1,
    do_cliente      = ia_conversas.do_cliente + excluded.do_cliente;
  return new;
end $$;

drop trigger if exists ia_mensagens_atualiza_conversa on public.ia_mensagens;
create trigger ia_mensagens_atualiza_conversa
  after insert on public.ia_mensagens
  for each row execute function public.ia_atualizar_conversa();

-- 5. Seguranca: so quem esta em ia_liberacoes le. Ninguem escreve pelo site.
--    O n8n grava com a chave de servico (service_role), que passa por cima do RLS.
create or replace function public.ia_tem_acesso() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.ia_liberacoes l
    where lower(l.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

alter table public.ia_mensagens  enable row level security;
alter table public.ia_conversas  enable row level security;
alter table public.ia_liberacoes enable row level security;

drop policy if exists ia_mensagens_ler  on public.ia_mensagens;
drop policy if exists ia_conversas_ler  on public.ia_conversas;
drop policy if exists ia_liberacoes_ler on public.ia_liberacoes;
create policy ia_mensagens_ler  on public.ia_mensagens  for select to authenticated using (public.ia_tem_acesso());
create policy ia_conversas_ler  on public.ia_conversas  for select to authenticated using (public.ia_tem_acesso());
create policy ia_liberacoes_ler on public.ia_liberacoes for select to authenticated
  using (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));

-- 6. Tempo real: o backoffice recebe a mensagem nova sem recarregar
do $$ begin
  alter publication supabase_realtime add table public.ia_mensagens;
exception when duplicate_object then null; end $$;

-- 7. Quem entra. Troque pelos e-mails de verdade (um insert por pessoa) e rode so esta parte de novo quando precisar.
-- insert into public.ia_liberacoes (email, nome) values ('alguem@houzze.com.br', 'Nome') on conflict (email) do nothing;
