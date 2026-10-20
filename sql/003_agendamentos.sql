-- 003 (20/10/2026): agendamentos no backoffice.
-- A Ana grava os leads na aba "Leads" da planilha (registrar_lead). O fluxo n8n "Houzze - Leads para o backoffice"
-- copia essa aba para ca a cada 5 minutos (upsert pela chave), e o backoffice le daqui. Rodar UMA vez.

create table if not exists public.ia_agendamentos (
  chave             text primary key,          -- telefone|data_hora da planilha: estavel mesmo se a linha mudar de lugar
  registrado_em     timestamptz,               -- data_hora da planilha convertida
  data_hora_texto   text,                      -- como esta na planilha (dd/MM/yyyy HH:mm)
  nome              text,
  telefone          text,                      -- so digitos
  interesse         text,
  renda_informada   text,
  unidade_interesse text,
  visita_dia        date,                      -- null quando nao marcou visita (so contato / outro imovel)
  visita_periodo    text,
  resumo            text,
  status            text,
  corretor          text,
  origem            text,
  atualizado_em     timestamptz not null default now()
);
create index if not exists ia_agendamentos_visita on public.ia_agendamentos (visita_dia);
create index if not exists ia_agendamentos_telefone on public.ia_agendamentos (telefone);

create or replace function public.ia_agendamentos_tocar() returns trigger
language plpgsql as $$
begin new.atualizado_em = now(); return new; end $$;
drop trigger if exists ia_agendamentos_tocar on public.ia_agendamentos;
create trigger ia_agendamentos_tocar before update on public.ia_agendamentos
  for each row execute function public.ia_agendamentos_tocar();

alter table public.ia_agendamentos enable row level security;
drop policy if exists ia_agendamentos_ler on public.ia_agendamentos;
create policy ia_agendamentos_ler on public.ia_agendamentos for select to authenticated using (public.ia_tem_acesso());

do $$ begin
  alter publication supabase_realtime add table public.ia_agendamentos;
exception when duplicate_object then null; end $$;
